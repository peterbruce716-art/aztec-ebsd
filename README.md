# AZtec EBSD skill

This repository publishes the reusable AZtec EBSD skill: PowerShell orchestration, C# helpers, native map-export adapters, cleanup readback checks, references, tests, and five self-built helper binaries.

The binaries are built from the C# sources in this repository. They do not contain Oxford Instruments AZtec Crystal, vendor assemblies, sample CPR/CRC/CTF data, or reference images. Native execution still requires a separately installed and licensed AZtec Crystal environment.

## Install

Clone the repository into the active Codex skills directory:

```powershell
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$skillRoot = Join-Path $codexHome 'skills/aztec-ebsd'
git clone https://github.com/peterbruce716-art/aztec-ebsd.git $skillRoot
```

If the destination already exists, use a new directory or update the existing Git clone with `git pull --ff-only`.

## Verify and rebuild

From the cloned skill directory:

```powershell
.\scripts\verify-source.ps1
.\scripts\verify-toolchain.ps1 -SkipEnvironment
.\tests\smoke.ps1 -OutputDirectory (Join-Path $env:TEMP ('aztec-ebsd-smoke-' + [guid]::NewGuid().ToString('N')))
```

To rebuild the five self-built binaries from the checked-in C# sources:

```powershell
.\scripts\build-toolchain.ps1
```

The build regenerates the toolchain and runtime integrity manifests (not `source-manifest.json`). If tracked sources change, refresh the source manifest's file inventory, byte lengths, and SHA-256 hashes first. These manifests are integrity checks, not signatures.

GitHub Actions runs a vendor-free Windows smoke suite: it verifies tracked sources, rebuilds the five self-built helpers, and exercises BMP comparison and dry-run contracts. Passing offline CI **does not** verify native AZtec algorithms or full-map pixel fidelity.

## Native prerequisites

Full native processing requires Windows x64, PowerShell 7, .NET Framework 4.8, a real Framework PowerShell STA worker, and a separately installed and licensed AZtec Crystal version supported by the package references. The repository does not grant a license to AZtec Crystal or its assemblies.

Use only authorized local CPR/CRC data, keep source files unchanged, and write derived results to a new directory outside the skill tree. Review the references before cleaning, filling, exporting, or interpreting EBSD maps.

`NativeFullMapFidelity=not_accepted` remains the package limit. Validate the actual AZtec version, input data, settings, and output before making scientific or pixel-equivalence claims.
