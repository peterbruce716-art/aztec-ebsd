# Notices

This repository contains original PowerShell and C# integration, validation, and
bitmap-comparison code, plus five binaries compiled from those sources. It does
not include Oxford Instruments AZtec Crystal, `core.ebsd.dll`, vendor
assemblies, sample CPR/CRC/CTF data, or reference images.

The native execution paths require a separately installed and properly licensed
AZtec Crystal installation. AZtec Crystal and its assemblies remain the
property of their respective owners. This repository does not grant a license
to that software, document a public vendor SDK, or imply vendor endorsement.

The native adapter uses reflection and version-specific behavior. Revalidate it
against the locally installed AZtec version before using it for scientific data.
The included binaries do not make the vendor runtime redistributable.
