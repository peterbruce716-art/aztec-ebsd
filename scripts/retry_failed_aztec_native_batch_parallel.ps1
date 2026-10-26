param(
    [string]$Workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')),
    [string]$OriginalStatusPath = '',
    [string]$RetryStatusPath = '',
    [int]$Limit = 0,
    [ValidateRange(30,3600)][int]$StageTimeoutSeconds = 3600,
    [ValidateSet('Strict','Fast')][string]$AuditMode = 'Fast',
    [ValidateRange(1,10)][int]$MaxConcurrency = 10,
    [ValidateRange(1,10)][int]$CleanupConcurrency = 2,
    [ValidateRange(1,5)][int]$WorkerAttempts = 3,
    [ValidateRange(1,50)][int]$ProgressCheckpointEvery = 8,
    [switch]$DryRun,
    [switch]$FailedOnly,
    [switch]$IncludeInputPairMismatch,
    [string]$CorruptedManifestPath = '',
    [switch]$IncludeRawDataCorrupted,
    [switch]$AllowHighConcurrency,
    [switch]$WorkerMode,
    [string]$WorkerSource,
    [string]$WorkerResultPath,
    [int]$WorkerRetryIndex = 0,
    [int]$WorkerOriginalIndex = 0
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Core') { throw 'requires_powershell_7_core' }
. (Join-Path $PSScriptRoot 'parallel-resource-policy.ps1')
if ($AllowHighConcurrency) { Write-Warning 'AllowHighConcurrency is retained for compatibility; resource headroom controls the effective concurrency.' }
if (-not $DryRun) {
    $frameworkHost = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
    if (-not [IO.File]::Exists($frameworkHost)) { throw 'framework_sta_host_missing' }
    $probe = "if (`$PSVersionTable.PSEdition -ne 'Desktop') { exit 21 }; if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) { exit 22 }; exit 0"
    $encodedProbe = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
    $probeInfo=[Diagnostics.ProcessStartInfo]::new();$probeInfo.FileName=$frameworkHost;$probeInfo.UseShellExecute=$false;$probeInfo.CreateNoWindow=$true
    foreach($argument in @('-NoProfile','-STA','-EncodedCommand',$encodedProbe)){[void]$probeInfo.ArgumentList.Add($argument)}
    $probeProcess=[Diagnostics.Process]::new();$probeProcess.StartInfo=$probeInfo
    if(-not $probeProcess.Start()){throw 'framework_sta_probe_start_failed'}
    $probeProcess.WaitForExit();$probeExit=$probeProcess.ExitCode;$probeProcess.Dispose()
    if ($probeExit -ne 0) {
        throw ('framework_sta_preflight_failed:exit={0};expected=Desktop|STA' -f $probeProcess.ExitCode)
    }
}
$workspacePath = (Resolve-Path -LiteralPath $Workspace).Path
$cleanupRunner = Join-Path $workspacePath 'scripts/native-cleanup/run_aztec_native_cleanup_sta.ps1'
$cleanupVerifier = Join-Path $workspacePath 'scripts/native-cleanup/verify_aztec_native_cleanup_run_optimized.ps1'
$skillRoot = $workspacePath
$exporter = Join-Path $skillRoot 'assets/aztec-native-toolchain/03_tools/aztec_exporter/AZtecBmpExporter.exe'
foreach ($required in @($cleanupRunner, $cleanupVerifier, $exporter)) {
    if (-not [IO.File]::Exists($required)) { throw "required_tool_missing:$required" }
}

function Read-JsonLines([string]$Path) {
    $rows = [System.Collections.Generic.List[object]]::new()
    $parseErrors = 0
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if (-not $line.Trim()) { continue }
        try {
            $value = $line | ConvertFrom-Json
            if ($value -is [array]) { $parseErrors++; continue }
            [void]$rows.Add($value)
        } catch {
            $parseErrors++
            continue
        }
    }
    $script:lastJsonParseErrors += $parseErrors
    @($rows)
}

function Read-RawDataCorruptedManifest([string]$Path) {
    $map = @{}
    if (-not $Path -or -not [IO.File]::Exists($Path)) { return $map }
    $document = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json
    foreach ($entry in @($document.entries)) {
        if (-not $entry.source) { continue }
        $map[[IO.Path]::GetFullPath([string]$entry.source)] = $entry
    }
    return $map
}

