param(
    [Parameter(Mandatory = $true)] [string] $CprPath,
    [Parameter(Mandatory = $true)] [string] $OutputJson,
    [string] $OutputCsv,
    [switch] $SummaryOnly,
    [string] $AztecRoot = 'C:\Program Files\Oxford Instruments NanoAnalysis\AZtec'
)

$ErrorActionPreference = 'Stop'
$sourcePath = (Resolve-Path -LiteralPath $CprPath).Path
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "missing_cpr:$CprPath" }
$sourceCrc = [IO.Path]::ChangeExtension($sourcePath, '.crc')
if (-not (Test-Path -LiteralPath $sourceCrc -PathType Leaf)) { throw "missing_crc:$sourceCrc" }
function Get-Sha256Hex([string] $Path) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '') }
    finally { $stream.Dispose(); $algorithm.Dispose() }
}
Set-Location -LiteralPath $AztecRoot
Get-ChildItem -LiteralPath $AztecRoot -Filter '*.dll' -File | ForEach-Object {
    try { [Reflection.Assembly]::LoadFrom($_.FullName) | Out-Null } catch { }
}
[Reflection.Assembly]::LoadFrom((Join-Path $AztecRoot 'core.ebsd.dll')) | Out-Null

$project = $null
try {
    $sourceCprHash = Get-Sha256Hex $sourcePath
    $sourceCrcHash = Get-Sha256Hex $sourceCrc
    $project = [Core.Ebsd.Infrastructure.Project]::new($sourcePath)
    if ($project.DatasetCount -ne 1) { throw "unexpected_dataset_count:$($project.DatasetCount)" }
    $dataset = $project.Datasets[0]
    if (-not $dataset.IsPopulated) { $dataset.PopulateData() }

    $kamSettings = [Core.Ebsd.Calculations.KernelAverageMisorientationSettings]::new(
        [Core.Ebsd.Common.MaskShape]::Square,
        [Core.Ebsd.Common.MaskSize]::Size_3x3,
        5.0,
        $true
    )
    $kamSettings.OnlyPeriphery = $true
    $kam = [Core.Ebsd.Calculations.KernelAverageMisorientation]::new($dataset, $kamSettings)
    $kamValues = New-Object 'System.Collections.Generic.List[System.Nullable[double]]'
    $kamValid = New-Object 'System.Collections.Generic.List[bool]'
    for ($y = 0; $y -lt $dataset.YCount; $y++) {
        for ($x = 0; $x -lt $dataset.XCount; $x++) {
            $value = $kam.GetValue($x, $y)
            if ($value.Item2) { $kamValues.Add([double]$value.Item1); $kamValid.Add($true) }
            else { $kamValues.Add($null); $kamValid.Add($false) }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($OutputCsv)) {
        $csvParent = Split-Path -Parent $OutputCsv
        if ($csvParent) { [IO.Directory]::CreateDirectory($csvParent) | Out-Null }
        $writer = [IO.StreamWriter]::new($OutputCsv, $false, [Text.UTF8Encoding]::new($true))
        try {
            $writer.WriteLine('Index,KAM_deg,Valid')
            for ($i = 0; $i -lt $kamValues.Count; $i++) {
                if ($kamValid[$i]) {
                    $formatted = ([double]$kamValues[$i]).ToString('R', [Globalization.CultureInfo]::InvariantCulture)
                    $writer.WriteLine("$i,$formatted,true")
                } else {
                    $writer.WriteLine("$i,,false")
                }
            }
        } finally { $writer.Dispose() }
    }

    $grainSizing = $dataset.GrainSizing
    $grainSettingsInfo = @()
    if ($null -ne $grainSizing) {
        $grainSettingsInfo = @($grainSizing.SettingsInfo | ForEach-Object {
            [pscustomobject]@{ name = $_.Key; value = $_.Value }
        })
    }

    $payload = [ordered]@{
        status = 'partial_kam_complete_gos_ui_workflow_required'
        source_cpr = $sourcePath
        source_crc = $sourceCrc
        source_cpr_sha256 = $sourceCprHash
        source_crc_sha256 = $sourceCrcHash
        aztec_core_sha256 = Get-Sha256Hex (Join-Path $AztecRoot 'core.ebsd.dll')
        dataset_name = $dataset.Name
        width = $dataset.XCount
        height = $dataset.YCount
        point_count = $dataset.PixelCount
        phase_count = $dataset.Phases.Count
        kam = [ordered]@{
            kernel_shape = 'Square'
            kernel_size = 'Size_3x3'
            only_periphery = $kamSettings.OnlyPeriphery
            max_angle_deg = $kamSettings.MaxAngleDegree
            value_count = $kamValues.Count
            valid_count = @($kamValid | Where-Object { $_ }).Count
            values_deg_row_major = if ($SummaryOnly) { @() } else { @($kamValues) }
            valid = if ($SummaryOnly) { @() } else { @($kamValid) }
        }
        gos = [ordered]@{
            status = 'native_values_not_exported_documented_grain_detection_workflow_required'
            parameter = 'Mean'
            native_grain_sizing_settings = $grainSettingsInfo
            algorithm_source = 'AZtec installed help: GOS and MOS Maps'
            grain_detection_source = 'AZtec installed help: Detecting Grains'
            required_ui_workflow = 'Run grain detection with the intended settings, then create the GOS map layer in AZtec.'
            values_deg_row_major = @()
        }
    }
    if ((Get-Sha256Hex $sourcePath) -ne $sourceCprHash -or (Get-Sha256Hex $sourceCrc) -ne $sourceCrcHash) {
        throw 'source_pair_hash_changed_during_export'
    }
    $parent = Split-Path -Parent $OutputJson
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $payload | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 -LiteralPath $OutputJson
    [pscustomobject]@{
        status = 'partial_kam_complete_gos_ui_workflow_required'
        output = $OutputJson
        points = $dataset.PixelCount
        kam_valid_count = @($kamValid | Where-Object { $_ }).Count
        kam_values_count = $kamValues.Count
        csv = $OutputCsv
        gos_value_count = 0
        grain_settings_entry_count = $grainSettingsInfo.Count
    } | ConvertTo-Json -Compress
} finally {
    if ($null -ne $project) {
        try { $project.Dispose() } catch { Write-Warning ("project_dispose: " + $_.Exception.Message) }
    }
}
