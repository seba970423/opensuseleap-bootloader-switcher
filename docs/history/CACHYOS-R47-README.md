# CachyOS Bootloader Switcher — r47

A safety-first UEFI bootloader migration and cross-backend backup-restore tool for CachyOS.

Supported bootloaders:

- GRUB
- Limine
- systemd-boot
- rEFInd


## r47: fix multi-assignment Limine backup cmdline restore validation

A real-hardware NVMe restore test exposed a false-negative Limine backup preflight. The backup was valid and its effective Limine policy matched the current GRUB runtime, but `/etc/default/limine` expressed that policy through **multiple** `KERNEL_CMDLINE[default]+=` lines.

The inherited restore extractor read only the first matching line, so a later appended parameter such as `intel_pstate=passive` disappeared from the backup-side comparison. The existing semantic comparator then correctly reported a difference against GRUB — but it had been given an incomplete reconstruction of the Limine policy.

r47 reconstructs the effective backed-up default policy from every supported assignment without sourcing or evaluating backup configuration:

- `KERNEL_CMDLINE[default]=...` replaces earlier accumulated policy
- `KERNEL_CMDLINE[default]+=...` appends to the effective policy
- quoted and unquoted assignment values are accepted in the same narrow line-oriented parser
- the existing semantic comparator remains authoritative and still filters only loader-specific `BOOT_IMAGE=` / `boot_image=` / `initrd=` artifacts
- meaningful drift such as a changed root UUID, mount mode, `intel_pstate`, mitigations policy, or any other real kernel parameter still blocks restore

The live migration engine and all ESP/NVRAM write paths are unchanged. This is a restore-preflight reconstruction fix only.

## Before you run this

This is advanced boot-chain software. It writes EFI System Partition state and UEFI NVRAM entries.

It is intended for CachyOS users who are comfortable with UEFI boot recovery and who have access to a firmware boot picker and/or a live recovery environment if something outside the tool's control goes wrong.

### What has actually been validated

All 24 directed cross-backend operations have completed end-to-end on the project's current real-hardware test system:

| Operation class | End-to-end validated |
|---|---:|
| Live migrations | **12 / 12** |
| Cross-backend backup restores | **12 / 12** |
| Combined directed-operation matrix | **24 / 24** |

This means all directed routes between GRUB, Limine, systemd-boot, and rEFInd have completed the full firmware `BootNext` → userspace runtime proof → finalization path on **one UEFI platform**.

It does **not** mean the tool has been validated across multiple firmware vendors, motherboard families, laptops, storage layouts, or Secure Boot configurations.

### Validated storage / boot topology

The current real-hardware matrix was exercised with:

- UEFI firmware
- one EFI System Partition
- ESP mounted at `/boot`
- VFAT ESP
- one root filesystem
- F2FS root
- no LUKS
- no LVM
- no RAID
- no multi-ESP layout
- Secure Boot disabled

The switcher contains topology and ownership checks that may reject unsupported or ambiguous layouts, but layouts outside the configuration above should be considered **not yet hardware-validated**.

## Not yet supported / not yet validated

### Secure Boot

Secure Boot is **not currently part of the supported or validated configuration**.

r47 does not manage:

- shim trust chains
- MOK enrollment
- custom Platform Key / KEK / db enrollment
- per-bootloader signing requirements
- automatic EFI binary re-signing
- UKI signing policy

Do not assume that a GRUB → Limine → rEFInd → systemd-boot transaction will remain bootable under Secure Boot merely because the same route works with Secure Boot disabled.

Until Secure Boot handling is explicitly designed and tested, use the switcher only with Secure Boot disabled.

### Storage / firmware coverage

The following have not yet completed the full 24-route hardware campaign:

- multiple ESPs
- encrypted boot layouts
- LUKS-based root/boot combinations
- LVM
- RAID
- unusual stacked mounts
- multiple firmware platforms/vendors
- firmware implementations with different `BootNext` / `BootOrder` quirks

