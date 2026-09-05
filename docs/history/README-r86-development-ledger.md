# openSUSE Bootloader Switcher — leap16-r86

**leap16-r86:** repairs the second half of the hardware-exposed rEFInd → systemd-boot routing hole. r85 added the missing runtime validator used by automatic resume, but `--manage-staged` enters through a separate pending-manager overlay chain. On the already-running exact systemd-boot target, that chain still fell through to the historical GRUB2 → Limine manager and safe-failed with `Current bootloader is neither the recorded GRUB2 source nor Limine target`. r86 intercepts only format-v5 `refind:systemd-boot` pending state, routes target-side `boot-armed` to the r85 runtime validator and `runtime-validated` to the unchanged r64 ownership-gated finalizer, and provides direction-correct source-side re-arm/rollback controls. Restore-backed systemd targets use the same pending state machine. No boot proof, ownership, fallback-transfer, or source-retirement gates are weakened. See `R86-REFIND-SYSTEMD-PENDING.md`.

# openSUSE Bootloader Switcher — leap16-r85

**leap16-r85:** repairs the first hardware-exposed rEFInd → systemd-boot runtime-dispatch hole. r84 staged the exact native systemd-boot target, preserved rEFInd first in persistent `BootOrder`, armed `BootNext`, and the machine booted the recorded systemd-boot `BootCurrent`. The root-owned r64 resume correctly recognized the rEFInd edge, but its generic runtime-validation call fell through every direction-specific overlay to the historical Limine-only validator and safe-failed with `Current bootloader is systemd-boot, not Limine`. No target proof, promotion, fallback transfer, or rEFInd retirement ran. r85 adds only the missing `refind:systemd-boot` runtime validator/dispatcher, reusing the existing deep native systemd-boot gate, exact candidate ownership, running kernel/cmdline proof, and passive rEFInd recovery proof. The same validator covers rEFInd → restored systemd-boot backups; staging/finalization/restore payload logic is unchanged. See `R85-REFIND-SYSTEMD-RUNTIME.md`.

**leap16-r84:** fixes the post-proof ownership false positive exposed by the first successful rEFInd → Limine fallback hardware boot. r83 reached `BootCurrent=Boot0002`, passed the complete second Limine runtime proof, and retained exact rEFInd recovery; finalization then failed before retirement because r80 used `grep | head` as a boolean baseline-ID predicate while the switcher does not enable global `pipefail`. A missing post-stage Boot ID was therefore misreported as pre-existing. r84 keeps the ownership policy unchanged and makes the lookup return grep's real match status.


**leap16-r83:** fixes the hardware-exposed rEFInd → Limine fallback-alias ID capture bug. r82 correctly repaired the `Limine,rEFInd` promotion order, but a newly-created fallback alias emitted a human `[OK]` status line into command-substitution stdout, contaminating the machine-readable Boot ID. The following metadata gate correctly failed closed and restored the proof-#1 topology. r83 redirects that status output away from the ID channel while preserving all existing ownership, proof, rollback and retirement gates.

See [R83-REFIND-LIMINE-FALLBACK-ID.md](R83-REFIND-LIMINE-FALLBACK-ID.md) for the diagnosis. Canonical proof #1 remains earned; proof #2 and rEFInd retirement remain hardware-pending.

**leap16-r82:** repairs the hardware-exposed rEFInd → Limine promotion-order bug after r81 successfully earned canonical Limine proof #1. The reverse edge now uses the dedicated two-proof `Limine,rEFInd` persistent ordering helper instead of the generic target promotion helper that intentionally drops the source from `BootOrder`. This is performed only after the existing canonical-Limine runtime, cmdline, deep target, immutable ownership and passive-rEFInd recovery gates pass.

The r81 recovery-menu, diagnostics and bounded alias-normalization hardening remains unchanged. r82 also resumes the exact r81 stranded `runtime-validated` state without manual NVRAM cleanup: it reconstructs `Limine,rEFInd` first, and only then may it transfer byte-identical Limine into `EFI/BOOT`, create/adopt the fallback alias and arm the independent second BootNext proof. rEFInd retirement still requires that second proof.

See [R82-REFIND-LIMINE-PROMOTION.md](R82-REFIND-LIMINE-PROMOTION.md) for the new hardware diagnosis and [R81-LIMINE-REFIND-RECOVERY.md](R81-LIMINE-REFIND-RECOVERY.md) for the preceding recovery/diagnostic repair. Run `bash tests/leap16-r82-selftest.sh` for the focused regression suite. Historical revision notes follow below.

# openSUSE Bootloader Switcher — leap16-r78

**leap16-r78:** fixes the fresh-process PTY dispatch omission exposed by the first r77 finalized-GRUB duplicate cleanup attempt. The parent correctly selected the NVRAM-only `grub -> grub` cleanup, but the strict r46 transcript child still inherited r75's allowlist and rejected `leap16_r77_cleanup_finalized_grub_duplicates_inner` before any cleanup preflight or firmware write. r78 admits exactly that zero-argument `grub -> grub`, `cleanup` contract and delegates every existing transcript child unchanged. See `R78-GRUB-DUPLICATE-CLEANUP-DISPATCH.md`.

# openSUSE Bootloader Switcher — leap16-r76

**leap16-r76:** fixes the outbound rEFInd -> native GRUB runtime dispatcher exposed by the r75 hardware run. The exact staged openSUSE shim target booted Leap successfully, but automatic resume fell through to the historical Limine-only validator and stopped before promotion or rEFInd retirement. r76 adopts that still-safe `boot-armed` target session in place, requires the complete native GRUB candidate/runtime and passive rEFInd recovery proof, persists `runtime-validated`, and leaves finalization as the separate unchanged r64 ownership gate. It does not restage, repair, roll back, weaken validation, or touch the persistent rEFInd-first recovery order before proof. See `R76-REFIND-GRUB-RUNTIME.md`.

**leap16-r75:** preserves the unchanged r64 clean-target gate and adds a separate fail-closed cleanup for the ownership-proven orphaned r66/r67 rEFInd filesystem residue left by the earlier finalized-rEFInd/failed-return sequence. Cleanup is offered only from canonical native GRUB when no canonical same-ESP rEFInd alias exists; it requires the exact controlled-source marker, managed config marker, deterministic current-cmdline `refind_linux.conf`, safe tree shape, and full deep rEFInd validation. It snapshots exact bytes/manifests, deletes only `EFI/refind` plus `/boot/refind_linux.conf`, proves the complete firmware table and GRUB are unchanged, and stops. The user must select rEFInd again to stage through the original clean-target gate. See `R75-REFIND-RESIDUE.md`.

**leap16-r74:** fixes the fresh-process PTY dispatch omission exposed by the first r73 repair attempt. The strict r46 transcript child now admits exactly `leap16_r73_run_repair_inner` with the fixed `grub -> grub`, `repair`, zero-argument contract; arbitrary child commands remain rejected. The failed r73 run stopped before preflight and changed no boot state. See `R74-GRUB-REPAIR.md`.

**leap16-r73:** adds a narrow, fail-closed native openSUSE same-GRUB repair for the hardware-observed r70 rollback residue. It reconstructs missing `/etc/default/grub`, the packaged openSUSE theme, and `/boot/grub2/grub.cfg`; retains the running shim/direct EFI bytes until the unchanged deep validator passes; refreshes the native EFI layer with `shim-install --no-nvram` under exact rollback ownership; then normalizes only exact same-ESP shim/direct NVRAM aliases. The inherited CachyOS/Arch repair path is never called. See `R73-GRUB-REPAIR.md`.

