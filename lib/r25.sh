#!/usr/bin/env bash

# r25 keeps the proven r22/r23 internal state-machine implementation names for
# compatibility, but removes release-number leakage from user-visible output
# and upgrades GRUB backup restore to the same transaction/runtime-proof model.

R25_GRUB_RESTORE_DIR=""
R25_GRUB_RESIDUE_DEFAULT=0
R25_GRUB_RESIDUE_TREE=0

# r24's old direct restore could copy the GRUB backup bytes to the inactive
# target namespace and then fail only while trying to preserve Unix ownership
# metadata on VFAT. That leaves no GRUB firmware entry, but it can leave an
# exact/subset copy of the selected backup under /boot/grub plus the selected
# /etc/default/grub. Recognize only residue whose ownership can be proven from
# the selected validated backup; unknown target bytes remain a hard stop.
r25_probe_failed_grub_restore_residue() {
    local dir=$1 backup_default="$dir/files/etc/default/grub" backup_tree="$dir/files/boot/grub"
    local cur rel backed listing rc=0
    R25_GRUB_RESIDUE_DEFAULT=0
    R25_GRUB_RESIDUE_TREE=0

    if [[ -e /etc/default/grub || -L /etc/default/grub ]]; then
        [[ -f $backup_default && ! -L $backup_default ]] || {
            fail 'A pre-existing /etc/default/grub exists, but the selected backup cannot prove its identity.'
            return 1
        }
        sudo cmp -s -- /etc/default/grub "$backup_default" || {
            fail 'Pre-existing /etc/default/grub does not byte-match the selected validated GRUB backup.'
            fail 'Refusing to classify it as failed-restore residue.'
            return 1
        }
        R25_GRUB_RESIDUE_DEFAULT=1
        info 'Detected ownership-proven /etc/default/grub residue from the selected GRUB backup.'
    fi

    if sudo test -e /boot/grub 2>/dev/null || sudo test -L /boot/grub 2>/dev/null; then
        sudo test -d /boot/grub 2>/dev/null || { fail 'Pre-existing /boot/grub is not a directory; ownership is ambiguous.'; return 1; }
        [[ -d $backup_tree ]] || { fail 'Selected GRUB backup has no /boot/grub tree to prove the pre-existing target residue.'; return 1; }

        listing=$(mktemp) || { fail 'Could not allocate a temporary ownership-scan file.'; return 1; }
        if ! sudo find -P /boot/grub -mindepth 1 -print0 >"$listing"; then
            rm -f -- "$listing"
            fail 'Could not enumerate the pre-existing /boot/grub tree for ownership proof.'
            return 1
        fi

        while IFS= read -r -d '' cur; do
            rel=${cur#/boot/grub/}
            backed="$backup_tree/$rel"
            if sudo test -L "$cur" 2>/dev/null; then
                fail "Pre-existing /boot/grub residue contains a symlink and cannot be proven safe: $cur"
                rc=1; break
            elif sudo test -d "$cur" 2>/dev/null; then
                [[ -d $backed && ! -L $backed ]] || {
                    fail "Pre-existing GRUB directory is not present in the selected backup: $cur"
                    rc=1; break
                }
            elif sudo test -f "$cur" 2>/dev/null; then
                [[ -f $backed && ! -L $backed ]] || {
                    fail "Pre-existing GRUB file is not present in the selected backup: $cur"
                    rc=1; break
                }
                sudo cmp -s -- "$cur" "$backed" || {
                    fail "Pre-existing GRUB file differs from the selected validated backup: $cur"
                    rc=1; break
                }
            else
                fail "Unsupported object exists in pre-existing /boot/grub residue: $cur"
                rc=1; break
            fi
        done <"$listing"
        rm -f -- "$listing"
        ((rc == 0)) || return 1

        R25_GRUB_RESIDUE_TREE=1
        info 'Detected ownership-proven /boot/grub residue whose existing files are a byte-identical subset of the selected backup.'
    fi
    return 0
}

r25_grub_restore_readonly_preflight() {
    local dir=$1 ver kid kernel_target initrd_target
    printf '\nGRUB restore preflight:\n'
    run_validation preflight || return 1
    is_cachyos || { fail 'This restore backend is intentionally restricted to CachyOS/Arch-like systems.'; return 1; }
    have sudo || { fail 'sudo is required for bootloader changes'; return 1; }
    have pacman || { fail 'pacman is required for the CachyOS backend'; return 1; }
    pending_exists && { fail 'A staged bootloader migration is already pending.'; return 1; }
    [[ -z ${BOOT_NEXT:-} ]] || { fail "UEFI BootNext is already set to Boot${BOOT_NEXT^^}; refusing to overwrite it."; return 1; }

    printf '\nSource Limine gate before GRUB restore staging:\n'
    validate_limine_boot_chain current || {
        fail 'The active Limine source does not pass the known-good deep validator; refusing GRUB restore staging.'
        return 1
    }

    if find_nvram_entry_for_target grub; then
        fail "An existing GRUB NVRAM entry (Boot$TARGET_NVRAM_ID) already exists before restore staging."
        fail 'Target ownership is ambiguous; refusing to reuse it automatically.'
        return 1
    fi
    if path_exists_on_esp_privileged "$(target_expected_efi_path grub)"; then
        fail 'A GRUB EFI executable already exists on the ESP before restore staging.'
        return 1
    fi
    if sudo -n test -e "$ESP_MOUNT/EFI/CACHYOS" 2>/dev/null || [[ -e $ESP_MOUNT/EFI/CACHYOS ]]; then
        fail "The target GRUB EFI namespace already exists before restore staging: $ESP_MOUNT/EFI/CACHYOS"
        return 1
    fi

    r25_probe_failed_grub_restore_residue "$dir" || return 1

    collect_kernels
    for ver in "${KERNEL_VERSIONS[@]}"; do
        kid=$(kernel_pkgbase_for_version "$ver" 2>/dev/null || true)
        [[ -n $kid ]] || { fail "Could not resolve pkgbase for installed kernel $ver"; return 1; }
        kernel_target="/boot/vmlinuz-$kid"
        initrd_target="/boot/initramfs-$kid.img"
        if sudo -n test -e "$kernel_target" 2>/dev/null || [[ -e $kernel_target ]]; then
            validate_preexisting_grub_artifact_against_limine "$kid" "$ver" path "$kernel_target" || return 1
        else
            info "Conventional GRUB kernel artifact is absent and may be transaction-created later: $kernel_target"
        fi
        if sudo -n test -e "$initrd_target" 2>/dev/null || [[ -e $initrd_target ]]; then
            validate_preexisting_grub_artifact_against_limine "$kid" "$ver" module_path "$initrd_target" || return 1
        else
            info "Conventional GRUB initramfs artifact is absent and may be transaction-created later: $initrd_target"
        fi
    done
    return 0
}

r25_remove_proven_grub_restore_residue() {
    local dir=$1
    # Re-probe immediately before deletion so no stale preflight decision can
    # authorize removing bytes that changed while the confirmation prompt was
    # displayed.
    r25_probe_failed_grub_restore_residue "$dir" || return 1
    if ((R25_GRUB_RESIDUE_DEFAULT)); then
        sudo rm -f -- /etc/default/grub || return 1
        ok 'Removed ownership-proven failed-restore /etc/default/grub residue'
    fi
    if ((R25_GRUB_RESIDUE_TREE)); then
        sudo rm -rf -- /boot/grub || return 1
        ok 'Removed ownership-proven failed-restore /boot/grub residue'
    fi
    return 0
}

r25_grub_backup_kernel_set_matches() {
    local dir=$1 current backup
    collect_kernels
    current=$(printf '%s\n' "${KERNEL_VERSIONS[@]}" | sed '/^$/d' | LC_ALL=C sort -u)
    backup=$(sed '/^[[:space:]]*$/d' "$dir/kernel-versions.txt" 2>/dev/null | LC_ALL=C sort -u)
    [[ -n $current && $current == "$backup" ]]
}

r25_validate_grub_backup_policy() {
    local dir=$1 src="$dir/files/etc/default/grub"
    [[ -f $src ]] || { fail 'GRUB backup is missing /etc/default/grub'; return 1; }
    grep -Fqx 'GRUB_THEME="/usr/share/grub/themes/cachyos/theme.txt"' "$src" || {
        fail 'GRUB backup policy does not reference the captured CachyOS theme path.'
        return 1
    }
    grep -Eq '^GRUB_DEFAULT=0$' "$src" || {
        fail 'GRUB backup policy is missing deterministic GRUB_DEFAULT=0.'
        return 1
    }
    return 0
}

r25_install_grub_policy_from_backup() {
    local dir=$1 src="$dir/files/etc/default/grub"
    [[ -f $src ]] || { fail 'GRUB backup policy disappeared before staging'; return 1; }
    # Preflight proved there was no source-owned /etc/default/grub. Installing
    # the grub package may create its packaged default; replacing only that
    # policy file with the integrity-validated backup is ownership-safe.
    sudo install -o root -g root -m 0644 -- "$src" /etc/default/grub || return 1
    GRUB_DEFAULT_CREATED=1
    GRUB_DEFAULT_HASH=$(sha256sum /etc/default/grub 2>/dev/null | awk '{print $1}' || sudo -n sha256sum /etc/default/grub 2>/dev/null | awk '{print $1}' || true)
    [[ $GRUB_DEFAULT_HASH =~ ^[0-9A-Fa-f]{64}$ ]] || { fail 'Could not hash restored /etc/default/grub'; return 1; }
    ok 'Restored the integrity-validated GRUB policy from backup'
    info 'Generated /boot/grub modules/config are rebuilt from the current CachyOS GRUB packages instead of copying stale generated payload bytes.'
}

# Save the proven normal Limine -> GRUB policy generator, then make restore
# staging select the backed-up policy without duplicating the transaction code.
eval "$(declare -f write_grub_candidate_policy | sed '1s/write_grub_candidate_policy/write_grub_candidate_policy_pre_r25/')"
write_grub_candidate_policy() {
    if [[ -n ${R25_GRUB_RESTORE_DIR:-} ]]; then
        r25_install_grub_policy_from_backup "$R25_GRUB_RESTORE_DIR"
    else
        write_grub_candidate_policy_pre_r25 "$@"
    fi
}

# FAT/VFAT has no Unix uid/gid/mode/xattr semantics. Any generic restore helper
# that writes into the ESP must restore bytes/tree shape, not archive metadata.
eval "$(declare -f restore_copy_from_backup | sed '1s/restore_copy_from_backup/restore_copy_from_backup_pre_r25/')"
restore_copy_from_backup() {
    local dir=$1 rel=$2 src dst esp_prefix
    src="$dir/files/${rel#/}"
    dst="/$rel"
    [[ -e $src || -L $src ]] || return 0
    esp_prefix=${ESP_MOUNT%/}
    if [[ -n $esp_prefix && ( $dst == "$esp_prefix" || $dst == "$esp_prefix/"* ) ]]; then
        # Symlinks cannot be represented faithfully on the FAT ESP. Refuse
        # rather than silently dereference an unexpected backup object.
        if [[ -d $src ]] && find "$src" -type l -print -quit 2>/dev/null | grep -q .; then
            fail "ESP restore payload contains a symlink that FAT cannot represent safely: $rel"
            return 1
        fi
        sudo mkdir -p -- "$(dirname -- "$dst")" || return 1
        if sudo test -e "$dst" 2>/dev/null || sudo test -L "$dst" 2>/dev/null; then
            sudo rm -rf -- "$dst" || return 1
        fi
        # -a keeps recursive/no-dereference copy semantics; --no-preserve=all
        # suppresses uid/gid/mode/xattr/timestamp restoration that VFAT rejects.
        sudo cp -a --no-preserve=all -- "$src" "$dst" || return 1
        return 0
    fi
    restore_copy_from_backup_pre_r25 "$@"
}

restore_grub_backup() {
    local dir=$1 ans rc
    pending_exists && {
        printf 'Restore refused while a staged bootloader migration is pending. Manage or roll back that transaction first.\n'
        return 1
    }
    validate_backup_compatibility "$dir" || { printf 'Restore refused: %s\n' "$BACKUP_COMPATIBILITY_REASON"; return 1; }
    load_backup_metadata "$dir" || return 1
    [[ $bootloader == grub ]] || { printf 'This restore backend requires a GRUB backup.\n'; return 1; }

    detect_bootloader
    [[ $BOOTLOADER == limine ]] || {
        fail 'Transactional GRUB backup restore currently requires the verified source bootloader to be Limine.'
        fail 'If GRUB is already current, use the GRUB repair path instead of creating a fake switch transaction.'
        return 1
    }

    # Restore-specific read-only preflight allows only ownership-proven residue
    # from the failed r24 direct-copy backend. Unknown target state is still a
    # hard stop. No bytes are removed before the explicit RESTORE confirmation.
    r25_grub_restore_readonly_preflight "$dir" || return 1
    r25_grub_backup_kernel_set_matches "$dir" || {
        fail 'Installed kernel versions do not exactly match the selected GRUB backup.'
        fail 'Refusing to restore a boot policy against a different installed kernel set.'
        return 1
    }
    r25_validate_grub_backup_policy "$dir" || return 1

    printf '\nTransactional GRUB restore plan:\n'
    printf '  - Restore the validated backed-up /etc/default/grub policy.\n'
    printf '  - Use current CachyOS grub + grub-hook + cachyos-grub-theme packages.\n'
    printf '  - Rebuild generated /boot/grub payload from current packages; do NOT archive-restore Unix ownership metadata onto the VFAT ESP.\n'
    if ((R25_GRUB_RESIDUE_DEFAULT || R25_GRUB_RESIDUE_TREE)); then
        printf '  - Remove only ownership-proven inactive residue left by the older failed direct-copy restore, then re-run the full clean-target preflight.\n'
    fi
    printf '  - Materialize/validate conventional kernel+initramfs artifacts from the active Limine source without mkinitcpio -P.\n'
    printf '  - Keep Limine first while the restored GRUB candidate is deeply validated.\n'
    printf '  - Automatically arm one-time GRUB BootNext and install the temporary resume service.\n'
    printf '  - Prompt before reboot. After a proven GRUB boot, automatically finalize and retire only ownership-proven Limine state.\n'
    printf '  - /etc/fstab remains reference-only and is never rewritten.\n\n'

    offer_operation_backup || return 1
    read -r -p 'Type RESTORE to stage this validated GRUB backup, or anything else to cancel: ' ans
    [[ $ans == RESTORE ]] || { printf 'Restore cancelled. No boot state was modified by the restore.\n'; return 0; }

    # If an older failed restore left only bytes that the selected validated
    # backup proves it owns, retire that inactive residue now, then run the full
    # normal switch preflight against a genuinely clean GRUB target namespace.
    r25_remove_proven_grub_restore_residue "$dir" || return 1
    run_switch_preflight grub || {
        fail 'Full GRUB staging preflight failed after proven residue cleanup. Limine remains the active source.'
        return 1
    }

    R25_GRUB_RESTORE_DIR=$dir
    execute_limine_to_grub
    rc=$?
    R25_GRUB_RESTORE_DIR=""
    return "$rc"
}

# User-visible prompt overrides. Internal r22/r23 function names are retained
# because persisted transaction bundles call them by name.
r22_prompt_reboot() {
    local answer
    printf '\nThe one-time GRUB test is armed and the switcher will resume automatically after reboot.\n'
    printf 'If runtime validation passes, GRUB will be finalized automatically and only ownership-proven Limine state will be retired.\n'
    read -r -p 'Reboot now? [y/N]: ' answer
    case "$answer" in
        y|Y|yes|YES)
            printf 'Rebooting now. No firmware-menu selection is required.\n'
            sudo systemctl reboot
            ;;
        *)
            printf 'Reboot deferred. BootNext and the temporary resume service remain armed for your next normal reboot.\n'
            ;;
    esac
}

r23_prompt_reboot() {
    local answer
    printf '\nThe one-time %s test is armed and the switcher will resume automatically after reboot.\n' "$(bootloader_display_name "$PENDING_TARGET")"
    printf 'If runtime validation passes, %s will be finalized automatically and only ownership-proven %s state will be retired.\n' "$(bootloader_display_name "$PENDING_TARGET")" "$(bootloader_display_name "$PENDING_SOURCE")"
    read -r -p 'Reboot now? [y/N]: ' answer
    case "$answer" in
        y|Y|yes|YES)
            printf 'Rebooting now. No firmware-menu selection is required.\n'
            sudo systemctl reboot
            ;;
        *)
            printf 'Reboot deferred. BootNext and the temporary resume service remain armed for your next normal reboot.\n'
            ;;
    esac
}
