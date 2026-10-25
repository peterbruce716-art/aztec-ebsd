using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;

// The host only validates requests and isolates each native pipeline invocation.
public static class AZtecBmpExporter {
    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 131072 };

    public static int Main(string[] args) {
        try {
            var options = Parse(args);
            if (options.ContainsKey("--help")) { PrintHelp(); return 0; }
            bool batch = options.ContainsKey("--input-dir");
            if (options.ContainsKey("--input") == batch || !options.ContainsKey("--output")) throw new ArgumentException("provide_exactly_one_of_input_or_input_dir_and_output");
            string output = FullLocalPath(options["--output"]);
            if (File.Exists(output) || Directory.Exists(output)) throw new ArgumentException("output_path_must_be_new");
            string[] types = ParseTypes(options.ContainsKey("--types") ? options["--types"] : "ALL");
            int timeout = ParseInt(options, "--timeout-seconds", 300, 10, 900);
            int jobTimeout = ParseInt(options, "--job-timeout-seconds", 1800, 10, 7200);
            string template = ResolveTemplate(options.ContainsKey("--template") ? options["--template"] : "native-v1");
            string expectedCrc = options.ContainsKey("--expected-crc-sha256") ? ValidateHash(options["--expected-crc-sha256"]) : null;
            if (batch) {
                if (expectedCrc != null) throw new ArgumentException("expected_crc_hash_not_supported_for_batch");
                return RunBatch(FullLocalPath(options["--input-dir"]), output, types, timeout, jobTimeout, template);
            }
            string input = FullLocalPath(options["--input"]);
            return RunOne(input, output, types, timeout, jobTimeout, template, expectedCrc);
        } catch (Exception e) {
            Console.Error.WriteLine(e.GetType().Name + ":" + e.Message);
            return 64;
        }
    }

    private static Dictionary<string,string> Parse(string[] args) {
        var options = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        var allowed = new HashSet<string>(new[]{"--input","--input-dir","--output","--types","--timeout-seconds","--job-timeout-seconds","--expected-crc-sha256","--template"},StringComparer.OrdinalIgnoreCase);
        for (int i=0;i<args.Length;i++) {
            if (args[i] == "--help") { options["--help"] = "true"; continue; }
            if (!allowed.Contains(args[i]) || i+1>=args.Length || options.ContainsKey(args[i])) throw new ArgumentException("unknown_duplicate_or_missing_argument:"+args[i]);
            options.Add(args[i],args[++i]);
        }
        return options;
    }

    private static void PrintHelp() {
        Console.WriteLine("AZtecBmpExporter --input <sample.cpr> | --input-dir <directory> --output <new-directory> [--types ALL|IPF,KAM,GOS] [--timeout-seconds 300] [--job-timeout-seconds 1800] [--expected-crc-sha256 HEX] [--template native-v1|frozen-v1|template.json]");
        Console.WriteLine("Batch mode processes top-level CPR files sequentially into one subdirectory per input.");
        Console.WriteLine("JSON template supports optional kam.min/kam.max and gos.min/gos.max display limits.");
        Console.WriteLine("Default native-v1 uses the installed AZtec Crystal MapExport for maps and legends; frozen-v1 reproduces the prior compatible canvas.");
    }

    private static string FullLocalPath(string path) {
        string full = Path.GetFullPath(path);
        if (full.StartsWith(@"\\") || full.IndexOf('"') >= 0) throw new ArgumentException("local_paths_only");
        return full;
    }

    private static string[] ParseTypes(string raw) {
        raw = raw.Trim().ToUpperInvariant();
        string[] input = raw == "ALL" ? new[]{"IPF","KAM","GOS"} : raw.Split(',');
        var types = new List<string>();
        foreach (string item in input) {
            string type = item.Trim().ToUpperInvariant();
            if (type != "IPF" && type != "KAM" && type != "GOS") throw new ArgumentException("unsupported_image_type:"+type);
            if (!types.Contains(type)) types.Add(type);
        }
        if (types.Count == 0) throw new ArgumentException("image_types_required");
        return types.ToArray();
    }

    private static int ParseInt(Dictionary<string,string> options, string name, int fallback, int min, int max) {
        int value;
        if (!options.ContainsKey(name)) return fallback;
        if (!Int32.TryParse(options[name], out value) || value < min || value > max) throw new ArgumentException("invalid_"+name.TrimStart('-'));
        return value;
    }

    private static string ValidateHash(string hash) {
        if (!System.Text.RegularExpressions.Regex.IsMatch(hash,"\\A[0-9a-fA-F]{64}\\z")) throw new ArgumentException("invalid_crc_hash");
        return hash;
    }

    private static string ResolveTemplate(string value) {
        if (value == "frozen-v1" || value == "native-v1") return value;
        string path = FullLocalPath(value);
        if (!File.Exists(path)) throw new ArgumentException("template_not_found");
        using (var reader = new StreamReader(path, true)) {
            object parsed = Json.DeserializeObject(reader.ReadToEnd());
            if (!(parsed is Dictionary<string,object>)) throw new ArgumentException("invalid_template_json");
        }
        return path;
    }

    private static int RunBatch(string inputDirectory, string outputDirectory, string[] types, int timeout, int jobTimeout, string template) {
        if (!Directory.Exists(inputDirectory)) throw new ArgumentException("input_directory_not_found");
        var inputs = new List<string>(Directory.GetFiles(inputDirectory, "*.cpr", SearchOption.TopDirectoryOnly));
        inputs.Sort(StringComparer.OrdinalIgnoreCase);
        if (inputs.Count == 0) throw new ArgumentException("no_cpr_files_found");
        Directory.CreateDirectory(outputDirectory);
        string manifestPath = Path.Combine(outputDirectory, "batch_manifest.json");
        string logPath = Path.Combine(outputDirectory, "render.log");
        var results = new List<object>();
        int success = 0, partial = 0, failed = 0;
        WriteBatchManifest(manifestPath, "running", inputs.Count, results);
        foreach (string input in inputs) {
            string sampleOutput = Path.Combine(outputDirectory, Path.GetFileNameWithoutExtension(input));
            int exitCode;
            if (Directory.Exists(sampleOutput) || File.Exists(sampleOutput)) {
                exitCode = 64;
                results.Add(new { input = input, output = sampleOutput, status = "failed", exit_code = exitCode, error = "sample_output_path_exists" });
            } else {
                exitCode = RunOne(input, sampleOutput, types, timeout, jobTimeout, template, null);
                string status = exitCode == 0 ? "completed" : exitCode == 2 ? "partial_failed" : "failed";
                results.Add(new { input = input, output = sampleOutput, status = status, exit_code = exitCode, manifest = Path.Combine(sampleOutput, "render_manifest.json") });
            }
            if (exitCode == 0) success++; else if (exitCode == 2) partial++; else failed++;
            File.AppendAllText(logPath, DateTime.UtcNow.ToString("o") + " " + Path.GetFileName(input) + " " + (exitCode == 0 ? "completed" : exitCode == 2 ? "partial_failed" : "failed") + " exit=" + exitCode + Environment.NewLine, new UTF8Encoding(true));
            WriteBatchManifest(manifestPath, "running", inputs.Count, results);
        }
        string finalStatus = failed == 0 && partial == 0 ? "completed" : success + partial > 0 ? "partial_failed" : "failed";
        WriteBatchManifest(manifestPath, finalStatus, inputs.Count, results);
        return finalStatus == "completed" ? 0 : finalStatus == "partial_failed" ? 2 : 1;
    }

    private static void WriteBatchManifest(string path, string status, int count, List<object> results) {
        var value = new { schema_version = 1, status = status, total_inputs = count, completed = CountStatus(results, "completed"), partial_failed = CountStatus(results, "partial_failed"), failed = CountStatus(results, "failed"), samples = results };
        File.WriteAllText(path, Json.Serialize(value), new UTF8Encoding(true));
    }

    private static int CountStatus(List<object> rows, string status) {
        int count = 0;
        foreach (object row in rows) {
            object value = row.GetType().GetProperty("status").GetValue(row, null);
            if ((string)value == status) count++;
        }
        return count;
    }

    private static int RunOne(string input, string output, string[] types, int timeout, int jobTimeout, string template, string expectedCrc) {
        string temp = null;
        try {
            var request = new Dictionary<string,object>{{"input",input},{"output",output},{"types",types},{"timeout_seconds",timeout},{"job_timeout_seconds",jobTimeout},{"template",template}};
            if (expectedCrc != null) request.Add("expected_crc_sha256",expectedCrc);
            temp = Path.Combine(Path.GetTempPath(), "aztec_export_" + Guid.NewGuid().ToString("N") + ".json");
            File.WriteAllText(temp, Json.Serialize(request), new UTF8Encoding(true));
            string script = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "export.ps1");
            string payload = Convert.ToBase64String(Encoding.UTF8.GetBytes(Json.Serialize(new { script = script, request = temp })));
            string code = "$p=([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + payload + "'))|ConvertFrom-Json); & $p.script -RequestPath $p.request; exit $LASTEXITCODE";
            var start = new ProcessStartInfo(@"C:\Program Files\PowerShell\7\pwsh.exe", "-NoProfile -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(code))) { UseShellExecute = false, CreateNoWindow = true };
            using (var process = Process.Start(start)) {
                if (!process.WaitForExit(jobTimeout * 1000)) {
                    using (var killer = Process.Start(new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "taskkill.exe"), "/PID " + process.Id + " /T /F") { UseShellExecute = false, CreateNoWindow = true })) killer.WaitForExit(10000);
                    Console.Error.WriteLine("job_total_timeout:" + input);
                    return 124;
                }
                return process.ExitCode;
            }
        } catch (Exception e) {
            Console.Error.WriteLine("sample_failed:" + input + ":" + e.GetType().Name + ":" + e.Message);
            return 1;
        } finally { if (temp != null && File.Exists(temp)) File.Delete(temp); }
    }
}
