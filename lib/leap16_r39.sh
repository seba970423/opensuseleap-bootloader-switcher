#!/usr/bin/env bash
# leap16-r39: repair the systemd-boot -> GRUB2 hardware-test edge after the
# first real reverse one-shot boot.
#
# Hardware evidence from r38 proved two separate facts:
#   1. The GRUB shim candidate actually booted (BootCurrent == target shim), but
#      the automatic root continuation fell through to an older Limine-oriented
#      runtime path.
#   2. During that real shim boot, firmware/shim created additional same-ESP
#      aliases (generic EFI/BOOT and a duplicate direct-GRUB path).  They were
#      not present in the complete pre-stage firmware baseline.  They must be
#      treated as post-stage firmware churn: never mistaken for pre-existing
#      ownership, never allowed to survive finalization/rollback, and never
#      deleted until the exact path/ESP/baseline relationship is proven.
#
# This overlay does not alter the proven GRUB2 <-> Limine or GRUB2 ->
# systemd-boot production layers.  It is compatible with an already-running
# r38 reverse candidate so the current real GRUB session can be proved and
# finalized without a pointless restage.

LEAP16_R39_CHURN_RECORD='r39-firmware-churn.tsv'
LEAP16_R39_CHURN_RETIRED='r39-firmware-churn-retired'

leap16_r39_churn_record_path() {
    local snap=${PENDING_TRANSACTION_SNAPSHOT_DIR:-${TRANSACTION_SNAPSHOT_DIR:-}}
    [[ -n $snap ]] || return 1
    printf '%s/%s\n' "$snap" "$LEAP16_R39_CHURN_RECORD"
}

leap16_r39_churn_retired_path() {
    local snap=${PENDING_TRANSACTION_SNAPSHOT_DIR:-${TRANSACTION_SNAPSHOT_DIR:-}}
    [[ -n $snap ]] || return 1
    printf '%s/%s\n' "$snap" "$LEAP16_R39_CHURN_RETIRED"
}

leap16_r39_baseline_has_id() {
    local id=${1^^} baseline
    baseline=$(leap16_r34_baseline_path 2>/dev/null || true)
    [[ -n $baseline && -s $baseline ]] || return 1
    grep -Eq "^Boot${id}\\*?[[:space:]]" "$baseline"
}

leap16_r39_entry_path_for_id() {
    local id=${1^^} line
    line=$(leap16_boot_entry_line_for_id "$id" | head -n1 || true)
    [[ -n $line ]] || return 1
    efi_path_from_efibootmgr_line "$line" 2>/dev/null
}

leap16_r39_allowed_churn_path() {
    local norm
    norm=$(normalize_efi_path "$1" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    case "$norm" in
        efi/boot/bootx64.efi|efi/opensuse/shim.efi|efi/opensuse/grubx64.efi|efi/opensuse/grub.efi) return 0 ;;
        *) return 1 ;;
    esac
}

# Enumerate only post-baseline aliases that point to transaction-relevant paths
# on this exact ESP.  Unrelated newly-added firmware/BBS entries are preserved
# and never claimed by the switcher.
leap16_r39_collect_transaction_churn() {
    local source=${PENDING_OLD_BOOT_ID^^} target=${PENDING_TARGET_BOOT_ID^^} direct id path norm
    direct=$(leap16_r38_direct_id)
    while IFS= read -r id; do
        id=${id^^}
        [[ $id =~ ^[0-9A-F]{4}$ ]] || continue
        [[ $id != "$source" && $id != "$target" && $id != "$direct" ]] || continue
        leap16_r39_baseline_has_id "$id" && continue
        path=$(leap16_r39_entry_path_for_id "$id" 2>/dev/null || true)
        [[ -n $path ]] || continue
        leap16_r39_allowed_churn_path "$path" || continue
        leap16_nvram_entry_matches_current_esp "$id" || continue
        norm=$(normalize_efi_path "$path" | tr '[:upper:]' '[:lower:]')
        printf '%s\t%s\n' "$id" "$norm"
    done < <(efibootmgr -v 2>/dev/null | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\)\*.*/\1/p' | tr '[:lower:]' '[:upper:]' | LC_ALL=C sort -u)
}

