#!/usr/bin/env bash

restore_copy_from_backup() {
    local dir=$1 rel=$2 src dst
    src="$dir/files/${rel#/}"
    dst="/$rel"
    [[ -e $src || -L $src ]] || return 0
    sudo mkdir -p -- "$(dirname -- "$dst")" || return 1
    # Restore the backed-up object at the exact path, not as a nested child
    # when the destination directory already exists. /etc/fstab is never a
    # writable restore path in this project.
    if sudo test -e "$dst" 2>/dev/null || sudo test -L "$dst" 2>/dev/null; then
        sudo rm -rf -- "$dst" || return 1
    fi
    sudo cp -a -- "$src" "$dst" || return 1
}

restore_grub_backup() {
    local dir=$1
    if pending_exists; then
        printf 'Restore refused while a staged bootloader migration is pending. Manage or explicitly forget the staged transaction first.\n'
        return 1
    fi
    validate_backup_compatibility "$dir" || { printf 'Restore refused: %s\n' "$BACKUP_COMPATIBILITY_REASON"; return 1; }
    load_backup_metadata "$dir" || return 1
    [[ $bootloader == grub ]] || { printf 'This restore backend requires a GRUB backup.\n'; return 1; }

    printf '\nGRUB restore preflight:\n'
    run_validation preflight || return 1
    printf '\nRestore plan:\n'
    printf '  - Restore backed-up /etc/default/grub and /etc/grub.d when present.\n'
    printf '  - Restore backed-up /boot/grub payload when present, then regenerate grub.cfg.\n'
    printf '  - Install/refresh grub + grub-hook with pacman --needed.\n'
    printf '  - Rebuild initramfs with mkinitcpio -P.\n'
    printf '  - Reinstall GRUB to the CURRENT validated ESP mount: %s.\n' "$ESP_MOUNT"
    printf '  - Recreate/refresh the cachyos NVRAM entry through grub-install.\n'
    printf '  - /etc/fstab is reference-only and will NOT be restored.\n'
    printf '  - Unrelated EFI/NVRAM entries will NOT be deleted.\n'
    read -r -p 'Type RESTORE to execute, or anything else to cancel: ' ans
    [[ $ans == RESTORE ]] || { printf 'Restore cancelled.\n'; return 0; }

    sudo pacman -S --needed --noconfirm -- grub grub-hook cachyos-grub-theme || return 1
    restore_copy_from_backup "$dir" etc/default/grub || return 1
    restore_copy_from_backup "$dir" etc/grub.d || return 1
    restore_copy_from_backup "$dir" boot/grub || return 1
    sudo mkinitcpio -P || return 1
    sudo mkdir -p /boot/grub || return 1
    sudo grub-install --target=x86_64-efi --efi-directory="$ESP_MOUNT" --bootloader-id=cachyos --force || return 1
    sudo grub-mkconfig -o /boot/grub/grub.cfg || return 1

    if validate_target_state grub && validate_grub_boot_chain current; then
        if pacman -Q cachyos-grub-theme >/dev/null 2>&1; then validate_cachyos_grub_theme || return 1; fi
        printf '\nRestore validation: PASS\n'
        return 0
    fi
    printf '\nRestore validation: FAIL\n'
    return 1
}

