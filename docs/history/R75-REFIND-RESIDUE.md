# leap16-r75 — ownership-proven orphaned-rEFInd cleanup

## Hardware finding

The r74 Leap-native GRUB repair completed and a normal reboot reached canonical
openSUSE shim Boot0001. The subsequent GRUB2 -> rEFInd attempt passed every
unchanged GRUB source gate, then stopped before staging because
`/boot/efi/EFI/refind` already existed. Firmware remained canonical:
Boot0001 shim first, Boot0003 direct GRUB second, and no BootNext.

That directory is residue from the earlier r69 rEFInd session followed by the
failed rEFInd -> GRUB return. It is not part of the now-canonical GRUB source.

## r75 behavior

r75 does not weaken or bypass `leap16_r64_refind_namespace_clean`. Selecting
rEFInd from GRUB while either target path exists invokes a separate cleanup
preflight. Deletion is authorized only when all of these remain true:

- current boot is native openSUSE GRUB on the current ESP;
- the complete unchanged GRUB deep validator passes and BootNext is empty;
- both `EFI/refind` and `/boot/refind_linux.conf` are safe, complete objects;
- the tree contains the exact r66 controlled-archive source marker and exactly
  one r64 managed-policy marker;
- `refind_linux.conf` is byte-identical to the deterministic switcher writer
  for the current proven kernel command line;
- no canonical same-ESP rEFInd firmware alias exists;
- the unchanged deep Leap rEFInd validator accepts the residue; and
- the tree contains no symlink or special object.

If any proof fails, nothing is deleted.

After explicit `CLEAN` confirmation, r75 snapshots the complete residue,
hashes/manifests, and full `efibootmgr -v` table. It repeats all proofs at the
write boundary, deletes only the two rEFInd-owned paths, then requires:

- the original r64 clean-target gate to pass;
- canonical GRUB deep validation to pass; and
- the full firmware table to remain byte-identical.

Failure triggers exact filesystem restoration and revalidation. r75 performs
no NVRAM write and never touches GRUB files, `EFI/BOOT`, or the openSUSE EFI
namespace.

Cleanup and staging are intentionally separate. After successful cleanup, run
the switcher again and select rEFInd; only that second run can begin the normal
GRUB2 -> rEFInd staged transaction.
