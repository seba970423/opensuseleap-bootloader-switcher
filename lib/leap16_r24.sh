#!/usr/bin/env bash
# openSUSE Leap 16 r24
#
# r24 keeps the hardware-proven r23 firmware topology unchanged:
#   primary:  EFI/LIMINE/LIMINE_X64.EFI
#   fallback: EFI/BOOT/BOOTX64.EFI (byte-identical Limine)
#
# The only forward-transaction change is the finalized Limine menu contract.
# Instead of dropping the temporary GRUB2 recovery block entirely after GRUB
# retirement, r24 replaces it with an explicit "EFI fallback" entry that
# chainloads the standard UEFI fallback executable.  This mirrors the visible
# CachyOS Limine menu while leaving the NVRAM fallback proof/ownership model
# untouched.

r24_final_fallback_block_present() {
    local conf=$1
    grep -Fqx '/EFI fallback' "$conf" \
        && grep -Fqx 'protocol: efi' "$conf" \
        && grep -Fqx 'path: boot():/EFI/BOOT/BOOTX64.EFI' "$conf"
}

# Convert the exact temporary direct-GRUB recovery block into the final visible
# EFI fallback entry.  The caller has already proven the actual firmware-level
# fallback Boot#### and its bytes; this only exposes that executable in Limine.
r24_replace_direct_grub_recovery_with_efi_fallback() {
    local conf=$PENDING_LIMINE_CONF_PATH tmp out current expected found=0 line a b c d new_hash final_snap
    expected=$(r21_meta_value transferred_limine_conf_hash)
    current=$(r21_hash_privileged "$conf")
    [[ -n $expected && $current == "$expected" ]] || { fail 'Transferred limine.conf changed before final EFI fallback menu conversion'; return 1; }

    tmp=$(mktemp) || return 1
    out=$(mktemp) || { rm -f -- "$tmp"; return 1; }
    sudo -n cat -- "$conf" >"$tmp" 2>/dev/null || cat -- "$conf" >"$tmp" || { rm -f -- "$tmp" "$out"; return 1; }

    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == '/openSUSE GRUB2 recovery' ]]; then
            IFS= read -r a || { rm -f -- "$tmp" "$out"; return 1; }
            IFS= read -r b || { rm -f -- "$tmp" "$out"; return 1; }
            IFS= read -r c || { rm -f -- "$tmp" "$out"; return 1; }
            IFS= read -r d || { rm -f -- "$tmp" "$out"; return 1; }
            [[ $c == 'protocol: efi' && $d == 'path: boot():/EFI/OPENSUSE/SHIM.EFI' ]] || {
                rm -f -- "$tmp" "$out"
                fail 'Direct GRUB2 recovery block changed before final EFI fallback menu conversion'
                return 1
            }
            {
                printf '/EFI fallback\n'
                printf '### Standard UEFI fallback executable; byte-identical to canonical Limine\n'
                printf 'comment: Standard UEFI fallback loader (Limine)\n'
                printf 'protocol: efi\n'
                printf 'path: boot():/EFI/BOOT/BOOTX64.EFI\n'
            } >>"$out"
            found=$((found + 1))
        else
            printf '%s\n' "$line" >>"$out"
        fi
    done <"$tmp"
    rm -f -- "$tmp"

    [[ $found == 1 ]] || { rm -f -- "$out"; fail "Expected exactly one direct GRUB2 recovery block, found $found"; return 1; }
    new_hash=$(sha256sum -- "$out" | awk '{print $1}')
    r21_atomic_replace "$out" "$conf" "$new_hash" || { rm -f -- "$out"; return 1; }
    final_snap="$PENDING_TRANSACTION_SNAPSHOT_DIR/$LEAP16_R21_FINALCONF_BASENAME"
    cp -- "$out" "$final_snap" 2>/dev/null || true
    chmod 600 -- "$final_snap" 2>/dev/null || true
    rm -f -- "$out"
    printf '%s\n' "$new_hash"
}