function Test-RawDataCorrupted([string]$SourcePath) {
    if ($IncludeRawDataCorrupted) { return $false }
    return $script:rawDataCorrupted.ContainsKey([IO.Path]::GetFullPath($SourcePath))
}

function Test-CompletedRow($Row) {
    return ([string]$Row.status -eq 'completed_native_cleanup_verified_and_three_maps_exported')
}

function Assert-InputPair([string]$SourcePath) {
    $crc = [IO.Path]::ChangeExtension($SourcePath, '.crc')
    if (-not [IO.File]::Exists($crc)) { throw 'matching_crc_missing' }
    $header = [IO.File]::ReadAllText($SourcePath)
    $pointsMatch = [regex]::Match($header, '(?m)^NoOfPoints=(\d+)\r?$')
    $xMatch = [regex]::Match($header, '(?m)^xCells=(\d+)\r?$')
    $yMatch = [regex]::Match($header, '(?m)^yCells=(\d+)\r?$')
    if (-not $pointsMatch.Success -or -not $xMatch.Success -or -not $yMatch.Success) { throw 'cpr_geometry_header_missing' }
    $points = [int64]$pointsMatch.Groups[1].Value
    $grid = [int64]$xMatch.Groups[1].Value * [int64]$yMatch.Groups[1].Value
    $crcBytes = (Get-Item -LiteralPath $crc).Length
    if ($points -ne $grid) { throw ('cpr_geometry_mismatch:points=' + $points + ';grid=' + $grid) }
    if ($crcBytes -ne ($points * 25)) { throw ('cpr_crc_length_mismatch:expected=' + ($points * 25) + ';actual=' + $crcBytes) }
}

function Get-CleanupFailureDetail([string]$Directory) {
    $parts = [System.Collections.Generic.List[string]]::new()
    $failurePath = Join-Path $Directory 'cleanup-failure.json'
    if ([IO.File]::Exists($failurePath)) {
        try {
            $failure = Get-Content -Raw -Encoding UTF8 -LiteralPath $failurePath | ConvertFrom-Json
            if ($failure.error) { [void]$parts.Add([string]$failure.error) }
            foreach ($diagnosticPath in @($failure.diagnostic_files)) {
                if ([IO.File]::Exists([string]$diagnosticPath)) {
                    try {
                        $diagnostic = Get-Content -Raw -Encoding UTF8 -LiteralPath ([string]$diagnosticPath) | ConvertFrom-Json
                        if ($diagnostic.stderr_tail) { [void]$parts.Add([string]$diagnostic.stderr_tail) }
                        if ($diagnostic.stdout_tail) { [void]$parts.Add([string]$diagnostic.stdout_tail) }
                    } catch { }
                }
            }
        } catch { }
    }
    return (($parts | Where-Object { $_ }) -join ':')
}

function Write-CoverageAudit([string]$OriginalPath,[string]$RetryPath,[string]$OutputDirectory) {
    $originalAll = @(Read-JsonLines $OriginalPath | Where-Object { @('failed_or_conflicted','skipped_missing_crc') -contains [string]$_.status } | Sort-Object index)
    $original = @($originalAll | Where-Object { -not (Test-RawDataCorrupted ([string]$_.source)) })
    $latest = @{}
    if ([IO.File]::Exists($RetryPath)) {
        foreach ($row in (Read-JsonLines $RetryPath)) {
            if ($row.source) { $latest[[IO.Path]::GetFullPath([string]$row.source)] = $row }
        }
    }
    $unattempted = @($original | Where-Object { -not $latest.ContainsKey([IO.Path]::GetFullPath([string]$_.source)) })
    $eligibleLatest = @($latest.Values | Where-Object { -not (Test-RawDataCorrupted ([string]$_.source)) })
    $unresolved = @($eligibleLatest | Where-Object { -not (Test-CompletedRow $_) })
    $completed = @($eligibleLatest | Where-Object { Test-CompletedRow $_ })
    $excluded = if ($IncludeRawDataCorrupted) { @() } else { @($script:rawDataCorrupted.Keys | Sort-Object) }
    $coverage = [ordered]@{
        generated_utc = [DateTime]::UtcNow.ToString('o')
        original_failed = $original.Count
        retry_unique = $eligibleLatest.Count
        completed = $completed.Count
        unresolved = $unresolved.Count
        unattempted = $unattempted.Count
        excluded_raw_data_corrupted = $excluded.Count
        raw_data_corrupted_sources = $excluded
        json_parse_errors = [int]$script:lastJsonParseErrors
        coverage_complete = ($unattempted.Count -eq 0)
        completion_complete = ($unattempted.Count -eq 0 -and $unresolved.Count -eq 0)
        retry_status_path = $RetryPath
    }
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'retry-coverage.json'), ($coverage | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'unattempted-sources.json'), ($unattempted | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'unresolved-sources.json'), ($unresolved | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($true))
    return $coverage
}

