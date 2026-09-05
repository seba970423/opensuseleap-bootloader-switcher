# leap16-r67 rEFInd dracut/symlink correction

The r66 hardware stage reached a parked canonical rEFInd alias and then exposed a validator-only bug: Leap 16 uses dracut initrds, while the inherited structural check used the CachyOS/Arch mkinitcpio helper. r67 uses `lsinitrd` for Leap rEFInd validation and leaves the already-proven generic helper untouched.

The same audit also incorporates upstream's openSUSE-specific `follow_symlinks true` support (available since rEFInd 0.14.0; r66/r67 use 0.14.2). This is applied only to the controlled Leap rEFInd policy alongside the existing scanner exclusions.

# leap16-r66 controlled rEFInd binary staging

The second real GRUB2 -> rEFInd stage reached the corrected r65 zypper invocation and then proved the actual Leap repository state: no provider of `refind` exists. r66 deliberately stops treating package availability as a prerequisite. For live rEFInd staging it acquires the fixed official SourceForge `refind-bin-0.14.2.zip` (or an explicitly supplied local ZIP), validates/extracts only the x64 EFI binary, ext4 driver, config sample and icon tree, manually installs those immutable files, and creates the canonical firmware alias with `efibootmgr --create-only`. No rEFInd RPM, package post-install script, or `refind-install` execution is permitted.

This is more than a repository workaround: upstream documents that its binary RPM copies files to the ESP and registers rEFInd as the default boot loader on EFI systems. That side effect would violate this project's source-first/create-only ownership boundary. r66 therefore keeps every ESP/NVRAM mutation inside the transaction engine. Restore-to-rEFInd remains self-contained and skips archive/network acquisition entirely; exact validated backup bytes are restored directly and mutable `vars/PreviousBoot` must be freshly earned. Backup validation accepts the exact r66 controlled-binary source marker instead of requiring a nonexistent RPM.

# leap16-r65 zypper option-scope correction

Hardware staging proved that this Leap 16 zypper parses `--non-interactive` globally but `--no-recommends` as an `install` command option. r65 uses `zypper --non-interactive install --no-recommends ...` after probing `zypper install --help`, and applies the correction to rEFInd, fresh systemd-boot, and native GRUB/shim acquisition. The failed r64 rEFInd attempt committed no candidate and changed no proof/finalization semantics.

## leap16-r64 complete rEFInd adapter notes

r64 is an additive Leap overlay over the hardware-proven r63 three-loader core. It enables all six directed live rEFInd edges, all six cross-loader rEFInd restore edges, and a Leap-native immutable rEFInd backup schema. The first hardware revision is intentionally scoped to `/boot` on the ext4 root filesystem; rEFInd direct-boots `/boot/vmlinuz-<release>` using the package-owned `ext4_x64.efi` driver and proves the boot with canonical BootCurrent plus `PreviousBoot`. Mutable `EFI/refind/vars` is excluded from backup/ownership.

Unlike Limine, rEFInd does not claim generic `EFI/BOOT` in r64. A bare fallback copy of `refind_x64.efi` would not provide the relative config/driver/resource runtime tree and therefore would create a false proof contract. Inbound rEFInd finalization instead preserves unrelated fallback bytes or retires only an ownership-proven source fallback after direct-kernel proof. `rEFInd -> Limine` still uses the established canonical-Limine + independent EFI/BOOT two-proof state machine. The post-enable audit also adds path+ESP-bounded tolerance/removal for firmware-created duplicate rEFInd Boot#### aliases, mirroring the hardware-observed GRUB alias churn without widening ownership.

Package staging prefers `zypper --no-recommends install refind`. If that package is unavailable from configured Leap repositories, a trusted local RPM may be supplied explicitly through `BOOTLOADER_SWITCHER_REFIND_RPM=/absolute/path/refind.rpm`; r64 verifies it with `rpm -K` and installs it through zypper. No unpinned rEFInd package is downloaded by the switcher. See `R64-REFIND-MATRIX.md` for the complete implementation/hardware evidence ledger and latent-bug audit.

## leap16-r63 shared machine-id restore merge fix

The r62 hardware restore progressed through preflight and failed when the r31 Limine backup substitution saw the existing `ESP/<machine-id>` parent. That parent is required on a finalized systemd-boot source and contains the exact `opensuse-bootloader-switcher` payload child; Limine owns separate per-kernel sibling children. r63 makes only the systemd-source restore substitution merge those exact validated Limine children into the shared parent, preserving the systemd child and failing closed on foreign, overlapping, non-directory, or symlinked backup/live children. The r51 BootNext, canonical Limine proof, EFI/BOOT fallback proof, promotion, retirement authorization, rollback, and resume algorithms are unchanged.

## leap16-r62 PTY restore-child allowlist fix

r61 added two direct Limine ↔ systemd-boot backup-restore executors and correctly sent them through the full PTY transaction transcript wrapper. The wrapper launches a fresh switcher child, whose r52 fail-closed allowlist did not know those r61 function names, so the transaction stopped before restore preflight or any firmware write. r62 adds exactly those two executor names to the allowlist and leaves the r52 sanitizer plus every restore/live transaction gate unchanged.

## leap16-r42 hardware retry note

The r41 retry reached the reverse finalizer from the already runtime-proven GRUB session but failed before writes with `Target EFI executable changed since candidate creation`. The generic r26 verifier used only `sudo -n sha256sum`; in a fresh interactive process, an expired/missing sudo ticket collapses to an empty hash and is indistinguishable from byte drift. r42 acquires sudo before reverse runtime/finalization and uses the established privileged/readable hash helper for that exact target check. Real hash mismatches remain fail-closed.

## r30 reconstructed-GRUB synthesized direct-alias runtime fix

The first r29 hardware reconstruction successfully booted the exact staged shim target but firmware/openSUSE appended a new same-ESP `opensuse -> EFI/OPENSUSE/GRUBX64.EFI` alias to persistent `BootOrder`. The inherited reverse runtime gate expected only `Limine primary, Limine fallback, shim target` and therefore rejected the working GRUB boot before cmdline/ownership proof or Limine retirement. r30 keeps the three-entry core order exact, but permits trailing non-BBS entries only when their path and ESP exactly match the transaction-owned direct-GRUB executable. Runtime proof remains read-only; only after `runtime-validated` is persisted does r30 remove redundant direct-GRUB aliases, retain the transaction-created direct identity, and continue through the existing r28 promotion/fallback-transfer/Limine-retirement gates.

> **r29:** recovers the ASUS-observed fallback-only Limine state before any reconstructed-GRUB attempt. If canonical `EFI/LIMINE/LIMINE_X64.EFI` bytes remain intact and byte-identical `EFI/BOOT/BOOTX64.EFI` is actively booting Limine, but the canonical `openSUSE Limine` Boot#### vanished while native GRUB remains absent, r29 captures a required pre-write diagnostic, recreates only that canonical alias, re-discovers the fallback by ESP/path, restores canonical/fallback order, and captures a required post-repair diagnostic. It deliberately stops there and requires one normal reboot through the repaired canonical alias before r28 GRUB reconstruction is allowed.

