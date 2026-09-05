#!/usr/bin/env bash
# leap16-r40: direction-correct pending UX for the systemd-boot -> GRUB2
# hardware-test edge.
#
# r39 fixed the root automatic-resume dispatcher and reverse runtime verifier,
# but the interactive pending menu was still inherited from the historical
# GRUB2 -> Limine implementation.  Consequently a real, correct GRUB target
# session (BootCurrent == target shim) was rejected because the stale menu
# demanded BootCurrent == the recorded *source* systemd-boot ID.
#
# This overlay changes no staging, runtime proof, finalization, rollback, GRUB2
# <-> Limine, or GRUB2 -> systemd-boot logic.  It only routes the already-proven
# reverse transaction to the generic adapter semantics that match its source
# and target identities.

leap16_r40_reverse_pending_menu() {
    local choice next source target
    source=${PENDING_OLD_BOOT_ID^^}
    target=${PENDING_TARGET_BOOT_ID^^}
    detect_bootloader
    show_pending_details

    # Exact running GRUB target session.  This is the state reached by the real
    # r38/r39 one-shot hardware boot and is where runtime proof/finalization
    # must execute.
    if [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == "$target" ]]; then
        case "$PENDING_PHASE" in
            boot-armed)
                next=$(pending_bootnext_id)
                [[ -z $next ]] || {
                    fail "GRUB2 target is BootCurrent but BootNext is still set to Boot${next}; refusing runtime proof"
                    return 1
                }
                printf '\nThe exact GRUB2 one-shot target is running.\n'
                printf 'systemd-boot Boot%s remains the persistent source until GRUB2 earns runtime proof.\n' "$source"
                printf '[1] Run exact runtime validation now\n[2] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) leap16_r39_validate_grub_runtime ;;
                    2|'') return 0 ;;
                    *) printf 'Invalid selection.\n'; return 1 ;;
                esac
                return $?
                ;;
            runtime-validated)
                printf '\nThis exact GRUB2 target session has runtime proof.\n'
                printf '[1] Re-run exact runtime validation\n'
                printf '[2] Finalize GRUB2 and retire exact systemd-boot source\n'
                printf '[3] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) leap16_r39_validate_grub_runtime ;;
                    2) r26_finalize_adapter_transaction ;;
                    3|'') return 0 ;;
                    *) printf 'Invalid selection.\n'; return 1 ;;
                esac
                return $?
                ;;
            candidate-ready)
                fail 'GRUB2 is the target, but this transaction is only candidate-ready; a manually entered target session is not accepted as runtime proof'
                return 1
                ;;
        esac
    fi

    # Exact systemd-boot source session.  Preserve the generic adapter recovery
    # semantics: park/re-arm/rollback while the source remains authoritative.
    if [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == "$source" ]]; then
        case "$PENDING_PHASE" in
            candidate-ready)
                printf '\nsystemd-boot source is active and the native GRUB2 target is parked.\n'
                printf '[1] Re-run source + target validation\n'
                printf '[2] Arm one-time GRUB2 test + automatic resume\n'
                printf '[3] Roll back the staged GRUB2 target\n'
                printf '[4] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) run_validation preflight && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep ;;
                    2) r26_rearm_candidate_with_resume ;;
                    3) rollback_pending_candidate ;;
                    4|'') return 0 ;;
                    *) printf 'Invalid selection.\n'; return 1 ;;
                esac
                return $?
                ;;
            boot-armed)
                next=$(pending_bootnext_id)
                if [[ ${next^^} == "$target" ]]; then
                    printf '\nThe one-time GRUB2 BootNext is armed and waiting for reboot.\n'
                    printf '[1] Re-check source/target integrity\n'
                    printf '[2] Cancel BootNext and return to candidate-ready\n'
                    printf '[3] Roll back the staged GRUB2 target\n'
                    printf '[4] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in
                        1) run_validation preflight && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep ;;
                        2) cancel_pending_one_time_boot ;;
                        3) rollback_pending_candidate ;;
                        4|'') return 0 ;;
                        *) printf 'Invalid selection.\n'; return 1 ;;
                    esac
                    return $?
                elif [[ -z $next ]]; then
                    printf '\nThe GRUB2 one-shot was consumed/cleared and systemd-boot source is active again.\n'
                    printf 'No target runtime proof exists in this source session.\n'
                    printf '[1] Revalidate and return to candidate-ready\n'
                    printf '[2] Roll back the staged GRUB2 target\n'
                    printf '[3] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in
                        1) reset_consumed_test_to_candidate_ready ;;
                        2) rollback_pending_candidate ;;
                        3|'') return 0 ;;
                        *) printf 'Invalid selection.\n'; return 1 ;;
                    esac
                    return $?
                fi
                fail "BootNext belongs to unrelated Boot$next; the transaction will not touch it"
                return 1
                ;;
            runtime-validated)
                printf '\nGRUB2 runtime proof is recorded, but persistent source-first BootOrder returned to systemd-boot.\n'
                printf '[1] Re-arm the proven GRUB2 target + automatic finalization\n'
                printf '[2] Re-check source/target ownership\n'
                printf '[3] Roll back the staged GRUB2 target\n'
                printf '[4] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) r26_rearm_runtime_validated_target ;;
                    2) run_validation preflight && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep ;;
                    3) rollback_pending_candidate ;;
                    4|'') return 0 ;;
                    *) printf 'Invalid selection.\n'; return 1 ;;
                esac
                return $?
                ;;
        esac
    fi

    fail "Active session matches neither reverse source systemd-boot Boot$source nor target GRUB2 Boot$target; no transaction writes were attempted"
    return 1
}

eval "$(declare -f manage_pending_migration | sed '1s/manage_pending_migration/manage_pending_migration_pre_leap16_r40/')"
manage_pending_migration() {
    pending_exists || { printf '\nNo pending/staged migration exists.\n'; return 0; }
    validate_pending_compatibility || { printf '\nPending migration state is invalid/incompatible: %s\n' "$PENDING_REASON"; return 1; }
    if leap16_r38_pending; then
        leap16_r40_reverse_pending_menu
    else
        manage_pending_migration_pre_leap16_r40 "$@"
    fi
}

# Do not present the old Limine-dispatch failure as if it described the current
# reverse transaction.  The pending state remains authoritative; this is only a
# clearer historical-status rendering.
eval "$(declare -f r22_show_last_auto_result | sed '1s/r22_show_last_auto_result/r22_show_last_auto_result_pre_leap16_r40/')"
r22_show_last_auto_result() {
    local f="$PENDING_STATE_DIR/${R22_RESULT_FILE_NAME:-last-auto-result.txt}" detail=''
    if pending_exists && validate_pending_compatibility >/dev/null 2>&1 && leap16_r38_pending && [[ -f $f ]]; then
        detail=$(sed -n 's/^detail=//p' "$f" 2>/dev/null | head -n1 || true)
        if [[ $detail == 'Limine booted but automatic runtime proof failed; persistent promotion was NOT attempted.' ]]; then
            printf 'Last transaction result:\n'
            printf '  [NOTE] Historical r38 resume-dispatch failure; current systemd-boot -> GRUB2 pending state is authoritative.\n\n'
            return 0
        fi
    fi
    r22_show_last_auto_result_pre_leap16_r40 "$@"
}
