param()
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Core') { throw 'requires_powershell_core' }
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$strict = [Text.UTF8Encoding]::new($false, $true)
$manifestPath = Join-Path $root 'source-manifest.json'
foreach ($path in @($root, $manifestPath)) {
    if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'source_reparse_point_rejected' }
}
$manifest = $strict.GetString([IO.File]::ReadAllBytes($manifestPath)).TrimStart([char]0xFEFF) | ConvertFrom-Json
if ($manifest.schema_version -ne 1 -or $manifest.files -isnot [array] -or
    @($manifest.files).Count -lt 1 -or @($manifest.files).Count -ne $manifest.file_count) {
    throw 'invalid_source_manifest'
}
$generated = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($relative in @(
    'source-manifest.json', 'runtime-manifest.json',
    'assets/aztec-native-toolchain/toolchain-manifest.json',
    'assets/aztec-native-toolchain/03_tools/aztec_exporter/AZtecBmpExporter.exe',
    'assets/aztec-native-toolchain/03_tools/aztec_exporter/AZtecBmpExporter.dll',
    'assets/aztec-native-toolchain/03_tools/scripts/AztecNativeIpfConsole.exe',
    'assets/aztec-native-toolchain/03_tools/scripts/AztecNativeIpfKeyProbeNoDispose.exe'
)) { [void]$generated.Add($relative) }
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($entry in $manifest.files) {
    $relative = [string]$entry.relative_path
    if ([string]::IsNullOrWhiteSpace($relative) -or $relative.Contains('\') -or
        $relative.Contains(':') -or $relative.StartsWith('/') -or
        @($relative.Split('/') | Where-Object { $_ -in '', '.', '..', '.git' }).Count -gt 0 -or
        $generated.Contains($relative) -or -not $seen.Add($relative)) { throw 'invalid_or_duplicate_source_path' }
    $path = [IO.Path]::GetFullPath((Join-Path $root $relative))
    if (-not $path.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'source_path_outside_root'
    }
    $cursor = Get-Item -LiteralPath $path -Force
    while ($cursor.FullName -ne $root) {
        if ($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'source_reparse_point_rejected' }
        $cursor = $cursor.Parent ?? $cursor.Directory
    }
    if ([string]$entry.sha256 -notmatch '\A[0-9a-fA-F]{64}\z' -or
        [string]$entry.bytes -notmatch '\A(?:0|[1-9][0-9]*)\z' -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.sha256 -or
        ([IO.FileInfo]::new($path)).Length -ne $entry.bytes) { throw ('source_changed:' + $relative) }
    [void]$strict.GetString([IO.File]::ReadAllBytes($path))
}
# Enumerate explicitly to reject unlisted files, including ignored files. Only .git is skipped.
$queue = [Collections.Generic.Queue[string]]::new()
$queue.Enqueue($root)
while ($queue.Count -gt 0) {
    foreach ($item in Get-ChildItem -LiteralPath $queue.Dequeue() -Force) {
        $relative = [IO.Path]::GetRelativePath($root, $item.FullName).Replace('\', '/')
        if ($relative -eq '.git') { continue }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw ('reparse_point_rejected:' + $relative) }
        if ($item.PSIsContainer) { $queue.Enqueue($item.FullName); continue }
        if (-not $seen.Contains($relative) -and -not $generated.Contains($relative)) {
            throw ('unlisted_file:' + $relative)
        }
    }
}
[pscustomobject]@{ status = 'passed'; source_files_verified = $seen.Count; signature = $false } | ConvertTo-Json
