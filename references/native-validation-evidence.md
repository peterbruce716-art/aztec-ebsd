# Native validation evidence boundary

The public package contains reusable validators and mock smoke tests, but no sample CPR/CRC/CTF files, reference images, private reports, or historical workspace logs.

Before making a claim for a new dataset, rerun the relevant checks against the current input and configuration:

- source CPR/CRC hashes are unchanged;
- cleanup report, independent readback, and final zero-solution count meet the v7 gate;
- native report, saved-pixel snapshot, output dimensions, and file hashes are retained;
- RGB comparison parameters and results identify the current candidate and reference files;
- `NativeFullMapFidelity=not_accepted` remains the package-wide limit unless the specific scope has complete evidence.

The included retry and parallel-policy tests exercise orchestration contracts only. They do not validate vendor rendering or scientific conclusions.
