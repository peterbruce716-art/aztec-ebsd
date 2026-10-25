# AZtec/MTEX IPF display and fidelity boundary

This note defines reusable checks for IPF display work. It is a method boundary, not a sample-specific baseline.

## Display contract

- Preserve phase IDs, crystal symmetries, point order, grid, step size, and the declared sample/reference frame.
- Record the actual BC range, transparency, visible layers, IPF direction, grain-boundary thresholds, raster scale, and software versions for every run.
- Do not apply a color table, display range, or orientation result from one dataset to another dataset, including a cleaned or filled derivative.
- Keep BC, per-point IPF, and grain-boundary layers distinguishable in the audit. A visual export does not prove data cleaning or full-map equivalence.

## Validation

For a new input, validate CPR/CRC or CTF identity, point count, coordinates, phases, symmetry, and Euler convention before rendering. Compare native and derived outputs using the same dimensions and settings, and report full canvas, map ROI, legend, and outside-map metrics separately. Keep source hashes and output hashes.

MTEX default HKL/TSL/HSV color keys are not automatically equivalent to AZtec native colors. If an installed AZtec interface supplies a native key, record the version and extraction route. If a pure MTEX key is used, label it as such and do not call it pixel-matched to AZtec.

## Processing boundary

Cleaning, denoising, or hole filling must produce a new output directory and preserve the raw input. Report measured-point orientation changes separately from estimated points. A zero unindexed count after filling is an imputation result, not proof that the original experiment indexed every point.

Use scientific interpretation terms consistently: GOS below 2 degrees may be described as a recrystallized-like or low internal-misorientation state; low KAM supports lower local orientation gradients but does not alone prove recrystallization; CDRX/DDRX claims require grain size, boundary migration, subgrain rotation, HAGB/LAGB changes, and new-grain morphology.

## Unsupported assumptions

Do not assume a rectangular grid, single dataset, coordinate convention, or fixed BC range unless the current input passes those checks. Stop on unsupported schemas rather than deleting assertions or substituting a reference image.
