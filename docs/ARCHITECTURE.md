# Architecture

## Purpose

openSUSE Bootloader Switcher is a transactional migration and recovery engine for four UEFI bootloaders on openSUSE Leap 16:

- GRUB2
- Limine
- systemd-boot
- rEFInd

The central design rule is that **installation is not proof**. A target is trusted only after the machine has actually booted it and the runtime state matches the transaction that staged it.

## Layered implementation

The project currently uses a revision-overlay architecture.

`bootloader-switcher.sh` loads the inherited core modules first, then the openSUSE Leap adapter, followed by `lib/leap16_r21.sh` through `lib/leap16_r86.sh` in order. Later overlays intentionally replace or wrap selected functions from earlier revisions.

That means the revisioned files in `lib/` are part of the effective r86 program. They should not be deleted merely because their names look historical.

The matching revisioned tests serve the same purpose: they preserve regressions and assumptions exposed during the hardware campaign.

Development notes and test reports, by contrast, are non-executable history and are archived under `docs/history/`.

## Transaction lifecycle

A typical cross-loader migration is split into ownership, staging, runtime proof, finalization, and retirement boundaries.

### 1. Source capture

Before a target is committed, the switcher records the working source state, including the relevant combination of:

- `BootCurrent`
- persistent `BootOrder`
- source EFI path and hash
- ESP identity
- root filesystem identity
- source-owned files
- source/fallback ownership
- known-good kernel command line
- a complete pre-stage firmware baseline

The source is still authoritative at this point.

### 2. Candidate staging

The target is constructed or restored without deleting the source. Candidate-owned files and firmware entries are recorded so later code can distinguish transaction-owned state from unrelated firmware state.

The target normally remains behind the source in persistent `BootOrder` while a one-time `BootNext` is armed.

### 3. Boot-armed state

The target receives a one-time firmware boot request. A temporary root-owned systemd resume service is prepared so the transaction can continue after reboot.

The persistent source recovery path remains intact until runtime proof succeeds.

### 4. Runtime proof

After reboot the switcher proves that the running system is the exact target that was staged. Depending on the backend, the gate includes:

- exact `BootCurrent` identity
- exact ESP + EFI path
- consumed/cleared `BootNext`
- installed/running kernel identity
- root filesystem identity
- token-equivalent kernel command line
- immutable target ownership
- backend-native deep boot-chain validation
- passive validation of the still-retained source recovery path

Only then is the pending transaction promoted to `runtime-validated`.

### 5. Final topology proof

Each backend has its own final proof contract.

#### GRUB2

The Leap GRUB backend validates native `/boot/grub2` state, openSUSE policy, shim/direct-GRUB identities, and the owned generic fallback topology before the previous source is retired.

#### Limine

Limine requires two independent hardware identities:

1. canonical `EFI/LIMINE/LIMINE_X64.EFI`
2. byte-identical `EFI/BOOT/BOOTX64.EFI`

The old source remains recovery until the second boot has actually happened and passed runtime proof.

#### systemd-boot

systemd-boot proves its native BLS entries and payloads, then finalization transfers byte-identical systemd-boot to the generic `EFI/BOOT` path and proves the resulting topology before source retirement.

#### rEFInd

rEFInd proves a direct Leap kernel boot using canonical rEFInd plus fresh `PreviousBoot` runtime evidence. It intentionally does not claim `EFI/BOOT`, because a bare rEFInd EFI binary is not a complete fallback environment without its config/driver/resource tree.

### 6. Source retirement

Source cleanup is the final privilege, not an early convenience.

Retirement is restricted to exact ownership-proven files and firmware entries. Same-path firmware aliases are handled only within bounded, baseline-aware rules; unrelated pre-stage IDs are not reclassified as transaction-owned.

If ownership cannot be proven, finalization stops.

## Automatic resume

The temporary openSUSE resume service is:

```text
opensuse-bootloader-switcher-resume.service
```

Its root-owned transaction bundle lives below:

```text
/var/lib/opensuse-bootloader-switcher/
```

The normal-user shadow state lives below:

```text
~/.local/state/opensuse-bootloader-switcher/
```

The service exists only to continue a staged transaction after the target boot. It is removed after success or a terminal fail-closed condition.

## Restore architecture

Restore deliberately reuses the live transaction engines.

A validated backup supplies target bytes and policy at the restore write boundary, but it does not carry authority to retire the currently working source. The restored target must still earn the same runtime and final-topology proofs as a freshly staged target.

This separation prevents an old but structurally valid backup from being treated as proof that the restored state boots today.

## Firmware ownership and alias churn

Real UEFI firmware can synthesize, renumber, or duplicate entries. The project therefore does not rely on a Boot#### number alone as ownership.

Ownership decisions combine the pre-stage firmware table with the expected ESP, EFI path, hashes, transaction metadata, and bounded alias rules.

The implementation intentionally fails closed when firmware churn cannot be reconciled within those boundaries.

## State and evidence

Default paths:

```text
Backups:      ~/opensuse-bootloader-backups
State:        ~/.local/state/opensuse-bootloader-switcher
Diagnostics:  ~/opensuse-bootloader-diagnostics
```

Diagnostics capture transaction metadata, firmware state, boot-chain artifacts, hashes, cmdline/runtime evidence, and relevant ownership manifests so a failed transition can be diagnosed without first destroying the evidence.

## Refactoring rule

The revision overlay stack is ugly but currently hardware-proven as a whole. A future squash into subsystem modules should be treated as a behavior-preserving refactor, not as cleanup-by-deletion.

The r86 transaction contracts and hardware matrix are the compatibility baseline for that work.
