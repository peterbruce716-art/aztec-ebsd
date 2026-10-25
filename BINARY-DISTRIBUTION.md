# Included binaries

All four helper binaries listed here are part of the repository and are also recorded in `assets/aztec-native-toolchain/toolchain-manifest.json` with their SHA-256 hashes and byte counts:

| File | Purpose |
|---|---|
| `assets/aztec-native-toolchain/03_tools/aztec_exporter/AZtecBmpExporter.exe` | Native map-export CLI |
| `assets/aztec-native-toolchain/03_tools/aztec_exporter/AZtecBmpExporter.dll` | C# API wrapper for the exporter |
| `assets/aztec-native-toolchain/03_tools/scripts/AztecNativeIpfConsole.exe` | Native IPF helper/verification host |
| `assets/aztec-native-toolchain/03_tools/scripts/AztecNativeIpfKeyProbeNoDispose.exe` | Native IPF key probe helper |

The binaries are built from source in this repository. Rebuild and re-run the checks after changing their source:

```powershell
.\scripts\build-toolchain.ps1
.\scripts\verify-toolchain.ps1 -SkipEnvironment
```

The exporter EXE/DLL require the companion scripts and package layout. The native execution paths also require a separately installed and properly licensed AZtec Crystal environment, plus the .NET Framework and STA prerequisites. These self-built helpers do not include or replace Oxford Instruments AZtec Crystal, its application binaries, or vendor assemblies.

Use `README.md` for installation and smoke-test instructions. No CPR/CRC/CTF data or reference images are distributed.