r23_backup_limine_conf_path() {
    local dir=$1 backup_esp_mount=$2 rel
    rel=${backup_esp_mount#/}
    printf '%s/files/%s/limine.conf\n' "$dir" "$rel"
}

r23_backup_limine_splash_path() {
    local dir=$1 backup_esp_mount=$2 rel
    rel=${backup_esp_mount#/}
    printf '%s/files/%s/%s\n' "$dir" "$rel" "$R23_LIMINE_SPLASH_NAME"
}

r23_backup_limine_managed_path() {
    local dir=$1 backup_esp_mount=$2 machine=$3 rel
    rel=${backup_esp_mount#/}
    printf '%s/files/%s/%s\n' "$dir" "$rel" "$machine"
}

r23_limine_backup_theme_is_cachyos() {
    local dir=$1 backup_mount=$2 conf
    conf=$(r23_backup_limine_conf_path "$dir" "$backup_mount")
    [[ -f $conf ]] || return 1
    local line
    for line in \
        '# CachyOS Limine theme' \
        'term_palette: 1e1e2e;f38ba8;a6e3a1;f9e2af;89b4fa;f5c2e7;94e2d5;cdd6f4' \
        'term_palette_bright: 585b70;f38ba8;a6e3a1;f9e2af;89b4fa;f5c2e7;94e2d5;cdd6f4' \
        'term_background: ffffffff' \
        'term_foreground: cdd6f4' \
        'term_background_bright: ffffffff' \
        'term_foreground_bright: cdd6f4' \
        'interface_branding:' \
        'wallpaper: boot():/limine-splash.png'; do
        grep -Fqx -- "$line" "$conf" || return 1
    done
}

r23_backup_limine_cmdline() {
    local dir=$1 raw
    raw=$(sed -nE 's/^[[:space:]]*KERNEL_CMDLINE\[default\]\+=[[:space:]]*(.*)$/\1/p' "$dir/files/etc/default/limine" 2>/dev/null | head -n1)
    [[ -n $raw ]] || return 1
    if [[ $raw == \"*\" && ${#raw} -ge 2 ]]; then raw=${raw:1:${#raw}-2}; fi
    if [[ $raw == \'*\' && ${#raw} -ge 2 ]]; then raw=${raw:1:${#raw}-2}; fi
    printf '%s\n' "$raw"
}

r23_limine_restore_kernel_set_matches() {
    local dir=$1 current backup
    collect_kernels
    current=$(printf '%s\n' "${KERNEL_VERSIONS[@]}" | sed '/^$/d' | LC_ALL=C sort -u)
    backup=$(sed '/^[[:space:]]*$/d' "$dir/kernel-versions.txt" 2>/dev/null | LC_ALL=C sort -u)
    [[ -n $current && $current == "$backup" ]]
}

r23_limine_restore_preflight() {
    local dir=$1 current_cmd backup_cmd
    pending_exists && { fail 'A staged bootloader migration is already pending'; return 1; }
    validate_backup_compatibility "$dir" || { fail "Backup is not compatible: $BACKUP_COMPATIBILITY_REASON"; return 1; }
    load_backup_metadata "$dir" || return 1
    [[ $bootloader == limine ]] || { fail 'Selected backup is not a Limine backup'; return 1; }
    [[ $format_version == 3 || $format_version == 4 ]] || { fail "Limine live restore requires backup format v3 or v4 (found v${format_version:-unknown})"; return 1; }

    detect_bootloader
    [[ $BOOTLOADER == grub ]] || { fail 'Transactional Limine restore currently requires the verified source bootloader to be GRUB'; return 1; }
    run_switch_preflight limine || return 1
    printf '\nSource GRUB deep gate before Limine restore staging:\n'
    validate_grub_boot_chain current || { fail 'Current GRUB source failed deep validation; refusing restore staging'; return 1; }

    # The backup identifies the same ESP by UUID already. Requiring the same
    # mountpoint keeps /etc/default/limine and boot(): paths topology-exact and
    # avoids silently rewriting the backed-up policy.
    [[ ${esp_mount:-} == "$ESP_MOUNT" ]] || {
        fail "Backup ESP mountpoint (${esp_mount:-unknown}) differs from the current validated topology ($ESP_MOUNT)"
        fail 'The switcher refuses to rewrite backup topology during a live restore.'
        return 1
    }
    r23_limine_restore_kernel_set_matches "$dir" || {
        fail 'Installed kernel versions do not exactly match the selected Limine backup.'
        fail 'Restoring a managed payload for a different /usr/lib/modules set could produce an unbootable system.'
        return 1
    }
    r23_limine_backup_theme_is_cachyos "$dir" "$esp_mount" || {
        fail 'Selected Limine backup does not contain the captured CachyOS Limine theme block.'
        return 1
    }
    backup_cmd=$(r23_backup_limine_cmdline "$dir" 2>/dev/null || true)
    current_cmd=$(cat /proc/cmdline 2>/dev/null || true)
    [[ -n $backup_cmd && -n $current_cmd ]] || { fail 'Could not resolve backup/current kernel command line'; return 1; }
    pending_cmdline_equivalent "$backup_cmd" "$current_cmd" || {
        fail 'Backup Limine cmdline is not token-equivalent to the currently proven GRUB runtime cmdline.'
        fail 'Restore is refused rather than changing root/cmdline semantics behind the runtime-proof model.'
        return 1
    }
    if [[ $format_version == 3 ]]; then
        validate_existing_boot_artifacts_for_limine_stage || return 1
        info 'Legacy v3 backup is reconstructable: current kernel versions/cmdline/source artifacts match the backup control state.'
    else
        info 'v4 backup contains the self-contained Limine config, splash and managed kernel/initramfs payload tree.'
    fi
    return 0
}

r23_install_limine_policy_from_backup() {
    local dir=$1 src
    src="$dir/files/etc/default/limine"
    [[ -f $src ]] || { fail 'Backup is missing /etc/default/limine'; return 1; }
    [[ ! -e /etc/default/limine ]] || { fail '/etc/default/limine appeared after preflight'; return 1; }
    sudo install -o root -g root -m 0644 -- "$src" /etc/default/limine || return 1
    LIMINE_DEFAULT_CREATED=1
    LIMINE_DEFAULT_HASH=$(sha256sum /etc/default/limine 2>/dev/null | awk '{print $1}' || sudo -n sha256sum /etc/default/limine 2>/dev/null | awk '{print $1}' || true)
    [[ $LIMINE_DEFAULT_HASH =~ ^[0-9A-Fa-f]{64}$ ]] || { fail 'Could not hash restored /etc/default/limine'; return 1; }
    ok 'Restored backed-up Limine policy to /etc/default/limine'
}

r23_stage_limine_from_v3_backup() {
    local dir=$1 tmp
    r23_install_limine_policy_from_backup "$dir" || return 1
    [[ ! -e "$ESP_MOUNT/limine.conf" ]] || { fail 'limine.conf appeared after preflight'; return 1; }
    tmp=$(mktemp) || return 1
    chmod 600 -- "$tmp" 2>/dev/null || true
    r23_write_cachyos_limine_theme_base "$tmp" "$R23_LIMINE_SPLASH_SOURCE" || { rm -f -- "$tmp"; return 1; }
    sudo install -o root -g root -m 0644 -- "$tmp" "$ESP_MOUNT/limine.conf" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
    r23_install_cachyos_limine_splash "$R23_LIMINE_SPLASH_SOURCE" || return 1
    stage_limine_kernel_entries_from_existing_artifacts || return 1
    ok 'Reconstructed legacy v3 Limine managed payload from the current validated kernel/initramfs artifacts'
}

r23_stage_limine_from_v4_backup() {
    local dir=$1 backup_mount=$2 machine=$3 conf splash managed dst_managed
    conf=$(r23_backup_limine_conf_path "$dir" "$backup_mount")
    splash=$(r23_backup_limine_splash_path "$dir" "$backup_mount")
    managed=$(r23_backup_limine_managed_path "$dir" "$backup_mount" "$machine")
    [[ -f $conf && -f $splash && -d $managed ]] || { fail 'Limine v4 backup payload is incomplete'; return 1; }
    r23_install_limine_policy_from_backup "$dir" || return 1
    [[ ! -e "$ESP_MOUNT/limine.conf" ]] || { fail 'limine.conf appeared after preflight'; return 1; }
    dst_managed="$ESP_MOUNT/$machine"
    [[ ! -e $dst_managed ]] || { fail 'Limine managed payload directory appeared after preflight'; return 1; }
    sudo install -o root -g root -m 0644 -- "$conf" "$ESP_MOUNT/limine.conf" || return 1
    sudo install -o root -g root -m 0644 -- "$splash" "$ESP_MOUNT/$R23_LIMINE_SPLASH_NAME" || return 1
    sudo cp -a -- "$managed" "$dst_managed" || return 1
    ok 'Restored self-contained v4 Limine config, CachyOS splash and managed kernel/initramfs payload tree'
}

r23_stage_limine_restore_candidate() {
    local dir=$1 old_id=$BOOT_CURRENT original_order=$BOOT_ORDER target_id='' install_rc=0
    load_backup_metadata "$dir" || return 1
    local restore_format=$format_version backup_mount=$esp_mount backup_machine=$machine_id

    snapshot_grub_fallback_ownership || return 1
    snapshot_source_boot_artifacts || { [[ -n $TRANSACTION_SNAPSHOT_DIR ]] && rm -rf -- "$TRANSACTION_SNAPSHOT_DIR" 2>/dev/null || true; return 1; }

    if ! install_target_packages limine; then
        [[ -n $TRANSACTION_SNAPSHOT_DIR ]] && rm -rf -- "$TRANSACTION_SNAPSHOT_DIR" 2>/dev/null || true
        return 1
    fi
    have limine-install || { fail 'limine-install is unavailable after package installation'; cleanup_uncommitted_limine_candidate "$original_order" "$old_id"; return 1; }
    have limine-entry-tool || { fail 'limine-entry-tool is unavailable after package installation'; cleanup_uncommitted_limine_candidate "$original_order" "$old_id"; return 1; }

    case "$restore_format" in
        3) r23_stage_limine_from_v3_backup "$dir" || { cleanup_uncommitted_limine_candidate "$original_order" "$old_id"; return 1; } ;;
        4) r23_stage_limine_from_v4_backup "$dir" "$backup_mount" "$backup_machine" || { cleanup_uncommitted_limine_candidate "$original_order" "$old_id"; return 1; } ;;
        *) cleanup_uncommitted_limine_candidate "$original_order" "$old_id"; fail 'Unsupported Limine restore format'; return 1 ;;
    esac

    sudo limine-install || install_rc=$?
    if ((install_rc == 0)); then sudo limine-install --fallback || install_rc=$?; fi

    if find_nvram_entry_for_target limine; then
        target_id=$TARGET_NVRAM_ID
        if ! set_source_first_boot_order "$old_id" "$target_id" "$original_order"; then
            fail 'Could not restore source GRUB as first in persistent BootOrder after Limine restore staging.'
            cleanup_uncommitted_limine_candidate "$original_order" "$old_id"
            return 1
        fi
    else
        [[ -n $original_order ]] && sudo efibootmgr -o "$original_order" >/dev/null 2>&1 || true
    fi

    if ((install_rc != 0)); then
        fail "limine-install exited with status $install_rc during backup restore staging."
        cleanup_uncommitted_limine_candidate "$original_order" "$old_id"
        return 1
    fi
    [[ -n $target_id ]] || { fail 'Limine NVRAM entry was not created at the exact expected EFI path'; cleanup_uncommitted_limine_candidate "$original_order" "$old_id"; return 1; }

    printf '\nSource recovery invariants after restore candidate generation:\n'
    verify_source_grub_recovery_state "$old_id" || { cleanup_uncommitted_limine_candidate "$original_order" "$old_id"; return 1; }
    verify_source_boot_artifacts_unchanged || { cleanup_uncommitted_limine_candidate "$original_order" "$old_id"; return 1; }
    validate_target_state limine || { cleanup_uncommitted_limine_candidate "$original_order" "$old_id"; return 1; }
    validate_limine_boot_chain migration || { cleanup_uncommitted_limine_candidate "$original_order" "$old_id"; return 1; }
    validate_cachyos_limine_theme || { cleanup_uncommitted_limine_candidate "$original_order" "$old_id"; return 1; }

    find_nvram_entry_for_target limine || { cleanup_uncommitted_limine_candidate "$original_order" "$old_id"; return 1; }
    [[ $TARGET_NVRAM_ID == "$target_id" ]] || { fail 'Limine NVRAM identity changed during restore validation'; cleanup_uncommitted_limine_candidate "$original_order" "$old_id"; return 1; }
    verify_source_grub_recovery_state "$old_id" || { cleanup_uncommitted_limine_candidate "$original_order" "$old_id"; return 1; }
    snapshot_limine_candidate_metadata || { cleanup_uncommitted_limine_candidate "$original_order" "$old_id"; return 1; }

    OPERATION_BACKUP=$dir
    capture_limine_diagnostics restore-candidate-pass >/dev/null 2>&1 || true
    if ! write_pending_grub_to_limine "$old_id" "$original_order" "$target_id" candidate-ready; then
        fail 'Could not persist the restored Limine candidate transaction metadata.'
        cleanup_uncommitted_limine_candidate "$original_order" "$old_id"
        return 1
    fi

    printf '\nRESTORE-CANDIDATE-READY. Source GRUB is still first; no source cleanup has occurred.\n'
    printf 'The restored CachyOS-themed Limine candidate passed structural + deep validation.\n'
    r23_after_fresh_grub_to_limine_candidate
}

restore_limine_backup() {
    local dir=$1 ans
    r23_limine_restore_preflight "$dir" || return 1
    load_backup_metadata "$dir" || return 1

    printf '\nLimine restore transaction plan:\n'
    if [[ $format_version == 3 ]]; then
        printf '  - Legacy v3: restore the backed-up Limine policy and reconstruct kernel entries/payload from the CURRENT deeply validated GRUB kernel/initramfs artifacts.\n'
        printf '  - Apply the captured CachyOS Limine palette and the canonical CachyOS limine-splash.png.\n'
    else
        printf '  - v4: restore the backed-up Limine policy, limine.conf, CachyOS splash and complete managed kernel/initramfs payload tree.\n'
    fi
    printf '  - Install/refresh limine + limine-mkinitcpio-hook + cachyos-wallpapers.\n'
    printf '  - Install Limine at the detected ESP and refresh the standard EFI fallback.\n'
    printf '  - Keep current GRUB first while the candidate is validated.\n'
    printf '  - Automatically arm a one-time Limine BootNext and install the temporary resume service.\n'
    printf '  - Prompt before rebooting. After a proven Limine boot, automatically finalize and remove only ownership-proven GRUB state.\n'
    printf '  - /etc/fstab is reference-only and will NOT be restored or rewritten.\n'
    printf '  - No firmware-menu selection should be necessary.\n\n'

    offer_operation_backup || return 1
    read -r -p 'Type RESTORE to stage this validated Limine backup, or anything else to cancel: ' ans
    [[ $ans == RESTORE ]] || { printf 'Restore cancelled. No boot state was modified by the restore.\n'; return 0; }
    r23_stage_limine_restore_candidate "$dir"
}

restore_backup_interactive() {
    discover_backups_quiet
    ((${#DISCOVERED_BACKUPS[@]})) || { printf '\nNo backups found.\n'; return 0; }
    printf '\n'; list_backups; printf '\n'
    read -r -p 'Select backup number to restore, or Enter to cancel: ' n
    [[ -n $n ]] || return 0
    [[ $n =~ ^[0-9]+$ ]] && ((n>=1 && n<=${#DISCOVERED_BACKUPS[@]})) || { printf 'Invalid selection.\n'; return 1; }
    local dir=${DISCOVERED_BACKUPS[n-1]}
    validate_backup_compatibility "$dir" || { printf 'Restore refused: %s\n' "$BACKUP_COMPATIBILITY_REASON"; return 1; }
    load_backup_metadata "$dir" || return 1
    case "$bootloader" in
        grub) restore_grub_backup "$dir" ;;
        limine) restore_limine_backup "$dir" ;;
        *) printf 'Live restore for %s backups is not implemented in this release.\n' "$bootloader"; return 2 ;;
    esac
}
