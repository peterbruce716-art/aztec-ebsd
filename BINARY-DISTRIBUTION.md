# Included binaries

The repository includes these four binaries, each built from the corresponding
source in the same repository:

- `assets/aztec-native-toolchain/03_tools/aztec_exporter/AZtecBmpExporter.exe`
- `assets/aztec-native-toolchain/03_tools/aztec_exporter/AZtecBmpExporter.dll`
- `assets/aztec-native-toolchain/03_tools/scripts/AztecNativeIpfConsole.exe`
- `assets/aztec-native-toolchain/03_tools/scripts/AztecNativeIpfKeyProbeNoDispose.exe`

They are self-built wrappers and verification hosts. They do not contain or
replace Oxford Instruments AZtec Crystal assemblies. The native execution paths
still require a separately installed and properly licensed AZtec Crystal
environment, and the included binaries must be rebuilt and revalidated if the
source changes.

`assets/aztec-native-toolchain/toolchain-manifest.json` records the SHA-256 and
byte count for every native source and included binary. `runtime-manifest.json`
also records the complete public runtime set. `scripts/verify-toolchain.ps1`
checks both manifests and the exporter help path without opening a dataset.
