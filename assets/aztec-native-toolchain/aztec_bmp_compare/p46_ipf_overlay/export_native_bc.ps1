param(
    [Parameter(Mandatory=$true)][string] $CprPath,
    [Parameter(Mandatory=$true)][string] $OutputDirectory,
    [string] $AztecRoot = 'C:\Program Files\Oxford Instruments NanoAnalysis\AZtec'
)
$ErrorActionPreference = 'Stop'
function Write-JsonNew([string]$Path, $Value) {
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $writer=[IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($true))
    try {$writer.Write(($Value|ConvertTo-Json -Depth 12))} finally {$writer.Dispose()}
}
function Sha([string]$Path) {
    $hash=[Security.Cryptography.SHA256]::Create();$stream=[IO.File]::OpenRead($Path)
    try {([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-','')} finally {$stream.Dispose();$hash.Dispose()}
}
if ($PSVersionTable.PSEdition -ne 'Desktop' -or [Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    throw 'native_bc_requires_Windows_PowerShell_Framework_STA_child_process'
}

[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$source=(Resolve-Path -LiteralPath $CprPath).Path;$crc=[IO.Path]::ChangeExtension($source,'.crc')
if(-not [IO.File]::Exists($crc)){throw 'source_crc_missing'}
$output=[IO.Path]::GetFullPath($OutputDirectory)
foreach($name in @('bc_sources.csv','bc_native.json','failure.json')){if([IO.File]::Exists((Join-Path $output $name))){throw ('output_exists:'+ $name)}}
function Snapshot($Object,[int]$Depth=2){
    if($null -eq $Object){return $null}
    $result=[ordered]@{type=$Object.GetType().FullName}
    foreach($property in $Object.GetType().GetProperties([Reflection.BindingFlags]'Public,Instance')){
        if($property.GetIndexParameters().Count -ne 0 -or $null -eq $property.GetGetMethod()){continue}
        try{
            $value=$property.GetValue($Object,$null)
            if($null -eq $value){$result[$property.Name]=$null}
            elseif($value -is [string] -or $value -is [ValueType]){$result[$property.Name]=$value.ToString()}
            elseif($Depth -gt 0 -and $property.Name -match 'Settings$|Range$|Limits$|Color$'){$result[$property.Name]=Snapshot $value ($Depth-1)}
            else{$result[$property.Name]=@{type=$value.GetType().FullName}}
        }catch{$result[$property.Name]=@{read_error=$_.Exception.GetBaseException().Message}}
    }
    [pscustomobject]$result
}
$project=$null;$layer=$null;$stage='assembly_load'
try{
    $before=@{cpr=Sha $source;crc=Sha $crc}
    Set-Location -LiteralPath $AztecRoot
    Get-ChildItem -LiteralPath $AztecRoot -Filter '*.dll' -File|ForEach-Object {try{[Reflection.Assembly]::LoadFrom($_.FullName)|Out-Null}catch{}}
    $assembly=[Reflection.Assembly]::LoadFrom((Join-Path $AztecRoot 'core.ebsd.dll'))
    $stage='project_dataset_open'
    $project=[Core.Ebsd.Infrastructure.Project]::new($source)
    if($project.DatasetCount -ne 1){throw 'unexpected_dataset_count'}
    $dataset=$project.Datasets[0];if(-not $dataset.IsPopulated){$dataset.PopulateData()}
    $savedMaps=@()
    if($null -ne $dataset.Maps -and $null -ne $dataset.Maps.Items){
        foreach($map in $dataset.Maps.Items){
            $layers=@();if($null -ne $map.MapLayersValueGrid){foreach($savedLayer in $map.MapLayersValueGrid){$layers+=@{type=$savedLayer.GetType().FullName;settings=Snapshot $savedLayer.Settings 3}}}
            $storage=@($map.GetType().GetFields([Reflection.BindingFlags]'Public,NonPublic,Instance')|Where-Object {$_.Name -match 'layer'}|ForEach-Object {@{name=$_.Name;type=$_.FieldType.FullName}})
            $savedMaps+=@{name=$map.Name;settings=Snapshot $map.Settings 2;layers=$layers;layer_collection_source='Map.MapLayersValueGrid';layer_storage_metadata=$storage}
        }
    }
    $stage='native_bc_settings_and_layer'
    $settings=[Core.Ebsd.EBSDMaps.MapLayerBandContrastSettings]::new()
    $newSettings=Snapshot $settings 3
    $layer=$settings.GetMapLayer($dataset)
    $stage='native_bc_populate_only'
    $layer.Populate()
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while(($null -eq $layer.Values -or $null -eq $layer.LimitsForDrawing) -and $watch.Elapsed.TotalSeconds -lt 20){Start-Sleep -Milliseconds 100}
    if($null -eq $layer.Values -or $null -eq $layer.LimitsForDrawing){throw 'native_bc_layer_not_ready'}
    $stage='native_bc_full_export'
    Add-Type -Path (Join-Path $PSScriptRoot 'NativeBcAudit.cs')
    $audit=[NativeBcAudit]::Run($dataset,$layer,(Join-Path $output 'bc_sources.csv'))
    $after=@{cpr=Sha $source;crc=Sha $crc}
    if($before.cpr -ne $after.cpr -or $before.crc -ne $after.crc){throw 'source_hash_changed'}
    $getPixel=$layer.GetType().GetMethod('GetPixel',[type[]]@([int]))
    $getValue=$layer.GetType().GetMethod('GetValue',[type[]]@([int]))
    $report=[ordered]@{
        status='verified_native_bc_export';source_cpr=$source;source_crc=$crc;source_hashes_before=$before;source_hashes_after=$after
        vendor_assembly=$assembly.FullName;vendor_assembly_sha256=Sha (Join-Path $AztecRoot 'core.ebsd.dll')
        width=[int]$dataset.XCount;height=[int]$dataset.YCount;grid_step_micron=@([double]$dataset.StepSizeMicronX,[double]$dataset.StepSizeMicronY)
        raw_data_source='Project(path).Datasets[0].BandContrast';raw_data_type=$dataset.BandContrast.GetType().FullName
        csv_path=(Join-Path $output 'bc_sources.csv');csv_sha256=Sha (Join-Path $output 'bc_sources.csv');audit=$audit
        saved_maps_before_new_layer=$savedMaps;new_constructor_settings=$newSettings;runtime_layer_settings=Snapshot $layer.Settings 3
        actual_limits_for_drawing=@([double]$layer.LimitsForDrawing.Item1,[double]$layer.LimitsForDrawing.Item2)
        layer_type=$layer.GetType().FullName;get_pixel_signature=$getPixel.ToString();get_value_signature=$(if($getValue){$getValue.ToString()}else{$null})
        provenance=@{raw='verified';new_layer_settings='verified_runtime_default_new_layer_not_saved_golden_settings';saved_maps='read_from_project_before_new_layer_creation';gray='verified_pointwise_GetPixel_output';composition='unproven_no_BC_IPF_mixing_rule_inferred';grains='no_GrainSizing_Populate_or_boundary_calculation_called'}
        failures=@();constraints=@('no_gui','no_original_cpr_crc_write','no_golden_bmp_read_or_write','no_ipf_rgb_change','no_custom_crystallography')
    }
    Write-JsonNew (Join-Path $output 'bc_native.json') $report
    [Console]::WriteLine('verified_native_bc_export:'+ $audit['count'])
}catch{
    Write-JsonNew (Join-Path $output 'failure.json') @{status='failed';stage=$stage;error=$_.Exception.GetBaseException().Message;detail=$_.ToString()}
    throw
}finally{
    if($null -ne $layer){try{$layer.Dispose()}catch{}}
    if($null -ne $project){try{$project.Dispose()}catch{}}
}