**leap16-r72:** fixes the future pre-commit rollback leak that created this contamination. It does not reinterpret or silently clean an already-contaminated current GRUB installation. See `R72-REFIND-MATRIX.md`.

**leap16-r71:** fixes outgoing rEFInd -> GRUB2 candidate validation so it preserves the actual finalized-rEFInd source invariants instead of reusing systemd-boot-specific fallback and LOADER_TYPE assertions. A finalized rEFInd source may legitimately have no EFI/BOOT fallback and intentionally carries LOADER_TYPE=grub2-efi as the openSUSE compatibility value until GRUB earns runtime proof. See `R71-REFIND-MATRIX.md`.

**leap16-r70:** fixes finalized-rEFInd backup self-validation so the canonical raw UEFI BootCurrent path is compared literally rather than as a Bash glob pattern. The first r69 backup attempt safe-failed before any rEFInd -> GRUB2 staging because byte-identical `\EFI\refind\refind_x64.efi` values compared false when the RHS was unquoted. Backup schema/payload and transaction behavior are unchanged. See `R70-REFIND-MATRIX.md`.

## leap16-r67 — Leap-native rEFInd initrd/symlink validation

The first r66 hardware run to reach real rEFInd staging proved the controlled upstream 0.14.2 binary path, ext4 driver, manual ESP payload, scanner policy, and parked `efibootmgr --create-only` NVRAM entry. It then failed safely before candidate commit because the r64 Leap rEFInd validator accidentally reused a CachyOS/Arch mkinitcpio (`lsinitcpio`) structural helper against Leap's dracut initrds.

r67 replaces that one stale assumption with a Leap-native `lsinitrd` structural gate and explicitly enables `follow_symlinks true`, an upstream rEFInd >=0.14.0 feature intended for openSUSE direct-kernel layouts. The existing GRUB2/Limine/systemd-boot transaction engines and rEFInd firmware choreography are unchanged.

# openSUSE Bootloader Switcher — leap16-r66


## leap16-r66 — controlled rEFInd binary staging after Leap repository safe-fail

The second GRUB2 -> rEFInd hardware stage proved that the configured Leap 16 repositories have no `refind` provider. r66 removes package/RPM/refind-install staging from the rEFInd transaction entirely. It uses the fixed upstream `refind-bin-0.14.2.zip` payload from the official SourceForge release (or an explicit local archive), validates the ZIP and required x64 EFI/ext4/config/icon payload, then manually stages only the transaction-owned `EFI/refind` tree. The canonical NVRAM alias is created only through the switcher's proven `efibootmgr --create-only` choreography, so no upstream post-install script can silently promote rEFInd or take over `EFI/BOOT`. The upstream project explicitly documents that its binary RPM copies files to the ESP and registers rEFInd as the default boot loader, which is incompatible with this source-first transaction boundary.

A self-contained rEFInd backup restore does **not** download the upstream ZIP: the already integrity-validated immutable backup tree is restored directly at the write boundary and must earn a fresh `PreviousBoot` runtime proof. r66 backup validation also no longer invents an RPM dependency; it accepts the exact controlled-binary source marker (while retaining legacy package identity compatibility) and still excludes mutable `EFI/refind/vars`. Live archive acquisition is checked before any target ESP/NVRAM mutation. Optional local pinning is available with `BOOTLOADER_SWITCHER_REFIND_ARCHIVE_SHA256=<sha256>`. See `R66-REFIND-MATRIX.md`.

## leap16-r65 — zypper option-scope hardware hotfix

The first GRUB2 -> rEFInd hardware stage exposed a package-manager CLI bug before any candidate was committed: r64 passed the install-command option `--no-recommends` as a global zypper option. Leap 16 rejected it with `The flag --no-recommends is not known.` r65 adds a capability-checked native installer helper using `zypper --non-interactive install --no-recommends ...`, preserving the fail-closed no-weak-dependency contract. The same latent ordering bug also existed in the previously unexercised fresh-package branches for systemd-boot and native GRUB/shim reconstruction, so r65 overrides all three effective installers. No transaction/proof/retirement algorithm is changed; the r64 rEFInd matrix remains hardware-pending.


## leap16-r64 — complete four-loader rEFInd implementation (hardware pending)

r64 adds rEFInd as a first-class Leap 16 backend without changing the already hardware-proven GRUB2/Limine/systemd-boot transaction engines. All six directed live edges involving rEFInd and all six corresponding cross-loader restore edges are enabled in code and regression-covered; they remain explicitly **HW-PENDING** until exercised on the real ASUS UEFI test machine. rEFInd backup creation is self-contained for immutable `EFI/refind` + `/boot/refind_linux.conf`; mutable `EFI/refind/vars` (including `PreviousBoot`) is intentionally excluded so a restored rEFInd target must earn fresh runtime evidence.

The Leap rEFInd target uses `zypper`/`refind-install`, never the inherited Arch/pacman path. The first hardware revision is deliberately fail-closed to the tested topology where `/boot` lives on the ext4 root filesystem and therefore requires the package-owned `drivers_x64/ext4_x64.efi`. If `refind` is unavailable from the configured repositories, a trusted local RPM can be supplied with `BOOTLOADER_SWITCHER_REFIND_RPM=/absolute/path/to/refind.rpm`; the switcher never downloads an unpinned rEFInd package itself. Scanner policy excludes all managed/source/reference EFI namespaces so the retained Limine reference tree cannot appear as an accidental rEFInd boot target.

rEFInd target proof is intentionally **not** modeled as a Limine-style generic-fallback proof: canonical rEFInd + `PreviousBoot` must prove that the running Leap kernel was directly launched, but rEFInd does not claim `EFI/BOOT` in r64 because a bare `refind_x64.efi` copy there would not carry its relative config/driver runtime tree. In contrast, `rEFInd -> Limine` retains the established two-independent-proof contract (canonical Limine, then byte-identical Limine `EFI/BOOT`) before rEFInd retirement. See `R64-REFIND-MATRIX.md` or `./bootloader-switcher.sh --matrix` for the complete evidence ledger.


## leap16-r63 — systemd-boot → restored Limine shared-parent merge fix

A real r62 restore reached the r51 staging engine and exposed one restore-only topology bug: Limine and systemd-boot intentionally share `ESP/<machine-id>` as a parent, but r61's Limine backup substitution still required that whole parent to be absent. A finalized systemd-boot source correctly owns only the `opensuse-bootloader-switcher` child there, so the restore failed closed before committing a candidate. r63 keeps the r51 two-proof firmware transaction unchanged and restores only the exact integrity-validated Limine per-kernel sibling directories beside the preserved systemd-boot child. Backup shape, destination shape, overlap, symlinks, and foreign children are rechecked at the write boundary; existing r51 rollback already removes only the Limine siblings.

## leap16-r62 — r61 restore transcript child dispatch fix

r61 correctly routed Limine ↔ systemd-boot backup restores through the existing r46 PTY transaction transcript wrapper, but the fresh child process still inherited r52's strict pre-r61 command allowlist. The result was a fail-closed `Refusing unknown r46 transcript child command` before restore preflight or firmware mutation. r62 extends that allowlist with exactly `leap16_r61_restore_systemd_backup_from_limine` and `leap16_r61_restore_limine_backup_from_systemd`; arbitrary child commands remain rejected. Restore validation, write-boundary revalidation, BootNext/proof/fallback/retirement behavior, and r61 diagnostic housekeeping are unchanged.

