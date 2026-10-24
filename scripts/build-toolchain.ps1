param()
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Core' -or -not $IsWindows) { throw 'requires_windows_powershell_core' }
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourceCheck = (& (Join-Path $PSScriptRoot 'verify-source.ps1') | ConvertFrom-Json)
if ($sourceCheck.status -ne 'passed') { throw 'source_verification_failed' }
$bundle = Join-Path $root 'assets/aztec-native-toolchain'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if (-not [IO.File]::Exists($compiler)) { throw 'framework_x64_compiler_missing' }
$targets = @(
    @{ source='03_tools/aztec_exporter/AZtecBmpExporter.cs'; output='03_tools/aztec_exporter/AZtecBmpExporter.exe'; kind='exe' },
    @{ source='03_tools/aztec_exporter/AZtecBmpApi.cs'; output='03_tools/aztec_exporter/AZtecBmpExporter.dll'; kind='library' },
    @{ source='03_tools/scripts/AztecNativeIpfConsole.cs'; output='03_tools/scripts/AztecNativeIpfConsole.exe'; kind='exe' },
    @{ source='03_tools/scripts/AztecNativeIpfKeyProbe.cs'; output='03_tools/scripts/AztecNativeIpfKeyProbeNoDispose.exe'; kind='exe' }
)
foreach ($target in $targets) {
    $output = Join-Path $bundle $target.output
    & $compiler /nologo ('/target:' + $target.kind) /platform:x64 /reference:System.Core.dll /reference:System.Web.Extensions.dll ('/out:' + $output) (Join-Path $bundle $target.source)
    if ($LASTEXITCODE -ne 0) { throw ('build_failed:' + $target.source) }
}
$source = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes((Join-Path $root 'source-manifest.json'))).TrimStart([char]0xFEFF) | ConvertFrom-Json
function FileEntry([string]$base, [string]$relative) {
    $file = Join-Path $base $relative
    [ordered]@{ relative_path=$relative; sha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash; bytes=([IO.FileInfo]::new($file)).Length }
}
function WriteManifest([string]$path, [object[]]$files) {
    $value = [ordered]@{
        schema_version=1; package_id='aztec-ebsd-source-build'; validated_aztec_version='5.1.7829.1'
        file_count=$files.Count; NativeFullMapFidelity='not_accepted'; vendor_assemblies_included=$false
        sample_or_reference_images_included=$false; files=$files
    }
    [IO.File]::WriteAllText($path, ($value | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($true))
}
$bundlePrefix = 'assets/aztec-native-toolchain/'
$bundleFiles = @($source.files | Where-Object { $_.relative_path.StartsWith($bundlePrefix) } | ForEach-Object {
    FileEntry $bundle $_.relative_path.Substring($bundlePrefix.Length)
}) + @($targets | ForEach-Object { FileEntry $bundle $_.output })
WriteManifest (Join-Path $bundle 'toolchain-manifest.json') $bundleFiles
$runtimeFiles = @($source.files | Where-Object { -not $_.relative_path.StartsWith($bundlePrefix) } | ForEach-Object {
    FileEntry $root $_.relative_path
}) + @((FileEntry $root 'source-manifest.json'), (FileEntry $root 'assets/aztec-native-toolchain/toolchain-manifest.json'))
WriteManifest (Join-Path $root 'runtime-manifest.json') $runtimeFiles
[pscustomobject]@{ status='built'; targets=$targets.Count; source_files_verified=$sourceCheck.source_files_verified; vendor_assemblies_included=$false } | ConvertTo-Json
