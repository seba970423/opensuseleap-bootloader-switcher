#!/usr/bin/env bash
# leap16-r76: direction-correct continuation for an already booted
# rEFInd -> native openSUSE GRUB2 transaction.
#
# Hardware r75 reached the exact staged shim target and booted Leap through
# GRUB, but automatic resume delegated runtime proof to the historical
# Leap GRUB2 -> Limine validator.  That validator correctly rejected GRUB as
# "not Limine" before promotion or source retirement.  This layer recognizes
# only format-v5 refind:grub state and reuses the r64/r71 native GRUB candidate,
# runtime, passive-source, and finalization contracts.  No repair, restaging,
# or rollback is performed to adopt the already-running target session.

LEAP16_R76_HARDWARE_NOTE='r75 rEFInd -> GRUB: exact shim target booted Leap; automatic resume SAFE-FAILED in stale Limine runtime dispatcher before promotion/source retirement'

leap16_r76_refind_grub_pending() {
    [[ ${PENDING_FORMAT:-} == "${R26_PENDING_FORMAT:-5}" \
       && ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == refind:grub ]]
}

leap16_r76_validate_refind_grub_runtime() {
    local target source next order first diag
    validate_pending_compatibility \
        || { fail "Pending rEFInd -> GRUB transaction is incompatible: ${PENDING_REASON:-unknown reason}"; return 1; }
    leap16_r76_refind_grub_pending \
        || { fail 'r76 GRUB runtime validator received the wrong transaction direction'; return 1; }
    [[ ${PENDING_PHASE:-} == boot-armed || ${PENDING_PHASE:-} == runtime-validated ]] || {
        fail "rEFInd -> GRUB runtime validation requires boot-armed/runtime-validated state (phase is ${PENDING_PHASE:-missing})"
        return 1
    }

    target=${PENDING_TARGET_BOOT_ID^^}; source=${PENDING_OLD_BOOT_ID^^}
    detect_bootloader
    [[ ${BOOTLOADER:-} == grub ]] \
        || { fail "Current bootloader is $(bootloader_display_name "${BOOTLOADER:-unknown}"), not GRUB2"; return 1; }
    [[ ${BOOT_CURRENT^^} == "$target" ]] \
        || { fail "GRUB runtime proof requires BootCurrent=Boot$target (found Boot${BOOT_CURRENT:-unknown})"; return 1; }
    nvram_id_matches_path "$target" "$PENDING_TARGET_EFI_PATH" \
        || { fail "BootCurrent GRUB target Boot$target no longer has the recorded exact shim path"; return 1; }
    leap16_nvram_entry_matches_current_esp "$target" \
        || { fail "BootCurrent GRUB target Boot$target is no longer bound to the transaction ESP"; return 1; }
    leap16_require_sudo_session || return 1

    run_validation preflight || return 1
    validate_pending_compatibility \
        || { fail "Pending rEFInd -> GRUB transaction became incompatible during runtime preflight: ${PENDING_REASON:-unknown reason}"; return 1; }

    next=$(pending_bootnext_id 2>/dev/null || true)
    if [[ -n $next && ${next^^} != "$target" ]]; then
        fail "BootNext belongs to unrelated Boot${next^^}; refusing to alter it or certify GRUB runtime"
        return 1
    elif [[ -n $next ]]; then
        warn "Firmware still reports consumed transaction BootNext=Boot${next^^}; clearing only that exact target value"
        sudo efibootmgr -N >/dev/null \
            || { fail 'Could not clear the consumed GRUB transaction BootNext'; return 1; }
        [[ -z $(pending_bootnext_id 2>/dev/null || true) ]] \
            || { fail 'BootNext remained set after the exact transaction value was cleared'; return 1; }
        ok 'Consumed GRUB transaction BootNext is now clear'
    else
        ok 'BootNext was consumed/cleared by firmware after the one-time GRUB boot'
    fi

    order=$(leap16_current_boot_order 2>/dev/null || true)
    first=${order%%,*}; first=${first^^}
    [[ -n $order && $first == "$source" ]] || {
        fail "Persistent BootOrder changed before GRUB runtime certification; expected rEFInd source Boot$source first (found ${order:-unavailable})"
        return 1
    }
    ok "Persistent BootOrder still keeps rEFInd source Boot$source first"

    pending_validate_running_kernel || return 1
    pending_validate_runtime_cmdline_against_source || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    leap16_r64_validate_grub_candidate || return 1
    printf '\nDeep native openSUSE GRUB2 validation from the actually booted shim target:\n'
    validate_grub_boot_chain runtime || return 1
    printf '\nRe-validating the untouched rEFInd source as passive recovery:\n'
    leap16_r64_verify_refind_source_passive || return 1
    leap16_r64_validate_grub_direct_alias || return 1

    if [[ $PENDING_PHASE == boot-armed ]]; then
        pending_set_phase runtime-validated || {
            fail 'GRUB runtime checks passed but the phase could not be persisted; source cleanup remains forbidden'
            return 1
        }
        PENDING_PHASE=runtime-validated
    fi
    [[ $PENDING_PHASE == runtime-validated ]] || return 1
    diag=$(pending_capture_runtime_diagnostics runtime-pass-grub-from-refind | tail -n1 || true)
    [[ -n $diag ]] && printf 'Runtime diagnostic snapshot: %s\n' "$diag"
    r35_write_local_transaction_result runtime-validated \
        "rEFInd -> GRUB2 runtime proof passed. BootCurrent is the exact native openSUSE shim target; rEFInd remains persistent-first and no source retirement has run." || true
    printf '\nRUNTIME-VALIDATED rEFInd -> native GRUB2 one-time boot succeeded.\n'
    printf 'Persistent BootOrder is still rEFInd-first; fallback transfer and source retirement remain a separate ownership-gated finalization.\n'
}

