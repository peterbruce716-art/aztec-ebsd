param([Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Core' -or -not $IsWindows) { throw 'requires_windows_powershell_core' }
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
if ($out -eq $root -or $out.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'test_output_must_be_outside_repository'
}
if (Test-Path -LiteralPath $out) { throw 'test_output_must_be_new' }
[void][IO.Directory]::CreateDirectory($out)
$checks = [Collections.Generic.List[object]]::new()
function Check([string]$name, [bool]$condition) {
    $checks.Add([ordered]@{ name=$name; passed=$condition })
    if (-not $condition) { throw ('check_failed:' + $name) }
}
try {
    $scripts = @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File -Recurse | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' })
    foreach ($scriptFile in $scripts) {
        $tokens = $null; $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$parseErrors)
        Check ('syntax:' + [IO.Path]::GetRelativePath($root, $scriptFile.FullName).Replace('\', '/')) ($parseErrors.Count -eq 0)
    }
    $build = & (Join-Path $root 'scripts/build-toolchain.ps1') | ConvertFrom-Json
    Check 'build_five_targets' ($build.status -eq 'built' -and $build.targets -eq 5)
    $toolchain = & (Join-Path $root 'scripts/verify-toolchain.ps1') -SkipEnvironment | ConvertFrom-Json
    $requiredBinaries = @(
        'assets/aztec-native-toolchain/03_tools/aztec_exporter/AZtecBmpExporter.exe',
        'assets/aztec-native-toolchain/03_tools/aztec_exporter/AZtecBmpExporter.dll',
        'assets/aztec-native-toolchain/03_tools/aztec_exporter/StaFullMapWorker.exe',
        'assets/aztec-native-toolchain/03_tools/scripts/AztecNativeIpfConsole.exe',
        'assets/aztec-native-toolchain/03_tools/scripts/AztecNativeIpfKeyProbeNoDispose.exe'
    )
    $binariesPresent = @($requiredBinaries | Where-Object {
        -not [IO.File]::Exists((Join-Path $root $_)) -or (Get-Item -LiteralPath (Join-Path $root $_)).Length -le 0
    }).Count -eq 0
    Check 'source_and_built_manifest_integrity' ($toolchain.status -eq 'passed' -and
        $toolchain.files_verified -ge 4 -and $toolchain.runtime_files_verified -gt 0 -and
        $toolchain.NativeFullMapFidelity -eq 'not_accepted' -and $binariesPresent)
    $bundle = Join-Path $root 'assets/aztec-native-toolchain'
    $exe = Join-Path $bundle '03_tools/aztec_exporter/AZtecBmpExporter.exe'
    $process = [Diagnostics.ProcessStartInfo]::new($exe)
    $process.UseShellExecute=$false; $process.CreateNoWindow=$true
    $process.RedirectStandardOutput=$true; $process.RedirectStandardError=$true
    $process.ArgumentList.Add('--invalid-public-smoke-option')
    $child = [Diagnostics.Process]::Start($process)
    try {
        $stdout=$child.StandardOutput.ReadToEndAsync(); $stderr=$child.StandardError.ReadToEndAsync()
        if (-not $child.WaitForExit(10000)) { $child.Kill($true); throw 'cli_smoke_timeout' }
        $errorText=$stderr.GetAwaiter().GetResult(); [void]$stdout.GetAwaiter().GetResult()
        Check 'invalid_cli_rejected' ($child.ExitCode -eq 64 -and $errorText.Contains('unknown_duplicate_or_missing_argument'))
    } finally { $child.Dispose() }
    # Run the existing mocked retry contract in a separate process; it never loads vendor software.
    $retryScript = Join-Path $bundle '03_tools/scripts/test_aztec_native_retry.ps1'
    $retryOut = Join-Path $out 'retry'
    $retryText = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $retryScript -OutputDirectory $retryOut
    $retryExit = $LASTEXITCODE
    [IO.File]::WriteAllText((Join-Path $out 'retry.stdout.json'), ($retryText -join [Environment]::NewLine), [Text.UTF8Encoding]::new($true))
    $retry = [IO.File]::ReadAllText((Join-Path $retryOut 'test_report.json')) | ConvertFrom-Json
    Check 'eight_retry_contracts' ($retryExit -eq 0 -and $retry.status -eq 'pass' -and @($retry.checks).Count -eq 8 -and $retry.failed -eq 0)
    Add-Type -Path (Join-Path $bundle 'aztec_bmp_compare/p47_baseline/P47BaselineMetrics.cs')
    Add-Type -TypeDefinition @'
using System;
using System.IO;
public static class PublicBmpFixture {
    public static void Write(string path, int bits, bool topDown, bool change) {
        int width=3, height=2, stride=((width*bits+31)/32)*4;
        using(var stream=new FileStream(path,FileMode.CreateNew,FileAccess.Write))
        using(var writer=new BinaryWriter(stream)) {
            writer.Write((byte)'B'); writer.Write((byte)'M'); writer.Write(54+stride*height);
            writer.Write(0); writer.Write(54); writer.Write(40); writer.Write(width);
            writer.Write(topDown?-height:height); writer.Write((short)1); writer.Write((short)bits);
            writer.Write(0); writer.Write(stride*height); writer.Write(2835); writer.Write(2835);
            writer.Write(0); writer.Write(0);
            for(int row=0;row<height;row++) {
                int y=topDown?row:height-1-row;
                for(int x=0;x<width;x++) {
                    writer.Write((byte)(20+x+3*y)); writer.Write((byte)(50+2*x+y));
                    writer.Write((byte)(80+x+y+(change&&x==0&&y==0?10:0)));
                    if(bits==32)writer.Write((byte)(200+x+y));
                }
                for(int p=width*(bits/8);p<stride;p++)writer.Write((byte)0);
            }
        }
    }
}
'@
    $bmp24=Join-Path $out 'bottom-up-24.bmp'; $bmp32=Join-Path $out 'top-down-32.bmp'; $changed=Join-Path $out 'changed-32.bmp'
    [PublicBmpFixture]::Write($bmp24,24,$false,$false)
    [PublicBmpFixture]::Write($bmp32,32,$true,$false)
    [PublicBmpFixture]::Write($changed,32,$true,$true)
    $exact = [AztecP47.BaselineMetrics]::Compare($bmp24,$bmp24,0,0,2,2)
    Check 'bmp_exact_identity' ($exact[0].Pixels -eq 6 -and $exact[0].ExactPixels -eq 6 -and $exact[0].Mae -eq 0)
    $fullRoi = [AztecP47.BaselineMetrics]::Compare($bmp24,$bmp24,0,0,3,2)
    Check 'bmp_full_roi_empty_outside_is_finite' ($fullRoi[1].Pixels -eq 6 -and
        $fullRoi[2].Pixels -eq 0 -and $fullRoi[2].ExactPixels -eq 0 -and
        $fullRoi[2].ExactFraction -eq 1.0 -and $fullRoi[2].Mae -eq 0.0 -and
        $fullRoi[2].Rmse -eq 0.0)
    $formats = [AztecP47.BaselineMetrics]::Compare($bmp24,$bmp32,0,0,2,2)
    Check 'bmp_24_bottom_up_equals_32_top_down' ($formats[0].ExactPixels -eq 6 -and $formats[0].MaxChannelError -eq 0)
    $difference = [AztecP47.BaselineMetrics]::Compare($changed,$bmp24,0,0,2,2)
    Check 'bmp_changed_pixel_metrics' ($difference[0].ExactPixels -eq 5 -and $difference[0].AbsoluteChannelError -eq 10 -and
        $difference[0].SquaredChannelError -eq 100 -and $difference[0].MaxChannelError -eq 10 -and
        [Math]::Abs($difference[0].Mae-10.0/18) -lt 1e-12 -and $difference[1].ExactPixels -eq 3 -and $difference[2].ExactPixels -eq 2)
    $rejected = $false
    try { [void][AztecP47.BaselineMetrics]::Compare($bmp24,$bmp32,2,0,2,2) } catch {
        $rejected = $_.Exception.ToString().Contains('invalid_roi')
    }
    Check 'bmp_invalid_roi_rejected' $rejected
    # Inventory-only dry-run must not require a licensed AZtec installation.
    $fixture = Join-Path $out 'dry-run-input'
    [void][IO.Directory]::CreateDirectory($fixture)
    [IO.File]::WriteAllText((Join-Path $fixture 'sample.cpr'),'offline fixture',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllBytes((Join-Path $fixture 'sample.crc'),[byte[]]@(0))
    $dry = & (Join-Path $root 'scripts/run_aztec_native_fresh_batch.ps1') -InputRoot $fixture -RunId 'offline_smoke' -DryRun | ConvertFrom-Json
    Check 'fresh_batch_dry_run_without_vendor_preflight' ($dry.status -eq 'dry_run' -and
        $dry.candidates -eq 1 -and $dry.paired -eq 1 -and
        $dry.output_directories_created -eq $false -and
        -not (Test-Path -LiteralPath (Join-Path $fixture '.aztec_fresh_batch_logs')))
    $report = [ordered]@{ status='passed'; checks=$checks; check_count=$checks.Count; native_dataset_validation='not_run'; NativeFullMapFidelity='not_accepted' }
} catch {
    $report = [ordered]@{ status='failed'; checks=$checks; error=$_.Exception.Message; native_dataset_validation='not_run'; NativeFullMapFidelity='not_accepted' }
    throw
} finally {
    if ($null -ne $report) {
        $json=$report | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText((Join-Path $out 'smoke-report.json'),$json,[Text.UTF8Encoding]::new($true))
        Write-Output $json
    }
}
