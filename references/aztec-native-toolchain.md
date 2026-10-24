# Native toolchain boundary

The exporter source wraps the installed AZtec Crystal native map layers and
keeps the native worker in a Framework STA process. The repository supplies
only the wrapper and validation source. It does not supply `core.ebsd.dll`,
AZtecCrystal, vendor licenses, sample data, or compiled outputs.

Build the local source targets with `scripts/build-toolchain.ps1`, then use the
generated exporter only with explicit CPR/CRC input and a new output directory.
The `native-v1` profile uses the installed native MapExport path. `frozen-v1`
is a compatibility profile for local regression work; neither profile implies
complete equivalence across every dataset or display configuration.

For every local run, retain source hashes, native reports, output hashes,
pixel snapshots, and retry evidence. A successful native call, saved bitmap
match, or zero-difference comparison against one reference is not a general
claim of full-map fidelity. The public package reports
`NativeFullMapFidelity=not_accepted`.

Use the standalone `P47BaselineMetrics` source for BMP comparisons when no
AZtec installation is involved. It supports the documented uncompressed 24-bit
and 32-bit formats and compares explicit regions; it does not interpret EBSD
scientific values.
