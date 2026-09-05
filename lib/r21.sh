#!/usr/bin/env bash

# r21 adds two things on top of the r20 transaction engine:
#   1. CachyOS/Calamares GRUB theme parity, including a second runtime proof
#      when upgrading an already-runtime-validated unthemed r20 candidate.
#   2. Ownership-gated Limine -> GRUB finalization after the exact themed GRUB
#      state has successfully booted and passed runtime validation.
#
# The r20 state format remains readable. Theme proof is represented by files
# inside the transaction-private snapshot directory, so existing r20 state can
# be upgraded without rewriting the source identity/cmdline fields.

R21_GRUB_THEME_DIR=/usr/share/grub/themes/cachyos
R21_GRUB_THEME_PATH=/usr/share/grub/themes/cachyos/theme.txt

r21_theme_marker_path() {
    printf '%s/grub-theme-required\n' "$PENDING_TRANSACTION_SNAPSHOT_DIR"
}

r21_theme_manifest_path() {
    printf '%s/grub-theme-dir.tsv\n' "$PENDING_TRANSACTION_SNAPSHOT_DIR"
}

r21_theme_required() {
    [[ $PENDING_SOURCE == limine && $PENDING_TARGET == grub ]] || return 1
    [[ -n $PENDING_TRANSACTION_SNAPSHOT_DIR ]] || return 1
    [[ -f $(r21_theme_marker_path) && -f $(r21_theme_manifest_path) ]]
}

# Preserve the r20 implementations so r21 can add only its extra ownership
# checks instead of duplicating the whole transaction engine.
eval "$(declare -f verify_pending_candidate_ownership_unchanged | sed '1s/verify_pending_candidate_ownership_unchanged/verify_pending_candidate_ownership_unchanged_r20/')"
eval "$(declare -f validate_pending_target_deep | sed '1s/validate_pending_target_deep/validate_pending_target_deep_r20/')"

verify_pending_candidate_ownership_unchanged() {
    verify_pending_candidate_ownership_unchanged_r20 || return 1
    if r21_theme_required; then
        pending_verify_tree_manifest "$R21_GRUB_THEME_DIR" "$(r21_theme_manifest_path)" || {
            fail 'CachyOS GRUB theme assets differ from the exact candidate manifest'
            return 1
        }
        ok 'CachyOS GRUB theme assets still match the transaction manifest'
    fi
    return 0
}

validate_pending_target_deep() {
    validate_pending_target_deep_r20 || return 1
    if r21_theme_required; then
        validate_cachyos_grub_theme || return 1
    fi
    return 0
}

r21_pending_set_key() {
    local key=$1 value=${2:-} tmp found=0
    pending_safe_value "$key" && pending_safe_value "$value" || return 1
    [[ -f $PENDING_STATE_FILE ]] || return 1
    tmp=$(mktemp "$PENDING_STATE_DIR/.r21-state.XXXXXX") || return 1
    chmod 600 -- "$tmp" 2>/dev/null || true
    while IFS=$'\t' read -r k v; do
        if [[ $k == "$key" ]]; then
            printf '%s\t%s\n' "$key" "$value" >>"$tmp" || { rm -f -- "$tmp"; return 1; }
            found=1
        else
            printf '%s\t%s\n' "$k" "$v" >>"$tmp" || { rm -f -- "$tmp"; return 1; }
        fi
    done <"$PENDING_STATE_FILE"
    ((found)) || printf '%s\t%s\n' "$key" "$value" >>"$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$PENDING_STATE_FILE"
}

r21_write_theme_policy_into_grub_default() {
    local tmp
    [[ -f /etc/default/grub ]] || { fail '/etc/default/grub is missing'; return 1; }
    tmp=$(mktemp) || return 1
    awk -v theme="$R21_GRUB_THEME_PATH" '
        BEGIN { done=0 }
        /^[[:space:]]*GRUB_THEME[[:space:]]*=/ {
            if (!done) { printf "GRUB_THEME=\"%s\"\n", theme; done=1 }
            next
        }
        { print }
        END { if (!done) printf "GRUB_THEME=\"%s\"\n", theme }
    ' /etc/default/grub >"$tmp" || { rm -f -- "$tmp"; return 1; }
    sudo install -o root -g root -m 0644 -- "$tmp" /etc/default/grub || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
}

