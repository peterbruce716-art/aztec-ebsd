# AZtec EBSD skill

This repository contains the distributable portion of an AZtec Crystal EBSD skill: PowerShell orchestration, C# helper source, native-map export adapters, cleanup readback checks, tests, and four self-built helper binaries. It does not redistribute AZtec Crystal, Oxford Instruments assemblies, sample data, or reference images.

The included binaries are:

- `assets/aztec-native-toolchain/03_tools/aztec_exporter/AZtecBmpExporter.exe`
- `assets/aztec-native-toolchain/03_tools/aztec_exporter/AZtecBmpExporter.dll`
- `assets/aztec-native-toolchain/03_tools/scripts/AztecNativeIpfConsole.exe`
- `assets/aztec-native-toolchain/03_tools/scripts/AztecNativeIpfKeyProbeNoDispose.exe`

The exporter EXE and DLL work with the scripts and runtime described below; they are not standalone replacements for AZtec Crystal.

## Install

In PowerShell 7 on Windows, choose the active Codex home and clone the repository into its skills directory:

```powershell
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$skillRoot = Join-Path $codexHome 'skills/aztec-ebsd'
if (Test-Path -LiteralPath $skillRoot) {
    if (Test-Path -LiteralPath (Join-Path $skillRoot '.git')) {
        git -C $skillRoot pull --ff-only
    } else {
        throw 'skill_destination_exists_choose_another_path'
    }
} else {
    New-Item -ItemType Directory -Force -Path (Split-Path $skillRoot) | Out-Null
    git clone https://github.com/peterbruce716-art/aztec-ebsd.git $skillRoot
}
Set-Location $skillRoot
```

If the skill directory is already a Git clone, the example fast-forwards it. If that path exists but is not a Git clone, choose a different directory. Do not copy only the EXE/DLL files; the repository includes the companion scripts, sources, references, and integrity manifests they require.

## Verify the download

Run these commands from the cloned skill directory:

```powershell
.\scripts\verify-source.ps1
.\scripts\verify-toolchain.ps1 -SkipEnvironment
.\tests\smoke.ps1 -OutputDirectory (Join-Path $env:TEMP ('aztec-ebsd-smoke-' + [guid]::NewGuid().ToString('N')))
```

The smoke test builds all four binaries, checks manifests and script syntax, and exercises synthetic bitmap and mocked retry cases. It does not need or read an EBSD dataset. The output path must be new and outside the repository.

To check native prerequisites as well, run:

```powershell
.\scripts\verify-toolchain.ps1
```

A full check requires the supported AZtec Crystal installation, x64 .NET Framework compiler/runtime, PowerShell 7, and Windows PowerShell Framework STA worker. See [NOTICE.md](NOTICE.md) and [binary distribution notes](BINARY-DISTRIBUTION.md).

## Use

For a saved CPR with its matching CRC, first verify the files are authorized and use a fresh output directory. For a native export:

```powershell
$exporter = Join-Path $skillRoot 'assets/aztec-native-toolchain/03_tools/aztec_exporter/AZtecBmpExporter.exe'
& $exporter --input 'D:\data\map.cpr' --output 'D:\results\map-export' --types ALL --template native-v1
```

For the packaged cleanup workflow:

```powershell
& (Join-Path $skillRoot 'scripts/native-cleanup/run_aztec_native_cleanup.ps1') `
  -CprPath 'D:\data\map.cpr' -OutputDirectory 'D:\results\map-cleanup'
& (Join-Path $skillRoot 'scripts/native-cleanup/verify_aztec_native_cleanup_run.ps1') `
  -RunDirectory 'D:\results\map-cleanup'
```

For batch scheduling, start with an existing workspace and original status log, and use a new retry status log:

```powershell
& (Join-Path $skillRoot 'scripts/retry_failed_aztec_native_batch_parallel.ps1') `
  -Workspace 'D:\data\workspace' `
  -OriginalStatusPath 'D:\data\workspace\status.jsonl' `
  -RetryStatusPath 'D:\results\retry-status.jsonl' `
  -DryRun
```

Remove `-DryRun` only when the paths, input scope, and requested processing have been checked. See the references for supported schemas, parameters, output interpretation, and limitations.

## Package boundaries

The manifests check file hashes and byte counts; they are integrity checks, not digital signatures. Build and smoke tests verify the packaged software path, not universal scientific validity. The package keeps `NativeFullMapFidelity=not_accepted`; validate each native result for the actual AZtec version and input.
