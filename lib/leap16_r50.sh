#!/usr/bin/env bash
# leap16-r50: direct Limine -> systemd-boot pending-manager routing.
#
# r49 fixed the phase-aware finalization verifier, but selector [2] still fell
# through the historical GRUB2 -> Limine manager.  That old manager hard-codes
# "recorded GRUB2 source / Limine target" and therefore rejected the exact
# runtime-proven systemd-boot session before r49's repaired finalizer could be
# reached.  r50 intercepts only the r48 direct-edge pending format and exposes
# source/target-correct recovery actions.  All other pending directions are
# delegated unchanged.

leap16_r50_rearm_limine_to_systemd() {
    local next
    leap16_r48_pending || return 1
    detect_bootloader
    [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == ${PENDING_OLD_BOOT_ID^^} ]] || {
        fail "Re-arm requires recorded Limine source Boot${PENDING_OLD_BOOT_ID^^}"
        return 1
    }
    leap16_require_sudo_session || return 1
    run_validation preflight || return 1
    verify_pending_source_recovery_unchanged || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1
    next=$(pending_bootnext_id)
    [[ -z $next ]] || { fail "BootNext is already set to Boot$next"; return 1; }
    pending_set_phase candidate-ready || return 1
    PENDING_PHASE=candidate-ready
    r23_arm_candidate_automatically || return 1
    if ! r22_prepare_resume_bundle; then
        fail 'Could not prepare automatic post-reboot continuation. Clearing transaction BootNext for safety.'
        r22_rollback_automation_arm
        return 1
    fi
    r23_prompt_reboot
}