r21_refresh_grub_theme_candidate_metadata() {
    local cfg_hash default_hash marker manifest
    [[ -n $PENDING_TRANSACTION_SNAPSHOT_DIR && -d $PENDING_TRANSACTION_SNAPSHOT_DIR ]] || {
        fail 'Transaction snapshot directory is unavailable'; return 1;
    }
    cfg_hash=$(sudo -n sha256sum -- "$PENDING_GRUB_CFG_PATH" 2>/dev/null | awk '{print $1}' || true)
    default_hash=$(sha256sum /etc/default/grub 2>/dev/null | awk '{print $1}' || sudo -n sha256sum /etc/default/grub 2>/dev/null | awk '{print $1}' || true)
    [[ $cfg_hash =~ ^[0-9A-Fa-f]{64}$ && $default_hash =~ ^[0-9A-Fa-f]{64}$ ]] || {
        fail 'Could not hash the themed GRUB policy/config'; return 1;
    }

    write_privileged_tree_manifest "$PENDING_GRUB_DIR" "$PENDING_GRUB_DIR_MANIFEST" || {
        fail 'Could not refresh the exact /boot/grub candidate manifest'; return 1;
    }
    manifest=$(r21_theme_manifest_path)
    write_privileged_tree_manifest "$R21_GRUB_THEME_DIR" "$manifest" || {
        fail 'Could not record the exact CachyOS GRUB theme asset manifest'; return 1;
    }
    marker=$(r21_theme_marker_path)
    printf 'required\n' >"$marker" || return 1
    chmod 600 -- "$PENDING_GRUB_DIR_MANIFEST" "$manifest" "$marker" 2>/dev/null || true

    r21_pending_set_key grub_cfg_hash "$cfg_hash" || return 1
    r21_pending_set_key grub_default_hash "$default_hash" || return 1
    PENDING_GRUB_CFG_HASH=$cfg_hash
    PENDING_GRUB_DEFAULT_HASH=$default_hash
    return 0
}

apply_cachyos_theme_to_pending_grub() {
    validate_pending_compatibility || { fail "Pending migration is not compatible: $PENDING_REASON"; return 1; }
    [[ $PENDING_SOURCE == limine && $PENDING_TARGET == grub ]] || { fail 'Theme upgrade is implemented only for Limine -> GRUB'; return 1; }
    [[ $PENDING_PHASE == runtime-validated || $PENDING_PHASE == candidate-ready ]] || {
        fail "Theme upgrade requires candidate-ready/runtime-validated state (current: $PENDING_PHASE)"; return 1;
    }
    r21_theme_required && { ok 'This GRUB candidate already has recorded CachyOS theme parity'; return 0; }

    detect_bootloader
    [[ $BOOTLOADER == "$PENDING_SOURCE" || $BOOTLOADER == "$PENDING_TARGET" ]] || {
        fail 'Current bootloader is neither the recorded source nor target'; return 1;
    }
    run_validation preflight || return 1
    validate_pending_compatibility || return 1
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext must be clear before changing the candidate'; return 1; }
    verify_pending_source_recovery_unchanged || return 1
    verify_pending_candidate_ownership_unchanged || return 1

    printf '\nCachyOS GRUB parity upgrade:\n'
    printf '  Reference package: cachyos-grub-theme\n'
    printf '  Reference theme:   %s\n' "$R21_GRUB_THEME_PATH"
    printf '  grub.cfg will be regenerated, so the old runtime proof will be invalidated.\n'
    printf '  A new one-time GRUB boot + runtime validation is required before FINALIZE.\n\n'
    local answer
    read -r -p 'Type THEME to apply CachyOS GRUB theme parity: ' answer
    [[ $answer == THEME ]] || { printf 'Theme upgrade cancelled.\n'; return 0; }

    sudo pacman -S --needed --noconfirm -- cachyos-grub-theme || { fail 'Could not install/refresh cachyos-grub-theme'; return 1; }
    [[ -f $R21_GRUB_THEME_PATH ]] || { fail "Theme package installed but $R21_GRUB_THEME_PATH is missing"; return 1; }
    r21_write_theme_policy_into_grub_default || return 1
    sudo grub-mkconfig -o /boot/grub/grub.cfg || { fail 'grub-mkconfig failed while applying CachyOS theme parity'; return 1; }

    validate_target_state grub || return 1
    validate_grub_boot_chain migration || return 1
    validate_cachyos_grub_theme || return 1
    verify_pending_source_recovery_unchanged || return 1

    # The candidate changed after its previous successful boot. Refresh only
    # target-owned hashes/manifests and deliberately throw away old runtime
    # certification by returning to candidate-ready.
    r21_refresh_grub_theme_candidate_metadata || return 1
    pending_set_phase candidate-ready || { fail 'Themed candidate is valid but its transaction phase could not be reset'; return 1; }
    PENDING_PHASE=candidate-ready
    verify_pending_candidate_ownership_unchanged || return 1

    capture_grub_diagnostics themed-candidate-pass >/dev/null 2>&1 || true
    printf '\nTHEMED-CANDIDATE-READY. The CachyOS GRUB presentation now matches the captured Calamares reference.\n'
    printf 'The previous unthemed runtime proof is intentionally invalidated.\n'
    if [[ $BOOTLOADER == "$PENDING_SOURCE" ]]; then
        printf 'Use [2] Manage pending/staged migration -> arm one-time GRUB test boot.\n'
    else
        printf 'You are still running the old GRUB session. Reboot normally to the source Limine entry first, then arm the new one-time GRUB test.\n'
    fi
}

