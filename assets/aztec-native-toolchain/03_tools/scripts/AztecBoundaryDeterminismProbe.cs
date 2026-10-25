using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Runtime.InteropServices;

public static class AztecBoundaryDeterminismProbe
{
    private static string Hash(int[] pixels)
    {
        byte[] bytes = new byte[pixels.Length * 4];
        Buffer.BlockCopy(pixels, 0, bytes, 0, bytes.Length);
        using (var sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "");
    }
    private static object Diff(int[] first, int[] next, int width)
    {
        int count = 0;
        var examples = new List<object>();
        for (int i = 0; i < first.Length; i++) if (first[i] != next[i])
        {
            count++;
            if (examples.Count < 64) examples.Add(new { x = i % width, y = i / width,
                first_argb = unchecked((uint)first[i]).ToString("X8"), next_argb = unchecked((uint)next[i]).ToString("X8") });
        }
        return new { differing_pixels = count, examples = examples };
    }
    private static void SaveBmp(string path, int[] pixels, int width, int height)
    {
        // Explicit uncompressed 32-bpp BMP preserves raw ARGB bytes, including alpha.
        using (var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        using (var writer = new BinaryWriter(stream))
        {
            int size = checked(width * height * 4);
            writer.Write((ushort)0x4D42); writer.Write(54 + size); writer.Write(0); writer.Write(54);
            writer.Write(40); writer.Write(width); writer.Write(-height); writer.Write((ushort)1);
            writer.Write((ushort)32); writer.Write(0); writer.Write(size); writer.Write(3780); writer.Write(3780);
            writer.Write(0); writer.Write(0);
            byte[] bytes = new byte[size]; Buffer.BlockCopy(pixels, 0, bytes, 0, size); writer.Write(bytes);
        }
    }
    public static object Run(object map, int mapWidth, int mapHeight, int pixelWidth, int repeats, string output)
    {
        double scale = (double)pixelWidth / mapWidth;
        int height = (int)(mapHeight * scale);
        MethodInfo draw = map.GetType().GetMethod("DrawBoundaries");
        Type pointType = draw.GetParameters()[5].ParameterType;
        Func<double,double,object> point = (x,y) => Activator.CreateInstance(pointType, new object[] { x, y });
        object offset = point(0.5 * scale, 0.5 * scale);
        var rows = new List<object>();
        int[] baseline = null, previous = null, serialBaseline = null;
        for (int run = 1; run <= repeats + 2; run++)
        {
            bool serial = run > repeats;
            int[] pixels = new int[checked(pixelWidth * height)];
            if (serial)
            {
                // Native range is Floor(p0.Y) <= j < Ceiling(p1.Y)+1. Equal integer ends select one row.
                for (int y = 0; y < mapHeight; y++)
                    draw.Invoke(map, new object[] { pixels, pixelWidth, height, scale, point(0,y), point(mapWidth,y), offset });
            }
            else draw.Invoke(map, new object[] { pixels, pixelWidth, height, scale, point(0,0), point(mapWidth,mapHeight), offset });
            string name = serial ? "serial_" + (run - repeats) : "parallel_" + run;
            SaveBmp(Path.Combine(output, name + ".bmp"), pixels, pixelWidth, height);
            rows.Add(new { name = name, raw_argb_sha256 = Hash(pixels),
                versus_first_parallel = baseline == null ? null : Diff(baseline, pixels, pixelWidth),
                versus_previous = previous == null ? null : Diff(previous, pixels, pixelWidth),
                versus_first_serial = serialBaseline == null ? null : Diff(serialBaseline, pixels, pixelWidth) });
            if (baseline == null) baseline = pixels;
            if (serial && serialBaseline == null) serialBaseline = pixels;
            previous = pixels;
        }
        return new { width = pixelWidth, height = height, scale = scale, parallel_repeats = repeats,
            serial_repeats = 2, row_range = "Floor(p0.Y) inclusive; Ceiling(p1.Y)+1 exclusive, clamped to dataset", outputs = rows };
    }
}
