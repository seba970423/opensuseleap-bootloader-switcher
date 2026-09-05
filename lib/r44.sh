#!/usr/bin/env bash
# r44: close the missing interactive restore-dispatch edge exposed by
# sequential real-hardware sanity testing: rEFInd -> restored GRUB.
#
# r43 correctly refused this direction because its interactive restore matrix
# never routed refind:grub.  This is a coverage gap, not a new transaction
# design problem:
#
# - the r26 format-v5 pending parser already admits refind:grub because the
#   direct live rEFInd -> GRUB adapter path is hardware-proven;
# - r33 already defines rEFInd source ownership so mutable EFI/refind/vars is
#   excluded from immutable proof while the rest of the source stays exact;
# - r31's GRUB v3/v4 restore-target contract is source-generic through the r30
#   common preflight and shared restored-adapter executor;
# - r26 already knows how to runtime-validate/promote GRUB and retire only
#   ownership-proven rEFInd source state after a proven GRUB userspace boot.
#
# Therefore r44 changes only the restore allowlist/dispatcher.  It deliberately
# does not widen the pending-state schema or invent another GRUB restore engine.

# Preserve the inherited restore routes and add exactly the missing
# rEFInd -> GRUB dispatcher/allowlist edge. r46 later repairs the separate
# historical grub:refind support-predicate omission.
eval "$(declare -f r30_cross_restore_supported | sed '1s/r30_cross_restore_supported/r30_cross_restore_supported_pre_r44/')"
r30_cross_restore_supported() {
    case "$1:$2" in
        refind:grub) return 0 ;;
        *) r30_cross_restore_supported_pre_r44 "$@" ;;
    esac
}

# Keep every inherited route byte-for-byte equivalent and route only the new
# rEFInd -> restored-GRUB case through r31/r30's already-existing generic GRUB
# restore target executor.
restore_backup_interactive() {
    discover_backups_quiet
    ((${#DISCOVERED_BACKUPS[@]})) || { printf '\nNo backups found.\n'; return 0; }
    printf '\n'; list_backups; printf '\n'
    read -r -p 'Select backup number to restore, or Enter to cancel: ' n
    [[ -n $n ]] || return 0
    [[ $n =~ ^[0-9]+$ ]] && ((n>=1 && n<=${#DISCOVERED_BACKUPS[@]})) || { printf 'Invalid selection.\n'; return 1; }
    local dir=${DISCOVERED_BACKUPS[n-1]} target source
    validate_backup_compatibility "$dir" || { printf 'Restore refused: %s\n' "$BACKUP_COMPATIBILITY_REASON"; return 1; }
    load_backup_metadata "$dir" || return 1
    target=$bootloader
    detect_bootloader
    source=$BOOTLOADER

    if [[ $source == "$target" ]]; then
        printf '\nSame-backend %s restore is not enabled as a fake switch transaction.\n' "$(bootloader_display_name "$target")"
        if [[ $target == grub ]]; then printf 'Use GRUB repair/reinstall for the current bootloader instead.\n'; fi
        return 2
    fi

    case "$source:$target" in
        limine:grub) restore_grub_backup "$dir" ;;
        grub:limine) restore_limine_backup "$dir" ;;
        grub:systemd-boot) restore_systemd_boot_backup "$dir" ;;
        systemd-boot:grub) r30_restore_grub_backup "$dir" ;;
        systemd-boot:limine) r30_restore_limine_backup "$dir" ;;
        limine:systemd-boot) r30_restore_systemd_boot_backup "$dir" ;;
        grub:refind|limine:refind|systemd-boot:refind) r38_restore_refind_backup "$dir" ;;
        refind:grub) r30_restore_grub_backup "$dir" ;;
        refind:limine) r30_restore_limine_backup "$dir" ;;
        refind:systemd-boot) r30_restore_systemd_boot_backup "$dir" ;;
        *)
            printf 'Cross-backend restore %s -> %s is not enabled in %s.\n' "$(bootloader_display_name "$source")" "$(bootloader_display_name "$target")" "${SWITCHER_RELEASE:-r44}"
            return 2
            ;;
    esac
}
