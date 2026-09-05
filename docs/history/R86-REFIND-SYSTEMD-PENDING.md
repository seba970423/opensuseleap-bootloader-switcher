# leap16-r86 — rEFInd -> systemd-boot pending-manager dispatch repair

## Hardware symptom

The r85 hardware retry was still in the original format-v5 transaction:

- phase: `boot-armed`
- source: rEFInd `Boot0001`
- target: systemd-boot `Boot0000`
- the machine was already running the exact systemd-boot target.

Invoking:

```bash
./bootloader-switcher.sh --manage-staged
```

printed the staged transaction details and then failed with:

```text
[FAIL] Current bootloader is neither the recorded GRUB2 source nor Limine target
```

This is an interactive pending-dispatch failure, not a systemd-boot boot failure.

## Root cause

r85 overrode `validate_pending_target_runtime()` for `refind:systemd-boot`, which repairs the path used by the root-owned automatic resume service. `--manage-staged` does not enter through that symbol: it enters through `manage_pending_migration()`.

The latest pending-manager overlay before r86 was r76, which intercepts only `refind:grub`. `refind:systemd-boot` therefore delegated through the historical manager chain until it reached the old GRUB2 -> Limine manager, whose final branch emitted the observed failure.

The transaction was not mutated by that failure. Runtime proof, promotion, fallback transfer and rEFInd retirement were not attempted.

## r86 repair

r86 adds a narrow format-v5 `refind:systemd-boot` pending manager after every older overlay.

Target-side states:

- `boot-armed` + exact systemd-boot `BootCurrent` -> r85 runtime validator.
- `runtime-validated` + exact systemd-boot `BootCurrent` -> unchanged r64 adapter finalizer.
- `candidate-ready` target sessions are rejected as manually entered/unarmed proof sessions.

Source-side states:

- `candidate-ready` -> existing source/target validation, generic safe arm+resume, or rollback.
- `boot-armed` -> integrity recheck/cancel/rollback while rEFInd stays authoritative.
- `runtime-validated` -> existing proven-target re-arm helper, ownership recheck, or rollback.

Restore provenance does not alter dispatch. A restored systemd-boot backup from active rEFInd produces the same `source=refind`, `target=systemd-boot` transaction and therefore uses this exact manager and the r85/r64 proof/finalization stack.

## Safety invariants preserved

r86 does not replace or relax:

- source-first BootOrder before first runtime proof;
- exact BootCurrent/path/ESP identity;
- running kernel and cmdline equivalence;
- immutable target ownership checks;
- deep native openSUSE systemd-boot validation;
- passive rEFInd recovery proof;
- runtime-validated persistence;
- r64 target promotion and exact EFI/BOOT transfer;
- source retirement only after final target topology proof;
- fail-closed rollback semantics.

The currently running r85 hardware transaction is intended to be resumed in place. No restaging, reboot, NVRAM cleanup, or manual repair is required before trying r86.