## leap16-r61 — Limine ↔ systemd-boot backup restore

r61 opens the final non-rEFInd user-backup restore pair after both direct live edges were hardware-proven. A Limine source can now restore a validated native systemd-boot v4 backup through the r48 Limine → systemd-boot transaction, and a finalized systemd-boot source can restore a validated Limine v4 backup through the r51 two-proof systemd-boot → Limine transaction. Restore substitutes only the already integrity-checked target policy/payload; source-first BootOrder, BootNext, runtime proof, fallback transfer, rollback, ownership manifests, retirement, and automatic resume remain owned by the proven live engines.

r61 also closes the last r60 diagnostic housekeeping splinter: a valid `staged-efibootmgr-v.txt` is no longer redundantly recaptured, and interrupted `.staged-efibootmgr-v.*` atomic scratch files are removed when the transaction is rebound or during trusted root resume synchronization. This changes diagnostic residue only, not boot state.

## leap16-r60 — shared diagnostic lifecycle repair

r60 changes evidence/reporting channels only. It preserves the hardware-proven
r59 migration, fallback, cleanup, backup, and restore execution paths unchanged.
The r59 Limine finalizer now keeps human `[OK]` text on stderr so its hash-valued
stdout cannot falsely fail an already-successful second-proof finalization. systemd-boot
runtime/final checkpoints now use the synchronized Leap diagnostic root;
staged `efibootmgr -v` evidence is installed atomically and cannot be replaced
by an empty late capture; direct Limine/systemd firmware-order reports understand
each proof/finalized topology and retain a report-only baseline cache through
post-finalization capture; and root resume sync sanitizes and closes PTY stage
transcripts whose interactive parent was terminated by the requested reboot.

## leap16-r50 — phase-aware Limine -> systemd-boot finalization

r48 hardware evidence proved the systemd-boot one-shot and every runtime/source ownership gate, but finalization stopped safely immediately after persistent systemd-boot promotion. The cause was a phase-order contradiction: r48 intentionally changed BootOrder from Limine-primary/Limine-fallback-first to systemd-boot-first, then re-ran an r48 recovery verifier whose final clause still required Limine to remain first. No fallback transfer, Limine NVRAM deletion, or Limine file retirement was attempted after that failure.

r49 keeps every byte/path/manifest/fallback ownership check and makes only the firmware-order expectation phase-aware. Before promotion it still requires Limine primary first and its exact generic-fallback alias second. After the runtime-proven systemd-boot target is first, it accepts only the exact promoted topology `target, Limine-primary, Limine-fallback`; the Limine primary/fallback variables, paths, ESP binding, source manifest, deep boot chain, and old Limine fallback bytes must all still be intact. This also allows the safe r48 post-promotion checkpoint to be resumed and completed without restaging.

## leap16-r47 — shared machine-id ESP namespace cleanup + systemd-boot backup/restore

r44 keeps the r43 GRUB2 <-> systemd-boot firmware/fallback transaction mechanics unchanged and activates the user backup layer for systemd-boot. Normal GRUB2 -> systemd-boot and systemd-boot -> GRUB2 switches once again offer the optional user backup before the write boundary; declining it does not affect the mandatory private transaction snapshot.

A systemd-boot backup is self-contained for the switcher-owned target state: canonical `EFI/systemd`, `loader.conf`, the exact per-kernel openSUSE BLS entries, and the machine-id `opensuse-bootloader-switcher` kernel/initrd payload tree. `/etc/sysconfig/bootloader` (and `/etc/kernel/cmdline` when present) are captured as policy/reference evidence. The generic `EFI/BOOT/BOOTX64.EFI` fallback is captured separately as byte-exact shared recovery evidence and must match the finalized canonical systemd-boot EFI. Restore is enabled only across the already-proven GRUB2 <-> systemd-boot transaction engines; Limine <-> systemd-boot restore remains locked with that unproven switch matrix.

r44 also records the interactive pre-reboot migration output in a timestamped transaction directory (`stage.log`) and carries its identity into the root-owned resume bundle so post-reboot `resume.log` and checkpoint diagnostics can be associated with the same transaction. Diagnostics remain folder-only; the tool does not create archives automatically.

## leap16-r43 retry hardening

r42 fixes a false "Target EFI executable changed" result on resumed systemd-boot -> GRUB2 finalization when a fresh interactive process has no cached `sudo -n` ticket. Reverse runtime proof/finalization now acquires sudo explicitly, and the reverse target hash verifier uses the existing privileged/readable hash helper while preserving the exact recorded hash + NVRAM path + ownership manifest gates.

# openSUSE Leap 16 Bootloader Switcher — leap16-r39

## r38: systemd-boot -> native openSUSE GRUB2 hardware-test edge

The GRUB2 -> systemd-boot edge is now hardware-proven end-to-end through one-shot BootNext, runtime proof, ownership-gated GRUB retirement, generic EFI fallback transfer, and a clean persistent systemd-boot reboot. r39 keeps those proven paths unchanged and repairs the reverse **systemd-boot -> GRUB2** hardware-test edge after the first real GRUB one-shot exposed an automatic-resume dispatch bug and baseline-distinguishable firmware/shim NVRAM churn.

The reverse candidate reconstructs native openSUSE `/boot/grub2` and `EFI/OPENSUSE` from the installed GRUB/shim toolchain, creates a parked direct `GRUBX64.EFI` alias plus a shim target with `efibootmgr --create-only`, keeps canonical systemd-boot first in persistent BootOrder, and preserves the byte-identical systemd-boot `EFI/BOOT/BOOTX64.EFI` fallback until GRUB has actually booted and passed exact runtime proof. Only after that proof may shim become persistent first, direct GRUB become second, the generic fallback transfer to shim, and the exact source systemd-boot NVRAM/BLS/payload ownership retire.

Limine <-> systemd-boot, rEFInd writes, and systemd-boot user backup/restore remain locked. GRUB2/Limine backup + restore behavior remains the r31 hardware-proven implementation.

> **r30:** fixes the hardware-observed reconstructed-GRUB runtime failure where the one-shot shim boot succeeded but ASUS/openSUSE appended a second same-ESP `opensuse -> EFI/OPENSUSE/GRUBX64.EFI` alias to `BootOrder`. Runtime proof now accepts only trailing aliases with that exact owned path/ESP, remains read-only, and after full proof removes those synthesized duplicates while preserving the transaction-created parked direct-GRUB identity before promotion/finalization.


## leap16-r33: systemd-boot first-proof hardening

- Keeps the hardware-proven r31 GRUB2 <-> Limine switch and restore paths unchanged.
- Fixes the first GRUB2 -> systemd-boot hardware-stage validator for Leap cmdlines that intentionally contain no explicit `rw`/`ro` token.
- Installs only the `systemd-boot` RPM for a fresh candidate (`--no-recommends`) instead of pulling optional sdbootutil/PCR/TPM tooling during the GRUB-authoritative proof phase.
- Cleans the exact Leap systemd-boot payload/BLS namespace on uncommitted failure and can recover the exact stale r32 candidate residue only after the STAGE write boundary.
- systemd-boot -> GRUB2, Limine <-> systemd-boot, and systemd-boot user backup/restore remain locked until the forward hardware proof succeeds.

## leap16-r31: user backups + restore selector + explicit second-reboot warning

