using System;
using System.IO;
using System.Collections.Generic;
using System.Reflection;
using System.Security.Cryptography;

// Read-only audit helper. All cleaning is performed by AZtec's native steps.
public sealed class NativeCleanupSnapshot
{
    public int Count;
    public Dictionary<string, byte[]> Fields = new Dictionary<string, byte[]>();
    static readonly string[] Names = { "PhaseID", "Euler1", "Euler2", "Euler3", "MAD", "Q1", "Q2", "Q3", "Q4", "ErrorCode", "BandContrast", "BandSlope", "NumberOfBands" };
    static bool FloatField(string name) { return name.StartsWith("Euler") || name.StartsWith("Q") || name == "MAD"; }
    static object Get(object obj, string name) { return obj.GetType().GetProperty(name).GetValue(obj, null); }
    public static NativeCleanupSnapshot Capture(object dataset)
    {
        var result = new NativeCleanupSnapshot();
        result.Count = Convert.ToInt32(Get(dataset, "PixelCount"));
        foreach (var name in Names)
        {
            var nativeName = name.StartsWith("Q") ? "Orientation" : name;
            var prop = dataset.GetType().GetProperty(nativeName);
            if (prop == null) prop = Get(dataset, "Data").GetType().GetProperty(nativeName);
            var owner = dataset.GetType().GetProperty(nativeName) != null ? dataset : Get(dataset, "Data");
            var space = prop.GetValue(owner, null);
            var get = space.GetType().GetMethod("GetItem", new[] { typeof(int) });
            using (var stream = new MemoryStream())
            using (var writer = new BinaryWriter(stream))
            {
                for (int i = 0; i < result.Count; i++)
                {
                    var value = get.Invoke(space, new object[] { i });
                    if (name.StartsWith("Q")) value = Get(value, "X" + name.Substring(1));
                    if (FloatField(name)) writer.Write(Convert.ToSingle(value));
                    else writer.Write(Convert.ToByte(value));
                }
                result.Fields.Add(name, stream.ToArray());
            }
        }
        return result;
    }
    public string Hash(bool qualityOnly)
    {
        using (var stream = new MemoryStream())
        using (var writer = new BinaryWriter(stream))
        using (var sha = SHA256.Create())
        {
            writer.Write(Count);
            foreach (var name in Names)
            {
                if (qualityOnly && name != "BandContrast" && name != "BandSlope" && name != "NumberOfBands") continue;
                writer.Write(name); writer.Write(Fields[name].Length); writer.Write(Fields[name]);
            }
            writer.Flush();
            return BitConverter.ToString(sha.ComputeHash(stream.ToArray())).Replace("-", "");
        }
    }
    public void Save(string path)
    {
        using (var writer = new BinaryWriter(File.Open(path, FileMode.CreateNew)))
        {
            writer.Write("AZTEC_NATIVE_AUDIT_V1"); writer.Write(Count);
            foreach (var name in Names) { writer.Write(name); writer.Write(Fields[name].Length); writer.Write(Fields[name]); }
        }
    }
    public static NativeCleanupSnapshot Load(string path)
    {
        using (var reader = new BinaryReader(File.OpenRead(path)))
        {
            if (reader.ReadString() != "AZTEC_NATIVE_AUDIT_V1") throw new InvalidDataException("snapshot_header");
            var result = new NativeCleanupSnapshot(); result.Count = reader.ReadInt32();
            if (result.Count <= 0) throw new InvalidDataException("snapshot_count");
            foreach (var name in Names)
            {
                if (reader.ReadString() != name) throw new InvalidDataException("snapshot_field");
                int length = reader.ReadInt32();
                if (length != checked(result.Count * (FloatField(name) ? 4 : 1))) throw new InvalidDataException("snapshot_length");
                var bytes = reader.ReadBytes(length);
                if (bytes.Length != length) throw new EndOfStreamException();
                result.Fields.Add(name, bytes);
            }
            if (reader.BaseStream.Position != reader.BaseStream.Length) throw new InvalidDataException("snapshot_trailing_data");
            return result;
        }
    }
    public int ChangedPoints(NativeCleanupSnapshot other, string maskPath)
    {
        if (Count != other.Count) throw new InvalidDataException("point_count_changed");
        var mask = new byte[Count]; int changed = 0;
        for (int i = 0; i < Count; i++)
        {
            foreach (var name in Names)
            {
                int size = FloatField(name) ? 4 : 1;
                for (int j = 0; j < size; j++) if (Fields[name][size * i + j] != other.Fields[name][size * i + j]) mask[i] |= 1;
            }
            if (Fields["PhaseID"][i] == 0 && other.Fields["PhaseID"][i] > 0) mask[i] |= 2;
            if (mask[i] != 0) changed++;
        }
        if (!String.IsNullOrEmpty(maskPath)) { using (var output = File.Open(maskPath, FileMode.CreateNew)) output.Write(mask, 0, mask.Length); }
        return changed;
    }
    public string Compare(NativeCleanupSnapshot other)
    {
        if (Count != other.Count) return "point_count";
        foreach (var name in Names)
        {
            var a = Fields[name]; var b = other.Fields[name];
            for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) return name + ":byte:" + i;
        }
        return "";
    }
    public string CompareOrientations(NativeCleanupSnapshot other)
    {
        if (Count != other.Count) return "point_count";
        foreach (var name in new [] { "PhaseID", "Euler1", "Euler2", "Euler3", "MAD", "Q1", "Q2", "Q3", "Q4" })
        {
            var a = Fields[name]; var b = other.Fields[name];
            for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) return name + ":byte:" + i;
        }
        return "";
    }
}
