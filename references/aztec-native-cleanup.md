# Native cleanup boundary

The cleanup scripts are a version-bound adapter around native AZtec steps. They
do not implement a replacement cleanup algorithm and do not include vendor
assemblies. Use only with a separately licensed AZtec Crystal installation and
matching CPR/CRC input.

The documented local sequence is: zero-solution removal with the configured
neighbour levels and iteration caps, one wild-spike step, repeated native Auto
Clean-Up steps, and a final Quadrants/radius-3 Kuwahara step. The exact
parameters are part of the run report, not universal defaults. Pseudosymmetry
deletion is not part of this public route.

The runner requires PowerShell 7 for orchestration and a short-lived Windows
PowerShell Framework STA child for vendor calls. It checks the AZtec version,
CPR field schema, CRC record shape, source hashes, derived pair hashes, and an
independent readback. The original CPR/CRC must remain byte-for-byte unchanged.

`NativeSave` preserves the native serialized Euler state while rebuilding the
canonical quaternion representation. `FilteredQuaternion` explicitly commits
the filtered Euler representation. These outputs have different persistence
semantics and must not be described as interchangeable.

No output is a measurement of an imputed point merely because a zero solution
was removed. Keep modification masks and provenance limitations in the local
report. Do not place CPR, CRC, CSV, or run reports in this repository.
