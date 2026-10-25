param(
    [Parameter(Mandatory = $true)] [string] $CprPath,
    [Parameter(Mandatory = $true)] [string] $InputCsv,
    [Parameter(Mandatory = $true)] [ValidateSet('KAM', 'GOS')] [string] $Metric,
    [Parameter(Mandatory = $true)] [string] $OutputBmp,
    [Parameter(Mandatory = $true)] [string] $OutputReport,
    [double] $DisplayMin = 0.0,
    [Nullable[double]] $DisplayMax,
    [string] $ColorScale = 'HeatMap',
    [string] $AztecRoot = 'C:\Program Files\Oxford Instruments NanoAnalysis\AZtec'
)

$ErrorActionPreference = 'Stop'
$source = (Resolve-Path -LiteralPath $CprPath).Path
$sourceCrc = [IO.Path]::ChangeExtension($source, '.crc')
$csv = (Resolve-Path -LiteralPath $InputCsv).Path
$bmpPath = [IO.Path]::GetFullPath($OutputBmp)
$reportPath = [IO.Path]::GetFullPath($OutputReport)
if (-not [IO.File]::Exists($sourceCrc)) { throw "source_crc_missing:$sourceCrc" }
if ([IO.Path]::GetExtension($bmpPath) -ine '.bmp') { throw "output_must_be_bmp:$bmpPath" }
foreach ($target in @($bmpPath, $reportPath)) {
    if ($target -eq $source -or $target -eq $sourceCrc -or $target -eq $csv) { throw "output_must_not_replace_input:$target" }
    if ([IO.File]::Exists($target)) { throw "output_exists:$target" }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
}
if (-not [IO.File]::Exists((Join-Path $AztecRoot 'core.ebsd.dll'))) { throw "aztec_core_missing:$AztecRoot" }

function Get-Sha256Hex([string] $Path) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '') }
    finally { $stream.Dispose(); $algorithm.Dispose() }
}

$sourceCprHash = Get-Sha256Hex $source
$sourceCrcHash = Get-Sha256Hex $sourceCrc
$csvHash = Get-Sha256Hex $csv
Set-Location -LiteralPath $AztecRoot
Get-ChildItem -LiteralPath $AztecRoot -Filter '*.dll' -File | ForEach-Object {
    try { [Reflection.Assembly]::LoadFrom($_.FullName) | Out-Null } catch { }
}
[Reflection.Assembly]::LoadFrom((Join-Path $AztecRoot 'core.ebsd.dll')) | Out-Null