## r29 fallback-only Limine NVRAM recovery

- The repair does not touch either Limine EFI payload, `limine.conf`, or GRUB files.
- Firmware identities are rediscovered by ESP + EFI path after the write, so ASUS renumbering/synthesis is tolerated only when ownership remains exact.
- A timestamped diagnostic folder is mandatory before the first NVRAM write and again after successful repair.
- Healthy finalized Limine and all existing r28 transaction paths are unchanged.

## r28 finalized-Limine -> reconstructed native GRUB2

r28 closes the remaining two-way gap created by successful r23+ GRUB retirement. When Limine owns both canonical `EFI/LIMINE/LIMINE_X64.EFI` and byte-identical `EFI/BOOT/BOOTX64.EFI`, and native openSUSE GRUB state is genuinely absent, the reverse adapter no longer requires a retained target. It reconstructs native GRUB2 from the installed `grub2-common`, `grub2-x86_64-efi` and `shim` payloads.

The reconstruction uses the native openSUSE theme, a switcher-owned `/etc/default/grub`, `grub2-mkconfig`, and `shim-install --no-nvram`. Firmware authority remains explicit: direct GRUB and shim aliases are created with `efibootmgr --create-only`, Limine primary/fallback stay first, direct GRUB is parked outside candidate `BootOrder`, and only the shim alias receives one-shot `BootNext`.

Because `shim-install` may populate the generic EFI/BOOT namespace, r28 snapshots the Limine `BOOTX64.EFI` plus `fallback.efi`/`MokManager.efi`, captures the generated native replacements, and restores the Limine-owned bytes before the candidate reboot. Exact GRUB runtime proof is therefore required while the source Limine fallback remains intact. Only after proof does r28 promote shim, transfer the generic fallback back to the proven shim, install the captured native auxiliary files, retire both Limine aliases/files, and normalize the final GRUB order. A persisted fallback-transfer marker makes this post-proof retirement retry-safe after partial finalization.

This completes the intended hardware sanity cycle: finalized Limine -> reconstructed native GRUB2 -> the existing two-proof GRUB2 -> Limine transaction.

## r27 finalized-menu write/read-back fix

r26 reached the finalized Limine maintenance gate on hardware, but the rebooted menu still lacked `EFI fallback` and `/boot/efi/limine.conf` contained no such stanza. r27 replaces the inherited maintenance writer with a self-verifying path: it renders the existing active root ESP config, normalizes stale per-kernel CachyOS-port wording, appends exactly one `/EFI fallback -> boot():/EFI/BOOT/BOOTX64.EFI` block, installs it, hashes the installed bytes, reads the installed config back, and deep-validates it before reporting success. The proven Boot#### topology and EFI payload bytes are never changed by this maintenance action.

The extra `EFI/opensuse-bootloader-switcher/limine/limine.conf` path observed on hardware is not used as the active menu target by this action and is left untouched. Fresh Leap kernel entries now say `Managed by openSUSE Bootloader Switcher`; CachyOS r47 remains implementation/theme provenance, not the identity of the installed openSUSE kernels.


> **r26:** fixes finalized-Limine hash validation when no cached sudo ticket exists; r25 could return empty hashes because a failed `sudo -n ... | awk` pipeline masked the sudo failure.

## leap16-r26

- Fixes the r24 finalized-Limine in-place `EFI fallback` menu upgrade: primary Limine NVRAM discovery now matches the literal `\EFI\LIMINE\LIMINE_X64.EFI` path emitted by `efibootmgr -v` instead of a doubly escaped string.
- Adds a regression for the real `Boot0002 openSUSE Limine` + `Boot0003 UEFI OS` firmware topology.
# openSUSE Leap 16 port notes — leap16-r30

## Source of truth

The implementation remains a last-loaded openSUSE adapter over the exact user-provided CachyOS r47 lineage. `lib/r47.sh` stays byte-identical and all nine top-level selectors stay present. Distro/firmware adaptations live in `lib/opensuse_leap16.sh`.

## Hardware progression

- **r01–r03:** read-only Leap 16 detection/native GRUB2 validation reached 0 failures / 0 warnings.
- **r04–r07:** incrementally staged the Limine filesystem/NVRAM candidate, fixed nounset, EFI `file(1)` wording, ESP partition derivation and diagnostics; r07 completed `candidate-ready` with GRUB2 first and Limine parked last.
- **r08:** hardware-proved BootNext -> Limine -> Leap userspace -> normal GRUB2 return, with exact runtime/source-return proof and no persistent promotion.
- **r09:** made firmware-order validation BBS-aware without weakening real EFI-file identity checks.
- **r10:** removed the non-actionable missing staging-wallpaper-source warning while retaining installed splash/hash checks.
- **r11:** repaired rollback choreography and recovered the real r10 partial-teardown state without replaying stale BBS BootOrder IDs.
- **r12:** fixed stale same-process `PENDING_*` snapshot state and made rollback-pass diagnostics represent the true final neutral state.
- **r13:** ports r47 automatic BootNext + root-owned reboot continuation and opens only runtime-proven persistent Limine promotion. GRUB2 recovery retirement remains locked.
- **r15–r19:** port and hardware-prove the reverse Limine -> retained native GRUB2 path; r19 completes automatic runtime proof, promotion, exact Limine retirement, and fallback preservation.
- **r20:** diagnostic-only cleanup so post-retirement reverse success reports the finalized topology instead of stale candidate/promoted expectations.
- **r21:** complete forward GRUB2 -> Limine with a genuine `EFI/BOOT/BOOTX64.EFI` Limine fallback, explicit fallback Boot#### runtime proof, then ownership-gated retirement of native openSUSE GRUB2.

- **r22:** fix the post-primary-promotion firmware-order validator so it expects Limine-first after promotion, add in-place recovery/continuation for the safe r21 `runtime-validated` checkpoint, lock the unported backup/restore selectors visibly, and remove misleading r13 end-state text from current UX.




## r22 hardware-found promoted-order fix

The first r21 hardware run reached canonical Limine, passed runtime proof, and successfully promoted Boot0002 first (`0002,0000,0001`). The next fallback-staging preflight then failed only because `verify_pending_source_recovery_unchanged()` delegated to an inherited recorded-source validator whose firmware-order gate still expected the pre-promotion candidate order (`0000,0001,0002`). All GRUB bytes, manifests, fallback bytes, kernel/root/cmdline evidence and NVRAM identities were otherwise still proven.

r22 chooses the firmware-order contract by transaction phase/topology: source-first before promotion; target-first/source-second after a proven promotion. It also exposes an interactive continuation for the exact stranded state, re-proves the promoted checkpoint, stages the Limine fallback, installs a fresh root-owned resume bundle, and continues with the second reboot. No GRUB retirement is allowed before fallback runtime proof.

## r21 forward fallback + GRUB2 retirement