# Intercept only the missing outbound direction after every older runtime
# overlay has loaded.  All other directions retain their exact effective path.
if declare -F validate_pending_target_runtime >/dev/null 2>&1; then
    eval "$(declare -f validate_pending_target_runtime | sed '1s/validate_pending_target_runtime/validate_pending_target_runtime_pre_leap16_r76/')"
fi
validate_pending_target_runtime() {
    if leap16_r76_refind_grub_pending; then
        leap16_r76_validate_refind_grub_runtime
    else
        validate_pending_target_runtime_pre_leap16_r76 "$@"
    fi
}

leap16_r76_refind_grub_pending_menu() {
    local choice next source target order first
    leap16_r76_refind_grub_pending \
        || { fail 'r76 rEFInd -> GRUB pending menu received the wrong transaction direction'; return 1; }
    source=${PENDING_OLD_BOOT_ID^^}; target=${PENDING_TARGET_BOOT_ID^^}
    detect_bootloader
    show_pending_details

    if [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == "$target" ]]; then
        case "$PENDING_PHASE" in
            boot-armed)
                next=$(pending_bootnext_id 2>/dev/null || true)
                [[ -z $next || ${next^^} == "$target" ]] || {
                    fail "BootNext belongs to unrelated Boot${next^^}; refusing runtime proof or firmware mutation"
                    return 1
                }
                printf '\nThe exact native openSUSE GRUB shim target Boot%s is running.\n' "$target"
                printf 'rEFInd Boot%s remains persistent-first recovery; no source retirement has occurred.\n' "$source"
                printf '[1] Run exact GRUB runtime validation now\n'
                printf '[2] Re-check GRUB candidate + passive rEFInd recovery only\n'
                printf '[3] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) leap16_require_sudo_session && validate_pending_target_runtime ;;
                    2)
                        leap16_require_sudo_session || return 1
                        run_validation preflight \
                            && verify_pending_candidate_ownership_unchanged \
                            && leap16_r64_validate_grub_candidate \
                            && validate_grub_boot_chain runtime \
                            && leap16_r64_verify_refind_source_passive \
                            && leap16_r64_validate_grub_direct_alias
                        ;;
                    3|'') return 0 ;;
                    *) printf 'Invalid selection.\n'; return 1 ;;
                esac
                return $?
                ;;
            runtime-validated)
                order=$(leap16_current_boot_order 2>/dev/null || true)
                first=${order%%,*}; first=${first^^}
                [[ $first == "$source" || $first == "$target" ]] || {
                    fail "Persistent BootOrder has an unexpected first entry (${order:-unavailable}); finalization is refused"
                    return 1
                }
                printf '\nThe exact native GRUB shim target Boot%s has persisted runtime proof.\n' "$target"
                printf '[1] Re-run exact GRUB runtime validation\n'
                printf '[2] Re-check every gate and FINALIZE now\n'
                printf '[3] Re-check GRUB target + passive rEFInd recovery only\n'
                printf '[4] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) leap16_require_sudo_session && validate_pending_target_runtime ;;
                    2) leap16_require_sudo_session && r26_finalize_adapter_transaction ;;
                    3)
                        leap16_require_sudo_session || return 1
                        run_validation preflight \
                            && pending_validate_running_kernel \
                            && pending_validate_runtime_cmdline_against_source \
                            && verify_pending_candidate_ownership_unchanged \
                            && validate_grub_boot_chain runtime \
                            && leap16_r64_verify_refind_source_passive \
                            && leap16_r64_validate_grub_direct_alias
                        ;;
                    4|'') return 0 ;;
                    *) printf 'Invalid selection.\n'; return 1 ;;
                esac
                return $?
                ;;
            candidate-ready)
                fail "GRUB Boot$target is the recorded target, but the transaction was never armed; a manually entered target session cannot earn runtime proof"
                return 1
                ;;
            *) fail "Unsupported rEFInd -> GRUB pending phase: $PENDING_PHASE"; return 1 ;;
        esac
    fi

    if [[ $BOOTLOADER == refind && ${BOOT_CURRENT^^} == "$source" ]]; then
        case "$PENDING_PHASE" in
            candidate-ready)
                printf '\nrEFInd source Boot%s is active and native GRUB shim target Boot%s is parked.\n' "$source" "$target"
                printf '[1] Revalidate rEFInd source + native GRUB candidate\n'
                printf '[2] Arm one-time GRUB test + automatic resume\n'
                printf '[3] Roll back the staged GRUB candidate\n'
                printf '[4] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) leap16_require_sudo_session && run_validation preflight && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && leap16_r64_validate_grub_candidate ;;
                    2) leap16_require_sudo_session && r26_rearm_candidate_with_resume ;;
                    3) rollback_pending_candidate ;;
                    4|'') return 0 ;;
                    *) printf 'Invalid selection.\n'; return 1 ;;
                esac
                return $?
                ;;
            boot-armed)
                next=$(pending_bootnext_id 2>/dev/null || true)
                if [[ ${next^^} == "$target" ]]; then
                    printf '\nOne-time native GRUB BootNext=Boot%s is armed and waiting for reboot.\n' "$target"
                    printf '[1] Re-check source/candidate integrity and leave BootNext armed\n'
                    printf '[2] Cancel this exact BootNext and return to candidate-ready\n'
                    printf '[3] Roll back the staged GRUB candidate\n'
                    printf '[4] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in
                        1) leap16_require_sudo_session && run_validation preflight && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && leap16_r64_validate_grub_candidate ;;
                        2) cancel_pending_one_time_boot ;;
                        3) rollback_pending_candidate ;;
                        4|'') return 0 ;;
                        *) printf 'Invalid selection.\n'; return 1 ;;
                    esac
                    return $?
                elif [[ -z $next ]]; then
                    printf '\nThe GRUB one-shot was consumed/cleared and the recorded rEFInd source booted again.\n'
                    printf '[1] Revalidate and return to candidate-ready\n'
                    printf '[2] Roll back the staged GRUB candidate\n'
                    printf '[3] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in
                        1) leap16_require_sudo_session && reset_consumed_test_to_candidate_ready ;;
                        2) rollback_pending_candidate ;;
                        3|'') return 0 ;;
                        *) printf 'Invalid selection.\n'; return 1 ;;
                    esac
                    return $?
                fi
                fail "BootNext belongs to unrelated Boot${next^^}; the transaction will not touch it"
                return 1
                ;;
            runtime-validated)
                printf '\nGRUB runtime proof is persisted, but the recorded rEFInd source Boot%s is active again.\n' "$source"
                printf '[1] Re-arm the already-proven GRUB target for continuation\n'
                printf '[2] Re-check rEFInd source + GRUB target ownership\n'
                printf '[3] Roll back/abandon the GRUB candidate\n'
                printf '[4] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) leap16_require_sudo_session && r26_rearm_runtime_validated_target ;;
                    2) leap16_require_sudo_session && run_validation preflight && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && leap16_r64_validate_grub_candidate ;;
                    3) rollback_pending_candidate ;;
                    4|'') return 0 ;;
                    *) printf 'Invalid selection.\n'; return 1 ;;
                esac
                return $?
                ;;
        esac
    fi

    fail "Active session matches neither recorded rEFInd source Boot$source nor native GRUB target Boot$target; no transaction writes were attempted"
    return 1
}