r21_nvram_ids_for_esp_path() {
    local expected=$1 partuuid line id lower expected_lower
    partuuid=$(lsblk -no PARTUUID -- "$PENDING_ESP_SOURCE" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)
    expected_lower=${expected,,}
    while IFS= read -r line; do
        [[ $line =~ ^Boot([0-9A-Fa-f]{4})\*? ]] || continue
        id=${BASH_REMATCH[1]^^}
        lower=${line,,}
        [[ $lower == *"$expected_lower"* ]] || continue
        if [[ -n $partuuid && $lower != *"${partuuid,,}"* ]]; then
            continue
        fi
        printf '%s\n' "$id"
    done < <(efibootmgr -v 2>/dev/null)
}

r21_promote_target_first() {
    local current id joined first
    local -a ids=() current_ids=()
    boot_id_exists "$PENDING_TARGET_BOOT_ID" || { fail 'Target GRUB NVRAM entry disappeared'; return 1; }
    ids+=("$PENDING_TARGET_BOOT_ID")
    current=$(efibootmgr 2>/dev/null | awk -F': ' '/^BootOrder:/ {print toupper($2); exit}')
    IFS=',' read -ra current_ids <<<"$current"
    for id in "${current_ids[@]}"; do
        id=${id^^}
        [[ -n $id && $id != "$PENDING_TARGET_BOOT_ID" ]] || continue
        boot_id_exists "$id" && ids+=("$id")
    done
    joined=$(IFS=,; printf '%s' "${ids[*]}")
    sudo efibootmgr -o "$joined" >/dev/null || return 1
    first=$(pending_bootorder_first)
    [[ $first == "$PENDING_TARGET_BOOT_ID" ]] || { fail 'Could not promote GRUB to first place in persistent BootOrder'; return 1; }
    ok "Persistent BootOrder now starts with target GRUB Boot$PENDING_TARGET_BOOT_ID"
}

