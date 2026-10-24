# Cleanup, metrics, and MTEX boundary

KAM reports local orientation gradients and must state symmetry, neighbourhood,
valid-point rules, angle limit, and edge treatment. GOS reports intragranular
misorientation and must state grain reconstruction, boundary threshold,
statistic, phase, and valid mask. The native profile parameters are explicit
local configuration, not universal AZtec defaults.

Numerical agreement does not establish agreement of interpolation, colour
keys, grain boundaries, legends, text, or complete canvas layout. Keep native
map rendering and MTEX analysis as separately named workflows.

This package contains no universal MTEX runner. Before writing a dataset
specific MTEX script, verify the installed reader and version, phase symmetry,
coordinate convention, point order, neighbourhood, grain reconstruction, and
thresholds. Record unresolved-point and imputation masks separately. A low KAM
or GOS below 2 degrees alone cannot prove complete recrystallization or CDRX/
DDRX.