function New-UniqueDirectory([string]$Parent, [string]$LeafBase) {
    for ($i = 1; $i -le 999; $i++) {
        $leaf = if ($i -eq 1) { $LeafBase } else { $LeafBase + $i }
        $candidate = Join-Path $Parent $leaf
        if (-not [IO.Directory]::Exists($candidate) -and -not [IO.File]::Exists($candidate)) { return $candidate }
    }
    throw "no_unique_output_directory:$LeafBase"
}

function Validate-Cleanup([string]$Directory) {
    $reportPath = Join-Path $Directory 'cleanup-report.json'
    if (-not [IO.File]::Exists($reportPath)) { throw 'cleanup_report_missing' }
    $report = Get-Content -Raw -Encoding UTF8 -LiteralPath $reportPath | ConvertFrom-Json
    if ($report.status -ne 'complete_native_cleanup_readback_verified') { throw 'cleanup_report_not_complete' }
    & $cleanupVerifier -RunDirectory $Directory | Out-Null
    if (-not $?) { throw 'independent_cleanup_verifier_failed' }
    $cleaned = Join-Path $Directory 'cleaned.cpr'
    $cleanedCrc = [IO.Path]::ChangeExtension($cleaned, '.crc')
    if (-not [IO.File]::Exists($cleaned) -or -not [IO.File]::Exists($cleanedCrc)) { throw 'verified_cleaned_pair_missing' }
    [pscustomobject]@{ ReportPath = $reportPath; Cpr = $cleaned; Crc = $cleanedCrc; Report = $report }
}

function Validate-Maps([string]$Directory, [string]$CleanedCpr, [string]$CleanedCrc) {
    $manifestPath = Join-Path $Directory 'render_manifest.json'
    if (-not [IO.File]::Exists($manifestPath)) { throw 'render_manifest_missing' }
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
    if ($manifest.status -ne 'completed') { throw 'render_manifest_not_completed' }
    if ([IO.Path]::GetFullPath([string]$manifest.input) -ne [IO.Path]::GetFullPath($CleanedCpr)) { throw 'render_input_is_not_verified_cleaned_cpr' }
    $crcHash = if ($manifest.input_hashes.crc -and $manifest.input_hashes_after.crc -eq $manifest.input_hashes.crc) {
        [string]$manifest.input_hashes.crc
    } else { (Get-FileHash -Algorithm SHA256 -LiteralPath $CleanedCrc).Hash }
    if ($manifest.input_hashes.crc -ne $crcHash -or $manifest.input_hashes_after.crc -ne $crcHash) { throw 'render_crc_pair_identity_mismatch' }
    foreach ($type in @('IPF','KAM','GOS')) {
        $bmp = Join-Path $Directory ($type + '.bmp')
        $entry = @($manifest.outputs | Where-Object type -eq $type)
        if ($entry.Count -ne 1 -or $entry[0].status -ne 'completed' -or -not [IO.File]::Exists($bmp)) { throw "required_native_map_invalid:$type" }
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $bmp).Hash -ne $entry[0].sha256) { throw "native_map_sha256_mismatch:$type" }
    }
    [pscustomobject]@{ ManifestPath = $manifestPath; Manifest = $manifest }
}

function Find-VerifiedCleanup([string]$Parent, [string]$BaseName) {
    $candidates = @(Get-ChildItem -LiteralPath $Parent -Directory -ErrorAction SilentlyContinue |
        Where-Object Name -like ($BaseName + '_native_cleanup*') |
        Sort-Object LastWriteTime -Descending)
    foreach ($candidate in $candidates) {
        try { return (Validate-Cleanup $candidate.FullName) } catch { }
    }
    return $null
}