The successful r20 hardware diagnostic proved canonical `\EFI\LIMINE\LIMINE_X64.EFI` but also showed the generic fallback still byte-identical to openSUSE shim and no firmware alias for `\EFI\BOOT\BOOTX64.EFI`. r21 treats that missing topology as the forward-completion target. Primary Limine proof remains unchanged. After proof, r21 snapshots the primary-proven config, redirects temporary recovery directly to `EFI/OPENSUSE/SHIM.EFI`, transfers generic-fallback ownership to byte-identical Limine, creates/adopts exactly one `UEFI OS` alias, and performs a second BootNext/runtime proof of that exact alias.

Because the second proof boots through the generic path rather than a filename containing `limine`, the Leap detector now classifies `\EFI\BOOT\BOOTX64.EFI` by exact byte ownership. A byte-identical match to canonical `EFI/LIMINE/LIMINE_X64.EFI` is Limine; a match to the native openSUSE shim/GRUB chain is GRUB; cross-owner ambiguity is rejected.

Native GRUB2 is not touched until the fallback proof passes. Retirement uses the pre-stage firmware dump plus the existing `/boot/grub2`, `EFI/OPENSUSE`, and `/etc/default/grub` ownership manifests, so all and only baseline native openSUSE GRUB2 aliases on the transaction ESP are removed. Final persistent order begins canonical Limine, genuine Limine fallback, then unrelated real EFI entries. If fallback proof fails, the alias is removed, shim fallback/config are restored, and GRUB2 remains intact.

## r20 reverse diagnostic phase-awareness

The successful r19 hardware archive proves the reverse transaction itself is correct: Boot0000 booted through the native openSUSE shim, runtime proof passed, GRUB2 was promoted to `0000,0005,0001`, the Limine source was re-proved, then Boot0005 and only ownership-proven Limine state were retired, leaving `0000,0001` and the shared shim fallback. The remaining defects were diagnostic-only. `finalization-pass/firmware-order.txt` fell back to the old candidate topology, `auto-resume-pass/firmware-order.txt` reused the promoted-order gate that still required Boot0005, and post-retirement r18 ownership evidence treated the deliberately absent source trees as a mismatch.

r20 adds a reverse-finalized firmware assessor and phase-selective reporting. Candidate/runtime semantics are unchanged; promotion expects target-first/source-second; post-retirement success expects target-first with the source Boot#### absent. BBS disappearance/reappearance remains informational. Reverse ownership evidence now knows that source Limine trees must be absent after finalization and records `retired-as-expected` instead of a false mismatch. No transaction mutation logic changes.


## r19 reverse artifact ownership fix

r18 hardware diagnostics showed `reason=none` for all six expected-vs-live manifests and zero-byte diffs, proving the candidate files had not changed. The inherited r47 format-4 GRUB artifact helper nevertheless canonicalizes logical `/boot/vmlinuz-*` paths before enforcing the `/boot` root. Leap 16 may represent those logical kernel paths as symlinks into `/usr/lib/modules/...` when `/boot` is not a separate filesystem, so the canonical-root check rejects valid distro-owned shared artifacts. r19 adds a Leap-only reverse verifier: the recorded logical path must stay lexically under `/boot`, be marked `shared`, and retain the exact SHA256; all native GRUB2 tree/EFI/theme/NVRAM ownership checks remain exact. The inherited r47 verifier remains unchanged for every other transaction direction.


## r18 diagnostic evidence retention

The r17 hardware run reached `candidate-ready` and then failed the inherited format-4 candidate ownership gate. The failure diagnostic preserved high-level hashes but cleanup deleted the live `.prestage.*` directory containing the exact expected tree manifests, making the failing object impossible to identify afterward. r18 changes only diagnostics: while the reverse snapshot still exists, the timestamped diagnostic folder receives copies of all retained-GRUB/source-Limine ownership manifests, regenerated live manifests, unified diffs, and a compact first-mismatch report. The transaction verifier itself is unchanged; this revision exists to make the next failure explanatory instead of speculative.


## r17 hotfix

The first real reverse staging attempt reached the transaction snapshot boundary and exposed another undefined r15 near-name: `leap16_capture_prestage_firmware_baseline`. The adapter already has `leap16_snapshot_firmware_baseline`, which is the exact helper used by the proven forward path and writes `prestage-efibootmgr-v.txt` into the live `TRANSACTION_SNAPSHOT_DIR`. r17 uses that existing helper and adds a static regression. The captured r16 failure diagnostic showed BootCurrent 0005, no BootNext, and unchanged BootOrder `0005,0000,0001,0002,0003,0004`; therefore the failure was pre-commit.

## r16 hotfix

Hardware testing of the new reverse preflight exposed one typo-level adapter bug: `leap16_validate_retained_grub_target()` referenced undefined `leap16_boot_entry_on_current_esp`. The intended helper already exists as `leap16_nvram_entry_matches_current_esp` and is used by the proven forward path. r16 switches the reverse validator to that helper and adds a regression preventing the undefined symbol from returning.


## r15 two-way backend

r15 opens the reverse `limine:grub` edge using the retained native openSUSE GRUB2/shim recovery state instead of staging a second GRUB installation. Candidate ordering remains r47-style source-first/target-last; BootNext points once to the retained native GRUB2 target; a root-owned copied-tool/copied-state service proves the GRUB2 target after reboot. Only then may GRUB2 become persistent first.

Reverse source retirement is ownership-gated and occurs only after a second post-promotion Limine source proof. The source Limine Boot####, `EFI/LIMINE`, `limine.conf`, splash, `/etc/default/limine`, and managed kernel tree are retired. The Leap shared fallback `EFI/BOOT/BOOTX64.EFI` is explicitly excluded from retirement because it is the openSUSE shim recovery payload. Firmware-generated BBS entries remain churn, never transaction-owned state.

The reverse auto-resume pre-reboot boundary is self-proving: bundle directory, marker, copied pending state, systemd unit, enabled state, and exact ExecStart must all validate before a reboot is offered.

## r14 menu-branding correction

Fresh Leap Limine candidates retain the CachyOS visual theme but identify the OS group as `openSUSE`. The override changes only the generated `/+CachyOS` group marker to `/+openSUSE`; it does not mutate an already-staged candidate.

## r13 automatic resume

The r47 `r22` design is retained: the normal user authorizes the transaction before reboot, while privileged post-reboot decisions execute from a root-owned bundle containing a copied tool tree, copied pending state and copied `.prestage.*` ownership snapshot.

openSUSE namespace:

```text
/var/lib/opensuse-bootloader-switcher/r13/
/etc/systemd/system/opensuse-bootloader-switcher-resume.service
```

The service carries the root-owned state through `BOOTLOADER_SWITCHER_STATE_DIR`, sets `LEAP16_AUTO_RESUME=1`, and runs `--resume-transaction-root`. If firmware returns to the recorded GRUB2 source rather than Limine, the inherited safe-fallback model is used and promotion is not attempted. If BootCurrent is neither the exact recorded source nor target, writes are refused.

On the exact Limine target session, runtime proof must complete before promotion. The root continuation then changes only persistent BootOrder priority and revalidates both the Limine target and retained GRUB2 recovery state.

## Promotion boundary

The promoted stable real-EFI topology is:

```text
Limine target first
recorded GRUB2/shim source second
other original real EFI-file entries in original relative order
```

