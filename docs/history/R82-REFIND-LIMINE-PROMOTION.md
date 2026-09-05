# r82 — rEFInd → Limine promotion-order repair

## Hardware evidence from `20260905-2.tar.gz`

The r81 run successfully staged canonical Limine from rEFInd, booted Limine via
BootNext, and passed the full primary runtime/deep validation twice. At the last
captured checkpoint (`20260905-221258-runtime-pass-limine-from-refind`):

- `BootCurrent: 0000` = canonical `\\EFI\\LIMINE\\LIMINE_X64.EFI`.
- `BootOrder: 0001,0000` still kept rEFInd persistent-first before promotion.
- canonical rEFInd `Boot0001` and its source bytes were intact and deep-validated.
- `EFI/BOOT/BOOTX64.EFI` was still absent.
- no Limine fallback Boot#### alias existed.
- pending phase was already `runtime-validated`.

The automatic resume then failed at:

`[FAIL] Canonical Limine/rEFInd promoted recovery topology is not exact`

No fallback transfer or rEFInd retirement was attempted after that failure.

## Root cause

`leap16_r64_promote_and_stage_limine_fallback()` reused
`adapter_target_promote(target, source)`. That helper is intentionally a
single-proof promotion helper: it writes the target first **while omitting the
source ID from BootOrder**. The rEFInd → Limine edge is different: rEFInd must
remain exact persistent recovery until a second, independent boot from the
byte-identical Limine `EFI/BOOT/BOOTX64.EFI` succeeds.

This is the same semantic class already repaired for systemd-boot → Limine in
r54, which uses `r21_order_primary_then_source_recovery()` rather than the
generic adapter promotion helper.

## r82 change

r82 reproduces only the r64 fallback-staging function and changes the promotion
step to:

1. re-run all existing pending/runtime/deep/ownership gates;
2. call `r21_order_primary_then_source_recovery()`;
3. require exact `target,source` as the first two BootOrder IDs;
4. only then snapshot the primary manifest, transfer EFI/BOOT, create/adopt the
   fallback alias, verify byte identity, and arm fallback BootNext.

No source-retirement, fallback-proof, alias-normalization, restore provenance,
menu-finalization, or diagnostic gate is weakened.

## Recovery of the r81 stranded state

No manual NVRAM cleanup is required or accepted. If r81's generic promotion
write left BootOrder with only canonical Limine first, r82 accepts that state
only after the existing primary Limine runtime proof and exact passive rEFInd
source checks pass. It then reconstructs `Limine,rEFInd` using the dedicated
ordering helper before any fallback transfer.

The user can continue the existing `runtime-validated` transaction through the
normal pending-management path. A fresh second hardware proof is still required
before rEFInd can be retired or the edge can become HW-PROVEN.
