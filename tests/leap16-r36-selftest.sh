#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
pass(){ printf '[PASS] %s\n' "$1"; }
fail_test(){ printf '[FAIL] %s\n' "$1" >&2; exit 1; }

printf 'openSUSE Leap 16 r36 focused self-test\n'
printf '======================================\n\n'

for f in bootloader-switcher.sh lib/*.sh tests/*.sh; do bash -n "$f" || fail_test "shell parse failed: $f"; done
pass 'all shell files parse'

grep -Fq 'SWITCHER_RELEASE="leap16-r36"' bootloader-switcher.sh || fail_test 'r36 release marker missing'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r35.sh"' bootloader-switcher.sh || fail_test 'r35 layer missing'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r36.sh"' bootloader-switcher.sh || fail_test 'r36 rollback layer not loaded last'
pass 'r36 is a narrow final layer over r35'

body=$(sed -n '/^leap16_r36_rollback_grub_to_systemd()/,/^}/p' lib/leap16_r36.sh)
! grep -Eq '^[[:space:]]*leap16_validate_pending_firmware_order([[:space:]]|$)' <<<"$body" || fail_test 'legacy systemd rollback still depends on the unavailable firmware baseline gate'
grep -Fq 'verify_pending_source_recovery_unchanged' <<<"$body" || fail_test 'source ownership proof missing'
grep -Fq 'leap16_r36_verify_target_manifest_for_rollback' <<<"$body" || fail_test 'target ownership manifest proof missing'
grep -Fq 'count_nvram_entries_for_target systemd-boot' <<<"$body" || fail_test 'exact single systemd NVRAM ownership gate missing'
grep -Fq 'Target Boot$target is already absent; accepting idempotent partial rollback recovery' <<<"$body" || fail_test 'partial NVRAM rollback recovery gate missing'
pass 'legacy rollback uses exact source/target ownership rather than retirement baseline'

line_order=$(grep -n 'leap16_r36_order_without_exact_target' <<<"$body" | tail -n1 | cut -d: -f1)
line_delete=$(grep -n 'efibootmgr -b "$target" -B' <<<"$body" | tail -n1 | cut -d: -f1)
line_files=$(grep -n 'leap16_r36_remove_target_manifest_paths' <<<"$body" | tail -n1 | cut -d: -f1)
[[ -n $line_order && -n $line_delete && -n $line_files && $line_order -lt $line_delete && $line_delete -lt $line_files ]] || fail_test 'rollback ordering is not BootOrder -> exact target NVRAM -> target files'
pass 'rollback cannot create a persistent BootOrder -> missing target EFI window'

grep -Fq 'r26_restore_fallback_on_rollback' <<<"$body" || fail_test 'source fallback restore missing'
grep -Fq 'final_order == "$LEAP16_R36_ROLLBACK_ORDER"' <<<"$body" || fail_test 'live non-target BootOrder preservation postcondition missing'
grep -Fq 'adapter_source_validate grub' <<<"$body" || fail_test 'post-cleanup GRUB deep validation missing'
grep -Fq 'ROLLBACK-COMPLETE. GRUB2 remains authoritative' <<<"$body" || fail_test 'successful rollback completion gate missing'
pass 'rollback ends with exact order/fallback/source postconditions'

# Routing must touch only the new adapter edge.
grep -Fq 'rollback_pending_candidate_pre_leap16_r36 "$@"' lib/leap16_r36.sh || fail_test 'other rollback directions are not delegated unchanged'
grep -Fq 'if leap16_r34_sdboot_pending; then' lib/leap16_r36.sh || fail_test 'GRUB2 -> systemd-boot direction gate missing'
pass 'all non-systemd rollback directions remain delegated unchanged'

# Dynamic helper regression: removing Boot0000 from 0003,0002,0000 must keep
# 0003,0002 exactly and must never reconstruct a historical baseline order.
(
    rollback_pending_candidate(){ :; }
    fail(){ printf '[mock-fail] %s\n' "$*" >&2; return 1; }
    ok(){ :; }
    PENDING_OLD_BOOT_ID=0003
    PENDING_TARGET_BOOT_ID=0000
    MOCK_ORDER=0003,0002,0000
    leap16_current_boot_order(){ printf '%s\n' "$MOCK_ORDER"; }
    boot_id_exists(){ case "$1" in 0003|0002|0000) return 0;; *) return 1;; esac; }
    sudo(){
        [[ ${1:-} == -n ]] && shift
        [[ ${1:-} == efibootmgr && ${2:-} == -o ]] || return 1
        MOCK_ORDER=$3
    }
    source lib/leap16_r36.sh
    leap16_r36_order_without_exact_target
    [[ $MOCK_ORDER == 0003,0002 ]]
    [[ $LEAP16_R36_ROLLBACK_ORDER == 0003,0002 ]]
) || fail_test 'dynamic live-order preservation helper failed'
pass 'dynamic rollback helper preserves the exact live non-target order'

printf '\nAll focused openSUSE Leap 16 r36 self-tests passed.\n'