function Find-VerifiedMaps([string]$Parent, [string]$BaseName, [string]$CleanedCpr, [string]$CleanedCrc) {
    $candidates = @(Get-ChildItem -LiteralPath $Parent -Directory -ErrorAction SilentlyContinue |
        Where-Object Name -like ($BaseName + '_native_bmp*') |
        Sort-Object LastWriteTime -Descending)
    foreach ($candidate in $candidates) {
        try { return (Validate-Maps $candidate.FullName $CleanedCpr $CleanedCrc) } catch { }
    }
    return $null
}

function Invoke-CleanupWithSlot([string]$SourcePath, [string]$CleanupDir) {
    $created = $false
    $slot = [Threading.Semaphore]::new($CleanupConcurrency, $CleanupConcurrency, 'Global\AztecEbsdNativeCleanupSlots', [ref]$created)
    $held = $false
    try {
        $held = $slot.WaitOne([TimeSpan]::FromHours(12))
        if (-not $held) { throw 'native_cleanup_slot_timeout' }
        & $cleanupRunner -CprPath $SourcePath -OutputDirectory $CleanupDir -PersistencePolicy NativeSave -StageTimeoutSeconds $StageTimeoutSeconds -AuditMode $AuditMode -ProgressCheckpointEvery $ProgressCheckpointEvery | Out-Null
        $runnerExit = $LASTEXITCODE
        if ($runnerExit -ne 0) {
            # A reboot can leave a fully verified report while the wrapper still
            # observes a stale/nonzero child exit code. Re-adopt only after the
            # independent verifier confirms the completed report.
            $reportPath = Join-Path $CleanupDir 'cleanup-report.json'
            $report = $null
            if ([IO.File]::Exists($reportPath)) {
                try { $report = Get-Content -Raw -Encoding UTF8 -LiteralPath $reportPath | ConvertFrom-Json } catch { }
            }
            if ($report -and $report.status -eq 'complete_native_cleanup_readback_verified') {
                & $cleanupVerifier -RunDirectory $CleanupDir | Out-Null
                if ($?) { return }
            }
            $stderrPath = Join-Path $CleanupDir 'clean.stderr.log'
            if ([IO.File]::Exists($stderrPath)) {
                $stderr = ((Get-Content -LiteralPath $stderrPath -Tail 20 -ErrorAction SilentlyContinue) -join "`n").Trim()
                if ($stderr -match 'native_dataset_not_populated') {
                    throw ('native_dataset_not_populated:runner_exit=' + $runnerExit)
                }
            }
            throw ('native_cleanup_runner_failed:' + $runnerExit)
        }
    } finally {
        if ($held) { [void]$slot.Release() }
        $slot.Dispose()
    }
}