Current firmware-owned BBS entries are preserved if they exist, but missing BBS IDs are never resurrected. Loss/path mutation of a real pre-existing EFI-file Boot#### fails the gate.

If post-promotion validation fails, r13 derives a source-first recovery order from the entries that currently exist and attempts to restore it. No source files or NVRAM entry are deleted by r13 promotion.

## Why source retirement remains locked

On this Leap topology, `EFI/BOOT/BOOTX64.EFI` is byte-identical to openSUSE shim and therefore depends on retaining the native openSUSE EFI recovery chain. The earlier experimental openSUSE branch also produced an ASUS pre-POST hang after persistent Limine ordering. r13 deliberately tests persistent promotion as a single isolated variable while retaining GRUB2/shim/config/fallback recovery intact.

## r12 transaction adoption

A real r12 transaction is already capable of reaching `boot-armed` with exact Limine BootNext. r13 can adopt that state from selector `[2]`: it re-proves source/candidate identity and exact BootNext, then installs the root-owned automatic resume bundle. It does not restage the candidate and does not write BootNext again.

## Diagnostics

All diagnostics remain timestamped folders under the user's `~/opensuse-bootloader-diagnostics`. Root automatic-resume snapshots are first captured inside the protected bundle and then copied back only to the recorded user's safe diagnostic directory. The root automatic session transcript is saved as `operation.log`. No automatic diagnostic archives are created.

## Still locked in the historical r13 stage

At r13, GRUB2 source retirement/deletion, Limine -> GRUB2 live migration, backup/restore writes, systemd-boot writes and rEFInd writes were still locked. Later Leap layers open only the GRUB2 <-> Limine directions; backup/restore, systemd-boot and rEFInd writes remain locked in r28.

## leap16-r23

- Fixes the post-fallback finalizer false failure exposed on ASUS hardware after successful deletion of the historical GRUB Boot#### IDs.
- Treats native GRUB NVRAM ownership after fallback transfer as **transaction ESP + EFI path**, not immutable Boot#### numbers; hardware was observed recreating `opensuse -> EFI/OPENSUSE/GRUBX64.EFI` under a new ID after the original alias was deleted.
- Retires the ownership-proven `EFI/OPENSUSE` namespace before the final NVRAM alias sweep so firmware cannot rediscover `GRUBX64.EFI` during a later reboot.
- Re-enumerates and removes all current native openSUSE GRUB aliases after filesystem retirement, preserving unrelated firmware entries.
- Adds a recovery continuation for an already-stranded primary-Limine session: re-arm the exact `EFI/BOOT/BOOTX64.EFI` fallback proof, then continue through the corrected r23 finalizer without rolling the whole migration back.

## leap16-r24

- Keeps the r23 primary Limine + explicit `UEFI OS -> EFI/BOOT/BOOTX64.EFI` firmware topology unchanged.
- Final GRUB2 retirement now converts the temporary `openSUSE GRUB2 recovery` menu stanza into `/EFI fallback -> boot():/EFI/BOOT/BOOTX64.EFI` instead of deleting the stanza entirely.
- The Limine recovery validator distinguishes the pre-transfer GRUB-backed `EFI fallback` from the finalized Limine-backed `EFI fallback` by byte identity plus absence of `EFI/OPENSUSE`.
- Adds a narrow in-place r23 -> r24 finalized-Limine menu upgrade that changes only `limine.conf`; it requires exact primary/fallback firmware topology, byte-identical Limine EFI payloads, and zero remaining native GRUB2 aliases/files.


## leap16-r31

This revision preserves r30 firmware/runtime-proof behavior, adds openSUSE-native user backup capture/validation/read-only planning for GRUB2 and Limine, exposes selector [5] for staged cross-backend GRUB2 <-> Limine restore testing through the existing Leap transaction engines, and makes the already-existing second automatic fallback-proof reboot explicit before the first reboot. GRUB restore reuses r28 native reconstruction with the validated backed-up policy; Limine restore replays the self-contained backed-up target payload before the ordinary candidate/NVRAM proof sequence. systemd-boot and rEFInd restore routes remain unavailable on the Leap port.

## leap16-r32 — first systemd-boot live-switch backend

r32 deliberately leaves the hardware-proven r31 GRUB2 <-> Limine code path unchanged and adds only the first openSUSE-native systemd-boot edge: GRUB2 -> systemd-boot.

The new candidate uses the existing format-v5 transaction engine (source-first persistent BootOrder, exact BootNext, root-owned resume, runtime proof, ownership-gated retirement), but replaces the CachyOS /boot-ESP assumptions with Leap's normal separate ESP topology. Native `systemd-boot` package bytes are staged at `EFI/systemd/systemd-bootx64.efi`; exact `/boot/vmlinuz-*` + `/boot/initrd-*` pairs are copied into a machine-id-owned ESP tree and deterministic Type #1 BLS entries are generated under `loader/entries`.

For this first hardware proof, Secure Boot must be disabled. systemd-boot backup/restore, systemd-boot -> GRUB2, and Limine <-> systemd-boot remain intentionally locked until the forward topology is proven on hardware.


## leap16-r33 — first hardware-proof corrections

r33 keeps the r31 GRUB2 <-> Limine paths frozen and changes only the r32 GRUB2 -> systemd-boot edge after the first physical staging run exposed three issues before BootNext was ever armed. Leap's known-good GRUB cmdline legitimately omits an explicit `rw`/`ro` token, so the systemd-boot validator now reuses the transaction engine's proven token-equivalence normalizer and preserves that omission exactly instead of requiring a mount-mode token.

Fresh systemd-boot package installation now uses `zypper --no-recommends`, preventing the `systemd-boot` + installed shim weak-dependency relationship from dragging `sdbootutil` and PCR/TPM helpers into a GRUB-authoritative candidate stage. If r32 already installed those packages, r33 leaves them untouched but never invokes sdbootutil before runtime proof.

r33 also replaces inherited CachyOS uncommitted systemd-boot cleanup with the exact Leap r32 ownership set, including the machine-id payload tree and switcher-owned `opensuse-*.conf` entries. Exact orphaned r32/r33 candidate residue with no target NVRAM entry is recognized read-only during preflight and removed only after the user crosses the STAGE write boundary; the strict clean-namespace gate must then pass before a new candidate is written.

## leap16-r34 — systemd-boot one-shot resume + menu/retirement hardening

The first r33 GRUB2 -> systemd-boot hardware boot reached the exact candidate BootCurrent and booted the newest Leap kernel successfully. The root-owned resume then failed safely before promotion because the Leap forward resume dispatcher still routed non-reverse transactions into the older GRUB2 -> Limine runtime validator (`Current bootloader is systemd-boot, not Limine`). Persistent BootOrder remained GRUB2-first and no source cleanup ran.

r34 adds an explicit format-5 `grub:systemd-boot` root-resume/runtime path. New r34 stages also record a full pre-stage `efibootmgr -v` baseline in the private transaction snapshot; pre-r34 candidates are not eligible for GRUB2 retirement because they lack this ownership evidence. Final retirement follows the already hardware-learned Leap rule: keep source recovery through promotion, transfer the fallback only after runtime proof, remove `EFI/OPENSUSE` before sweeping same-ESP native GRUB aliases, then retire `/boot/grub2` and `/etc/default/grub` from the exact source manifest. This avoids leaving the direct-GRUB NVRAM alias orphaned.

