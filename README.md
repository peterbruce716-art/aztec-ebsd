# AZtec EBSD integration skill

This repository is the public portion of an AZtec EBSD workflow. It provides
PowerShell orchestration, .NET Framework helper source, native-map export
adapters, cleanup persistence checks, a standalone BMP comparison utility, and
the four self-built wrapper/verification binaries produced from this source.

The package excludes vendor assemblies, sample data, reference images, local
validation reports, historical backups, and private workstation paths. The
published executables and DLL are compiled from this repository's source; they
are wrappers and verification hosts, not AZtec Crystal binaries. The native
paths call an AZtec Crystal install that you must already be licensed to use;
the repository does not redistribute that software.

## Build and smoke check

Use PowerShell 7 on Windows with the .NET Framework 4.x C# compiler available:

```powershell
.\scripts\build-toolchain.ps1
.\tests\smoke.ps1 -OutputDirectory C:\temp\aztec-ebsd-smoke
```

The build creates or refreshes four self-built helper binaries and integrity
manifests. The binaries are included in the public repository; the manifests
record their hashes. The smoke check uses synthetic bitmap data and mocked
retry scenarios; it does not read or upload scientific datasets.

The build expects the x64 compiler at
`C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe` and runs on x64
Windows. To install a downloaded copy as a Codex skill, clone or copy this
repository to `C:\Users\<user>\.codex\skills\aztec-ebsd`; the skill resolves
its scripts relative to that directory. Verify a source-only installation with:

```powershell
pwsh -NoProfile -File .\scripts\verify-source.ps1
pwsh -NoProfile -File .\scripts\verify-toolchain.ps1 -SkipEnvironment
```

## Native execution prerequisites

The native cleanup and export paths require a separately installed AZtec
Crystal 5.1.7829.1 environment, .NET Framework 4.8, and matching CPR/CRC input
files. The scripts preserve input hashes and require a new output directory.
Use explicit local paths for every input and output. Do not place data or run
reports inside this repository.

`NativeFullMapFidelity=not_accepted` remains an explicit limitation. Successful
process execution or a matching pixel snapshot does not establish universal
equivalence to every AZtec map or configuration. Native scientific-data
validation is intentionally not included in this public source release.

## Scientific interpretation boundary

Keep GOS, KAM, LAGB/HAGB, IPF, and recrystallized-like fraction distinct.
GOS below 2 degrees may indicate a recrystallized-like or low internal
misorientation state, but it is not proof of complete recrystallization. Low
KAM supports lower local orientation gradients and stored dislocation density;
it does not independently prove recrystallization. CDRX/DDRX discussion should
also consider grain size, boundary migration, subgrain rotation, HAGB increase,
and new-grain morphology.

## Layout

- `agents/openai.yaml`: skill display metadata.
- `scripts/native-cleanup`: native cleanup orchestration and readback checks.
- `assets/aztec-native-toolchain`: source for the native exporter, helpers, and
  bitmap comparison routines.
- `scripts/build-toolchain.ps1`: local source build; no vendor assembly is
  compiled into the package.
- `scripts/verify-source.ps1`: strict source manifest and path audit.
- `scripts/verify-toolchain.ps1`: source/build manifest and CLI verification.
- `tests/smoke.ps1`: synthetic, no-dataset smoke verification.

See `NOTICE.md` for the vendor boundary and `LICENSE` for the source license.
