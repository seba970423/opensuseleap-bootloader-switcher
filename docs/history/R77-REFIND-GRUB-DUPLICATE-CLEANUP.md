# leap16-r77 — rEFInd -> GRUB duplicate direct-alias cleanup

## Hardware evidence that triggered r77

The r76 automatic `rEFInd -> GRUB2` run staged exactly:

- Boot0000 = canonical rEFInd source
- Boot0001 = parked direct GRUB (`EFI/OPENSUSE/GRUBX64.EFI`)
- Boot0002 = shim target (`EFI/OPENSUSE/SHIM.EFI`)

After the one-shot shim boot, ASUS/openSUSE firmware exposed an additional:

- Boot0003 = `EFI/OPENSUSE/GRUBX64.EFI` on the same ESP, with optional data `00 00 42 4f`

The r76 runtime proof and source retirement were otherwise successful.  Its final
order became `0002,0001,0003`: shim first and the recorded direct GRUB second,
but the synthesized duplicate remained.  r76's final report checked the prefix
and recorded alias, not exact-one direct-GRUB uniqueness, so it incorrectly
reported an exact finalized topology.

## r77 contract

During runtime proof, an extra direct-GRUB alias remains tolerated and read-only.
After `runtime-validated` is persisted, r77 may delete an extra only when:

1. the recorded shim target is the running `BootCurrent`;
2. the recorded direct-GRUB alias still exists at the exact path on the exact ESP;
3. the extra resolves to the same direct-GRUB path on that ESP;
4. its Boot#### number did not exist in the complete pre-stage r64 firmware baseline;
5. it is removed from BootOrder before `efibootmgr -B` deletes it.

Normalization runs immediately before and immediately after the final GRUB
BootOrder write, then requires the direct-GRUB alias set to contain exactly the
recorded transaction-owned identity.

## Existing r76 residue

Because the r76 transaction already removed its pending snapshot, r77 does not
silently claim historical ownership on startup.  When current GRUB is deeply
valid and the sole observed defect is multiple exact same-ESP direct-GRUB
aliases, selecting current `GRUB2 (repair/reinstall)` is intercepted as an
explicit NVRAM-only cleanup.  It keeps the first/current shim and the second
persistent direct-GRUB identity, removes only later exact same-path/same-ESP
duplicates, touches no EFI/GRUB filesystem bytes, and revalidates GRUB.

## Matrix status

`rEFInd -> GRUB2` remains `HW-PENDING` until the full edge is rerun and r77
proves automatic duplicate normalization on the ASUS hardware.