The r34 systemd-boot BLS writer also removes the duplicate `opensuse-current.conf` alias. Each real kernel entry uses `title openSUSE Leap 16`, a separate `version`, and `sort-key opensuse`; `loader.conf` points directly at the newest real kernel entry. Boot-critical linux/initrd/options content is unchanged from the r33 hardware-booted candidate.

The hardware-proven GRUB2 <-> Limine layers remain byte-identical to r33/r31. systemd-boot backup/restore and the reverse systemd-boot -> GRUB2 edge remain out of scope until this forward edge is hardware-proven end-to-end.

## leap16-r35 — eliminate the GRUB orphan window before hardware-testing r34

Review of the r34 finalizer found an ordering mistake: deleting `EFI/OPENSUSE` before deleting Boot#### aliases would temporarily leave persistent firmware entries pointing to missing EFI paths. That is specifically disallowed by the ASUS firmware behavior established during the GRUB/Limine hardware matrix. r35 therefore removes the exact baseline-owned GRUB IDs from BootOrder first, while the source EFI files are still present, then deletes only those exact NVRAM variables, and only after both steps succeed removes the source EFI/config filesystem state.

r35 also tightens NVRAM ownership from "all live same-ESP native-GRUB aliases" to exact set equality against the pre-stage firmware baseline. Any added, removed, path-changed, or ESP-moved GRUB alias aborts source retirement before files are removed. Baseline capture is now performed with `sudo -n efibootmgr -v` under the already-established sudo session. The unrelated-fallback preservation branch now has a matching final postcondition instead of unconditionally demanding a systemd-boot fallback hash.


## leap16-r38 — open the reverse systemd-boot -> GRUB2 hardware matrix edge

After r37 physically proved the finalized GRUB2 -> systemd-boot topology (`BootOrder` containing only canonical systemd-boot and a byte-identical `EFI/BOOT/BOOTX64.EFI` fallback), r38 unlocks only the reverse systemd-boot -> native openSUSE GRUB2 edge. It does not modify the hardware-proven GRUB2 <-> Limine or forward GRUB2 -> systemd-boot production layers.

Reverse staging snapshots the complete systemd-boot source ownership, generic fallback, EFI/BOOT auxiliary state and privileged `efibootmgr -v` table. Native GRUB is reconstructed with `grub2-mkconfig` and `shim-install --no-nvram`; any shim-installer fallback changes are immediately hidden again so systemd-boot remains authoritative. A direct `EFI/OPENSUSE/GRUBX64.EFI` alias is parked outside BootOrder and the shim alias is appended as the one-shot target.

After exact shim runtime proof, finalization first promotes shim while source systemd-boot still exists, transfers the generic fallback to byte-identical shim plus generated `fallback.efi`/`MokManager.efi`, removes the source systemd-boot Boot#### from BootOrder while its canonical EFI file still exists, deletes that exact source variable, then retires only the source ownership manifest. Final state requires shim first, direct GRUB second, no canonical systemd-boot NVRAM/EFI ownership, `LOADER_TYPE=grub2-efi`, and deep native GRUB validation.


## leap16-r39 — reverse systemd-boot -> GRUB2 hardware evidence follow-up

The first r38 reverse one-shot physically booted the recorded GRUB shim target, but the temporary root resume service fell through to an inherited Limine-oriented continuation. r39 explicitly dispatches `systemd-boot:grub`, validates systemd-boot as passive source recovery while GRUB is BootCurrent, and preserves the source-first transaction rule until runtime proof succeeds.

The same hardware boot also produced additional same-ESP firmware aliases after staging: a generic `EFI/BOOT/BOOTX64.EFI` alias and a duplicate direct-GRUB alias. r39 does not guess ownership from labels. It compares the live table to the complete pre-stage firmware baseline, records only new aliases whose exact path and ESP match the transaction's GRUB/fallback paths, and removes those recorded aliases only after they are out of BootOrder while their referenced EFI files still exist. Unrelated new entries are left alone. The record is also used by exact rollback.

## leap16-r43

- Reverse systemd-boot -> GRUB2 finalization now normalizes redundant pre-stage same-ESP `EFI/BOOT/BOOTX64.EFI` NVRAM aliases after GRUB runtime proof and fallback transfer.
- The generic `EFI/BOOT/BOOTX64.EFI` file itself is preserved and must remain byte-identical to the proven openSUSE shim; only the redundant firmware alias is removed.
- Baseline/path/ESP identity gates remain fail-closed, and unrelated firmware entries are preserved.

## leap16-r44

- Enables user-owned systemd-boot backup creation/validation using only the switcher-owned EFI/systemd, loader.conf, per-kernel BLS entries and machine-id payload tree, with EFI/BOOT captured as reference evidence.
- Restores the pre-write-boundary user backup prompt for GRUB2 -> systemd-boot and systemd-boot -> GRUB2; the mandatory private transaction snapshot remains unconditional and separate.
- Enables cross-backend restore for GRUB2 <-> systemd-boot by reusing the hardware-proven staged BootNext/runtime-proof/finalization engines. Limine <-> systemd-boot restore remains locked with its still-unproven switch matrix.
- Adds a user-owned full transaction transcript directory for the two systemd edges: stage.log captures the interactive migration, while the root resume log/checkpoints are aggregated into the same folder after reboot. Diagnostics remain folder-only; no archive is created automatically.

## leap16-r45 — transcript live-UX normalization

r44's full stage transcript used a raw `tee` mirror for merged stdout/stderr. Some GRUB/openSUSE helpers emit carriage-return/ANSI progress control sequences; after piping through `tee`, those cursor controls could visibly overwrite unrelated transaction lines in Konsole even though the transaction itself completed normally. r45 changes only the transcript mirror: CR progress is rendered as ordinary lines, common ANSI CSI controls are stripped from the mirrored/logged stream, and the logger is drained before the next prompt. Boot transaction, backup, restore, ownership, NVRAM and fallback semantics are unchanged.

## leap16-r46 — PTY-backed transaction transcript

r45 proved that sanitizing the tee stream was insufficient: the captured stage.log was already clean while Konsole could still show displaced status lines. The remaining race was architectural: helpers such as sudo/system tooling may write directly to /dev/tty while the switcher output was asynchronously replayed through a process-substitution tee. r46 replaces only that transcript transport. Systemd-edge switch/restore operations run under util-linux script(1), which provides one pseudo-terminal and serializes stdout, stderr and /dev/tty writers exactly as a terminal session. The raw typescript is sanitized after the operation into stage.log. Boot, backup, restore, NVRAM, ownership and fallback semantics are unchanged.


## leap16-r47 — reconcile systemd-boot and Limine machine-id namespaces