leap16_r39_record_transaction_churn() {
    local p tmp id path count=0
    p=$(leap16_r39_churn_record_path) || return 1
    if [[ -s $p ]]; then
        ok 'Using the existing transaction-owned firmware-churn record'
        return 0
    fi
    tmp=$(mktemp) || return 1
    printf 'version\t1\n' >"$tmp" || { rm -f -- "$tmp"; return 1; }
    while IFS=$'\t' read -r id path; do
        [[ $id =~ ^[0-9A-F]{4}$ && -n $path ]] || continue
        printf 'entry\t%s\t%s\n' "$id" "$path" >>"$tmp" || { rm -f -- "$tmp"; return 1; }
        count=$((count + 1))
    done < <(leap16_r39_collect_transaction_churn)
    mv -f -- "$tmp" "$p" || { rm -f -- "$tmp"; return 1; }
    chmod 600 -- "$p" 2>/dev/null || true
    if ((count)); then
        ok "Recorded $count post-stage firmware alias(es) as exact transaction-associated churn"
    else
        ok 'No post-stage transaction-associated firmware aliases were observed'
    fi
}

leap16_r39_recorded_churn_ids() {
    local p
    p=$(leap16_r39_churn_record_path) || return 1
    [[ -s $p ]] || return 0
    awk -F'\t' '$1=="entry" && $2 ~ /^[0-9A-F]{4}$/{print $2}' "$p" | LC_ALL=C sort -u
}

leap16_r39_verify_recorded_churn() {
    local p retired id expected path norm current_ids recorded_ids
    p=$(leap16_r39_churn_record_path) || return 1
    retired=$(leap16_r39_churn_retired_path) || return 1
    [[ -s $p ]] || { fail 'r39 firmware-churn ownership record is missing'; return 1; }

    if [[ -e $retired ]]; then
        while IFS= read -r id; do
            [[ -n $id ]] || continue
            boot_id_exists "$id" && { fail "Retired firmware-churn Boot$id reappeared"; return 1; }
        done < <(leap16_r39_recorded_churn_ids)
        ok 'Recorded post-stage firmware churn remains retired'
        return 0
    fi

    while IFS=$'\t' read -r tag id expected; do
        [[ $tag == entry ]] || continue
        [[ $id =~ ^[0-9A-F]{4}$ ]] || return 1
        boot_id_exists "$id" || { fail "Recorded post-stage firmware-churn Boot$id disappeared before cleanup boundary"; return 1; }
        leap16_nvram_entry_matches_current_esp "$id" || { fail "Recorded firmware-churn Boot$id changed ESP binding"; return 1; }
        path=$(leap16_r39_entry_path_for_id "$id" 2>/dev/null || true)
        norm=$(normalize_efi_path "$path" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        [[ -n $norm && $norm == "$expected" ]] || { fail "Recorded firmware-churn Boot$id changed EFI path"; return 1; }
    done <"$p"

    # Prove there is no unrecorded same-ESP native GRUB alias beyond the exact
    # target/direct identities and the recorded churn set.
    recorded_ids=$(leap16_r39_recorded_churn_ids | paste -sd, -)
    current_ids=$({ r28_ids_for_path "$R28_GRUB_SHIM_PATH"; r28_ids_for_path "$R28_GRUB_DIRECT_PATH"; } | awk '/^[0-9A-Fa-f]{4}$/{print toupper($0)}' | LC_ALL=C sort -u)
    while IFS= read -r id; do
        [[ -n $id ]] || continue
        [[ $id == ${PENDING_TARGET_BOOT_ID^^} || $id == $(leap16_r38_direct_id) ]] && continue
        case ",$recorded_ids," in *",$id,"*) ;; *) fail "Unrecorded native GRUB alias Boot$id appeared after staging"; return 1 ;; esac
    done <<<"$current_ids"

    # Generic-fallback aliases may be synthesized by firmware after a real boot.
    # Baseline-owned ones are unrelated and preserved; post-baseline ones must
    # already be in the exact churn record before finalization can proceed.
    while IFS= read -r id; do
        id=${id^^}; [[ $id =~ ^[0-9A-F]{4}$ ]] || continue
        leap16_nvram_entry_matches_current_esp "$id" || continue
        leap16_r39_baseline_has_id "$id" && continue
        [[ $id == ${PENDING_OLD_BOOT_ID^^} || $id == ${PENDING_TARGET_BOOT_ID^^} || $id == $(leap16_r38_direct_id) ]] && continue
        case ",$recorded_ids," in *",$id,"*) ;; *) fail "Unrecorded generic-fallback alias Boot$id appeared after the churn record was frozen"; return 1 ;; esac
    done < <(r21_nvram_ids_for_esp_path '\EFI\BOOT\BOOTX64.EFI' | awk '/^[0-9A-Fa-f]{4}$/{print toupper($0)}' | LC_ALL=C sort -u)

    ok 'Every post-stage same-ESP GRUB/fallback alias is baseline-distinguished and ownership-recorded'
}

