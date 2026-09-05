#!/usr/bin/env bash
# openSUSE Leap 16 r23
#
# r23 fixes the post-fallback GRUB retirement failure exposed on ASUS hardware:
# - r21_remove_source_grub_nvram_ids() inherited the false status of its final
#   "entry no longer exists" probe and could abort after successful deletion;
# - deleting the recorded Boot#### IDs before EFI/OPENSUSE was removed allowed
#   firmware to synthesize a new direct-GRUB alias (observed Boot0001 -> Boot0004);
# - fallback-proof recovery previously treated a later canonical-Limine boot as
#   proof failure even when the exact fallback had already been proven on the
#   previous root-owned resume attempt.
#
# r23 therefore treats ESP + EFI path as NVRAM ownership after fallback transfer,
# removes the owned openSUSE EFI namespace before the final alias sweep, repeats
# the sweep against fresh efibootmgr output, and can safely re-arm the exact
# fallback proof from a stranded primary-Limine session.

# Preserve the strict pre-transfer implementation.  Before fallback ownership
# transfer, the exact baseline Boot#### set is still a useful anti-drift gate.
eval "$(declare -f r21_verify_source_grub_nvram_ids | sed '1s/r21_verify_source_grub_nvram_ids/r21_verify_source_grub_nvram_ids_pre_r23/')"

r23_current_native_grub_ids_csv() {
    r21_current_native_grub_ids | awk 'NF{print toupper($0)}' | LC_ALL=C sort -u | paste -sd, -
}

r23_verify_current_native_grub_aliases() {
    local id csv count=0
    csv=$(r23_current_native_grub_ids_csv)
    if [[ -z $csv ]]; then
        ok 'No native openSUSE GRUB2 NVRAM alias is currently present; filesystem recovery ownership remains the authoritative retirement gate'
        return 0
    fi
    IFS=',' read -ra ids <<<"$csv"
    for id in "${ids[@]}"; do
        id=${id^^}
        leap16_boot_entry_is_active "$id" || { fail "Current native GRUB2 alias Boot$id is not active"; return 1; }
        leap16_nvram_entry_matches_current_esp "$id" || { fail "Current native GRUB2 alias Boot$id is not bound to the transaction ESP"; return 1; }
        count=$((count + 1))
    done
    ok "Current native openSUSE GRUB2 aliases are path/ESP-owned: Boot${csv//,/ Boot}"
    return 0
}

r21_verify_source_grub_nvram_ids() {
    local csv=$1
    # Once the fallback sidecar exists, the firmware is allowed to renumber or
    # synthesize native openSUSE aliases.  Ownership is now the ESP + known EFI
    # path, not the historical Boot#### number.  Files/config remain separately
    # hash/manifest-gated by r21_verify_grub_cleanup_ownership().
    if r21_fallback_meta_exists 2>/dev/null; then
        r23_verify_current_native_grub_aliases
        return $?
    fi
    r21_verify_source_grub_nvram_ids_pre_r23 "$csv"
}

# Delete every *current* native openSUSE GRUB alias on this transaction ESP.
# Re-enumerate after each pass so firmware-created/renumbered aliases cannot
# escape merely because they were not in the original staging snapshot.
r23_sweep_native_grub_nvram_aliases() {
    local pass id csv removed
    for pass in 1 2 3; do
        csv=$(r23_current_native_grub_ids_csv)
        [[ -n $csv ]] || { ok 'Final native openSUSE GRUB2 NVRAM alias sweep is empty'; return 0; }
        removed=0
        IFS=',' read -ra ids <<<"$csv"
        for id in "${ids[@]}"; do
            id=${id^^}
            leap16_nvram_entry_matches_current_esp "$id" || { fail "Refusing to remove Boot$id because it is no longer bound to the transaction ESP"; return 1; }
            sudo efibootmgr -b "$id" -B >/dev/null || { fail "Could not remove native GRUB2 alias Boot$id"; return 1; }
            ok "Removed current path-owned native GRUB2 NVRAM alias Boot$id"
            removed=$((removed + 1))
        done
        ((removed > 0)) || break
    done
    csv=$(r23_current_native_grub_ids_csv)
    [[ -z $csv ]] || { fail "Native openSUSE GRUB2 aliases remain after repeated final sweep: Boot${csv//,/ Boot}"; return 1; }
    ok 'No native openSUSE GRUB2 NVRAM alias remains on the transaction ESP'
    return 0
}