The Leap systemd-boot backend stores copied kernel/initrd payloads in `ESP/<machine-id>/opensuse-bootloader-switcher`. The existing hardware-proven Limine backend uses `ESP/<machine-id>/<kernel-id>`. Prior systemd-boot retirement removed only its owned child tree and could leave an empty `ESP/<machine-id>` directory. The GRUB2 -> Limine preflight historically treated existence of that parent as proof that Limine state already existed, causing a false collision after a clean systemd-boot -> GRUB2 migration.

r47 keeps the safety boundary narrow: after exact systemd-owned removal it attempts only `rmdir ESP/<machine-id>`, which succeeds only if the parent is empty. The Limine preflight now treats a non-symlink empty parent as harmless shared-namespace residue, while any child content or non-directory/symlink shape remains a hard failure. This applies to finalized retirement, exact candidate rollback, and stale uncommitted systemd cleanup. The proven Limine payload and firmware transaction choreography are otherwise unchanged.

## leap16-r48 — direct Limine -> systemd-boot hardware-proof edge

- Opens only finalized Limine -> native openSUSE systemd-boot.
- Preserves the proven Limine primary + explicit generic-fallback Boot#### as source recovery until exact systemd-boot userspace/runtime proof.
- Treats `ESP/<machine-id>` as a shared parent: Limine source ownership is frozen per child, excluding the systemd-boot `opensuse-bootloader-switcher` child.
- After runtime proof, systemd-boot is promoted first, `EFI/BOOT/BOOTX64.EFI` is transferred to byte-identical systemd-boot, both Limine aliases are removed from BootOrder before deletion, and only exact Limine-owned files are retired.
- `systemd-boot -> Limine` remains intentionally locked until this first direct edge is hardware-proven; the reverse target must retain Limine's two-independent-proof primary/fallback architecture rather than shortcut it.
- Source file ownership claims only exact installed-kernel Limine children below the shared machine-id parent; any unexpected/foreign child fails closed instead of being absorbed into the retirement manifest.
- Records the complete pre-stage firmware table and ownership-records only post-baseline same-ESP generic-fallback aliases, so firmware-synthesized `UEFI OS` churn can be removed after it leaves `BootOrder` without guessing by label.
- Failed/uncommitted Limine -> systemd-boot staging removes the actual Leap systemd EFI/BLS/payload namespace and opportunistically `rmdir`s only an empty shared machine-id parent.
- Existing GRUB2/Limine, GRUB2/systemd-boot, backup/restore and r46 PTY transcript paths remain layered and unchanged.


## leap16-r49 — fix r48 post-promotion cleanup gate

The first physical Limine -> systemd-boot r48 run reached the exact systemd-boot BootCurrent, passed runtime kernel/root/cmdline proof, passed deep systemd validation, and re-proved the complete Limine source/fallback ownership. Finalization then successfully promoted systemd-boot first, but immediately called the same r48 source verifier that still required Limine primary/fallback to be first/second. It failed with `Limine source is no longer first in persistent BootOrder` before generic-fallback transfer or any Limine NVRAM/filesystem cleanup.

r49 treats that state as a transaction-owned safe checkpoint, not as corruption. The pre-promotion verifier remains unchanged and strict. If the exact runtime-proven systemd-boot target is already first, r49 reuses the pre-r48 format-v5 source byte/path/manifest/fallback validation and additionally requires the exact promoted order `target, source-primary, source-fallback`. Only then may the existing r48 finalizer continue with fallback transfer, removal of both Limine aliases from BootOrder, deletion of those exact variables, exact source-manifest retirement, and LOADER_TYPE transfer.


## leap16-r50 — direct Limine/systemd pending UX routing

r49's finalizer was resumable after the r48 promoted-state failure, but selector `[2]` was not: the last generic pending dispatcher still fell through to the old GRUB2 -> Limine menu and rejected an active systemd-boot target with `Current bootloader is neither the recorded GRUB2 source nor Limine target`. r50 adds a narrow final dispatcher for format-v5 `limine:systemd-boot`. On the exact runtime-proven systemd target it distinguishes source-first from already-promoted target-first BootOrder and routes both to the existing r48/r49 finalizer; the target-first recovery path is specifically for the safe r48 checkpoint where Limine primary/fallback remain intact. Source-side candidate/BootNext/re-arm/rollback controls are also direction-correct. No finalization is permitted from the Limine source session.

## leap16-r51 — complete live Limine <-> systemd-boot matrix

r51 opens the reverse live edge `systemd-boot -> Limine`; `Limine -> systemd-boot` remains the r48-r50 implementation.  The reverse edge deliberately mirrors the hardware-proven GRUB-to-Limine two-proof completion contract instead of using the generic one-proof adapter finalizer: canonical Limine must first earn an exact BootCurrent/runtime proof while finalized systemd-boot stays authoritative, then Limine is promoted, EFI/BOOT ownership is transferred, an explicit byte-identical fallback Boot#### is armed, and only the second exact fallback BootCurrent proof authorizes systemd-boot retirement.  The systemd source manifest excludes the shared machine-id parent; Limine staging/removal touches only exact Limine child namespaces, so the systemd `opensuse-bootloader-switcher` child is never removed by candidate cleanup.  After final proof, source systemd NVRAM is removed from BootOrder before deletion and only the ownership-proven systemd EFI/BLS/payload paths are retired.  rEFInd writes and Limine <-> systemd-boot backup/restore execution remain locked pending hardware proof of both live directions.

## leap16-r52

- Fixed the newly enabled systemd-boot -> Limine live path failing before preflight under the r46 PTY transcript wrapper. r46 intentionally allowlisted transcript child entry points, and r51 introduced `leap16_r51_run_systemd_to_limine_inner` without extending that allowlist. r52 keeps the restriction and adds only that exact r51 entry point.
- Made the r46 PTY transcript sanitizer locale-safe by forcing C collation for the ANSI CSI regular expression. This prevents the hardware-observed `sed: ... Invalid range end` failure under locales whose collation rules reject the ASCII range expression.
- No boot-state, NVRAM, fallback, backup, restore, or runtime-proof semantics changed.

## leap16-r53 — firmware-created systemd fallback alias adoption

Hardware testing of the newly enabled systemd-boot -> Limine edge showed that
ASUS firmware can synthesize a same-ESP `UEFI OS` Boot#### for
`\\EFI\\BOOT\\BOOTX64.EFI` after an earlier Limine -> systemd-boot transaction
has already finalized cleanly.  r51 incorrectly required the live pre-stage
fallback alias set to be globally empty.  r53 allows zero or one exact alias,
freezes it in the complete pre-stage firmware baseline, requires exact baseline
identity through the first Limine proof, and reuses that Boot#### as the genuine
Limine fallback after EFI/BOOT ownership transfer.  Post-baseline duplicate
aliases are ownership-gated churn and may be retired before adoption.  Rollback
preserves the baseline alias and restores the original systemd fallback bytes.
No shared EFI fallback file or machine-id parent is broadly deleted.

## leap16-r54 — reverse-matrix promotion + resumable retirement fix

