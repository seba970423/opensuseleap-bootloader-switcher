# Testing

## Two different kinds of proof

The project distinguishes **regression coverage** from **hardware proof**.

A shell selftest can prove that a dispatcher, ownership predicate, rollback path, or state transition behaves as expected under its fixture. It cannot prove that real UEFI firmware will boot the staged identity or preserve the expected NVRAM topology.

`HW-PROVEN` is therefore reserved for completed real-hardware workflows.

## Revision selftests

The `tests/leap16-rXX-selftest.sh` files correspond to the revision overlays in `lib/leap16_rXX.sh`.

They are intentionally retained because later releases depend on the accumulated behavior of the earlier overlays. A revision test often reproduces the exact failure shape that originally appeared on hardware before proving its fix.

For the current release, the focused test is:

```bash
bash tests/leap16-r86-selftest.sh
```

The older revision tests remain useful when changing code they cover.

## Syntax validation

Before packaging a documentation or code change, validate every shell file:

```bash
find . -type f -name '*.sh' -print0 \
  | xargs -0 -n1 bash -n
```

The main executable should remain executable:

```bash
test -x ./bootloader-switcher.sh
```

## Inherited test suites

`tests/selftest.sh` is an inherited historical core suite and contains revision-era documentation/package assertions from the pre-Leap lineage. It is valuable regression material, but it is not by itself the release-status oracle for the current Leap overlay chain.

The current Leap release verdict should come from the relevant Leap selftests plus hardware evidence for any changed write path.

## Hardware acceptance criteria

A normal cross-loader live or restore workflow is considered complete only when all required boundaries pass without accepting manual cleanup as success.

Typical criteria are:

1. source is deeply valid before staging;
2. target is staged without premature source retirement;
3. firmware boots the exact target identity;
4. running kernel, root and cmdline match the transaction;
5. target-owned bytes still match the recorded candidate;
6. the backend-native boot chain passes deep validation;
7. source recovery remains valid until the target is proven;
8. target-specific final topology is established;
9. only ownership-proven source state is retired;
10. final firmware and filesystem topology passes validation;
11. automatic resume completes where automation is part of the workflow.

Limine adds an independent second `EFI/BOOT` hardware proof.

rEFInd adds fresh `PreviousBoot` direct-kernel evidence.

## Diagnostics as test evidence

The default diagnostic root is:

```text
~/opensuse-bootloader-diagnostics
```

Captures are timestamped by transaction phase and may contain:

- `efibootmgr` state
- pending transaction metadata
- firmware baselines
- source/target ownership manifests
- EFI hashes
- bootloader configuration
- kernel/cmdline evidence
- automatic-resume results

Preserve failed-state diagnostics before attempting any recovery action.

## Current hardware milestone

The 2026-09-06 diagnostic campaign completed all 24 directed live/restore workflows. See [HARDWARE-MATRIX.md](HARDWARE-MATRIX.md).

A future functional refactor that changes the transaction engines should not inherit that status automatically. It should first demonstrate regression equivalence, then re-run the hardware edges affected by the refactor.
