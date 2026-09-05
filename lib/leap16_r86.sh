#!/usr/bin/env bash
# leap16-r86: direction-correct pending manager for rEFInd -> systemd-boot.
#
# r85 repaired validate_pending_target_runtime() for this edge, which fixed the
# root-owned automatic resume path.  The interactive --manage-staged entry point
# is a separate overlay chain, however.  On the already-running systemd-boot
# target it still fell through to the historical GRUB2 -> Limine manager and
# rejected the valid session with:
#
#   Current bootloader is neither the recorded GRUB2 source nor Limine target
#
# r86 intercepts only format-v5 refind:systemd-boot pending state and routes it
# to the r85 runtime validator + unchanged r64 finalizer.  No staging, runtime
# proof, ownership, fallback-transfer, source-retirement, or restore semantics
# are weakened or duplicated here.

leap16_r86_refind_systemd_pending() {
    [[ ${PENDING_FORMAT:-} == "${R26_PENDING_FORMAT:-5}" \
       && ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == refind:systemd-boot ]]
}

leap16_r86_refind_systemd_pending_menu() {
    local choice next source target svc order first
    leap16_r86_refind_systemd_pending \
        || { fail 'r86 rEFInd -> systemd-boot pending menu received the wrong transaction direction'; return 1; }

    source=${PENDING_OLD_BOOT_ID^^}
    target=${PENDING_TARGET_BOOT_ID^^}
    detect_bootloader
    show_pending_details

    if [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == "$target" ]]; then
        case "$PENDING_PHASE" in
            boot-armed|runtime-validated)
                svc=$(r26_resume_service_state 2>/dev/null || printf 'not-found')
                if [[ $svc == active || $svc == activating ]]; then
                    printf '\nAutomatic rEFInd -> systemd-boot continuation is still running in the background.\n'
                    printf 'Service state: %s\n' "$svc"
                    printf 'Do not start a second validator/finalizer or reboot this session.\n'
                    return 0
                fi
                ;;
        esac

        case "$PENDING_PHASE" in
            boot-armed)
                next=$(pending_bootnext_id 2>/dev/null || true)
                [[ -z $next || ${next^^} == "$target" ]] || {
                    fail "BootNext belongs to unrelated Boot${next^^}; refusing runtime proof or firmware mutation"
                    return 1
                }
                printf '\nThe exact native openSUSE systemd-boot target Boot%s is running.\n' "$target"
                printf 'rEFInd Boot%s remains persistent-first recovery; no source retirement has occurred.\n' "$source"
                printf '[1] Run exact systemd-boot runtime validation now\n'
                printf '[2] Re-check systemd-boot target + passive rEFInd recovery only\n'
                printf '[3] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) leap16_require_sudo_session && validate_pending_target_runtime ;;
                    2)
                        leap16_require_sudo_session || return 1
                        run_validation preflight \
                            && verify_pending_candidate_ownership_unchanged \
                            && leap16_r34_validate_systemd_boot_chain runtime \
                            && leap16_r64_verify_refind_source_passive
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
                printf '\nThe exact native systemd-boot target Boot%s has persisted runtime proof.\n' "$target"
                printf '[1] Re-run exact systemd-boot runtime validation\n'
                printf '[2] Re-check every gate and FINALIZE now\n'
                printf '[3] Re-check systemd-boot target + passive rEFInd recovery only\n'
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
                            && leap16_r34_validate_systemd_boot_chain runtime \
                            && leap16_r64_verify_refind_source_passive
                        ;;
                    4|'') return 0 ;;
                    *) printf 'Invalid selection.\n'; return 1 ;;
                esac
                return $?
                ;;
            candidate-ready)
                fail "systemd-boot Boot$target is the recorded target, but the transaction was never armed; this manual target session cannot earn runtime proof"
                return 1
                ;;
            *)
                fail "Unsupported rEFInd -> systemd-boot target phase: ${PENDING_PHASE:-missing}"
                return 1
                ;;
        esac
    fi

    if [[ $BOOTLOADER == refind && ${BOOT_CURRENT^^} == "$source" ]]; then
        case "$PENDING_PHASE" in
            candidate-ready)
                printf '\nrEFInd source is active; native systemd-boot target is parked.\n'
                printf '[1] Revalidate source + target\n'
                printf '[2] Arm one-time systemd-boot test + automatic resume\n'
                printf '[3] Roll back staged target\n'
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
                    printf '\nOne-time systemd-boot BootNext=Boot%s is armed; rEFInd remains persistent first.\n' "$target"
                    printf '[1] Re-check source + target integrity\n'
                    printf '[2] Cancel BootNext and return to candidate-ready\n'
                    printf '[3] Roll back staged target\n'
                    printf '[4] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in
                        1) leap16_require_sudo_session && run_validation preflight && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged ;;
                        2) cancel_pending_one_time_boot ;;
                        3) rollback_pending_candidate ;;
                        4|'') return 0 ;;
                        *) printf 'Invalid selection.\n'; return 1 ;;
                    esac
                    return $?
                elif [[ -z $next ]]; then
                    printf '\nBootNext was consumed/cleared without accepted systemd-boot runtime proof and rEFInd is active again.\n'
                    printf '[1] Revalidate and return to candidate-ready\n'
                    printf '[2] Roll back staged target\n'
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
                fail "BootNext belongs to unrelated Boot${next^^}; refusing transaction mutation"
                return 1
                ;;
            runtime-validated)
                printf '\nsystemd-boot runtime proof is already recorded, but rEFInd source is active again.\n'
                printf '[1] Re-arm proven systemd-boot target + automatic finalization\n'
                printf '[2] Re-check source + target ownership\n'
                printf '[3] Roll back/abandon target\n'
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
            *)
                fail "Unsupported rEFInd -> systemd-boot source phase: ${PENDING_PHASE:-missing}"
                return 1
                ;;
        esac
    fi

    fail "Active session matches neither recorded rEFInd source Boot$source nor native systemd-boot target Boot$target; no transaction writes were attempted"
    return 1
}

