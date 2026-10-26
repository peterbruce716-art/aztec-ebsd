param(
    [Parameter(Mandatory=$true)][string] $CprPath,
    [Parameter(Mandatory=$true)][string] $OutputDirectory,
    [Parameter(Mandatory=$true)][ValidateSet('IPF','KAM','GOS')][string] $Metric,
    [int] $PixelWidth=2734,
    [string] $AztecRoot='C:\Program Files\Oxford Instruments NanoAnalysis\AZtec',
    [double] $DisplayMin,
    [double] $DisplayMax,
    [bool] $ShowGrains=$true
)

$ErrorActionPreference='Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop' -or [Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    throw 'native_map_requires_Windows_PowerShell_Framework_STA_child_process'
}
$process=[Diagnostics.Process]::GetCurrentProcess()
$out=[IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $out) { throw "output_exists:$out" }
[IO.Directory]::CreateDirectory($out) | Out-Null
$report=[ordered]@{
    schema_version=1;status='running';metric=$Metric;stage='validate';output_directory=$out
    started_utc=[DateTime]::UtcNow.ToString('o');host_edition=$PSVersionTable.PSEdition
    host_apartment=[string][Threading.Thread]::CurrentThread.ApartmentState
    renderer='AZtec EBSDDataAnalysis.Export.MapExport';gui_started=$false;csv_read=$false
    reference_pixels_used=$false;custom_drawing_used=$false
}
$report.requested_show_grains=$ShowGrains
$source=$null; $crc=$null; $before=$null; $bitmap=$null
function Sha([string] $Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function AssemblyReport([Reflection.Assembly] $Assembly) {
    [pscustomobject]@{
        name=$Assembly.GetName().Name;assembly_version=$Assembly.GetName().Version.ToString()
        file_version=[Diagnostics.FileVersionInfo]::GetVersionInfo($Assembly.Location).FileVersion
        path=$Assembly.Location;sha256=Sha $Assembly.Location
    }
}
function LayerReport($Layer) {
    $r=[ordered]@{type=$Layer.GetType().FullName}
    if ($null -ne $Layer.GetType().GetProperty('Values')) {
        $values=$Layer.Values
        $r.values_type=if ($null -ne $values) {$values.GetType().FullName} else {$null}
        $r.values_count=if ($null -ne $values) {$values.Count} else {0}
    }
    if ($null -ne $Layer.GetType().GetProperty('LimitsForDrawing')) {
        $limits=$Layer.LimitsForDrawing
        $r.limits_for_drawing=if ($null -ne $limits) {@([double]$limits.Item1,[double]$limits.Item2)} else {$null}
    }
    [pscustomobject]$r
}
function PixelSnapshot($Bitmap) {
    # Normalize only for measurement. The native exporter still owns all drawing
    # and encoding; exclude BMP headers, padding and unused alpha from identity.
    $rgb=[Windows.Media.Imaging.FormatConvertedBitmap]::new($Bitmap,[Windows.Media.PixelFormats]::Bgr24,$null,0)
    $stride=[int]($rgb.PixelWidth*3)
    $pixels=[byte[]]::new($stride*$rgb.PixelHeight)
    $rgb.CopyPixels($pixels,$stride,0)
    $hash=[Security.Cryptography.SHA256]::Create()
    try {
        [pscustomobject]@{width=$rgb.PixelWidth;height=$rgb.PixelHeight;format='Bgr24';stride=$stride;sha256=([BitConverter]::ToString($hash.ComputeHash($pixels))).Replace('-','')}
    } finally { $hash.Dispose() }
}
try {
    if ($PixelWidth -le 0 -or $PixelWidth -gt 16000) { throw 'pixel_width_out_of_supported_range' }
    $hasRange=$PSBoundParameters.ContainsKey('DisplayMin') -or $PSBoundParameters.ContainsKey('DisplayMax')
    if ($hasRange) {
        if (-not $PSBoundParameters.ContainsKey('DisplayMin') -or -not $PSBoundParameters.ContainsKey('DisplayMax')) { throw 'display_range_requires_both_min_and_max' }
        if ([double]::IsNaN($DisplayMin) -or [double]::IsInfinity($DisplayMin) -or
            [double]::IsNaN($DisplayMax) -or [double]::IsInfinity($DisplayMax) -or $DisplayMin -ge $DisplayMax) {
            throw 'display_range_requires_finite_min_less_than_max'
        }
        if ($Metric -eq 'IPF') { throw 'display_range_not_supported_for_IPF' }
    }
    $report.requested_display_range=if ($hasRange) {@($DisplayMin,$DisplayMax)} else {$null}
    $source=(Resolve-Path -LiteralPath $CprPath).Path
    $crc=[IO.Path]::ChangeExtension($source,'.crc')
    if (-not [IO.File]::Exists($source) -or -not [IO.File]::Exists($crc)) { throw 'source_cpr_crc_pair_missing' }
    $report.source=$source; $report.source_crc=$crc
    $before=@{cpr=Sha $source;crc=Sha $crc}; $report.before=$before
    $workerPath=if($PSCommandPath){$PSCommandPath}elseif($env:AZTEC_NATIVE_MAP_SCRIPT_PATH){$env:AZTEC_NATIVE_MAP_SCRIPT_PATH}else{$null}
    $report.worker_sha256=if($workerPath){Sha $workerPath}else{$null}
    $report.stage='load'
    # Set the UI language before any vendor type initializes localized defaults.
    [Threading.Thread]::CurrentThread.CurrentUICulture=[Globalization.CultureInfo]::GetCultureInfo('zh-CN')
    $report.ui_culture=[Threading.Thread]::CurrentThread.CurrentUICulture.Name
    Set-Location -LiteralPath $AztecRoot
    Get-ChildItem -LiteralPath $AztecRoot -Filter '*.dll' -File | ForEach-Object {
        try { [Reflection.Assembly]::LoadFrom($_.FullName) | Out-Null } catch { }
    }
    $core=[Reflection.Assembly]::LoadFrom((Join-Path $AztecRoot 'core.ebsd.dll'))
    $assembly=[Reflection.Assembly]::LoadFrom((Join-Path $AztecRoot 'AZtecCrystal.exe'))
    $report.native_assemblies=@(AssemblyReport $core; AssemblyReport $assembly)
    [Core.Ebsd.Infrastructure.GlobalSettings]::InBackground=$false
    $report.in_background=[Core.Ebsd.Infrastructure.GlobalSettings]::InBackground
    $report.stage='open_project'
    $project=[Core.Ebsd.Infrastructure.Project]::new($source)
    if ($project.DatasetCount -ne 1) { throw "requires_single_dataset:actual=$($project.DatasetCount)" }
    $dataset=$project.Datasets[0]
    if (-not $dataset.IsPopulated) { $dataset.PopulateData() }
    $report.dataset=@{name=$dataset.Name;width=$dataset.XCount;height=$dataset.YCount;points=$dataset.PixelCount}
    if ($Metric -eq 'IPF') {
        $report.stage='select_saved_IPF_map'
        $maps=@($dataset.Maps.Items | Where-Object {$null -ne $_})
        $report.saved_maps=@($maps | ForEach-Object {@{name=$_.Name;layers=@($_.Items | Where-Object {$null -ne $_} | ForEach-Object {$_.GetType().FullName})}})
        $required=@('Core.Ebsd.EBSDMaps.MapLayerIPF','Core.Ebsd.EBSDMaps.MapLayerBandContrast','Core.Ebsd.EBSDMaps.MapLayerGrainBoundaries')
        $candidates=@($maps | Where-Object {
            $types=@($_.Items | Where-Object {$null -ne $_} | ForEach-Object {$_.GetType().FullName})
            @($required | Where-Object {$types -notcontains $_}).Count -eq 0
        })
        if ($candidates.Count -ne 1) { throw "saved_IPF_BC_GB_map_not_unique:count=$($candidates.Count)" }
        $map=$candidates[0]
        $report.map_source='unique saved map containing IPF, BandContrast and GrainBoundaries'
    } else {
        $report.stage='configure_scalar_layer'
        if ($Metric -eq 'KAM') {
            $settings=[Core.Ebsd.EBSDMaps.MapLayerKAMSettings]::new()
            $settings.KAMSettings.MaskShape=[Core.Ebsd.Common.MaskShape]::Square
            $settings.KAMSettings.MaskSize=[Core.Ebsd.Common.MaskSize]::Size_3x3
            $settings.KAMSettings.MaxAngleDegree=5.0
            $settings.KAMSettings.OnlyPeriphery=$true
            $mapName='KAM'
            $report.calculation=@{mask_shape=[string]$settings.KAMSettings.MaskShape;mask_size=[string]$settings.KAMSettings.MaskSize;max_angle_degree=$settings.KAMSettings.MaxAngleDegree;only_periphery=$settings.KAMSettings.OnlyPeriphery}
        } else {
            $report.stage='populate_native_grains'
            if (-not ('AztecNativeMap.Progress' -as [type])) { Add-Type 'namespace AztecNativeMap { public sealed class Progress : System.IProgress<int> { public void Report(int value) {} } }' }
            $progress=[AztecNativeMap.Progress]::new()
            $grainSizing=$dataset.GrainSizing
            if ($null -eq $grainSizing) { throw 'grain_sizing_missing' }
            $boundarySettings=$grainSizing.Settings.BoundaryMapSettings
            $boundarySettings.ThresholdAngleDegree=10.0
            if ([double]$boundarySettings.ThresholdAngleDegree -ne 10.0) { throw 'boundary_threshold_readback_mismatch' }
            $boundaryMap=[Core.Ebsd.Grains.BoundaryMap]::new($dataset)
            $boundaryMap.Populate($boundarySettings,$progress,[Threading.CancellationTokenSource]::new())
            $grainSizing.GrainMap.Populate($boundaryMap,$progress,[Threading.CancellationTokenSource]::new())
            $grainSizing.Populate()
            $settings=[Core.Ebsd.EBSDMaps.MapLayerGrainOrientationSpreadSettings]::new()
            $parameter=@($settings.AvailableParameters | Where-Object {$_.ToString() -eq 'Mean'})
            if ($parameter.Count -ne 1) { throw 'GOS_Mean_parameter_unavailable' }
            $settings.Parameter=$parameter[0]
            $mapName='OS'
            $report.calculation=@{parameter=[string]$settings.Parameter;boundary_threshold_degree=$boundarySettings.ThresholdAngleDegree;grain_map_populated=$grainSizing.GrainMap.IsPopulated}
        }
        $settings.ColorScaleSettings.ColorScaleType=[Core.Ebsd.ImageProcessing.ColorScaleType]::HeatMap
        $settings.ColorScaleSettings.WithColorGradient=$true
        $settings.ColorScaleSettings.Inverted=$false
        $settings.ColorScaleSettings.StepCount=5
        $limitType=$settings.DataLimitSettings.GetType().GetProperty('DataLimitType').PropertyType
        if ($hasRange) {
            $settings.DataLimitSettings.DataLimitType=[Enum]::Parse($limitType,'UserDefined')
            $settings.DataLimitSettings.LowerLimit=$DisplayMin
            $settings.DataLimitSettings.UpperLimit=$DisplayMax
            if ($settings.DataLimitSettings.DataLimitType.ToString() -ne 'UserDefined' -or
                [double]$settings.DataLimitSettings.LowerLimit -ne $DisplayMin -or [double]$settings.DataLimitSettings.UpperLimit -ne $DisplayMax) { throw 'display_range_settings_readback_mismatch' }
        } else { $settings.DataLimitSettings.DataLimitType=[Enum]::Parse($limitType,'Automatic') }
        $report.stage='construct_native_map'
        $mapSettings=[Core.Ebsd.EBSDMaps.MapSettings]::new($mapName)
        $map=[Core.Ebsd.EBSDMaps.Map]::new($dataset,$mapSettings)
        $layer=$settings.GetMapLayer($dataset)
        $map.AddMapLayer($layer,$true)
        $report.map_source='new native scalar map with native calculation layer'
        $report.map_constructor=[string]$map.GetType().GetConstructors()[0]
    }
    $report.map_name=$map.Name
    # Check the native map dimensions before allocating export or layer bitmaps.
    $exportHeight=[double]$PixelWidth*[double]$map.Height/[double]$map.Width
    if ($map.Width -lt 1 -or $map.Height -lt 1 -or [double]::IsNaN($exportHeight) -or
        [double]::IsInfinity($exportHeight) -or $exportHeight -lt 100 -or
        $exportHeight+70 -gt 16000 -or ([double]$PixelWidth+180)*($exportHeight+70) -gt 64000000) {
        throw 'unsupported_canvas_aspect'
    }
    $report.canvas_guard=@{native_width=$map.Width;native_height=$map.Height;estimated_export_height=$exportHeight;max_dimension=16000;max_pixels=64000000}
    $report.stage='populate_native_layers'
    foreach ($item in @($map.Items | Where-Object {$null -ne $_})) { $item.Populate() }
    $report.stage='populate_native_map'
    $map.PopulateSync()
    $report.layer_states=@($map.Items | Where-Object {$null -ne $_} | ForEach-Object {LayerReport $_})
    if ($Metric -ne 'IPF') {
        if ($null -eq $layer.Values -or $layer.Values.Count -ne $dataset.PixelCount) { throw 'native_scalar_values_not_ready' }
        $report.values_count=$layer.Values.Count
        $limits=$layer.LimitsForDrawing
        if ($null -eq $limits) { throw 'scalar_limits_for_drawing_null' }
        $report.limits_for_drawing=@([double]$limits.Item1,[double]$limits.Item2)
        if ($hasRange -and ([double]$limits.Item1 -ne $DisplayMin -or [double]$limits.Item2 -ne $DisplayMax)) {
            throw "display_range_drawing_readback_mismatch:requested=$DisplayMin,$DisplayMax;actual=$($report.limits_for_drawing -join ',')"
        }
        $report.data_limit_settings=@{type=[string]$settings.DataLimitSettings.DataLimitType;lower=$settings.DataLimitSettings.LowerLimit;upper=$settings.DataLimitSettings.UpperLimit}
        $report.color_settings=@{scale=[string]$settings.ColorScaleSettings.ColorScaleType;gradient=$settings.ColorScaleSettings.WithColorGradient;inverted=$settings.ColorScaleSettings.Inverted;steps=$settings.ColorScaleSettings.StepCount}
        if ($Metric -eq 'GOS') {
            $report.grains=@{grain_list_count=$grainSizing.GrainList.Count;object_count=$grainSizing.GrainMap.ObjectCount}
            if ($grainSizing.GrainList.Count -le 0 -or $grainSizing.GrainList.Count -ne $grainSizing.GrainMap.ObjectCount) { throw 'native_grain_count_mismatch' }
        }
    }
    $report.stage='native_map_viewmodel'
    $vmType=$assembly.GetType('EBSDDataAnalysis.ViewModels.MapViewModel',$true)
    $report.viewmodel_constructor=[string]$vmType.GetConstructors()[0]
    $vm=$vmType.GetConstructors()[0].Invoke([object[]]@($map.PSObject.BaseObject,$null,[double]1,[Windows.Point]::new(0,0)))
    $report.stage='native_map_exporter'
    $export=[Activator]::CreateInstance($assembly.GetType('EBSDDataAnalysis.Export.MapExport',$true))
    $export.MapViewModel=$vm
    $export.Settings.PixelWidth=$PixelWidth
    $export.Settings.ShowPixelLayers=$true
    $export.Settings.ShowBoundaries=$true
    $export.Settings.ShowGrains=$ShowGrains
    $export.Settings.ShowSubsets=$true
    $export.Settings.ShowLegend=$true
    $export.Settings.ShowHeader=$true
    $export.Settings.ShowScaleBar=$false
    $export.Settings.ShowRasterSize=$true
    $export.Settings.ShowStepWidth=$true
    $export.Settings.ShowCoordinateSystem=$true
    $export.Settings.ShowSelectedRecord=$false
    $export.Settings.ShowSelectedGrain=$false
    $export.Settings.ShowInteractiveLineMeasurements=$false
    $report.export_settings_before_bitmap=@{
        PixelWidth=$export.Settings.PixelWidth
        ShowPixelLayers=$export.Settings.ShowPixelLayers
        ShowBoundaries=$export.Settings.ShowBoundaries
        ShowGrains=$export.Settings.ShowGrains
        ShowSubsets=$export.Settings.ShowSubsets
        ShowLegend=$export.Settings.ShowLegend
        ShowHeader=$export.Settings.ShowHeader
        ShowScaleBar=$export.Settings.ShowScaleBar
        ShowRasterSize=$export.Settings.ShowRasterSize
        ShowStepWidth=$export.Settings.ShowStepWidth
        ShowCoordinateSystem=$export.Settings.ShowCoordinateSystem
        ShowSelectedRecord=$export.Settings.ShowSelectedRecord
        ShowSelectedGrain=$export.Settings.ShowSelectedGrain
        ShowInteractiveLineMeasurements=$export.Settings.ShowInteractiveLineMeasurements
    }
    $report.bitmap_property=[string]$export.GetType().GetProperty('BitmapForExport')
    $report.stage='native_map_bitmap'
    $bitmap=$export.GetType().GetProperty('BitmapForExport').GetValue($export,$null)
    if ($null -eq $bitmap) { throw 'native_bitmap_null' }
    $report.width=$bitmap.PixelWidth; $report.height=$bitmap.PixelHeight
    $report.native_pixel_snapshot=PixelSnapshot $bitmap
    $report.stage='native_map_save'
    $target=[IO.Path]::GetFullPath((Join-Path $out ($Metric+'.bmp')))
    $report.target_debug=@{value=[string]$target;type=[string]$target.GetType().FullName;length=([string]$target).Length}
    $report.save_method='AZtec_MapExport.SaveAs'
    try {
        $export.SaveAs($target)
    } catch [ArgumentException] {
        # Some embedded Framework runspaces reject the full path inside the
        # vendor SaveAs helper even though the native BitmapSource is valid.
        # Encode that same native BitmapSource directly and verify pixels below.
        $report.save_method='WpfBmpBitmapEncoder_fallback'
        $encoder=[Windows.Media.Imaging.BmpBitmapEncoder]::new()
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $encoder.Save($stream) } finally { $stream.Dispose() }
    }
    if (-not [IO.File]::Exists($target)) { throw 'native_save_missing' }
    $report.stage='verify_saved_native_pixels'
    $stream=[IO.File]::OpenRead($target)
    try {
        $decoder=[Windows.Media.Imaging.BitmapDecoder]::Create($stream,[Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,[Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
    } finally { $stream.Dispose() }
    $report.saved_pixel_snapshot=PixelSnapshot $decoder.Frames[0]
    $report.saved_pixels_match_native=($report.saved_pixel_snapshot.width -eq $report.width -and
        $report.saved_pixel_snapshot.height -eq $report.height -and
        $report.saved_pixel_snapshot.sha256 -eq $report.native_pixel_snapshot.sha256)
    if (-not $report.saved_pixels_match_native) { throw 'saved_bitmap_disagrees_with_native_pixels' }
    # Composition can update derived export settings, so capture them last.
    $report.export_settings=@($export.Settings | Select-Object *)
    $report.output=$target; $report.sha256=Sha $target; $report.bytes=([IO.FileInfo]::new($target)).Length
    $report.status='native_map_exported'
} catch {
    $report.status='failed'; $report.error=$_.Exception.ToString(); $report.position=$_.ScriptStackTrace
} finally {
    if ($null -ne $before) {
        try {
            $report.after=@{cpr=Sha $source;crc=Sha $crc}
            if ($report.after.cpr -ne $before.cpr -or $report.after.crc -ne $before.crc) { $report.status='input_changed' }
        } catch { $report.status='input_verification_failed'; $report.input_verification_error=$_.Exception.ToString() }
    }
    $applicationType='System.Windows.Application' -as [type]
    $report.application_created=($null -ne $applicationType -and $null -ne $applicationType.GetProperty('Current').GetValue($null,$null))
    $report.finished_utc=[DateTime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText((Join-Path $out 'report.json'),($report | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($true))
}
$report | ConvertTo-Json -Depth 6
# This short-lived STA child owns all native objects and threads. Exit only after
# flushing the artifact report; no project save or vendor shutdown is requested.
[Environment]::Exit($(if ($report.status -eq 'native_map_exported') {0} else {1}))
