param(
    [string]$FrameworkHost = (Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'),
    [ValidateRange(1000,120000)][int]$TimeoutMilliseconds = 30000
)

$ErrorActionPreference = 'Stop'
if (-not [IO.File]::Exists($FrameworkHost)) { throw "framework_host_missing:$FrameworkHost" }
$probe = '$ProgressPreference="SilentlyContinue";$o=[ordered]@{edition=[string]$PSVersionTable.PSEdition;apartment=[string][Threading.Thread]::CurrentThread.GetApartmentState()};$o|ConvertTo-Json -Compress'
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
$info = [Diagnostics.ProcessStartInfo]::new()
$info.FileName = $FrameworkHost
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
$info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-STA','-EncodedCommand',$encoded)) {
    [void]$info.ArgumentList.Add($argument)
}
$process = [Diagnostics.Process]::new()
try {
    $process.StartInfo = $info
    if (-not $process.Start()) { throw 'framework_probe_start_failed' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutMilliseconds)) {
        try { $process.Kill($true) } catch {}
        throw 'framework_probe_timeout'
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult().Trim()
    $stderr = $stderrTask.GetAwaiter().GetResult().Trim()
    $exit = $process.ExitCode
} finally {
    $process.Dispose()
}
if ($exit -ne 0) { throw "framework_probe_failed:exit=$exit;stderr=$stderr" }
$value = $stdout | ConvertFrom-Json
if ($value.edition -ne 'Desktop' -or $value.apartment -ne 'STA') {
    throw "framework_probe_wrong_thread:edition=$($value.edition);apartment=$($value.apartment)"
}
[pscustomobject]@{
    status = 'passed'
    framework_host = $FrameworkHost
    use_shell_execute = $false
    create_no_window = $true
    edition = $value.edition
    apartment = $value.apartment
    exit_code = $exit
    stderr_empty = [string]::IsNullOrWhiteSpace($stderr)
} | ConvertTo-Json -Compress
