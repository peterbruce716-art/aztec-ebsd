function Get-AztecBatchResourceSnapshot {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
    if ($processors.Count -eq 0 -or [int64]$os.TotalVisibleMemorySize -le 0) { throw 'resource_snapshot_incomplete' }
    $load = ($processors | Measure-Object -Property LoadPercentage -Average).Average
    if ($null -eq $load) { throw 'cpu_load_unavailable' }
    $freeMemory = 100.0 * [double]$os.FreePhysicalMemory / [double]$os.TotalVisibleMemorySize
    [pscustomobject]@{
        measurable = $true
        cpu_headroom_percent = [Math]::Max(0.0, 100.0 - [double]$load)
        memory_headroom_percent = [Math]::Max(0.0, [Math]::Min(100.0, $freeMemory))
        cpu_load_percent = [double]$load
        free_memory_mb = [Math]::Round([double]$os.FreePhysicalMemory / 1024.0)
        total_memory_mb = [Math]::Round([double]$os.TotalVisibleMemorySize / 1024.0)
    }
}

function Get-AztecBatchConcurrency {
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1, 10)][int]$Requested,
        [Parameter(Mandatory = $true)][double]$CpuHeadroomPercent,
        [Parameter(Mandatory = $true)][double]$MemoryHeadroomPercent,
        [Parameter(Mandatory = $true)][bool]$Measurable
    )
    if ($Requested -gt 5 -and (-not $Measurable -or $CpuHeadroomPercent -lt 10.0 -or $MemoryHeadroomPercent -lt 10.0)) {
        return 5
    }
    return $Requested
}