leap16_r50_limine_systemd_pending_menu() {
    local source target fallback choice next order first
    source=${PENDING_OLD_BOOT_ID^^}
    target=${PENDING_TARGET_BOOT_ID^^}
    fallback=$(leap16_r48_fallback_id 2>/dev/null || true)

    detect_bootloader
    show_pending_details

    if [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == "$target" ]]; then
        case "$PENDING_PHASE" in
            boot-armed)
                printf '\nThe exact systemd-boot one-shot target is active; Limine recovery is still authoritative.\n'
                printf '[1] Run exact runtime validation\n'
                printf '[2] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) leap16_r48_validate_systemd_runtime ;;
                    2|'') return 0 ;;
                    *) printf 'Invalid selection.\n'; return 1 ;;
                esac
                ;;
            runtime-validated)
                order=$(leap16_current_boot_order 2>/dev/null || true)
                first=${order%%,*}; first=${first^^}
                if [[ $first == "$target" ]]; then
                    printf '\nThe systemd-boot target is runtime-proven and already persistently promoted.\n'
                    printf 'Limine primary Boot%s + fallback Boot%s are still intact because the previous finalizer failed closed before retirement.\n' "$source" "${fallback:-unknown}"
                    printf '[1] Continue ownership-gated finalization from this promoted checkpoint\n'
                    printf '[2] Re-check the promoted target + intact Limine recovery checkpoint\n'
                    printf '[3] Capture diagnostics\n'
                    printf '[4] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in
                        1) leap16_require_sudo_session && r26_finalize_adapter_transaction ;;
                        2) leap16_require_sudo_session && run_validation preflight && pending_validate_running_kernel && pending_validate_runtime_cmdline_against_source && verify_pending_candidate_ownership_unchanged && leap16_r34_validate_systemd_boot_chain runtime && verify_pending_source_recovery_unchanged ;;
                        3) leap16_capture_diagnostics r50-promoted-limine-systemd-checkpoint ;;
                        4|'') return 0 ;;
                        *) printf 'Invalid selection.\n'; return 1 ;;
                    esac
                elif [[ $first == "$source" ]]; then
                    printf '\nThe systemd-boot target is runtime-proven; Limine primary/fallback remain persistent recovery.\n'
                    printf '[1] FINALIZE now: promote systemd-boot, transfer fallback, retire exact Limine-owned state\n'
                    printf '[2] Re-run exact runtime validation\n'
                    printf '[3] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in
                        1) leap16_require_sudo_session && r26_finalize_adapter_transaction ;;
                        2) leap16_r48_validate_systemd_runtime ;;
                        3|'') return 0 ;;
                        *) printf 'Invalid selection.\n'; return 1 ;;
                    esac
                else
                    fail "Runtime-proven transaction has an unexpected persistent BootOrder ($order); no writes were attempted"
                    return 1
                fi
                ;;
            candidate-ready)
                fail 'systemd-boot is active while the transaction is only candidate-ready; runtime proof is not authorized from this inconsistent phase'
                return 1
                ;;
            *)
                fail "Unsupported Limine -> systemd-boot pending phase: $PENDING_PHASE"
                return 1
                ;;
        esac
        return $?
    fi

    if [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == "$source" ]]; then
        case "$PENDING_PHASE" in
            candidate-ready)
                printf '\nLimine source is active and the systemd-boot candidate is parked.\n'
                printf '[1] Revalidate exact source + candidate ownership\n'
                printf '[2] Arm one-time systemd-boot test + automatic resume\n'
                printf '[3] Roll back this exact systemd-boot candidate\n'
                printf '[4] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) leap16_require_sudo_session && run_validation preflight && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep ;;
                    2) leap16_require_sudo_session && r23_arm_candidate_automatically && r22_prepare_resume_bundle && r23_prompt_reboot ;;
                    3) rollback_pending_candidate ;;
                    4|'') return 0 ;;
                    *) printf 'Invalid selection.\n'; return 1 ;;
                esac
                ;;
            boot-armed)
                next=$(pending_bootnext_id)
                if [[ ${next^^} == "$target" ]]; then
                    printf '\nOne-time systemd-boot BootNext=Boot%s is armed; Limine remains persistent first.\n' "$target"
                    printf '[1] Re-check source/candidate integrity and leave BootNext armed\n'
                    printf '[2] Cancel transaction BootNext and return to candidate-ready\n'
                    printf '[3] Roll back this exact candidate\n'
                    printf '[4] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in
                        1) leap16_require_sudo_session && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep ;;
                        2) sudo efibootmgr -N >/dev/null && pending_set_phase candidate-ready && r22_disarm_user_resume_bundle ;;
                        3) rollback_pending_candidate ;;
                        4|'') return 0 ;;
                        *) printf 'Invalid selection.\n'; return 1 ;;
                    esac
                elif [[ -z $next ]]; then
                    printf '\nThe one-shot was consumed/cleared and Limine is active; no systemd-boot runtime proof was accepted.\n'
                    printf '[1] Return transaction to candidate-ready\n'
                    printf '[2] Roll back this exact candidate\n'
                    printf '[3] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in
                        1) pending_set_phase candidate-ready; r22_disarm_user_resume_bundle ;;
                        2) rollback_pending_candidate ;;
                        3|'') return 0 ;;
                        *) printf 'Invalid selection.\n'; return 1 ;;
                    esac
                else
                    fail "BootNext belongs to unrelated Boot$next; the transaction will not touch it"
                    return 1
                fi
                ;;
            runtime-validated)
                printf '\nsystemd-boot runtime proof exists, but Limine is active again. Finalization is forbidden from the source session.\n'
                printf '[1] Re-arm the exact systemd-boot target for a fresh target session + automatic resume\n'
                printf '[2] Re-check source + target ownership only\n'
                printf '[3] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) leap16_r50_rearm_limine_to_systemd ;;
                    2) leap16_require_sudo_session && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep ;;
                    3|'') return 0 ;;
                    *) printf 'Invalid selection.\n'; return 1 ;;
                esac
                ;;
            *)
                fail "Unsupported Limine -> systemd-boot pending phase: $PENDING_PHASE"
                return 1
                ;;
        esac
        return $?
    fi

    fail "Active session matches neither recorded Limine source Boot$source nor systemd-boot target Boot$target; no transaction writes were attempted"
    return 1
}

eval "$(declare -f manage_pending_migration | sed '1s/manage_pending_migration/manage_pending_migration_pre_leap16_r50/')"
manage_pending_migration() {
    pending_exists || { printf '\nNo pending/staged migration exists.\n'; return 0; }
    validate_pending_compatibility || { printf '\nPending migration state is invalid/incompatible: %s\n' "$PENDING_REASON"; return 1; }
    if leap16_r48_pending; then
        leap16_r50_limine_systemd_pending_menu
    else
        manage_pending_migration_pre_leap16_r50 "$@"
    fi
}