# r85 repaired the runtime call used by automatic resume, but --manage-staged
# enters through a separate manager symbol.  Intercept the same one direction
# here and delegate every other already-proven path unchanged.
if declare -F manage_pending_migration >/dev/null 2>&1; then
    eval "$(declare -f manage_pending_migration | sed '1s/manage_pending_migration/manage_pending_migration_pre_leap16_r86/')"
fi
manage_pending_migration() {
    pending_exists || { printf '\nNo pending/staged migration exists.\n'; return 0; }
    load_pending_state \
        || { printf '\nPending migration state is invalid: %s\n' "${PENDING_REASON:-unknown reason}"; return 1; }
    validate_pending_compatibility \
        || { printf '\nPending migration state is invalid/incompatible: %s\n' "${PENDING_REASON:-unknown reason}"; return 1; }
    if leap16_r86_refind_systemd_pending; then
        leap16_r86_refind_systemd_pending_menu
    else
        manage_pending_migration_pre_leap16_r86 "$@"
    fi
}

# User-facing matrix ledger.  The Sep 6 hardware campaign completed the
# remaining systemd-boot <-> rEFInd live and restore directions, so r86 now
# reports the full 24/24 hardware-proven cross-loader milestone.
if declare -F leap16_r64_print_matrix >/dev/null 2>&1; then
    eval "$(declare -f leap16_r64_print_matrix | sed '1s/leap16_r64_print_matrix/leap16_r64_print_matrix_pre_leap16_r86/')"
fi
leap16_r64_print_matrix() {
    cat <<'MATRIX'
openSUSE Leap 16 bootloader matrix — leap16-r86

Legend:
  HW-PROVEN       completed on real hardware through required proof/finalization boundaries
  —               same-backend; not a cross-loader edge

LIVE SWITCH MATRIX (source rows -> target columns)
                 GRUB2        Limine       systemd-boot  rEFInd
  GRUB2          —            HW-PROVEN    HW-PROVEN     HW-PROVEN
  Limine         HW-PROVEN    —            HW-PROVEN     HW-PROVEN
  systemd-boot   HW-PROVEN    HW-PROVEN    —             HW-PROVEN
  rEFInd         HW-PROVEN    HW-PROVEN    HW-PROVEN     —

CROSS-LOADER RESTORE MATRIX (active source -> restored backup target)
                 GRUB2        Limine       systemd-boot  rEFInd
  GRUB2          —            HW-PROVEN    HW-PROVEN     HW-PROVEN
  Limine         HW-PROVEN    —            HW-PROVEN     HW-PROVEN
  systemd-boot   HW-PROVEN    HW-PROVEN    —             HW-PROVEN
  rEFInd         HW-PROVEN    HW-PROVEN    HW-PROVEN     —

BACKUP BACKENDS
  GRUB2          HW-PROVEN
  Limine         HW-PROVEN
  systemd-boot   HW-PROVEN
  rEFInd         HW-PROVEN

MILESTONE
  12/12 directed live-switch workflows HW-PROVEN
  12/12 directed cross-loader restore workflows HW-PROVEN
  24/24 total directed live/restore workflows HW-PROVEN

TARGET PROOF CONTRACTS
  GRUB2          native shim runtime proof -> owned EFI/BOOT topology -> direct-GRUB recovery
  Limine         canonical runtime proof -> independent byte-identical EFI/BOOT BootCurrent proof -> source retirement
  systemd-boot   canonical runtime/BLS proof -> byte-identical EFI/BOOT topology -> source retirement
  rEFInd         canonical runtime + fresh PreviousBoot direct-kernel proof -> source retirement; no EFI/BOOT ownership

Hardware status reflects the project test machine as of 2026-09-06; it is not a universal firmware guarantee.
MATRIX
}
