# Reusable EBSD workflow reference

> 历史工作区记录，仅供追溯；其中脚本路径和强制 CTF 条件属于当时的特定管线，不是本包当前通用入口；当前路线及输入要求以 [SKILL.md](../SKILL.md) 和 [清理与 MTEX 边界](cleanup-metrics-and-mtex.md) 为准。

This reference maps the recurring EBSD tasks in this workspace to an explicit workflow. It is a routing and acceptance guide, not a replacement for MTEX or AZtecCrystal documentation.

## Input contract

Before MATLAB/MTEX work, establish:

- CPR, CRC, and CTF paths and SHA-256 hashes. A CPR path is not sufficient without its matching CRC and a CTF export that can be read back.
- One dataset, regular rectangular grid, point order, X/Y coordinates, X/Y steps, phase IDs/names, lattice and symmetry definitions, and CS0 Euler convention.
- Counts of indexed (`phase > 0`) and unindexed (`phase == 0`) points. Do not use header `Coverage` as the measured indexed count.
- MATLAB and MTEX versions, and the installed AZtec native interface version when exact colors are requested.

Reject or explicitly scope unsupported data: multiple datasets, nonuniform/nonrectangular grids, missing companions, ambiguous phase definitions, or a coordinate convention that cannot be verified.

For a new CPR, save this information as a preflight manifest before any denoising or filling. Verify CPR/CRC basename pairing and point identity; a same-name file alone is not proof that the companion belongs to the current dataset. Pass the manifest to every later stage and stop if a stage changes the source hash unexpectedly.

## Display modes

### AZtec-style standard

Use `03_tools/scripts/run_mtex_aztec_standard.ps1 -InputPath <CPR|CTF> -OutputDirectory <out>`.

The validated composition is BC plus 50% per-point IPF Z0 in CS0, with same-phase 2-10 degree boundaries in gray and >10 degree boundaries in black. BC limits, transparency, native map index, and raster scale are read from the actual AZtec map configuration. MTEX computes geometry and disorientation; the installed AZtec interface supplies the actual per-point color key; MATLAB composes and rasterizes the layers. This is not a pure MTEX default color key.

For a changed dataset, rerun native extraction and validation from that dataset. The original Map_006 color table is never portable to a denoised file.

### Conservative denoise and hole fill

The existing `03_tools/scripts/run_mtex_denoise_map006.ps1` is a Map_006-specific recipe. It uses one symmetry-aligned 8-neighbour quaternion pass, a 2 degree same-phase cutoff, a 0.4999 degree measured-point cap, boundary-aware rollback, and nearest original measured donors for holes. It does not recursively use imputed points as donors.

For a new dataset, derive and document equivalent parameters from that dataset instead of calling this recipe. Preserve raw quality bytes and source files. Output a provenance table with row ID, original/processed phase, imputed flag, modified flag, donor ID, donor distance, and measured-point change angle.

There is no generic denoise/fill runner in the current workspace. Treat a new dataset as a dataset-specific implementation task: produce a processing script, parameter manifest, provenance table, and audit before writing a derived CPR. `fill_unindexed` defaults to off. If enabled, record the maximum donor distance, reject cross-phase donors and large holes unless explicitly justified, and report rejected/high-uncertainty points separately. Never use imputed points as recursive donors unless a new method explicitly validates that choice.

Minimum acceptance evidence:

1. Raw files are byte/hash unchanged.
2. Original measured phases and coordinates are unchanged.
3. Original measured orientation changes have median/P95/P99/max and an explicit cap.
4. Original measured same-phase LAGB/HAGB classifications are compared before/after.
5. Imputed count, fraction, source mask, donor rule, distance statistics, and uncertainty are reported separately.
6. CPR, CRC, and CTF are independently read back; quality columns remain source values.

Zero output unindexed points means labelled imputation, not a higher experimental indexing rate.

### Dark-region diagnosis and clarity

Make a diagnostic matrix before editing data:

- BC-only, pure IPF, and BC/IPF composites using the same native color key.
- Boundary-off, boundary-on, and boundary-density overlays.
- Indexed/unindexed mask and phase map.
- Before/after raster size, line width, anti-aliasing, and Y-axis checks.

If BC-only is dark, inspect the actual BC distribution and limits. If pure IPF is dark, inspect native color-key phase coverage and orientation distribution. If only the composite is dark, inspect the blend equation and clipping. If black pixels track boundary density, inspect >10 degree boundary rasterization and line width. A clarity variant may reduce BC contribution, use lighter boundary tones, or render at a larger display scale, but must state that it changes presentation only.

The existing `03_tools/scripts/audit_map006_dark_regions.py` is a Map_006 diagnostic precedent. It reports layer-specific black pixels, 9x9 boundary-density strata, raw BC/luminance, unindexed fraction, and small phase components. Small 1-2 point components are candidates for review, not automatic noise.

For a new dataset, recreate this diagnostic matrix from the current map instead of calling the Map_006 script directly. If the native exporter or compatible layer configuration is unavailable, pure MTEX layers may be exported only with an audit field such as `pure_mtex_color_key=true`; the result cannot be called AZtec pixel-matched.

The existing `03_tools/scripts/mtex_map006_clarity.m` produces Map_006 display-only variants with lower BC contribution and no orientation/phase edits. Treat its thresholds and scale as a precedent, not a universal default.

### Whole-map overview

Use `03_tools/scripts/mtex_map006_overview.m` for the Map_006 overview precedent. The overview keeps all phases, per-point IPF colors, the actual grid/step, a scale bar, and separately rendered LAGB/HAGB lines. It may choose a readable boundary width and BC contribution, but those are presentation parameters and must be recorded. Do not merge graphite, Al4C3, or other phases merely to simplify the legend.

For another CPR, construct the overview after the current dataset passes preflight and standard layer checks. The clarity and overview stages are display-only and must carry the current dataset hash and settings in their audit.

## Deliverables

For a standard render: PNG/TIFF, optional editable FIG, parameter JSON, native extraction, and verification JSON.

For denoise/fill: derived CPR/CRC/CTF, provenance TSV, original-unindexed and measured-change masks, processing audit, rendered before/after maps, and an independent readback audit.

For clarity/overview: complete-view PNG/TIFF and FIG when requested, a comparison image, a short audit stating data hashes and that the change is display-only, and the exact BC/boundary/scale settings.

The standard and denoise wrappers reuse the precompiled `03_tools/aztec_native_bin/AztecMapExporter.exe`. They do not call `build_aztec_map.ps1` or any compiler during ordinary processing. If the exporter is missing, the workflow stops; rebuilding it is a separate explicit maintenance action.

## Interpretation language

Use “recrystallized-like” or “low internal misorientation state” for GOS < 2 degrees, with the threshold and grain reconstruction stated. Use “lower local orientation-gradient proxy” for a KAM decrease after smoothing; do not call it proof of recovery or recrystallization. Describe HAGB/LAGB maps as boundary classifications under the stated thresholds, not as direct proof of CDRX/DDRX. For filled holes, say “estimated orientation” and report the fraction.

## Batch execution boundary

MTEX is a MATLAB toolbox. Use MATLAB batch mode from PowerShell for unattended execution. This workflow never invokes VS2019, `devenv.exe`, `vswhere.exe`, or a Visual Studio GUI; external UMAT/MEX compilation is a separate explicitly requested workflow and cannot replace the MATLAB interpreter required by MTEX.