That is a coverage limit, not a claim that those configurations are necessarily broken.

## What happens when something fails?

The transaction model is deliberately designed around the assumption that staging can fail.

A target is **not** trusted because its files were written successfully.

> **Target exists does not mean target works. Runtime proof earns cleanup authority.**

During staging:

- the currently working source bootloader remains installed
- the source remains first in persistent `BootOrder`
- target state is deeply validated before reboot
- the target is armed only once through `BootNext`
- source ownership/recovery state is recorded before destructive cleanup can ever become legal

After reboot:

- the target must actually reach CachyOS userspace
- the running kernel/root/cmdline must match the transaction
- the exact target NVRAM entry must be proven
- target ownership must still match
- source recovery state must still match

Only after those checks pass can the target be promoted and the ownership-proven source retired.

### If staging fails before reboot

The transaction refuses to arm the target and keeps the source authoritative.

Where inactive target residue had to be quarantined for staging, rollback restores it before recovery is considered complete.

### If the target does not boot

Persistent `BootOrder` still points to the previously working source.

Because `BootNext` is one-shot, the next normal firmware boot should return to the source unless the firmware itself behaves unexpectedly.

### If runtime proof fails

Source cleanup is refused.

The transaction remains in a recoverable/pending state so the source can stay authoritative while the failure is inspected or rolled back.

### If power is lost

There is no universal guarantee against firmware, filesystem, or hardware corruption caused by power loss.

The transaction reduces exposure by keeping the source persistent-first until runtime proof and by avoiding source retirement during candidate staging.

If power is lost:

- before `BootNext` is armed, the source should remain the normal boot path
- after `BootNext` is armed but before target runtime proof, the source is still retained and persistent-first
- during finalization, recovery depends on how far the ownership-gated cleanup progressed and on firmware/filesystem integrity

For any machine where an unexpected power loss is plausible, keep a CachyOS live USB or equivalent UEFI recovery environment available.

## Manual recovery expectations

The tool is designed to preserve a firmware-visible source boot path for as long as possible, but users should still know how to recover independently.

Before using the switcher on a machine you care about, you should be comfortable with at least:

- opening the firmware boot picker
- booting a live Linux environment in UEFI mode
- mounting the ESP manually
- inspecting `efibootmgr -v`
- restoring or recreating a known-good bootloader entry if required

The switcher is not a substitute for firmware recovery knowledge.

## Live migration matrix

Every directed live migration between different supported bootloaders has completed the end-to-end transaction on the current hardware test system:

| Current source ↓ / Target → | GRUB | Limine | systemd-boot | rEFInd |
|---|---:|---:|---:|---:|
| **GRUB** | — | ✅ | ✅ | ✅ |
| **Limine** | ✅ | — | ✅ | ✅ |
| **systemd-boot** | ✅ | ✅ | — | ✅ |
| **rEFInd** | ✅ | ✅ | ✅ | — |

## Cross-backend restore matrix

Every directed restore between different supported bootloaders has also completed end-to-end on the current hardware test system:

| Current source ↓ / Backup target → | GRUB | Limine | systemd-boot | rEFInd |
|---|---:|---:|---:|---:|
| **GRUB** | — | ✅ | ✅ | ✅ |
| **Limine** | ✅ | — | ✅ | ✅ |
| **systemd-boot** | ✅ | ✅ | — | ✅ |
| **rEFInd** | ✅ | ✅ | ✅ | — |

Restore target requirements:

- **GRUB:** compatible v3 or v4
- **Limine:** compatible v3 legacy-reconstructable or v4 self-contained
- **systemd-boot:** v4
- **rEFInd:** v4

A backup must be both **VALID** and **COMPATIBLE** before it can be staged.

Same-backend restore is intentionally separate because a running backend and its own backup share canonical paths and firmware identities. It is not modeled as a fake cross-backend switch.

