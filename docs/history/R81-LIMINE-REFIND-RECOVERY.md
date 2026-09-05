# r81 — Limine/rEFInd recovery contract and diagnostic repair

## What the supplied r80 bundle establishes

All times below are the diagnostic filenames/local timestamps from September 5, 2026.

| Operation | Evidence in this bundle | Outcome |
| --- | --- | --- |
| GRUB2 → Limine baseline preparation | 21:05–21:08 checkpoints; canonical and fallback proofs; GRUB retirement | Final Limine order `0000,0003` |
| Limine → rEFInd live | `20260905-212447-switch-limine-to-refind/resume.log`; direct-kernel PreviousBoot proof; ownership-gated retirement | Completed automatically; final `BootCurrent: 0001`, `BootOrder: 0001` |
| rEFInd → Limine live | `20260905-212929-switch-refind-to-limine/stage.log` | Failed at candidate deep validation before commit; automatic rollback restored authoritative rEFInd |
| Either Limine/rEFInd backup restore | No restore transaction completion trace in this archive | No new restore hardware certification from this bundle |

The handoff's GRUB2 ↔ rEFInd live and both restore results remain HW-PROVEN. The clean GRUB `0002,0001` topology is the earlier starting baseline, not the latest state shown by these logs. The last captured reverse attempt identifies rEFInd Boot0001 and verifies its source after rollback.

The handoff describes the Limine/rEFInd campaign as completed with problems. This package records the narrower evidence available in the attached diagnostics; successful live switching cannot certify either restore direction, and local regression tests cannot certify hardware.

## Confirmed defects

1. **Wrong candidate recovery path.** Finalized rEFInd intentionally leaves no owned `EFI/BOOT/BOOTX64.EFI`. r64 nevertheless reused the GRUB-style `/EFI fallback` Limine stanza and changed only its comment to mention rEFInd. The effective validator had no rEFInd-specific branch and rejected that dangling recovery path. Kernel copies, BLAKE2 checks and the CachyOS theme all passed before this failure.
2. **False final firmware report.** The successful Limine → rEFInd checkpoint contains `assessment=fail` with `source recovery Boot0000 is not active after promotion`, although source retirement was complete and the exact rEFInd target was the sole firmware entry. The reporter still assessed a pre-retirement contract.
3. **Missing rEFInd-target checkpoint export.** The effective runtime collector handled GRUB, Limine and systemd-boot, then used a historical CachyOS fallback directory for rEFInd. This explains why the successful rEFInd transaction has a resume transcript and late checkpoint but lacks the complete intermediate runtime/final checkpoint set in its openSUSE bundle.

## Changes

- Before any Limine candidate deep validation, convert exactly one generated or restored fallback stanza to direct canonical `EFI/refind/refind_x64.efi` recovery. Keep the canonical rEFInd tree intact; preserve the original generic fallback bytes or absence.
- Validate the complete recovery stanza and exact source/target hashes for the actual transaction phase. Reject duplicate recovery entries, changed source bytes, unexpected fallback appearance and changed pre-stage fallback bytes.
- Keep direct rEFInd recovery through canonical Limine proof and the EFI/BOOT transfer. Freeze an exact pre-transfer config copy for rollback at the existing transfer boundary.
- After the unchanged second Limine runtime proof, convert the temporary rEFInd recovery stanza into the visible `/EFI fallback` block. The old r64 finalizer would simply delete the entry, repeating the menu omission already fixed for the systemd-boot path in r59.
- Allow at most two alias normalization passes at each existing boundary, so one same-path firmware re-synthesis wave can converge automatically. Recheck path/ESP ownership after removing duplicate IDs from BootOrder and before deletion. Continued churn, baseline-ID collisions, changed identities, failed enumeration or a failed deletion refuse success.
- Route the pair's runtime captures through the openSUSE collector. Export rEFInd config, PreviousBoot text, EFI hashes and edge metadata. Keep a transaction-bound **report-only** baseline through snapshot removal. Reporting examines complete firmware tables, including parked duplicates, expected retirement, exact path/ESP binding, and unrelated baseline entries/order.

The public menu and strict transcript-child allowlist are unchanged. Existing GRUB2/rEFInd proof and cleanup engines are delegated unchanged. No installer, package, theme, root/kernel/cmdline, ownership or independent boot-proof gate is removed. No new runtime dependency is introduced.

## Hardware retest

For the last state shown in this bundle, launch the extracted r81 `./bootloader-switcher.sh` and choose the normal switch to Limine. The failed r80 attempt never committed a candidate; its log shows automatic rollback, so it does not call for manual EFI/NVRAM cleanup or a GRUB baseline repair.

Expected sequence:

1. Candidate validation accepts **direct canonical rEFInd recovery** while generic fallback state is unchanged.
2. First reboot proves canonical Limine with rEFInd still available.
3. The existing engine transfers EFI/BOOT to byte-identical Limine and arms its separate fallback BootNext.
4. Second reboot proves that exact fallback identity. Only then may rEFInd be retired.
5. Final topology has exactly one canonical Limine alias and one genuine fallback alias, first and second in BootOrder; no canonical rEFInd source alias remains. The menu retains the visible EFI fallback entry, and final firmware-order reporting passes.

Capture the complete stage/resume/checkpoint folder. Each restore direction must subsequently complete its own selected-backup transaction and fresh boot proof(s), with backup provenance retained in the result. No manual cleanup counts as a completed matrix edge.

## Local validation

See `R81-TEST-REPORT.txt`. These checks use temporary files, real config/hash helpers, captured firmware fixtures and simulated firmware mutations. They do not execute a real firmware update, live switch, reboot or restore on the user's hardware.
