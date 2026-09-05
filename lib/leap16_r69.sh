#!/usr/bin/env bash
# leap16-r69
# r68 repaired the automatic inbound * -> rEFInd runtime dispatcher, but the
# interactive selector-[2] pending manager still fell through to the historical
# GRUB2 -> Limine manager.  A real rEFInd BootCurrent therefore hit the stale
# error "Current bootloader is neither the recorded GRUB2 source nor Limine
# target" before r68's runtime validator could be reached.
#
# r69 adds a direction-correct pending manager for inbound rEFInd targets only.
# It does not alter staging, proof, finalization, rollback, or any non-rEFInd
# edge.  The existing r68 runtime proof and r64 ownership-gated finalizer remain
# authoritative.

LEAP16_R69_HARDWARE_NOTE='r68 interactive pending manager SAFE-FAILED on stale GRUB2/Limine routing while canonical rEFInd Boot0005 remained active; no source cleanup attempted'

leap16_r69_inbound_refind_pending_menu() {
    local choice next source target order first
    leap16_r68_refind_target_pending || { fail 'r69 inbound-rEFInd pending menu received the wrong transaction direction'; return 1; }
    source=${PENDING_OLD_BOOT_ID^^}
    target=${PENDING_TARGET_BOOT_ID^^}

    detect_bootloader
    show_pending_details

    # Exact running rEFInd target session.  This is the hardware state reached
    # by r67/r68 and is the only target session eligible for runtime proof or
    # finalization.
    if [[ $BOOTLOADER == refind && ${BOOT_CURRENT^^} == "$target" ]]; then
        case "$PENDING_PHASE" in
            boot-armed)
                next=$(pending_bootnext_id 2>/dev/null || true)
                if [[ -n $next && ${next^^} != "$target" ]]; then
                    fail "BootNext belongs to unrelated Boot${next^^}; refusing runtime proof or firmware mutation"
                    return 1
                fi
                printf '\nThe exact rEFInd one-shot target Boot%s is running.\n' "$target"
                printf '%s Boot%s remains persistent recovery until rEFInd earns runtime proof.\n' "$(bootloader_display_name "$PENDING_SOURCE")" "$source"
                if [[ -z $next ]]; then
                    printf 'The transaction BootNext has been consumed/cleared, as expected after the one-shot boot.\n'
                else
                    printf 'Firmware still exposes consumed transaction BootNext=Boot%s; the r68 runtime validator will clear only that exact target value.\n' "${next^^}"
                fi
                printf '[1] Run exact rEFInd runtime validation now\n'
                printf '[2] Re-check target ownership + passive source recovery (read-only except sudo session acquisition)\n'
                printf '[3] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) leap16_require_sudo_session && validate_pending_target_runtime ;;
                    2)
                        leap16_require_sudo_session || return 1
                        run_validation preflight && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep && leap16_r68_verify_source_recovery_while_refind_active
                        ;;
                    3|'') return 0 ;;
                    *) printf 'Invalid selection.\n'; return 1 ;;
                esac
                return $?
                ;;
            runtime-validated)
                order=$(leap16_current_boot_order 2>/dev/null || true)
                first=${order%%,*}; first=${first^^}
                printf '\nThe exact rEFInd target Boot%s has persisted direct-kernel runtime proof.\n' "$target"
                if [[ $first == "$source" ]]; then
                    printf '%s Boot%s is still persistent-first; no source retirement has occurred yet.\n' "$(bootloader_display_name "$PENDING_SOURCE")" "$source"
                elif [[ $first == "$target" ]]; then
                    printf 'rEFInd Boot%s is already persistent-first; finalization will re-prove both target and surviving source recovery before retirement.\n' "$target"
                else
                    fail "Persistent BootOrder has an unexpected first entry (${order:-unavailable}); finalization is refused"
                    return 1
                fi
                printf '[1] Re-run exact rEFInd runtime validation\n'
                printf '[2] Re-check every gate and FINALIZE now\n'
                printf '[3] Re-check target + passive source recovery only\n'
                printf '[4] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) leap16_require_sudo_session && validate_pending_target_runtime ;;
                    2) leap16_require_sudo_session && r26_finalize_adapter_transaction ;;
                    3)
                        leap16_require_sudo_session || return 1
                        run_validation preflight && pending_validate_running_kernel && pending_validate_runtime_cmdline_against_source && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep && leap16_r68_verify_source_recovery_while_refind_active
                        ;;
                    4|'') return 0 ;;
                    *) printf 'Invalid selection.\n'; return 1 ;;
                esac
                return $?
                ;;
            candidate-ready)
                fail "rEFInd Boot$target is the recorded target, but the transaction is only candidate-ready; a manually entered target session is not accepted as runtime proof"
                return 1
                ;;
            *)
                fail "Unsupported inbound-rEFInd pending phase: $PENDING_PHASE"
                return 1
                ;;
        esac
    fi

    # Exact recorded source session.  Preserve generic adapter lifecycle for
    # parking, one-shot arming, safe reset after a failed/consumed test, and
    # rollback.  Runtime proof can never be manufactured from the source boot.
    if [[ $BOOTLOADER == "$PENDING_SOURCE" && ${BOOT_CURRENT^^} == "$source" ]]; then
        case "$PENDING_PHASE" in
            candidate-ready)
                printf '\n%s source Boot%s is active and rEFInd target Boot%s is parked.\n' "$(bootloader_display_name "$PENDING_SOURCE")" "$source" "$target"
                printf '[1] Revalidate source + rEFInd candidate\n'
                printf '[2] Arm one-time rEFInd test + automatic resume\n'
                printf '[3] Roll back the staged rEFInd candidate\n'
                printf '[4] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) leap16_require_sudo_session && run_validation preflight && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep ;;
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
                    printf '\nOne-time rEFInd BootNext=Boot%s is armed and waiting for reboot.\n' "$target"
                    printf '[1] Re-check source/candidate integrity and leave BootNext armed\n'
                    printf '[2] Cancel this exact BootNext and return to candidate-ready\n'
                    printf '[3] Roll back the staged rEFInd candidate\n'
                    printf '[4] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in
                        1) leap16_require_sudo_session && run_validation preflight && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep ;;
                        2) cancel_pending_one_time_boot ;;
                        3) rollback_pending_candidate ;;
                        4|'') return 0 ;;
                        *) printf 'Invalid selection.\n'; return 1 ;;
                    esac
                    return $?
                elif [[ -z $next ]]; then
                    printf '\nThe rEFInd one-shot was consumed/cleared and the recorded source booted again.\n'
                    printf 'No rEFInd runtime proof can be recorded from this source session.\n'
                    printf '[1] Revalidate and return to candidate-ready\n'
                    printf '[2] Roll back the staged rEFInd candidate\n'
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
                printf '\nrEFInd runtime proof is already persisted, but the recorded source Boot%s is active again.\n' "$source"
                printf 'Finalization is forbidden from the source session.\n'
                printf '[1] Re-arm the already-proven rEFInd target for continuation\n'
                printf '[2] Re-check source + target ownership\n'
                printf '[3] Roll back/abandon the rEFInd candidate\n'
                printf '[4] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) leap16_require_sudo_session && r26_rearm_runtime_validated_target ;;
                    2) leap16_require_sudo_session && run_validation preflight && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep ;;
                    3) rollback_pending_candidate ;;
                    4|'') return 0 ;;
                    *) printf 'Invalid selection.\n'; return 1 ;;
                esac
                return $?
                ;;
        esac
    fi

    fail "Active session matches neither recorded $(bootloader_display_name "$PENDING_SOURCE") source Boot$source nor rEFInd target Boot$target; no transaction writes were attempted"
    return 1
}