$project = $null
$bitmap = $null
try {
    $project = [Core.Ebsd.Infrastructure.Project]::new($source)
    if ($project.DatasetCount -ne 1) { throw "unexpected_dataset_count:$($project.DatasetCount)" }
    $dataset = $project.Datasets[0]
    if (-not $dataset.IsPopulated) { $dataset.PopulateData() }
    $width = [int]$dataset.XCount
    $height = [int]$dataset.YCount
    $pointCount = [int]$dataset.PixelCount
    if ($width -lt 1 -or $height -lt 1 -or $width * $height -ne $pointCount) { throw 'invalid_dataset_geometry' }

    $reader = [IO.StreamReader]::new($csv, $true)
    try {
        $header = $reader.ReadLine()
        if ($Metric -eq 'KAM' -and $header -cne 'Index,KAM_deg,Valid') { throw "invalid_kam_csv_header:$header" }
        if ($Metric -eq 'GOS' -and $header -cne 'Index,Grain Orientation Spread') { throw "invalid_gos_csv_header:$header" }
        if ($Metric -eq 'GOS') { [void]$reader.ReadLine() }
        $pixels = [int[]]::new($pointCount)
        $seen = [bool[]]::new($pointCount)
        $validCount = 0
        $minimum = [double]::PositiveInfinity
        $maximum = [double]::NegativeInfinity
        $scale = [Enum]::Parse([Core.Ebsd.ImageProcessing.ColorScaleType], $ColorScale, $true)
        $index = 0
        $invariant = [Globalization.CultureInfo]::InvariantCulture
        while ($null -ne ($line = $reader.ReadLine())) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $fields = $line.Split(',')
            if ($fields.Length -lt 2) { throw "invalid_csv_row:$index" }
            $rowIndex = -1
            if (-not [int]::TryParse($fields[0], [Globalization.NumberStyles]::Integer, $invariant, [ref]$rowIndex)) { throw "invalid_csv_index:$index" }
            if ($rowIndex -lt 0 -or $rowIndex -ge $pointCount -or $seen[$rowIndex]) { throw "csv_index_duplicate_or_out_of_range:$rowIndex" }
            $seen[$rowIndex] = $true
            $isValid = $fields[1].Length -gt 0
            if ($Metric -eq 'KAM') {
                if ($fields.Length -ne 3) { throw "invalid_kam_csv_fields:$rowIndex" }
                $isValid = $isValid -and $fields[2].Trim().ToLowerInvariant() -in @('true', '1', 'yes')
            }
            if (-not $isValid) { $pixels[$rowIndex] = -1; $index++; continue }
            $value = [double]::NaN
            if (-not [double]::TryParse($fields[1], [Globalization.NumberStyles]::Float, $invariant, [ref]$value) -or [double]::IsNaN($value) -or [double]::IsInfinity($value)) {
                throw "invalid_scalar_value:$rowIndex"
            }
            $validCount++
            if ($value -lt $minimum) { $minimum = $value }
            if ($value -gt $maximum) { $maximum = $value }
            $index++
        }
        if (@($seen | Where-Object { $_ }).Count -ne $pointCount) { throw "csv_point_coverage:$(@($seen | Where-Object { $_ }).Count)/$pointCount" }
        if ($validCount -eq 0) { throw 'no_valid_scalar_values' }
        $displayMaxValue = if ($null -ne $DisplayMax) { [double]$DisplayMax } else { [Math]::Ceiling(($maximum - $DisplayMin) * 100.0) / 100.0 + $DisplayMin }
        if ($displayMaxValue -le $DisplayMin) { throw 'display_range_must_be_positive' }
        $reader.Dispose()
    } finally { $reader.Dispose() }

    # Re-read only scalar values after selecting the display range, preserving the verified CSV index map.
    $reader = [IO.StreamReader]::new($csv, $true)
    try {
        [void]$reader.ReadLine()
        if ($Metric -eq 'GOS') { [void]$reader.ReadLine() }
        while ($null -ne ($line = $reader.ReadLine())) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $fields = $line.Split(',')
            $rowIndex = [int]::Parse($fields[0], $invariant)
            if ($Metric -eq 'KAM' -and $fields[2].Trim().ToLowerInvariant() -notin @('true', '1', 'yes')) { continue }
            $value = [double]::Parse($fields[1], $invariant)
            $color = [Core.Ebsd.ImageProcessing.ColorCoding]::GetColorFromScale(
                $value, $DisplayMin, $displayMaxValue, $scale, $false, $true, 5)
            $pixels[$rowIndex] = [int](-16777216 -bor ([int]$color.R -shl 16) -bor ([int]$color.G -shl 8) -bor [int]$color.B)
        }
    } finally { $reader.Dispose() }

    $bitmap = [Core.Ebsd.ImageProcessing.BitmapTools]::IntArrayToBitmap($pixels, $width, $height)
    [Core.Ebsd.ImageProcessing.BitmapTools]::Save($bitmap, $bmpPath)
    if ((Get-Sha256Hex $source) -ne $sourceCprHash -or (Get-Sha256Hex $sourceCrc) -ne $sourceCrcHash -or (Get-Sha256Hex $csv) -ne $csvHash) {
        throw 'input_hash_changed_during_export'
    }
    $fileBytes = [IO.File]::ReadAllBytes($bmpPath)
    if ($fileBytes.Length -lt 54 -or $fileBytes[0] -ne 0x42 -or $fileBytes[1] -ne 0x4D) { throw 'bmp_signature_invalid' }
    $report = [pscustomobject]@{
        status = 'aztec_native_scalar_bmp_exported'
        metric = $Metric
        source_cpr = $source; source_cpr_sha256 = $sourceCprHash
        source_crc = $sourceCrc; source_crc_sha256 = $sourceCrcHash
        values_csv = $csv; values_csv_sha256 = $csvHash
        output_bmp = $bmpPath; output_bmp_sha256 = Get-Sha256Hex $bmpPath; output_bmp_bytes = $fileBytes.Length
        width = $width; height = $height; point_count = $pointCount; valid_count = $validCount
        data_min = $minimum; data_max = $maximum; display_min = $DisplayMin; display_max = $displayMaxValue
        color_scale = $ColorScale; gradient = $true; step_count = 5; inverted = $false
        color_engine = 'AZtec Core.Ebsd.ImageProcessing.ColorCoding.GetColorFromScale'
        bitmap_encoder = 'AZtec Core.Ebsd.ImageProcessing.BitmapTools.IntArrayToBitmap/Save'
        row_order = 'CPR dataset index, x-fastest'
        display_limit_note = 'Default upper bound rounds the observed maximum up to 0.01 degree; pass DisplayMax to match a saved map template.'
    }
    [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($true))
    $report | ConvertTo-Json -Depth 5
} finally {
    if ($null -ne $bitmap) { $bitmap = $null }
    if ($null -ne $project) { try { $project.Dispose() } catch { } }
}
