param([Parameter(Mandatory=$true)][string]$RunDirectory,[switch]$PendingReport)
$ErrorActionPreference='Stop'
$run=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RunDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar)
$report=Join-Path $run 'cleanup-report.json'
if(-not [IO.File]::Exists($report)){throw 'complete_native_cleanup_report_missing'}
$r=Get-Content -Raw -Encoding UTF8 -LiteralPath $report|ConvertFrom-Json
$requiredStatus=if($PendingReport){'pending_native_cleanup_contract'}else{'complete_native_cleanup_readback_verified'}
if($r.status -ne $requiredStatus){throw 'native_cleanup_incomplete'}
if($r.worker.status -ne 'native_saved_pending_independent_readback' -or $r.readback.status -ne 'readback_verified'){throw 'worker_status_invalid'}
foreach($hash in @($r.source_cpr_sha256,$r.source_crc_sha256,$r.worker.core_sha256,$r.worker.source_snapshot_sha256,$r.worker.expected_snapshot_sha256,$r.worker.quality_before,$r.worker.quality_after,$r.readback.snapshot_sha256,$r.readback.quality_sha256)){if($hash -notmatch '^[A-Fa-f0-9]{64}$'){throw 'required_sha256_invalid'}}
$cycles=[int]$r.worker.zero_cycles_run
if($cycles -lt 1 -or $r.worker.zero_cycle_limit -lt 1 -or $cycles -gt $r.worker.zero_cycle_limit -or $r.worker.zero_cycle_limit -gt 50){throw 'zero_cycle_limit_invalid'}
$expected=@()
foreach($cycle in 1..$cycles){$expected+=@('zero_8','zero_7','zero_6','zero_5','zero_4','zero_3','zero_2','zero_1')}
$expected+=@('wild_spike','auto_1','auto_2','auto_3','auto_4','auto_5','kuwahara')
if(@($r.worker.stages).Count -ne $expected.Count){throw 'native_stage_count_mismatch'}
$levels=@('EightNeighbors','SevenNeighbors','SixNeighbors','FiveNeighbors','FourNeighbors','ThreeNeighbors','TwoNeighbors','OneNeighbor')
$previousZero=$r.worker.before_zero
for($i=0;$i -lt $expected.Count;$i++){
 $s=$r.worker.stages[$i]
 $kind=if($i -lt 8*$cycles){'ZeroSolutionRemoval'}elseif($s.name -eq 'wild_spike'){'WildSpikeRemoval'}elseif($s.name -like 'auto_*'){'AutoCleanUp'}else{'KuwaharaFilter'}
 if($s.name -ne $expected[$i] -or $s.status -ne 'executed' -or $s.native_type -ne ('Core.Ebsd.DataCleanUp.'+$kind+'Step') -or $s.settings.native_type -ne ('Core.Ebsd.DataCleanUp.'+$kind+'Settings')){throw "stage_contract_failed:$i"}
 if($null -eq $s.before_zero -or $null -eq $s.after_zero -or $s.before_zero -lt 0 -or $s.after_zero -lt 0 -or $s.before_zero -ne $previousZero){throw "stage_chain_failed:$i"}
 $stageHash = if($r.worker.audit_mode -eq 'Strict'){$s.snapshot_sha256}else{$s.stage_record_sha256}
 if($stageHash -notmatch '^[A-Fa-f0-9]{64}$'){throw "stage_sha256_invalid:$i"}
 $previousZero=$s.after_zero
 if($i -lt 8*$cycles){
  if($s.settings.Iterate -ne $true -or $s.settings.MaxIterations -ne 50 -or $s.settings.agreeing_neighbours -ne (8-($i%8)) -or $s.settings.Level -ne $levels[$i%8]){throw 'zero_stage_settings_failed'}
  if($s.after_zero -gt $s.before_zero){throw 'zero_stage_increased_zero_count'}
 }
 if($kind -eq 'AutoCleanUp'){
  $sequence=@($s.settings.sequence)
  if($sequence.Count -eq 0){throw 'native_autoclean_sequence_empty'}
  foreach($entry in $sequence){if($entry.native_type -notin @('Core.Ebsd.DataCleanUp.WildSpikeRemovalSettings','Core.Ebsd.DataCleanUp.ZeroSolutionRemovalSettings')){throw 'unapproved_autoclean_sequence_step'}}
 }
}
for($cycle=0;$cycle -lt $cycles;$cycle++){
 $first=$r.worker.stages[8*$cycle];$lastZero=$r.worker.stages[8*$cycle+7]
 if($cycle -lt $cycles-1 -and $lastZero.after_zero -ge $first.before_zero){throw 'zero_cycles_continued_after_plateau'}
 if($cycle -eq $cycles-1 -and $cycles -lt $r.worker.zero_cycle_limit -and $lastZero.after_zero -lt $first.before_zero){throw 'zero_cycles_stopped_before_plateau'}
}
$last=$r.worker.stages[-1]
if($last.settings.Radius -ne 3 -or $last.settings.FilterType -ne 'Quadrants'){throw 'filter_settings_failed'}
if($previousZero -ne $r.worker.after_zero -or $previousZero -ne $r.readback.zero_solutions){throw 'final_zero_count_mismatch'}
if($r.worker.pseudo_symmetry -ne 'excluded_by_user' -or $r.readback.matches_expected -ne $true -or $r.readback.geometry_matches -ne $true -or $r.source_unchanged -ne $true -or $r.quality_unchanged -ne $true -or $r.worker.quality_before -ne $r.worker.quality_after -or $r.worker.quality_after -ne $r.readback.quality_sha256 -or $r.worker.expected_snapshot_sha256 -ne $r.readback.snapshot_sha256){throw 'persistence_gate_failed'}
$normal=$r.worker.normalization
$policy=$r.persistence_policy
if($policy -notin @('NativeSave','FilteredQuaternion') -or $r.worker.persistence_policy -ne $policy -or $r.readback.persistence_policy -ne $policy -or $normal.audit.PersistencePolicy -ne $policy){throw 'persistence_policy_contract_failed'}
$operation=if($policy -eq 'NativeSave'){'native_single_euler_preserved_then_rawdata_updatedata'}else{'native_unit_quaternion_to_single_euler_then_rawdata_updatedata'}
$reference=if($policy -eq 'NativeSave'){'native_serialized_single_euler_prediction'}else{'native_filtered_quaternion'}
if($normal.method -ne $operation -or $normal.audit.Operation -ne $normal.method -or $normal.audit.PrecisionReference -ne $reference -or $normal.phase_mad_unchanged -ne $true -or $normal.acquisition_quality_unchanged -ne $true -or $normal.audit.Points -ne $r.worker.geometry.points -or $normal.normalized_snapshot_sha256 -ne $r.worker.expected_snapshot_sha256){throw 'normalization_contract_failed'}
foreach($hash in @($normal.native_result_snapshot_sha256,$normal.normalized_snapshot_sha256,$normal.audit.OrientationEulerSha256Before,$normal.audit.OrientationEulerSha256After,$normal.audit.EulerSha256Before,$normal.audit.EulerSha256After)){if($hash -notmatch '^[A-Fa-f0-9]{64}$'){throw 'normalization_sha256_invalid'}}
if($normal.audit.EulerBytesPreserved -ne ($normal.audit.EulerSha256Before -eq $normal.audit.EulerSha256After)){throw 'euler_preservation_report_inconsistent'}
if($policy -eq 'NativeSave' -and ($normal.audit.EulerBytesPreserved -ne $true -or $normal.audit.ChangedEulerPoints -ne 0 -or $normal.audit.MaxEulerDifferenceRadians -ne 0)){throw 'native_save_euler_preservation_failed'}
foreach($field in @('PhaseZeroPoints','ChangedEulerPoints','ChangedQuaternionPoints','QuaternionSignFlips')){if($null -eq $normal.audit.$field -or $normal.audit.$field -lt 0 -or $normal.audit.$field -gt $normal.audit.Points){throw 'normalization_count_invalid'}}
$componentDifference=[double]$normal.audit.MaxSignAlignedComponentDifference
if($null -eq $normal.audit.MaxSignAlignedComponentDifference -or $normal.audit.ComponentLimit -ne 1e-5 -or [double]::IsNaN($componentDifference) -or [double]::IsInfinity($componentDifference) -or $componentDifference -lt 0 -or $componentDifference -gt $normal.audit.ComponentLimit){throw 'normalization_precision_gate_failed'}
foreach($field in @('MaxRawComponentDifference','MaxQuaternionNormErrorBefore','MaxQuaternionNormErrorAfter','MaxEulerDifferenceRadians','MaxFilteredToSavedSignAlignedComponentDifference','MaxFilteredToSavedRawComponentDifference')){
 $value=[double]$normal.audit.$field
 if($null -eq $normal.audit.$field -or [double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -lt 0){throw ('normalization_numeric_audit_invalid:'+$field)}
}
if($policy -eq 'FilteredQuaternion' -and $normal.audit.MaxFilteredToSavedSignAlignedComponentDifference -ne $normal.audit.MaxSignAlignedComponentDifference){throw 'filtered_precision_reference_mismatch'}
$sourceCrc=[IO.Path]::ChangeExtension($r.source,'.crc')
if(-not [IO.File]::Exists($r.source) -or -not [IO.File]::Exists($sourceCrc) -or (Get-FileHash -Algorithm SHA256 -LiteralPath $r.source).Hash -ne $r.source_cpr_sha256 -or (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceCrc).Hash -ne $r.source_crc_sha256){throw 'source_pair_changed'}
$codec=$normal.errorcode_codec
if($codec.method -ne 'RawData.ErrorCodesH5OINAToC5_then_ErrorCodesC5ToH5OINA(final_PhaseID)' -or $codec.dataset_errorcode_unchanged -ne $true -or $null -eq $codec.changed_points -or $codec.changed_points -lt 0 -or $codec.changed_points -gt $r.worker.geometry.points){throw 'errorcode_codec_contract_failed'}
$serialized=$r.serialized_errorcode
if($serialized.schema -ne '3,4,5,6,7,8,10,11,12' -or $serialized.record_bytes -ne 25 -or $serialized.errorcode_offset -ne 20 -or $serialized.unchanged -ne $true -or $serialized.source_c5_sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or $serialized.source_c5_sha256 -ne $serialized.derived_c5_sha256){throw 'serialized_errorcode_contract_failed'}
foreach($pair in @(@($sourceCrc,$serialized.source_c5_sha256),@((Join-Path $run 'cleaned.crc'),$serialized.derived_c5_sha256))){
 $bytes=[IO.File]::ReadAllBytes($pair[0])
 if($bytes.Length -ne $r.worker.geometry.points*25){throw 'crc_record_count_mismatch'}
 $codes=[byte[]]::new($r.worker.geometry.points)
 for($i=0;$i -lt $codes.Length;$i++){$codes[$i]=$bytes[25*$i+20]}
 $sha=[Security.Cryptography.SHA256]::Create()
 try{$hash=[BitConverter]::ToString($sha.ComputeHash($codes)).Replace('-','')}finally{$sha.Dispose()}
 if($hash -ne $pair[1]){throw 'serialized_errorcode_hash_failed'}
}
$manifest=@{}
foreach($f in $r.output_files){
 $path=[IO.Path]::GetFullPath($f.path)
 if(-not [string]::Equals([IO.Path]::GetDirectoryName($path),$run,[StringComparison]::OrdinalIgnoreCase) -or $manifest.ContainsKey($path)){throw 'output_manifest_path_invalid'}
 if(-not [IO.File]::Exists($path) -or (Get-Item -LiteralPath $path).Length -ne $f.bytes -or (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash -ne $f.sha256){throw 'output_file_hash_mismatch'}
 $manifest[$path]=$true
}
foreach($name in @('cleaned.cpr','cleaned.crc','native-result.snapshot','expected.snapshot','point-provenance.mask','clean-worker.json','readback-worker.json','stage-progress.json','clean.stdout.log','clean.stderr.log','readback.stdout.log','readback.stderr.log')){if(-not $manifest.ContainsKey((Join-Path $run $name))){throw ('required_output_hash_missing:'+$name)}}
$progressLogPath=Join-Path $run 'stage-progress.jsonl'
$hasProgressLog=[IO.File]::Exists($progressLogPath)
if($r.worker.progress_log -eq 'stage-progress.jsonl' -and -not $hasProgressLog){throw 'stage_progress_log_missing'}
if($r.worker.progress_log -eq 'stage-progress.jsonl' -and -not $manifest.ContainsKey($progressLogPath)){throw 'stage_progress_log_hash_missing'}
if($r.worker.geometry.points -lt 1 -or (Get-Item -LiteralPath (Join-Path $run 'point-provenance.mask')).Length -ne $r.worker.geometry.points){throw 'provenance_mask_length_invalid'}
if(-not ('NativeCleanupSnapshot' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'NativeCleanupSnapshotOptimized.cs')}
$nativeSnapshot=[NativeCleanupSnapshot]::Load((Join-Path $run 'native-result.snapshot'))
$expectedSnapshot=[NativeCleanupSnapshot]::Load((Join-Path $run 'expected.snapshot'))
if($nativeSnapshot.Count -ne $r.worker.geometry.points -or $expectedSnapshot.Count -ne $nativeSnapshot.Count -or $nativeSnapshot.Hash($false) -ne $normal.native_result_snapshot_sha256 -or $expectedSnapshot.Hash($false) -ne $normal.normalized_snapshot_sha256 -or $nativeSnapshot.Hash($true) -ne $r.worker.quality_before -or $expectedSnapshot.Hash($true) -ne $r.worker.quality_before){throw 'normalization_snapshot_mismatch'}
$mask=[IO.File]::ReadAllBytes((Join-Path $run 'point-provenance.mask'))
$maskChanged=0
for($i=0;$i -lt $mask.Length;$i++){
 if($mask[$i] -ne 0 -and $mask[$i] -ne 1 -and $mask[$i] -ne 3){throw ('provenance_mask_bits_invalid:'+$i)}
 if(($mask[$i] -band 1) -ne 0){$maskChanged++}
 if(($mask[$i] -band 2) -ne 0 -and $expectedSnapshot.Fields['PhaseID'][$i] -eq 0){throw ('provenance_filled_point_not_indexed:'+$i)}
}
if($null -eq $r.worker.changed_points -or $r.worker.changed_points -ne $maskChanged){throw 'provenance_changed_point_count_mismatch'}
foreach($field in @('PhaseID','MAD')){if([Convert]::ToBase64String($nativeSnapshot.Fields[$field]) -ne [Convert]::ToBase64String($expectedSnapshot.Fields[$field])){throw 'normalization_changed_phase_or_mad'}}
if($policy -eq 'NativeSave'){
 foreach($field in @('Euler1','Euler2','Euler3')){if([Convert]::ToBase64String($nativeSnapshot.Fields[$field]) -ne [Convert]::ToBase64String($expectedSnapshot.Fields[$field])){throw 'native_save_changed_native_euler_bytes'}}
}
$savedWorker=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $run 'clean-worker.json')|ConvertFrom-Json
$savedReadback=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $run 'readback-worker.json')|ConvertFrom-Json
if(($savedWorker|ConvertTo-Json -Depth 15 -Compress) -ne ($r.worker|ConvertTo-Json -Depth 15 -Compress) -or ($savedReadback|ConvertTo-Json -Depth 15 -Compress) -ne ($r.readback|ConvertTo-Json -Depth 15 -Compress)){throw 'report_worker_artifact_mismatch'}
$progress=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $run 'stage-progress.json')|ConvertFrom-Json
# Strict mode stores the full stage list. Fast mode stores a compact checkpoint;
# the complete worker report remains the authoritative full stage evidence.
if($progress.status -notin @('running','complete')){throw 'stage_progress_status_invalid'}
if($r.worker.audit_mode -eq 'Strict'){
 if(($progress.stages|ConvertTo-Json -Depth 15 -Compress) -ne ($r.worker.stages|ConvertTo-Json -Depth 15 -Compress)){throw 'stage_progress_contract_failed'}
}else{
 if($progress.audit_mode -ne 'Fast' -or $progress.completed_stage_count -ne @($r.worker.stages).Count){throw 'fast_stage_progress_count_failed'}
 $lastStage=$r.worker.stages[-1]
 if($progress.last_stage -ne $lastStage.name -or $progress.last_stage_sha256 -ne $lastStage.stage_record_sha256 -or $progress.zero_solutions -ne $lastStage.after_zero){throw 'fast_stage_progress_checkpoint_failed'}
}
if($hasProgressLog){
 $events=@(Get-Content -Encoding UTF8 -LiteralPath $progressLogPath | Where-Object {$_.Trim()} | ForEach-Object {$_|ConvertFrom-Json})
 if(@($events|Where-Object event -eq 'run_started').Count -ne 1 -or @($events|Where-Object event -eq 'run_completed').Count -ne 1){throw 'stage_progress_log_lifecycle_invalid'}
 $stageEvents=@($events|Where-Object event -eq 'stage'|Sort-Object index)
 if($stageEvents.Count -ne @($r.worker.stages).Count){throw 'stage_progress_log_count_invalid'}
 for($i=0;$i -lt $stageEvents.Count;$i++){
  if($stageEvents[$i].index -ne ($i+1)){throw "stage_progress_log_index_invalid:$i"}
  if(($stageEvents[$i].stage|ConvertTo-Json -Depth 15 -Compress) -ne ($r.worker.stages[$i]|ConvertTo-Json -Depth 15 -Compress)){throw "stage_progress_log_stage_mismatch:$i"}
 }
}
[pscustomobject]@{status='passed';native_stages=$expected.Count;zero_cycles=$cycles;source_unchanged=$true;independent_readback=$true}|ConvertTo-Json
