# Reusable EBSD workflow reference

This document routes common EBSD tasks to explicit checks. It does not replace AZtec Crystal or MTEX documentation.

## Input preflight

Record CPR, CRC, and optional CTF paths and SHA-256 hashes. Confirm one dataset, a supported regular grid, point order, coordinates, step size, phase IDs/names, lattice and symmetry definitions, and the CS0 Euler convention. Count indexed and unindexed points from actual data rather than a header coverage field.

Reject or explicitly scope missing companions, ambiguous phase definitions, unsupported grid layouts, and coordinate conventions that cannot be verified.

## Native display and metrics

Use the native exporter for native IPF/KAM/GOS maps. For comparisons, use the independent RGB comparator with current-data ROIs and record full-canvas, map, legend, and outside-map results. A saved bitmap matching its native snapshot proves save integrity, not equivalence to a reference image.

## Cleaning and filling

The v7 native cleanup entry point writes a new CPR and requires independent readback with zero remaining unresolved points before export. Preserve raw files and report measured-point changes, estimated-point counts, donor rules, and uncertainty separately. Do not describe imputation as an improved experimental indexing rate.

## Interpretation

Use “recrystallized-like” or “low internal misorientation state” for GOS < 2 degrees with the grain reconstruction threshold stated. Describe a KAM decrease as a lower local orientation-gradient proxy. Treat LAGB/HAGB maps as thresholded boundary classifications and combine them with grain size, morphology, boundary migration, and subgrain rotation before discussing CDRX/DDRX.

## Batch boundary

The fresh batch entry point creates a unique run directory, performs cleanup/readback gates per source, and serializes the native exporter. The retry entry point is for explicit recovery only and requires caller-supplied status paths. Do not mix fresh and retry modes for the same run.
