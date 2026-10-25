using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;

// Independent, non-GUI verification host for the installed AZtec Crystal
// backend. It deliberately loads core.ebsd.dll, not AZtecCrystal.exe.
public static class AztecNativeIpfConsole
{
    private static readonly List<string> Evidence = new List<string>();

    private static void Log(string text)
    {
        Evidence.Add(text);
        Console.WriteLine(text);
    }

    private static string Sha256(string path)
    {
        using (var sha = SHA256.Create())
        using (var stream = File.OpenRead(path))
            return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "");
    }

    private static object Property(object value, string name)
    {
        if (value == null) throw new InvalidOperationException("null_object_for_property:" + name);
        var property = value.GetType().GetProperty(name,
            BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance);
        if (property == null) throw new MissingMemberException(value.GetType().FullName, name);
        return property.GetValue(value, null);
    }

    private static object Indexed(object collection, int index)
    {
        if (collection == null) throw new InvalidOperationException("null_indexed_collection");
        var array = collection as Array;
        if (array != null) return array.GetValue(index);
        var list = collection as IList;
        if (list != null) return list[index];
        var getter = collection.GetType().GetMethod("GetItem",
            BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance,
            null, new[] { typeof(int) }, null);
        if (getter != null) return getter.Invoke(collection, new object[] { index });
        var item = collection.GetType().GetProperty("Item",
            BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance,
            null, null, new[] { typeof(int) }, null);
        if (item == null) throw new MissingMemberException(collection.GetType().FullName, "Item[int]");
        return item.GetValue(collection, new object[] { index });
    }

    private static int Count(object collection)
    {
        if (collection is Array) return ((Array)collection).Length;
        var list = collection as ICollection;
        if (list != null) return list.Count;
        return Convert.ToInt32(Property(collection, "Count"), CultureInfo.InvariantCulture);
    }

    private static object ConvertArgument(object value, Type target)
    {
        if (value == null) return null;
        if (target.IsInstanceOfType(value)) return value;
        if (target == typeof(string)) return value as string ?? Convert.ToString(value, CultureInfo.InvariantCulture);
        if (target.IsEnum) return Enum.ToObject(target, Convert.ToInt32(value, CultureInfo.InvariantCulture));
        if (target == typeof(double)) return Convert.ToDouble(value, CultureInfo.InvariantCulture);
        if (target == typeof(float)) return Convert.ToSingle(value, CultureInfo.InvariantCulture);
        if (target == typeof(int)) return Convert.ToInt32(value, CultureInfo.InvariantCulture);
        if (target == typeof(long)) return Convert.ToInt64(value, CultureInfo.InvariantCulture);
        if (target == typeof(byte)) return Convert.ToByte(value, CultureInfo.InvariantCulture);
        return Convert.ChangeType(value, target, CultureInfo.InvariantCulture);
    }

    private static object Construct(Type type, params object[] values)
    {
        foreach (var ctor in type.GetConstructors(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance))
        {
            var parameters = ctor.GetParameters();
            if (parameters.Length != values.Length) continue;
            try
            {
                var args = new object[values.Length];
                for (var i = 0; i < values.Length; i++) args[i] = ConvertArgument(values[i], parameters[i].ParameterType);
                return ctor.Invoke(args);
            }
            catch (ArgumentException) { }
            catch (InvalidCastException) { }
        }
        throw new MissingMethodException(type.FullName, "constructor(" + values.Length + ")");
    }

    private static object InvokeStatic(Type type, string name, object[] values)
    {
        foreach (var method in type.GetMethods(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static))
        {
            if (method.Name != name) continue;
            var parameters = method.GetParameters();
            if (parameters.Length != values.Length) continue;
            try
            {
                var args = new object[values.Length];
                for (var i = 0; i < values.Length; i++) args[i] = ConvertArgument(values[i], parameters[i].ParameterType);
                return method.Invoke(null, args);
            }
            catch (ArgumentException) { }
            catch (InvalidCastException) { }
        }
        throw new MissingMethodException(type.FullName, name);
    }

    private static void SaveBitmap(Type bitmapType, object bitmap, string output)
    {
        var method = bitmapType.GetMethods(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static)
            .First(x => x.Name == "Save" && x.GetParameters().Length == 2
                && x.GetParameters()[1].ParameterType == typeof(string));
        Log("bitmap_save_method=" + method);
        Log("bitmap_save_path=" + output + ";type=" + output.GetType().FullName);
        method.Invoke(null, new object[] { bitmap, output });
    }

    private static void WriteStandardBmp32(int[] argb, int width, int height, string output)
    {
        var rowBytes = width * 4;
        var fileSize = 54 + rowBytes * height;
        using (var stream = new FileStream(output, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        using (var writer = new BinaryWriter(stream, Encoding.UTF8))
        {
            writer.Write((byte)'B'); writer.Write((byte)'M');
            writer.Write(fileSize); writer.Write((short)0); writer.Write((short)0); writer.Write(54);
            writer.Write(40); writer.Write(width); writer.Write(height); writer.Write((short)1);
            writer.Write((short)32); writer.Write(0); writer.Write(0);
            writer.Write(3780); writer.Write(3780); writer.Write(0); writer.Write(0);
            // Match BitmapTools' positive-height, bottom-up scanline order.
            for (var y = height - 1; y >= 0; y--)
                for (var x = 0; x < width; x++)
                {
                    var color = argb[y * width + x];
                    writer.Write((byte)(color & 0xFF));
                    writer.Write((byte)((color >> 8) & 0xFF));
                    writer.Write((byte)((color >> 16) & 0xFF));
                    writer.Write((byte)((color >> 24) & 0xFF));
                }
        }
    }

    private static object InvokeInstance(object instance, string name, object[] values)
    {
        foreach (var method in instance.GetType().GetMethods(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance))
        {
            if (method.Name != name) continue;
            var parameters = method.GetParameters();
            if (parameters.Length != values.Length) continue;
            try
            {
                var args = new object[values.Length];
                for (var i = 0; i < values.Length; i++) args[i] = ConvertArgument(values[i], parameters[i].ParameterType);
                return method.Invoke(instance, args);
            }
            catch (ArgumentException) { }
            catch (InvalidCastException) { }
        }
        throw new MissingMethodException(instance.GetType().FullName, name);
    }

    private static byte ColorChannel(object color, string name)
    {
        return Convert.ToByte(Property(color, name), CultureInfo.InvariantCulture);
    }

    private static string Json(string value)
    {
        if (value == null) return "null";
        return "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"")
            .Replace("\r", "\\r").Replace("\n", "\\n") + "\"";
    }

    private static void WriteReport(string path, string sourceCpr, string sourceCrc,
        string cprHash, string crcHash, string outputHash, int width, int height,
        int pointCount, int indexedCount, double maxError, string firstRgb,
        string colorType, string bitmapType, string rgbPath, string rgbHash,
        string status, string error)
    {
        var builder = new StringBuilder();
        builder.AppendLine("{");
        builder.AppendLine("  \"status\": " + Json(status) + ",");
        builder.AppendLine("  \"source_cpr\": " + Json(sourceCpr) + ",");
        builder.AppendLine("  \"source_crc\": " + Json(sourceCrc) + ",");
        builder.AppendLine("  \"source_cpr_sha256\": " + Json(cprHash) + ",");
        builder.AppendLine("  \"source_crc_sha256\": " + Json(crcHash) + ",");
        builder.AppendLine("  \"output_bmp_sha256\": " + Json(outputHash) + ",");
        builder.AppendLine("  \"output_rgb\": " + Json(rgbPath) + ",");
        builder.AppendLine("  \"output_rgb_sha256\": " + Json(rgbHash) + ",");
        builder.AppendLine("  \"width\": " + width + ",");
        builder.AppendLine("  \"height\": " + height + ",");
        builder.AppendLine("  \"point_count\": " + pointCount + ",");
        builder.AppendLine("  \"indexed_count\": " + indexedCount + ",");
        builder.AppendLine("  \"sample_direction\": \"Z\",");
        builder.AppendLine("  \"row_order\": \"CPR dataset index, x-fastest\",");
        builder.AppendLine("  \"max_euler_to_native_orientation_error_deg\": " + maxError.ToString("R", CultureInfo.InvariantCulture) + ",");
        builder.AppendLine("  \"first_valid_rgb\": " + Json(firstRgb) + ",");
        builder.AppendLine("  \"color_component\": " + Json(colorType) + ",");
        builder.AppendLine("  \"bitmap_component\": " + Json(bitmapType) + ",");
        builder.AppendLine("  \"gui_started\": false,");
        builder.AppendLine("  \"error\": " + Json(error) + ",");
        builder.AppendLine("  \"evidence\": [");
        for (var i = 0; i < Evidence.Count; i++)
            builder.AppendLine("    " + Json(Evidence[i]) + (i + 1 == Evidence.Count ? "" : ","));
        builder.AppendLine("  ]");
        builder.AppendLine("}");
        File.WriteAllText(path, builder.ToString(), new UTF8Encoding(true));
    }

    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Length != 4)
        {
            Console.Error.WriteLine("usage: AztecNativeIpfConsole <aztec-root> <cpr> <output-bmp> <report-json>");
            return 2;
        }
        var root = Path.GetFullPath(args[0]);
        var cpr = Path.GetFullPath(args[1]);
        var crc = Path.ChangeExtension(cpr, ".crc");
        var output = Path.GetFullPath(args[2]);
        var report = Path.GetFullPath(args[3]);
        string cprHash = null, crcHash = null, outputHash = null, rgbPath = null, rgbHash = null;
        var width = 0; var height = 0; var points = 0; var indexed = 0;
        var maxError = 0.0; var firstRgb = ""; object project = null;
        var bitmapComponent = "Core.Ebsd.ImageProcessing.BitmapTools";
        try
        {
            if (!File.Exists(cpr)) throw new FileNotFoundException("cpr_not_found", cpr);
            if (!File.Exists(crc)) throw new FileNotFoundException("crc_not_found", crc);
            Directory.CreateDirectory(Path.GetDirectoryName(output));
            Directory.CreateDirectory(Path.GetDirectoryName(report));
            if (File.Exists(output) || File.Exists(report)) throw new IOException("refusing_existing_output");
            cprHash = Sha256(cpr); crcHash = Sha256(crc);
            Log("gui_started=false");
            Log("source_cpr_sha256=" + cprHash);
            Log("source_crc_sha256=" + crcHash);

            Environment.CurrentDirectory = root;
            AppDomain.CurrentDomain.AssemblyResolve += delegate(object sender, ResolveEventArgs eventArgs)
            {
                var candidate = Path.Combine(root, new AssemblyName(eventArgs.Name).Name + ".dll");
                return File.Exists(candidate) ? Assembly.LoadFrom(candidate) : null;
            };
            foreach (var dll in Directory.GetFiles(root, "*.dll"))
            {
                try { Assembly.LoadFrom(dll); } catch (Exception ex) { Log("assembly_skip=" + Path.GetFileName(dll) + ":" + ex.GetType().Name); }
            }
            var core = Assembly.LoadFrom(Path.Combine(root, "core.ebsd.dll"));
            Log("core_ebsd=" + core.FullName);
            var projectType = core.GetType("Core.Ebsd.Infrastructure.Project", true);
            project = Construct(projectType, cpr);
            Log("component=Core.Ebsd.Infrastructure.Project(path)");
            var datasets = Property(project, "Datasets");
            if (Convert.ToInt32(Property(project, "DatasetCount"), CultureInfo.InvariantCulture) != 1 || Count(datasets) != 1)
                throw new InvalidDataException("expected_one_dataset");
            var dataset = Indexed(datasets, 0);
            var populated = Convert.ToBoolean(Property(dataset, "IsPopulated"), CultureInfo.InvariantCulture);
            if (!populated) { InvokeInstance(dataset, "PopulateData", new object[0]); Log("dataset_populated=true"); }
            else Log("dataset_populated=already");
            width = Convert.ToInt32(Property(dataset, "XCount"), CultureInfo.InvariantCulture);
            height = Convert.ToInt32(Property(dataset, "YCount"), CultureInfo.InvariantCulture);
            points = Convert.ToInt32(Property(dataset, "PixelCount"), CultureInfo.InvariantCulture);
            if (width < 2 || height < 2 || width * height != points) throw new InvalidDataException("invalid_regular_grid");
            Log("grid=" + width + "x" + height + ";points=" + points);

            var phaseIds = Property(dataset, "PhaseID");
            var euler1 = Property(dataset, "Euler1");
            var euler2 = Property(dataset, "Euler2");
            var euler3 = Property(dataset, "Euler3");
            var orientations = Property(dataset, "Orientation");
            var phases = Property(dataset, "Phases");
            var symmetryType = core.GetType("Core.Ebsd.Crystallography.CrystalSymmetry", true);
            var laueType = core.GetType("Core.Ebsd.Crystallography.LaueGroups", true);
            var symmetries = new Dictionary<int, object>();
            for (var phaseId = 1; phaseId < Count(phases); phaseId++)
            {
                var phase = Indexed(phases, phaseId);
                var laue = Property(phase, "LaueGroup");
                symmetries[phaseId] = Construct(symmetryType,
                    Property(phase, "Name"), Property(phase, "A"), Property(phase, "B"), Property(phase, "C"),
                    Convert.ToDouble(Property(phase, "AlphaDeg"), CultureInfo.InvariantCulture) * Math.PI / 180.0,
                    Convert.ToDouble(Property(phase, "BetaDeg"), CultureInfo.InvariantCulture) * Math.PI / 180.0,
                    Convert.ToDouble(Property(phase, "GammaDeg"), CultureInfo.InvariantCulture) * Math.PI / 180.0,
                    Enum.ToObject(laueType, Convert.ToInt32(laue, CultureInfo.InvariantCulture)));
            }
            Log("phase_symmetries=" + symmetries.Count);
            var eulerType = core.GetType("Core.Ebsd.Geometry.Euler", true);
            var quaternionType = core.GetType("Core.Ebsd.Geometry.Quaternion", true);
            var directionsType = core.GetType("Core.Ebsd.Geometry.SampleDirections", true);
            var directionType = core.GetType("Core.Ebsd.Geometry.SampleDirection", true);
            var directionEnum = Enum.Parse(directionsType, "Z");
            var sampleDirection = Construct(directionType, directionEnum);
            var ipfType = core.GetType("Core.Ebsd.Calculations.IPFColorCoding", true);
            var ipf = Construct(ipfType, sampleDirection);
            var getColor = ipfType.GetMethods(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance)
                .First(x => x.Name == "GetColor" && x.GetParameters().Length == 2);
            Log("component=Core.Ebsd.Calculations.IPFColorCoding(SampleDirection.Z)");

            var argb = new int[points];
            for (var i = 0; i < points; i++)
            {
                var phaseId = Convert.ToInt32(Indexed(phaseIds, i), CultureInfo.InvariantCulture);
                if (phaseId <= 0) { argb[i] = -1; continue; }
                if (!symmetries.ContainsKey(phaseId)) throw new InvalidDataException("phase_id_out_of_range:" + phaseId);
                var euler = Construct(eulerType, Indexed(euler1, i), Indexed(euler2, i), Indexed(euler3, i));
                var q = InvokeInstance(euler, "ToQuaternion", new object[0]);
                var native = InvokeInstance(Indexed(orientations, i), "ToQuaternion", new object[0]);
                var dot = Math.Abs(Convert.ToDouble(Property(q, "W"), CultureInfo.InvariantCulture) * Convert.ToDouble(Property(native, "W"), CultureInfo.InvariantCulture)
                    + Convert.ToDouble(Property(q, "X"), CultureInfo.InvariantCulture) * Convert.ToDouble(Property(native, "X"), CultureInfo.InvariantCulture)
                    + Convert.ToDouble(Property(q, "Y"), CultureInfo.InvariantCulture) * Convert.ToDouble(Property(native, "Y"), CultureInfo.InvariantCulture)
                    + Convert.ToDouble(Property(q, "Z"), CultureInfo.InvariantCulture) * Convert.ToDouble(Property(native, "Z"), CultureInfo.InvariantCulture));
                dot = Math.Max(0.0, Math.Min(1.0, dot));
                maxError = Math.Max(maxError, 2.0 * Math.Acos(dot) * 180.0 / Math.PI);
                var color = getColor.Invoke(ipf, new[] { symmetries[phaseId], q });
                var r = ColorChannel(color, "R"); var g = ColorChannel(color, "G"); var b = ColorChannel(color, "B");
                argb[i] = unchecked((int)0xFF000000 | (r << 16) | (g << 8) | b);
                indexed++;
                if (firstRgb.Length == 0) firstRgb = r + "," + g + "," + b + ";phase=" + phaseId + ";index=" + i;
            }
            if (indexed == 0) throw new InvalidDataException("no_indexed_points");
            Log("ipf_valid_points=" + indexed);
            Log("first_valid_rgb=" + firstRgb);
            Log("max_euler_to_native_orientation_error_deg=" + maxError.ToString("R", CultureInfo.InvariantCulture));
            rgbPath = output + ".rgb";
            if (File.Exists(rgbPath)) File.Delete(rgbPath);
            using (var rgbStream = new FileStream(rgbPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            using (var rgbWriter = new BinaryWriter(rgbStream, Encoding.UTF8))
            {
                for (var i = 0; i < argb.Length; i++)
                {
                    var color = argb[i];
                    rgbWriter.Write((byte)((color >> 16) & 0xFF));
                    rgbWriter.Write((byte)((color >> 8) & 0xFF));
                    rgbWriter.Write((byte)(color & 0xFF));
                }
            }
            rgbHash = Sha256(rgbPath);
            Log("output_rgb=" + rgbPath);
            Log("output_rgb_sha256=" + rgbHash);
            var bitmapType = core.GetType("Core.Ebsd.ImageProcessing.BitmapTools", true);
            var bitmap = InvokeStatic(bitmapType, "IntArrayToBitmap", new object[] { argb, width, height });
            Log("component=Core.Ebsd.ImageProcessing.BitmapTools.IntArrayToBitmap");
            try
            {
                SaveBitmap(bitmapType, bitmap, output);
                Log("component=Core.Ebsd.ImageProcessing.BitmapTools.Save");
            }
            catch (Exception bitmapException)
            {
                var actualBitmap = bitmapException;
                while (actualBitmap is TargetInvocationException && actualBitmap.InnerException != null)
                    actualBitmap = actualBitmap.InnerException;
                bitmapComponent = "Core.Ebsd.ImageProcessing.BitmapTools.IntArrayToBitmap; Standard BMP 32bpp fallback after Save failure: "
                    + actualBitmap.GetType().FullName + ": " + actualBitmap.Message;
                Log("bitmap_save_failed=" + actualBitmap.GetType().FullName + ":" + actualBitmap.Message);
                if (File.Exists(output)) File.Delete(output);
                WriteStandardBmp32(argb, width, height, output);
                Log("component=standard_BMP_32bpp_fallback");
            }
            outputHash = Sha256(output);
            if (cprHash != Sha256(cpr) || crcHash != Sha256(crc)) throw new InvalidDataException("source_hash_changed");
            Log("source_hash_unchanged=true");
            WriteReport(report, cpr, crc, cprHash, crcHash, outputHash, width, height, points, indexed,
                maxError, firstRgb, "Core.Ebsd.Calculations.IPFColorCoding.GetColor", bitmapComponent,
                rgbPath, rgbHash, "ok", null);
            Console.WriteLine("status=ok");
            Console.WriteLine("output_bmp=" + output);
            Console.WriteLine("output_sha256=" + outputHash);
            return 0;
        }
        catch (Exception exception)
        {
            var actual = exception;
            while (actual is TargetInvocationException && actual.InnerException != null) actual = actual.InnerException;
            var detail = actual.GetType().FullName + ": " + actual.Message + "\n" + actual.StackTrace;
            Console.Error.WriteLine(detail);
            try { WriteReport(report, cpr, crc, cprHash, crcHash, outputHash, width, height, points, indexed,
                maxError, firstRgb, "Core.Ebsd.Calculations.IPFColorCoding.GetColor", "Core.Ebsd.ImageProcessing.BitmapTools",
                rgbPath, rgbHash, "failed", detail); }
            catch (Exception reportError) { Console.Error.WriteLine("report_write_failed=" + reportError); }
            return 1;
        }
        finally
        {
            var disposable = project as IDisposable;
            if (disposable != null) try { disposable.Dispose(); } catch { }
        }
    }
}