function Invoke-One([string]$Source, [int]$RetryIndex, [int]$OriginalIndex) {
    $sourcePath = [IO.Path]::GetFullPath($Source)
    $result = [ordered]@{ retry_index = $RetryIndex; original_index = $OriginalIndex; source = $sourcePath; status = 'pending'; error = $null; cleanup_directory = $null; bmp_directory = $null }
    try {
        if (Test-RawDataCorrupted $sourcePath) {
            $result.status = 'skipped_raw_data_corrupted'
            $result.failure_kind = 'raw_data_corrupted'
            $result.error = [string]$script:rawDataCorrupted[$sourcePath].reason
            return [pscustomobject]$result
        }
        $crc = [IO.Path]::ChangeExtension($sourcePath, '.crc')
        if (-not [IO.File]::Exists($crc)) { $result.status = 'skipped_missing_crc'; throw 'matching_crc_missing' }
        Assert-InputPair $sourcePath
        $parent = Split-Path -Parent $sourcePath
        $base = [IO.Path]::GetFileNameWithoutExtension($sourcePath)
        $clean = Find-VerifiedCleanup $parent $base
        if ($null -eq $clean) {
            if (-not $DryRun) {
                $lastCleanupError = $null
                for ($attempt = 1; $attempt -le $WorkerAttempts -and $null -eq $clean; $attempt++) {
                    $cleanupDir = New-UniqueDirectory $parent ($base + '_native_cleanup_retry_sta')
                    $result.cleanup_directory = $cleanupDir
                    try {
                        Invoke-CleanupWithSlot $sourcePath $cleanupDir
                        $clean = Validate-Cleanup $cleanupDir
                    } catch {
                        $lastCleanupError = (($_.Exception.Message) + ':' + (Get-CleanupFailureDetail $cleanupDir)).TrimEnd(':')
                        if ($lastCleanupError -match 'framework_sta_preflight_failed|requires_framework_sta_worker|native_dataset_not_populated|unsupported_crc|unsupported_|requires_single_dataset|requires_rectangular|requires_cpr_and_matching_crc') { break }
                        if ($attempt -lt $WorkerAttempts) { Start-Sleep -Seconds ([Math]::Min(30, 2 * $attempt)) }
                    }
                }
                if ($null -eq $clean) { throw ('cleanup_failed_after_attempts:' + $WorkerAttempts + ':' + $lastCleanupError) }
            }
        } else { $result.cleanup_directory = Split-Path -Parent $clean.ReportPath }
        if ($DryRun) { $result.status = 'dry_run_ready'; return [pscustomobject]$result }
        if ($null -eq $clean) { throw 'cleanup_not_executed' }
        $maps = Find-VerifiedMaps $parent $base $clean.Cpr $clean.Crc
        if ($null -eq $maps) {
            $bmpDir = New-UniqueDirectory $parent ($base + '_native_bmp_retry')
            $result.bmp_directory = $bmpDir
            # The exporter provenance gate compares the complete cleaned CRC file hash.
            $crcHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $clean.Crc).Hash
            $exportMutex = [Threading.Mutex]::new($false, 'Global\AztecEbsdNativeBmpExporter')
            $hasMutex = $false
            try {
                $hasMutex = $exportMutex.WaitOne([TimeSpan]::FromHours(12))
                if (-not $hasMutex) { throw 'native_bmp_exporter_mutex_timeout' }
                & $exporter --input $clean.Cpr --output $bmpDir --types ALL --template native-v1 --expected-crc-sha256 $crcHash | Out-Null
                $exportExitCode = $LASTEXITCODE
            } finally {
                if ($hasMutex) { [void]$exportMutex.ReleaseMutex() }
                $exportMutex.Dispose()
            }
            try {
                $maps = Validate-Maps $bmpDir $clean.Cpr $clean.Crc
                if ($exportExitCode -ne 0) { $result.export_warning = 'exporter_nonzero_but_manifest_validated'; $result.export_exit_code = $exportExitCode }
            } catch {
                if ($exportExitCode -ne 0) { throw ('native_bmp_exporter_failed:' + $exportExitCode + ':' + $_.Exception.Message) }
                throw
            }
        } else { $result.bmp_directory = Split-Path -Parent $maps.ManifestPath }
        $result.status = 'completed_native_cleanup_verified_and_three_maps_exported'
        $result.cleanup_report = $clean.ReportPath
        $result.render_manifest = $maps.ManifestPath
    } catch {
        if ($result.status -ne 'skipped_missing_crc') { $result.status = 'failed_or_conflicted' }
        $detail = $_.Exception.Message
        if ($result.cleanup_directory) {
            $failureDetail = Get-CleanupFailureDetail ([string]$result.cleanup_directory)
            if ($failureDetail) { $detail = $detail + ':' + $failureDetail }
        }
        $result.error = $detail
        $result.failure_kind = if ($detail -match 'cpr_crc_length_mismatch|cpr_geometry_mismatch|matching_crc_missing|cpr_geometry_header_missing') { 'input_pair_mismatch' } elseif ($detail -match 'dataset_not_populated|unsupported_|requires_single_dataset|requires_rectangular') { 'data_preflight' } elseif ($detail -match 'STA|Geometry|memory|Not enough memory|SaveProjectAs|procedure not found|worker_exit') { 'transient_native_worker' } elseif ($detail -match 'bmp_exporter|render_manifest|native_map') { 'export' } elseif ($detail -match 'readback|cleanup_verifier') { 'verification' } else { 'unknown' }
    }
    [pscustomobject]$result
}

