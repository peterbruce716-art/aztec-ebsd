using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Collections;
using System.Web.Script.Serialization;

namespace AZtecBmpExporter {
    public sealed class ExportResult {
        public int ExitCode { get; internal set; }
        public string Status { get; internal set; }
        public string ManifestPath { get; internal set; }
        public string LogPath { get; internal set; }
        public string ValidationLevel { get; internal set; }
        public Dictionary<string, object> Manifest { get; internal set; }
        public Dictionary<string, string> ImageStatuses { get; internal set; }
        public Dictionary<string, string> ImagePaths { get; internal set; }
        public Dictionary<string, string> ImageErrors { get; internal set; }
    }

    public static class AZtecBmpApi {
        public static ExportResult Export(string inputPath, string outputDirectory, string imageTypes, string template = "native-v1") {
            var options = new Dictionary<string, object>();
            options["template"] = template;
            return Export(inputPath, outputDirectory, imageTypes, options);
        }

        public static ExportResult Export(string inputPath, string outputDirectory, string imageTypes, IDictionary<string, object> options) {
            if (String.IsNullOrWhiteSpace(inputPath)) throw new ArgumentException("input_path_required", "inputPath");
            if (String.IsNullOrWhiteSpace(outputDirectory)) throw new ArgumentException("output_directory_required", "outputDirectory");
            options = options ?? new Dictionary<string, object>();
            string apiDirectory = Path.GetDirectoryName(typeof(AZtecBmpApi).Assembly.Location);
            string exe = Path.Combine(apiDirectory, "AZtecBmpExporter.exe");
            if (!File.Exists(exe)) throw new FileNotFoundException("AZtecBmpExporter.exe must be beside AZtecBmpExporter.dll", exe);
            string manifest = Path.Combine(Path.GetFullPath(outputDirectory), "render_manifest.json");
            string input = Path.GetFullPath(inputPath);
            string output = Path.GetFullPath(outputDirectory);
            if (Directory.Exists(output) || File.Exists(output)) throw new ArgumentException("output_path_must_be_new", "outputDirectory");
            string types = String.IsNullOrWhiteSpace(imageTypes) ? "ALL" : imageTypes;
            var start = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = apiDirectory };
            var arguments = new List<string> { "--input", input, "--output", output, "--types", types };
            AddOption(arguments, options, "template", "--template", "native-v1");
            AddOption(arguments, options, "timeout_seconds", "--timeout-seconds", null);
            AddOption(arguments, options, "job_timeout_seconds", "--job-timeout-seconds", null);
            AddOption(arguments, options, "expected_crc_sha256", "--expected-crc-sha256", null);
            var quoted = new List<string>();
            foreach (string value in arguments) quoted.Add(Quote(value));
            start.Arguments = String.Join(" ", quoted.ToArray());
            int exitCode;
            int jobTimeoutSeconds = ReadIntOption(options, "job_timeout_seconds", 1800, 10, 7200);
            bool timedOut = false;
            using (var process = Process.Start(start)) {
                if (process == null) throw new InvalidOperationException("exporter_process_start_failed");
                if (!process.WaitForExit(jobTimeoutSeconds * 1000)) {
                    KillProcessTree(process.Id);
                    timedOut = true;
                    exitCode = 124;
                } else {
                    exitCode = process.ExitCode;
                }
            }
            var result = new ExportResult {
                ExitCode = exitCode,
                Status = exitCode == 0 ? "completed" : exitCode == 2 ? "partial_failed" : "failed",
                ManifestPath = manifest,
                LogPath = Path.Combine(Path.GetFullPath(outputDirectory), "render.log"),
                ValidationLevel = "compatible_canvas; NativeFullMapFidelity=not_accepted",
                ImageStatuses = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase),
                ImagePaths = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase),
                ImageErrors = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            };
            if ((exitCode == 0 || exitCode == 1 || exitCode == 2 || exitCode == 124) && File.Exists(manifest)) {
                var serializer = new JavaScriptSerializer { MaxJsonLength = 131072 };
                result.Manifest = serializer.Deserialize<Dictionary<string, object>>(File.ReadAllText(manifest));
                object outputs;
                if (result.Manifest.TryGetValue("outputs", out outputs)) {
                    var outputItems = outputs as IEnumerable;
                    if (outputItems == null) outputItems = new object[0];
                    foreach (object item in outputItems) {
                        var row = item as Dictionary<string, object>;
                        if (row == null || !row.ContainsKey("type")) continue;
                        string type = Convert.ToString(row["type"]);
                        result.ImageStatuses[type] = row.ContainsKey("status") ? Convert.ToString(row["status"]) : "unknown";
                        if (row.ContainsKey("path")) result.ImagePaths[type] = Convert.ToString(row["path"]);
                        if (row.ContainsKey("error")) result.ImageErrors[type] = Convert.ToString(row["error"]);
                    }
                }
                object fidelity;
                if (result.Manifest.TryGetValue("NativeFullMapFidelity", out fidelity))
                    result.ValidationLevel = Convert.ToString(result.Manifest.ContainsKey("renderer") ? result.Manifest["renderer"] : "unknown") + "; NativeFullMapFidelity=" + Convert.ToString(fidelity);
            }
            if (timedOut) result.ImageErrors["process"] = "job_total_timeout";
            return result;
        }

        private static int ReadIntOption(IDictionary<string, object> options, string key, int fallback, int minimum, int maximum) {
            object raw;
            if (!options.TryGetValue(key, out raw) || raw == null) return fallback;
            int value;
            try { value = Convert.ToInt32(raw, System.Globalization.CultureInfo.InvariantCulture); }
            catch (Exception e) { throw new ArgumentException("invalid_" + key, e); }
            if (value < minimum || value > maximum) throw new ArgumentException("invalid_" + key);
            return value;
        }

        private static void KillProcessTree(int processId) {
            string taskkill = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "taskkill.exe");
            using (var killer = Process.Start(new ProcessStartInfo(taskkill, "/PID " + processId + " /T /F") { UseShellExecute = false, CreateNoWindow = true })) {
                if (killer != null) killer.WaitForExit(10000);
            }
        }

        private static void AddOption(List<string> arguments, IDictionary<string, object> options, string key, string cliName, string fallback) {
            object value;
            if (!options.TryGetValue(key, out value) || value == null) {
                if (fallback == null) return;
                value = fallback;
            }
            arguments.Add(cliName); arguments.Add(Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture));
        }

        private static string Quote(string value) {
            if (value == null) return "\"\"";
            var quoted = new System.Text.StringBuilder("\"");
            int slashes = 0;
            foreach (char ch in value) {
                if (ch == '\\') { slashes++; continue; }
                if (ch == '"') { quoted.Append('\\', slashes * 2 + 1); quoted.Append('"'); slashes = 0; continue; }
                quoted.Append('\\', slashes); quoted.Append(ch); slashes = 0;
            }
            quoted.Append('\\', slashes * 2); quoted.Append('"');
            return quoted.ToString();
        }
    }
}