Hardware r53 reached canonical Limine successfully from systemd-boot, but the automatic continuation failed at the pre-fallback promotion boundary.  The cause was a composition mismatch: the generic adapter promotion helper removes the source Boot#### from persistent BootOrder, while the systemd-boot -> Limine two-proof contract requires the exact systemd source to remain second until the Limine EFI fallback earns its own runtime proof.  r54 uses the dedicated primary-Limine + source-recovery ordering helper and can repair the exact runtime-validated r53 stranded topology without restaging.

r54 also closes the previously identified latent cleanup retry gap.  After the exact fallback runtime proof, an immutable transaction-side retirement authorization record is written before any source deletion.  From that checkpoint onward, source cleanup is idempotent: absent source-owned objects are accepted as already-retired, while any remaining file/tree must still be unchanged and contained in the frozen source manifest.  The temporary direct systemd recovery block in limine.conf is finalized idempotently against an authorization-bound final hash.  Shared machine-id namespace probes now fail closed on enumeration errors; cleanup remains rmdir-only.

## leap16-r55 — stranded pre-transfer source recovery

r55 fixes the already-failed/no-pending aftermath of the r51-r53 systemd-boot -> Limine promotion-order bug.  On affected firmware the dropped source systemd-boot Boot#### may be garbage-collected/reused even though its EFI/BLS/payload files and the byte-identical EFI/BOOT fallback remain intact.  The firmware's `UEFI OS` alias alone is not a proven Limine fallback.

Selector [2] now recognizes only the exact historical failure signature while canonical Limine is running.  The recovery action fails closed unless the surviving systemd-boot BLS/payload/EFI chain deep-validates, EFI/BOOT is byte-identical to canonical systemd-boot, exactly one same-ESP EFI/BOOT alias exists, and the current Limine NVRAM identity is canonical.  It restores a visible `/EFI fallback` Limine menu entry when missing, recreates one canonical systemd-boot Boot#### with `efibootmgr --create-only` only when needed, sets persistent order to systemd-boot first / proven Limine second / existing EFI fallback third, and leaves EFI/BOOT untouched as systemd-boot.  The user then boots systemd-boot normally and may start a fresh r55 two-proof migration.

This recovery deliberately does not "finish" the failed transaction from Limine: the second fallback proof was never earned, so converting EFI/BOOT to Limine or retiring systemd-boot would be an ownership violation.


## leap16-r56

Hardware recovery under r55 proved canonical systemd-boot could boot while the intentionally preserved recovery topology (`systemd-boot, Limine, UEFI OS`) remained persistent across reboot. r56 adds the missing post-reboot recovery-cleanup phase. Selector [2] recognizes the exact r55 safe-recovery result from a canonical systemd-boot session, deep-validates systemd and the stranded Limine candidate, requires EFI/BOOT to remain exact systemd bytes, freezes an ownership manifest for only the stranded Limine namespaces, and persists a cleanup authorization before any deletion. Cleanup is idempotently retryable: missing authorized Limine objects are accepted as completed steps, remaining objects must stay an exact subset of the frozen manifest, unrelated firmware entries are preserved, and the EFI/BOOT file itself is never removed or replaced. Fresh systemd-boot -> Limine staging remains blocked until this cleanup has succeeded.

## leap16-r57 — identity-based EFI/BOOT aliases + consumed one-shot re-arm

Real hardware demonstrated that `Boot####` is not a stable identity on the ASUS test firmware. r53/r56 still compared parts of the current generic-fallback alias set to frozen pre-stage IDs. r57 changes the pre-transfer systemd-boot -> Limine invariant to the actual boot identity: the current transaction ESP, exact `\\EFI\\BOOT\\BOOTX64.EFI` path, and exact frozen systemd-boot fallback bytes. Zero or one active exact alias is accepted regardless of which ephemeral `Boot####` firmware assigned. The complete pre-stage firmware table remains captured for diagnostics/provenance and is not discarded.

r57 also closes a pending-state UX/state-machine hole. A first Limine `BootNext` is one-shot. If that proof is not accepted and the user later reboots, persistent systemd-boot naturally becomes current while the transaction can still say `boot-armed` with `BootNext=none`. The pending manager now offers a safe re-arm of the exact existing Limine candidate after revalidating source/candidate ownership; no manual `efibootmgr -n` command or restaging is required.

Fallback adoption after ownership transfer resolves the current exact EFI/BOOT alias fresh rather than requiring a frozen pre-stage ID. Transfer rollback preserves current exact fallback aliases instead of deleting firmware variables merely because their numeric IDs were absent from the old baseline; the payload is restored to the frozen systemd-boot bytes first-class by the existing rollback path.

## leap16-r58 — r57 runtime symbol integration fix

The first real r57 automatic resume proved canonical Limine, the runtime kernel/root/cmdline, Limine ownership, and the complete systemd-boot recovery payload, then aborted before fallback transfer with `leap16_r56_validate_current_fallback_alias: command not found`.  r57's selftest had mocked that helper, so the test accidentally hid the production integration error.

r58 supplies the missing production validator as a compatibility shim while preserving r57's identity-based firmware model.  A currently resolved EFI/BOOT alias is accepted only when it is one valid active Boot####, is bound to the transaction ESP, points exactly to `\\EFI\\BOOT\\BOOTX64.EFI`, and does not collide with the recorded source or canonical Limine target NVRAM identity.  The numeric Boot#### itself remains ephemeral and is never compared to a frozen pre-stage ID set.

The r58 regression sources the complete production overlay stack before testing the r57 identity path and deliberately does not mock the missing symbol, preventing this class of undefined-helper release regression from passing again.  No NVRAM, payload, fallback-transfer, retirement, backup, or restore semantics change in r58.

## leap16-r59 — restore finalized Limine EFI-fallback menu parity

The r51/r54 systemd-boot -> Limine finalizer regressed the r24/r27 finalized Limine UX contract by *removing* `/openSUSE systemd-boot recovery` after source retirement and accepting a final `limine.conf` with no visible fallback entry. Firmware ownership was correct, but the menu no longer exposed the proven `EFI/BOOT/BOOTX64.EFI` path. r59 changes the deterministic final renderer to convert the temporary direct systemd recovery stanza into the exact standard `/EFI fallback` block used by the hardware-proven GRUB -> Limine path. It also recognizes old r54-r58 retirement authorizations and can deterministically upgrade their already-authorized no-entry final config without re-earning either runtime proof.

For already-finalized r54-r58 systems with no pending migration, current-Limine repair now has a narrow presentation-only path: it requires one exact primary Limine alias, one exact same-ESP `EFI/BOOT` alias, primary/fallback BootOrder, byte-identical canonical/fallback Limine EFI bytes, no active systemd-boot alias, and no temporary recovery stanza. It then adds only the visible `/EFI fallback` block to `limine.conf` and verifies that firmware/EFI identity did not change.


## leap16-r68

Hardware r67 GRUB2 -> rEFInd proved the upstream 0.14.2 binary, ext4 driver, `follow_symlinks=true`, and openSUSE direct-kernel path through to Leap userspace. Automatic resume failed before any cleanup because the generic inbound rEFInd path called the historical Leap Limine-only runtime validator. r68 adds a last-layer `validate_pending_target_runtime()` dispatcher for inbound rEFInd only and delegates every non-rEFInd path unchanged.

