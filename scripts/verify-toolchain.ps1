param([switch]$SkipEnvironment)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Core') { throw 'requires_powershell_core' }
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$bundle = Join-Path $root 'assets/aztec-native-toolchain'
$strict = [Text.UTF8Encoding]::new($false, $true)
$sourceCheck = (& (Join-Path $PSScriptRoot 'verify-source.ps1') | ConvertFrom-Json)
if ($sourceCheck.status -ne 'passed') { throw 'source_verification_failed' }
$source = $strict.GetString([IO.File]::ReadAllBytes((Join-Path $root 'source-manifest.json'))).TrimStart([char]0xFEFF) | ConvertFrom-Json
function VerifyManifest([string]$base, [string]$relativeManifest, [string[]]$expected) {
    $manifest = $strict.GetString([IO.File]::ReadAllBytes((Join-Path $base $relativeManifest))).TrimStart([char]0xFEFF) | ConvertFrom-Json
    if ($manifest.schema_version -ne 1 -or $manifest.files -isnot [array] -or
        $manifest.file_count -ne $expected.Count -or @($manifest.files).Count -ne $expected.Count) { throw 'invalid_runtime_manifest' }
    $remaining = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($relative in $expected) { [void]$remaining.Add($relative) }
    foreach ($entry in $manifest.files) {
        $relative = [string]$entry.relative_path
        if (-not $remaining.Remove($relative)) { throw 'unexpected_or_duplicate_runtime_path' }
        $path = Join-Path $base $relative
        if ([string]$entry.sha256 -notmatch '\A[0-9a-fA-F]{64}\z' -or
            [string]$entry.bytes -notmatch '\A(?:0|[1-9][0-9]*)\z' -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.sha256 -or
            ([IO.FileInfo]::new($path)).Length -ne $entry.bytes) { throw ('runtime_file_changed:' + $relative) }
    }
    if ($remaining.Count -ne 0) { throw 'runtime_manifest_incomplete' }
    $manifest
}
$prefix = 'assets/aztec-native-toolchain/'
$binaries = @('03_tools/aztec_exporter/AZtecBmpExporter.exe', '03_tools/aztec_exporter/AZtecBmpExporter.dll',
    '03_tools/scripts/AztecNativeIpfConsole.exe', '03_tools/scripts/AztecNativeIpfKeyProbeNoDispose.exe')
$bundleExpected = @($source.files | Where-Object { $_.relative_path.StartsWith($prefix) } | ForEach-Object { $_.relative_path.Substring($prefix.Length) }) + $binaries
$runtimeExpected = @($source.files | Where-Object { -not $_.relative_path.StartsWith($prefix) } | ForEach-Object { $_.relative_path }) + @('source-manifest.json', 'assets/aztec-native-toolchain/toolchain-manifest.json')
$bundleManifest = VerifyManifest $bundle 'toolchain-manifest.json' $bundleExpected
$runtimeManifest = VerifyManifest $root 'runtime-manifest.json' $runtimeExpected
$exe = Join-Path $bundle $binaries[0]
$help = @(& $exe --help)
if ($LASTEXITCODE -ne 0 -or -not ($help -match 'AZtecBmpExporter --input')) { throw 'exporter_help_failed' }
$environment = [ordered]@{ checked=(-not $SkipEnvironment); exporter_help_passed=$true }
if (-not $SkipEnvironment) {
    $aztec = 'C:\Program Files\Oxford Instruments NanoAnalysis\AZtec'
    $framework = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
    foreach ($path in @($framework, (Join-Path $aztec 'core.ebsd.dll'), (Join-Path $aztec 'AZtecCrystal.exe'))) {
        if (-not [IO.File]::Exists($path)) { throw ('required_runtime_missing:' + $path) }
    }
    $environment.aztec_version = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $aztec 'AZtecCrystal.exe')).FileVersion
    if ($environment.aztec_version -ne $bundleManifest.validated_aztec_version) { throw 'unvalidated_aztec_version' }
    if ([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() -ne 'X64') { throw 'requires_x64_host' }
}
[pscustomobject]@{ status='passed'; source_files_verified=$sourceCheck.source_files_verified; files_verified=$bundleManifest.file_count;
    runtime_files_verified=$runtimeManifest.file_count; environment=$environment; native_dataset_validation='not_run'; NativeFullMapFidelity='not_accepted' } | ConvertTo-Json -Depth 5
