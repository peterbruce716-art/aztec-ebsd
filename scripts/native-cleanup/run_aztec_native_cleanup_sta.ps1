param(
    [Parameter(Mandatory=$true)][string]$CprPath,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [ValidateRange(30,3600)][int]$StageTimeoutSeconds=3600,
    [ValidateRange(1,50)][int]$MaxZeroCycles=50,
    [ValidateSet('NativeSave','FilteredQuaternion')][string]$PersistencePolicy='NativeSave',
    [ValidateSet('Strict','Fast')][string]$AuditMode='Fast',
    [ValidateRange(1,50)][int]$ProgressCheckpointEvery=8,
    [string]$SkillRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..')),
    [string]$AztecRoot='C:\Program Files\Oxford Instruments NanoAnalysis\AZtec'
)
$PersistencePolicy=if($PersistencePolicy -eq 'NativeSave'){'NativeSave'}else{'FilteredQuaternion'}
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Core'){throw 'requires_powershell_7_core'}
$source=(Resolve-Path -LiteralPath $CprPath).Path
$crc=[IO.Path]::ChangeExtension($source,'.crc')
if([IO.Path]::GetExtension($source) -ine '.cpr' -or -not [IO.File]::Exists($crc)){throw 'requires_cpr_and_matching_crc'}
$header=[IO.File]::ReadAllText($source)
$fields=@([regex]::Matches($header,'(?m)^Field\d+=(\d+)\r?$')|ForEach-Object {$_.Groups[1].Value})
if(($fields -join ',') -ne '3,4,5,6,7,8,10,11,12'){throw 'unsupported_crc_field_schema'}
$pointsMatch=[regex]::Match($header,'(?m)^NoOfPoints=(\d+)\r?$')
$xMatch=[regex]::Match($header,'(?m)^xCells=(\d+)\r?$')
$yMatch=[regex]::Match($header,'(?m)^yCells=(\d+)\r?$')
if(-not $pointsMatch.Success -or -not $xMatch.Success -or -not $yMatch.Success){throw 'cpr_geometry_header_missing'}
$declaredPoints=[int64]$pointsMatch.Groups[1].Value
$xCells=[int64]$xMatch.Groups[1].Value
$yCells=[int64]$yMatch.Groups[1].Value
$crcBytes=(Get-Item -LiteralPath $crc).Length
if($declaredPoints -ne ($xCells*$yCells)){throw ('cpr_geometry_mismatch:points=' + $declaredPoints + ';grid=' + ($xCells*$yCells))}
if($crcBytes -ne ($declaredPoints*25)){throw ('cpr_crc_length_mismatch:expected=' + ($declaredPoints*25) + ';actual=' + $crcBytes)}
function ErrorCode-BytesHash($Path){
    $bytes=[IO.File]::ReadAllBytes($Path)
    if($bytes.Length -eq 0 -or $bytes.Length%25 -ne 0){throw 'unsupported_crc_record_length'}
    $codes=[byte[]]::new($bytes.Length/25)
    for($i=0;$i -lt $codes.Length;$i++){$codes[$i]=$bytes[$i*25+20]}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return [BitConverter]::ToString($sha.ComputeHash($codes)).Replace('-','')}finally{$sha.Dispose()}
}
$sourceErrorHash=ErrorCode-BytesHash $crc
$output=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
if(Test-Path -LiteralPath $output){throw 'output_directory_must_not_exist'}
$cleanupRoot=Join-Path $SkillRoot 'scripts/native-cleanup'
$localScriptRoot=Split-Path -Parent $PSCommandPath
$worker=Join-Path $localScriptRoot 'native_cleanup_worker_optimized.ps1'
$snapshot=Join-Path $localScriptRoot 'NativeCleanupSnapshotOptimized.cs'
$orientation=Join-Path $localScriptRoot 'NativeOrientationPersistenceOptimized.cs'
$verify=Join-Path $localScriptRoot 'verify_aztec_native_cleanup_run_optimized.ps1'
$framework=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
foreach($file in @($worker,$snapshot,$orientation,$verify,$framework,(Join-Path $AztecRoot 'core.ebsd.dll'))){if(-not [IO.File]::Exists($file)){throw ('required_file_missing:'+$file)}}
$version=[Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $AztecRoot 'AZtecCrystal.exe')).FileVersion
if($version -ne '5.1.7829.1'){throw ('unvalidated_aztec_version:'+$version)}
$probe="if (`$PSVersionTable.PSEdition -ne 'Desktop') { exit 21 }; if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) { exit 22 }; exit 0"
$encodedProbe=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
$probeProcess=Start-Process -FilePath $framework -ArgumentList @('-NoProfile','-STA','-EncodedCommand',$encodedProbe) -WindowStyle Hidden -PassThru -Wait
if($probeProcess.ExitCode -ne 0){throw ('framework_sta_preflight_failed:exit=' + $probeProcess.ExitCode + ';expected=Desktop|STA')}
$sourceBefore=(Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash
$crcBefore=(Get-FileHash -Algorithm SHA256 -LiteralPath $crc).Hash
[void][IO.Directory]::CreateDirectory($output)
function Write-Json($path,$object){[IO.File]::WriteAllText($path,($object|ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($true))}
function Read-LogTail([string]$path,[int]$lines=40){
    if(-not [IO.File]::Exists($path)){return $null}
    try{return ((Get-Content -LiteralPath $path -Tail $lines -ErrorAction Stop) -join "`n")}catch{return $null}
}
function Invoke-Worker([string]$mode,[string]$inputCpr){
    # The child must validate its actual execution thread; launch flags alone
    # do not guarantee that the Framework worker runs in STA.
    $quote = { param([string]$value) "'" + ($value -replace "'", "''") + "'" }
    $command = '& ' + (& $quote $worker) +
        ' -Mode ' + (& $quote $mode) +
        ' -CprPath ' + (& $quote $inputCpr) +
        ' -RunDirectory ' + (& $quote $output) +
        ' -AztecRoot ' + (& $quote $AztecRoot) +
        ' -MaxZeroCycles ' + [string]$MaxZeroCycles +
        ' -PersistencePolicy ' + (& $quote $PersistencePolicy) +
        ' -AuditMode ' + (& $quote $AuditMode) +
        ' -ProgressCheckpointEvery ' + [string]$ProgressCheckpointEvery
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $stdoutPath=Join-Path $output ($mode+'.stdout.log')
    $stderrPath=Join-Path $output ($mode+'.stderr.log')
    $arguments=@('-NoProfile','-STA','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
    $process=$null
    try{
        $process=Start-Process -FilePath $framework -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $finished=$process.WaitForExit($StageTimeoutSeconds*1000)
        if(-not $finished){$process.Kill($true);if(-not $process.WaitForExit(10000)){throw 'worker_termination_unconfirmed'}}
        if(-not $finished){throw ('worker_timeout:'+$mode)}
        if($process.ExitCode -ne 0){
            $diagnostic=[ordered]@{
                mode=$mode
                exit_code=$process.ExitCode
                stdout_path=$stdoutPath
                stderr_path=$stderrPath
                stdout_tail=(Read-LogTail $stdoutPath)
                stderr_tail=(Read-LogTail $stderrPath)
            }
            $diagnosticPath=Join-Path $output ($mode+'-failure-diagnostic.json')
            Write-Json $diagnosticPath $diagnostic
            throw ('worker_failed:'+$mode+'; diagnostic='+$diagnosticPath)
        }
    }finally{if($null -ne $process){$process.Dispose()}}
}
try{
    Invoke-Worker 'clean' $source
    $clean=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $output 'clean-worker.json')|ConvertFrom-Json
    $derived=Join-Path $output 'cleaned.cpr'
    $derivedCrc=[IO.Path]::ChangeExtension($derived,'.crc')
    if(-not [IO.File]::Exists($derived) -or -not [IO.File]::Exists($derivedCrc)){throw 'derived_cpr_crc_missing'}
    $derivedHash=(Get-FileHash -Algorithm SHA256 -LiteralPath $derived).Hash
    $derivedCrcHash=(Get-FileHash -Algorithm SHA256 -LiteralPath $derivedCrc).Hash
    Invoke-Worker 'readback' $derived
    $readback=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $output 'readback-worker.json')|ConvertFrom-Json
    $unchanged=(Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash -eq $sourceBefore -and (Get-FileHash -Algorithm SHA256 -LiteralPath $crc).Hash -eq $crcBefore
    if(-not $unchanged){throw 'source_pair_changed'}
    if((Get-FileHash -Algorithm SHA256 -LiteralPath $derived).Hash -ne $derivedHash -or (Get-FileHash -Algorithm SHA256 -LiteralPath $derivedCrc).Hash -ne $derivedCrcHash){throw 'derived_pair_changed_during_readback'}
    $derivedErrorHash=ErrorCode-BytesHash $derivedCrc
    $semanticErrorcodeUnchanged = ($clean.normalization.errorcode_codec.dataset_errorcode_unchanged -eq $true)
    $serializedErrorcodeUnchanged = ($derivedErrorHash -eq $sourceErrorHash)
    if(-not $semanticErrorcodeUnchanged){throw 'semantic_errorcode_bytes_changed'}
    $quality=$clean.quality_before -eq $clean.quality_after -and $clean.quality_after -eq $readback.quality_sha256
    if(-not $quality -or -not $readback.matches_expected){throw 'independent_readback_gate_failed'}
    $files=@(Get-ChildItem -LiteralPath $output -File|ForEach-Object{[ordered]@{path=$_.FullName;bytes=$_.Length;sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash}})
    $report=[ordered]@{status='pending_native_cleanup_contract';audit_mode=$AuditMode;progress_checkpoint_every=$ProgressCheckpointEvery;persistence_policy=$PersistencePolicy;source=$source;source_cpr_sha256=$sourceBefore;source_crc_sha256=$crcBefore;source_unchanged=$unchanged;quality_unchanged=$quality;serialized_errorcode=[ordered]@{schema='3,4,5,6,7,8,10,11,12';record_bytes=25;errorcode_offset=20;source_c5_sha256=$sourceErrorHash;derived_c5_sha256=$derivedErrorHash;unchanged=$serializedErrorcodeUnchanged;serialized_unchanged=$serializedErrorcodeUnchanged;semantic_unchanged=$semanticErrorcodeUnchanged;serialization_warning=if($serializedErrorcodeUnchanged){$null}else{'phase_dependent_c5_reencoding'};accepted_by='semantic_errorcode_unchanged_and_independent_readback'};worker=$clean;readback=$readback;output_files=$files}
    Write-Json (Join-Path $output 'cleanup-report.json') $report
    & $verify -RunDirectory $output -PendingReport
    if(-not $?){throw 'cleanup_contract_failed'}
    $report.status='complete_native_cleanup_readback_verified'
    Write-Json (Join-Path $output 'cleanup-report.json') $report
    exit 0
}catch{
    $sourceUnchanged=[IO.File]::Exists($source) -and [IO.File]::Exists($crc) -and (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash -eq $sourceBefore -and (Get-FileHash -Algorithm SHA256 -LiteralPath $crc).Hash -eq $crcBefore
    $diagnostics=@(Get-ChildItem -LiteralPath $output -Filter '*-failure-diagnostic.json' -File -ErrorAction SilentlyContinue | ForEach-Object {$_.FullName})
    Write-Json (Join-Path $output 'cleanup-failure.json') ([ordered]@{status='failed';error=$_.Exception.Message;source_unchanged=$sourceUnchanged;diagnostic_files=$diagnostics})
    throw
}
