# leap16-r67 rEFInd matrix / hardware ledger

r67 preserves all 6/6 hardware-proven GRUB2/Limine/systemd-boot live edges and all 6/6 hardware-proven cross-loader restore edges.
All six live and six restore edges involving rEFInd remain IMPLEMENTED / HW-PENDING.

## r67 fixes after the first successful upstream-binary staging

The real r66 GRUB2 -> rEFInd stage proved upstream rEFInd 0.14.2 acquisition, ZIP validation, manual immutable ESP staging, ext4 driver installation, scanner policy application, and create-only parked NVRAM creation. It then safe-failed before candidate commit because the Leap rEFInd validator reused the inherited CachyOS/Arch `grub_initramfs_matches_kernel_version()` helper, which requires mkinitcpio/`lsinitcpio` semantics. Leap 16 initrds are dracut images.

r67 replaces only the Leap rEFInd initrd gate with `lsinitrd` structural validation. When module-tree paths are present they must bind exclusively to the exact kernel release. A valid module-less host-only image is accepted only when dracut's own `lsinitrd -k <release>` resolver accepts the exact release.

r67 also explicitly writes and validates `follow_symlinks true`. Upstream rEFInd added this option in 0.14.0 specifically to support openSUSE layouts where scanned kernel names are symlinks to files outside normally scanned directories. r66 already fixes the payload at upstream 0.14.2.

## rEFInd hardware attempts

- r64 GRUB2 -> rEFInd: SAFE-FAIL before candidate commit — malformed zypper option scope.
- r65 GRUB2 -> rEFInd: SAFE-FAIL before candidate commit — configured Leap repositories have no `refind` provider.
- r66 GRUB2 -> rEFInd: SAFE-FAIL before candidate commit — upstream 0.14.2 staging/create-only succeeded; stale mkinitcpio structural validator rejected both Leap dracut initrds.
- r67 GRUB2 -> rEFInd: HW-PENDING.
