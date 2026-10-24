param(
    [Parameter(Mandatory=$true)][string]$CprPath,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [int]$Repeat=6,
    [int]$PixelWidth=2734,
    [string]$AztecRoot='C:\Program Files\Oxford Instruments NanoAnalysis\AZtec'
)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop' -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'requires_framework_sta_child'}
if($Repeat -lt 2 -or $Repeat -gt 12 -or $PixelWidth -lt 1 -or $PixelWidth -gt 4000){throw 'probe_size_out_of_range'}
$out=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path -LiteralPath $out){throw 'output_exists'}
[IO.Directory]::CreateDirectory($out)|Out-Null
function Sha([string]$Path){$s=[IO.File]::OpenRead($Path);$h=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($h.ComputeHash($s))).Replace('-','')}finally{$s.Dispose();$h.Dispose()}}
$report=[ordered]@{status='running';edition=$PSVersionTable.PSEdition;apartment=[string][Threading.Thread]::CurrentThread.ApartmentState;started_utc=[DateTime]::UtcNow.ToString('o');gui_started=$false;reference_pixels_used=$false;custom_boundary_drawing_used=$false}
$source=$null;$crc=$null;$before=$null
try{
    $source=(Resolve-Path -LiteralPath $CprPath).Path;$crc=[IO.Path]::ChangeExtension($source,'.crc')
    $before=@{cpr=Sha $source;crc=Sha $crc};$report.before=$before;$report.source=$source
    $helper=Join-Path $PSScriptRoot 'AztecBoundaryDeterminismProbe.cs'
    Add-Type -Path $helper
    $report.helper_sha256=Sha $helper;$report.script_sha256=Sha $PSCommandPath
    [Threading.Thread]::CurrentThread.CurrentUICulture=[Globalization.CultureInfo]::GetCultureInfo('zh-CN')
    Set-Location -LiteralPath $AztecRoot
    Get-ChildItem -LiteralPath $AztecRoot -Filter '*.dll' -File|ForEach-Object{try{[Reflection.Assembly]::LoadFrom($_.FullName)|Out-Null}catch{}}
    $core=[Reflection.Assembly]::LoadFrom((Join-Path $AztecRoot 'core.ebsd.dll'))
    [Reflection.Assembly]::LoadFrom((Join-Path $AztecRoot 'AZtecCrystal.exe'))|Out-Null
    $report.core_sha256=Sha $core.Location
    [Core.Ebsd.Infrastructure.GlobalSettings]::InBackground=$false
    $project=[Core.Ebsd.Infrastructure.Project]::new($source)
    if($project.DatasetCount -ne 1){throw 'requires_single_dataset'}
    $dataset=$project.Datasets[0];if(-not $dataset.IsPopulated){$dataset.PopulateData()}
    $required=@('Core.Ebsd.EBSDMaps.MapLayerIPF','Core.Ebsd.EBSDMaps.MapLayerBandContrast','Core.Ebsd.EBSDMaps.MapLayerGrainBoundaries')
    $candidates=@($dataset.Maps.Items|Where-Object{$null-ne $_}|Where-Object{$types=@($_.Items|Where-Object{$null-ne $_}|ForEach-Object{$_.GetType().FullName});@($required|Where-Object{$types-notcontains $_}).Count-eq 0})
    if($candidates.Count-ne 1){throw 'saved_IPF_BC_GB_map_not_unique'}
    $map=$candidates[0];foreach($item in @($map.Items|Where-Object{$null-ne $_})){$item.Populate()};$map.PopulateSync()
    $report.map_name=$map.Name;$report.map_width=$map.Width;$report.map_height=$map.Height
    $report.result=[AztecBoundaryDeterminismProbe]::Run($map.PSObject.BaseObject,[int]$map.Width,[int]$map.Height,$PixelWidth,$Repeat,$out)
    $report.status='completed'
}catch{$report.status='failed';$report.error=$_.Exception.ToString();$report.position=$_.ScriptStackTrace}
finally{
    if($null-ne $before){$report.after=@{cpr=Sha $source;crc=Sha $crc};if($report.after.cpr-ne $before.cpr-or $report.after.crc-ne $before.crc){$report.status='input_changed'}}
    $report.finished_utc=[DateTime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText((Join-Path $out 'report.json'),($report|ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($true))
}
[Console]::WriteLine($report.status)
[Environment]::Exit($(if($report.status-eq 'completed'){0}else{1}))
