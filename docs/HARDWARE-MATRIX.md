# Hardware Matrix

## Status

As of **2026-09-06**, the complete four-bootloader cross-loader matrix has been exercised successfully on the project openSUSE Leap 16 UEFI test machine.

There are four supported bootloaders, which produces six unique cross-loader pairs and twelve directed edges. The project validates each directed edge twice: once as a live switch and once as a backup restore.

```text
12 directed live-switch workflows
+ 12 directed cross-loader restore workflows
= 24/24 hardware-proven workflows
```

## Live switch matrix

Source rows → target columns:

| Source \ Target | GRUB2 | Limine | systemd-boot | rEFInd |
| --- | --- | --- | --- | --- |
| **GRUB2** | — | ✅ HW-PROVEN | ✅ HW-PROVEN | ✅ HW-PROVEN |
| **Limine** | ✅ HW-PROVEN | — | ✅ HW-PROVEN | ✅ HW-PROVEN |
| **systemd-boot** | ✅ HW-PROVEN | ✅ HW-PROVEN | — | ✅ HW-PROVEN |
| **rEFInd** | ✅ HW-PROVEN | ✅ HW-PROVEN | ✅ HW-PROVEN | — |

## Cross-loader restore matrix

Active source rows → restored backup target columns:

| Active source \ Restored target | GRUB2 | Limine | systemd-boot | rEFInd |
| --- | --- | --- | --- | --- |
| **GRUB2** | — | ✅ HW-PROVEN | ✅ HW-PROVEN | ✅ HW-PROVEN |
| **Limine** | ✅ HW-PROVEN | — | ✅ HW-PROVEN | ✅ HW-PROVEN |
| **systemd-boot** | ✅ HW-PROVEN | ✅ HW-PROVEN | — | ✅ HW-PROVEN |
| **rEFInd** | ✅ HW-PROVEN | ✅ HW-PROVEN | ✅ HW-PROVEN | — |

## Backup backends

| Backup backend | Status |
| --- | --- |
| GRUB2 | ✅ HW-PROVEN |
| Limine | ✅ HW-PROVEN |
| systemd-boot | ✅ HW-PROVEN |
| rEFInd | ✅ HW-PROVEN |

## What `HW-PROVEN` means here

A matrix cell is promoted to `HW-PROVEN` only after the relevant workflow has completed on real hardware through the required proof and retirement boundaries. It is not awarded merely because staging succeeded or because a unit/selftest passed.

Depending on the target, the evidence includes:

- the exact target becoming `BootCurrent`
- the expected one-time `BootNext` being consumed
- the running kernel/root/cmdline matching transaction expectations
- immutable target ownership remaining intact
- backend-native deep boot-chain validation
- source recovery remaining valid until proof
- target-specific final topology proof
- exact ownership-gated source retirement
- automatic post-reboot resume/finalization where the workflow is designed to automate it

## Final systemd-boot ↔ rEFInd hole

The last pair closed on 2026-09-06.

Representative completed transactions in the final diagnostic archive include:

```text
20260906-001817-switch-systemd-boot-to-refind
20260906-002023-switch-refind-to-systemd-boot
20260906-002352-restore-systemd-boot-to-refind
20260906-002624-restore-refind-to-systemd-boot
```

Each direction reached successful automatic resume/finalization evidence before the matrix was considered complete.

## Limine two-proof requirement

A Limine target is deliberately stronger than a single target boot. Source retirement is gated by two independent hardware proofs:

1. canonical Limine (`EFI/LIMINE/LIMINE_X64.EFI`)
2. the byte-identical generic fallback (`EFI/BOOT/BOOTX64.EFI`)

This contract applies to both live migration and restore.

## Test scope and limitations

The hardware campaign proves the transaction logic against the tested openSUSE Leap 16 installation and its real UEFI firmware behavior, including firmware alias churn encountered during development.

It does **not** guarantee that every motherboard/firmware implementation will expose identical NVRAM behavior. The fail-closed ownership model exists specifically because firmware behavior can differ.

A new platform should therefore preserve the same rule: do not infer universal firmware compatibility from this matrix, and do not weaken ownership gates just to make a new machine pass.