- Keeps the hardware-proven r30 GRUB2 <-> Limine transaction engine unchanged.
- Adds optional user-owned backups for the currently booted GRUB2 or Limine backend before STAGE; declining the backup does not weaken the mandatory internal transaction ownership snapshot.
- Enables menu [3] backup creation, [4] backup validation/listing, [5] staged restore execution, and [6] read-only restore planning for the proven GRUB2 <-> Limine scope. [5] reuses the Leap transaction engines; systemd-boot/rEFInd restore routes remain unavailable.
- GRUB2 backups capture `/etc/default/grub`, `/etc/sysconfig/bootloader`, `/boot/grub2`, and `EFI/OPENSUSE`; Limine backups capture `/etc/default/limine`, `limine.conf`, splash, `EFI/LIMINE`, and the machine-id managed kernel/initrd tree while treating `EFI/BOOT/BOOTX64.EFI` as shared ownership/reference evidence.
- GRUB2 restore reuses r28 native openSUSE reconstruction while restoring the validated backed-up GRUB policy; generated `/boot/grub2` and `EFI/OPENSUSE` bytes are rebuilt from the installed Leap packages instead of replayed blindly. Limine restore replays the validated self-contained config/splash/EFI/managed payload into the ordinary GRUB2 -> Limine candidate transaction.
- Before the first GRUB2 -> Limine reboot, the UI explicitly warns that a successful canonical Limine proof will trigger one additional automatic reboot to prove the genuine EFI fallback before GRUB2 retirement.

## leap16-r30

- Does not weaken unrelated EFI-entry checks: the core runtime stable order must still be exact `source Limine, Limine fallback, proven shim`; every extra non-BBS entry must point exactly to the native direct-GRUB path on the transaction ESP.
- Keeps runtime proof read-only. Duplicate direct-GRUB aliases are removed only after kernel/root/cmdline/ownership/source-recovery proof has persisted `runtime-validated`.
- Removes only same-ESP/same-path direct-GRUB duplicates that entered BootOrder after the proof boot; the transaction-created parked direct alias remains the owned final direct-GRUB identity. This restores both r28 invariants: exactly one direct alias, and that alias remains outside BootOrder until finalization.
- Allows an already-stranded r29 `BootCurrent=proven shim`, `phase=boot-armed`, `BootNext=clear` session to be recovered interactively without another reboot.

> **r29:** recovers the ASUS-observed fallback-only Limine state before any reconstructed-GRUB attempt. If canonical `EFI/LIMINE/LIMINE_X64.EFI` bytes remain intact and byte-identical `EFI/BOOT/BOOTX64.EFI` is actively booting Limine, but the canonical `openSUSE Limine` Boot#### vanished while native GRUB remains absent, r29 captures a required pre-write diagnostic, recreates only that canonical alias, re-discovers the fallback by ESP/path, restores canonical/fallback order, and captures a required post-repair diagnostic. It deliberately stops there and requires one normal reboot through the repaired canonical alias before r28 GRUB reconstruction is allowed.

## leap16-r29

- The repair does not touch either Limine EFI payload, `limine.conf`, or GRUB files.
- Firmware identities are rediscovered by ESP + EFI path after the write, so ASUS renumbering/synthesis is tolerated only when ownership remains exact.
- A timestamped diagnostic folder is mandatory before the first NVRAM write and again after successful repair.
- Healthy finalized Limine and all existing r28 transaction paths are unchanged.

> **r28:** completes the real round trip. A fully finalized Limine-only installation can now reconstruct native openSUSE GRUB2 from the already-installed GRUB2/shim RPM payloads, stage it without taking persistent authority, prove the exact shim target with one-shot `BootNext`, and retire both Limine firmware paths only after that runtime proof.

## leap16-r28

- Requires the finalized Limine topology: canonical `EFI/LIMINE/LIMINE_X64.EFI` first, byte-identical `UEFI OS -> EFI/BOOT/BOOTX64.EFI` fallback second, and no remaining native openSUSE GRUB files or aliases.
- Reconstructs `/etc/default/grub`, `/boot/grub2`, the native openSUSE theme and `EFI/OPENSUSE` using the installed openSUSE toolchain and `shim-install --no-nvram`; no network/package reinstall is part of the transaction.
- Snapshots `EFI/BOOT/BOOTX64.EFI`, `fallback.efi` and `MokManager.efi`; any temporary shim-installer changes are hidden again before the GRUB proof so Limine remains fully authoritative.
- Creates explicit `opensuse-secureboot -> EFI/OPENSUSE/SHIM.EFI` and direct `opensuse -> EFI/OPENSUSE/GRUBX64.EFI` aliases with `efibootmgr --create-only`. The direct alias is parked outside candidate `BootOrder`; only the shim target receives one-shot `BootNext`.
- After exact GRUB runtime proof, promotes the shim, transfers the generic EFI fallback back to the proven shim plus the captured native auxiliary files, then retires both Limine aliases and ownership-proven Limine files.
- Persists the post-proof fallback-transfer checkpoint so a partial finalization can resume idempotently instead of repeating destructive work.
- The existing GRUB2 -> Limine two-proof path remains unchanged, so r28 is the first release intended to exercise a complete `Limine -> GRUB2 -> Limine` hardware round trip.

> **r27:** fixes finalized-Limine menu maintenance so success is reported only after the installed `/boot/efi/limine.conf` is read back with exactly one visible `EFI fallback` entry. It also replaces the misleading per-kernel `for CachyOS r47` generator comment with `Managed by openSUSE Bootloader Switcher`.

## leap16-r27

- Keeps the proven firmware topology unchanged: canonical Limine first and byte-identical `UEFI OS -> EFI/BOOT/BOOTX64.EFI` fallback second.
- Rewrites only the active root ESP config at `/boot/efi/limine.conf`; an `EFI/opensuse-bootloader-switcher/limine/limine.conf` reference/copy, if present, is not treated as the active menu config.
- The in-place `APPLY` path now generates, installs, hashes, reads back, and deep-validates the final menu before printing success.
- Existing finalized openSUSE kernel comments are normalized to `### Managed by openSUSE Bootloader Switcher`; fresh GRUB2 -> Limine staging emits the same wording.


> **r26:** fixes finalized-Limine hash validation when no cached sudo ticket exists; r25 could return empty hashes because a failed `sudo -n ... | awk` pipeline masked the sudo failure.

## leap16-r26

- Fixes the r24 finalized-Limine in-place `EFI fallback` menu upgrade: primary Limine NVRAM discovery now matches the literal `\EFI\LIMINE\LIMINE_X64.EFI` path emitted by `efibootmgr -v` instead of a doubly escaped string.
- Adds a regression for the real `Boot0002 openSUSE Limine` + `Boot0003 UEFI OS` firmware topology.
# openSUSE Leap 16 Bootloader Switcher — leap16-r33

Direct openSUSE Leap 16 port of the user-provided CachyOS Bootloader Switcher r47. The complete r47 library lineage remains the transaction-engine base; `lib/opensuse_leap16.sh` supplies the distro/platform adapter and `lib/leap16_r21.sh` provides the two-proof forward-completion transaction and `lib/leap16_r22.sh` layers the hardware-found promoted-order fix and resumable checkpoint recovery after it. All nine top-level selectors are preserved.

Selector `[2] Manage pending/staged migration` remains the recovery/control surface for parked or interrupted transactions, including the r21 second-boot Limine fallback proof.



