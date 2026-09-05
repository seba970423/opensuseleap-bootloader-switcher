#!/usr/bin/env bash
# leap16-r57: make the systemd-boot -> Limine pre-transfer fallback model
# identity-based instead of Boot####-set based, and make a consumed first
# one-shot retryable from the still-authoritative systemd-boot source session.
#
# Hardware contract:
#   * Boot#### is an ephemeral firmware handle on this ASUS board.
#   * Before EFI/BOOT ownership transfer, identity is the current transaction
#     ESP + exact \\EFI\\BOOT\\BOOTX64.EFI path + exact systemd-boot payload.
#   * Zero or one exact active same-ESP alias is acceptable at each check.
#   * The complete pre-stage firmware table remains diagnostic/provenance data;
#     it is NOT a frozen-ID runtime invariant.
#   * After the primary BootNext is consumed and firmware returns to persistent
#     systemd-boot, the exact already-staged Limine candidate can be re-armed
#     without restaging or manual efibootmgr commands.

leap16_r57_current_pretransfer_fallback_id() {
    local id hash
    local -a ids=()

    hash=$(r21_hash_privileged "$PENDING_OLD_FALLBACK_PATH" 2>/dev/null || true)
    [[ -n $hash && $hash == "$PENDING_OLD_FALLBACK_HASH" ]] || {
        fail 'Pre-transfer EFI/BOOT bytes no longer match the frozen systemd-boot recovery payload'
        return 1
    }

    mapfile -t ids < <(leap16_r53_current_fallback_ids)
    ((${#ids[@]} <= 1)) || {
        fail "Generic-fallback NVRAM identity is ambiguous before ownership transfer (${#ids[@]} exact same-ESP aliases)"
        return 1
    }
    if ((${#ids[@]} == 0)); then
        printf '\n'
        return 0
    fi

    id=${ids[0]^^}
    leap16_r56_validate_current_fallback_alias "$id" || return 1
    printf '%s\n' "$id"
}

# Replace r53/r56's baseline-set comparison with fresh identity resolution.
# The function name is kept because older transaction code already calls it.
leap16_r53_verify_pretransfer_fallback_alias_set() {
    local id
    id=$(leap16_r57_current_pretransfer_fallback_id) || return 1
    if [[ -n $id ]]; then
        ok "Current pre-transfer EFI/BOOT identity is valid at Boot$id; Boot#### provenance is not treated as immutable firmware state"
    else
        ok 'Current pre-transfer EFI/BOOT identity is valid with no explicit NVRAM alias; Boot#### provenance is not treated as immutable firmware state'
    fi
}

# r53 special-cased a frozen baseline Boot#### during adoption. For this board,
# resolve whatever exact fallback alias exists AFTER the Limine payload transfer
# and adopt that current identity. If no alias exists, fall back to the original
# r21 create-only implementation, then validate the newly returned identity.
eval "$(declare -f r21_create_or_adopt_fallback_alias | sed '1s/r21_create_or_adopt_fallback_alias/r21_create_or_adopt_fallback_alias_pre_leap16_r57/')"
r21_create_or_adopt_fallback_alias() {
    local id
    local -a ids=()
    if ! leap16_r51_pending || leap16_r51_fallback_staged; then
        r21_create_or_adopt_fallback_alias_pre_leap16_r57 "$@"
        return $?
    fi

    mapfile -t ids < <(leap16_r53_current_fallback_ids)
    ((${#ids[@]} <= 1)) || {
        fail "Fallback NVRAM identity is ambiguous after Limine payload installation (${#ids[@]} exact same-ESP aliases)"
        return 1
    }
    if ((${#ids[@]} == 1)); then
        id=${ids[0]^^}
        leap16_r56_validate_current_fallback_alias "$id" || return 1
        [[ $(r21_hash_privileged "$PENDING_OLD_FALLBACK_PATH") == "$PENDING_TARGET_EFI_HASH" ]] || {
            fail 'Current EFI/BOOT alias points at a payload that is not byte-identical to canonical Limine'
            return 1
        }
        ok "Adopting current exact Limine EFI/BOOT identity at Boot$id; no frozen Boot#### ID is required" >&2
        printf '%s\n' "$id"
        return 0
    fi

    # Bypass r53's baseline-ID wrapper and use the original r21 create/adopt
    # primitive. At this point there is no current alias, so it will create one.
    id=$(r21_create_or_adopt_fallback_alias_pre_leap16_r53) || return 1
    id=${id^^}
    leap16_r56_validate_current_fallback_alias "$id" || return 1
    printf '%s\n' "$id"
}

# Rollback restores the original systemd-boot EFI/BOOT bytes. Do not delete or
# preserve aliases based on their historical Boot#### membership: once the
# payload is restored, every exact same-ESP EFI/BOOT alias is merely a firmware
# handle for the recovered systemd fallback. Keep them and let later finalized
# topology normalization deal with firmware churn.
eval "$(declare -f r21_remove_staging_fallback_aliases | sed '1s/r21_remove_staging_fallback_aliases/r21_remove_staging_fallback_aliases_pre_leap16_r57/')"
r21_remove_staging_fallback_aliases() {
    local id failures=0 count=0
    if ! leap16_r51_pending; then
        r21_remove_staging_fallback_aliases_pre_leap16_r57 "$@"
        return $?
    fi
    while IFS= read -r id; do
        [[ $id =~ ^[0-9A-Fa-f]{4}$ ]] || continue
        id=${id^^}; count=$((count + 1))
        leap16_boot_entry_is_active "$id" || { fail "Rollback saw inactive EFI/BOOT alias Boot$id"; failures=$((failures + 1)); continue; }
        leap16_nvram_entry_matches_current_esp "$id" || { fail "Rollback EFI/BOOT alias Boot$id is not bound to the transaction ESP"; failures=$((failures + 1)); continue; }
        nvram_id_matches_path "$id" "$LEAP16_R21_FALLBACK_EFI_PATH" || { fail "Rollback EFI/BOOT alias Boot$id changed path"; failures=$((failures + 1)); continue; }
    done < <(leap16_r53_current_fallback_ids)
    ((failures == 0)) || return 1
    if ((count > 0)); then
        ok "Preserving $count current exact EFI/BOOT firmware alias(es) during rollback; Boot#### IDs are not used as ownership"
    fi
    return 0
}

# r51's source-session boot-armed menu assumed that if BootNext was gone there
# was nothing useful to do. But BootNext is one-shot: after a failed/manual
# first proof and another reboot, persistent systemd-boot naturally returns and
# the already-staged Limine candidate must be re-armable.
eval "$(declare -f leap16_r51_pending_menu | sed '1s/leap16_r51_pending_menu/leap16_r51_pending_menu_pre_leap16_r57/')"
leap16_r51_pending_menu() {
    local source target next choice
    if leap16_r51_pending && ! leap16_r51_fallback_staged && [[ $PENDING_PHASE == boot-armed ]]; then
        source=${PENDING_OLD_BOOT_ID^^}
        target=${PENDING_TARGET_BOOT_ID^^}
        detect_bootloader
        next=$(pending_bootnext_id 2>/dev/null || true)
        if [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == "$source" && -z $next ]]; then
            show_pending_details
            printf '\nThe first Limine one-shot was already consumed, and persistent systemd-boot is active again.\n'
            printf 'No Limine runtime proof is accepted from this source session, but the exact staged candidate can be re-armed safely.\n'
            printf '[1] Re-arm the exact canonical Limine one-shot + automatic resume\n'
            printf '[2] Re-check systemd-boot recovery + staged Limine candidate\n'
            printf '[3] Roll back this unproven Limine candidate\n'
            printf '[4] Back\n\n'
            read -r -p 'Select an option: ' choice
            case "$choice" in
                1) leap16_r51_rearm_primary ;;
                2) leap16_require_sudo_session && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep ;;
                3) leap16_r51_rollback_candidate ;;
                4|'') return 0 ;;
                *) printf 'Invalid selection.\n'; return 1 ;;
            esac
            return $?
        fi
    fi
    leap16_r51_pending_menu_pre_leap16_r57 "$@"
}

# Add the corrected invariant to the printed plan without changing transaction
# mutations.
eval "$(declare -f leap16_r51_plan | sed '1s/leap16_r51_plan/leap16_r51_plan_pre_leap16_r57/')"
leap16_r51_plan() {
    leap16_r51_plan_pre_leap16_r57 "$@"
    printf '  r57 note: EFI/BOOT NVRAM aliases are resolved fresh by current ESP + exact path + payload identity; pre-stage Boot#### IDs remain diagnostics, not a reboot-stability contract.\n'
}
