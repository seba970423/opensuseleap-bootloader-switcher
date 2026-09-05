# leap16-r73 — Leap-native same-GRUB repair

r73 repairs the hardware-observed state left by the earlier failed rEFInd to
GRUB staging attempt: native openSUSE GRUB is bootable through
`EFI/OPENSUSE/GRUBX64.EFI`, but `/etc/default/grub` is absent and strict native
theme/policy validation therefore fails.

The backend is intentionally narrow and fail-closed. It requires the current
BootCurrent alias to resolve to the native openSUSE shim or direct-GRUB path on
the detected ESP; validates the existing `EFI/OPENSUSE` binaries, current
`/boot/grub2/grub.cfg`, every installed kernel/initrd pair, root UUID, RPM set,
packaged openSUSE theme, and `LOADER_TYPE=grub2-efi`; and refuses any existing
`/etc/default/grub` because that is not the contamination shape being repaired.

The current `grub.cfg`, theme, `EFI/OPENSUSE`, and `EFI/BOOT` states are
snapshotted first. r73 then uses the same Leap-native policy renderer already
proven by the r28 reconstruction backend, the packaged
`/usr/share/grub2/themes/openSUSE` assets, and `grub2-mkconfig` to build a
candidate. The candidate must pass syntax, complete kernel-set, root UUID, and
native-theme checks before it replaces the current `grub.cfg`. The ordinary
strict deep GRUB validator is then run unchanged while the currently bootable
EFI bytes are still untouched. Only after that proof does r73 invoke openSUSE's
native `shim-install --no-nvram`, require firmware aliases and BootOrder to
remain unchanged, and validate the refreshed shim/direct payload, native
`boot.csv`, byte-identical shim fallback, and complete GRUB chain. Any failure
in this reconstruction restores the exact old policy/config/theme and both EFI
trees.

Only after filesystem deep proof may r73 touch NVRAM. It creates a missing shim
alias with `efibootmgr --create-only`, retains the current direct-GRUB alias,
removes only path-and-ESP-proven duplicates, and installs canonical shim-first,
direct-GRUB-second BootOrder while preserving unrelated entries. BootNext must
remain empty. A final deep validation and exact one-shim/one-direct count are
required for success.

r73 never calls `mkinitcpio`, never writes `/boot/grub`, never invokes
`grub-install`, and never uses the CachyOS EFI namespace. Existing bootable EFI
executables are preserved through the first complete repaired-state deep proof;
only then are they refreshed by native `shim-install --no-nvram` under exact
rollback ownership.

After r73 succeeds, reboot once through the shim-first canonical order and run
the ordinary deep GRUB validator again. Only after that clean baseline proof
should the automatic GRUB2 to rEFInd edge be rerun; the prior manual r69
finalization remains useful evidence but does not mark that automatic edge
HW-PROVEN.
