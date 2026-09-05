# leap16-r71 — rEFInd -> GRUB candidate-source invariant fix

## Hardware observation

The first rEFInd -> GRUB staging attempt reached native GRUB reconstruction, then failed closed before candidate commit with two source-inappropriate assertions:

- `systemd-boot-owned generic EFI fallback changed during GRUB staging`
- `LOADER_TYPE changed before GRUB runtime proof`

Those assertions came from `leap16_r38_validate_grub_files_candidate()`, which is intentionally specialized for the already hardware-proven **systemd-boot -> GRUB2** edge. r64 reused that validator for **rEFInd -> GRUB2**, even though finalized rEFInd intentionally does not own `EFI/BOOT` and uses `LOADER_TYPE=grub2-efi` as its openSUSE compatibility policy.

The failure therefore occurred in validation, not because rEFInd lost authority. The target transaction had not been committed.

## r71 correction

r71 leaves `leap16_r38.sh` unchanged and replaces only the r64 rEFInd -> GRUB candidate wrapper with a source-correct validator. It requires:

1. exact shim and direct-GRUB candidate EFI paths;
2. valid native GRUB filesystem/config/kernel/root UUID state;
3. the **actual pre-stage rEFInd fallback state** to remain unchanged:
   - if a generic fallback existed, its exact hash must be preserved;
   - if finalized rEFInd had no generic fallback, GRUB staging must leave it absent;
4. finalized rEFInd's openSUSE compatibility policy to remain `LOADER_TYPE=grub2-efi` until GRUB earns runtime proof;
5. the direct-GRUB recovery alias to remain parked outside BootOrder.

The hardware-proven systemd-boot -> GRUB validator is not modified.

## Matrix status

Legacy three-loader live/restore matrix remains hardware-proven.

rEFInd live matrix remains hardware-pending except for the already observed GRUB2 -> rEFInd direct-kernel runtime/finalization evidence; the automatic end-to-end proof campaign is still in progress.

The rEFInd -> GRUB2 cell remains **HW-PENDING** until a fresh candidate reaches one-shot GRUB runtime proof and automatic finalization.
