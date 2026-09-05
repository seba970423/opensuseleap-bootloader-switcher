# Backup and Restore

## Backup location

User backups are stored by default under:

```text
~/opensuse-bootloader-backups
```

The location can be overridden with `BOOTLOADER_SWITCHER_BACKUP_ROOT`.

Backups are separate from the transaction-internal ownership snapshots used to make a live migration fail closed.

## Creating a backup

Use menu option **3** or run the interactive tool and select:

```text
Create backup of currently booted bootloader
```

The currently booted backend is detected and validated before the backup is created.

Backups include metadata, an integrity manifest, and the backend-owned payload required by the Leap restore executor. Protected files are read with narrowly-scoped privilege while the backup directory itself remains user-owned.

## Validation and compatibility

A restore candidate must pass both integrity and compatibility checks.

The validator checks the backup schema and `SHA256SUMS`, then requires the backup to match the current machine identity, ESP UUID, and root filesystem UUID. Backend-specific validators add stricter payload checks.

Use:

```bash
./bootloader-switcher.sh --list-backups
```

or menu option **4**.

A backup may be structurally valid but not restorable on the current host; the tool reports that separately instead of silently reinterpreting it.

## Backend payloads

### GRUB2

The Leap GRUB backup owns the native openSUSE state, including:

```text
/etc/default/grub
/etc/sysconfig/bootloader
/boot/grub2
<ESP>/EFI/OPENSUSE
```

Restore still requires a real staged GRUB runtime proof before the active source can be retired.

### Limine

The Limine backup captures the native policy/configuration plus its EFI and managed kernel/initrd payload tree:

```text
/etc/default/limine
<ESP>/limine.conf
<ESP>/limine-splash.png
<ESP>/EFI/LIMINE
<ESP>/<machine-id>/...
```

The shared generic `EFI/BOOT` path is recorded as reference evidence rather than blindly treated as Limine-owned restore data. Final ownership must be earned during the transaction.

Limine restore must still pass both canonical and independent fallback hardware proofs.

### systemd-boot

The systemd-boot backup captures the canonical EFI binary, native loader/BLS state, policy, and managed payload tree. The backup also records the generic `EFI/BOOT` systemd-boot state as shared recovery reference evidence and verifies that it is byte-identical when the finalized source requires it.

A restored systemd-boot target must earn fresh runtime proof before finalization transfers/authorizes the final generic fallback topology.

### rEFInd

The rEFInd backup captures the immutable rEFInd tree and direct-kernel options:

```text
<ESP>/EFI/refind
/boot/refind_linux.conf
```

`EFI/refind/vars` is intentionally excluded. In particular, `PreviousBoot` is mutable runtime evidence and must **never** be restored as proof.

After restore, rEFInd must create fresh direct-kernel `PreviousBoot` evidence during the new hardware boot.

## Restore workflow

Use menu option **5** after validating the backup. Menu option **6** provides a read-only restore plan before any write is attempted.

A cross-loader restore follows the same safety model as a live switch:

```text
validate selected backup
        ↓
validate the currently working source
        ↓
restore/substitute the target payload at the controlled write boundary
        ↓
stage target NVRAM + ownership metadata
        ↓
BootNext target once
        ↓
real hardware runtime proof
        ↓
target-specific final topology proof
        ↓
retire exact source state
```

A backup's historical validity does not authorize source retirement. The restored bytes must prove themselves again on the current boot.

## Restore matrix

All twelve directed cross-loader restore workflows among GRUB2, Limine, systemd-boot, and rEFInd are hardware-proven in r86. See [HARDWARE-MATRIX.md](HARDWARE-MATRIX.md).

## Do not manually repair a failed restore

If a restore stops at a gate, preserve the pending transaction and diagnostics. Use:

```bash
./bootloader-switcher.sh --manage-staged
```

Manual NVRAM/file cleanup may destroy the ownership evidence the rollback/finalizer needs and is not considered a successful restore outcome.
