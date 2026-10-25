param([switch]$SkipEnvironment)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Core'){throw 'requires_powershell_core'}
$skillRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$bundleRoot=[IO.Path]::GetFullPath((Join-Path $skillRoot 'assets/aztec-native-toolchain'))
$strict=[Text.UTF8Encoding]::new($false,$true)
function VerifyManifest([string]$Root,[string]$ManifestPath,[string[]]$Required,[string]$Label){
    if(-not [IO.File]::Exists($ManifestPath)){throw ($Label+'_manifest_missing')}
    $value=[IO.File]::ReadAllText($ManifestPath,$strict)|ConvertFrom-Json
    if($null -eq $value -or $value.schema_version -ne 1 -or
       $value.files -isnot [array] -or @($value.files).Count -eq 0 -or
       [string]$value.file_count -notmatch '\A[1-9][0-9]*\z' -or
       @($value.files).Count -ne $value.file_count){throw ('invalid_'+$Label+'_manifest')}
    $prefix=$Root+[IO.Path]::DirectorySeparatorChar
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($entry in $value.files){
        $relative=[string]$entry.relative_path
        if([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative)){throw ('invalid_or_duplicate_'+$Label+'_path')}
        $path=[IO.Path]::GetFullPath((Join-Path $Root $relative))
        if(-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or -not $seen.Add($path)){throw ('invalid_or_duplicate_'+$Label+'_path')}
        if(-not [IO.File]::Exists($path)){throw ($Label+'_file_missing:'+$relative)}
        if([string]$entry.sha256 -notmatch '\A[0-9A-Fa-f]{64}\z' -or
           [string]$entry.bytes -notmatch '\A(?:0|[1-9][0-9]*)\z' -or
           (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash -ne $entry.sha256 -or
           ([IO.FileInfo]::new($path)).Length -ne $entry.bytes){throw ($Label+'_file_changed:'+$relative)}
    }
    foreach($relative in $Required){
        if(-not $seen.Contains([IO.Path]::GetFullPath((Join-Path $Root $relative)))){throw ($Label+'_required_file_not_listed:'+$relative)}
    }
    [pscustomobject]@{manifest=$value;files_verified=$seen.Count}
}
# Required paths prevent a self-consistent but incomplete manifest from passing.
# Additional listed files remain supported; this is an integrity check, not a signature.
$bundleRequired=@(
    '03_tools/aztec_exporter/AZtecBmpExporter.exe',
    '03_tools/aztec_exporter/AZtecBmpExporter.dll',
    '03_tools/aztec_exporter/AZtecBmpExporter.cs',
    '03_tools/aztec_exporter/AZtecBmpApi.cs',
    '03_tools/aztec_exporter/build.ps1',
    '03_tools/aztec_exporter/export.ps1',
    '03_tools/aztec_exporter/native_map.ps1',
    '03_tools/aztec_exporter/native_gos.ps1',
    '03_tools/aztec_exporter/native_kam.ps1',
    '03_tools/aztec_exporter/render_ipf_layout.ps1',
    '03_tools/aztec_exporter/README.md',
    '03_tools/scripts/AztecNativeIpfConsole.exe',
    '03_tools/scripts/AztecNativeIpfConsole.cs',
    '03_tools/scripts/AztecNativeIpfKeyProbeNoDispose.exe',
    '03_tools/scripts/AztecNativeIpfKeyProbe.cs',
    '03_tools/scripts/export_aztec_native_gos_pixels.ps1',
    '03_tools/scripts/AztecNativeGosPixelAudit.cs',
    '03_tools/scripts/export_aztec_native_kam_gos.ps1',
    '03_tools/scripts/export_aztec_native_scalar_bmp.ps1',
    '03_tools/scripts/render_aztec_native_scalar_canvas.ps1',
    '03_tools/scripts/verify_aztec_native_dll.ps1',
    '03_tools/scripts/test_aztec_native_retry.ps1',
    '03_tools/scripts/probe_aztec_boundary_determinism.ps1',
    '03_tools/scripts/AztecBoundaryDeterminismProbe.cs',
    'aztec_bmp_compare/p46_ipf_overlay/IpfOverlayRenderer.cs',
    'aztec_bmp_compare/p46_ipf_overlay/export_native_bc.ps1',
    'aztec_bmp_compare/p46_ipf_overlay/NativeBcAudit.cs',
    'aztec_bmp_compare/p47_baseline/P47BaselineMetrics.cs'
)
$runtimeRequired=@(
    'SKILL.md',
    'references/aztec-native-cleanup.md',
    'references/cleanup-metrics-and-mtex.md',
    'references/aztec-native-toolchain.md',
    'scripts/native-cleanup/run_aztec_native_cleanup.ps1',
    'scripts/native-cleanup/run_aztec_native_cleanup_sta.ps1',
    'scripts/native-cleanup/native_cleanup_worker.ps1',
    'scripts/native-cleanup/native_cleanup_worker_optimized.ps1',
    'scripts/native-cleanup/NativeCleanupSnapshot.cs',
    'scripts/native-cleanup/NativeCleanupSnapshotOptimized.cs',
    'scripts/native-cleanup/NativeOrientationPersistence.cs',
    'scripts/native-cleanup/NativeOrientationPersistenceOptimized.cs',
    'scripts/native-cleanup/verify_aztec_native_cleanup_run.ps1',
    'scripts/native-cleanup/verify_aztec_native_cleanup_run_optimized.ps1',
    'scripts/retry_failed_aztec_native_batch_parallel.ps1',
    'scripts/parallel-resource-policy.ps1',
    'scripts/test-parallel-resource-policy.ps1',
    'scripts/verify-toolchain.ps1'
)
$bundleCheck=VerifyManifest $bundleRoot (Join-Path $bundleRoot 'toolchain-manifest.json') $bundleRequired 'toolchain'
$runtimeCheck=VerifyManifest $skillRoot (Join-Path $skillRoot 'runtime-manifest.json') $runtimeRequired 'runtime'
$manifest=$bundleCheck.manifest
$environment=[ordered]@{checked=(-not $SkipEnvironment)}
if(-not $SkipEnvironment){
    $ps7='C:\Program Files\PowerShell\7\pwsh.exe'
    $framework=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $aztec='C:\Program Files\Oxford Instruments NanoAnalysis\AZtec'
    foreach($path in @($ps7,$framework,(Join-Path $aztec 'core.ebsd.dll'),(Join-Path $aztec 'AZtecCrystal.exe'))){if(-not [IO.File]::Exists($path)){throw ('required_runtime_missing:'+$path)}}
    $environment.aztec_version=[Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $aztec 'AZtecCrystal.exe')).FileVersion
    if($environment.aztec_version -ne $manifest.validated_aztec_version){throw ('unvalidated_aztec_version:'+$environment.aztec_version)}
    $environment.powershell_core=[string]$PSVersionTable.PSVersion
    $environment.architecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    if($environment.architecture -ne 'X64'){throw 'requires_x64_host'}
    $staProbe="if (`$PSVersionTable.PSEdition -ne 'Desktop') { exit 21 }; if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) { exit 22 }; exit 0"
    $staProbeEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($staProbe))
    $staProbeProcess=Start-Process -FilePath $framework -ArgumentList @('-NoProfile','-STA','-EncodedCommand',$staProbeEncoded) -WindowStyle Hidden -PassThru -Wait
    if($staProbeProcess.ExitCode -ne 0){throw ('framework_sta_preflight_failed:exit=' + $staProbeProcess.ExitCode + ';expected=Desktop|STA')}
    $environment.framework_sta_worker_passed=$true
    $exe=Join-Path $bundleRoot '03_tools/aztec_exporter/AZtecBmpExporter.exe'
    $help=@(& $exe --help)
    if($LASTEXITCODE -ne 0 -or -not ($help -match 'AZtecBmpExporter --input')){throw 'exporter_help_failed'}
    $environment.exporter_help_passed=$true
}
[pscustomobject]@{status='passed';files_verified=$bundleCheck.files_verified;runtime_files_verified=$runtimeCheck.files_verified;bundle_root=$bundleRoot;environment=$environment;NativeFullMapFidelity='not_accepted'}|ConvertTo-Json -Depth 5