## r22 delta: fix promoted-order contradiction and resume in place

r21 hardware testing exposed a phase bug after a completely successful primary Limine proof and promotion: the transaction intentionally changed persistent BootOrder from source-first to `Limine, GRUB...`, then an inherited recorded-source validator still demanded the old source-first candidate order. r22 makes that source-recovery proof phase-aware: before promotion it requires the candidate/source-first order; after promotion it requires the promoted Limine-first order while still proving the exact same GRUB EFI/config ownership.

r22 also recognizes an interrupted `runtime-validated` transaction already sitting at the safe primary-promoted checkpoint and can continue directly into genuine fallback staging/proof without rolling back to GRUB or repeating the primary proof. Backup/restore selectors remain present to preserve the nine-selector UX but are visibly locked until a Leap-native backup format exists. Historical r13 status text is made version-neutral so the UI describes the actual two-proof transaction.

## r21 base: genuine Limine EFI fallback proof before GRUB2 retirement

r21 completes the forward GRUB2 -> Limine transaction that r13/r20 intentionally left incomplete. The already hardware-proven canonical Limine Boot#### test remains the first proof. Only after that exact runtime proof does r21 redirect the temporary Limine recovery entry to `EFI/OPENSUSE/SHIM.EFI`, replace `EFI/BOOT/BOOTX64.EFI` with bytes identical to canonical `EFI/LIMINE/LIMINE_X64.EFI`, create or adopt exactly one transaction-ESP `UEFI OS` alias for `\EFI\BOOT\BOOTX64.EFI`, put primary Limine then fallback Limine first in persistent BootOrder, and arm the fallback alias with BootNext.

The Leap generic-fallback detector is also extended for this phase: `BootCurrent -> \EFI\BOOT\BOOTX64.EFI` is identified as Limine only when the fallback bytes are an unambiguous SHA256 match for canonical `EFI/LIMINE/LIMINE_X64.EFI`. A generic label such as `UEFI OS` is never trusted by itself; ambiguous byte ownership fails closed.

A second boot must prove the exact fallback BootCurrent, fallback EFI path/ESP binding, canonical Limine byte identity, kernel, root and cmdline. **Only that second proof authorizes GRUB2 retirement.** r21 then removes every pre-stage native openSUSE GRUB2 Boot#### alias on the transaction ESP plus the ownership-proven `/boot/grub2`, `EFI/OPENSUSE`, and `/etc/default/grub` state, while leaving GRUB packages installed. Finalized Limine keeps both firmware-visible paths: canonical `EFI/LIMINE/LIMINE_X64.EFI` first and genuine `EFI/BOOT/BOOTX64.EFI` fallback second.

If the fallback proof does not arrive, GRUB2 retirement is forbidden and r21 restores the snapshotted openSUSE shim fallback plus the primary-proven Limine config. The retained-target reverse adapter remains fail-closed when no retained GRUB target exists. Starting with r28, that finalized Limine-only state is handled by a separate openSUSE-native reconstruction transaction that rebuilds GRUB2/shim from installed RPM payloads, proves the exact shim target with BootNext, and retires Limine only after runtime proof.

## r20 delta: phase-aware reverse success diagnostics

r19 completed the first hardware-proven Limine -> native openSUSE GRUB2 automatic return, including runtime proof, persistent GRUB2 promotion, ownership-gated Limine retirement, and shim-fallback preservation. The write path was correct, but the success archive exposed stale diagnostic assumptions after retirement: `finalization-pass` still expected the candidate source-first topology, `auto-resume-pass` still expected the retired Limine Boot#### to exist, and the r18 ownership evidence called intentionally removed Limine trees a mismatch.

r20 changes diagnostics only. Reverse `promotion-pass` reports target-first/source-recovery state with direction-correct wording; reverse `finalization-pass` and `auto-resume-pass` require the native GRUB2 target first, the retired Limine Boot#### absent, and all other original real EFI-file entries exact while continuing to treat BBS entries as firmware churn. Post-retirement source-tree evidence is reported as `retired-as-expected` and is not counted as an ownership mismatch. The hardware-proven r19 BootOrder, BootNext, runtime proof, promotion, retirement, fallback, and cleanup logic is unchanged.


## r19 delta: fix false reverse ownership failure on openSUSE kernel symlinks

r18 proved that every retained-GRUB/source-Limine tree manifest was unchanged, yet the inherited format-4 ownership verifier still returned failure. The remaining mismatch is the inherited GRUB artifact root-confinement rule: r47 canonicalizes each `/boot/vmlinuz-*` / `/boot/initrd-*` path with `realpath` and requires the resolved object to stay under `/boot`. On openSUSE systems where `/boot` is part of the root filesystem, versioned kernel paths may be distro-owned symlinks into `/usr/lib/modules/...`; their exact bytes remain unchanged but their canonical path is intentionally outside `/boot`.

r19 leaves r47 untouched and overrides candidate ownership only for the Leap `limine -> grub` adopted-native-GRUB direction. The logical artifact paths must still be clean absolute paths under `/boot`, every recorded artifact must be `shared`, and every SHA256 must match exactly. NVRAM path + ESP binding, shim, `grub.cfg`, `/etc/default/grub`, the complete `/boot/grub2` tree, `EFI/OPENSUSE` tree, and native openSUSE theme remain byte-for-byte ownership gates.


## r18 delta: preserve reverse ownership evidence before cleanup

r18 deliberately does **not** change the Limine -> GRUB2 ownership policy after the r17 hardware failure. Instead, every reverse diagnostic captured while a live format-4 transaction snapshot exists now copies the exact expected ownership manifests into the timestamped diagnostic folder *before* uncommitted cleanup can delete `.prestage.*`. It also regenerates live `actual-*.tsv` manifests with the same tree-manifest writer, emits full unified `*.diff` files, and writes both `ownership-manifest-diff.txt` and a compact `ownership-first-mismatch.txt`. The captured set includes `grub-artifacts.tsv`, `grub-dir.tsv`, `grub-efi-dir.tsv`, `grub-theme-dir.tsv`, `source-limine-efi-dir.tsv`, and `source-limine-managed-dir.tsv`, plus the small theme/splash ownership markers when present. This revision is diagnostic-only: no BootOrder, BootNext, promotion, retirement, fallback, GRUB ownership, or Limine ownership gate is weakened.


## r17 delta: reverse firmware-baseline helper hotfix

Hardware staging of Limine -> GRUB2 exposed a second adapter near-name bug from r15: the reverse executor called undefined `leap16_capture_prestage_firmware_baseline` after successfully creating the transaction snapshot directory. The real Leap helper is `leap16_snapshot_firmware_baseline`, already used by the hardware-proven forward GRUB2 -> Limine path. r17 switches the reverse call to that existing helper and adds a regression forbidding the undefined symbol. The failure occurs before BootOrder normalization, BootNext arming, pending-state serialization, or any Limine retirement, so no boot-chain mutation is intended by this hotfix.

## r16 delta: retained-GRUB2 ESP identity hotfix

r16 fixes the first hardware-only failure found in the new Limine -> GRUB2 preflight. The reverse target validator accidentally called a non-existent helper, `leap16_boot_entry_on_current_esp`, after it had already proven Boot0000 active and bound to `\EFI\OPENSUSE\SHIM.EFI`. r16 uses the existing, already-hardware-proven `leap16_nvram_entry_matches_current_esp` helper instead. No NVRAM, transaction, promotion, retirement, theme, fallback or resume-service policy changes are made by this revision.


