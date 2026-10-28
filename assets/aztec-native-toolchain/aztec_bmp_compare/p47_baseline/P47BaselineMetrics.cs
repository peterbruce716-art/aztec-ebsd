using System;
using System.IO;

namespace AztecP47
{
    public sealed class Metric
    {
        public string Region;
        public long Pixels, ExactPixels, AbsoluteChannelError, SquaredChannelError;
        public double ExactFraction, Mae, Rmse;
        public int MaxChannelError;
    }

    public static class BaselineMetrics
    {
        sealed class Bmp
        {
            public byte[] Bytes;
            public int Width, Height, Stride, Offset, PixelBytes;
            public bool TopDown;
            public int At(int x, int y) { return checked(Offset + (TopDown ? y : Height - 1 - y) * Stride + x * PixelBytes); }
        }

        static Bmp Read(string path)
        {
            byte[] b = File.ReadAllBytes(path);
            if (b.Length < 54 || b[0] != 66 || b[1] != 77) throw new InvalidDataException("invalid_bmp:" + path);
            uint header = BitConverter.ToUInt32(b, 14), offset = BitConverter.ToUInt32(b, 10);
            int w = BitConverter.ToInt32(b, 18), signedHeight = BitConverter.ToInt32(b, 22);
            int bits = BitConverter.ToUInt16(b, 28);
            if (header < 40 || offset < 14L + header || w < 1 || signedHeight == 0 || signedHeight == Int32.MinValue
                || BitConverter.ToUInt16(b, 26) != 1 || (bits != 24 && bits != 32) || BitConverter.ToUInt32(b, 30) != 0)
                throw new InvalidDataException("unsupported_bmp:" + path);
            long stride = ((long)w * bits + 31) / 32 * 4;
            int h = Math.Abs(signedHeight);
            if (stride > Int32.MaxValue || offset > Int32.MaxValue || offset + stride * h > b.LongLength)
                throw new InvalidDataException("truncated_bmp:" + path);
            return new Bmp { Bytes = b, Width = w, Height = h, Stride = (int)stride, Offset = (int)offset,
                PixelBytes = bits / 8, TopDown = signedHeight < 0 };
        }

        static void Add(Metric m, int r, int g, int b)
        {
            m.Pixels++;
            m.AbsoluteChannelError += r + g + b;
            m.SquaredChannelError += (long)r * r + (long)g * g + (long)b * b;
            int e = Math.Max(r, Math.Max(g, b));
            if (e == 0) m.ExactPixels++;
            if (e > m.MaxChannelError) m.MaxChannelError = e;
        }

        public static Metric[] Compare(string generated, string reference, int x, int y, int w, int h)
        {
            Bmp a = Read(generated), b = Read(reference);
            if (a.Width != b.Width || a.Height != b.Height) throw new InvalidDataException("dimensions_differ");
            if (x < 0 || y < 0 || w < 1 || h < 1 || (long)x + w > a.Width || (long)y + h > a.Height)
                throw new ArgumentException("invalid_roi");
            var full = new Metric { Region = "full_canvas" };
            var roi = new Metric { Region = "map_viewport" };
            var outside = new Metric { Region = "outside_map" };
            for (int yy = 0; yy < a.Height; yy++)
            {
                int p = a.At(0, yy), q = b.At(0, yy);
                for (int xx = 0; xx < a.Width; xx++, p += a.PixelBytes, q += b.PixelBytes)
                {
                    int r = Math.Abs(a.Bytes[p + 2] - b.Bytes[q + 2]);
                    int g = Math.Abs(a.Bytes[p + 1] - b.Bytes[q + 1]);
                    int blue = Math.Abs(a.Bytes[p] - b.Bytes[q]);
                    Add(full, r, g, blue);
                    Add(xx >= x && xx < x + w && yy >= y && yy < y + h ? roi : outside, r, g, blue);
                }
            }
            Metric[] result = { full, roi, outside };
            foreach (Metric m in result)
            {
                // A full-canvas ROI has no outside pixels. Preserve the
                // three-region contract with finite metrics for empty regions.
                // Consumers must check Pixels == 0 before interpreting them.
                if (m.Pixels == 0)
                {
                    m.ExactFraction = 1.0;
                    m.Mae = 0.0;
                    m.Rmse = 0.0;
                    continue;
                }
                m.ExactFraction = (double)m.ExactPixels / m.Pixels;
                m.Mae = m.AbsoluteChannelError / (3.0 * m.Pixels);
                m.Rmse = Math.Sqrt(m.SquaredChannelError / (3.0 * m.Pixels));
            }
            return result;
        }
    }
}
