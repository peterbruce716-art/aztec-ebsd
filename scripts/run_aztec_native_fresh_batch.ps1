param(
    [Parameter(Mandatory=$true)][string]$InputRoot,
    [string[]]$ExcludeDirectoryName = @(),
    [string]$ExcludeFileRegex = '(?i)codex_backup|(^|_)cleaned\.cpr$',
    [ValidateRange(1,10)][int]$MaxConcurrency = 10,
    [ValidateRange(1,2)][int]$CleanupConcurrency = 2,
    [ValidateRange(0,100000)][int]$Limit = 0,
    [string]$RunId = (Get-Date -Format 'yyyyMMdd_HHmmss'),
    [ValidateRange(30,3600)][int]$StageTimeoutSeconds = 3600,
    [switch]$DryRun,
    [string]$SkillRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Core') { throw 'requires_powershell_7_core' }
if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'run_id_must_be_path_safe' }
$sourceRoot = (Resolve-Path -LiteralPath $InputRoot).Path.TrimEnd([IO.Path]::DirectorySeparatorChar)
$cleanupRunner = Join-Path $SkillRoot 'scripts/native-cleanup/run_aztec_native_cleanup.ps1'
$cleanupVerifier = Join-Path $SkillRoot 'scripts/native-cleanup/verify_aztec_native_cleanup_run_optimized.ps1'
$exporter = Join-Path $SkillRoot 'assets/aztec-native-toolchain/03_tools/aztec_exporter/AZtecBmpExporter.exe'
$toolchainVerifier = Join-Path $SkillRoot 'scripts/verify-toolchain.ps1'
foreach ($path in @($cleanupRunner,$cleanupVerifier,$exporter,$toolchainVerifier)) {
    if (-not [IO.File]::Exists($path)) { throw "required_tool_missing:$path" }
}
$toolchainResult = (& $toolchainVerifier | Out-String) | ConvertFrom-Json
if ($toolchainResult.status -ne 'passed' -or -not $toolchainResult.environment.framework_sta_worker_passed) {
    throw 'toolchain_or_framework_sta_preflight_failed'
}

$excludedNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($name in $ExcludeDirectoryName) { [void]$excludedNames.Add($name) }
$candidates = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Filter '*.cpr' -ErrorAction Stop |
    Where-Object {
        $relative = $_.FullName.Substring($sourceRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
        $segments = $relative.Split([IO.Path]::DirectorySeparatorChar)
        $excludedPath = $false
        foreach ($segment in $segments[0..([Math]::Max(0,$segments.Length-2))]) {
            if ($excludedNames.Contains($segment) -or $segment -match '(?i)^AZtec_v7_fresh_') { $excludedPath = $true; break }
        }
        -not $excludedPath -and $_.Name -notmatch $ExcludeFileRegex
    } | Sort-Object FullName)
if ($Limit -gt 0) { $candidates = @($candidates | Select-Object -First $Limit) }