if (-not $CorruptedManifestPath) {
    $CorruptedManifestPath = Join-Path ([IO.Path]::GetDirectoryName($RetryStatusPath)) 'raw-data-corrupted.json'
}
$script:rawDataCorrupted = Read-RawDataCorruptedManifest $CorruptedManifestPath
$script:lastJsonParseErrors = 0

if ($WorkerMode) {
    if (-not $WorkerSource -or -not $WorkerResultPath) { throw 'worker_source_and_result_path_required' }
    $row = Invoke-One $WorkerSource $WorkerRetryIndex $WorkerOriginalIndex
    [IO.File]::WriteAllText($WorkerResultPath, ($row | ConvertTo-Json -Depth 10 -Compress), [Text.UTF8Encoding]::new($false))
    exit 0
}

$schedulerMutex = $null
$schedulerMutexOwned = $false
if (-not $DryRun) {
    $schedulerMutex = [Threading.Mutex]::new($false, 'Global\AztecEbsdRetryBatchScheduler')
    try {
        $schedulerMutexOwned = $schedulerMutex.WaitOne(0)
    } catch [Threading.AbandonedMutexException] {
        $schedulerMutexOwned = $true
    }
    if (-not $schedulerMutexOwned) {
        $schedulerMutex.Dispose()
        throw 'batch_already_running'
    }
}

