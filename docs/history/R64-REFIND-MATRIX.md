# leap16-r64 rEFInd matrix + audit ledger

This file is an evidence ledger, not a claim that implementation equals hardware proof.

## Status legend

- **HW-PROVEN** — completed on the real Leap 16 / ASUS UEFI test machine before r64.
- **TEST-COVERED / HW-PENDING** — implemented in r64 and covered by shell/synthetic regressions, but not yet proven by a real rEFInd boot transaction.
- **N/A** — same-backend edge; the cross-loader engine does not fake it as a migration.

## Live-switch matrix

| source \\ target | GRUB2 | Limine | systemd-boot | rEFInd |
|---|---|---|---|---|
| **GRUB2** | N/A | HW-PROVEN | HW-PROVEN | TEST-COVERED / HW-PENDING |
| **Limine** | HW-PROVEN | N/A | HW-PROVEN | TEST-COVERED / HW-PENDING |
| **systemd-boot** | HW-PROVEN | HW-PROVEN | N/A | TEST-COVERED / HW-PENDING |
| **rEFInd** | TEST-COVERED / HW-PENDING | TEST-COVERED / HW-PENDING | TEST-COVERED / HW-PENDING | N/A |

Existing three-loader evidence therefore remains **6/6 HW-PROVEN**. r64 adds six new directed rEFInd edges, making the implemented four-loader graph **12/12**, with the six new edges hardware-pending.

## Cross-loader backup/restore matrix

| active source \\ restored backup | GRUB2 | Limine | systemd-boot | rEFInd |
|---|---|---|---|---|
| **GRUB2** | N/A | HW-PROVEN | HW-PROVEN | TEST-COVERED / HW-PENDING |
| **Limine** | HW-PROVEN | N/A | HW-PROVEN | TEST-COVERED / HW-PENDING |
| **systemd-boot** | HW-PROVEN | HW-PROVEN | N/A | TEST-COVERED / HW-PENDING |
| **rEFInd** | TEST-COVERED / HW-PENDING | TEST-COVERED / HW-PENDING | TEST-COVERED / HW-PENDING | N/A |

Existing three-loader restore evidence remains **6/6 HW-PROVEN**. r64 implements all six rEFInd restore edges, producing a code-complete **12/12** cross-loader restore graph, pending hardware proof for the new six.

## Backup backend matrix

| backend | creation | immutable payload validation | restore substitution | hardware status |
|---|---|---|---|---|
| GRUB2 | enabled | native Leap policy/config reconstruction | enabled | HW-PROVEN |
| Limine | enabled | policy + EFI + config + splash + managed kernels/initrds | enabled | HW-PROVEN |
| systemd-boot | enabled | EFI + loader/BLS + managed kernels/initrds | enabled | HW-PROVEN |
| rEFInd | enabled | immutable `EFI/refind` + `/boot/refind_linux.conf`; `vars` excluded | enabled with write-boundary revalidation | TEST-COVERED / HW-PENDING |

`EFI/refind/vars` is runtime-mutable and is deliberately excluded from backup ownership. A restored target must create a fresh `PreviousBoot` record through a real rEFInd boot.

## Target proof/fallback matrix

| target | required real runtime proof | generic `EFI/BOOT` ownership contract |
|---|---|---|
| GRUB2 | canonical shim BootCurrent + kernel/root/cmdline/deep GRUB validation | native shim fallback transferred/proven before source retirement; direct GRUB retained second |
| Limine | canonical Limine proof **plus a second independent BootCurrent proof through Limine `EFI/BOOT`** | Limine owns byte-identical primary/fallback after proof #2 |
| systemd-boot | canonical systemd-boot BootCurrent + BLS/payload/root/cmdline validation | exact byte-identical systemd-boot fallback transferred before source retirement |
| rEFInd | canonical rEFInd BootCurrent **and `PreviousBoot` proving direct launch of `/boot/vmlinuz-<running-release>`** | r64 intentionally does **not** claim `EFI/BOOT`; unrelated fallback is preserved, ownership-proven source fallback is retired only after rEFInd proof |

### Why rEFInd does not use a Limine-style second fallback reboot

A bare copy of `refind_x64.efi` to `EFI/BOOT/BOOTX64.EFI` is not equivalent to the canonical rEFInd installation because rEFInd expects config, drivers, icons/resources and mutable state relative to its launch directory. r64 therefore refuses to invent a fake fallback proof. A future design could duplicate and independently own a complete fallback rEFInd runtime tree, but that is outside r64.

`rEFInd -> Limine` still performs two reboots/proofs because **Limine is the target** and its established final state genuinely owns `EFI/BOOT`.

## rEFInd-edge resume / rollback matrix

