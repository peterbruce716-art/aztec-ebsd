param(
    [Parameter(Mandatory=$true)] $Layer,
    [Parameter(Mandatory=$true)] $Dataset,
    [Parameter(Mandatory=$true)] $GrainSizing,
    [Parameter(Mandatory=$true)] $BoundaryMap,
    [Parameter(Mandatory=$true)][string] $LegacyCsv,
    [Parameter(Mandatory=$true)][string] $OutputDirectory,
    [double] $LegacyDisplayMin=0,
    [Parameter(Mandatory=$true)][double] $LegacyDisplayMax
)
$ErrorActionPreference='Stop'
if($Layer.Settings.Parameter.ToString() -ne 'Mean'){throw 'pixel_audit_supports_mean_only'}
$out=[IO.Path]::GetFullPath($OutputDirectory)
$legacy=(Resolve-Path -LiteralPath $LegacyCsv).Path
if(Test-Path -LiteralPath (Join-Path $out 'point_audit.csv')){throw 'refusing_existing_pixel_audit'}
[IO.Directory]::CreateDirectory($out)|Out-Null
$observation=[ordered]@{HasPublicIsPopulated=($null -ne $Layer.GetType().GetProperty('IsPopulated'));ValuesNull=($null -eq $Layer.Values);ValuesCount=$Layer.Values.Count;LimitsNull=($null -eq $Layer.LimitsForDrawing);SettingsType=$Layer.Settings.GetType().FullName;DataLimits=@($Layer.Settings.DataLimitSettings|Select-Object *);Color=@($Layer.Settings.ColorScaleSettings|Select-Object *)}
$observationPath=Join-Path $out ('initialization_observation_'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfff')+'.json')
if(Test-Path -LiteralPath $observationPath){throw 'initialization_observation_exists'}
[IO.File]::WriteAllText($observationPath,($observation|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($true))
if($null -eq $Layer.Values -or $null -eq $Layer.LimitsForDrawing){throw ('native_layer_not_ready:'+($observation|ConvertTo-Json -Depth 3 -Compress))}
if($Layer.Values.Count -ne $Dataset.PixelCount){throw 'native_values_count_mismatch'}
if($LegacyDisplayMax -le $LegacyDisplayMin){throw 'invalid_legacy_range'}
[IO.Directory]::CreateDirectory($out)|Out-Null
Add-Type -AssemblyName System.Drawing
if(-not ('AztecNativeGosPixelAudit' -as [type])){
    Add-Type -Path (Join-Path $PSScriptRoot 'AztecNativeGosPixelAudit.cs') -ReferencedAssemblies 'System.Drawing.dll','System.Core.dll'
}
function Read-Settings($s){
    $r=[ordered]@{}
    foreach($name in @('ColorScaleType','Inverted','WithColorGradient','StepCount','DataLimitType','LowerLimit','UpperLimit')){
        if($null -ne $s.PSObject.Properties[$name]){$r[$name]=[string]$s.$name}
    }
    $r
}
$settings=$Layer.Settings
$limits=$Layer.LimitsForDrawing
$hashAlgorithm=[Security.Cryptography.SHA256]::Create()
$hashStream=[IO.File]::OpenRead($legacy)
try{$legacyHash=([BitConverter]::ToString($hashAlgorithm.ComputeHash($hashStream))).Replace('-','')}
finally{$hashStream.Dispose();$hashAlgorithm.Dispose()}
$existing=@()
foreach($map in @($Dataset.Maps.Items)){
    if($null -eq $map){continue}
    foreach($candidate in @($map.Layers.Items)){
        if($null -ne $candidate -and -not [object]::ReferenceEquals($candidate,$Layer) -and $candidate.GetType().Name -eq 'MapLayerGrainOrientationSpread'){
            $existing+=@{MapName=$map.Name;Type=$candidate.GetType().FullName;Color=(Read-Settings $candidate.Settings.ColorScaleSettings);Limits=(Read-Settings $candidate.Settings.DataLimitSettings)}
        }
    }
}
$counts=[AztecNativeGosPixelAudit]::Run($Layer,$Dataset,$GrainSizing,$BoundaryMap,$legacy,$out,$LegacyDisplayMin,$LegacyDisplayMax)
$meta=[ordered]@{
    status='native_float_getvalue_getpixel_audited';width=[int]$Dataset.XCount;height=[int]$Dataset.YCount;points=[int]$Dataset.PixelCount
    native_layer_type=$Layer.GetType().FullName;native_values_type=$Layer.Values.GetType().FullName
    getpixel_signature=$Layer.GetType().GetMethod('GetPixel',[type[]]@([int])).ToString()
    getvalue_signature=$Layer.GetType().GetMethod('GetValue',[type[]]@([int])).ToString()
    limits_for_drawing=@([double]$limits.Item1,[double]$limits.Item2)
    native_color_settings=(Read-Settings $settings.ColorScaleSettings)
    native_data_limit_settings=(Read-Settings $settings.DataLimitSettings)
    selected_phases=@($settings.IsPhaseSelected)
    legacy_limits=@($LegacyDisplayMin,$LegacyDisplayMax);legacy_csv=$legacy;legacy_csv_sha256=$legacyHash
    counts=$counts;other_existing_gos_layers=$existing
    limits_provenance='Actual newly populated native Mean GOS layer; not independently recovered saved golden-map settings.'
    semantic_display='PhaseId=0, invalid grain or null GetPixel -> white, tracked separately from native GetPixel.'
    reference_pixels_used=$false;gui_started=$false;mtex_used=$false;pillow_used=$false
    bitmap_encoder='AZtec BitmapTools.IntArrayToBitmap/Save';source_index='CPR x-fastest; every GetIndex(x,y) checked at runtime'
}
[IO.File]::WriteAllText((Join-Path $out 'native_pixel_audit.json'),($meta|ConvertTo-Json -Depth 9),[Text.UTF8Encoding]::new($true))
$meta
