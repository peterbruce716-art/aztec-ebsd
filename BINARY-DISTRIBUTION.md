# Included algorithms and binaries

The repository includes the algorithm adapters and the five helper binaries built from the checked-in C# sources:

- `assets/aztec-native-toolchain/03_tools/aztec_exporter/AZtecBmpExporter.exe`
- `assets/aztec-native-toolchain/03_tools/aztec_exporter/AZtecBmpExporter.dll`
- `assets/aztec-native-toolchain/03_tools/aztec_exporter/StaFullMapWorker.exe`
- `assets/aztec-native-toolchain/03_tools/scripts/AztecNativeIpfConsole.exe`
- `assets/aztec-native-toolchain/03_tools/scripts/AztecNativeIpfKeyProbeNoDispose.exe`

PowerShell and C# sources are published beside the binaries. Rebuild with `scripts/build-toolchain.ps1`; the build verifies source files and refreshes relative-path manifests.

These are project-built helpers. They are not Oxford Instruments binaries and do not replace a separately installed AZtec Crystal runtime or its license.