$runRootName = 'AZtec_v7_fresh_' + $RunId
$runLog = Join-Path $sourceRoot ('.aztec_fresh_batch_logs\' + $RunId)
if (Test-Path -LiteralPath $runLog) { throw "run_log_directory_exists:$runLog" }
$targets = @($candidates | ForEach-Object { Join-Path $_.DirectoryName ($runRootName + '\' + $_.BaseName) })
$existing = @($targets | Where-Object { Test-Path -LiteralPath $_ })
if ($existing.Count -gt 0) { throw "fresh_output_target_exists:$($existing[0])" }
if ($DryRun) {
    [pscustomobject]@{
        status = 'dry_run'
        source_root = $sourceRoot
        run_id = $RunId
        candidates = $candidates.Count
        paired = @($candidates | Where-Object { Test-Path -LiteralPath ([IO.Path]::ChangeExtension($_.FullName,'.crc')) }).Count
        skipped_missing_crc = @($candidates | Where-Object { -not (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($_.FullName,'.crc'))) }).Count
        existing_targets = $existing.Count
        old_results_reused = $false
        output_directories_created = $false
    } | ConvertTo-Json -Compress
    return
}
[void][IO.Directory]::CreateDirectory($runLog)
$summaryPath = Join-Path $runLog 'batch-results.jsonl'

Write-Output (([ordered]@{
    status='started'
    source_root=$sourceRoot
    run_id=$RunId
    candidates=$candidates.Count
    max_concurrency=$MaxConcurrency
    cleanup_concurrency=$CleanupConcurrency
    old_results_reused=$false
    output_root_name=$runRootName
    summary_path=$summaryPath
} | ConvertTo-Json -Compress))

try {
$candidates | ForEach-Object -Parallel {
    $ErrorActionPreference = 'Stop'
    $source = $_.FullName
    $crc = [IO.Path]::ChangeExtension($source,'.crc')
    $sampleRoot = Join-Path $_.DirectoryName ($using:runRootName + '\' + $_.BaseName)
    $cleanupDir = Join-Path $sampleRoot 'cleanup'
    $mapsDir = Join-Path $sampleRoot 'maps'
    $row = [ordered]@{source=$source;crc=$crc;status='pending';old_results_reused=$false;cleanup_directory=$cleanupDir;maps_directory=$mapsDir;error=$null}
    try {
        [void][IO.Directory]::CreateDirectory($sampleRoot)
        [IO.File]::WriteAllText((Join-Path $sampleRoot 'fresh-batch-state.json'),([ordered]@{status='running';source=$source;crc=$crc;started_utc=[DateTime]::UtcNow.ToString('o');run_id=$using:runId}|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($true))
        if (-not [IO.File]::Exists($crc)) { $row.status='skipped_missing_crc'; throw 'matching_crc_missing' }
        $sourceCprHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash
        $sourceCrcHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $crc).Hash

        $cleanupSlot = [Threading.Semaphore]::new($using:CleanupConcurrency,$using:CleanupConcurrency,'Global\AztecEbsdNativeCleanupSlots')
        $heldCleanup = $false
        try {
            $heldCleanup = $cleanupSlot.WaitOne([TimeSpan]::FromHours(12))
            if (-not $heldCleanup) { throw 'native_cleanup_slot_timeout' }
            if (Test-Path -LiteralPath $cleanupDir) { throw 'fresh_cleanup_directory_already_exists' }
            & $using:cleanupRunner -CprPath $source -OutputDirectory $cleanupDir -PersistencePolicy NativeSave -AuditMode Fast -MaxZeroCycles 50 -StageTimeoutSeconds $using:StageTimeoutSeconds | Out-Null
        } finally {
            if ($heldCleanup) { [void]$cleanupSlot.Release() }
            $cleanupSlot.Dispose()
        }

        $cleanupReportPath = Join-Path $cleanupDir 'cleanup-report.json'
        if (-not [IO.File]::Exists($cleanupReportPath)) { throw 'cleanup_report_missing' }
        $cleanupReport = Get-Content -Raw -Encoding UTF8 -LiteralPath $cleanupReportPath | ConvertFrom-Json
        if ($cleanupReport.status -ne 'complete_native_cleanup_readback_verified') { throw 'cleanup_report_not_verified' }
        if ($cleanupReport.worker.final_zero_solution_count -ne 0) { throw 'final_zero_solutions_not_zero' }
        if ($cleanupReport.readback.zero_solutions -ne 0) { throw 'readback_zero_solutions_not_zero' }
        if ($cleanupReport.source_unchanged -ne $true) { throw 'source_pair_changed_during_cleanup' }
        $verifyText = (& $using:cleanupVerifier -RunDirectory $cleanupDir | Out-String)
        $verifyResult = $verifyText | ConvertFrom-Json
        if ($verifyResult.status -ne 'passed' -or $verifyResult.independent_readback -ne $true) { throw 'independent_cleanup_verifier_failed' }
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash -ne $sourceCprHash -or
            (Get-FileHash -Algorithm SHA256 -LiteralPath $crc).Hash -ne $sourceCrcHash) { throw 'source_pair_hash_changed' }

        $cleanedCpr = Join-Path $cleanupDir 'cleaned.cpr'
        $cleanedCrc = [IO.Path]::ChangeExtension($cleanedCpr,'.crc')
        if (-not [IO.File]::Exists($cleanedCpr) -or -not [IO.File]::Exists($cleanedCrc)) { throw 'verified_cleaned_pair_missing' }
        $expectedCrcHash = [string]$cleanupReport.worker.serialized_errorcode.derived_c5_sha256
        if (-not $expectedCrcHash) { $expectedCrcHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $cleanedCrc).Hash }

        $exportMutex = [Threading.Mutex]::new($false,'Global\AztecEbsdNativeBmpExporter')
        $heldExport = $false
        try {
            $heldExport = $exportMutex.WaitOne([TimeSpan]::FromHours(12))
            if (-not $heldExport) { throw 'native_export_mutex_timeout' }
            if (Test-Path -LiteralPath $mapsDir) { throw 'fresh_maps_directory_already_exists' }
            & $using:exporter --input $cleanedCpr --output $mapsDir --types ALL --template native-v1 --expected-crc-sha256 $expectedCrcHash *> $null
            $exportExit = $LASTEXITCODE
        } finally {
            if ($heldExport) { [void]$exportMutex.ReleaseMutex() }
            $exportMutex.Dispose()
        }

        $manifestPath = Join-Path $mapsDir 'render_manifest.json'
        if (-not [IO.File]::Exists($manifestPath)) { throw "render_manifest_missing:exit=$exportExit" }
        $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
        if ($manifest.status -ne 'completed') { throw "render_manifest_not_completed:exit=$exportExit" }
        if ([IO.Path]::GetFullPath([string]$manifest.input) -ne [IO.Path]::GetFullPath($cleanedCpr)) { throw 'maps_not_exported_from_fresh_cleaned_cpr' }
        $verifiedTypes = [Collections.Generic.List[string]]::new()
        foreach ($type in @('IPF','KAM','GOS')) {
            $entry = @($manifest.outputs | Where-Object type -eq $type)
            if ($entry.Count -ne 1 -or $entry[0].status -ne 'completed') { throw "native_map_invalid:$type" }
            $bmp = Join-Path $mapsDir ($type + '.bmp')
            if (-not [IO.File]::Exists($bmp) -or (Get-FileHash -Algorithm SHA256 -LiteralPath $bmp).Hash -ne $entry[0].sha256) { throw "native_map_hash_mismatch:$type" }
            if (-not $entry[0].native_report) { throw "native_report_missing:$type" }
            $nativeReport = Get-Content -Raw -Encoding UTF8 -LiteralPath $entry[0].native_report | ConvertFrom-Json
            if ($nativeReport.saved_pixels_match_native -ne $true) { throw "saved_pixels_not_verified:$type" }
            $verifiedTypes.Add($type)
        }
        $row.status='completed'
        $row.cleanup_status=$cleanupReport.status
        $row.final_zero_solutions=[int]$cleanupReport.worker.final_zero_solution_count
        $row.readback_zero_solutions=[int]$cleanupReport.readback.zero_solutions
        $row.cleanup_report=$cleanupReportPath
        $row.cleanup_verifier=$verifyResult
        $row.render_manifest=$manifestPath
        $row.map_types=@($verifiedTypes)
        $row.map_files=@('IPF.bmp','KAM.bmp','GOS.bmp')
        $row.exporter_exit_code=$exportExit
        if ($exportExit -ne 0) { $row.export_warning='nonzero_exit_but_manifest_and_map_hashes_passed' }
        $row.source_cpr_sha256=$sourceCprHash
        $row.source_crc_sha256=$sourceCrcHash
    } catch {
        if ($row.status -ne 'skipped_missing_crc') { $row.status='failed' }
        $row.error=$_.Exception.Message
    }
    [IO.File]::WriteAllText((Join-Path $sampleRoot 'fresh-batch-state.json'),([ordered]@{status=$row.status;source=$source;crc=$crc;finished_utc=[DateTime]::UtcNow.ToString('o');error=$row.error;cleanup_directory=$cleanupDir;maps_directory=$mapsDir}|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($true))
    $resultPath = Join-Path $sampleRoot 'fresh-batch-result.json'
    [IO.File]::WriteAllText($resultPath,($row|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($true))
    [pscustomobject]$row
} -ThrottleLimit $MaxConcurrency | ForEach-Object {
    $line = $_ | ConvertTo-Json -Depth 12 -Compress
    [IO.File]::AppendAllText($summaryPath,$line+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
    Write-Output $line
}
} catch {
    $interruptedPath = Join-Path $runLog 'batch-interrupted.json'
    $interrupted = [ordered]@{
        status = 'interrupted'
        source_root = $sourceRoot
        run_id = $RunId
        candidates = $candidates.Count
        recorded_results = if (Test-Path -LiteralPath $summaryPath) { @(Get-Content -Encoding UTF8 -LiteralPath $summaryPath | Where-Object { $_.Trim() }).Count } else { 0 }
        error = $_.Exception.Message
        utc = [DateTime]::UtcNow.ToString('o')
        old_results_reused = $false
    }
    [IO.File]::WriteAllText($interruptedPath,($interrupted|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($true))
    throw
}

$rows = @(Get-Content -Encoding UTF8 -LiteralPath $summaryPath | ForEach-Object { if ($_.Trim()) { $_ | ConvertFrom-Json } })
$summary = [ordered]@{
    status = if (@($rows | Where-Object status -ne 'completed').Count -eq 0) { 'completed' } else { 'completed_with_failures_or_skips' }
    candidates = $candidates.Count
    completed = @($rows | Where-Object status -eq 'completed').Count
    failed = @($rows | Where-Object status -eq 'failed').Count
    skipped_missing_crc = @($rows | Where-Object status -eq 'skipped_missing_crc').Count
    unrecorded = $candidates.Count - $rows.Count
    final_zero_solutions_nonzero = @($rows | Where-Object { $_.status -eq 'completed' -and ($_.final_zero_solutions -ne 0 -or $_.readback_zero_solutions -ne 0) }).Count
    old_results_reused = $false
    summary_path = $summaryPath
}
$summaryPathJson = Join-Path $runLog 'batch-summary.json'
[IO.File]::WriteAllText($summaryPathJson,($summary|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($true))
$summary | ConvertTo-Json -Depth 8
