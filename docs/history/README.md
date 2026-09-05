# Development History

This directory contains the development archaeology that previously cluttered the repository root.

It is preserved because the hardware campaign exposed many useful failure modes, but these files are **not required reading for normal operation**.

## Contents

- `README-r86-development-ledger.md` — the former root README with the accumulated revision-by-revision narrative.
- `PORTING-NOTES.md` — long-form openSUSE Leap port notes.
- `CACHYOS-R47-README.md` — inherited CachyOS r47 lineage documentation.
- `R64-...` through `R86-...` — focused design, diagnosis and hardware notes for the rEFInd campaign and later hardening.
- `R80-TO-R81.patch`, `R81-TO-R82.patch` — preserved historical patch artifacts.
- `R81-TEST-REPORT.txt` through `R86-TEST-REPORT.txt` — revision-specific regression reports.

## Important distinction

Only the **prose, reports, and patch artifacts** were moved here.

The revisioned executable overlays remain in:

```text
lib/leap16_r21.sh ... lib/leap16_r86.sh
```

and their regression tests remain in:

```text
tests/leap16-r21-selftest.sh ... tests/leap16-r86-selftest.sh
```

Those files are part of the effective r86 implementation and were intentionally not removed or relocated.

For current project status, use:

- [../HARDWARE-MATRIX.md](../HARDWARE-MATRIX.md)
- [../ARCHITECTURE.md](../ARCHITECTURE.md)
- [../../README.md](../../README.md)