## r15 delta: real Limine -> GRUB2 backend

r15 completes the first two-way Leap backend. The already-hardware-proven GRUB2 -> Limine path remains unchanged, including automatic BootNext/runtime proof and persistent Limine promotion. The new reverse path **does not reinstall GRUB2**. It adopts the native openSUSE recovery chain deliberately retained by r13/r14 (`Boot#### -> \EFI\OPENSUSE\SHIM.EFI`, `/boot/grub2`, `EFI/opensuse`, `/etc/default/grub`, native openSUSE theme), snapshots it as a pre-existing target, and tests it with one BootNext while Limine remains persistent first.

After an exact GRUB2 target boot proves BootCurrent, kernel/cmdline/root identity, ownership manifests, fallback identity and BBS-aware firmware ordering, r15 promotes GRUB2 first. It then re-proves the exact Limine source *after promotion* before retiring only that source's Boot####, `EFI/LIMINE`, `limine.conf`, `limine-splash.png`, `/etc/default/limine`, and the managed Limine kernel directory. `EFI/BOOT/BOOTX64.EFI` is never retired on Leap because it is the stock openSUSE shim fallback; the direct openSUSE GRUB entry and unrelated live firmware entries are preserved.

Before r15 offers the reverse reboot, it also proves that the root-owned resume bundle exists, contains the copied pending state, that the temporary systemd unit is enabled, and that its `ExecStart` points to the exact copied tool. If that proof fails, BootNext is cleared and the transaction returns to candidate-ready rather than rebooting into an unresumable transaction.

Fresh GRUB2 -> Limine candidates continue to use the CachyOS visual theme with the corrected `/+openSUSE` menu group introduced in r14.

## r14 delta: correct Limine OS menu branding

r14 leaves the r13 automatic-resume/promotion machinery unchanged. Fresh Limine candidates still use the captured CachyOS palette and splash, but the top-level Limine menu group is now `/+openSUSE` instead of the inherited `/+CachyOS`. Existing already-staged r13 candidates are not rewritten because their `limine.conf` is transaction-owned and hash-bound.

## r13 delta: automatic GRUB2 -> Limine continuation

r13 ports the r47 root-owned automatic resume choreography onto the hardware-proven Leap GRUB2 -> Limine path.

A fresh authorized stage now proceeds as:

```text
GRUB2 source validation
  -> exact recovery/ownership snapshot
  -> Limine candidate stage + deep validation
  -> create-only Limine Boot####
  -> source-first / target-last persistent BootOrder
  -> candidate-ready diagnostics
  -> exact Limine BootNext
  -> root-owned copied-tool + copied-state systemd resume bundle
  -> optional normal reboot
  -> exact Limine BootCurrent runtime proof
  -> persistent Limine-first / GRUB2-second promotion
  -> post-promotion target + GRUB2 recovery validation
  -> automatic diagnostics/result sync
```

The automatic service executes a root-owned copy of the tool and transaction state from `/var/lib/opensuse-bootloader-switcher/r13`; it does not execute user-writable code after reboot.

### Deliberate Leap/ASUS safety boundary

r13 does **not** port r47 source retirement yet. After successful runtime proof and promotion, it intentionally retains:

- the recorded GRUB2/shim Boot#### recovery entry;
- `/boot/grub2`;
- the native `EFI/opensuse` namespace;
- `/etc/default/grub` when it was present in the source snapshot;
- the stock shared `EFI/BOOT/BOOTX64.EFI` shim fallback byte-for-byte.

This isolates persistent Limine-first firmware ordering as the next hardware variable without simultaneously deleting the known-good openSUSE recovery chain.

If any post-promotion target/recovery/order gate fails, r13 attempts to restore the source-first ordering immediately and does **not** delete either bootloader.

## Existing r12 boot-armed transactions

r13 can adopt an already-armed r12 transaction without restaging and without rewriting BootNext. From selector `[2]`, when the recorded GRUB2 source is active and the transaction is `boot-armed`, choose:

```text
Prepare/verify automatic resume and reboot prompt
```

The existing exact target BootNext is revalidated, then the root-owned r13 continuation bundle is installed.

## Proven pre-r13 hardware path

The path below was already exercised on the Leap 16 ASUS test system before r13 enabled persistent promotion:

```text
GRUB2 Boot0000
  -> one-shot BootNext Limine Boot0005
  -> Limine menu
  -> Leap 16 userspace
  -> exact runtime proof
  -> normal reboot
  -> GRUB2 Boot0000
  -> source-return proof
```

Repeated normal GRUB2 boots remained stable afterward. ASUS firmware may remove and later recreate generic `BBS(...)` CD/DVD/removable/network entries; those are reported as firmware-owned churn. Real EFI-file Boot#### identity/path/order remains strict.

## Still locked

r15 enables only the two GRUB2 <-> Limine directions. Backup/restore writes, systemd-boot writes, and rEFInd writes remain disabled.

## Diagnostics

Diagnostics remain timestamped folders only:

```text
~/opensuse-bootloader-diagnostics/YYYYMMDD-HHMMSS-<phase>/
```

Automatic resume diagnostics are copied back from the root bundle. The automatic session also gets an `operation.log`. The tool does not create diagnostic `.tar.gz` archives automatically.

### Leap 16 r23 hardware-retirement fix

r23 keeps the r21/r22 two-proof GRUB2 -> Limine transaction, but fixes final retirement after the genuine Limine fallback has booted. Native openSUSE GRUB aliases are no longer trusted by historical Boot#### number after fallback transfer: the tool discovers them by transaction ESP and `EFI/OPENSUSE/{SHIM.EFI,GRUBX64.EFI,GRUB.EFI}` path, removes the ownership-proven `EFI/OPENSUSE` namespace first, then performs a fresh repeated NVRAM sweep. This handles firmware alias renumbering/synthesis observed on the ASUS test system while preserving unrelated firmware entries.

### Leap 16 r24 visible EFI fallback menu

r24 preserves r23's hardware-proven firmware topology unchanged: canonical Limine remains at `EFI/LIMINE/LIMINE_X64.EFI`, and the explicit `UEFI OS` fallback remains at `EFI/BOOT/BOOTX64.EFI` with byte-identical Limine payloads and primary/fallback NVRAM ordering. After exact fallback runtime proof and GRUB2 retirement, the temporary `openSUSE GRUB2 recovery` Limine stanza is now converted into a visible `EFI fallback` entry pointing to `boot():/EFI/BOOT/BOOTX64.EFI`, matching the CachyOS Limine-menu convention. This menu entry chainloads the fallback executable; it does not replace or invoke the firmware's fallback Boot#### identity.

For already-finalized r23 installations, selecting Limine while Limine is current performs a narrowly scoped in-place upgrade: it proves the Limine-only primary/fallback topology, absence of native GRUB2 state, and byte identity of both Limine EFI payloads, then modifies only `limine.conf` after an explicit `APPLY` confirmation. NVRAM and EFI payload bytes are left untouched.

### leap16-r34 systemd-boot test status

r33 achieved the first real one-shot systemd-boot boot on Leap 16, but automatic continuation was accidentally routed through the older Limine-only runtime validator. The failure was safe: systemd-boot was BootCurrent, GRUB2 remained first in persistent BootOrder, and no promotion/retirement occurred.

