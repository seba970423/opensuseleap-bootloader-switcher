# leap16-r78 — finalized GRUB duplicate-cleanup transcript dispatch

## Hardware failure

The first r77 explicit cleanup attempt reached the PTY transaction wrapper but failed before cleanup execution with:

`[FAIL] Refusing unknown r46 transcript child command: leap16_r77_cleanup_finalized_grub_duplicates_inner`

No cleanup preflight or firmware write ran.

## Root cause

r77 added a new same-backend NVRAM-only cleanup executor and correctly routed it through the existing transaction transcript wrapper. That wrapper launches a fresh switcher process. The effective strict child allowlist was still the r75 implementation, which knew the r73 GRUB repair and r75 residue cleanup executors but not the new r77 executor.

## r78 correction

r78 intercepts only `leap16_r77_cleanup_finalized_grub_duplicates_inner` at the final transcript-child boundary and requires the exact contract:

- expected current loader: `grub`
- target: `grub`
- operation kind: `cleanup`
- executor arguments: none
- diagnostics directory: existing non-symlink directory
- actual fresh-child detection: still `grub`

All other child commands delegate unchanged to the inherited strict dispatcher. Arbitrary commands and malformed r77 cleanup invocations remain rejected.

## Hardware status

The underlying r77 duplicate-alias cleanup is still HW-PENDING until this corrected fresh-process dispatch executes against the observed `BootOrder=0002,0001,0003` residue and converges to exact shim/direct `0002,0001` with only one same-ESP direct-GRUB alias.
