# leap16-r84 — rEFInd → Limine post-proof baseline ownership repair

## Hardware evidence

The Sep 5 r83 run reached the second independent Limine proof successfully:

- fallback alias: `Boot0002` → `\EFI\BOOT\BOOTX64.EFI`
- `BootCurrent=0002`
- `BootOrder=0000,0002,0001`
- canonical `Boot0000` and fallback `Boot0002` carry the same Limine EFI hash
- canonical rEFInd `Boot0001` remained intact and passive
- the automatic resume transcript reached `FALLBACK-RUNTIME-VALIDATED`

Finalization then stopped before source retirement with:

```text
[FAIL] Recorded Limine primary Boot0000 reuses a pre-stage firmware ID; refusing ownership
```

The immutable r64 baseline in the same diagnostic bundle contains only pre-stage `Boot0001` rEFInd. `Boot0000` was therefore genuinely post-stage and should not have been classified as a baseline collision.

## Root cause

`leap16_r80_baseline_line_for_id()` used:

```bash
grep -Ei "^Boot${id}\\*?[[:space:]]" "$baseline" | head -n1
```

The switcher runs with `set -u` but not global `set -o pipefail`. If `grep` found no matching Boot ID, `head` still returned success, so `leap16_r80_id_existed_in_baseline()` falsely treated every syntactically valid ID as pre-existing whenever the baseline file itself existed.

## r84 repair

r84 preserves the r80 ownership policy and changes only the lookup's shell-status contract:

```bash
grep -Eim1 "^Boot${id}\\*?[[:space:]]" "$baseline"
```

GNU grep's own `-m1` limit removes the pipeline. A real match returns success; an absent ID returns failure regardless of `pipefail`.

This means:

- pre-stage IDs are still ownership-gated exactly as before;
- unrelated baseline-ID reuse still fails closed;
- genuinely post-stage Limine IDs are no longer rejected as phantom baseline reuse;
- no proof, alias normalization, source retirement, rollback, or restore gate is weakened.

## Retry semantics

The r83 failure occurred at the first post-proof alias-ownership normalization gate, before final Limine config conversion or rEFInd retirement. The transaction therefore remains retryable. If the machine is still running fallback `Boot0002`, r84 can revalidate proof #2 and finish migration directly from `--manage-staged`; no additional fallback proof reboot is required.

The rEFInd → Limine live edge remains `HW-PENDING` until ownership-gated source retirement completes successfully on hardware. Both Limine/rEFInd restore directions remain independently `HW-PENDING`.
