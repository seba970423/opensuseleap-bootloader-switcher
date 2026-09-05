#!/usr/bin/env bash
# openSUSE Leap 16 r22
#
# r22 fixes a phase-order contradiction exposed by real hardware diagnostics:
# after primary Limine promotion, r21 intentionally writes target-first order,
# then an inherited recorded-source validator still demanded the old source-first
# candidate order.  The source bytes/ownership were unchanged; only the expected
# firmware-order phase was wrong.  r22 makes the recovery proof phase-aware and
# provides an interactive continuation for transactions stranded at the safe
# primary-promoted checkpoint.

# Preserve the r21/current behavior for every state except a runtime-validated
# GRUB2 -> Limine transaction that is already in the promoted Limine topology.
eval "$(declare -f verify_pending_source_recovery_unchanged | sed '1s/verify_pending_source_recovery_unchanged/verify_pending_source_recovery_unchanged_pre_r22/')"
verify_pending_source_recovery_unchanged() {
    if [[ ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == grub:limine \
          && ${BOOTLOADER:-} == limine \
          && ${PENDING_PHASE:-} == runtime-validated ]] \
       && leap16_assess_promoted_firmware_order >/dev/null 2>&1; then
        leap16_verify_grub_recovery_after_promotion
        return $?
    fi
    verify_pending_source_recovery_unchanged_pre_r22 "$@"
}

r22_continue_promoted_forward() {
    local fallback_id
    validate_pending_compatibility || { fail "Pending migration is incompatible: $PENDING_REASON"; return 1; }
    r21_forward_pending || { fail 'Promoted-state continuation is valid only for GRUB2 -> Limine'; return 1; }
    [[ ${PENDING_PHASE:-} == runtime-validated ]] || { fail 'Promoted-state continuation requires persisted primary runtime proof'; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || {
        fail "Promoted-state continuation must run from primary Limine Boot$PENDING_TARGET_BOOT_ID"
        return 1
    }
    [[ -z $(pending_bootnext_id 2>/dev/null || true) ]] || { fail 'BootNext must be clear before promoted-state recovery'; return 1; }
    leap16_require_sudo_session || return 1
    run_validation preflight || return 1
    pending_validate_running_kernel || return 1
    pending_validate_runtime_cmdline_against_source || return 1
    leap16_validate_promoted_firmware_order 'r22 promoted-state recovery' || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1
    leap16_verify_grub_recovery_after_promotion || return 1

    printf '\nr22 recovered the safe primary-promoted checkpoint. No fallback ownership transfer has happened yet.\n'
    printf 'Staging the genuine Limine EFI fallback now; native GRUB2 remains intact until the second runtime proof.\n'
    r21_stage_fallback_test || return 1
    fallback_id=$(r21_meta_value fallback_boot_id 2>/dev/null || true); fallback_id=${fallback_id^^}
    if ! r22_prepare_resume_bundle; then
        fail 'Could not prepare the second-boot root resume bundle; restoring the pre-fallback primary-Limine + shim-recovery topology'
        r21_restore_pre_fallback_state "$fallback_id" || true
        return 1
    fi
    ok "Recovered transaction continuation: fallback Boot$fallback_id is armed and the root-owned resume service is installed"
    printf '\nThe next normal reboot is the exact Limine EFI fallback proof.\n'
    printf 'GRUB2 retirement remains forbidden unless that BootCurrent/path/bytes/kernel/root/cmdline proof succeeds.\n'
    r13_prompt_reboot
}

# Intercept exactly the state produced by the r21 bug. All other pending UX is
# delegated to the already-existing r21 manager.
eval "$(declare -f manage_pending_migration | sed '1s/manage_pending_migration/manage_pending_migration_pre_r22/')"
manage_pending_migration() {
    pending_exists || { printf '\nNo pending/staged migration exists.\n'; return 0; }
    validate_pending_compatibility || { printf '\nPending migration state is invalid/incompatible: %s\n' "$PENDING_REASON"; return 1; }

    if r21_forward_pending && ! r21_fallback_meta_exists; then
        detect_bootloader
        if [[ ${PENDING_PHASE:-} == runtime-validated \
              && $BOOTLOADER == limine \
              && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] \
           && leap16_assess_promoted_firmware_order >/dev/null 2>&1; then
            local choice
            show_pending_details
            printf '\nPrimary Limine is already runtime-proven and persistently promoted.\n'
            printf 'r21 stopped here because an inherited validator incorrectly demanded the old source-first BootOrder.\n'
            printf 'Native GRUB2 and the original shim fallback are still intact.\n\n'
            printf '[1] Continue with genuine Limine fallback staging/proof\n'
            printf '[2] Re-check the safe promoted checkpoint\n'
            printf '[3] Capture diagnostics\n'
            printf '[4] Back\n\n'
            read -r -p 'Select an option: ' choice
            case "$choice" in
                1) r22_continue_promoted_forward ;;
                2) leap16_require_sudo_session && run_validation preflight && leap16_validate_promoted_firmware_order 'r22 promoted-state re-check' && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep && leap16_verify_grub_recovery_after_promotion ;;
                3) leap16_stage_diagnostic r22-promoted-checkpoint ;;
                4|'') return 0 ;;
                *) return 1 ;;
            esac
            return $?
        fi
    fi

    manage_pending_migration_pre_r22 "$@"
}

# r13_prompt_reboot is a historical function name only; the user-facing text
# must describe the current two-proof transaction rather than the old r13 end state.
r13_prompt_reboot() {
    local answer
    printf '\nThe one-shot boot test and root-owned automatic resume service are armed.\n'
    if r21_fallback_meta_exists 2>/dev/null; then
        printf 'The next boot targets the explicit Limine EFI fallback. Native GRUB2 remains intact until that exact fallback proof succeeds.\n'
    else
        printf 'The next boot targets canonical Limine. After its proof, the transaction will stage and test the genuine Limine EFI fallback before any GRUB2 retirement.\n'
    fi
    read -r -p 'Reboot now? [y/N]: ' answer
    case "$answer" in
        y|Y|yes|YES)
            printf 'Rebooting now. No firmware-menu selection is required.\n'
            sudo systemctl reboot
            ;;
        *)
            printf 'Reboot deferred. BootNext and the temporary resume service remain armed for the next normal reboot.\n'
            ;;
    esac
}
