#!/usr/bin/env bash
set -euo pipefail
ROOT=${R82_TEST_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
fail_test(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
source_effective_stack(){
    local prelude
    prelude=$(awk '/^select_target_bootloader\(\)/{exit} {print}' "$ROOT/bootloader-switcher.sh" | sed '/^SCRIPT_DIR=/d')
    SCRIPT_DIR=$ROOT
    eval "$prelude"
}

(
    source_effective_stack
    [[ $SWITCHER_RELEASE == leap16-r82 ]] || fail_test 'r82 release not loaded'
    matrix=$(leap16_r64_print_matrix)
    [[ $matrix == *'matrix — leap16-r82'* ]] || fail_test 'matrix heading is stale'
    [[ $matrix == *'rEFInd         HW-PROVEN    HW-PENDING   HW-PENDING    —'* ]] \
        || fail_test 'reverse Limine edge was incorrectly promoted to HW-PROVEN'
    declare -f leap16_r64_promote_and_stage_limine_fallback | grep -Fq 'r21_order_primary_then_source_recovery' \
        || fail_test 'dedicated primary+source recovery ordering is not wired'
    ! declare -f leap16_r64_promote_and_stage_limine_fallback | grep -Fq 'adapter_target_promote' \
        || fail_test 'generic source-dropping promotion helper remains in the effective reverse path'
)

# Reproduce both the pre-promotion r81 ordering (source,target) and the exact
# plausible stranded state after the generic helper (target only). In either
# case, r82 must restore target,source before any EFI/BOOT transfer is allowed.
for start_order in 0001,0000 0000; do
(
    source_effective_stack
    td=$(mktemp -d); trap 'rm -rf -- "$td"' EXIT
    PENDING_SOURCE=refind; PENDING_TARGET=limine; PENDING_PHASE=runtime-validated
    PENDING_OLD_BOOT_ID=0001; PENDING_TARGET_BOOT_ID=0000
    PENDING_TARGET_MANIFEST="$td/target-owned.tsv"; printf owned >"$PENDING_TARGET_MANIFEST"
    PENDING_TARGET_EFI_RESOLVED="$td/LIMINE_X64.EFI"; printf limine >"$PENDING_TARGET_EFI_RESOLVED"
    PENDING_TARGET_EFI_HASH=$(printf 'a%.0s' {1..64})
    PENDING_OLD_FALLBACK_PATH="$td/BOOTX64.EFI"
    printf '%s\n' "$start_order" >"$td/order"; : >"$td/next"; : >"$td/trace"

    mark(){ printf ' %s' "$1" >>"$td/trace"; }
    validate_pending_compatibility(){ return 0; }
    detect_bootloader(){ BOOTLOADER=limine; BOOT_CURRENT=0000; }
    leap16_r64_validate_limine_primary_runtime(){ mark validated; return 0; }
    leap16_current_boot_order(){ cat "$td/order"; }
    r21_order_primary_then_source_recovery(){ mark ordered; printf '0000,0001\n' >"$td/order"; return 0; }
    adapter_target_promote(){ fail_test 'generic promotion helper was called'; }
    leap16_r64_limine_primary_manifest_path(){ printf '%s/primary-owned.tsv\n' "$td"; }
    leap16_r64_rewrite_limine_recovery_to_refind(){ mark pretransfer; printf '%064d\n' 1; }
    r21_atomic_replace(){ mark transfer; cp -- "$1" "$2"; return 0; }
    r21_hash_privileged(){ [[ $1 == "$PENDING_OLD_FALLBACK_PATH" ]] && printf '%s\n' "$PENDING_TARGET_EFI_HASH" || command sha256sum -- "$1" | awk '{print $1}'; }
    leap16_r64_create_or_adopt_limine_fallback_alias(){ mark alias; printf '0002\n'; }
    leap16_r64_refresh_limine_manifest(){ mark manifest; return 0; }
    leap16_r64_update_limine_fallback_meta(){ mark meta; return 0; }
    r21_order_primary_fallback_then_existing(){ mark fallback-order; printf '0000,0002,0001\n' >"$td/order"; cat "$td/order"; }
    leap16_r64_verify_transferred_limine(){ mark verify-transfer; [[ $(cat "$td/order") == 0000,0002,0001 ]]; }
    sudo(){
        if [[ ${1:-} == efibootmgr && ${2:-} == -n ]]; then printf '%s\n' "${3^^}" >"$td/next"; mark bootnext; return 0; fi
        command "$@"
    }
    pending_bootnext_id(){ cat "$td/next"; }
    pending_capture_runtime_diagnostics(){ mark diagnostics; printf '%s/diag\n' "$td"; }
    leap16_r64_restore_pre_limine_fallback_state(){ fail_test 'valid promotion unexpectedly entered rollback'; }
    ok(){ :; }; fail(){ printf 'FAILMSG: %s\n' "$*" >&2; }

    leap16_r64_promote_and_stage_limine_fallback >/dev/null \
        || fail_test "r82 could not promote from r81 ordering $start_order"
    trace=$(cat "$td/trace")
    [[ $trace == *' validated ordered pretransfer transfer'* ]] \
        || fail_test "fallback transfer began before dedicated recovery ordering ($trace)"
    [[ $(cat "$td/order") == 0000,0002,0001 && $(cat "$td/next") == 0002 ]] \
        || fail_test "valid r82 fallback staging ended in wrong topology ($(cat "$td/order") / $(cat "$td/next"))"
)
done

# Fail closed before the ordering write if the existing primary/source runtime
# gate does not pass. This preserves the no-manual-repair contract.
(
    source_effective_stack
    PENDING_SOURCE=refind; PENDING_TARGET=limine; PENDING_PHASE=runtime-validated
    PENDING_OLD_BOOT_ID=0001; PENDING_TARGET_BOOT_ID=0000; MOCK_ORDER='0000'; writes=0
    validate_pending_compatibility(){ return 0; }
    detect_bootloader(){ BOOTLOADER=limine; BOOT_CURRENT=0000; }
    leap16_r64_validate_limine_primary_runtime(){ return 1; }
    r21_order_primary_then_source_recovery(){ writes=$((writes+1)); return 0; }
    leap16_current_boot_order(){ printf '%s\n' "$MOCK_ORDER"; }
    ! leap16_r64_promote_and_stage_limine_fallback || fail_test 'failed primary/source proof was accepted'
    [[ $writes == 0 && $MOCK_ORDER == 0000 ]] || fail_test 'BootOrder mutated before primary/source proof'
)

printf 'leap16-r82 selftest: PASS\n'
