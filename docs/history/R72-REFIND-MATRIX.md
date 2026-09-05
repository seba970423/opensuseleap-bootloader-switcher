# leap16-r72 — rEFInd -> GRUB pre-commit rollback repair

## Hardware finding carried forward

The r70 hardware attempt staged native openSUSE GRUB from a finalized rEFInd source, created parked direct-GRUB and shim aliases, then failed candidate validation before a pending transaction was committed. The inherited r26 cleanup removed only the shim alias and `/etc/default/grub`; it did **not** own native Leap `/boot/grub2`, `EFI/OPENSUSE`, or the parked direct-GRUB alias. That left a bootable half-GRUB residue after the failed stage.

A later r71 run therefore started from `BootCurrent` direct GRUB and failed the GRUB source deep gate (`/etc/default/grub` missing, theme policy unset). This was residue from the earlier failed stage, not a second execution of the rEFInd -> GRUB candidate validator.

## r72 change

Only the uncommitted `rEFInd -> GRUB` cleanup is intercepted. It now:

1. requires the still-running recorded rEFInd source session;
2. refuses unrelated BootNext state;
3. deletes every exact same-ESP shim/direct-GRUB alias while target EFI bytes still exist;
4. removes `EFI/OPENSUSE`, `/boot/grub2`, and `/etc/default/grub`, all of which were proven absent before staging;
5. restores pre-stage `fallback.efi`/`MokManager.efi` and generic `EFI/BOOT/BOOTX64.EFI` state;
6. restores exact pre-stage BootOrder;
7. proves no shim/direct-GRUB aliases remain;
8. re-proves rEFInd source ownership/deep validation before declaring rollback complete;
9. preserves transaction snapshot evidence if any rollback proof fails.

No hardware-proven legacy cleanup path is changed.

## Matrix status

The existing three-loader GRUB2/Limine/systemd-boot live + restore matrix remains HW-PROVEN. rEFInd edges remain HW-PENDING until each completes its automatic proof/finalization contract. The earlier GRUB2 -> rEFInd direct-kernel runtime/finalization evidence remains useful, but the fully automatic edge is still pending a clean re-run.