r21_remove_owned_limine_source_files() {
    local hash dir
    hash=$(sudo -n sha256sum -- "$PENDING_SOURCE_LIMINE_CONF_PATH" 2>/dev/null | awk '{print $1}' || true)
    [[ $hash == "$PENDING_SOURCE_LIMINE_CONF_HASH" ]] || { fail 'limine.conf changed before finalization'; return 1; }
    sudo rm -f -- "$PENDING_SOURCE_LIMINE_CONF_PATH" || return 1
    ok 'Removed ownership-proven source limine.conf'

    hash=$(sha256sum /etc/default/limine 2>/dev/null | awk '{print $1}' || sudo -n sha256sum /etc/default/limine 2>/dev/null | awk '{print $1}' || true)
    [[ $hash == "$PENDING_SOURCE_LIMINE_DEFAULT_HASH" ]] || { fail '/etc/default/limine changed before finalization'; return 1; }
    sudo rm -f -- /etc/default/limine || return 1
    ok 'Removed ownership-proven source /etc/default/limine'

    hash=$(hash_directory_tree_privileged "$PENDING_SOURCE_LIMINE_MANAGED_DIR" 2>/dev/null || true)
    [[ $hash == "$PENDING_SOURCE_LIMINE_MANAGED_HASH" ]] || { fail 'Limine managed kernel tree changed before finalization'; return 1; }
    sudo rm -rf -- "$PENDING_SOURCE_LIMINE_MANAGED_DIR" || return 1
    ok 'Removed ownership-proven Limine managed kernel tree'

    hash=$(sudo -n sha256sum -- "$PENDING_SOURCE_LIMINE_EFI_RESOLVED" 2>/dev/null | awk '{print $1}' || true)
    [[ $hash == "$PENDING_SOURCE_LIMINE_EFI_HASH" ]] || { fail 'Source Limine EFI executable changed before finalization'; return 1; }
    sudo rm -f -- "$PENDING_SOURCE_LIMINE_EFI_RESOLVED" || return 1
    dir=$(dirname -- "$PENDING_SOURCE_LIMINE_EFI_RESOLVED")
    if sudo rmdir -- "$dir" 2>/dev/null; then
        ok 'Removed now-empty Limine EFI directory'
    else
        info "Limine EFI directory contains additional unproven files and was retained: $dir"
    fi
    return 0
}

