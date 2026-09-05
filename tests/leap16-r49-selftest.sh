#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ok(){ :; }; fail(){ printf 'FAIL: %s\n' "$*" >&2; return 1; }

# Stubs representing the r48 layer that r49 wraps.
R48_STRICT_CALLS=0
BASE_SOURCE_CALLS=0
verify_pending_source_recovery_unchanged(){ R48_STRICT_CALLS=$((R48_STRICT_CALLS+1)); return 0; }
verify_pending_source_recovery_unchanged_pre_leap16_r48(){ BASE_SOURCE_CALLS=$((BASE_SOURCE_CALLS+1)); return 0; }
leap16_r48_pending(){ return 0; }
leap16_r48_validate_meta(){ return 0; }
leap16_r48_fallback_id(){ printf '0003\n'; }
leap16_r48_current_fallback_ids(){ printf '0003\n'; }
boot_id_exists(){ return 0; }
leap16_nvram_entry_matches_current_esp(){ return 0; }
nvram_id_matches_path(){ return 0; }
r21_hash_privileged(){ printf '%s\n' "$PENDING_OLD_FALLBACK_HASH"; }
detect_bootloader(){ BOOTLOADER=systemd-boot; BOOT_CURRENT=0001; }

PENDING_PHASE=runtime-validated
PENDING_SOURCE=limine
PENDING_TARGET=systemd-boot
PENDING_OLD_BOOT_ID=0000
PENDING_TARGET_BOOT_ID=0001
PENDING_OLD_BOOT_EFI_PATH='\\EFI\\LIMINE\\LIMINE_X64.EFI'
PENDING_OLD_FALLBACK_PATH="$TMP/BOOTX64.EFI"
PENDING_OLD_FALLBACK_HASH=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
PENDING_REASON=valid
LEAP16_R21_FALLBACK_EFI_PATH='\\EFI\\BOOT\\BOOTX64.EFI'

ORDER='0001,0000,0003'
leap16_current_boot_order(){ printf '%s\n' "$ORDER"; }

# shellcheck source=/dev/null
source "$ROOT/lib/leap16_r49.sh"

# The exact r48 stranded topology must bypass the stale r48 source-first order
# assertion while still running the complete pre-r48 source ownership proof.
verify_pending_source_recovery_unchanged
[[ $BASE_SOURCE_CALLS -eq 1 ]]
[[ $R48_STRICT_CALLS -eq 0 ]]

# Fresh pre-promotion source-first state must still delegate to r48 unchanged.
ORDER='0000,0003,0001'
verify_pending_source_recovery_unchanged
[[ $R48_STRICT_CALLS -eq 1 ]]

# A promoted topology with source/fallback swapped must fail closed.
ORDER='0001,0003,0000'
_saved_fail=$(declare -f fail)
fail(){ return 1; }
if verify_pending_source_recovery_unchanged; then
    printf 'FAIL: malformed promoted source/fallback order was accepted\n' >&2
    exit 1
fi
eval "$_saved_fail"

printf 'leap16-r49 selftest: PASS\n'
