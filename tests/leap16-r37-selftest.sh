#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
pass(){ printf '[PASS] %s\n' "$1"; }
fail_test(){ printf '[FAIL] %s\n' "$1" >&2; exit 1; }

printf 'openSUSE Leap 16 r37 focused self-test\n'
printf '======================================\n\n'

for f in bootloader-switcher.sh lib/*.sh tests/*.sh; do bash -n "$f" || fail_test "shell parse failed: $f"; done
pass 'all shell files parse'

grep -Fq 'SWITCHER_RELEASE="leap16-r37"' bootloader-switcher.sh || fail_test 'r37 release marker missing'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r36.sh"' bootloader-switcher.sh || fail_test 'r36 layer missing'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r37.sh"' bootloader-switcher.sh || fail_test 'r37 layer not loaded after r36'
pass 'r37 is a narrow final layer over r36'

body=$(sed -n '/^leap16_r37_verify_grub_recovery_while_systemd_active()/,/^}/p' lib/leap16_r37.sh)
grep -Fq 'r26_verify_owned_manifest "$PENDING_SOURCE_MANIFEST"' <<<"$body" || fail_test 'source manifest proof missing'
grep -Fq 'leap16_r34_verify_source_grub_ids' <<<"$body" || fail_test 'complete pre-stage GRUB alias proof missing'
! grep -Fq 'adapter_source_validate' <<<"$body" || fail_test 'target-runtime source proof still requires source to be active BootCurrent'
pass 'target-runtime GRUB recovery proof is passive/ownership-based, not active-loader based'

# Dynamic regression: while the exact systemd target is BootCurrent, the wrapper
# must use the passive source-recovery proof and must NOT call the inherited
# active-source verifier.
(
    delegated=0
    verify_pending_source_recovery_unchanged(){ delegated=$((delegated+1)); return 77; }
    leap16_pending_firmware_baseline_path(){ return 1; }
    fail(){ printf '[mock-fail] %s\n' "$*" >&2; return 1; }
    ok(){ :; }
    detect_bootloader(){ BOOTLOADER=systemd-boot; BOOT_CURRENT=0000; }
    nvram_id_matches_path(){ return 0; }
    leap16_nvram_entry_matches_current_esp(){ return 0; }
    r26_verify_owned_manifest(){ return 0; }
    leap16_r34_verify_source_grub_ids(){ return 0; }
    leap16_r34_baseline_path(){ printf '%s\n' "$TMPBASE"; }
    sudo(){
        [[ ${1:-} == -n ]] && shift
        if [[ ${1:-} == sha256sum ]]; then
            printf '%s  %s\n' "$SOURCE_HASH" "${@: -1}"
            return 0
        fi
        if [[ ${1:-} == test ]]; then return 1; fi
        return 1
    }
    R26_PENDING_FORMAT=5
    PENDING_FORMAT=5
    PENDING_SOURCE=grub
    PENDING_TARGET=systemd-boot
    PENDING_OLD_BOOT_ID=0003
    PENDING_TARGET_BOOT_ID=0000
    PENDING_OLD_BOOT_EFI_PATH='\\EFI\\OPENSUSE\\SHIM.EFI'
    PENDING_SOURCE_EFI_RESOLVED=/boot/efi/EFI/OPENSUSE/SHIM.EFI
    SOURCE_HASH=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    PENDING_SOURCE_EFI_HASH=$SOURCE_HASH
    PENDING_SOURCE_MANIFEST=/mock/source-owned.tsv
    PENDING_OLD_FALLBACK_EXISTED=0
    PENDING_OLD_FALLBACK_PATH=/definitely/not/present-r37-test
    TMPBASE=$(mktemp)
    trap 'rm -f "$TMPBASE"' EXIT
    printf 'BootCurrent: 0003\nBootOrder: 0003,0002\n' >"$TMPBASE"
    source lib/leap16_r37.sh
    verify_pending_source_recovery_unchanged
    [[ $delegated == 0 ]]
) || fail_test 'systemd-target runtime still falls into inherited active-GRUB validator'
pass 'exact systemd target runtime no longer fails because GRUB2 is not BootCurrent'

# Dynamic regression: source-active sessions must continue delegating to the
# inherited verifier, preserving r36 rollback/staging behavior.
(
    delegated=0
    verify_pending_source_recovery_unchanged(){ delegated=$((delegated+1)); return 0; }
    leap16_pending_firmware_baseline_path(){ return 1; }
    detect_bootloader(){ BOOTLOADER=grub; BOOT_CURRENT=0003; }
    R26_PENDING_FORMAT=5 PENDING_FORMAT=5 PENDING_SOURCE=grub PENDING_TARGET=systemd-boot PENDING_OLD_BOOT_ID=0003 PENDING_TARGET_BOOT_ID=0000
    source lib/leap16_r37.sh
    verify_pending_source_recovery_unchanged
    [[ $delegated == 1 ]]
) || fail_test 'source-active behavior was not delegated unchanged'
pass 'source-active GRUB staging/rollback behavior remains inherited unchanged'

# Dynamic regression: generic Leap firmware-order diagnostics must see the
# r34/r35 source-firmware-baseline.txt for this edge.
(
    leap16_pending_firmware_baseline_path(){ printf '/legacy/missing\n'; return 0; }
    R26_PENDING_FORMAT=5 PENDING_FORMAT=5 PENDING_SOURCE=grub PENDING_TARGET=systemd-boot
    TMPDIR=$(mktemp -d)
    trap 'rm -rf "$TMPDIR"' EXIT
    PENDING_TRANSACTION_SNAPSHOT_DIR=$TMPDIR
    LEAP16_R34_FIRMWARE_BASELINE=source-firmware-baseline.txt
    printf 'BootCurrent: 0003\nBootOrder: 0003,0002\n' >"$TMPDIR/$LEAP16_R34_FIRMWARE_BASELINE"
    leap16_r34_baseline_path(){ printf '%s/%s\n' "$PENDING_TRANSACTION_SNAPSHOT_DIR" "$LEAP16_R34_FIRMWARE_BASELINE"; }
    source lib/leap16_r37.sh
    got=$(leap16_pending_firmware_baseline_path)
    [[ $got == "$TMPDIR/$LEAP16_R34_FIRMWARE_BASELINE" ]]
) || fail_test 'generic firmware baseline resolver cannot see r34/r35 systemd baseline'
pass 'generic firmware-order gates/diagnostics can consume the adapter firmware baseline'

printf '\nAll focused openSUSE Leap 16 r37 self-tests passed.\n'
