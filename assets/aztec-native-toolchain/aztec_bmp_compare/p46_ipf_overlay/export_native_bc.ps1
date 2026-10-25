param(
    [int[]] $Samples = @(1,2,3),
    [string] $OutputRoot = $PSScriptRoot,
    [ValidateRange(10,600)] [int] $TimeoutSeconds = 180,
    [string] $AztecRoot = 'C:\Program Files\Oxford Instruments NanoAnalysis\AZtec',
    [switch] $NativeChild,
    [string] $CprPath,
    [string] $OutputDirectory
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
if(-not $NativeChild){
    if($PSVersionTable.PSEdition -ne 'Core'){throw 'parent_requires_powershell_core'}
    $root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $child=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    foreach($n in $Samples){
        if($n -notin 1,2,3){throw 'sample_out_of_scope'}
        $sample=([string][char]0x6539)+([string][char]0x8fdb)+$n
        $directory=Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ($sample+'\native_bc')
        if([IO.Directory]::Exists($directory) -and @(Get-ChildItem -LiteralPath $directory -Force | Where-Object {$_.Name -ne '_attempts'}).Count -gt 0){throw ('output_directory_exists:'+ $directory)}
        [IO.Directory]::CreateDirectory($directory)|Out-Null
        $arguments=@('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-NativeChild',
            '-CprPath',(Join-Path $root ('改进\'+$sample+'.cpr')),'-OutputDirectory',$directory,'-AztecRoot',$AztecRoot)
        Write-JsonNew (Join-Path $directory 'command.json') @{Executable=$child;Arguments=$arguments;TimeoutSeconds=$TimeoutSeconds}
        $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$child;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$info.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
        foreach($argument in $arguments){$info.ArgumentList.Add($argument)}
        $process=[Diagnostics.Process]::new();$process.StartInfo=$info
        try{
            if(-not $process.Start()){throw 'child_start_failed'}
            $stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync()
            if(-not $process.WaitForExit($TimeoutSeconds*1000)){
                $process.Kill($true);$process.WaitForExit()
                Write-JsonNew (Join-Path $directory 'timeout.json') @{status='failed';reason='finite_child_timeout';seconds=$TimeoutSeconds}
                throw 'native_bc_timeout'
            }
            [IO.File]::WriteAllText((Join-Path $directory 'stdout.log'),$stdoutTask.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($true))
            [IO.File]::WriteAllText((Join-Path $directory 'stderr.log'),$stderrTask.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($true))
            if($process.ExitCode -ne 0){throw ('native_bc_failed:sample='+$n+';exit='+$process.ExitCode)}
            $report=Get-Content -LiteralPath (Join-Path $directory 'bc_native.json') -Encoding UTF8 -Raw|ConvertFrom-Json
            [pscustomobject]@{Sample=$sample;Status=$report.status;RawRange=$report.audit.raw_range;Limits=$report.actual_limits_for_drawing;Pixels=$report.audit.count}|ConvertTo-Json -Compress
        }finally{$process.Dispose()}
    }
    return
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