Three latent follow-on failures were closed in the same pass: (1) PreviousBoot may name the openSUSE `/boot/vmlinuz` symlink instead of a versioned path, so the proof now binds that text to the exact running version by `readlink -f`; (2) source recovery under rEFInd BootCurrent is manifest/NVRAM/hash/fallback based and never invokes an active source validator; (3) a firmware-created duplicate canonical rEFInd target alias is normalized only after direct-kernel runtime proof, only for exact same-path/same-ESP aliases, and only when the extra Boot#### ID was absent from the pre-stage firmware baseline.

This is a continuation-compatible release: an r67 `boot-armed` inbound-rEFInd pending state can be runtime-validated and finalized from the existing successful rEFInd session.

## leap16-r69 — inbound rEFInd interactive pending-manager repair

Hardware r68 proved another latent routing bug after rEFInd had already direct-booted Leap: selector [2] still delegated an inbound `GRUB2 -> rEFInd` transaction to the historical GRUB2/Limine pending manager and emitted `Current bootloader is neither the recorded GRUB2 source nor Limine target`. r69 intercepts only inbound `GRUB2|Limine|systemd-boot -> rEFInd` pending state, routes the exact rEFInd BootCurrent session to the r68 runtime validator and r64 finalizer, preserves generic source-session re-arm/reset/rollback behavior, and delegates every non-rEFInd pending direction unchanged. No source retirement is allowed before the existing direct-kernel runtime proof persists `runtime-validated`.

## leap16-r70 — rEFInd backup raw-UEFI-path comparison

The first backup taken from finalized rEFInd exposed a Bash comparison bug inherited from the r64 rEFInd backup validator. Both sides contained the correct canonical raw firmware path, but the unquoted RHS of `[[ lhs == rhs ]]` was interpreted as a pattern and its backslashes became pattern escapes. r70 compares raw EFI paths literally (case-insensitively) and regression-tests the exact `\\EFI\\refind\\refind_x64.efi` case. No transaction, runtime-proof, retirement, restore-payload, or legacy three-loader engine is changed.

## leap16-r71

- Fixed rEFInd -> GRUB candidate validation accidentally inheriting systemd-boot-only fallback and `LOADER_TYPE` assertions from leap16-r38.
- Finalized rEFInd may legitimately have no `EFI/BOOT/BOOTX64.EFI`; r71 preserves exact pre-stage presence/hash state instead of requiring a systemd-boot-owned fallback.
- Finalized rEFInd intentionally carries `LOADER_TYPE=grub2-efi` as the openSUSE compatibility policy until GRUB runtime proof; r71 validates that actual source policy.
- The already hardware-proven systemd-boot -> GRUB validator remains unchanged.

## leap16-r72 — rEFInd -> GRUB uncommitted-cleanup repair

Hardware exposed an r26 namespace mismatch after a failed rEFInd -> native-GRUB stage: the generic CachyOS cleanup knew only the shim target and old `/boot/grub`/`EFI/CACHYOS` namespace, while Leap staging had also created a parked direct-GRUB alias plus `/boot/grub2` and `EFI/OPENSUSE`. r72 intercepts only `source=refind,target=grub` pre-commit cleanup, removes both exact same-ESP GRUB aliases and all transaction-created native Leap GRUB namespaces, restores pre-stage EFI/BOOT auxiliary/fallback state and exact BootOrder, then re-proves rEFInd. Snapshot evidence is retained on any cleanup-proof failure.

## leap16-r77 — rEFInd -> GRUB duplicate direct-alias normalization

The r76 automatic hardware run exposed Boot0003 as a firmware-synthesized
same-ESP duplicate of the transaction-owned direct-GRUB Boot0001 after the
one-shot shim boot.  r76 finalized with `BootOrder=0002,0001,0003` because its
final gate required only the shim/direct prefix and the recorded direct alias.
r77 retains duplicate tolerance during read-only runtime proof, then after
persisted proof ownership-bounds extras by exact path + ESP + absence from the
complete pre-stage firmware baseline, removes them from BootOrder, deletes them,
and requires exact-one direct-GRUB identity before rEFInd retirement.  A
separate explicit same-backend NVRAM-only cleanup handles already-finalized r76
residue without touching GRUB filesystem bytes.


## leap16-r78 — r77 finalized-GRUB cleanup PTY child dispatch

The first r77 cleanup-only hardware attempt failed closed before any NVRAM mutation because the parent transcript wrapper launched a fresh process whose effective r75 strict child allowlist did not know the new `leap16_r77_cleanup_finalized_grub_duplicates_inner` executor. r78 keeps the boundary closed and admits only the exact no-argument `grub -> grub`, `cleanup` contract; every prior child action delegates unchanged. This is the same failure class previously exposed by r61/r62 and r73/r74, now regression-tested through the effective fresh-process stack.

## leap16-r79

- Corrects r77/r78 duplicate-direct-GRUB normalization for rEFInd -> GRUB: the transaction-recorded direct GRUB alias is intentionally parked outside BootOrder until final normalization and must not be required there prematurely.
- Retains exact path+ESP ownership checks and complete pre-stage Boot#### exclusion for firmware-created duplicate aliases.
- Allows the existing r78 `runtime-validated` transaction to continue to finalization without another reboot or manual NVRAM cleanup.
- Hardware evidence under r78 establishes automatic GRUB2 -> rEFInd end-to-end success; rEFInd -> GRUB reached automatic runtime proof but still needs a clean automatic rerun after this fix.

## leap16-r80 — Limine ↔ rEFInd hardware-campaign hardening

r80 keeps the r64 Limine/rEFInd live and restore executors enabled and applies the firmware lessons from the now hardware-proven GRUB/rEFInd pair. Limine→rEFInd source retirement now rejects a current source-path Boot#### when that numeric ID existed in the pre-stage firmware table for an unrelated path. rEFInd→Limine now ownership-bounds both canonical-Limine and EFI/BOOT duplicate aliases, removes them from BootOrder before deletion, requires exact-one primary/fallback alias sets before source retirement, and rechecks after retirement. Fallback-transfer rollback likewise removes only post-stage fallback aliases and proves the exact pre-stage alias/byte topology. Firmware alias enumeration failures now propagate instead of being mistaken for an empty set. The same gates cover restored-backup transactions because restore uses the same target transaction engines. See `R80-LIMINE-REFIND-HARDENING.md`.

## leap16-r86 — rEFInd -> systemd-boot interactive pending dispatch

The first r85 manual continuation exposed that runtime validation and interactive pending management are separate dispatch layers. r85 fixed `validate_pending_target_runtime()` for `refind:systemd-boot`, but `--manage-staged` still delegated through r76/r69/r64 and eventually into the historical GRUB2 -> Limine manager. r86 intercepts only format-v5 `refind:systemd-boot` pending state after all older manager overlays, routes the exact running target to the r85 validator and unchanged r64 finalizer, and preserves source-side generic re-arm/rollback behavior. The already-running hardware transaction is resumable without reboot/restage/manual cleanup.
