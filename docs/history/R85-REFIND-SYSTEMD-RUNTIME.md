# r85 — rEFInd -> systemd-boot runtime dispatcher

## Hardware evidence

The first r84 live rEFInd -> systemd-boot run staged successfully:

- pre-stage: `BootCurrent=0001`, `BootOrder=0001`, canonical rEFInd at `\\EFI\\refind\\refind_x64.efi`;
- staged: `BootNext=0000`, `BootOrder=0001,0000`;
- target `Boot0000` was the exact canonical `\\EFI\\systemd\\systemd-bootx64.efi` entry;
- the target deep BLS/systemd-boot validation passed before reboot;
- after reboot, the r64 root-owned resume passed its exact target identity guard, which proves the running session was systemd-boot with `BootCurrent=0000`.

The resume then stopped with:

```text
[FAIL] Current bootloader is systemd-boot, not Limine
```

The transaction remained `phase=boot-armed`, and the resume result was `failed`. Because the failure occurred inside runtime validation before phase persistence or finalizer dispatch, no target promotion, `EFI/BOOT` transfer, rEFInd BootOrder removal, rEFInd NVRAM deletion, or rEFInd filesystem retirement was authorized.

## Root cause

r64 already intercepts all rEFInd-edge root resumes, but for five one-proof edges it calls the effective generic `validate_pending_target_runtime` dispatcher.

Later revisions had added explicit runtime dispatchers for:

- GRUB2 -> systemd-boot;
- systemd-boot -> GRUB2;
- Limine -> systemd-boot;
- systemd-boot -> Limine;
- inbound `* -> rEFInd`;
- rEFInd -> GRUB2;
- rEFInd -> Limine.

There was no corresponding outbound `rEFInd -> systemd-boot` runtime interceptor. The call therefore delegated all the way to the original Leap GRUB2 -> Limine validator in `opensuse_leap16.sh`, whose first target-type assertion is `BOOTLOADER == limine`.

This is the same dispatch class previously exposed independently by other matrix edges: the candidate itself booted; a stale direction-specific runtime router mislabeled the successful target session.

## r85 change

r85 adds `leap16_r85_validate_refind_systemd_runtime` and a final, narrow `validate_pending_target_runtime` interceptor for exactly:

```text
PENDING_SOURCE=refind
PENDING_TARGET=systemd-boot
```

The validator requires:

1. compatible `boot-armed` or already-`runtime-validated` transaction state;
2. exact `systemd-boot` detection and exact target `BootCurrent`;
3. target NVRAM path and ESP identity matching the frozen transaction;
4. consumed/clear transaction `BootNext` (or clears only the exact stale target BootNext value);
5. rEFInd persistent-first ordering before the first proof;
6. running-kernel and cmdline equivalence to the source proof context;
7. unchanged target ownership manifest;
8. the existing deep native openSUSE systemd-boot runtime validator;
9. the existing r64 passive-rEFInd recovery ownership/deep-validation gate;
10. only then persistence of `runtime-validated`.

The existing r64 finalizer remains authoritative after proof. It still owns systemd-boot promotion, byte-identical `EFI/BOOT` transfer, final target-native systemd topology proof, bounded rEFInd BootOrder removal, and exact rEFInd retirement.

## Restore impact

`leap16_r64_restore_systemd_backup_from_refind` ultimately creates the same `source=refind`, `target=systemd-boot` pending transaction after the validated backup payload is substituted at the write boundary. Therefore the r85 runtime fix covers both:

- live rEFInd -> systemd-boot;
- rEFInd -> restored systemd-boot backup.

It does not alter backup validation, payload restoration, or provenance metadata.

## Current hardware status

The r84 run proves **target arrival**, not the full edge. Until r85 completes runtime proof and ownership-gated finalization on hardware:

- rEFInd -> systemd-boot live: **HW-PENDING**;
- rEFInd -> restored systemd-boot: **HW-PENDING**;
- systemd-boot -> rEFInd live: **HW-PENDING**;
- systemd-boot -> restored rEFInd: **HW-PENDING**.
