# openSUSE 16.X Bootloader Switcher

Transactional bootloader migration and backup restoration for **openSUSE Leap 16.x**.

The switcher supports **GRUB2, Limine, systemd-boot, and rEFInd**. It is designed around a fail-closed rule: the currently working bootloader remains available as recovery until the target has actually booted on hardware and passed runtime, ownership, and boot-chain validation.

> **Current milestone — leap16-r86:** every cross-loader live switch and backup-restore direction among the four supported bootloaders has completed successfully on the project test hardware. That is **12/12 directed live edges + 12/12 directed restore edges** hardware-proven.

## Supported bootloaders

| Bootloader | Target proof contract |
| --- | --- |
| **GRUB2** | Native openSUSE shim runtime proof, native GRUB configuration/policy validation, owned `EFI/BOOT` transfer, and direct-GRUB recovery topology. |
| **Limine** | Canonical Limine runtime proof followed by an **independent** byte-identical `EFI/BOOT` fallback boot proof before source retirement. |
| **systemd-boot** | Canonical systemd-boot runtime proof, native BLS/kernel/initrd validation, then byte-identical `EFI/BOOT` ownership and final topology proof. |
| **rEFInd** | Canonical rEFInd runtime proof plus fresh `PreviousBoot` direct-kernel evidence. rEFInd intentionally does **not** claim the generic `EFI/BOOT` namespace. |

See [docs/HARDWARE-MATRIX.md](docs/HARDWARE-MATRIX.md) for the complete live and restore matrices.

## Safety model

A normal cross-loader transaction follows this shape:

```text
capture and validate the known-good source
        ↓
snapshot source ownership + firmware baseline
        ↓
stage the target without retiring the source
        ↓
arm exactly one target boot through BootNext
        ↓
reboot and prove the target actually reached userspace
        ↓
prove BootCurrent, kernel, root, cmdline, target ownership and native boot-chain state
        ↓
promote/finalize the target and prove its final topology
        ↓
retire only the exact ownership-proven source state
```

If a required gate fails, the transaction stops instead of treating manual cleanup as success. The pending transaction can be inspected and resumed through the switcher.

**Do not manually change `BootOrder`, `BootNext`, EFI files, or source NVRAM entries while a staged transaction exists.**

## Requirements

- openSUSE Leap **16.x**
- UEFI boot mode
- Secure Boot **disabled**
- a mounted VFAT EFI System Partition
- a working `sudo` configuration for the normal user
- complete installed kernel/initrd pairs

Run the tool as your **normal user**, not with `sudo`. It elevates only the operations that require root privileges.

## Quick start

Clone the repo and run the switcher:

```bash
git clone https://github.com/seba970423/opensuseleap-bootloader-switcher
cd opensuseleap-bootloader-switcher
./bootloader-switcher.sh
```

The main menu provides:

1. live bootloader switching / supported repair actions
2. pending transaction management
3. backup creation
4. backup validation
5. validated backup restore
6. read-only restore planning
7. deep validation of the current boot chain
8. detection refresh

Useful command-line entry points:

```bash
./bootloader-switcher.sh --report
./bootloader-switcher.sh --validate
./bootloader-switcher.sh --validate-grub
./bootloader-switcher.sh --validate-limine
./bootloader-switcher.sh --validate-systemd-boot
./bootloader-switcher.sh --validate-refind
./bootloader-switcher.sh --list-backups
./bootloader-switcher.sh --manage-staged
./bootloader-switcher.sh --matrix
```

## Backups and restore

User backups are stored by default in:

```text
~/opensuse-bootloader-backups
```

A backup must pass integrity and host-compatibility checks before the restore executor will use it. Restore is not treated as a file-copy shortcut: the restored bootloader becomes a new candidate and must earn fresh hardware runtime proof before the currently working source may be retired.

Read [docs/BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md) for the backup contracts and restore workflow.

## Pending state and diagnostics

Persistent user transaction state:

```text
~/.local/state/opensuse-bootloader-switcher
```

Hardware/runtime diagnostic captures:

```text
~/opensuse-bootloader-diagnostics
```

If a rebooted transaction does not complete automatically, **preserve the state** and use:

```bash
./bootloader-switcher.sh --manage-staged
```

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) before doing any manual firmware or ESP cleanup.

## rEFInd acquisition

The Leap backend uses the fixed upstream **rEFInd 0.14.2 binary ZIP** and stages the required x64 payload directly; it does not rely on an openSUSE rEFInd package or `refind-install` side effects.

A local upstream archive can be supplied with:

```bash
BOOTLOADER_SWITCHER_REFIND_ARCHIVE=/absolute/path/refind-bin-0.14.2.zip ./bootloader-switcher.sh
```

An optional `BOOTLOADER_SWITCHER_REFIND_ARCHIVE_SHA256` may pin that local archive.

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Hardware matrix](docs/HARDWARE-MATRIX.md)
- [Backup and restore](docs/BACKUP-RESTORE.md)
- [Testing](docs/TESTING.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Development history](docs/history/README.md)

## Repository layout

```text
README.md
LICENSE
bootloader-switcher.sh
lib/
tests/
docs/
```

The revisioned `lib/leap16_rXX.sh` overlays and matching selftests are **active implementation**, not disposable history. The current executable loads them in order so later revisions can harden or override earlier behavior. Development prose, patch files, and historical test reports live under `docs/history/` instead of the repository root.

## Development status

`leap16-r86` is the first project milestone with the complete four-bootloader live + restore matrix hardware-proven on the test machine. Hardware proof demonstrates the tested platform and firmware behavior; it is not a claim that every UEFI implementation will behave identically.

Future implementation refactoring should preserve the r86 behavior and proof contracts before collapsing the revision overlay stack.

## License

GNU General Public License v3.0. See [LICENSE](LICENSE).
