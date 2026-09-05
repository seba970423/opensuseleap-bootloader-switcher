# Troubleshooting

## First rule: preserve the state

If a staged migration or restore fails, **do not immediately clean NVRAM or the ESP by hand**.

The switcher intentionally leaves recoverable evidence behind when a gate fails. Manual deletion can destroy the baseline/ownership information needed to resume or roll back safely.

## Inspect the current system

Read-only detection:

```bash
./bootloader-switcher.sh --report
```

Passive validation:

```bash
./bootloader-switcher.sh --validate
```

Firmware view:

```bash
sudo efibootmgr -v
```

Use the matching deep validator when needed:

```bash
./bootloader-switcher.sh --validate-grub
./bootloader-switcher.sh --validate-limine
./bootloader-switcher.sh --validate-systemd-boot
./bootloader-switcher.sh --validate-refind
```

## Pending transaction

The normal-user pending state lives under:

```text
~/.local/state/opensuse-bootloader-switcher
```

Use the built-in manager rather than editing the state file:

```bash
./bootloader-switcher.sh --manage-staged
```

The manager understands source-side, target-side, `boot-armed`, `runtime-validated`, and backend-specific recovery/finalization states.

## Automatic resume

The openSUSE temporary resume unit is:

```text
opensuse-bootloader-switcher-resume.service
```

Useful read-only checks after a staged reboot:

```bash
systemctl status opensuse-bootloader-switcher-resume.service --no-pager -l
sudo journalctl -b -u opensuse-bootloader-switcher-resume.service --no-pager
```

The service is temporary. After a clean success or a terminal fail-closed condition it may already have removed itself, so `Unit ... could not be found` is not by itself proof of failure.

The user-visible automatic result is normally stored as:

```text
~/.local/state/opensuse-bootloader-switcher/last-auto-result.txt
```

## Diagnostics

Default diagnostic root:

```text
~/opensuse-bootloader-diagnostics
```

When reporting a failure, preserve the newest transaction folder(s) and the current output of:

```bash
sudo efibootmgr -v
./bootloader-switcher.sh --report
```

If a transaction has already reached userspace on the target, do not assume a failed finalizer means the target boot failed. Runtime proof, final topology, and source retirement are separate gates.

## Common states

### Target booted, source still first in BootOrder

This is often intentional before runtime proof. The source remains persistent recovery while `BootNext` tests the target once.

Do not reorder it manually.

### Target runtime proof passed, source still exists

Also intentional. Source retirement belongs to the finalizer and occurs only after target-specific final topology/ownership gates pass.

Use `--manage-staged` if automatic continuation did not finish.

### Limine primary boot passed but source is still present

Expected until the independent Limine `EFI/BOOT` fallback boot proof also succeeds.

### rEFInd restored but `PreviousBoot` is absent

Expected before the fresh restore boot. rEFInd backups intentionally exclude mutable `EFI/refind/vars` state so old `PreviousBoot` evidence cannot be reused.

### Firmware created an extra Boot#### alias

Do not delete it manually during a transaction. The project handles only bounded aliases whose ESP/path/ownership can be proven against the pre-stage firmware baseline.

An unexplained alias should cause a fail-closed stop, not a broader cleanup rule.

## What not to do

During an active transaction, avoid:

```text
efibootmgr -o ...
efibootmgr -b ... -B
manual BootNext writes
manual EFI/BOOT replacement
manual deletion of the source EFI tree
editing pending-migration.tsv
```

unless you are deliberately abandoning the transaction and have first captured the diagnostics needed to understand the state.

The project's acceptance rule is that a normal supported workflow should recover/finalize itself without requiring those actions.
