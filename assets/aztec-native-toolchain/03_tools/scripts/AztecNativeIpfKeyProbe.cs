using System;
using System.Collections;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;

public static class AztecNativeIpfKeyProbe
{
    private static object Get(object target, string name)
    {
        if (target == null) throw new InvalidOperationException("null_for:" + name);
        var property = target.GetType().GetProperty(name, BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance);
        if (property == null) throw new MissingMemberException(target.GetType().FullName, name);
        return property.GetValue(target, null);
    }

    private static int Count(object collection)
    {
        var array = collection as Array;
        if (array != null) return array.Length;
        var count = collection.GetType().GetProperty("Count");
        return Convert.ToInt32(count.GetValue(collection, null));
    }

    private static object Item(object collection, int index)
    {
        var array = collection as Array;
        if (array != null) return array.GetValue(index);
        return collection.GetType().GetProperty("Item").GetValue(collection, new object[] { index });
    }

    private static string Quote(string value)
    {
        return "\"" + (value ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"")
            .Replace("\r", "\\r").Replace("\n", "\\n") + "\"";
    }

    private static void WriteBmp32(int[] pixels, int width, int height, string path)
    {
        var rowBytes = width * 4;
        using (var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        using (var writer = new BinaryWriter(stream))
        {
            writer.Write((byte)'B'); writer.Write((byte)'M');
            writer.Write(54 + rowBytes * height); writer.Write(0); writer.Write(54);
            writer.Write(40); writer.Write(width); writer.Write(height);
            writer.Write((short)1); writer.Write((short)32); writer.Write(0);
            writer.Write(rowBytes * height); writer.Write(2835); writer.Write(2835);
            writer.Write(0); writer.Write(0);
            for (var y = height - 1; y >= 0; y--)
            for (var x = 0; x < width; x++)
            {
                var value = pixels[y * width + x];
                if ((value & 0x00FFFFFF) == 0) value = unchecked((int)0xFFFFFFFF);
                writer.Write((byte)(value & 0xFF));
                writer.Write((byte)((value >> 8) & 0xFF));
                writer.Write((byte)((value >> 16) & 0xFF));
                writer.Write((byte)0);
            }
        }
    }

    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Length != 4)
        {
            Console.Error.WriteLine("usage: AztecNativeIpfKeyProbe <aztec-root> <cpr> <report-json> <key-output-dir>");
            return 2;
        }
        var root = Path.GetFullPath(args[0]);
        var cpr = Path.GetFullPath(args[1]);
        var report = Path.GetFullPath(args[2]);
        var keyOutput = Path.GetFullPath(args[3]);
        object project = null;
        try
        {
            if (!File.Exists(cpr)) throw new FileNotFoundException("cpr_not_found", cpr);
            if (File.Exists(report)) throw new IOException("refusing_existing_report");
            if (Directory.Exists(keyOutput) && Directory.GetFiles(keyOutput, "*.bmp").Length != 0)
                throw new IOException("refusing_existing_key_bmps");
            Environment.CurrentDirectory = root;
            AppDomain.CurrentDomain.AssemblyResolve += delegate(object sender, ResolveEventArgs eventArgs)
            {
                var candidate = Path.Combine(root, new AssemblyName(eventArgs.Name).Name + ".dll");
                return File.Exists(candidate) ? Assembly.LoadFrom(candidate) : null;
            };
            foreach (var dll in Directory.GetFiles(root, "*.dll"))
                try { Assembly.LoadFrom(dll); } catch { }
            var core = Assembly.LoadFrom(Path.Combine(root, "core.ebsd.dll"));
            var projectType = core.GetType("Core.Ebsd.Infrastructure.Project", true);
            project = Activator.CreateInstance(projectType, new object[] { cpr });
            var datasets = Get(project, "Datasets");
            var dataset = Item(datasets, 0);
            if (!Convert.ToBoolean(Get(dataset, "IsPopulated"))) dataset.GetType().GetMethod("PopulateData").Invoke(dataset, null);
            var phases = Get(dataset, "Phases");
            Directory.CreateDirectory(keyOutput);
            var phaseRows = new StringBuilder();
            var phaseCount = Count(phases);
            for (var i = 1; i < phaseCount; i++)
            {
                var phase = Item(phases, i);
                var key = Get(phase, "IPFColorKey");
                var pixels = Get(key, "Pixels") as IEnumerable;
                var pixelValues = pixels.Cast<object>().Select(x => Convert.ToInt32(x)).ToArray();
                var keyWidth = Convert.ToInt32(Get(key, "Width"));
                var keyHeight = Convert.ToInt32(Get(key, "Height"));
                if (pixelValues.Length != keyWidth * keyHeight) throw new InvalidDataException("ipf_key_pixel_count_mismatch:" + i);
                var keyBmp = Path.Combine(keyOutput, "phase_" + i.ToString("D2") + ".bmp");
                WriteBmp32(pixelValues, keyWidth, keyHeight, keyBmp);
                var outlines = Get(key, "Outline2D") as IEnumerable;
                var outlineRows = outlines.Cast<object>().Select(polyline => Count(polyline)).ToArray();
                var outlinePolygons = outlines.Cast<object>().Select(polyline =>
                {
                    var points = (polyline as IEnumerable).Cast<object>();
                    return "[" + String.Join(",", points.Select(point => "["
                        + Convert.ToString(Get(point, "X"), System.Globalization.CultureInfo.InvariantCulture) + ","
                        + Convert.ToString(Get(point, "Y"), System.Globalization.CultureInfo.InvariantCulture) + "]")) + "]";
                }).ToArray();
                var annotations = Get(key, "Annotations2D") as IEnumerable;
                var annotationRows = annotations.Cast<object>().Select(annotation =>
                {
                    var description = new StringBuilder("{\"type\":").Append(Quote(annotation.GetType().FullName));
                    foreach (var property in annotation.GetType().GetProperties(BindingFlags.Public | BindingFlags.Instance))
                    {
                        if (property.GetIndexParameters().Length != 0) continue;
                        try
                        {
                            var value = property.GetValue(annotation, null);
                            if (value == null || value.GetType().IsPrimitive || value.GetType().IsEnum || value is string)
                                description.Append(",").Append(Quote(property.Name)).Append(":").Append(Quote(Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture)));
                            else if (value.GetType().GetProperties(BindingFlags.Public | BindingFlags.Instance).Length <= 4)
                                description.Append(",").Append(Quote(property.Name)).Append(":").Append(Quote(value.ToString()));
                        }
                        catch { }
                    }
                    return description.Append("}").ToString();
                }).ToArray();
                if (i > 1) phaseRows.AppendLine(",");
                phaseRows.Append("{\"phase_id\":").Append(i)
                    .Append(",\"name\":").Append(Quote(Convert.ToString(Get(phase, "Name"))))
                    .Append(",\"laue_group\":").Append(Quote(Convert.ToString(Get(phase, "LaueGroup"))))
                    .Append(",\"key_type\":").Append(Quote(key.GetType().FullName))
                    .Append(",\"key_name\":").Append(Quote(Convert.ToString(Get(key, "Name"))))
                    .Append(",\"width\":").Append(Convert.ToInt32(Get(key, "Width")))
                    .Append(",\"height\":").Append(Convert.ToInt32(Get(key, "Height")))
                    .Append(",\"bmp_path\":").Append(Quote(keyBmp))
                    .Append(",\"pixel_count\":").Append(pixelValues.Length)
                    .Append(",\"distinct_pixel_count\":").Append(pixelValues.Distinct().Count())
                    .Append(",\"pixel_sha256\":").Append(Quote(BitConverter.ToString(SHA256.Create().ComputeHash(
                        pixelValues.SelectMany(BitConverter.GetBytes).ToArray())).Replace("-", "")))
                    .Append(",\"outline_point_counts\":[").Append(String.Join(",", outlineRows)).Append("]")
                    .Append(",\"outline_polygons\":[").Append(String.Join(",", outlinePolygons)).Append("]")
                    .Append(",\"annotations\":[").Append(String.Join(",", annotationRows)).Append("]}");
            }
            var json = "{\"status\":\"native_ipf_key_read\",\"gui_started\":false,\"cpr\":" + Quote(cpr)
                + ",\"grid\":" + Quote(Convert.ToInt32(Get(dataset, "XCount")) + "x" + Convert.ToInt32(Get(dataset, "YCount")))
                + ",\"step_x_micron\":" + Convert.ToString(Get(dataset, "StepSizeMicronX"), System.Globalization.CultureInfo.InvariantCulture)
                + ",\"step_y_micron\":" + Convert.ToString(Get(dataset, "StepSizeMicronY"), System.Globalization.CultureInfo.InvariantCulture)
                + ",\"phases\":[" + phaseRows + "]}";
            Directory.CreateDirectory(Path.GetDirectoryName(report));
            File.WriteAllText(report, json, new UTF8Encoding(true));
            Console.WriteLine(json);
            return 0;
        }
        catch (Exception exception)
        {
            while (exception is TargetInvocationException && exception.InnerException != null) exception = exception.InnerException;
            Console.Error.WriteLine(exception.GetType().FullName + ": " + exception.Message + "\n" + exception.StackTrace);
            return 1;
        }
    }
}