| edge | automatic resume | pre-proof rollback | special handling |
|---|---|---|---|
| GRUB2 -> rEFInd | enabled | inherited r26 ownership rollback | bounded multi-alias GRUB retirement after rEFInd proof |
| Limine -> rEFInd | enabled | inherited r26 ownership rollback | retires Limine primary/fallback aliases only after rEFInd proof |
| systemd-boot -> rEFInd | enabled | inherited r26 ownership rollback | source-owned systemd fallback removed only after rEFInd proof |
| rEFInd -> GRUB2 | enabled | r64 custom rollback | parked direct-GRUB alias is outside the normal target manifest and is explicitly rolled back |
| rEFInd -> Limine | enabled across both proofs | r64 split rollback | canonical proof then fallback-transfer/proof; rEFInd retained until final Limine config is frozen and revalidated |
| rEFInd -> systemd-boot | enabled | inherited r26 ownership rollback | final systemd topology proven before rEFInd deletion |

## First-hardware topology scope

r64 rEFInd edges fail closed unless all of these are true:

1. openSUSE Leap 16.x, UEFI, Secure Boot disabled as required by the existing transaction gates;
2. `/boot` lives on the same filesystem/device as `/`;
3. that filesystem is ext4;
4. the installed `refind` RPM owns an `ext4_x64.efi` driver copied to `EFI/refind/drivers_x64/`;
5. scanner policy excludes `EFI/BOOT`, `EFI/OPENSUSE`, `EFI/LIMINE`, `EFI/systemd`, and `EFI/opensuse-bootloader-switcher`;
6. exactly one canonical target rEFInd alias is committed after installer-created duplicates are normalized.

This deliberately does **not** claim Btrfs/XFS/XBOOTLDR/Tumbleweed support.

## Package acquisition policy

r64 first uses an already-installed `refind` RPM/tool set. Otherwise it attempts:

`zypper --non-interactive --no-recommends install refind`

If the configured Leap repositories do not provide it, the user can explicitly provide a trusted local package:

`BOOTLOADER_SWITCHER_REFIND_RPM=/absolute/path/to/refind.rpm ./bootloader-switcher.sh`

The local path must be an absolute, regular non-symlink file and pass `rpm -K`; installation still goes through zypper. r64 never downloads an unpinned rEFInd RPM itself.

## Latent bugs found before enabling rEFInd

1. inherited validator assumed CachyOS kernel/initramfs naming;
2. inherited installer path used pacman/Arch semantics;
3. generic source retirement modeled too few Leap source aliases;
4. direct Leap `/boot` access required an ext4 rEFInd driver;
5. rEFInd scanner could discover the retained `EFI/opensuse-bootloader-switcher/limine` reference namespace;
6. strict PTY child allowlist did not know the new rEFInd executors;
7. inherited rEFInd backup schema/restore was CachyOS-specific;
8. `EFI/refind/vars/PreviousBoot` risked being treated as immutable backup state;
9. `rEFInd -> Limine` needed the same two-proof Limine finalization contract as other Limine inbound edges;
10. restore success text needed to preserve selected-backup provenance.

## Latent bugs found/fixed during the post-enable audit

1. **False test failure in restore-dispatch audit:** Bash reformatted `case` patterns in `declare -f`; the test now checks semantic dispatch dynamically rather than assuming textual formatting.
2. **Final-target proof ordering:** systemd-boot, GRUB2 and Limine final topology is re-proven while rEFInd recovery still exists; source deletion happens afterward.
3. **Limine final-config hazard:** after proof #2 the temporary rEFInd recovery stanza is removed and the final Limine config/manifest is frozen and revalidated before deleting rEFInd.
4. **rEFInd package availability ambiguity:** repository installation remains preferred, but a trusted local-RPM path is supported without introducing an unpinned downloader.
5. **Untested filesystem overclaim:** all rEFInd edges now fail closed unless `/boot` is on the ext4 root filesystem used by the hardware test environment.
6. **Firmware Boot#### renumber/duplicate risk:** outgoing rEFInd recovery now tolerates only bounded exact-path/same-ESP duplicate aliases, keeps the recorded canonical identity mandatory, removes every bounded alias from BootOrder before deletion, then normalizes all of them at retirement.
7. **Diagnostic terminology:** inherited `PreviousBoot` messages saying “CachyOS kernel” are overridden with exact Leap kernel-release wording.

## Efficient hardware-test order

Starting from GRUB2, this sequence covers every new live edge in exactly six migrations and ends back on GRUB2:

1. GRUB2 -> rEFInd
2. rEFInd -> Limine
3. Limine -> rEFInd
4. rEFInd -> systemd-boot
5. systemd-boot -> rEFInd
6. rEFInd -> GRUB2

After the first successful rEFInd finalization, create/validate an rEFInd backup. Then, starting from GRUB2, the analogous six-run restore sequence covers every new restore edge and again ends on GRUB2:

1. GRUB2 -> restored rEFInd
2. rEFInd -> restored Limine
3. Limine -> restored rEFInd
4. rEFInd -> restored systemd-boot
5. systemd-boot -> restored rEFInd
6. rEFInd -> restored GRUB2

Do not mark a cell HW-PROVEN until its final diagnostics show the required BootCurrent/runtime proof(s), final persistent BootOrder, ownership-gated source retirement, and no pending transaction.
