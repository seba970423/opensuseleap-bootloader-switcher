#!/usr/bin/env bash
# leap16-r55: recover the exact r51-r54 pre-transfer systemd-boot -> Limine
# stranded state without pretending it is finalized.
#
# The known failure can leave:
#   * canonical Limine running and runtime-proven;
#   * the old systemd-boot NVRAM alias dropped/reclaimed by firmware;
#   * EFI/BOOT still containing the exact systemd-boot bytes;
#   * one firmware UEFI OS alias still pointing at EFI/BOOT;
#   * no user pending transaction, and possibly no visible Limine EFI-fallback
#     menu entry.
#
# r55 does NOT convert EFI/BOOT to Limine in that state.  It first restores a
# fully bootable, visible, canonical systemd-boot recovery topology and returns
# systemd-boot to first place.  After a normal boot into systemd-boot the fixed
# r54 two-proof transaction can be started fresh.

LEAP16_R55_FAILED_DETAIL_PREFIX='Primary Limine proof passed, but fallback staging failed.'

leap16_r55_last_result_value() {
    local key=$1 f="$PENDING_STATE_DIR/${R22_RESULT_FILE_NAME:-last-auto-result.txt}"
    [[ -f $f ]] || return 1
    awk -F= -v k="$key" '$1==k{ sub(/^[^=]*=/,""); print; exit }' "$f"
}

leap16_r55_stranded_pretransfer_signature_quiet() {
    local detail
    pending_exists && return 1
    detect_bootloader
    [[ ${BOOTLOADER:-} == limine ]] || return 1
    detail=$(leap16_r55_last_result_value detail 2>/dev/null || true)
    [[ $detail == "$LEAP16_R55_FAILED_DETAIL_PREFIX"* ]] || return 1
    [[ ${BOOT_CURRENT:-} =~ ^[0-9A-Fa-f]{4}$ ]] || return 1
    nvram_id_matches_path "${BOOT_CURRENT^^}" "$(target_expected_efi_path limine)" >/dev/null 2>&1 || return 1
    return 0
}

