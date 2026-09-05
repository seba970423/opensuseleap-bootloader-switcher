# leap16-r76 — rEFInd to native GRUB runtime continuation

## Hardware result that triggered r76

The r75 transaction staged a complete native openSUSE GRUB candidate from a canonical rEFInd source:

- rEFInd source `Boot0000` remained first in persistent `BootOrder`;
- shim target `Boot0002` pointed to `\EFI\OPENSUSE\SHIM.EFI`;
- direct-GRUB recovery `Boot0001` pointed to `\EFI\OPENSUSE\GRUBX64.EFI` and remained outside `BootOrder`;
- `BootNext=0002` armed only the shim target;
- `/boot/grub2`, `/etc/default/grub`, the native openSUSE theme, kernel/initrd entries, root UUID, EFI payloads, and `LOADER_TYPE=grub2-efi` passed staging validation.

The machine then booted Leap through the exact GRUB shim target. Automatic resume stopped immediately with:

```text
[FAIL] Current bootloader is GRUB2, not Limine
```

That is a dispatcher error, not a GRUB boot failure. The format-v5 `refind:grub` transaction fell through the older Leap GRUB2-to-Limine runtime validator. The failure occurred before target promotion, fallback transfer, BootOrder normalization, source deletion, or any rEFInd retirement.

## r76 behavior

r76 intercepts only exact format-v5 `source=refind`, `target=grub` pending state. Every other runtime path delegates to the previously effective implementation.

From the exact running GRUB target session, runtime certification requires:

1. compatible root-owned pending state in `boot-armed` or `runtime-validated` phase;
2. `BOOTLOADER=grub` and `BootCurrent` equal to the recorded shim target;
3. exact target NVRAM path and current-ESP binding;
4. empty `BootNext`, clearing it only if firmware still exposes the exact recorded transaction target;
5. persistent `BootOrder` still beginning with the recorded rEFInd source before first certification;
6. running-kernel and kernel-command-line equivalence;
7. unchanged candidate ownership manifest;
8. the r71 native openSUSE GRUB candidate contract: `/boot/grub2`, `/etc/default/grub`, native theme/policy, shim, direct GRUB, kernel/initrd entries, root UUID, unchanged rEFInd fallback state, and `LOADER_TYPE=grub2-efi`;
9. deep runtime validation of the actually booted GRUB chain;
10. exact passive rEFInd recovery proof and exact parked direct-GRUB alias.

Only after all checks pass is `runtime-validated` persisted. rEFInd remains first and intact at that boundary.

The existing r64 finalizer remains authoritative. It re-runs runtime, candidate, passive-source, and direct-alias gates; promotes shim while retaining rEFInd recovery; transfers a byte-identical shim to `EFI/BOOT`; orders shim then direct GRUB; and only then retires the exact rEFInd source. No inherited CachyOS/Arch same-backend repair path, `mkinitcpio`, `/boot/grub`, `grub-install`, or `--bootloader-id=cachyos` operation is used.

## Continue the stranded r75 transaction

Do not reboot, restage, repair, or roll back while the exact GRUB target session is still running.

Run as the normal user:

```bash
./bootloader-switcher.sh --manage-staged
```

Choose `1` to run exact GRUB runtime validation. After it reports `RUNTIME-VALIDATED`, run the same command again and choose `2` to re-check every gate and finalize.

If any identity, ownership, kernel, command-line, theme/policy, fallback, NVRAM, or source-recovery proof differs from the recorded transaction, r76 fails closed and leaves source retirement unauthorized.