r34 fixes that direction dispatch, removes the duplicate/overlong systemd-boot menu entries for new stages, and records a full pre-stage firmware baseline so native openSUSE GRUB aliases can later be retired without leaving a direct-GRUB orphan. A candidate staged before r34 is inspection/rollback-only for source retirement and should be rolled back from GRUB2 before an r34 restage.

### leap16-r35 systemd-boot retirement-order hardening

Before r34 was hardware-tested, its GRUB2 -> systemd-boot finalizer was reviewed against the ASUS firmware failure mode already observed during the GRUB/Limine work. Two issues were fixed in r35: r34 temporarily removed `EFI/OPENSUSE` before deleting source GRUB NVRAM aliases, and its final alias sweep enumerated the live same-ESP GRUB set instead of deleting only the exact pre-stage ownership set.

r35 records the pre-stage firmware table through the established sudo session, requires the current native-GRUB alias set to equal that exact baseline, promotes/proves systemd-boot, transfers the fallback, removes only the baseline-owned GRUB IDs from persistent `BootOrder` while all GRUB EFI files still exist, deletes exactly those Boot#### variables, and only then removes `EFI/OPENSUSE`, `/boot/grub2`, and `/etc/default/grub`. This prevents a persistent BootOrder entry from ever pointing at a GRUB EFI file that the transaction already deleted.

The r33 candidate that already hardware-booted systemd-boot remains rollback/inspection-only because it predates the full firmware baseline. Return to GRUB2, roll it back, and restage with r35. New r35 systemd-boot stages keep the clean two-entry BLS menu introduced by r34.


### r45 transcript display fix
The r44 transaction transcript could garble the live Konsole display when GRUB/openSUSE helper programs emitted carriage-return or ANSI cursor controls. r45 normalizes only the transcript mirror so the live terminal and `stage.log` remain line-oriented and readable; transaction semantics are unchanged.

### r47 shared machine-id namespace fix
r47 fixes a cross-backend artifact exposed after finalized systemd-boot retirement. The openSUSE systemd-boot adapter owns only `ESP/<machine-id>/opensuse-bootloader-switcher`, while the proven Limine adapter owns kernel payloads below `ESP/<machine-id>/<kernel-id>`. Earlier retirement removed the owned systemd-boot child tree but could leave the now-empty machine-id parent. GRUB2 -> Limine then rejected that empty parent as if it were an existing Limine payload. r47 removes the parent with `rmdir` whenever exact systemd-owned cleanup leaves it empty, and the Limine preflight now accepts an existing machine-id directory only when it is a real, non-symlink, empty directory. Any file, subdirectory, symlink, or other payload still fails closed. No recursive cleanup is performed on the shared parent.

### r46 terminal transcript fix
r46 replaces the asynchronous live `tee` transcript with a PTY-backed `script(1)` recorder. This preserves normal terminal semantics for helpers that write to `/dev/tty`, while still producing a readable `stage.log` after the operation. If `script(1)` is unavailable, the boot operation runs with native terminal output and reduced transcript coverage rather than risking terminal corruption.

### leap16-r48 direct matrix expansion

r48 enables the first direct non-GRUB edge: **Limine -> systemd-boot**.  The finalized Limine primary and its explicit byte-identical `EFI/BOOT/BOOTX64.EFI` fallback remain authoritative until one real systemd-boot `BootNext` arrival passes exact runtime/kernel/root/cmdline/ownership proof.  Only then may systemd-boot become persistent, take ownership of the generic fallback, and retire both exact Limine NVRAM aliases plus Limine-owned EFI/config/kernel payloads.

The source ownership snapshot never claims the shared `ESP/<machine-id>` parent or arbitrary foreign children: it freezes only the exact installed-kernel Limine child directories. A complete pre-stage firmware table is recorded so any post-stage `UEFI OS -> EFI/BOOT/BOOTX64.EFI` alias can be distinguished from baseline state and removed only after it leaves `BootOrder`. Failed/uncommitted systemd staging now uses the real Leap systemd namespace cleanup rather than the inherited CachyOS layout.

The reverse **systemd-boot -> Limine** remains locked in r48 so the target can be implemented with the same two-independent-runtime-proof Limine primary/fallback contract already proven on hardware.  Backup/restore support for this new direct matrix is not enabled until both switch directions are hardware-proven.


## leap16-r50 pending-manager routing fix

r50 fixes selector `[2]` for the direct Limine -> systemd-boot transaction. r49 repaired the post-promotion source verifier, but the pending menu still delegated this new format-v5 edge to the historical GRUB2 -> Limine manager and therefore emitted the impossible `recorded GRUB2 source / Limine target` failure while systemd-boot was correctly active. r50 intercepts only `limine:systemd-boot` pending state, exposes exact source/target-aware actions, and can continue an r48/r49 `runtime-validated` target-first checkpoint directly into the existing ownership-gated r49 finalizer without restaging. Other transaction directions are delegated byte-for-byte to their existing managers.

### leap16-r51 live matrix

The openSUSE port now exposes both live `Limine -> systemd-boot` and `systemd-boot -> Limine` switch directions.  The reverse path uses two independent Limine runtime proofs (canonical entry, then genuine `EFI/BOOT/BOOTX64.EFI` fallback) before exact systemd-boot retirement.  Backup creation prompts remain available for the current source, while Limine <-> systemd-boot backup/restore execution stays locked until this new reverse edge is hardware-proven.

### leap16-r52 transcript dispatch hotfix

r52 fixes two transcript-layer regressions exposed by the newly enabled systemd-boot -> Limine path: the r46 PTY child allowlist now permits the exact r51 transaction entry point, and PTY transcript sanitization runs with C collation so locale-specific `sed` range parsing cannot fail. Transaction semantics are unchanged from r51.

### leap16-r53 hardware-compatibility note

The systemd-boot -> Limine path now accepts one exact same-ESP firmware-created
`UEFI OS` alias for `EFI/BOOT/BOOTX64.EFI`.  It is recorded as pre-stage state
and, if unchanged, is reused for the second Limine fallback proof instead of
being falsely classified as dirty state.  Multiple pre-stage aliases still
fail closed as ambiguous.

### r54 reverse-matrix hardening

r54 fixes the systemd-boot -> Limine first-proof continuation so Limine promotion keeps the exact systemd-boot source second in BootOrder until the explicit Limine EFI fallback is independently boot-proven.  It can continue an r53 transaction stranded at the runtime-validated checkpoint without restaging.  After the second proof, r54 persists a retirement-authorization checkpoint before any source deletion and makes exact systemd-boot cleanup idempotently resumable.  Machine-ID namespace enumeration now fails closed rather than treating a failed `find` as an empty directory.

### leap16-r56 stranded reverse-migration recovery

If an older r51-r54 systemd-boot -> Limine run recorded `Primary Limine proof passed, but fallback staging failed` and no pending transaction remains, selector **[2]** can now recover the exact safe pre-transfer topology.  r55 proves that canonical systemd-boot and `EFI/BOOT/BOOTX64.EFI` are still byte-identical, restores the visible Limine EFI-fallback recovery menu if needed, recreates one canonical systemd-boot NVRAM alias only if firmware reclaimed it, and returns systemd-boot to persistent first.  It does **not** claim or install a Limine EFI fallback until the normal two-proof migration is retried from a real systemd-boot session.


### leap16-r56 recovered-source cleanup