leap16_r55_exact_one_fallback_id() {
    local -a ids=()
    mapfile -t ids < <(leap16_r53_current_fallback_ids)
    ((${#ids[@]} == 1)) || return 1
    printf '%s\n' "${ids[0]^^}"
}

leap16_r55_systemd_recovery_bytes_exact() {
    local canonical fallback ch fh
    canonical=$(resolve_efi_path_on_esp_privileged "$LEAP16_R32_SDBOOT_EFI" 2>/dev/null || true)
    fallback="${ESP_MOUNT%/}/EFI/BOOT/BOOTX64.EFI"
    [[ -n $canonical ]] || { fail 'Canonical systemd-boot EFI is missing; stranded-state recovery is unsafe'; return 1; }
    (sudo -n test -f "$fallback" 2>/dev/null || [[ -f $fallback ]]) || { fail 'EFI/BOOT/BOOTX64.EFI is missing; stranded-state recovery is unsafe'; return 1; }
    ch=$(r21_hash_privileged "$canonical")
    fh=$(r21_hash_privileged "$fallback")
    [[ -n $ch && $ch == "$fh" ]] || {
        fail 'EFI/BOOT is not byte-identical to canonical systemd-boot; refusing to guess which backend owns the fallback'
        return 1
    }
    ok 'Generic EFI fallback is still byte-identical to canonical systemd-boot'
}

leap16_r55_validate_existing_or_missing_systemd_alias() {
    local id
    local -a ids=()
    mapfile -t ids < <(leap16_r38_current_systemd_ids)
    ((${#ids[@]} <= 1)) || { fail "Canonical systemd-boot NVRAM alias set is ambiguous (${#ids[@]} aliases)"; return 1; }
    if ((${#ids[@]} == 1)); then
        id=${ids[0]^^}
        leap16_boot_entry_is_active "$id" || { fail "Existing systemd-boot Boot$id is inactive"; return 1; }
        leap16_nvram_entry_matches_current_esp "$id" || { fail "Existing systemd-boot Boot$id is not bound to the current ESP"; return 1; }
        nvram_id_matches_path "$id" "$LEAP16_R32_SDBOOT_EFI" || { fail "Existing systemd-boot Boot$id changed EFI path"; return 1; }
        printf '%s\n' "$id"
        return 0
    fi
    printf '\n'
}

leap16_r55_ensure_pretransfer_limine_fallback_menu() {
    local conf="${ESP_MOUNT%/}/limine.conf" fallback_count direct_count tmp new_hash old_staging=${LEAP16_R51_STAGING:-0}
    (sudo -n test -f "$conf" 2>/dev/null || [[ -f $conf ]]) || { fail 'Active Limine config is missing'; return 1; }
    fallback_count=$(sudo -n grep -Fxc '/EFI fallback' "$conf" 2>/dev/null || grep -Fxc '/EFI fallback' "$conf" 2>/dev/null || true)
    direct_count=$(sudo -n grep -Fxc '/openSUSE systemd-boot recovery' "$conf" 2>/dev/null || grep -Fxc '/openSUSE systemd-boot recovery' "$conf" 2>/dev/null || true)
    [[ $fallback_count =~ ^[0-9]+$ && $direct_count =~ ^[0-9]+$ ]] || return 1
    ((fallback_count <= 1 && direct_count == 0)) || {
        fail "Limine recovery-menu state is ambiguous (EFI fallback=$fallback_count, direct systemd recovery=$direct_count)"
        return 1
    }

    if ((fallback_count == 0)); then
        tmp=$(mktemp) || return 1
        if [[ -r $conf ]]; then cat -- "$conf" >"$tmp"; else sudo -n cat -- "$conf" >"$tmp" 2>/dev/null; fi || { rm -f -- "$tmp"; return 1; }
        cat >>"$tmp" <<'EOF_MENU'

/EFI fallback
### Shared pre-transfer recovery entry; EFI/BOOT remains native openSUSE until Limine fallback proof
comment: Preserved openSUSE generic fallback / systemd-boot recovery path
protocol: efi
path: boot():/EFI/BOOT/BOOTX64.EFI
EOF_MENU
        new_hash=$(sha256sum -- "$tmp" | awk '{print $1}')
        r21_atomic_replace "$tmp" "$conf" "$new_hash" || { rm -f -- "$tmp"; return 1; }
        rm -f -- "$tmp"
        ok 'Restored visible Limine EFI fallback menu entry -> EFI/BOOT/BOOTX64.EFI'
    else
        ok 'Visible Limine EFI fallback menu entry is already present'
    fi

    LEAP16_R51_STAGING=1
    if ! leap16_validate_limine_recovery_contract "$conf"; then
        LEAP16_R51_STAGING=$old_staging
        fail 'Visible Limine EFI fallback menu entry does not match the exact systemd-boot pre-transfer recovery contract'
        return 1
    fi
    if ! validate_limine_boot_chain migration; then
        LEAP16_R51_STAGING=$old_staging
        fail 'Limine failed deep validation after recovery-menu normalization'
        return 1
    fi
    LEAP16_R51_STAGING=$old_staging
    return 0
}

LEAP16_R55_SYSTEMD_ID=''
leap16_r55_create_systemd_alias_if_missing() {
    local existing
    LEAP16_R55_SYSTEMD_ID=''
    existing=$(leap16_r55_validate_existing_or_missing_systemd_alias) || return 1
    if [[ -n $existing ]]; then
        LEAP16_R55_SYSTEMD_ID=${existing^^}
        ok "Canonical systemd-boot recovery alias already exists as Boot$LEAP16_R55_SYSTEMD_ID"
        return 0
    fi
    r28_create_alias_create_only "$LEAP16_R32_SDBOOT_LABEL" "$LEAP16_R32_SDBOOT_EFI" || return 1
    [[ ${R28_CREATED_ALIAS_ID:-} =~ ^[0-9A-Fa-f]{4}$ ]] || { fail 'systemd-boot recovery alias creation did not publish a Boot####'; return 1; }
    LEAP16_R55_SYSTEMD_ID=${R28_CREATED_ALIAS_ID^^}
}

leap16_r55_order_systemd_limine_fallback() {
    local systemd=${1^^} limine=${2^^} fallback=${3^^} order joined id
    local -a current=() out=("$systemd" "$limine" "$fallback")
    order=$(leap16_current_boot_order) || return 1
    IFS=',' read -ra current <<<"$order"
    for id in "${current[@]}"; do
        id=${id^^}
        [[ -n $id && $id != "$systemd" && $id != "$limine" && $id != "$fallback" ]] || continue
        boot_id_exists "$id" && out+=("$id")
    done
    joined=$(IFS=,; printf '%s' "${out[*]}")
    sudo efibootmgr -o "$joined" >/dev/null || return 1
    order=$(leap16_current_boot_order)
    [[ $order == "$systemd,$limine,$fallback"* ]] || { fail "Recovered BootOrder is not systemd-boot, Limine, EFI fallback first/second/third ($order)"; return 1; }
    ok "Recovered persistent BootOrder: systemd-boot Boot$systemd first, Limine Boot$limine second, EFI fallback Boot$fallback third"
}

leap16_r55_set_systemd_policy_if_needed() {
    local tmp
    if grep -Eq '^[[:space:]]*LOADER_TYPE=.*systemd-boot' /etc/sysconfig/bootloader 2>/dev/null; then
        ok 'openSUSE LOADER_TYPE already identifies systemd-boot recovery source'
        return 0
    fi
    [[ -f /etc/sysconfig/bootloader ]] || { fail '/etc/sysconfig/bootloader is missing'; return 1; }
    tmp=$(mktemp) || return 1
    awk 'BEGIN{done=0} /^[[:space:]]*LOADER_TYPE=/ {print "LOADER_TYPE=systemd-boot"; done=1; next} {print} END{if(!done) print "LOADER_TYPE=systemd-boot"}' /etc/sysconfig/bootloader >"$tmp" || { rm -f -- "$tmp"; return 1; }
    sudo install -m 0644 -- "$tmp" /etc/sysconfig/bootloader || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
    ok 'Restored openSUSE LOADER_TYPE=systemd-boot for the recovered source'
}

leap16_r55_write_recovery_result() {
    local f="$PENDING_STATE_DIR/${R22_RESULT_FILE_NAME:-last-auto-result.txt}" tmp
    mkdir -p -- "$PENDING_STATE_DIR" || return 1
    tmp=$(mktemp) || return 1
    {
        printf 'status=safe-fallback\n'
        printf 'time=%s\n' "$(date -Is)"
        printf 'detail=Recovered the stranded pre-transfer systemd-boot -> Limine state. Canonical systemd-boot is persistent first again; canonical Limine is second; the firmware EFI fallback remains byte-identical to systemd-boot and is visible from the Limine menu. Reboot into systemd-boot before starting a fresh migration.\n'
    } >"$tmp"
    install -m 0600 -- "$tmp" "$f" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
}

leap16_r55_recover_stranded_pretransfer() {
    local limine_id fallback_id systemd_id answer
    leap16_r55_stranded_pretransfer_signature_quiet || { fail 'The exact r51-r54 stranded pre-transfer signature is not present'; return 1; }
    leap16_require_sudo_session || return 1
    detect_bootloader
    run_validation preflight || return 1
    [[ -z ${BOOT_NEXT:-} ]] || { fail "BootNext is already set to Boot${BOOT_NEXT^^}; refusing recovery mutation"; return 1; }
    limine_id=${BOOT_CURRENT^^}
    nvram_id_matches_path "$limine_id" "$(target_expected_efi_path limine)" || { fail 'Current Limine BootCurrent is not the canonical Limine EFI path'; return 1; }
    leap16_nvram_entry_matches_current_esp "$limine_id" || { fail 'Current Limine BootCurrent is not bound to the detected ESP'; return 1; }

    printf '\nRecovering the failed pre-transfer systemd-boot -> Limine checkpoint:\n'
    printf '  - do NOT convert EFI/BOOT to Limine yet; the second proof was never earned\n'
    printf '  - re-prove the surviving canonical systemd-boot files and its current EFI/BOOT bytes\n'
    printf '  - restore the visible Limine EFI fallback menu entry if it is missing\n'
    printf '  - recreate one canonical systemd-boot Boot#### only if firmware reclaimed the old one\n'
    printf '  - put systemd-boot first, current proven Limine second, and the existing EFI fallback third\n'
    printf '  - reboot normally into systemd-boot before starting the fixed two-proof migration again\n\n'

    leap16_r34_validate_systemd_boot_chain recovery || { fail 'Surviving systemd-boot files failed deep validation; recovery stopped before NVRAM/config mutation'; return 1; }
    leap16_r55_systemd_recovery_bytes_exact || return 1
    fallback_id=$(leap16_r55_exact_one_fallback_id) || { fail 'Expected exactly one same-ESP EFI/BOOT fallback NVRAM alias for stranded-state recovery'; return 1; }
    leap16_boot_entry_is_active "$fallback_id" || { fail "Fallback Boot$fallback_id is inactive"; return 1; }
    leap16_nvram_entry_matches_current_esp "$fallback_id" || { fail "Fallback Boot$fallback_id is not bound to the current ESP"; return 1; }
    nvram_id_matches_path "$fallback_id" "$LEAP16_R21_FALLBACK_EFI_PATH" || { fail "Fallback Boot$fallback_id changed EFI path"; return 1; }

    leap16_r55_ensure_pretransfer_limine_fallback_menu || return 1
    leap16_r55_create_systemd_alias_if_missing || return 1
    systemd_id=${LEAP16_R55_SYSTEMD_ID^^}
    [[ $systemd_id =~ ^[0-9A-F]{4}$ ]] || { fail 'Recovered systemd-boot alias ID is invalid'; return 1; }
    leap16_r55_set_systemd_policy_if_needed || return 1
    leap16_r55_order_systemd_limine_fallback "$systemd_id" "$limine_id" "$fallback_id" || return 1

    # Re-prove both recovery paths after all writes.  EFI/BOOT remains systemd.
    nvram_id_matches_path "$systemd_id" "$LEAP16_R32_SDBOOT_EFI" || { fail 'Recovered systemd-boot NVRAM path changed during final verification'; return 1; }
    leap16_nvram_entry_matches_current_esp "$systemd_id" || { fail 'Recovered systemd-boot NVRAM ESP binding changed during final verification'; return 1; }
    leap16_r34_validate_systemd_boot_chain recovery || return 1
    leap16_r55_systemd_recovery_bytes_exact || return 1
    LEAP16_R51_STAGING=1 validate_limine_boot_chain migration || return 1
    [[ -z $(pending_bootnext_id 2>/dev/null || true) ]] || { fail 'BootNext appeared during stranded-state recovery'; return 1; }
    leap16_r55_write_recovery_result || warn 'Recovered topology is valid, but the historical result file could not be updated'

    printf '\nSAFE SOURCE RECOVERY COMPLETE.\n'
    printf '  systemd-boot: Boot%s, persistent first\n' "$systemd_id"
    printf '  Limine:       Boot%s, persistent second (current running session)\n' "$limine_id"
    printf '  EFI fallback: Boot%s, persistent third and still byte-identical to systemd-boot\n' "$fallback_id"
    printf '  Limine menu:  visible EFI fallback entry restored/preserved\n'
    printf '\nNo Limine fallback proof is claimed. Reboot into systemd-boot, then start systemd-boot -> Limine again under r55.\n'
    read -r -p 'Reboot now into the recovered persistent systemd-boot source? [y/N]: ' answer
    case "$answer" in
        y|Y|yes|YES) sudo systemctl reboot ;;
        *) printf 'Reboot deferred. Do not manually select the EFI/BOOT fallback as a Limine proof; it still contains systemd-boot.\n' ;;
    esac
}

leap16_r55_stranded_recovery_menu() {
    local choice
    printf '\nInterrupted systemd-boot -> Limine transaction detected.\n'
    printf 'The primary Limine boot succeeded, but the second fallback-proof stage never committed.\n'
    printf 'This is NOT a finalized Limine-only state.\n\n'
    printf '[1] Restore safe systemd-boot source + visible Limine recovery menu\n'
    printf '[2] Re-check stranded-state signature (read-only)\n'
    printf '[3] Back\n\n'
    read -r -p 'Select an option: ' choice
    case "$choice" in
        1) leap16_r55_recover_stranded_pretransfer ;;
        2)
            detect_bootloader
            printf '\nCurrent bootloader: %s Boot%s\n' "$(bootloader_display_name "$BOOTLOADER")" "${BOOT_CURRENT:-unknown}"
            printf 'Historical failure: %s\n' "$(leap16_r55_last_result_value detail 2>/dev/null || printf 'unavailable')"
            if leap16_r55_stranded_pretransfer_signature_quiet; then
                ok 'Exact r55 stranded pre-transfer recovery signature is present'
            else
                fail 'Exact r55 stranded pre-transfer recovery signature is not present'
            fi
            ;;
        *) return 0 ;;
    esac
}

# Selector [2] must not pretend that "no pending TSV" means there is nothing to
# recover after the known r53 failure.  Detect the exact historical signature
# and offer a narrow source-recovery action; all normal pending managers remain
# inherited unchanged.
eval "$(declare -f manage_pending_migration | sed '1s/manage_pending_migration/manage_pending_migration_pre_leap16_r55/')"
manage_pending_migration() {
    if ! pending_exists && leap16_r55_stranded_pretransfer_signature_quiet; then
        leap16_r55_stranded_recovery_menu
        return $?
    fi
    manage_pending_migration_pre_leap16_r55 "$@"
}

# Surface the stranded recovery in the ordinary banner without claiming an
# active transaction exists.
eval "$(declare -f pending_banner | sed '1s/pending_banner/pending_banner_pre_leap16_r55/')"
pending_banner() {
    pending_banner_pre_leap16_r55 "$@"
    if ! pending_exists && leap16_r55_stranded_pretransfer_signature_quiet; then
        printf 'Recovery required: failed systemd-boot -> Limine pre-transfer checkpoint detected; selector [2] can restore the safe source topology.\n'
    fi
}