# r24 recovery validator: the finalized state deliberately exposes EFI/BOOT in
# the Limine menu.  The same title/path is also used before ownership transfer,
# so byte identity distinguishes the two legitimate states.
leap16_validate_limine_recovery_contract() {
    local conf=$1 fallback="$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI" primary="$ESP_MOUNT/EFI/LIMINE/LIMINE_X64.EFI" fh ph
    LEAP16_LIMINE_RECOVERY_DETAIL=''

    if r24_final_fallback_block_present "$conf"; then
        fh=$(r21_hash_privileged "$fallback"); ph=$(r21_hash_privileged "$primary")
        [[ -n $fh && -n $ph ]] || return 1
        if [[ $fh != "$ph" ]]; then
            LEAP16_LIMINE_RECOVERY_DETAIL='Limine config keeps the pre-transfer openSUSE EFI fallback as GRUB2 recovery'
            return 0
        fi
        if sudo -n test -e "$ESP_MOUNT/EFI/OPENSUSE" 2>/dev/null || [[ -e $ESP_MOUNT/EFI/OPENSUSE ]]; then
            return 1
        fi
        LEAP16_LIMINE_RECOVERY_DETAIL='Finalized Limine exposes the byte-identical standard EFI fallback in its menu'
        return 0
    fi

    if grep -Fqx '/openSUSE GRUB2 recovery' "$conf" && grep -Fqx 'path: boot():/EFI/OPENSUSE/SHIM.EFI' "$conf"; then
        sudo -n test -f "$ESP_MOUNT/EFI/OPENSUSE/SHIM.EFI" 2>/dev/null || [[ -f $ESP_MOUNT/EFI/OPENSUSE/SHIM.EFI ]] || return 1
        fh=$(r21_hash_privileged "$fallback"); ph=$(r21_hash_privileged "$primary")
        [[ -n $fh && $fh == "$ph" ]] || return 1
        LEAP16_LIMINE_RECOVERY_DETAIL='Limine fallback owns EFI/BOOT; temporary recovery is redirected directly to openSUSE shim'
        return 0
    fi

    # Accept a finalized r23 installation so r24 can upgrade it in place.
    if ! grep -Fq '/EFI fallback' "$conf" && ! grep -Fq '/openSUSE GRUB2 recovery' "$conf"; then
        fh=$(r21_hash_privileged "$fallback"); ph=$(r21_hash_privileged "$primary")
        [[ -n $fh && $fh == "$ph" ]] || return 1
        if sudo -n test -e "$ESP_MOUNT/EFI/OPENSUSE" 2>/dev/null || [[ -e $ESP_MOUNT/EFI/OPENSUSE ]]; then return 1; fi
        LEAP16_LIMINE_RECOVERY_DETAIL='Finalized r23-compatible Limine fallback is valid; r24 can expose it in the Limine menu'
        return 0
    fi
    return 1
}

# Exact r23 retirement sequencing, with one deliberate final-config change:
# once EFI/OPENSUSE is gone, replace the temporary GRUB recovery stanza with
# the visible standard EFI fallback entry before the fresh path-owned NVRAM sweep.
r21_retire_grub_after_fallback_proof() {
    local fallback_id source_ids final_hash order
    r21_validate_fallback_runtime || return 1
    fallback_id=$(r21_meta_value fallback_boot_id); fallback_id=${fallback_id^^}
    source_ids=$(r21_meta_value source_grub_ids)

    printf '\nRETIRING native GRUB2 only after exact Limine fallback proof (r24):\n'
    printf '  - keep primary Limine Boot%s first\n' "$PENDING_TARGET_BOOT_ID"
    printf '  - keep proven Limine fallback Boot%s second\n' "$fallback_id"
    printf '  - historical GRUB2 aliases were Boot%s; final ownership is ESP + EFI path\n' "${source_ids//,/ Boot}"
    printf '  - retire ownership-proven EFI/OPENSUSE before NVRAM alias deletion\n'
    printf '  - convert the temporary GRUB2 recovery menu item into visible EFI fallback\n'
    printf '  - sweep every current native GRUB2 alias after filesystem retirement\n'

    r23_remove_source_grub_files_efi_first || return 1
    final_hash=$(r24_replace_direct_grub_recovery_with_efi_fallback) || return 1
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
    printf 'Primary Limine + genuine firmware fallback are proven, and EFI fallback is exposed in the Limine menu.\n'
    return 0
}