## Sequential restore sanity test

After the individual restore routes were covered, r46 was exercised through a continuous restore loop:

```text
rEFInd
  ↓ restore
GRUB
  ↓ restore
Limine
  ↓ restore
systemd-boot
  ↓ restore
rEFInd
```

Each restored backend:

1. staged from a validated backup
2. booted through firmware `BootNext`
3. reached userspace
4. passed runtime validation
5. finalized automatically
6. became first in persistent `BootOrder`
7. immediately served as the authoritative source for the next restore

This tests something different from isolated matrix cells: **restore-state composability**.

## Real-hardware failures that shaped r46

The successful matrix is only half of the engineering story.

Real-hardware testing also exposed failures that the transaction engine had to contain safely, including:

- a restore direction that was still gated even though the broader matrix had been assumed complete
- raw `cp -a` trying to preserve Unix ownership metadata onto a VFAT ESP during Limine v4 restore
- duplicate identical `/boot` mount layers left by `refind-install`
- legitimate rEFInd `PreviousBoot` updates being mistaken for immutable-tree tampering
- the need to distinguish direct rEFInd kernel boot from rEFInd → source-bootloader chainloading
- stale Limine source chainloader menu entries after successful source retirement
- loader-specific `BOOT_IMAGE=` / `initrd=` tokens leaking into Limine target policy
- Bash `set -u` / dynamic-scope bugs that only appeared in real transaction call paths
- a restore-support predicate that lagged behind the actual interactive dispatcher

The important result is not that failures never happened.

It is that, in the tested failure cases, the switcher refused to cross the destructive cleanup boundary or rolled back candidate state while preserving the previously working source.

Detailed revision history and the individual fixes live in [`CHANGELOG.md`](CHANGELOG.md).

## Running

```bash
git clone https://github.com/seba970423/cachyos-bootloader-switcher
cd cachyos-bootloader-switcher
./bootloader-switcher.sh
```

The script requests `sudo` only when a selected operation crosses a privileged validation or write boundary.

### Live migration

1. choose **Select bootloader to switch/repair**
2. choose the target bootloader
3. review the exact plan
4. type `STAGE`
5. allow the switcher to arm `BootNext`
6. reboot normally when prompted

### Cross-backend restore

1. choose **Restore a validated backup**
2. choose a backup marked `VALID, COMPATIBLE`
3. review the restore plan
4. type `RESTORE`
5. allow the switcher to arm `BootNext`
6. reboot normally when prompted

Do not manually bypass the one-time firmware test unless you are intentionally performing recovery.

## Safety invariants

r47 keeps the following rules:

- UEFI-only for live adapter transactions
- preserve the detected ESP topology
- never rewrite `/etc/fstab` as part of a switch or restore
- never silently replace an unrelated `BootNext`
- no source cleanup during candidate staging
- source remains first in persistent `BootOrder` until target runtime proof
- runtime proof must come from the exact recorded target NVRAM entry
- cleanup is limited to exact ownership-proven paths and NVRAM entries
- unrelated firmware entries are preserved
- foreign/shared BLS state is preserved
- shared `EFI/BOOT/BOOTX64.EFI` is treated as shared state
- reboot is explicitly prompted
- final target validation runs again after source retirement
- rollback re-proves the surviving source before recovery is considered complete

## Backend-specific notes

### GRUB

GRUB restore uses validated backup policy but rebuilds generated `/boot/grub` state from the current CachyOS packages and validated kernel set instead of blindly restoring stale generated modules/configuration.

Compatible legacy v3 backups require explicit integrity-manifest coverage.

### Limine

Limine supports:

- v3 legacy reconstruction from validated policy + current kernel/initramfs artifacts
- v4 self-contained restore

Managed kernel/initramfs payload restoration uses VFAT-safe copy semantics.

The CachyOS theme and splash are deep-validated.

