# leap16-r83 — rEFInd -> Limine fallback alias ID capture repair

## Hardware observation

After the r82 retry, the machine returned to the already-proven canonical Limine checkpoint:

- `BootCurrent: 0000` (canonical Limine)
- `BootOrder: 0000,0001` (Limine, exact rEFInd recovery)
- no `EFI/BOOT` fallback alias remained
- no temporary resume service existed and there were no current-boot service journal entries

That topology is consistent with the r64 fail-closed pre-fallback restoration path and proves that proof #2 was not earned.

## Root cause

`leap16_r64_promote_and_stage_limine_fallback()` captures the fallback ID with command substitution:

```bash
fallback_id=$(leap16_r64_create_or_adopt_limine_fallback_alias)
```

When a fallback alias must be newly created, the r64 wrapper called `r28_create_alias_create_only`. That helper prints a human `[OK] ...` line on stdout and stores the actual ID in `R28_CREATED_ALIAS_ID`. The wrapper then printed the ID on stdout too. Command substitution therefore captured both lines, not a four-digit ID.

The next `leap16_r64_update_limine_fallback_meta` gate correctly rejects the contaminated value because it is not `^[0-9A-F]{4}$`. Existing fail-closed rollback then removes the newly-created fallback alias, restores pre-transfer `EFI/BOOT` and `limine.conf`, and re-establishes `Limine,rEFInd` ordering. This exactly explains the observed post-reboot state.

## r83 repair

r83 overrides only `leap16_r64_create_or_adopt_limine_fallback_alias`:

- all r64 alias count/path/ESP ownership gates are preserved;
- `r28_create_alias_create_only` status output is redirected to stderr;
- stdout is guaranteed to contain only the exact four-hex-digit Boot ID;
- the returned ID is checked again before use.

No runtime-proof, fallback-proof, source-retirement, rollback, or bounded firmware-alias rules are relaxed.

## Hardware status

Canonical rEFInd -> Limine proof #1 remains hardware-proven from r81. The independent `EFI/BOOT` proof #2 and subsequent rEFInd retirement remain hardware-pending until a complete r83 run succeeds.