try {
if (-not $OriginalStatusPath) { throw 'original_status_path_required' }
if (-not $RetryStatusPath) { throw 'retry_status_path_required' }
$records = @(Read-JsonLines $OriginalStatusPath | Where-Object { @('failed_or_conflicted','skipped_missing_crc') -contains [string]$_.status } | Sort-Object index)
$records = @($records | Where-Object { -not (Test-RawDataCorrupted ([string]$_.source)) })
$alreadyCompleted = @{}
$latestRetry = @{}
if ([IO.File]::Exists($RetryStatusPath)) {
    foreach ($row in (Read-JsonLines $RetryStatusPath)) {
        if ($row.source) { $latestRetry[[IO.Path]::GetFullPath([string]$row.source)] = $row }
        if (Test-CompletedRow $row) { $alreadyCompleted[[IO.Path]::GetFullPath([string]$row.source)] = $true }
    }
}
$pending = if ($FailedOnly) {
    @($records | Where-Object {
        $key = [IO.Path]::GetFullPath([string]$_.source)
        $latestRetry.ContainsKey($key) -and -not (Test-CompletedRow $latestRetry[$key]) -and
        ($IncludeInputPairMismatch -or [string]$latestRetry[$key].failure_kind -ne 'input_pair_mismatch')
    })
} else {
    @($records | Where-Object {
        $key = [IO.Path]::GetFullPath([string]$_.source)
        -not $alreadyCompleted.ContainsKey($key) -and
        ($IncludeInputPairMismatch -or -not ($latestRetry.ContainsKey($key) -and [string]$latestRetry[$key].failure_kind -eq 'input_pair_mismatch'))
    })
}
if ($Limit -gt 0) { $pending = @($pending | Select-Object -First $Limit) }
if ($DryRun) {
    foreach ($record in $pending) {
        [pscustomobject]@{ index = $record.index; source = $record.source; latest_status = if ($latestRetry.ContainsKey([IO.Path]::GetFullPath([string]$record.source))) { $latestRetry[[IO.Path]::GetFullPath([string]$record.source)].status } else { 'unattempted' } } |
            ConvertTo-Json -Depth 5 -Compress
    }
    Write-Output ("Dry run: {0} candidates; no sample, output, or status files were modified." -f $pending.Count)
    exit 0
}
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($RetryStatusPath))
$stateRoot = Join-Path ([IO.Path]::GetDirectoryName($RetryStatusPath)) 'parallel-workers'
[void][IO.Directory]::CreateDirectory($stateRoot)
$runRoot = Join-Path $stateRoot ('run-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + $PID)
[void][IO.Directory]::CreateDirectory($runRoot)
$scriptPath = $PSCommandPath
$active = @{}
$next = 0
$completed = 0
$effectiveMaxConcurrency = $MaxConcurrency
$resourcePolicyPath = Join-Path $runRoot 'resource-policy.jsonl'
$lastResourceCheck = [DateTime]::MinValue
$memoryFailureHoldUntil = [DateTime]::MinValue
function Update-BatchCapacity([switch]$Force) {
    if (-not $Force -and ([DateTime]::UtcNow - $script:lastResourceCheck).TotalSeconds -lt 5) { return }
    $script:lastResourceCheck = [DateTime]::UtcNow
    $measurable = $true
    try {
        $snapshot = Get-AztecBatchResourceSnapshot
    } catch {
        $measurable = $false
        $snapshot = [pscustomobject]@{ measurable = $false; cpu_headroom_percent = $null; memory_headroom_percent = $null; cpu_load_percent = $null; free_memory_mb = $null; total_memory_mb = $null; error = $_.Exception.Message }
    }
    $suggested = Get-AztecBatchConcurrency -Requested $MaxConcurrency -CpuHeadroomPercent $(if ($measurable) { $snapshot.cpu_headroom_percent } else { 0 }) -MemoryHeadroomPercent $(if ($measurable) { $snapshot.memory_headroom_percent } else { 0 }) -Measurable $measurable
    if ([DateTime]::UtcNow -lt $script:memoryFailureHoldUntil) {
        $suggested = [Math]::Min($suggested, 5)
    }
    $before = $script:effectiveMaxConcurrency
    $script:effectiveMaxConcurrency = $suggested
    if ($Force -or $script:effectiveMaxConcurrency -ne $before) {
        $reason = if (-not $measurable) { 'resource_measurement_unavailable' } elseif ([DateTime]::UtcNow -lt $script:memoryFailureHoldUntil) { 'worker_memory_failure_hold' } elseif ($script:effectiveMaxConcurrency -lt $MaxConcurrency) { 'headroom_below_10_percent' } else { 'headroom_recovered_to_requested' }
        $entry = [ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); requested_concurrency = $MaxConcurrency; effective_concurrency = $script:effectiveMaxConcurrency; reason = $reason; snapshot = $snapshot }
        [IO.File]::AppendAllText($resourcePolicyPath, (($entry | ConvertTo-Json -Depth 5 -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        Write-Output ("resource policy: concurrency={0}; reason={1}; cpu_headroom={2}; memory_headroom={3}" -f $script:effectiveMaxConcurrency, $reason, $snapshot.cpu_headroom_percent, $snapshot.memory_headroom_percent)
    }
}
Update-BatchCapacity -Force

while ($next -lt $pending.Count -or $active.Count -gt 0) {
    Update-BatchCapacity
    while ($active.Count -lt $effectiveMaxConcurrency -and $next -lt $pending.Count) {
        $record = $pending[$next]
        $next++
        $workerKey = '{0:D5}' -f [int]$record.index
        $resultPath = Join-Path $runRoot ($workerKey + '.json')
        $stdoutPath = Join-Path $runRoot ($workerKey + '.stdout.log')
        $stderrPath = Join-Path $runRoot ($workerKey + '.stderr.log')
        $quote = { param([string]$value) "'" + ($value -replace "'", "''") + "'" }
        $command = '& ' + (& $quote $scriptPath) +
            ' -Workspace ' + (& $quote $workspacePath) +
            ' -OriginalStatusPath ' + (& $quote $OriginalStatusPath) +
            ' -RetryStatusPath ' + (& $quote $RetryStatusPath) +
            ' -StageTimeoutSeconds ' + [string]$StageTimeoutSeconds +
            ' -AuditMode ' + (& $quote $AuditMode) +
            ' -CleanupConcurrency ' + [string]$CleanupConcurrency +
            ' -WorkerAttempts ' + [string]$WorkerAttempts +
            ' -ProgressCheckpointEvery ' + [string]$ProgressCheckpointEvery +
            ' -WorkerMode' +
            ' -WorkerSource ' + (& $quote ([string]$record.source)) +
            ' -WorkerResultPath ' + (& $quote $resultPath) +
            ' -WorkerRetryIndex ' + [string]$next +
            ' -WorkerOriginalIndex ' + [string]$record.index +
            ' -CorruptedManifestPath ' + (& $quote $CorruptedManifestPath)
        if ($IncludeRawDataCorrupted) { $command += ' -IncludeRawDataCorrupted' }
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $procInfo=[Diagnostics.ProcessStartInfo]::new();$procInfo.FileName='C:\Program Files\PowerShell\7\pwsh.exe';$procInfo.UseShellExecute=$false;$procInfo.CreateNoWindow=$true;$procInfo.RedirectStandardOutput=$true;$procInfo.RedirectStandardError=$true
        foreach($argument in @('-NoProfile','-EncodedCommand',$encoded)){[void]$procInfo.ArgumentList.Add($argument)}
        $proc=[Diagnostics.Process]::new();$proc.StartInfo=$procInfo
        if(-not $proc.Start()){throw 'worker_process_start_failed'}
        $stdoutTask=$proc.StandardOutput.ReadToEndAsync();$stderrTask=$proc.StandardError.ReadToEndAsync()
        $active[$proc.Id] = [pscustomobject]@{ Process = $proc; StdoutTask=$stdoutTask; StderrTask=$stderrTask; Record = $record; ResultPath = $resultPath; StdoutPath = $stdoutPath; StderrPath = $stderrPath; Index = $next }
        Write-Output ("launched [{0}/{1}] {2}" -f $next,$pending.Count,$record.source)
    }
    Start-Sleep -Seconds 2
    foreach ($processId in @($active.Keys)) {
        $entry = $active[$processId]
        if (-not (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
            try {
                if ($entry.StdoutTask) { [IO.File]::WriteAllText($entry.StdoutPath,$entry.StdoutTask.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false)) }
                if ($entry.StderrTask) { [IO.File]::WriteAllText($entry.StderrPath,$entry.StderrTask.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false)) }
            } catch { }
            $row = $null
            if ([IO.File]::Exists($entry.ResultPath)) { $row = Get-Content -Raw -Encoding UTF8 -LiteralPath $entry.ResultPath | ConvertFrom-Json }
            if ($null -eq $row) {
                $stderrTail = if ([IO.File]::Exists($entry.StderrPath)) { (Get-Content -LiteralPath $entry.StderrPath -Tail 20 -ErrorAction SilentlyContinue) -join "`n" } else { $null }
                $row = [ordered]@{ retry_index=$entry.Index; original_index=$entry.Record.index; source=$entry.Record.source; status='failed_or_conflicted'; error='worker_exit_without_result'; worker_stderr=$stderrTail }
            }
            [IO.File]::AppendAllText($RetryStatusPath, (($row | ConvertTo-Json -Depth 10 -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            $completed++
            Write-Output ("[{0}/{1}] {2}: {3}" -f $completed,$pending.Count,$row.status,$row.source)
            if ($effectiveMaxConcurrency -gt 5 -and [string]$row.error -match '(?i)out of memory|not enough memory|memory allocation|0xC0000017') {
                $effectiveMaxConcurrency = 5
                $memoryFailureHoldUntil = [DateTime]::UtcNow.AddSeconds(30)
                $script:memoryFailureHoldUntil = $memoryFailureHoldUntil
                $entry = [ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); requested_concurrency = $MaxConcurrency; effective_concurrency = $effectiveMaxConcurrency; reason = 'worker_memory_failure'; source = $row.source }
                [IO.File]::AppendAllText($resourcePolicyPath, (($entry | ConvertTo-Json -Depth 5 -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
                Write-Output 'resource policy: concurrency reduced to 5 after a memory-related worker failure; active workers will drain before more are launched.'
            }
            $active.Remove($processId)
        }
    }
}
$coverage = Write-CoverageAudit ([string]$OriginalStatusPath) ([string]$RetryStatusPath) ([string]([IO.Path]::GetDirectoryName($RetryStatusPath)))
Write-Output ("Parallel retry batch complete: {0} candidates; requested_concurrency={1}; effective_concurrency={2}; unresolved={3}; unattempted={4}; status log: {5}" -f $pending.Count,$MaxConcurrency,$effectiveMaxConcurrency,$coverage.unresolved,$coverage.unattempted,$RetryStatusPath)
} finally {
    if ($schedulerMutexOwned) {
        [void]$schedulerMutex.ReleaseMutex()
        $schedulerMutexOwned = $false
    }
    if ($schedulerMutex) { $schedulerMutex.Dispose() }
}