r24_current_final_ids() {
    local primary_count fallback_count primary_id fallback_id order
    mapfile -t r24_primary_ids < <(r21_nvram_ids_for_esp_path '\\EFI\\LIMINE\\LIMINE_X64.EFI')
    mapfile -t r24_fallback_ids < <(r21_nvram_ids_for_esp_path "$LEAP16_R21_FALLBACK_EFI_PATH")
    primary_count=${#r24_primary_ids[@]}; fallback_count=${#r24_fallback_ids[@]}
    ((primary_count == 1 && fallback_count == 1)) || { fail "Expected exactly one primary Limine alias and one EFI fallback alias (found $primary_count/$fallback_count)"; return 1; }
    primary_id=${r24_primary_ids[0]^^}; fallback_id=${r24_fallback_ids[0]^^}
    leap16_nvram_entry_matches_current_esp "$primary_id" || { fail "Primary Limine Boot$primary_id is not bound to the current ESP"; return 1; }
    leap16_nvram_entry_matches_current_esp "$fallback_id" || { fail "EFI fallback Boot$fallback_id is not bound to the current ESP"; return 1; }
    order=$(leap16_current_boot_order)
    [[ $order == "$primary_id,$fallback_id"* ]] || { fail "Final BootOrder does not begin primary/fallback ($order)"; return 1; }
    printf '%s\t%s\n' "$primary_id" "$fallback_id"
}

r24_validate_inplace_fallback_menu_upgrade() {
    local ids primary_id fallback_id ph fh conf="$ESP_MOUNT/limine.conf"
    pending_exists && { fail 'An active transaction exists; refusing an in-place finalized-menu upgrade'; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == limine ]] || { fail 'The in-place r24 menu upgrade requires a currently booted Limine installation'; return 1; }
    run_validation preflight || return 1
    ids=$(r24_current_final_ids) || return 1
    primary_id=${ids%%$'\t'*}; fallback_id=${ids#*$'\t'}
    ph=$(r21_hash_privileged "$ESP_MOUNT/EFI/LIMINE/LIMINE_X64.EFI")
    fh=$(r21_hash_privileged "$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI")
    [[ -n $ph && $ph == "$fh" ]] || { fail 'Current EFI/BOOT fallback is not byte-identical to canonical Limine'; return 1; }
    [[ -z $(r23_current_native_grub_ids_csv) ]] || { fail 'A native openSUSE GRUB2 NVRAM alias still exists; this is not a finalized Limine-only topology'; return 1; }
    (sudo -n test ! -e "$ESP_MOUNT/EFI/OPENSUSE" 2>/dev/null || [[ ! -e $ESP_MOUNT/EFI/OPENSUSE ]]) || { fail 'EFI/OPENSUSE still exists; this is not a finalized Limine-only topology'; return 1; }
    [[ ! -e /boot/grub2 ]] || { fail '/boot/grub2 still exists; this is not a finalized Limine-only topology'; return 1; }
    [[ ! -e /etc/default/grub ]] || { fail '/etc/default/grub still exists; this is not a finalized Limine-only topology'; return 1; }
    validate_limine_boot_chain current || return 1
    if r24_final_fallback_block_present "$conf"; then
        ok "EFI fallback is already exposed in Limine; firmware paths are Boot$primary_id + Boot$fallback_id"
        return 2
    fi
    if grep -Fq '/openSUSE GRUB2 recovery' "$conf"; then
        fail 'A temporary GRUB2 recovery stanza is still present; refusing to reinterpret an unfinished transaction'
        return 1
    fi
    return 0
}

r24_add_fallback_menu_to_finalized_limine() {
    local conf="$ESP_MOUNT/limine.conf" before tmp new_hash ids primary_id fallback_id
    if r24_validate_inplace_fallback_menu_upgrade; then :; else
        case $? in
            2) return 0 ;;
            *) return 1 ;;
        esac
    fi
    ids=$(r24_current_final_ids) || return 1
    primary_id=${ids%%$'\t'*}; fallback_id=${ids#*$'\t'}

    printf '\nFinalized Limine EFI fallback menu upgrade (r24):\n'
    printf '  Firmware primary:  Boot%s -> \\EFI\\LIMINE\\LIMINE_X64.EFI\n' "$primary_id"
    printf '  Firmware fallback: Boot%s -> \\EFI\\BOOT\\BOOTX64.EFI\n' "$fallback_id"
    printf '  NVRAM/EFI payloads are not changed.\n'
    printf '  Only /boot/efi/limine.conf gains a visible "EFI fallback" chainload entry.\n\n'
    read -r -p 'Type APPLY to add the menu entry, or anything else to cancel: ' answer
    [[ $answer == APPLY ]] || { printf '\nOperation cancelled. Nothing was modified.\n'; return 0; }

    leap16_require_sudo_session || return 1
    r24_validate_inplace_fallback_menu_upgrade || {
        rc=$?; [[ $rc == 2 ]] && return 0; return 1;
    }
    before=$(r21_hash_privileged "$conf")
    tmp=$(mktemp) || return 1
    sudo -n cat -- "$conf" >"$tmp" 2>/dev/null || cat -- "$conf" >"$tmp" || { rm -f -- "$tmp"; return 1; }
    cat >>"$tmp" <<'EOF_R24_FALLBACK'

/EFI fallback
### Standard UEFI fallback executable; byte-identical to canonical Limine
comment: Standard UEFI fallback loader (Limine)
protocol: efi
path: boot():/EFI/BOOT/BOOTX64.EFI
EOF_R24_FALLBACK
    new_hash=$(sha256sum -- "$tmp" | awk '{print $1}')
    [[ $new_hash != "$before" ]] || { rm -f -- "$tmp"; fail 'Generated r24 Limine config did not change'; return 1; }
    r21_atomic_replace "$tmp" "$conf" "$new_hash" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
    validate_limine_boot_chain current || { fail 'r24 fallback menu entry was written but final validation failed'; return 1; }
    ok "Added visible EFI fallback menu entry -> EFI/BOOT/BOOTX64.EFI; Boot$primary_id/Boot$fallback_id firmware topology was untouched"
    return 0
}

# Enable a narrow current-Limine maintenance action solely for the finalized
# r23 -> r24 menu upgrade.  All other live-operation behavior stays inherited.
eval "$(declare -f run_live_operation | sed '1s/run_live_operation/run_live_operation_pre_r24/')"
run_live_operation() {
    local target=${1:-} current
    detect_bootloader
    current=$BOOTLOADER
    if [[ $current:$target == limine:limine ]]; then
        r24_add_fallback_menu_to_finalized_limine
    else
        run_live_operation_pre_r24 "$@"
    fi
}
