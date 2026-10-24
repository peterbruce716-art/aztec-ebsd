---
name: aztec-ebsd
description: Use when cleaning Oxford AZtec Crystal CPR/CRC data with native algorithms, exporting native IPF/KAM/GOS maps, comparing EBSD maps, or processing and interpreting EBSD data with MATLAB/MTEX.
---

# AZtec EBSD

Use this skill to route AZtec EBSD work into data cleanup, native map export,
bitmap comparison, or scientific interpretation. A rendered image is not proof
that CPR data was cleaned, and successful native execution is not proof of
universal pixel equivalence.

## Entry points

- `scripts/native-cleanup/run_aztec_native_cleanup.ps1` runs the version-bound
  native cleanup chain and writes a derived CPR/CRC pair. Readback verification
  is required before export.
- `assets/aztec-native-toolchain/03_tools/aztec_exporter` contains the native
  exporter source, API wrapper, scalar-map adapters, and helper source. Build
  locally with `scripts/build-toolchain.ps1`.
- `assets/aztec-native-toolchain/aztec_bmp_compare/p47_baseline` contains a
  standalone BMP metric implementation that does not load AZtec assemblies.

Resolve paths from the installed skill directory. Keep source CPR/CRC files and
all generated reports outside the skill or repository directory. Input/output
paths must be explicit and output directories must be new.

## Native boundary

The package includes four self-built wrappers and verification hosts, but does
not include AZtec Crystal or vendor assemblies. Native paths require a
separately licensed AZtec Crystal 5.1.7829.1 installation and use
version-specific reflection and persistence behavior. Revalidate the adapter
when the vendor version or data schema changes. The current release does not
claim `NativeFullMapFidelity`; that field remains `not_accepted`.

Production export must not read reference BMP files, modify the input CPR/CRC,
start the AZtec GUI, or redraw native maps with Pillow or MTEX. Preserve source
hashes, native reports, saved-pixel snapshots, and retry logs for each local
run. Retry only the documented WPF initialization symptoms and retain failed
attempt directories.

## Cleanup and MTEX

The local cleanup recipe is version-bound and is not a material-independent
default. It uses native zero-solution removal, wild-spike removal, repeated
Auto Clean-Up, and Kuwahara steps as documented in the cleanup reference. Keep
`NativeSave` and `FilteredQuaternion` persistence policies distinct.

This source release does not provide a universal MTEX runner. For MTEX work,
confirm the installed MATLAB/MTEX reader, phase symmetry, coordinate system,
neighbourhood, grain reconstruction, and thresholds for the current dataset.
Report GOS, KAM, LAGB/HAGB, IPF, and recrystallized-like fraction separately.
