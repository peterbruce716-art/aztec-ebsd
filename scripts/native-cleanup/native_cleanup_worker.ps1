param(
    [Parameter(Mandatory=$true)][ValidateSet('clean','readback')][string]$Mode,
    [Parameter(Mandatory=$true)][string]$CprPath,
    [Parameter(Mandatory=$true)][string]$RunDirectory,
    [string]$AztecRoot='C:\Program Files\Oxford Instruments NanoAnalysis\AZtec',
    [ValidateRange(1,50)][int]$MaxZeroCycles=50,
    [ValidateSet('NativeSave','FilteredQuaternion')][string]$PersistencePolicy='NativeSave'
)
$PersistencePolicy=if($PersistencePolicy -eq 'NativeSave'){'NativeSave'}else{'FilteredQuaternion'}
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$source=[IO.Path]::GetFullPath($CprPath)
$run=[IO.Path]::GetFullPath($RunDirectory)
$reportPath=Join-Path $run ($Mode+'-worker.json')
function Write-Json($Path,$Object){[IO.File]::WriteAllText($Path,($Object|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($true))}
function File-Sha256($Path){$h=[Security.Cryptography.SHA256]::Create();$f=[IO.File]::OpenRead($Path);try{return [BitConverter]::ToString($h.ComputeHash($f)).Replace('-','')}finally{$f.Dispose();$h.Dispose()}}
function Geometry($d){
    [ordered]@{points=$d.PixelCount;width=$d.XCount;height=$d.YCount;z=$d.ZCount;t=$d.TCount;step_x=$d.StepSizeMicronX;step_y=$d.StepSizeMicronY;phases=@($d.Phases|ForEach-Object{[ordered]@{name=$_.Name;laue=[string]$_.LaueGroup;a=$_.A;b=$_.B;c=$_.C;alpha=$_.AlphaDeg;beta=$_.BetaDeg;gamma=$_.GammaDeg}})}
}
function Settings-Row($s){
    $row=[ordered]@{native_type=$s.GetType().FullName;description=$s.Description}
    foreach($p in $s.GetType().GetProperties([Reflection.BindingFlags]'Public,Instance')){
        if(-not $p.CanRead -or $p.GetIndexParameters().Length){continue}
        $v=$p.GetValue($s,$null)
        if($null -eq $v -or $v -is [string] -or $v.GetType().IsPrimitive){$row[$p.Name]=$v}
        elseif($v.GetType().IsEnum){$row[$p.Name]=$v.ToString()}
    }
    if($s.GetType().Name -eq 'AutoCleanUpSettings'){$row.sequence=@($s.Sequence|ForEach-Object{Settings-Row $_})}
    if($s.GetType().Name -eq 'ZeroSolutionRemovalSettings'){$row.agreeing_neighbours=8-[int]$s.Level}
    return $row
}
try{
    if($PSVersionTable.PSEdition -ne 'Desktop' -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'requires_framework_sta_worker'}
    if(-not [IO.Directory]::Exists($run)){throw 'run_directory_missing'}
    Set-Location -LiteralPath $AztecRoot
    Get-ChildItem -LiteralPath $AztecRoot -Filter '*.dll' -File|ForEach-Object{try{[void][Reflection.Assembly]::LoadFrom($_.FullName)}catch{}}
    [void][Reflection.Assembly]::LoadFrom((Join-Path $AztecRoot 'core.ebsd.dll'))
    Add-Type -Path (Join-Path $PSScriptRoot 'NativeCleanupSnapshot.cs')
    Add-Type -Path (Join-Path $PSScriptRoot 'NativeOrientationPersistence.cs') -ReferencedAssemblies (Join-Path $AztecRoot 'core.ebsd.dll')
    $project=[Core.Ebsd.Infrastructure.Project]::new($source)
    if($project.DatasetCount -ne 1){throw 'requires_single_dataset'}
    $dataset=$project.Datasets[0]
    if(-not $dataset.IsPopulated){throw 'native_dataset_not_populated'}
    $geometry=Geometry $dataset
    if($dataset.ZCount -ne 1 -or $dataset.TCount -ne 1 -or $dataset.XCount*$dataset.YCount -ne $dataset.PixelCount){throw 'requires_rectangular_2d_grid'}
    $initial=[NativeCleanupSnapshot]::Capture($dataset)
    $initialZero=$dataset.ZeroSolutionCount
    if($Mode -eq 'readback'){
        $expected=[NativeCleanupSnapshot]::Load((Join-Path $run 'expected.snapshot'))
        $worker=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $run 'clean-worker.json')|ConvertFrom-Json
        if($worker.persistence_policy -ne $PersistencePolicy){throw 'readback_persistence_policy_mismatch'}
        $difference=$expected.Compare($initial)
        $geometryMatches=($geometry|ConvertTo-Json -Depth 6 -Compress) -eq ($worker.geometry|ConvertTo-Json -Depth 6 -Compress)
        $matches=$difference -eq '' -and $geometryMatches
        Write-Json $reportPath ([ordered]@{status=if($matches){'readback_verified'}else{'readback_failed'};persistence_policy=$PersistencePolicy;matches_expected=$matches;first_difference=$difference;geometry_matches=$geometryMatches;geometry=$geometry;zero_solutions=$dataset.ZeroSolutionCount;snapshot_sha256=$initial.Hash($false);quality_sha256=$initial.Hash($true);comparison='exact_all_phase_orientation_euler_mad_errorcode_bc_bs_bands_bytes'})
        if(-not $matches){throw ('independent_readback_mismatch:'+$difference)}
        exit 0
    }
    $derived=Join-Path $run 'cleaned.cpr'
    if([IO.File]::Exists($derived) -or [IO.File]::Exists([IO.Path]::ChangeExtension($derived,'.crc'))){throw 'derived_output_exists'}
    $tools=$dataset.DataCleanUp
    $settings=$tools.Settings
    if(@($settings.AutoCleanUpSettings.Sequence).Count -eq 0){throw 'native_autoclean_sequence_empty'}
    foreach($autoSetting in $settings.AutoCleanUpSettings.Sequence){if($autoSetting.GetType().FullName -notin @('Core.Ebsd.DataCleanUp.WildSpikeRemovalSettings','Core.Ebsd.DataCleanUp.ZeroSolutionRemovalSettings')){throw 'unsupported_or_pseudo_autoclean_step'}}
    $settings.ZeroSolutionRemovalSettings.Iterate=$true
    $settings.ZeroSolutionRemovalSettings.MaxIterations=50
    $settings.KuwaharaFilterSettings.FilterType=[Core.Ebsd.DataCleanUp.KuwaharaFilterType]::Quadrants
    $settings.KuwaharaFilterSettings.Radius=3
    $state=@{dataset=$dataset;snapshot=$initial}
    $stages=[Collections.Generic.List[object]]::new()
    function Run-NativeStep($s,[string]$name){
        $configuration=Settings-Row $s
        $step=$s.GetCleanUpStep($tools)
        if($step.GetType().Namespace -ne 'Core.Ebsd.DataCleanUp'){throw 'non_native_cleanup_step'}
        $beforeZero=$state.dataset.ZeroSolutionCount
        $watch=[Diagnostics.Stopwatch]::StartNew()
        $cancel=[Threading.CancellationTokenSource]::new()
        try{$next=$step.Populate($state.dataset,$cancel,($stages.Count -eq 0))}finally{$cancel.Dispose();$watch.Stop()}
        if($null -eq $next){throw ('native_step_returned_null:'+$name)}
        $after=[NativeCleanupSnapshot]::Capture($next)
        $changed=$state.snapshot.ChangedPoints($after,$null)
        $stages.Add([ordered]@{name=$name;status='executed';native_type=$step.GetType().FullName;settings=$configuration;result=[string]$step.Result;pixel_replaced_count=$step.PixelReplacedCount;changed_points=$changed;before_zero=$beforeZero;after_zero=$next.ZeroSolutionCount;snapshot_sha256=$after.Hash($false);intermediate_quality_matches_source=($after.Hash($true) -eq $initial.Hash($true));seconds=$watch.Elapsed.TotalSeconds})
        $state.dataset=$next;$state.snapshot=$after
        Write-Json (Join-Path $run 'stage-progress.json') ([ordered]@{status='running';stages=@($stages.ToArray())})
    }
    $cycles=0
    for($cycle=1;$cycle -le $MaxZeroCycles;$cycle++){
        $cycleBefore=$state.dataset.ZeroSolutionCount
        foreach($level in 0..7){$settings.ZeroSolutionRemovalSettings.Level=$level;Run-NativeStep $settings.ZeroSolutionRemovalSettings ('zero_'+(8-$level))}
        $cycles=$cycle
        if($state.dataset.ZeroSolutionCount -ge $cycleBefore){break}
    }
    Run-NativeStep $settings.WildSpikeRemovalSettings 'wild_spike'
    foreach($pass in 1..5){Run-NativeStep $settings.AutoCleanUpSettings ('auto_'+$pass)}
    Run-NativeStep $settings.KuwaharaFilterSettings 'kuwahara'
    # Audit native intermediate quality differences rather than hiding them.
    # Persistence copies orientations into the original project dataset; its
    # immutable acquisition quality fields must therefore retain source bytes.
    $method=$dataset.GetType().GetMethod('CopyOrientationFromDataset',[Reflection.BindingFlags]'NonPublic,Instance',$null,[Type[]]@([Core.Ebsd.Infrastructure.IDataset]),$null)
    if($null -eq $method){throw 'native_copy_orientation_signature_missing'}
    [void]$method.Invoke($dataset,@($state.dataset))
    $copied=[NativeCleanupSnapshot]::Capture($dataset)
    $copyDifference=$state.snapshot.CompareOrientations($copied)
    if($copyDifference -ne ''){throw ('native_copy_snapshot_mismatch:'+$copyDifference)}
    if($copied.Hash($true) -ne $initial.Hash($true)){throw 'persisted_acquisition_quality_changed'}
    if([Convert]::ToBase64String($initial.Fields['ErrorCode']) -ne [Convert]::ToBase64String($copied.Fields['ErrorCode'])){throw 'copy_changed_source_errorcode'}
    $copied.Save((Join-Path $run 'native-result.snapshot'))
    $conversion=[NativeOrientationPersistence]::Canonicalize($dataset,$PersistencePolicy)
    $normalized=[NativeCleanupSnapshot]::Capture($dataset)
    if($PersistencePolicy -eq 'NativeSave'){
        foreach($field in @('Euler1','Euler2','Euler3')){if([Convert]::ToBase64String($copied.Fields[$field]) -ne [Convert]::ToBase64String($normalized.Fields[$field])){throw 'persistence_changed_native_euler_bytes'}}
    }
    $phaseMadUnchanged=$true
    foreach($field in @('PhaseID','MAD')){if([Convert]::ToBase64String($copied.Fields[$field]) -ne [Convert]::ToBase64String($normalized.Fields[$field])){$phaseMadUnchanged=$false}}
    if(-not $phaseMadUnchanged -or $normalized.Hash($true) -ne $initial.Hash($true)){throw 'persistence_conversion_changed_nonorientation_fields'}
    # CPR saves C5 error bytes; loading decodes those bytes using the new PhaseID.
    # Predict with the native codec in the audit snapshot only. Keep Dataset.ErrorCode
    # unchanged so SaveProjectAs preserves the original C5 provenance bytes.
    if([Convert]::ToBase64String($copied.Fields['ErrorCode']) -ne [Convert]::ToBase64String($normalized.Fields['ErrorCode'])){throw 'conversion_changed_dataset_errorcode'}
    $codecChanged=0
    for($point=0;$point -lt $normalized.Count;$point++){
        $oldCode=$normalized.Fields['ErrorCode'][$point]
        $c5=[Core.Ebsd.Infrastructure.RawData]::ErrorCodesH5OINAToC5([Core.Ebsd.Common.ErrorCode]$oldCode)
        $decoded=[byte][Core.Ebsd.Infrastructure.RawData]::ErrorCodesC5ToH5OINA($normalized.Fields['PhaseID'][$point],$c5)
        if($oldCode -ne $decoded){$codecChanged++}
        $normalized.Fields['ErrorCode'][$point]=$decoded
    }
    $normalization=[ordered]@{method=$conversion.Operation;native_result_snapshot_sha256=$copied.Hash($false);normalized_snapshot_sha256=$normalized.Hash($false);phase_mad_unchanged=$phaseMadUnchanged;acquisition_quality_unchanged=($normalized.Hash($true) -eq $initial.Hash($true));audit=$conversion;errorcode_codec=[ordered]@{method='RawData.ErrorCodesH5OINAToC5_then_ErrorCodesC5ToH5OINA(final_PhaseID)';changed_points=$codecChanged;dataset_errorcode_unchanged=$true}} 
    $copied=$normalized
    $copied.Save((Join-Path $run 'expected.snapshot'))
    $changedTotal=$initial.ChangedPoints($copied,(Join-Path $run 'point-provenance.mask'))
    $project.SaveProjectAs($derived)
    Write-Json $reportPath ([ordered]@{status='native_saved_pending_independent_readback';persistence_policy=$PersistencePolicy;recipe='aztec-native-8to1-50-wild-auto5-quadrants3-v1';pseudo_symmetry='excluded_by_user';native_version=[Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $AztecRoot 'AZtecCrystal.exe')).FileVersion;core_sha256=(File-Sha256 (Join-Path $AztecRoot 'core.ebsd.dll'));geometry=$geometry;zero_cycles_run=$cycles;zero_cycle_limit=$MaxZeroCycles;stages=@($stages.ToArray());before_zero=$initialZero;after_zero=$state.dataset.ZeroSolutionCount;changed_points=$changedTotal;source_snapshot_sha256=$initial.Hash($false);expected_snapshot_sha256=$copied.Hash($false);quality_before=$initial.Hash($true);quality_after=$copied.Hash($true);derived=$derived;normalization=$normalization;provenance=[ordered]@{format='row-major one byte per point; bit0=any recorded field changed, bit1=original phase0 now indexed';donor_source='not_exposed_by_native_step';quality_fields_audited=@('BandContrast','BandSlope','NumberOfBands');errorcode_audit='native_C5_bytes_preserved_and_phase_dependent_decode_predicted';native_mutable_fields_audited=@('PhaseID','Orientation.X1..X4','Euler1','Euler2','Euler3','MAD');unavailable_fields=@('reliability_not_exposed_as_dataset_field')}})
}catch{
    Write-Json (Join-Path $run ($Mode+'-failure.json')) ([ordered]@{status='failed';error=$_.Exception.Message;type=$_.Exception.GetType().FullName;line=$_.InvocationInfo.ScriptLineNumber})
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
# Do not dispose Project: this AZtec version has a teardown exception path.
# The short-lived Framework process releases native resources on exit.
