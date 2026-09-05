# leap16-r69 rEFInd matrix / hardware ledger

The previously hardware-proven three-loader matrix is unchanged: all 6/6 directed live edges and all 6/6 directed cross-loader restore edges among GRUB2, Limine, and systemd-boot remain HW-PROVEN.

All six live and six restore edges involving rEFInd remain IMPLEMENTED / HW-PENDING until ownership-gated finalization completes on real hardware.

## rEFInd hardware attempts

- r64 GRUB2 -> rEFInd: SAFE-FAIL before candidate commit — malformed zypper option scope.
- r65 GRUB2 -> rEFInd: SAFE-FAIL before candidate commit — configured Leap repositories expose no `refind` provider.
- r66 GRUB2 -> rEFInd: SAFE-FAIL before candidate commit — controlled upstream 0.14.2 staging succeeded; stale mkinitcpio validator rejected Leap dracut initrds.
- r67 GRUB2 -> rEFInd: DIRECT BOOT TO USERSPACE PROVEN; automatic resume SAFE-FAILED before runtime certification/source cleanup because inbound rEFInd was dispatched into the historical Limine-only runtime validator.
- r68 GRUB2 -> rEFInd: canonical rEFInd Boot0005 remained active, but selector [2] SAFE-FAILED before runtime certification because the interactive pending manager still delegated to the historical GRUB2 -> Limine manager (`Current bootloader is neither the recorded GRUB2 source nor Limine target`). No source cleanup was attempted.
- r69 GRUB2 -> rEFInd: continuation/runtime-finalization HW-PENDING from the still-running rEFInd Boot0005 session.

## Hardware state preserved for r69 continuation

Observed after the successful rEFInd one-shot boot:

- BootCurrent = Boot0005 `openSUSE rEFInd` -> `\\EFI\\refind\\refind_x64.efi`.
- Persistent BootOrder remains source-first (`0002,0000,0005`), so GRUB2 recovery is still authoritative until proof/finalization.
- Running kernel = `6.12.0-160000.37-default`.
- `/boot/efi/EFI/refind/vars/PreviousBoot` exists.
- Pending transaction remains format-5 `GRUB2 -> rEFInd`, phase `boot-armed`, source Boot0002, target Boot0005.
- The r67/r68 failures did not authorize source retirement.

## r69 correction

1. Selector [2] now intercepts all inbound `GRUB2|Limine|systemd-boot -> rEFInd` format-5 transactions before the historical Limine-centric manager.
2. Exact running rEFInd target + `boot-armed` exposes the existing r68 runtime validator directly.
3. Exact running rEFInd target + `runtime-validated` exposes the existing r64 ownership-gated finalizer directly.
4. Candidate-ready/source-session behavior uses the generic adapter re-arm/reset/rollback lifecycle; runtime proof cannot be manufactured from the source session.
5. Unrelated BootNext values fail closed.
6. Non-rEFInd pending directions delegate unchanged.
7. The historical r67 failed-result banner is rendered as a dispatcher failure while this exact transaction is still pending, rather than falsely implying the rEFInd direct boot itself failed.

## Matrix status

| Source \\ Target | GRUB2 | Limine | systemd-boot | rEFInd |
|---|---|---|---|---|
| GRUB2 | — | HW-PROVEN | HW-PROVEN | HW-PENDING (direct boot to userspace proven; finalization pending) |
| Limine | HW-PROVEN | — | HW-PROVEN | HW-PENDING |
| systemd-boot | HW-PROVEN | HW-PROVEN | — | HW-PENDING |
| rEFInd | HW-PENDING | HW-PENDING | HW-PENDING | — |

Restore status has the same shape. rEFInd backup remains HW-PENDING until the first finalized rEFInd source is backed up and restored on hardware.
