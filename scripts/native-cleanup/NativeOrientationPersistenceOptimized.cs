using System;
using System.IO;
using System.Security.Cryptography;
using Core.Ebsd.Infrastructure;
using Core.Ebsd.Geometry;
using Core.Ebsd.DataSpaces;

// Persistence adapter only. The native clean-up result must be snapshotted
// separately before this conversion; independent reopened-data comparison stays exact.
public static class NativeOrientationPersistence
{
    public sealed class Report
    {
        public string Operation, PersistencePolicy, PrecisionReference;
        public bool EulerBytesPreserved;
        public int Points, PhaseZeroPoints, ChangedEulerPoints, ChangedQuaternionPoints, QuaternionSignFlips;
        public double ComponentLimit = 1e-5;
        public double MaxSignAlignedComponentDifference, MaxRawComponentDifference;
        public double MaxFilteredToSavedSignAlignedComponentDifference, MaxFilteredToSavedRawComponentDifference;
        public double MaxQuaternionNormErrorBefore, MaxQuaternionNormErrorAfter, MaxEulerDifferenceRadians;
        public string OrientationEulerSha256Before, OrientationEulerSha256After;
        public string EulerSha256Before, EulerSha256After;
    }

    static bool Finite(double v) { return !Double.IsNaN(v) && !Double.IsInfinity(v); }
    static float[] Components(FourFloats v) { return new[] { v.X1, v.X2, v.X3, v.X4 }; }
    static bool Same(float a, float b) { return BitConverter.ToInt32(BitConverter.GetBytes(a), 0) == BitConverter.ToInt32(BitConverter.GetBytes(b), 0); }
    static string Hash(RawData data)
    {
        using (var stream = new MemoryStream())
        using (var writer = new BinaryWriter(stream))
        using (var sha = SHA256.Create())
        {
            writer.Write(data.PixelCount);
            for (int i = 0; i < data.PixelCount; i++)
            {
                foreach (float value in Components(data.Orientation.GetItem(i))) writer.Write(value);
                writer.Write(data.Euler1.GetItem(i)); writer.Write(data.Euler2.GetItem(i)); writer.Write(data.Euler3.GetItem(i));
            }
            writer.Flush();
            return BitConverter.ToString(sha.ComputeHash(stream.ToArray())).Replace("-", "");
        }
    }

    static string EulerHash(RawData data)
    {
        using (var stream = new MemoryStream())
        using (var writer = new BinaryWriter(stream))
        using (var sha = SHA256.Create())
        {
            writer.Write(data.PixelCount);
            for (int i = 0; i < data.PixelCount; i++)
            {
                writer.Write(data.Euler1.GetItem(i)); writer.Write(data.Euler2.GetItem(i)); writer.Write(data.Euler3.GetItem(i));
            }
            writer.Flush();
            return BitConverter.ToString(sha.ComputeHash(stream.ToArray())).Replace("-", "");
        }
    }