# Remove the firmware-discoverable EFI namespace first.  The old r21 ordering
# deleted Boot#### aliases first and then could abort, leaving GRUBX64.EFI alive
# across a reboot; this exact hardware subsequently synthesized Boot0004.
r23_remove_source_grub_files_efi_first() {
    local dm em rec efi_dir present expected actual
    r21_verify_grub_cleanup_ownership || return 1
    dm=$(r23_source_grub_dir_manifest_path)
    em=$(r23_source_grub_efi_dir_manifest_path)
    rec=$(r23_source_grub_default_record_path)

    efi_dir=$(dirname -- "$PENDING_OLD_GRUB_EFI_RESOLVED")
    pending_verify_tree_manifest "$efi_dir" "$em" || return 1
    sudo rm -rf -- "$efi_dir" || return 1
    ok "Removed ownership-proven native openSUSE EFI namespace first: $efi_dir"

    pending_verify_tree_manifest /boot/grub2 "$dm" || return 1
    sudo rm -rf -- /boot/grub2 || return 1
    ok 'Removed ownership-proven native /boot/grub2 tree'

    present=$(awk -F'\t' '$1=="present"{print $2; exit}' "$rec")
    expected=$(awk -F'\t' '$1=="hash"{print $2; exit}' "$rec")
    if [[ $present == 1 && -e /etc/default/grub ]]; then
        actual=$(r21_hash_privileged /etc/default/grub)
        [[ $actual == "$expected" ]] || { fail 'Refusing to remove changed /etc/default/grub'; return 1; }
        sudo rm -f -- /etc/default/grub || return 1
        ok 'Removed ownership-proven native /etc/default/grub'
    fi
    return 0
}