# Source recovery while the target GRUB session is running must prove the
# systemd source as passive recovery state, not demand that it be BootCurrent.
leap16_r39_verify_systemd_recovery_while_grub_active() {
    local source=${PENDING_OLD_BOOT_ID^^} hash ids fallback expected
    [[ ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == systemd-boot:grub ]] || return 1
    [[ ${BOOTLOADER:-} == grub && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || {
        fail 'Passive systemd-boot recovery proof is restricted to the exact running GRUB target session'
        return 1
    }
    nvram_id_matches_path "$source" "$PENDING_OLD_BOOT_EFI_PATH" || { fail 'Source systemd-boot NVRAM entry/path changed while GRUB is running'; return 1; }
    leap16_nvram_entry_matches_current_esp "$source" || { fail 'Source systemd-boot NVRAM entry changed ESP binding'; return 1; }
    hash=$(r21_hash_privileged "$PENDING_SOURCE_EFI_RESOLVED")
    [[ -n $hash && $hash == "$PENDING_SOURCE_EFI_HASH" ]] || { fail 'Source systemd-boot EFI executable changed'; return 1; }
    r26_verify_owned_manifest "$PENDING_SOURCE_MANIFEST" || return 1

    fallback="$PENDING_OLD_FALLBACK_PATH"
    if r28_transfer_complete; then
        expected=$PENDING_TARGET_EFI_HASH
    else
        expected=$PENDING_OLD_FALLBACK_HASH
    fi
    [[ -n $expected && $(r21_hash_privileged "$fallback") == "$expected" ]] || { fail 'Generic EFI fallback does not match the expected transaction phase'; return 1; }

    ids=$(leap16_r38_current_systemd_ids | paste -sd, -)
    [[ -n $ids && $ids != *,* && ${ids^^} == "$source" ]] || { fail "Canonical systemd-boot source alias set changed (found ${ids:-none})"; return 1; }
    leap16_r34_validate_systemd_boot_chain recovery || return 1
    if ! r28_transfer_complete; then
        grep -Eq '^[[:space:]]*LOADER_TYPE=.*systemd-boot' /etc/sysconfig/bootloader 2>/dev/null \
            || { fail 'LOADER_TYPE changed before GRUB runtime proof/finalization'; return 1; }
    fi
    ok "Recorded systemd-boot source Boot$source remains exact passive recovery while GRUB is BootCurrent"
}

eval "$(declare -f verify_pending_source_recovery_unchanged | sed '1s/verify_pending_source_recovery_unchanged/verify_pending_source_recovery_unchanged_pre_leap16_r39/')"
verify_pending_source_recovery_unchanged() {
    if leap16_r38_pending; then
        detect_bootloader
        if [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]]; then
            leap16_r39_verify_systemd_recovery_while_grub_active
            return $?
        fi
    fi
    verify_pending_source_recovery_unchanged_pre_leap16_r39 "$@"
}

# r38 candidate validation expected the pre-transfer systemd fallback.  Make a
# resumed partial finalization idempotent: once the transaction's own transfer
# checkpoint exists, the same validator accepts only the proven shim hash.
eval "$(declare -f leap16_r38_validate_grub_files_candidate | sed '1s/leap16_r38_validate_grub_files_candidate/leap16_r38_validate_grub_files_candidate_pre_leap16_r39/')"
leap16_r38_validate_grub_files_candidate() {
    if ! leap16_r38_pending || ! r28_transfer_complete; then
        leap16_r38_validate_grub_files_candidate_pre_leap16_r39 "$@"
        return $?
    fi
    local saved=${PENDING_OLD_FALLBACK_HASH:-}
    PENDING_OLD_FALLBACK_HASH=$PENDING_TARGET_EFI_HASH
    leap16_r38_validate_grub_files_candidate_pre_leap16_r39 "$@"
    local rc=$?
    PENDING_OLD_FALLBACK_HASH=$saved
    return "$rc"
}

leap16_r39_validate_grub_runtime() {
    local first diag
    validate_pending_compatibility || { fail "Pending reverse transaction is incompatible: $PENDING_REASON"; return 1; }
    leap16_r38_pending || { fail 'r39 runtime validator received the wrong transaction direction'; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || {
        fail "Runtime proof requires GRUB shim Boot${PENDING_TARGET_BOOT_ID^^} as BootCurrent"
        return 1
    }
    leap16_require_sudo_session || return 1
    run_validation preflight || return 1
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext was not consumed/cleared by firmware'; return 1; }
    ok 'BootNext was consumed/cleared by firmware after the one-time GRUB boot'
    first=$(pending_bootorder_first)
    [[ ${first^^} == ${PENDING_OLD_BOOT_ID^^} ]] || { fail "Persistent BootOrder drifted; expected systemd-boot source Boot$PENDING_OLD_BOOT_ID first, found Boot${first:-unknown}"; return 1; }
    ok "Persistent BootOrder still keeps systemd-boot source Boot$PENDING_OLD_BOOT_ID first"
    pending_validate_running_kernel || return 1
    pending_validate_runtime_cmdline_against_source || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    leap16_r38_validate_grub_candidate || return 1
    verify_pending_source_recovery_unchanged || return 1
    leap16_r39_record_transaction_churn || return 1
    leap16_r39_verify_recorded_churn || return 1
    pending_set_phase runtime-validated || { fail 'Runtime checks passed but runtime-validated phase could not be persisted'; return 1; }
    PENDING_PHASE=runtime-validated
    diag=$(pending_capture_runtime_diagnostics runtime-pass-grub-from-systemd | tail -n1 || true)
    [[ -n $diag ]] && printf 'Runtime diagnostic snapshot: %s\n' "$diag"
    printf '\nRUNTIME-VALIDATED systemd-boot -> GRUB2 one-shot boot succeeded.\n'
    printf '  BootCurrent: Boot%s -> %s\n' "$PENDING_TARGET_BOOT_ID" "$PENDING_TARGET_EFI_PATH"
    printf '  BootNext: clear\n'
    printf '  Persistent BootOrder: systemd-boot remains first until finalization\n'
}

eval "$(declare -f validate_pending_target_runtime | sed '1s/validate_pending_target_runtime/validate_pending_target_runtime_pre_leap16_r39/')"
validate_pending_target_runtime() {
    if leap16_r38_pending; then
        leap16_r39_validate_grub_runtime
    else
        validate_pending_target_runtime_pre_leap16_r39 "$@"
    fi
}

# Replace r38's final BootOrder helper for this edge.  The runtime proof records
# exact post-baseline firmware churn, so finalization removes those aliases from
# BootOrder and deletes only those exact variables while every referenced EFI
# file still exists.  Unrelated current entries are preserved.
eval "$(declare -f leap16_r38_final_grub_order_without_systemd | sed '1s/leap16_r38_final_grub_order_without_systemd/leap16_r38_final_grub_order_without_systemd_pre_leap16_r39/')"
leap16_r38_final_grub_order_without_systemd() {
    local target=${PENDING_TARGET_BOOT_ID^^} direct source=${PENDING_OLD_BOOT_ID^^} order id joined retired
    local -a ids=() out=("$target" "$direct") churn=()
    if ! leap16_r38_pending; then
        leap16_r38_final_grub_order_without_systemd_pre_leap16_r39 "$@"
        return $?
    fi
    retired=$(leap16_r39_churn_retired_path) || return 1
    mapfile -t churn < <(leap16_r39_recorded_churn_ids)
    if [[ ! -e $retired ]]; then
        leap16_r39_verify_recorded_churn || return 1
    fi
    order=$(leap16_current_boot_order) || return 1
    IFS=',' read -ra ids <<<"$order"
    for id in "${ids[@]}"; do
        id=${id^^}
        [[ -n $id && $id != "$target" && $id != "$direct" && $id != "$source" ]] || continue
        local owned=0 c
        for c in "${churn[@]}"; do [[ $id == "$c" ]] && { owned=1; break; }; done
        ((owned)) && continue
        boot_id_exists "$id" && out+=("$id")
    done
    joined=$(IFS=,; printf '%s' "${out[*]}")
    sudo efibootmgr -o "$joined" >/dev/null || return 1
    order=$(leap16_current_boot_order)
    [[ $order == "$target,$direct"* ]] || { fail "Final GRUB BootOrder does not begin shim/direct ($order)"; return 1; }
    ! leap16_order_has_id "$order" "$source" || { fail "Source systemd-boot Boot$source remains in persistent BootOrder"; return 1; }
    for id in "${churn[@]}"; do
        leap16_order_has_id "$order" "$id" && { fail "Firmware-churn Boot$id remains in persistent BootOrder"; return 1; }
    done
    ok "Removed source systemd-boot Boot$source and recorded firmware churn from BootOrder while every referenced EFI file still exists"

    if [[ ! -e $retired ]]; then
        for id in "${churn[@]}"; do
            [[ -n $id ]] || continue
            if boot_id_exists "$id"; then
                sudo efibootmgr -b "$id" -B >/dev/null || { fail "Could not delete ownership-recorded firmware-churn Boot$id"; return 1; }
                ok "Deleted ownership-recorded post-stage firmware-churn Boot$id after removing it from BootOrder"
            fi
        done
        : >"$retired" || return 1
        chmod 600 -- "$retired" 2>/dev/null || true
    fi
    leap16_r39_verify_recorded_churn || return 1
}

# Rollback must also remove post-stage firmware/shim aliases that did not exist
# in the source baseline.  This is safe only after exact path+ESP classification.
eval "$(declare -f leap16_r38_rollback | sed '1s/leap16_r38_rollback/leap16_r38_rollback_pre_leap16_r39/')"
leap16_r38_rollback() {
    local source target direct next answer id path order joined
    local -a ids=() out=() churn=()
    if ! leap16_r38_pending; then
        leap16_r38_rollback_pre_leap16_r39 "$@"
        return $?
    fi
    validate_pending_compatibility || { fail "Pending reverse transaction is incompatible: $PENDING_REASON"; return 1; }
    detect_bootloader
    source=${PENDING_OLD_BOOT_ID^^}; target=${PENDING_TARGET_BOOT_ID^^}; direct=$(leap16_r38_direct_id)
    [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == "$source" ]] || { fail "Rollback requires recorded systemd-boot source Boot$source"; return 1; }
    run_validation preflight || return 1
    verify_pending_source_recovery_unchanged || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    leap16_r39_record_transaction_churn || return 1
    leap16_r39_verify_recorded_churn || return 1
    mapfile -t churn < <(leap16_r39_recorded_churn_ids)
    next=$(pending_bootnext_id)
    [[ -z $next || ${next^^} == "$target" ]] || { fail "Unrelated BootNext=Boot$next exists; refusing rollback"; return 1; }
    printf '\nExact systemd-boot -> GRUB2 candidate rollback (r39):\n'
    printf '  - keep source systemd-boot Boot%s and its generic fallback exact\n' "$source"
    printf '  - remove recorded shim/direct candidate aliases plus only baseline-distinguished post-stage churn\n'
    printf '  - remove every owned NVRAM alias from BootOrder while its EFI file still exists\n'
    printf '  - remove only transaction-owned EFI/OPENSUSE + /boot/grub2 + /etc/default/grub\n'
    read -r -p 'Type ROLLBACK to remove this exact GRUB2 candidate: ' answer
    [[ $answer == ROLLBACK ]] || { printf 'Rollback cancelled. No state was modified.\n'; return 0; }
    [[ -z $next ]] || sudo efibootmgr -N >/dev/null || return 1
    r22_disarm_user_resume_bundle || true
    order=$(leap16_current_boot_order) || return 1
    IFS=',' read -ra ids <<<"$order"
    for id in "${ids[@]}"; do
        id=${id^^}; [[ -n $id ]] || continue
        [[ $id == "$target" || $id == "$direct" ]] && continue
        local owned=0 c
        for c in "${churn[@]}"; do [[ $id == "$c" ]] && { owned=1; break; }; done
        ((owned)) && continue
        boot_id_exists "$id" && out+=("$id")
    done
    ((${#out[@]} > 0)) || { fail 'Rollback would leave an empty persistent BootOrder'; return 1; }
    joined=$(IFS=,; printf '%s' "${out[*]}")
    sudo efibootmgr -o "$joined" >/dev/null || return 1
    [[ $(pending_bootorder_first) == "$source" ]] || { fail 'Source systemd-boot is not first after candidate/churn removal from BootOrder'; return 1; }
    for id in "$target" "$direct" "${churn[@]}"; do
        [[ -n $id ]] || continue
        boot_id_exists "$id" && sudo efibootmgr -b "$id" -B >/dev/null || true
    done
    r26_remove_owned_manifest_paths "$PENDING_TARGET_MANIFEST" || return 1
    r26_restore_fallback_on_rollback || return 1
    r28_restore_source_boot_aux || return 1
    [[ -z $(leap16_r38_native_grub_ids) ]] || { fail 'A native GRUB2 alias remains after rollback'; return 1; }
    verify_pending_source_recovery_unchanged || return 1
    remove_pending_transaction_snapshot || true
    rm -f -- "$PENDING_STATE_FILE"
    r35_write_local_transaction_result success "systemd-boot -> GRUB2 candidate rolled back exactly under r39; source Boot$source remains authoritative and recorded post-stage firmware churn was retired." || true
    ok 'ROLLBACK-COMPLETE. systemd-boot remains authoritative; GRUB2 candidate and transaction-associated firmware churn are removed.'
}

# Automatic root continuation must dispatch this edge explicitly.  Do not fall
# through to the historical Limine -> GRUB2 resume function again.
leap16_r39_resume_grub_root() {
    r22_root_bundle_preflight || return 1
    local bundle=$R22_RESUME_BUNDLE conf="$R22_RESUME_BUNDLE/resume.conf" detail
    mkdir -p -- "$bundle/diagnostics" || return 1
    LEAP16_DIAGNOSTIC_ROOT="$bundle/diagnostics" LEAP16_AUTO_RESUME=1
    export LEAP16_DIAGNOSTIC_ROOT LEAP16_AUTO_RESUME
    exec > >(tee -a "$bundle/automatic-resume.log") 2>&1
    printf 'openSUSE Bootloader Switcher %s automatic systemd-boot -> GRUB2 resume\nBundle: %s\n' "${SWITCHER_RELEASE:-leap16-r39}" "$bundle"

    load_pending_state || { r22_write_user_result "$conf" failed "Invalid root-owned reverse pending state: $PENDING_REASON" || true; r22_remove_resume_service_files; return 1; }
    validate_pending_compatibility || { r22_write_user_result "$conf" failed "systemd-boot -> GRUB2 resume transaction is incompatible: $PENDING_REASON" || true; r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true; r22_remove_resume_service_files; return 1; }
    detect_bootloader
    if [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == ${PENDING_OLD_BOOT_ID^^} ]]; then
        printf 'Automatic reverse resume: firmware returned to the recorded systemd-boot source; no GRUB proof/finalization allowed.\n'
        r22_resume_source_fallback "$conf" || return 1
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" safe-fallback || true
        return 0
    fi
    [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || {
        leap16_capture_diagnostics auto-resume-unexpected-bootcurrent >/dev/null 2>&1 || true
        r22_write_user_result "$conf" failed 'systemd-boot -> GRUB2 automatic resume saw an unexpected BootCurrent/loader identity; no source retirement occurred.' || true
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
        r22_remove_resume_service_files
        return 1
    }

    case "$PENDING_PHASE" in
        boot-armed)
            leap16_r39_validate_grub_runtime || {
                r22_write_user_result "$conf" failed 'GRUB2 booted, but exact r39 runtime proof failed; systemd-boot was NOT retired.' || true
                leap16_capture_diagnostics auto-resume-runtime-failed >/dev/null 2>&1 || true
                r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
                r22_remove_resume_service_files
                return 1
            }
            PENDING_PHASE=runtime-validated
            r22_sync_user_phase_from_root "$conf" runtime-validated || true
            ;;
        runtime-validated) printf 'Automatic reverse resume: GRUB runtime proof already persisted; continuing finalization.\n' ;;
        *) r22_write_user_result "$conf" failed "Unexpected r39 reverse automatic-resume phase: $PENDING_PHASE" || true; r22_remove_resume_service_files; return 1 ;;
    esac

    if ! r26_finalize_adapter_transaction; then
        r22_write_user_result "$conf" failed 'GRUB runtime proof passed, but ownership-gated systemd-boot retirement/finalization failed. Unproven cleanup is forbidden.' || true
        leap16_capture_diagnostics auto-resume-finalization-failed >/dev/null 2>&1 || true
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
        r22_remove_resume_service_files
        return 1
    fi

    leap16_capture_diagnostics auto-resume-pass >/dev/null 2>&1 || true
    r13_sync_root_diagnostics_to_user "$conf" "$bundle" success || true
    detail="systemd-boot -> GRUB2 automated runtime proof and finalization succeeded under r39. Shim Boot$PENDING_TARGET_BOOT_ID is first; direct GRUB is second; source systemd-boot and ownership-recorded post-stage firmware churn were retired."
    r22_cleanup_user_shadow_after_success "$conf"
    r22_write_user_result "$conf" success "$detail" || true
    r22_remove_resume_service_files
    rm -rf -- "$bundle" 2>/dev/null || true
    return 0
}

eval "$(declare -f r22_resume_transaction_root | sed '1s/r22_resume_transaction_root/r22_resume_transaction_root_pre_leap16_r39/')"
r22_resume_transaction_root() {
    local src='' tgt=''
    if [[ -f ${PENDING_STATE_FILE:-/nonexistent} ]]; then
        src=$(awk -F'\t' '$1=="source"{print $2;exit}' "$PENDING_STATE_FILE" 2>/dev/null || true)
        tgt=$(awk -F'\t' '$1=="target"{print $2;exit}' "$PENDING_STATE_FILE" 2>/dev/null || true)
    fi
    if [[ $src:$tgt == systemd-boot:grub ]]; then
        leap16_r39_resume_grub_root
    else
        r22_resume_transaction_root_pre_leap16_r39 "$@"
    fi
}