# r64 only intercepted rEFInd -> Limine; inbound * -> rEFInd was delegated into
# the historical Limine-centric manager.  Intercept the complete inbound-rEFInd
# family after all earlier manager overlays have loaded and delegate everything
# else byte-for-byte.
if declare -F manage_pending_migration >/dev/null 2>&1; then
    eval "$(declare -f manage_pending_migration | sed '1s/manage_pending_migration/manage_pending_migration_pre_leap16_r69/')"
fi
manage_pending_migration() {
    pending_exists || { printf '\nNo pending/staged migration exists.\n'; return 0; }
    validate_pending_compatibility || { printf '\nPending migration state is invalid/incompatible: %s\n' "$PENDING_REASON"; return 1; }
    if leap16_r68_refind_target_pending; then
        leap16_r69_inbound_refind_pending_menu
    else
        manage_pending_migration_pre_leap16_r69 "$@"
    fi
}

# The r67 root-resume failure wrote a generic "target failed runtime proof"
# result even though hardware reached canonical rEFInd userspace and the actual
# failure was stale Limine dispatch.  While that exact inbound-rEFInd transaction
# remains pending, render the historical result accurately instead of implying
# that rEFInd itself failed runtime proof.
if declare -F r22_show_last_auto_result >/dev/null 2>&1; then
    eval "$(declare -f r22_show_last_auto_result | sed '1s/r22_show_last_auto_result/r22_show_last_auto_result_pre_leap16_r69/')"
fi
r22_show_last_auto_result() {
    local f="$PENDING_STATE_DIR/${R22_RESULT_FILE_NAME:-last-auto-result.txt}" detail=''
    if pending_exists && validate_pending_compatibility >/dev/null 2>&1 && leap16_r68_refind_target_pending && [[ -f $f ]]; then
        detail=$(sed -n 's/^detail=//p' "$f" 2>/dev/null | head -n1 || true)
        if [[ $detail == *'automatically booted refind target failed runtime proof'* || $detail == *'automatically booted rEFInd target failed runtime proof'* ]]; then
            printf 'Last transaction result:\n'
            printf '  [NOTE] Historical r67 resume-dispatch failure after canonical rEFInd reached Leap userspace; source cleanup was not attempted.\n\n'
            return 0
        fi
    fi
    r22_show_last_auto_result_pre_leap16_r69 "$@"
}

if declare -F leap16_r64_print_matrix >/dev/null 2>&1; then
    eval "$(declare -f leap16_r64_print_matrix | sed '1s/leap16_r64_print_matrix/leap16_r64_print_matrix_pre_leap16_r69/')"
fi
leap16_r64_print_matrix() {
    leap16_r64_print_matrix_pre_leap16_r69 "$@" | sed '1s/leap16-r68/leap16-r69/'
    cat <<'TXT'

r69 hardware note:
  r68 selector [2] on the still-running canonical rEFInd Boot0005 session SAFE-FAILED in the historical GRUB2 -> Limine pending manager.
  No runtime proof/source cleanup was attempted. r69 routes inbound * -> rEFInd pending state to a direction-correct manager and preserves the existing r68 proof/finalizer contracts.
TXT
}
