# AZtec native EXE/DLL toolchain

The package contains project-built C# helpers, PowerShell orchestration, validation code, and four binaries. It does not contain Oxford Instruments assemblies, AZtec Crystal, CPR/CRC/CTF data, reference images, or a vendor license.

## Runtime prerequisites

Use Windows x64 with PowerShell 7, .NET Framework 4.8, an actual Framework PowerShell STA worker, and an authorized AZtec Crystal installation. Verify the installed AZtec version against the package manifest before processing. The vendor installation root is configurable in the scripts; do not copy vendor assemblies into this repository.

## Included helpers

- `03_tools/aztec_exporter/AZtecBmpExporter.exe` and `.dll` provide the native map export adapter.
- `03_tools/scripts/AztecNativeIpfConsole.exe` and `AztecNativeIpfKeyProbeNoDispose.exe` are project-built helper binaries retained with their C# sources.
- `aztec_bmp_compare/p47_baseline/P47BaselineMetrics.cs` is an independent RGB/BMP comparator for current-data ROIs.

Rebuild all four binaries with `scripts/build-toolchain.ps1`. The build verifies the checked-in source manifest and refreshes relative-path integrity manifests. These manifests are integrity checks, not signatures.

## Input and output contract

Use authorized local CPR/CRC inputs. Preserve source files and write each run to a new output directory. The native exporter accepts `ALL` or a comma-separated subset of `IPF,KAM,GOS`; validate the actual output manifest, image status, dimensions, source hashes, and output hashes.

The native adapter is version-bound reflection/integration code. It is not a public vendor SDK, and successful invocation does not imply universal pixel equivalence. Keep `NativeFullMapFidelity=not_accepted` unless a narrower, explicitly tested scope has complete evidence.

## STA and process launch

Before native work, verify the real Framework child process reports `PSEdition=Desktop` and `Thread.CurrentThread.ApartmentState=STA`. Use the included process-launch test and explicit `ProcessStartInfo` redirection where a hidden child is needed. Do not infer STA from a command-line flag, runspace label, or process name.

## Comparisons and retries

Compare candidate and reference images at matching dimensions and current-data ROIs; report full canvas, map, legend, and outside-map metrics separately. A saved-pixel match proves save integrity only. The retry batch script requires caller-supplied status paths and is for recovery of an existing run; the fresh batch script creates a new run and must not reuse historical outputs.