if declare -F manage_pending_migration >/dev/null 2>&1; then
    eval "$(declare -f manage_pending_migration | sed '1s/manage_pending_migration/manage_pending_migration_pre_leap16_r76/')"
fi
manage_pending_migration() {
    pending_exists || { printf '\nNo pending/staged migration exists.\n'; return 0; }
    load_pending_state \
        || { printf '\nPending migration state is invalid: %s\n' "${PENDING_REASON:-unknown reason}"; return 1; }
    validate_pending_compatibility \
        || { printf '\nPending migration state is invalid/incompatible: %s\n' "${PENDING_REASON:-unknown reason}"; return 1; }
    if leap16_r76_refind_grub_pending; then
        leap16_r76_refind_grub_pending_menu
    else
        manage_pending_migration_pre_leap16_r76 "$@"
    fi
}

# Render the hardware result as a dispatch failure, not a failed GRUB boot,
# while the exact still-recoverable transaction remains pending.
if declare -F r22_show_last_auto_result >/dev/null 2>&1; then
    eval "$(declare -f r22_show_last_auto_result | sed '1s/r22_show_last_auto_result/r22_show_last_auto_result_pre_leap16_r76/')"
fi
r22_show_last_auto_result() {
    local f="$PENDING_STATE_DIR/${R22_RESULT_FILE_NAME:-last-auto-result.txt}" detail=''
    if pending_exists && validate_pending_compatibility >/dev/null 2>&1 \
       && leap16_r76_refind_grub_pending && [[ -f $f ]]; then
        detail=$(sed -n 's/^detail=//p' "$f" 2>/dev/null | head -n1 || true)
        if [[ $detail == *'automatically booted grub target failed runtime proof'* \
           || $detail == *'automatically booted GRUB target failed runtime proof'* \
           || $detail == *'automatically booted GRUB2 target failed runtime proof'* ]]; then
            printf 'Last transaction result:\n'
            printf '  [NOTE] Historical r75 resume-dispatch failure after the exact native GRUB shim target booted Leap; rEFInd source cleanup was not attempted.\n\n'
            return 0
        fi
    fi
    r22_show_last_auto_result_pre_leap16_r76 "$@"
}