r56 closes the post-r55 recovery gap exposed by repeated hardware testing. r55 deliberately restores `systemd-boot -> Limine` failures to a safe three-entry topology (canonical systemd-boot first, stranded Limine second, EFI/BOOT recovery alias third) and requires a real reboot into systemd-boot. r56 now treats that successful canonical systemd boot as the authorization boundary for a separate cleanup phase. It freezes the exact stranded Limine-owned paths, persists a retry-safe cleanup checkpoint, removes the stranded Limine and redundant EFI/BOOT NVRAM aliases, and retires only the frozen Limine files. `EFI/BOOT/BOOTX64.EFI` is never deleted or rewritten by this recovery cleanup; it remains byte-identical to canonical systemd-boot. A new systemd-boot -> Limine transaction is blocked until this cleanup completes. Timestamped pre/post cleanup diagnostics are captured.

### leap16-r57 transaction-state correction

For systemd-boot -> Limine, generic EFI fallback NVRAM aliases are now treated as ephemeral firmware handles. The current fallback is resolved by ESP + exact `\\EFI\\BOOT\\BOOTX64.EFI` path + payload identity instead of requiring the same `Boot####` IDs to survive a reboot. If a first Limine one-shot was consumed but systemd-boot becomes current again, the pending menu can re-arm the already-staged exact Limine candidate without restaging.

## leap16-r58 note

r58 fixes an r57 integration error where the new identity-based EFI/BOOT verifier called a helper that existed only as a selftest mock, causing automatic/manual primary Limine validation to stop with `command not found`. The production validator is now loaded explicitly and checked by a full-overlay smoke regression. Transaction semantics are otherwise unchanged from r57.

## leap16-r59 note

r59 restores the finalized Limine presentation contract on the systemd-boot -> Limine two-proof edge. r51-r58 correctly proved and retained the firmware-level `EFI/BOOT/BOOTX64.EFI` fallback but the r54 final renderer deleted the temporary direct systemd recovery stanza without converting it back into the visible `/EFI fallback` menu entry already required by the proven GRUB -> Limine r24/r27 path. r59 converts that stanza deterministically after the second proof and adds a narrow menu-only repair for already-finalized r54-r58 Limine installations. The repair changes only `limine.conf`; NVRAM, EFI payloads, kernel payloads and BootOrder remain untouched.


## leap16-r68 — inbound rEFInd runtime proof and safe continuation

The first r67 GRUB2 -> rEFInd one-shot boot reached the upstream rEFInd menu, selected the openSUSE `\boot\vmlinuz` direct-kernel entry, and reached Leap userspace. The temporary resume service then safe-failed before runtime certification with `Current bootloader is rEFInd, not Limine`. No source retirement occurred; persistent BootOrder remained GRUB-first.

r68 fixes the actual composition bug rather than weakening proof: inbound `GRUB2|Limine|systemd-boot -> rEFInd` now has an explicit Leap-native runtime validator. It requires exact canonical rEFInd BootCurrent/path/ESP identity, consumed one-shot BootNext, source-first persistent BootOrder, running-kernel and cmdline equivalence, immutable target ownership, deep rEFInd validation, and passive exact source-recovery ownership before persisting `runtime-validated`.

The hardware menu also exposed the next latent proof mismatch before another reboot: rEFInd can record the openSUSE symlink menu path `\boot\vmlinuz` in `PreviousBoot`. r68 accepts that form only when `/boot/vmlinuz` is a symlink resolving to the exact `/boot/vmlinuz-$(uname -r)` payload. Exact versioned PreviousBoot remains accepted; any protected source EFI chainload evidence remains an unconditional reject.

Source recovery while rEFInd is active is intentionally passive: exact source NVRAM path/ESP, EFI hash, immutable source manifest, fallback bytes/state, and baseline source-path representation are re-proven without calling an active-source backend validator. r68 also ownership-bounds firmware-created duplicate canonical rEFInd target aliases after runtime proof and removes only post-stage IDs absent from the pre-stage firmware baseline.

An r67 `boot-armed` transaction stranded by the dispatcher failure can be adopted in-place by r68 from the still-running rEFInd session; it does not need to be restaged merely to re-earn the same hardware boot.

### r69 hardware continuation fix

If r67/r68 already reached a canonical rEFInd target session but selector **Manage pending/staged migration** reported a GRUB2/Limine-only error, do **not reboot**. r69 recognizes the still-running inbound rEFInd target and offers exact runtime validation, followed by ownership-gated finalization only after proof. The historical failed-result banner is rendered as the earlier dispatcher failure rather than as an rEFInd direct-boot failure.

### leap16-r71

r71 fixes the outgoing rEFInd -> GRUB candidate gate so it validates rEFInd source invariants rather than reusing systemd-boot-specific fallback/LOADER_TYPE assertions. It remains fail-closed and does not weaken GRUB runtime proof or source retirement ordering.

### leap16-r72 note

r72 repairs the failed/uncommitted rEFInd -> GRUB cleanup path. A candidate-stage failure can no longer leave the parked direct-GRUB alias, `EFI/OPENSUSE`, or `/boot/grub2` behind while deleting only the shim alias. The exact finalized rEFInd source/fallback/BootOrder state must be restored and re-proven before rollback is reported successful.

### leap16-r76 note

The r75 rEFInd -> GRUB hardware run proved that the staged native openSUSE shim target boots Leap. Automatic continuation then safe-failed with `Current bootloader is GRUB2, not Limine` because that direction was missing from the final runtime dispatcher. r76 intercepts only exact format-v5 `refind:grub` pending state, validates the already-running target through the native `/boot/grub2` and shim/direct-GRUB contracts, and keeps rEFInd persistent-first until proof is recorded. Its pending manager can continue the stranded target directly; no repeat boot is required. The live edge remains HW-PENDING until ownership-gated finalization completes on hardware.

### leap16-r77 note

The r76 `rEFInd -> GRUB2` hardware run proved automatic shim runtime and source
retirement but exposed an ASUS-synthesized duplicate direct-GRUB NVRAM alias.
r77 normalizes that exact same-path/same-ESP post-stage alias only after runtime
proof and now requires a unique direct-GRUB final identity.  For an already
finalized r76 system whose GRUB chain is otherwise deeply valid, selecting
current **GRUB2 (repair/reinstall)** offers an NVRAM-only duplicate cleanup; no
GRUB/EFI files are rewritten.

### leap16-r79 note

r79 fixes the rEFInd -> GRUB finalizer when firmware synthesizes an extra direct-GRUB alias while the transaction-owned direct alias is still deliberately parked outside `BootOrder`. The recorded direct alias is now required to exist with exact path/ESP identity but is not required to be in `BootOrder` until the final `shim,direct` order is installed. Ownership-bounded duplicates are still removed from `BootOrder` before deletion.

### leap16-r80 — Limine ↔ rEFInd live + restore hardening

The Limine ↔ rEFInd live switches and both cross-loader restore directions were already enabled by the r64 four-loader adapter. r80 prepares those four paths for their hardware campaign using the alias-ownership lessons learned from GRUB ↔ rEFInd: pre-stage Boot#### ID collisions with unrelated firmware paths are never claimable, post-proof canonical-Limine/EFI-fallback duplicates are removed from BootOrder before deletion and must converge to exact-one primary + exact-one fallback aliases, fallback-transfer rollback must restore the exact pre-stage fallback alias/byte topology, and firmware alias-enumeration failures fail closed rather than looking like an empty alias set. GRUB ↔ rEFInd live and restore are now recorded HW-PROVEN from the Sep 5 hardware run; Limine ↔ rEFInd remains HW-PENDING until real hardware completes all four paths.