    public static Report Canonicalize(IDataset dataset, string persistencePolicy)
    {
        if (dataset == null) throw new ArgumentNullException("dataset");
        RawData data = dataset.Data;
        if (persistencePolicy != "NativeSave" && persistencePolicy != "FilteredQuaternion") throw new ArgumentException("unsupported_persistence_policy");
        bool filtered = persistencePolicy == "FilteredQuaternion";
        var report = new Report {
            Points = data.PixelCount, PersistencePolicy = persistencePolicy,
            Operation = filtered ? "native_unit_quaternion_to_single_euler_then_rawdata_updatedata" : "native_single_euler_preserved_then_rawdata_updatedata",
            PrecisionReference = filtered ? "native_filtered_quaternion" : "native_serialized_single_euler_prediction",
            OrientationEulerSha256Before = Hash(data), EulerSha256Before = EulerHash(data)
        };
        var e1 = new float[report.Points]; var e2 = new float[report.Points]; var e3 = new float[report.Points];
        var expected = new FourFloats[report.Points]; var before = new FourFloats[report.Points];
        // Complete the numerical audit before changing any field. Phase zero is
        // included because RawData.UpdateData rebuilds quaternions for every point.
        for (int i = 0; i < report.Points; i++)
        {
            if (data.PhaseID.GetItem(i) == 0) report.PhaseZeroPoints++;
            before[i] = data.Orientation.GetItem(i);
            float[] original = Components(before[i]);
            foreach (float value in original) if (!Finite(value)) throw new InvalidDataException("persistence_nonfinite_quaternion:" + i);
            if (filtered)
            {
                // Native ToEuler assumes a unit quaternion. Normalize its double
                // copy to avoid Single rounding amplification near Euler poles.
                Quaternion unitQuaternion = before[i].ToQuaternion();
                unitQuaternion.Normalize();
                Euler euler = unitQuaternion.ToEuler();
                e1[i] = (float)euler.E1Rad; e2[i] = (float)euler.E2Rad; e3[i] = (float)euler.E3Rad;
            }
            else
            {
                // Match SaveProjectAs: retain native Euler fields, which may
                // differ from the temporary Kuwahara quaternion result.
                e1[i] = data.Euler1.GetItem(i); e2[i] = data.Euler2.GetItem(i); e3[i] = data.Euler3.GetItem(i);
            }
            if (!Finite(e1[i]) || !Finite(e2[i]) || !Finite(e3[i])) throw new InvalidDataException("persistence_nonfinite_euler:" + i);
            expected[i] = new FourFloats(new Euler(e1[i], e2[i], e3[i]).ToQuaternion());
            float[] canonical = Components(expected[i]);
            double dot = 0, normBefore = 0, normAfter = 0;
            for (int j = 0; j < 4; j++)
            {
                if (!Finite(canonical[j])) throw new InvalidDataException("persistence_nonfinite_roundtrip:" + i);
                dot += (double)original[j] * canonical[j];
                normBefore += (double)original[j] * original[j]; normAfter += (double)canonical[j] * canonical[j];
            }
            double sign = dot < 0 ? -1 : 1;
            if (sign < 0) report.QuaternionSignFlips++;
            report.MaxQuaternionNormErrorBefore = Math.Max(report.MaxQuaternionNormErrorBefore, Math.Abs(Math.Sqrt(normBefore) - 1));
            report.MaxQuaternionNormErrorAfter = Math.Max(report.MaxQuaternionNormErrorAfter, Math.Abs(Math.Sqrt(normAfter) - 1));
            for (int j = 0; j < 4; j++)
            {
                double difference = Math.Abs(original[j] - sign * canonical[j]);
                report.MaxFilteredToSavedSignAlignedComponentDifference = Math.Max(report.MaxFilteredToSavedSignAlignedComponentDifference, difference);
                report.MaxFilteredToSavedRawComponentDifference = Math.Max(report.MaxFilteredToSavedRawComponentDifference, Math.Abs((double)original[j] - canonical[j]));
                if (filtered)
                {
                    report.MaxSignAlignedComponentDifference = Math.Max(report.MaxSignAlignedComponentDifference, difference);
                    report.MaxRawComponentDifference = Math.Max(report.MaxRawComponentDifference, Math.Abs((double)original[j] - canonical[j]));
                    if (difference > report.ComponentLimit) throw new InvalidDataException("persistence_roundtrip_component_limit:index=" + i + ";component=" + j + ";difference=" + difference.ToString("R", System.Globalization.CultureInfo.InvariantCulture));
                }
            }
            float[] previousEuler = { data.Euler1.GetItem(i), data.Euler2.GetItem(i), data.Euler3.GetItem(i) };
            float[] convertedEuler = { e1[i], e2[i], e3[i] };
            bool changedEuler = false;
            for (int j = 0; j < 3; j++)
            {
                if (!Finite(previousEuler[j])) throw new InvalidDataException("persistence_nonfinite_previous_euler:" + i);
                changedEuler |= !Same(previousEuler[j], convertedEuler[j]);
                report.MaxEulerDifferenceRadians = Math.Max(report.MaxEulerDifferenceRadians, Math.Abs((double)previousEuler[j] - convertedEuler[j]));
            }
            if (changedEuler) report.ChangedEulerPoints++;
        }
        if (filtered) for (int i = 0; i < report.Points; i++)
        {
            data.Euler1.SetItem(i, e1[i]); data.Euler2.SetItem(i, e2[i]); data.Euler3.SetItem(i, e3[i]);
        }
        // Native #CTe rebuilds FourFloats(Euler(single,single,single).ToQuaternion()).
        data.UpdateData();
        for (int i = 0; i < report.Points; i++)
        {
            float[] actual = Components(data.Orientation.GetItem(i));
            float[] canonical = Components(expected[i]); float[] original = Components(before[i]);
            bool changed = false;
            for (int j = 0; j < 4; j++)
            {
                if (!Finite(actual[j]) || !Same(actual[j], canonical[j])) throw new InvalidDataException("persistence_native_canonicalization_mismatch:" + i + ":" + j);
                if (!filtered)
                {
                    double difference = Math.Abs((double)actual[j] - canonical[j]);
                    report.MaxSignAlignedComponentDifference = Math.Max(report.MaxSignAlignedComponentDifference, difference);
                    report.MaxRawComponentDifference = Math.Max(report.MaxRawComponentDifference, difference);
                    if (difference > report.ComponentLimit) throw new InvalidDataException("persistence_euler_prediction_component_limit:" + i + ":" + j);
                }
                changed |= !Same(actual[j], original[j]);
            }
            if (changed) report.ChangedQuaternionPoints++;
        }
        report.OrientationEulerSha256After = Hash(data);
        report.EulerSha256After = EulerHash(data);
        report.EulerBytesPreserved = report.EulerSha256Before == report.EulerSha256After;
        if (!filtered && (!report.EulerBytesPreserved || report.ChangedEulerPoints != 0)) throw new InvalidDataException("persistence_changed_native_euler_bytes");
        return report;
    }
}