During a first candidate boot, Limine may still show the protected source bootloader because the source intentionally still exists. After runtime proof, the exact source chainloader stanza is reconciled before source retirement.

### systemd-boot

The adapter follows CachyOS' normal systemd-boot tooling:

- package: `systemd-boot-manager`
- canonical EFI path: `\EFI\systemd\systemd-bootx64.efi`
- install/update tool: `bootctl`
- entry generation: `sdboot-manage`
- deterministic regular `linux-cachyos` default
- regular and LTS entries validated independently

`/boot/loader/entries` is treated as a shared namespace. Foreign BLS entries are not claimed.

For this backend, the currently validated topology requires the ESP at `/boot`.

### rEFInd

The adapter uses:

- package: `refind`
- installer: `refind-install`
- canonical EFI path: `\EFI\refind\refind_x64.efi`
- `/boot/refind_linux.conf` for the known-good kernel command line

Loader-only `BOOT_IMAGE=` / `boot_image=` / `initrd=` tokens are filtered rather than treated as portable kernel policy.

`EFI/refind/vars` is mutable runtime state and is excluded from immutable ownership hashes.

Runtime certification requires fresh `PreviousBoot` evidence proving that rEFInd directly launched the running CachyOS `vmlinuz-*` kernel. Chainloading the protected source does not qualify.

## Transaction architecture

The project uses source and target adapters so the dangerous transaction choreography is shared rather than reimplemented for every pair.

```text
SOURCE adapter
  validate()
  snapshot()
  preserve_recovery()
  retire()

TARGET adapter
  stage()
  validate()
  arm()
  runtime_validate()
  promote()
  final_validate()
```

Shared flow:

```text
source.validate
→ source.snapshot
→ target.stage
→ target.validate
→ source stays first in persistent BootOrder
→ target gets one-time BootNext
→ explicit reboot prompt
→ target reaches userspace
→ runtime proof
→ target.promote
→ source.retire
→ target.final_validate
```

For the deeper ownership and rollback model, see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Regression tests

```bash
bash tests/selftest.sh
```

The suite covers, among other things:

- source/target adapter contracts
- all 12 directed live-migration routes
- all 12 directed cross-backend restore routes
- restore-support predicate consistency
- GRUB v3/v4 restore policy validation
- systemd-boot deep validation and narrow BLS ownership
- rEFInd immutable ownership and direct-kernel `PreviousBoot` proof
- Limine inactive-residue handling and rollback
- Limine post-proof source-menu reconciliation
- shared EFI fallback preservation
- NVRAM path parsing
- pending-state integrity
- rollback dispatch
- VFAT-safe Limine managed-payload restore
- Bash `set -u` / dynamic-scope regressions found during hardware testing

Passing tests are **not** treated as a substitute for real firmware proof.

## BTRFS compatibility
Btrfs root filesystems are supported by the topology-aware design. Snapper can coexist with the switcher, but bootable-snapshot integration such as grub-btrfs has not yet been explicitly validated.

## Documentation

- [`CHANGELOG.md`](CHANGELOG.md) — revision history and real-hardware discoveries
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — transaction framework and ownership model
- [`docs/HARDWARE-VALIDATION.md`](docs/HARDWARE-VALIDATION.md) — matrix evidence and sequential restore finisher
- [`docs/BACKUP-RESTORE.md`](docs/BACKUP-RESTORE.md) — backup formats and restore contracts

## CachyOS references

- CachyOS Calamares bootloader configuration: <https://github.com/CachyOS/cachyos-calamares/blob/cachyos/src/modules/bootloader/bootloader.conf>
- CachyOS bootloader post-setup: <https://github.com/CachyOS/cachyos-calamares/blob/cachyos/src/scripts/bootloader-post-setup>
- CachyOS `systemd-boot-manager`: <https://github.com/CachyOS/CachyOS-PKGBUILDS/tree/master/systemd-boot-manager>
