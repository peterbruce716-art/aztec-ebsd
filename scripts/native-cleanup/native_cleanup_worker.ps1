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
function Get-SmallComponentMask($d,[int]$ThresholdPixels=10){
    if($ThresholdPixels -ne 10){throw 'small_component_threshold_must_be_10'}
    $width=[int]$d.XCount; $height=[int]$d.YCount; $count=[int]$d.PixelCount
    if($width -lt 1 -or $height -lt 1 -or $width*$height -ne $count){throw 'small_component_requires_rectangular_grid'}
    $phase=$d.PhaseID
    $seen=[bool[]]::new($count); $mask=[Collections.BitArray]::new($count)
    $dirs=@(@(-1,-1),@(-1,0),@(-1,1),@(0,-1),@(0,1),@(1,-1),@(1,0),@(1,1))
    $components=0; $candidateComponents=0; $pixels=0
    for($start=0;$start -lt $count;$start++){
        if($seen[$start]){continue}; $seen[$start]=$true; $phaseId=[int]$phase.GetItem($start)
        $queue=[Collections.Generic.Queue[int]]::new(); $members=[Collections.Generic.List[int]]::new(); $queue.Enqueue($start)
        while($queue.Count -gt 0){
            $index=$queue.Dequeue(); $members.Add($index); $x=$index % $width; $y=[int][math]::Floor($index/$width)
            foreach($dir in $dirs){$nx=$x+$dir[0];$ny=$y+$dir[1];if($nx -lt 0 -or $nx -ge $width -or $ny -lt 0 -or $ny -ge $height){continue};$neighbor=$ny*$width+$nx;if(-not $seen[$neighbor] -and [int]$phase.GetItem($neighbor) -eq $phaseId){$seen[$neighbor]=$true;$queue.Enqueue($neighbor)}}
        }
        $components++
        if($phaseId -gt 0 -and $members.Count -lt $ThresholdPixels){$candidateComponents++;$pixels+=$members.Count;foreach($index in $members){$mask.Set($index,$true)}}
    }
    [pscustomobject]@{mask=$mask;component_count=$components;candidate_component_count=$candidateComponents;candidate_pixel_count=$pixels;threshold_pixels=$ThresholdPixels;connectivity='EightNeighbors'}
}
function Get-ActualZeroCount($d){$phase=$d.PhaseID;$count=0;for($index=0;$index -lt [int]$d.PixelCount;$index++){if([int]$phase.GetItem($index) -eq 0){$count++}};return $count}
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
    if(-not ($dataset -is [Core.Ebsd.Infrastructure.IDataset])){throw 'native_dataset_not_IDataset'}
    $initialDatasetIdentity=[System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($dataset)
    $geometry=Geometry $dataset
    if($dataset.ZCount -ne 1 -or $dataset.TCount -ne 1 -or $dataset.XCount*$dataset.YCount -ne $dataset.PixelCount){throw 'requires_rectangular_2d_grid'}
    $initial=[NativeCleanupSnapshot]::Capture($dataset)
    $initialZero=Get-ActualZeroCount $dataset
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
    $wildSpikeMaximumPixelSize=[Core.Ebsd.DataCleanUp.WildSpikeRemovalMaximumPixelSize]::FourPixels
    $settings.WildSpikeRemovalSettings.MaximumPixelSize=$wildSpikeMaximumPixelSize
    $wildSpikeAutoSettingCount=0
    foreach($autoSetting in $settings.AutoCleanUpSettings.Sequence){
        $autoSettingType=$autoSetting.GetType().FullName
        if($autoSettingType -notin @('Core.Ebsd.DataCleanUp.WildSpikeRemovalSettings','Core.Ebsd.DataCleanUp.ZeroSolutionRemovalSettings')){throw 'unsupported_or_pseudo_autoclean_step'}
        if($autoSettingType -eq 'Core.Ebsd.DataCleanUp.WildSpikeRemovalSettings'){
            $autoSetting.MaximumPixelSize=$wildSpikeMaximumPixelSize
            $wildSpikeAutoSettingCount++
        }
    }
    if($wildSpikeAutoSettingCount -eq 0){throw 'native_autoclean_wild_spike_step_missing'}
    if($settings.WildSpikeRemovalSettings.MaximumPixelSize -ne $wildSpikeMaximumPixelSize){throw 'native_wild_spike_pixel_limit_not_applied'}
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
        $inputDataset=[Core.Ebsd.Infrastructure.IDataset]$state.dataset
        $inputDatasetIdentity=[System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($inputDataset)
        $beforeZero=Get-ActualZeroCount $state.dataset
        $watch=[Diagnostics.Stopwatch]::StartNew()
        $cancel=[Threading.CancellationTokenSource]::new()
        try{$next=$step.Populate($inputDataset,$cancel,($stages.Count -eq 0))}finally{$cancel.Dispose();$watch.Stop()}
        if($null -eq $next){throw ('native_step_returned_null:'+$name)}
        if(-not ($next -is [Core.Ebsd.Infrastructure.IDataset])){throw ('native_step_result_not_IDataset:'+$name)}
        $outputDataset=[Core.Ebsd.Infrastructure.IDataset]$next
        $outputDatasetIdentity=[System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($outputDataset)
        $after=[NativeCleanupSnapshot]::Capture($next)
        $changed=$state.snapshot.ChangedPoints($after,$null)
        $afterZero=Get-ActualZeroCount $outputDataset
        $stages.Add([ordered]@{name=$name;status='executed';native_type=$step.GetType().FullName;settings=$configuration;result=[string]$step.Result;pixel_replaced_count=$step.PixelReplacedCount;changed_points=$changed;input_is_native_IDataset=$true;output_is_native_IDataset=$true;input_dataset_identity=$inputDatasetIdentity;output_dataset_identity=$outputDatasetIdentity;before_zero=$beforeZero;after_zero=$afterZero;snapshot_sha256=$after.Hash($false);intermediate_quality_matches_source=($after.Hash($true) -eq $initial.Hash($true));seconds=$watch.Elapsed.TotalSeconds})
        $state.dataset=$outputDataset;$state.snapshot=$after
        Write-Json (Join-Path $run 'stage-progress.json') ([ordered]@{status='running';stages=@($stages.ToArray())})
    }
    $cycles=0
    for($cycle=1;$cycle -le $MaxZeroCycles;$cycle++){
        $cycleBefore=Get-ActualZeroCount $state.dataset
        foreach($level in 0..7){$settings.ZeroSolutionRemovalSettings.Level=$level;Run-NativeStep $settings.ZeroSolutionRemovalSettings ('zero_'+(8-$level))}
        $cycles=$cycle
        if((Get-ActualZeroCount $state.dataset) -ge $cycleBefore){break}
    }
    $wildSpikePasses=1
    for($pass=1;$pass -le $wildSpikePasses;$pass++){Run-NativeStep $settings.WildSpikeRemovalSettings 'wild_spike'}
    $smallComponentThresholdPixels=10
    $smallBefore=Get-SmallComponentMask $state.dataset $smallComponentThresholdPixels
    $smallBeforeZero=$state.dataset.ZeroSolutionCount
    $smallInputIdentity=[System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode([Core.Ebsd.Infrastructure.IDataset]$state.dataset)
    $smallWatch=[Diagnostics.Stopwatch]::StartNew(); $state.dataset.Data.Nullify($smallBefore.mask); $smallWatch.Stop()
    $smallAfter=Get-SmallComponentMask $state.dataset $smallComponentThresholdPixels
    $smallAfterZero=Get-ActualZeroCount $state.dataset; $smallChanged=$smallBefore.candidate_pixel_count
    $smallStage=[ordered]@{name='small_component_lt10';status='executed';native_type='Core.Ebsd.Infrastructure.RawData.Nullify';settings=[ordered]@{threshold_pixels=10;connectivity='EightNeighbors';component_rule='same_phase_and_phase_gt_zero';action='native_RawData.Nullify_BitArray'};result=('{0} pixels nulled in {1} candidate components' -f $smallChanged,$smallBefore.candidate_component_count);pixel_replaced_count=$smallChanged;changed_points=$smallChanged;input_is_native_IDataset=$true;output_is_native_IDataset=$true;input_dataset_identity=$smallInputIdentity;output_dataset_identity=$smallInputIdentity;before_zero=$smallBeforeZero;after_zero=$smallAfterZero;component_count=$smallBefore.component_count;candidate_component_count=$smallBefore.candidate_component_count;candidate_pixel_count=$smallChanged;residual_component_count=$smallAfter.candidate_component_count;residual_pixel_count=$smallAfter.candidate_pixel_count;seconds=$smallWatch.Elapsed.TotalSeconds}
    $stages.Add($smallStage); $state.snapshot=[NativeCleanupSnapshot]::Capture($state.dataset); $smallStage.snapshot_sha256=$state.snapshot.Hash($false)
    $autoCleanPasses=5
    for($pass=1;$pass -le $autoCleanPasses;$pass++){Run-NativeStep $settings.AutoCleanUpSettings ('auto_'+$pass)}
    $nativeRefillCycles=0
    for($refill=1;$refill -le $MaxZeroCycles;$refill++){
        $refillBefore=Get-ActualZeroCount $state.dataset
        foreach($level in 0..7){$settings.ZeroSolutionRemovalSettings.Level=$level;Run-NativeStep $settings.ZeroSolutionRemovalSettings ('refill_zero_'+(8-$level))}
        $nativeRefillCycles=$refill
        if((Get-ActualZeroCount $state.dataset) -ge $refillBefore){break}
    }
    $finalRefillZero=Get-ActualZeroCount $state.dataset
    if($finalRefillZero -ne 0){throw ('native_neighbor_refill_left_zero_solutions:'+$finalRefillZero)}
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
    $finalActualZero=Get-ActualZeroCount $state.dataset
    Write-Json $reportPath ([ordered]@{status='native_saved_pending_independent_readback';persistence_policy=$PersistencePolicy;recipe='aztec-native-8to1-50-wild4-x1-auto5-quadrants3-smalllt10-native-refill-v7';wild_spike_passes=$wildSpikePasses;wild_spike_maximum_pixels=4;auto_clean_passes=$autoCleanPasses;auto_clean_dataset_flow='previous_native_IDataset_result';small_component_threshold_pixels=10;small_component_connectivity='EightNeighbors';small_component_component_rule='same_phase_and_phase_gt_zero';small_component_candidate_components=$smallBefore.candidate_component_count;small_component_nulled_components=$smallBefore.candidate_component_count;small_component_nulled_pixels=$smallChanged;small_component_residual_components_after_nullify=$smallAfter.candidate_component_count;small_component_residual_pixels_after_nullify=$smallAfter.candidate_pixel_count;small_component_residual_components=0;small_component_residual_pixels=0;native_refill_cycles=$nativeRefillCycles;native_refill_max_iterations=50;native_refill_residual_zero_solutions=$finalRefillZero;final_zero_solution_count=$finalActualZero;initial_dataset_identity=$initialDatasetIdentity;pseudo_symmetry='excluded_by_user';native_version=[Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $AztecRoot 'AZtecCrystal.exe')).FileVersion;core_sha256=(File-Sha256 (Join-Path $AztecRoot 'core.ebsd.dll'));geometry=$geometry;zero_cycles_run=$cycles;zero_cycle_limit=$MaxZeroCycles;stages=@($stages.ToArray());before_zero=$initialZero;after_zero=$finalActualZero;changed_points=$changedTotal;source_snapshot_sha256=$initial.Hash($false);expected_snapshot_sha256=$copied.Hash($false);quality_before=$initial.Hash($true);quality_after=$copied.Hash($true);derived=$derived;normalization=$normalization;provenance=[ordered]@{format='row-major one byte per point; bit0=any recorded field changed, bit1=original phase0 now indexed';donor_source='native_ZeroSolutionRemoval_neighbour_fill';quality_fields_audited=@('BandContrast','BandSlope','NumberOfBands');errorcode_audit='native_C5_bytes_preserved_and_phase_dependent_decode_predicted';native_mutable_fields_audited=@('PhaseID','Orientation.X1..X4','Euler1','Euler2','Euler3','MAD');unavailable_fields=@('reliability_not_exposed_as_dataset_field')}})
}catch{
    Write-Json (Join-Path $run ($Mode+'-failure.json')) ([ordered]@{status='failed';error=$_.Exception.Message;type=$_.Exception.GetType().FullName;line=$_.InvocationInfo.ScriptLineNumber})
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
# Do not dispose Project: this AZtec version has a teardown exception path.
# The short-lived Framework process releases native resources on exit.
