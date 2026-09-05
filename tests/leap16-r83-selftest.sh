#!/usr/bin/env bash
set -euo pipefail
ROOT=${R83_TEST_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
fail_test(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
source_effective_stack(){
    local prelude
    prelude=$(awk '/^select_target_bootloader\(\)/{exit} {print}' "$ROOT/bootloader-switcher.sh" | sed '/^SCRIPT_DIR=/d')
    SCRIPT_DIR=$ROOT
    eval "$prelude"
}

(
    source_effective_stack
    [[ $SWITCHER_RELEASE == leap16-r83 ]] || fail_test 'r83 release not loaded'
    matrix=$(leap16_r64_print_matrix)
    [[ $matrix == *'matrix — leap16-r83'* ]] || fail_test 'matrix heading is stale'
    declare -f leap16_r64_create_or_adopt_limine_fallback_alias | grep -Fq '>&2' \
        || fail_test 'fallback alias helper does not isolate status output from ID stdout'
)

# Exact hardware-exposed bug: the underlying r28 helper emits a success line to
# stdout.  The r83 wrapper must still return exactly the Boot#### ID to $(...).
(
    source_effective_stack
    LEAP16_R21_FALLBACK_EFI_PATH='\\EFI\\BOOT\\BOOTX64.EFI'
    r21_fallback_ids_now(){ :; }
    r28_create_alias_create_only(){
        printf '[OK] Created parked Boot0002 UEFI OS -> %s without changing BootOrder/BootNext\n' "$2"
        R28_CREATED_ALIAS_ID=0002
        return 0
    }
    err=$(mktemp); trap 'rm -f -- "$err"' EXIT
    id=$(leap16_r64_create_or_adopt_limine_fallback_alias 2>"$err") \
        || fail_test 'clean fallback alias creation failed'
    [[ $id == 0002 ]] || fail_test "stdout ID was contaminated: <$id>"
    grep -Fq '[OK] Created parked Boot0002' "$err" \
        || fail_test 'human status line was lost instead of being redirected to stderr'
)

# Existing exact fallback aliases keep the same ownership checks and also return
# only the ID.
(
    source_effective_stack
    LEAP16_R21_FALLBACK_EFI_PATH='\\EFI\\BOOT\\BOOTX64.EFI'
    r21_fallback_ids_now(){ printf '0007\n'; }
    leap16_nvram_entry_matches_current_esp(){ [[ $1 == 0007 ]]; }
    nvram_id_matches_path(){ [[ $1 == 0007 && $2 == "$LEAP16_R21_FALLBACK_EFI_PATH" ]]; }
    id=$(leap16_r64_create_or_adopt_limine_fallback_alias)
    [[ $id == 0007 ]] || fail_test "existing fallback alias returned unexpected stdout: <$id>"
)

# Full promotion regression with the real r83 fallback-ID wrapper and a noisy
# r28 create-only child.  r82's focused test mocked the wrapper itself and thus
# could not observe stdout contamination at this boundary.
(
    source_effective_stack
    td=$(mktemp -d); trap 'rm -rf -- "$td"' EXIT
    PENDING_SOURCE=refind; PENDING_TARGET=limine; PENDING_PHASE=runtime-validated
    PENDING_OLD_BOOT_ID=0001; PENDING_TARGET_BOOT_ID=0000
    PENDING_TARGET_MANIFEST="$td/target-owned.tsv"; printf owned >"$PENDING_TARGET_MANIFEST"
    PENDING_TARGET_EFI_RESOLVED="$td/LIMINE_X64.EFI"; printf limine >"$PENDING_TARGET_EFI_RESOLVED"
    PENDING_TARGET_EFI_HASH=$(printf 'a%.0s' {1..64})
    PENDING_OLD_FALLBACK_PATH="$td/BOOTX64.EFI"
    LEAP16_R21_FALLBACK_EFI_PATH='\\EFI\\BOOT\\BOOTX64.EFI'
    printf '0000,0001\n' >"$td/order"; : >"$td/next"; : >"$td/meta-id"

    validate_pending_compatibility(){ return 0; }
    detect_bootloader(){ BOOTLOADER=limine; BOOT_CURRENT=0000; }
    leap16_r64_validate_limine_primary_runtime(){ return 0; }
    leap16_current_boot_order(){ cat "$td/order"; }
    r21_order_primary_then_source_recovery(){ printf '0000,0001\n' >"$td/order"; }
    leap16_r64_limine_primary_manifest_path(){ printf '%s/primary-owned.tsv\n' "$td"; }
    leap16_r64_rewrite_limine_recovery_to_refind(){ printf '%064d\n' 1; }
    r21_atomic_replace(){ cp -- "$1" "$2"; }
    r21_hash_privileged(){ [[ $1 == "$PENDING_OLD_FALLBACK_PATH" ]] && printf '%s\n' "$PENDING_TARGET_EFI_HASH" || command sha256sum -- "$1" | awk '{print $1}'; }
    r21_fallback_ids_now(){ :; }
    r28_create_alias_create_only(){
        printf '[OK] Created parked Boot0002 UEFI OS -> %s without changing BootOrder/BootNext\n' "$2"
        R28_CREATED_ALIAS_ID=0002
    }
    leap16_r64_refresh_limine_manifest(){ return 0; }
    leap16_r64_update_limine_fallback_meta(){ printf '%s\n' "$1" >"$td/meta-id"; [[ $1 == 0002 ]]; }
    r21_order_primary_fallback_then_existing(){ printf '0000,0002,0001\n' >"$td/order"; cat "$td/order"; }
    leap16_r64_verify_transferred_limine(){ [[ $(cat "$td/order") == 0000,0002,0001 ]]; }
    sudo(){
        if [[ ${1:-} == efibootmgr && ${2:-} == -n ]]; then printf '%s\n' "${3^^}" >"$td/next"; return 0; fi
        command "$@"
    }
    pending_bootnext_id(){ cat "$td/next"; }
    pending_capture_runtime_diagnostics(){ printf '%s/diag\n' "$td"; }
    leap16_r64_restore_pre_limine_fallback_state(){ fail_test 'r83 entered rollback after a valid noisy create-only result'; }
    ok(){ :; }; fail(){ printf 'FAILMSG: %s\n' "$*" >&2; }

    leap16_r64_promote_and_stage_limine_fallback >/dev/null \
        || fail_test 'r83 full promotion rejected a valid fallback alias because of status output'
    [[ $(cat "$td/meta-id") == 0002 ]] || fail_test 'metadata did not receive the clean fallback ID'
    [[ $(cat "$td/order") == 0000,0002,0001 && $(cat "$td/next") == 0002 ]] \
        || fail_test 'r83 full promotion did not reach fallback-armed topology'
)

# Regression guard: r82's dedicated Limine,rEFInd promotion ordering remains in
# the effective function and the generic source-dropping helper stays absent.
(
    source_effective_stack
    declare -f leap16_r64_promote_and_stage_limine_fallback | grep -Fq 'r21_order_primary_then_source_recovery' \
        || fail_test 'r82 primary+source ordering repair was lost'
    ! declare -f leap16_r64_promote_and_stage_limine_fallback | grep -Fq 'adapter_target_promote' \
        || fail_test 'generic source-dropping promotion helper resurfaced'
)

printf 'leap16-r83 selftest: PASS\n'