# r64 captures auto-resume-pass after finalization, but the old generic report
# treats that name as a pre-retirement promotion checkpoint.  Report the two
# now-observed rEFInd final states according to their actual topology.  This is
# diagnostic-only and does not replace any transaction gate.
leap16_r76_write_final_refind_edge_order_report() {
    local out=$1 direction=${PENDING_SOURCE:-}:${PENDING_TARGET:-}
    local target=${PENDING_TARGET_BOOT_ID^^} direct='' order next source_ids='' assessment=pass reason=''
    order=$(leap16_current_boot_order 2>/dev/null || true)
    next=$(pending_bootnext_id 2>/dev/null || true)
    case "$direction" in
        refind:grub)
            direct=$(leap16_r64_grub_direct_id 2>/dev/null || true); direct=${direct^^}
            source_ids=$(leap16_r48_ids_for_current_esp_path "$LEAP16_R64_REFIND_EFI" | awk 'NF' | paste -sd, -)
            if [[ ${BOOT_CURRENT^^} != "$target" ]]; then assessment=fail; reason="BootCurrent is not finalized GRUB shim Boot$target"
            elif [[ -n $next ]]; then assessment=fail; reason="BootNext remains set to Boot${next^^}"
            elif [[ ! $direct =~ ^[0-9A-F]{4}$ ]]; then assessment=fail; reason='recorded direct-GRUB identity is unavailable'
            elif [[ $order != "$target,$direct"* ]]; then assessment=fail; reason="expected finalized shim/direct leading order $target,$direct, got ${order:-unreadable}"
            elif ! boot_id_exists "$target" || ! nvram_id_matches_path "$target" "$R28_GRUB_SHIM_PATH" || ! leap16_nvram_entry_matches_current_esp "$target"; then assessment=fail; reason="finalized shim Boot$target is not exact"
            elif ! boot_id_exists "$direct" || ! nvram_id_matches_path "$direct" "$R28_GRUB_DIRECT_PATH" || ! leap16_nvram_entry_matches_current_esp "$direct"; then assessment=fail; reason="finalized direct GRUB Boot$direct is not exact"
            elif [[ -n $source_ids ]]; then assessment=fail; reason="retired rEFInd alias set remains (${source_ids})"
            else reason='finalized native GRUB shim/direct topology is exact; rEFInd source aliases are retired'; fi
            ;;
        grub:refind)
            source_ids=$(leap16_r64_current_ids_for_source_paths grub | awk 'NF' | paste -sd, -)
            if [[ ${BOOT_CURRENT^^} != "$target" ]]; then assessment=fail; reason="BootCurrent is not finalized rEFInd Boot$target"
            elif [[ -n $next ]]; then assessment=fail; reason="BootNext remains set to Boot${next^^}"
            elif [[ ${order%%,*} != "$target" ]]; then assessment=fail; reason="expected finalized rEFInd Boot$target first, got ${order:-unreadable}"
            elif ! boot_id_exists "$target" || ! nvram_id_matches_path "$target" "$LEAP16_R64_REFIND_EFI" || ! leap16_nvram_entry_matches_current_esp "$target"; then assessment=fail; reason="finalized rEFInd Boot$target is not exact"
            elif [[ -n $source_ids ]]; then assessment=fail; reason="retired GRUB source alias set remains (${source_ids})"
            else reason='finalized rEFInd topology is exact; bounded GRUB source aliases are retired'; fi
            ;;
        *) return 2 ;;
    esac
    {
        printf 'assessment=%s\n' "$assessment"
        printf 'reason=%s\n' "$reason"
        printf 'full_current_boot_order=%s\n' "$order"
        printf 'stable_expected_prefix=%s\n' "$([[ $direction == refind:grub ]] && printf '%s,%s' "$target" "$direct" || printf '%s' "$target")"
        printf 'retired_source_aliases_still_present=%s\n' "${source_ids:-none}"
    } >"$out"
}

