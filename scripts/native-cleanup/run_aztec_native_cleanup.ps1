param(
    [Parameter(Mandatory=$true)][string]$CprPath,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [ValidateRange(30,3600)][int]$StageTimeoutSeconds=900,
    [ValidateRange(1,50)][int]$MaxZeroCycles=50,
    [ValidateSet('NativeSave','FilteredQuaternion')][string]$PersistencePolicy='NativeSave',
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
$worker=Join-Path $PSScriptRoot 'native_cleanup_worker.ps1'
$snapshot=Join-Path $PSScriptRoot 'NativeCleanupSnapshot.cs'
$verify=Join-Path $PSScriptRoot 'verify_aztec_native_cleanup_run.ps1'
$framework=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
foreach($file in @($worker,$snapshot,(Join-Path $PSScriptRoot 'NativeOrientationPersistence.cs'),$verify,$framework,(Join-Path $AztecRoot 'core.ebsd.dll'))){if(-not [IO.File]::Exists($file)){throw ('required_file_missing:'+$file)}}
$version=[Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $AztecRoot 'AZtecCrystal.exe')).FileVersion
if($version -ne '5.1.7829.1'){throw ('unvalidated_aztec_version:'+$version)}
$sourceBefore=(Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash
$crcBefore=(Get-FileHash -Algorithm SHA256 -LiteralPath $crc).Hash
[void][IO.Directory]::CreateDirectory($output)
function Write-Json($path,$object){[IO.File]::WriteAllText($path,($object|ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($true))}
function Invoke-Worker([string]$mode,[string]$inputCpr){
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$framework;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($arg in @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$worker,'-Mode',$mode,'-CprPath',$inputCpr,'-RunDirectory',$output,'-AztecRoot',$AztecRoot,'-MaxZeroCycles',[string]$MaxZeroCycles,'-PersistencePolicy',$PersistencePolicy)){$start.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    try{
        if(-not $process.Start()){throw ('worker_start_failed:'+$mode)}
        $outTask=$process.StandardOutput.ReadToEndAsync();$errTask=$process.StandardError.ReadToEndAsync()
        $finished=$process.WaitForExit($StageTimeoutSeconds*1000)
        if(-not $finished){$process.Kill($true);if(-not $process.WaitForExit(10000)){throw 'worker_termination_unconfirmed'}}
        [IO.File]::WriteAllText((Join-Path $output ($mode+'.stdout.log')),$outTask.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($true))
        [IO.File]::WriteAllText((Join-Path $output ($mode+'.stderr.log')),$errTask.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($true))
        if(-not $finished){throw ('worker_timeout:'+$mode)}
        if($process.ExitCode -ne 0){throw ('worker_failed:'+$mode+'; see '+$output)}
    }finally{$process.Dispose()}
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
    if($derivedErrorHash -ne $sourceErrorHash){throw 'serialized_c5_errorcode_bytes_changed'}
    $quality=$clean.quality_before -eq $clean.quality_after -and $clean.quality_after -eq $readback.quality_sha256
    if(-not $quality -or -not $readback.matches_expected){throw 'independent_readback_gate_failed'}
    $files=@(Get-ChildItem -LiteralPath $output -File|ForEach-Object{[ordered]@{path=$_.FullName;bytes=$_.Length;sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash}})
    $report=[ordered]@{status='pending_native_cleanup_contract';persistence_policy=$PersistencePolicy;source=$source;source_cpr_sha256=$sourceBefore;source_crc_sha256=$crcBefore;source_unchanged=$unchanged;quality_unchanged=$quality;serialized_errorcode=[ordered]@{schema='3,4,5,6,7,8,10,11,12';record_bytes=25;errorcode_offset=20;source_c5_sha256=$sourceErrorHash;derived_c5_sha256=$derivedErrorHash;unchanged=($sourceErrorHash -eq $derivedErrorHash)};worker=$clean;readback=$readback;output_files=$files}
    Write-Json (Join-Path $output 'cleanup-report.json') $report
    & $verify -RunDirectory $output -PendingReport
    if(-not $?){throw 'cleanup_contract_failed'}
    $report.status='complete_native_cleanup_readback_verified'
    Write-Json (Join-Path $output 'cleanup-report.json') $report
}catch{
    $sourceUnchanged=[IO.File]::Exists($source) -and [IO.File]::Exists($crc) -and (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash -eq $sourceBefore -and (Get-FileHash -Algorithm SHA256 -LiteralPath $crc).Hash -eq $crcBefore
    Write-Json (Join-Path $output 'cleanup-failure.json') ([ordered]@{status='failed';error=$_.Exception.Message;source_unchanged=$sourceUnchanged})
    throw
}
