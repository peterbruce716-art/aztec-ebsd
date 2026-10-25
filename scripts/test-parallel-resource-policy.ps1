$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'parallel-resource-policy.ps1')

$cases = @(
    @{ name = 'keeps ten when both margins pass'; requested = 10; cpu = 10; memory = 10; measurable = $true; expected = 10 },
    @{ name = 'keeps ten above threshold'; requested = 10; cpu = 15; memory = 40; measurable = $true; expected = 10 },
    @{ name = 'reduces when CPU headroom is under ten'; requested = 10; cpu = 9.9; memory = 40; measurable = $true; expected = 5 },
    @{ name = 'reduces when memory headroom is under ten'; requested = 10; cpu = 40; memory = 9.9; measurable = $true; expected = 5 },
    @{ name = 'reduces when resource data is unavailable'; requested = 10; cpu = 100; memory = 100; measurable = $false; expected = 5 },
    @{ name = 'does not raise an explicitly lower limit'; requested = 3; cpu = 1; memory = 1; measurable = $true; expected = 3 }
)

foreach ($case in $cases) {
    $actual = Get-AztecBatchConcurrency -Requested $case.requested -CpuHeadroomPercent $case.cpu -MemoryHeadroomPercent $case.memory -Measurable $case.measurable
    if ($actual -ne $case.expected) { throw ("{0}: expected {1}, got {2}" -f $case.name, $case.expected, $actual) }
}

Write-Output ("passed: {0} resource policy cases" -f $cases.Count)