# r23 finalizer: exact fallback proof first, then remove the temporary Limine
# recovery stanza, remove the firmware-discoverable GRUB EFI namespace, and only
# then sweep every current GRUB alias by path/ESP ownership.
r21_retire_grub_after_fallback_proof() {
    local fallback_id source_ids final_hash order
    r21_validate_fallback_runtime || return 1
    fallback_id=$(r21_meta_value fallback_boot_id); fallback_id=${fallback_id^^}
    source_ids=$(r21_meta_value source_grub_ids)

    printf '\nRETIRING native GRUB2 only after exact Limine fallback proof (r23):\n'
    printf '  - keep primary Limine Boot%s first\n' "$PENDING_TARGET_BOOT_ID"
    printf '  - keep proven Limine fallback Boot%s second\n' "$fallback_id"
    printf '  - historical GRUB2 aliases were Boot%s; final ownership is ESP + EFI path\n' "${source_ids//,/ Boot}"
    printf '  - remove the temporary Limine -> GRUB2 recovery stanza\n'
    printf '  - retire ownership-proven EFI/OPENSUSE before NVRAM alias deletion\n'
    printf '  - sweep every current native GRUB2 alias after filesystem retirement\n'

    final_hash=$(r21_remove_direct_grub_recovery_block) || return 1
    r23_remove_source_grub_files_efi_first || return 1
    r23_sweep_native_grub_nvram_aliases || return 1
    order=$(r21_order_final_primary_fallback "$fallback_id") || return 1

    [[ ! -e /boot/grub2 ]] || { fail '/boot/grub2 still exists after retirement'; return 1; }
    sudo -n test ! -e "$(dirname -- "$PENDING_OLD_GRUB_EFI_RESOLVED")" 2>/dev/null || { fail 'EFI/OPENSUSE still exists after retirement'; return 1; }
    [[ ! -e /etc/default/grub ]] || { fail '/etc/default/grub still exists after retirement'; return 1; }
    [[ -z $(r23_current_native_grub_ids_csv) ]] || { fail 'A native openSUSE GRUB2 NVRAM alias still exists after final sweep'; return 1; }
    [[ $(r21_hash_privileged "$PENDING_ESP_MOUNT/EFI/BOOT/BOOTX64.EFI") == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'Proven Limine fallback changed during GRUB2 retirement'; return 1; }
    boot_id_exists "$PENDING_TARGET_BOOT_ID" || { fail 'Primary Limine NVRAM entry disappeared during GRUB2 retirement'; return 1; }
    boot_id_exists "$fallback_id" || { fail 'Proven Limine fallback NVRAM entry disappeared during GRUB2 retirement'; return 1; }
    validate_target_state limine || return 1
    validate_limine_boot_chain migration || return 1
    validate_cachyos_limine_theme || return 1
    r23_verify_limine_theme_manifest || return 1
    [[ $(r21_hash_privileged "$PENDING_LIMINE_CONF_PATH") == "$final_hash" ]] || { fail 'Final Limine configuration hash changed after retirement'; return 1; }
    leap16_stage_diagnostic grub-retirement-pass
    printf '\nGRUB2-RETIREMENT-VALIDATED. Final persistent BootOrder: %s\n' "$order"
    printf 'Primary Limine + genuine Limine EFI fallback are the only transaction-owned boot paths; native openSUSE GRUB2 aliases/files are gone.\n'
    return 0
}

r23_rearm_fallback_proof() {
    local fallback_id before_order next
    validate_pending_compatibility || { fail "Pending migration is incompatible: $PENDING_REASON"; return 1; }
    r21_forward_pending || { fail 'Fallback re-arm is valid only for GRUB2 -> Limine'; return 1; }
    r21_fallback_meta_exists || { fail 'Fallback transaction metadata is missing'; return 1; }
    [[ ${PENDING_PHASE:-} == runtime-validated ]] || { fail 'Fallback re-arm requires persisted primary runtime proof'; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail 'Fallback re-arm must run from canonical Limine'; return 1; }
    [[ -z $(pending_bootnext_id 2>/dev/null || true) ]] || { fail 'BootNext must be clear before fallback re-arm'; return 1; }
    leap16_require_sudo_session || return 1
    run_validation preflight || return 1
    pending_validate_running_kernel || return 1
    pending_validate_runtime_cmdline_against_source || return 1
    r21_verify_transferred_limine_state || return 1
    r21_verify_grub_cleanup_ownership || return 1
    r23_verify_current_native_grub_aliases || return 1

    fallback_id=$(r21_meta_value fallback_boot_id); fallback_id=${fallback_id^^}
    before_order=$(leap16_current_boot_order)
    sudo efibootmgr -n "$fallback_id" >/dev/null || return 1
    next=$(pending_bootnext_id)
    if [[ ${next^^} != "$fallback_id" || $(leap16_current_boot_order) != "$before_order" ]]; then
        [[ ${next^^} == "$fallback_id" ]] && sudo efibootmgr -N >/dev/null 2>&1 || true
        fail 'Fallback re-arm changed persistent BootOrder or failed exact BootNext verification'
        return 1
    fi
    if ! r22_prepare_resume_bundle; then
        sudo efibootmgr -N >/dev/null 2>&1 || true
        fail 'Could not prepare the root-owned resume bundle after fallback re-arm; BootNext was cleared'
        return 1
    fi
    leap16_stage_diagnostic r23-fallback-rearmed
    ok "Re-armed exact Limine fallback BootNext=Boot$fallback_id without changing persistent BootOrder"
    printf '\nThe next normal reboot re-proves the exact EFI/BOOT fallback.\n'
    printf 'r23 will then remove EFI/OPENSUSE first and sweep every current GRUB2 alias by ESP/path ownership.\n'
    r13_prompt_reboot
}

# Intercept the stranded post-r22 state: fallback metadata exists, BootNext has
# already been consumed, the user is back on canonical Limine, and GRUB files
# remain intact.  Instead of rolling back the fallback transfer, r23 can simply
# re-arm and re-prove the exact fallback once more with the corrected finalizer.
eval "$(declare -f manage_pending_migration | sed '1s/manage_pending_migration/manage_pending_migration_pre_r23/')"
manage_pending_migration() {
    pending_exists || { printf '\nNo pending/staged migration exists.\n'; return 0; }
    validate_pending_compatibility || { printf '\nPending migration state is invalid/incompatible: %s\n' "$PENDING_REASON"; return 1; }

    if r21_forward_pending && r21_fallback_meta_exists; then
        detect_bootloader
        local fallback_id next choice aliases
        fallback_id=$(r21_meta_value fallback_boot_id); fallback_id=${fallback_id^^}
        next=$(pending_bootnext_id 2>/dev/null || true)
        if [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} && -z $next ]]; then
            aliases=$(r23_current_native_grub_ids_csv)
            show_pending_details
            printf '\nCanonical Limine is active after a previously consumed fallback test.\n'
            printf 'The genuine fallback Boot%s remains installed; native GRUB2 filesystem ownership is still available for gated retirement.\n' "$fallback_id"
            if [[ -n $aliases ]]; then
                printf 'Current native GRUB2 alias(es), discovered by ESP/path rather than historical ID: Boot%s\n' "${aliases//,/ Boot}"
            else
                printf 'No current native GRUB2 NVRAM alias is present.\n'
            fi
            printf '\n[1] Re-arm exact fallback proof and continue with corrected r23 retirement\n'
            printf '[2] Re-check transferred fallback + GRUB2 filesystem ownership\n'
            printf '[3] Capture diagnostics\n'
            printf '[4] Back\n\n'
            read -r -p 'Select an option: ' choice
            case "$choice" in
                1) r23_rearm_fallback_proof ;;
                2) leap16_require_sudo_session && r21_verify_transferred_limine_state && r21_verify_grub_cleanup_ownership && r23_verify_current_native_grub_aliases ;;
                3) leap16_stage_diagnostic r23-stranded-fallback-checkpoint ;;
                4|'') return 0 ;;
                *) return 1 ;;
            esac
            return $?
        fi
    fi

    manage_pending_migration_pre_r23 "$@"
}