if declare -F leap16_write_firmware_order_report >/dev/null 2>&1; then
    eval "$(declare -f leap16_write_firmware_order_report | sed '1s/leap16_write_firmware_order_report/leap16_write_firmware_order_report_pre_leap16_r76/')"
fi
leap16_write_firmware_order_report() {
    case "${PENDING_SOURCE:-}:${PENDING_TARGET:-}:${2:-snapshot}" in
        refind:grub:auto-resume-pass|refind:grub:finalized-grub-from-refind|\
        grub:refind:auto-resume-pass|grub:refind:finalized-refind-from-grub)
            leap16_r76_write_final_refind_edge_order_report "$1"
            ;;
        *) leap16_write_firmware_order_report_pre_leap16_r76 "$@" ;;
    esac
}

# Explicit evidence ledger.  Only a complete hardware run advances an edge.
leap16_r64_print_matrix() {
    cat <<'MATRIX'
openSUSE Leap 16 bootloader matrix — leap16-r76

Legend:
  HW-PROVEN       completed automatically on real hardware
  HW-PENDING      implemented + regression-covered; complete hardware run pending
  —               same-backend; not a cross-loader edge

LIVE SWITCH MATRIX (source rows -> target columns)
                 GRUB2        Limine       systemd-boot  rEFInd
  GRUB2          —            HW-PROVEN    HW-PROVEN     HW-PROVEN
  Limine         HW-PROVEN    —            HW-PROVEN     HW-PENDING
  systemd-boot   HW-PROVEN    HW-PROVEN    —             HW-PENDING
  rEFInd         HW-PENDING   HW-PENDING    HW-PENDING    —

CROSS-LOADER RESTORE MATRIX (active source -> restored backup target)
                 GRUB2        Limine       systemd-boot  rEFInd
  GRUB2          —            HW-PROVEN    HW-PROVEN     HW-PENDING
  Limine         HW-PROVEN    —            HW-PROVEN     HW-PENDING
  systemd-boot   HW-PROVEN    HW-PROVEN    —             HW-PENDING
  rEFInd         HW-PENDING   HW-PENDING    HW-PENDING    —

BACKUP BACKENDS
  GRUB2          HW-PROVEN
  Limine         HW-PROVEN
  systemd-boot   HW-PROVEN
  rEFInd         HW-PROVEN (immutable EFI/refind + refind_linux.conf; vars excluded)

r75/r76 hardware checkpoint:
  GRUB2 -> rEFInd completed automatic runtime proof, ownership-gated finalization, and source retirement under r75.
  rEFInd -> GRUB booted the exact native shim target to Leap userspace under r75, then SAFE-FAILED in the stale Limine runtime dispatcher before promotion or source retirement.
  r76 adopts that exact boot-armed target session in place. The edge remains HW-PENDING until runtime validation and finalization complete on hardware.
MATRIX
}