r21_finalize_limine_to_grub() {
    validate_pending_compatibility || { fail "Pending migration is not compatible: $PENDING_REASON"; return 1; }
    [[ $PENDING_SOURCE == limine && $PENDING_TARGET == grub ]] || { fail 'Finalization is implemented only for Limine -> GRUB in this transaction engine'; return 1; }
    [[ $PENDING_PHASE == runtime-validated ]] || { fail 'FINALIZE requires runtime-validated state'; return 1; }
    r21_theme_required || { fail 'FINALIZE is locked until the CachyOS-themed GRUB candidate has its own runtime proof'; return 1; }

    detect_bootloader
    [[ $BOOTLOADER == grub && $BOOT_CURRENT == "$PENDING_TARGET_BOOT_ID" ]] || {
        fail "FINALIZE must run from the recorded target GRUB Boot$PENDING_TARGET_BOOT_ID session"; return 1;
    }
    run_validation preflight || return 1
    validate_pending_compatibility || return 1
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext must be clear before FINALIZE'; return 1; }
    pending_validate_running_kernel || return 1
    pending_validate_runtime_cmdline_against_source || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1
    verify_pending_source_recovery_unchanged || return 1

    local fallback_hash answer id current_hash
    local -a fallback_ids=()
    while IFS= read -r id; do [[ -n $id ]] && fallback_ids+=("$id"); done < <(r21_nvram_ids_for_esp_path '\EFI\BOOT\BOOTX64.EFI')
    if [[ $PENDING_OLD_FALLBACK_EXISTED == 1 ]]; then
        fallback_hash=$(sudo -n sha256sum -- "$PENDING_OLD_FALLBACK_PATH" 2>/dev/null | awk '{print $1}' || true)
        [[ $fallback_hash == "$PENDING_OLD_FALLBACK_HASH" ]] || { fail 'Source-owned EFI/BOOT fallback changed; FINALIZE refused'; return 1; }
    else
        if sudo -n test -e "$PENDING_OLD_FALLBACK_PATH" 2>/dev/null || [[ -e $PENDING_OLD_FALLBACK_PATH ]] || ((${#fallback_ids[@]} > 0)); then
            fail 'A generic EFI/BOOT fallback appeared although the recorded source had none; FINALIZE refused'
            return 1
        fi
    fi

    printf '\nFINALIZE Limine -> GRUB:\n'
    printf '  - keep the already runtime-proven themed GRUB Boot%s\n' "$PENDING_TARGET_BOOT_ID"
    printf '  - promote GRUB to first place in persistent BootOrder\n'
    printf '  - remove source Limine Boot%s after exact-path verification\n' "$PENDING_OLD_BOOT_ID"
    printf '  - retire the ownership-proven source EFI/BOOT fallback and matching firmware alias(es)\n'
    printf '  - remove ownership-proven Limine config/managed-kernel state\n'
    printf '  - validate GRUB + CachyOS theme again after cleanup\n'
    printf '  - preserve generic firmware CD/DVD/removable/network entries\n'
    printf '  - leave Limine packages installed but inactive; package removal is NOT mixed into boot-state finalization\n\n'
    if [[ ${R22_AUTO_FINALIZE:-0} == 1 ]]; then
        answer=FINALIZE
        printf 'Automatic resume: prior migration authorization + runtime proof satisfy the FINALIZE confirmation gate.\n'
    else
        read -r -p 'Type FINALIZE to commit GRUB as the sole intended bootloader: ' answer
    fi
    [[ $answer == FINALIZE ]] || { printf 'Finalization cancelled.\n'; return 0; }

    r21_promote_target_first || return 1
    validate_pending_target_deep || { fail 'Target validation failed after BootOrder promotion; source state was not deleted'; return 1; }

    nvram_id_matches_path "$PENDING_OLD_BOOT_ID" "$PENDING_OLD_BOOT_EFI_PATH" || { fail 'Source Limine NVRAM path changed immediately before deletion'; return 1; }
    sudo efibootmgr -b "$PENDING_OLD_BOOT_ID" -B >/dev/null || return 1
    ok "Removed source Limine NVRAM entry Boot$PENDING_OLD_BOOT_ID"

    for id in "${fallback_ids[@]}"; do
        [[ $id != "$PENDING_TARGET_BOOT_ID" ]] || { fail 'Refusing to treat the target GRUB entry as a fallback alias'; return 1; }
        if boot_id_exists "$id"; then
            # The discovery helper already required both current ESP PARTUUID and exact fallback path substring.
            sudo efibootmgr -b "$id" -B >/dev/null || return 1
            ok "Removed source-owned generic UEFI fallback NVRAM entry Boot$id"
        fi
    done
    if [[ $PENDING_OLD_FALLBACK_EXISTED == 1 ]]; then
        current_hash=$(sudo -n sha256sum -- "$PENDING_OLD_FALLBACK_PATH" 2>/dev/null | awk '{print $1}' || true)
        [[ $current_hash == "$PENDING_OLD_FALLBACK_HASH" ]] || { fail 'Fallback payload changed during finalization; refusing deletion'; return 1; }
        sudo rm -f -- "$PENDING_OLD_FALLBACK_PATH" || return 1
        ok 'Removed ownership-proven source EFI/BOOT fallback payload'
    fi

    r21_remove_owned_limine_source_files || return 1

    # Final post-cleanup proof. No source validator is called here because the
    # source has intentionally been retired.
    detect_bootloader
    [[ $BOOTLOADER == grub && $BOOT_CURRENT == "$PENDING_TARGET_BOOT_ID" ]] || { fail 'Current target identity changed during finalization'; return 1; }
    [[ $(pending_bootorder_first) == "$PENDING_TARGET_BOOT_ID" ]] || { fail 'GRUB is not first in persistent BootOrder after finalization'; return 1; }
    boot_id_exists "$PENDING_OLD_BOOT_ID" && { fail 'Source Limine NVRAM entry still exists after deletion'; return 1; }
    [[ -z $(r21_nvram_ids_for_esp_path '\EFI\BOOT\BOOTX64.EFI') ]] || { fail 'A generic EFI/BOOT firmware alias remains on the finalized ESP'; return 1; }
    (sudo -n test ! -e "$PENDING_OLD_FALLBACK_PATH" 2>/dev/null && [[ ! -e $PENDING_OLD_FALLBACK_PATH ]]) || { fail 'EFI/BOOT fallback payload still exists after finalization'; return 1; }
    validate_target_state grub || return 1
    validate_grub_boot_chain current || return 1
    validate_cachyos_grub_theme || return 1

    local diag
    diag=$(pending_capture_runtime_diagnostics finalized-grub | tail -n1 || true)
    [[ -n $diag ]] && printf 'Finalization diagnostic snapshot: %s\n' "$diag"
    remove_pending_transaction_snapshot || warn 'Could not remove private transaction snapshot directory'
    rm -f -- "$PENDING_STATE_FILE"

    printf '\nFINALIZED Limine -> GRUB successfully.\n'
    printf 'GRUB Boot%s is the sole intended managed bootloader and is first in persistent BootOrder.\n' "$PENDING_TARGET_BOOT_ID"
    printf 'The source Limine NVRAM entry and source-owned generic EFI/BOOT fallback were retired.\n'
    printf 'The CachyOS GRUB theme and deep boot-chain validation both pass after cleanup.\n'
    printf 'Limine packages were intentionally left installed/inactive so package-hook side effects do not mutate the runtime-proven GRUB boot artifacts.\n'
}

r21_arm_validated_target_return() {
    validate_pending_compatibility || return 1
    [[ $PENDING_PHASE == runtime-validated ]] || { fail 'A validated target return requires runtime-validated state'; return 1; }
    r21_theme_required || { fail 'Themed runtime proof is not recorded'; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == "$PENDING_SOURCE" && $BOOT_CURRENT == "$PENDING_OLD_BOOT_ID" ]] || { fail 'This helper is available only while the source is active'; return 1; }
    run_validation preflight || return 1
    verify_pending_source_recovery_unchanged || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext is already set'; return 1; }
    local answer
    read -r -p "Type ARM to boot the already-validated GRUB target once for the FINALIZE session: " answer
    [[ $answer == ARM ]] || { printf 'Arming cancelled.\n'; return 0; }
    sudo efibootmgr -n "$PENDING_TARGET_BOOT_ID" >/dev/null || return 1
    [[ $(pending_bootnext_id) == "$PENDING_TARGET_BOOT_ID" ]] || { sudo efibootmgr -N >/dev/null 2>&1 || true; fail 'BootNext verification failed'; return 1; }
    ok "BootNext is armed for target Boot$PENDING_TARGET_BOOT_ID; persistent source-first BootOrder is unchanged"
    printf 'Reboot normally. The switcher can resume this target transaction automatically when its temporary resume service is armed.\n'
}

# r21 replaces only the menu dispatcher. The underlying r20 arming/runtime/
# rollback functions remain in force.
manage_pending_migration() {
    pending_exists || { printf '\nNo pending/staged migration exists.\n'; return 0; }
    validate_pending_compatibility || { printf '\nPending migration state is invalid/incompatible: %s\n' "$PENDING_REASON"; return 1; }
    detect_bootloader
    show_pending_details

    local choice next
    if [[ $BOOTLOADER == "$PENDING_TARGET" ]]; then
        case "$PENDING_PHASE" in
            boot-armed)
                printf '\nThe one-time target boot is running now. No source cleanup is allowed.\n'
                printf '[1] Run post-boot runtime validation\n[2] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in 1) validate_pending_target_runtime ;; 2|'') return 0 ;; *) printf 'Invalid selection.\n'; return 1 ;; esac
                ;;
            runtime-validated)
                if [[ $PENDING_SOURCE == limine && $PENDING_TARGET == grub ]]; then
                    if r21_theme_required; then
                        printf '\nThe exact CachyOS-themed GRUB state has runtime proof. FINALIZE is now eligible.\n'
                        printf '[1] Re-run runtime validation\n'
                        printf '[2] FINALIZE Limine -> GRUB\n'
                        printf '[3] Back\n\n'
                        read -r -p 'Select an option: ' choice
                        case "$choice" in 1) validate_pending_target_runtime ;; 2) r21_finalize_limine_to_grub ;; 3|'') return 0 ;; *) printf 'Invalid selection.\n'; return 1 ;; esac
                    else
                        printf '\nThis is the r20 unthemed runtime proof. GRUB booted, but CachyOS presentation parity has not been proven.\n'
                        printf '[1] Apply CachyOS GRUB theme parity (invalidates this runtime proof)\n'
                        printf '[2] Re-run current unthemed runtime validation\n'
                        printf '[3] Back\n\n'
                        read -r -p 'Select an option: ' choice
                        case "$choice" in 1) apply_cachyos_theme_to_pending_grub ;; 2) validate_pending_target_runtime ;; 3|'') return 0 ;; *) printf 'Invalid selection.\n'; return 1 ;; esac
                    fi
                else
                    printf '\nRuntime proof is recorded, but finalization is not implemented for this direction.\n'
                    printf '[1] Re-run runtime validation\n[2] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in 1) validate_pending_target_runtime ;; 2|'') return 0 ;; *) printf 'Invalid selection.\n'; return 1 ;; esac
                fi
                ;;
            candidate-ready)
                printf '\nThe target is active but the current candidate has no accepted runtime proof.\n'
                printf 'Reboot normally to the source (still first in BootOrder), then arm the test from this menu.\n'
                return 1
                ;;
        esac
    elif [[ $BOOTLOADER == "$PENDING_SOURCE" ]]; then
        case "$PENDING_PHASE" in
            candidate-ready)
                printf '\nThe source %s bootloader is active and the candidate is parked.\n' "$(bootloader_display_name "$PENDING_SOURCE")"
                printf '[1] Re-run deep validation of the staged %s candidate\n' "$(bootloader_display_name "$PENDING_TARGET")"
                printf '[2] Arm one-time test boot to %s (BootNext only)\n' "$(bootloader_display_name "$PENDING_TARGET")"
                printf '[3] Roll back the staged %s candidate\n' "$(bootloader_display_name "$PENDING_TARGET")"
                printf '[4] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) run_validation preflight && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep ;;
                    2) arm_pending_one_time_boot ;;
                    3) rollback_pending_candidate ;;
                    4|'') return 0 ;;
                    *) printf 'Invalid selection.\n'; return 1 ;;
                esac
                ;;
            boot-armed)
                next=$(pending_bootnext_id)
                if [[ $next == "$PENDING_TARGET_BOOT_ID" ]]; then
                    printf '\nOne-time target boot is ARMED and waiting for the next reboot.\n'
                    printf '[1] Re-check source/candidate integrity\n[2] Cancel BootNext\n[3] Roll back candidate\n[4] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in 1) run_validation preflight && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged ;; 2) cancel_pending_one_time_boot ;; 3) rollback_pending_candidate ;; 4|'') return 0 ;; *) printf 'Invalid selection.\n'; return 1 ;; esac
                elif [[ -z $next ]]; then
                    printf '\nThe one-time request was consumed/cleared and no target runtime success was recorded.\n'
                    printf '[1] Revalidate and return to candidate-ready\n[2] Roll back candidate\n[3] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in 1) reset_consumed_test_to_candidate_ready ;; 2) rollback_pending_candidate ;; 3|'') return 0 ;; *) printf 'Invalid selection.\n'; return 1 ;; esac
                else
                    printf '\nBootNext belongs to unrelated Boot%s. The transaction will not touch it.\n' "$next"; return 1
                fi
                ;;
            runtime-validated)
                if [[ $PENDING_SOURCE == limine && $PENDING_TARGET == grub ]]; then
                    if r21_theme_required; then
                        printf '\nThe themed GRUB runtime proof is recorded, but the source is active again.\n'
                        printf 'FINALIZE is deliberately allowed only from the target GRUB session.\n'
                        printf '[1] Arm one-time return to validated GRUB for FINALIZE\n'
                        printf '[2] Re-check source/candidate ownership\n'
                        printf '[3] Roll back/abandon target\n'
                        printf '[4] Back\n\n'
                        read -r -p 'Select an option: ' choice
                        case "$choice" in 1) r21_arm_validated_target_return ;; 2) run_validation preflight && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged ;; 3) rollback_pending_candidate ;; 4|'') return 0 ;; *) printf 'Invalid selection.\n'; return 1 ;; esac
                    else
                        printf '\nThe r20 GRUB runtime proof is recorded, but that candidate was unthemed.\n'
                        printf '[1] Apply CachyOS GRUB theme parity and require a fresh one-time test\n'
                        printf '[2] Re-check source/candidate ownership\n'
                        printf '[3] Roll back/abandon target\n'
                        printf '[4] Back\n\n'
                        read -r -p 'Select an option: ' choice
                        case "$choice" in 1) apply_cachyos_theme_to_pending_grub ;; 2) run_validation preflight && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged ;; 3) rollback_pending_candidate ;; 4|'') return 0 ;; *) printf 'Invalid selection.\n'; return 1 ;; esac
                    fi
                else
                    printf '\nA successful target runtime proof is recorded, but finalization is not implemented for this direction.\n'
                    printf '[1] Re-check source/candidate ownership\n[2] Roll back target\n[3] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in 1) run_validation preflight && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged ;; 2) rollback_pending_candidate ;; 3|'') return 0 ;; *) printf 'Invalid selection.\n'; return 1 ;; esac
                fi
                ;;
        esac
    else
        printf '\nCurrent bootloader is neither the recorded source nor target. Pending migration management is refused.\n'
        return 1
    fi
}
