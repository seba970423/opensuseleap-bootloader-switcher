#!/usr/bin/env bash
# r43: enable the final two cross-backend backup-restore directions.
#
# Newly enabled restore-only edges:
#   rEFInd       -> restored systemd-boot v4
#   systemd-boot -> restored rEFInd v4
#
# No new payload or finalization engine is introduced here. Both directions
# compose contracts already exercised on hardware by the corresponding live
# rEFInd <-> systemd-boot migrations:
#
# - restored systemd-boot keeps the r28/r30 v4 owned-payload contract, foreign
#   BLS preservation, source-first BootOrder, one-time BootNext, runtime proof,
#   and ownership-gated source retirement;
# - restored rEFInd keeps the r35/r38 immutable-tree contract, deliberately
#   omits stale EFI/refind/vars, and requires fresh PreviousBoot direct-kernel
#   evidence before the systemd-boot source may be retired.
#
# r41 already taught the format-v5 pending parser to admit both directed
# rEFInd/systemd-boot pairs for live migrations. Restore transactions use the
# same source/target state format, so no pending-state schema widening is needed.

# Open exactly the final two restore matrix edges while preserving every
# inherited GRUB/Limine/systemd-boot and Limine/rEFInd route.
eval "$(declare -f r30_cross_restore_supported | sed '1s/r30_cross_restore_supported/r30_cross_restore_supported_pre_r43/')"
r30_cross_restore_supported() {
    case "$1:$2" in
        refind:systemd-boot|systemd-boot:refind) return 0 ;;
        *) r30_cross_restore_supported_pre_r43 "$@" ;;
    esac
}

# r38 generalized the strict rEFInd-v4 target contract from GRUB to Limine.
# Intercept only the newly certified source family here; GRUB/Limine keep the
# inherited implementation byte-for-byte.
eval "$(declare -f r35_refind_restore_preflight | sed '1s/r35_refind_restore_preflight/r35_refind_restore_preflight_pre_r43/')"
r43_refind_restore_preflight_from_systemd_boot() {
    local dir=$1 reference
    pending_exists && { fail 'A staged bootloader migration is already pending'; return 1; }
    validate_backup_compatibility "$dir" || { fail "Backup is not compatible: $BACKUP_COMPATIBILITY_REASON"; return 1; }
    load_backup_metadata "$dir" || { fail 'Could not load selected backup metadata'; return 1; }
    [[ ${bootloader:-} == refind ]] || { fail 'Selected backup is not a rEFInd backup'; return 1; }

    detect_bootloader
    [[ $BOOTLOADER == systemd-boot ]] || {
        fail 'r43 systemd-boot-source rEFInd restore preflight was entered from the wrong source bootloader.'
        return 1
    }

    printf '\n%s rEFInd restore preflight:\n' "${SWITCHER_RELEASE:-r43}"
    run_validation preflight || { fail 'Base preflight failed; no boot state was modified'; return 1; }
    is_cachyos || { fail 'rEFInd live restore is intentionally restricted to CachyOS/Arch-like systems'; return 1; }
    if bootcurrent_is_generic_fallback; then
        fail 'The current session was booted through the generic UEFI fallback path.'
        fail 'Restore transactions require the canonical systemd-boot source NVRAM entry; reboot normally first.'
        return 1
    fi
    have sudo && have pacman || { fail 'sudo and pacman are required'; return 1; }
    [[ -z ${BOOT_NEXT:-} ]] || { fail "BootNext is already set to Boot${BOOT_NEXT^^}; refusing to overwrite firmware intent"; return 1; }

    printf '\nSource adapter deep gate (systemd-boot):\n'
    adapter_source_validate systemd-boot || { fail 'The active systemd-boot source failed deep validation; rEFInd restore staging is refused'; return 1; }
    r26_target_namespace_clean refind || return 1

    load_backup_metadata "$dir" || return 1
    [[ ${format_version:-} == 4 ]] || { fail "rEFInd live restore requires backup format v4 (found v${format_version:-unknown})"; return 1; }
    [[ ${esp_mount:-} == "$ESP_MOUNT" ]] || {
        fail "Backup ESP mountpoint (${esp_mount:-unknown}) differs from the current validated topology ($ESP_MOUNT)."
        fail 'The switcher refuses to rewrite backup topology during a live restore.'
        return 1
    }
    [[ $ESP_MOUNT == /boot ]] || {
        fail "${SWITCHER_RELEASE:-r43} rEFInd restore currently certifies the CachyOS /boot ESP topology only; detected $ESP_MOUNT."
        return 1
    }
    r35_refind_backup_kernel_set_matches "$dir" || {
        fail 'Installed kernel versions do not exactly match the selected rEFInd backup.'
        fail 'Refusing to restore rEFInd boot policy against a different installed kernel set.'
        return 1
    }
    reference=$(cat /proc/cmdline 2>/dev/null || true)
    r35_validate_refind_backup_payload "$dir" "$reference" || {
        fail "rEFInd v4 backup payload failed restore validation: ${R35_REFIND_RESTORE_REASON:-unknown reason}"
        return 1
    }
    ok 'rEFInd v4 immutable EFI/config payload is structurally complete and cmdline-equivalent to the proven systemd-boot runtime'
    info 'EFI/refind/vars is intentionally not restored; rEFInd recreates/updates that mutable runtime namespace on boot.'
    info '/etc/refind.d remains reference/package state and is not rewritten by the live restore backend.'
}

r35_refind_restore_preflight() {
    local dir=$1
    detect_bootloader
    if [[ ${BOOTLOADER:-unknown} == systemd-boot ]]; then
        r43_refind_restore_preflight_from_systemd_boot "$dir"
        return $?
    fi
    r35_refind_restore_preflight_pre_r43 "$@"
}

# r38 already supplies a source-generic rEFInd restore plan/executor once the
# strict target preflight accepts the source. r30 already supplies the generic
# systemd-boot v4 restore target. Only the interactive route matrix was still
# intentionally closed.
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
        refind:limine) r30_restore_limine_backup "$dir" ;;
        refind:systemd-boot) r30_restore_systemd_boot_backup "$dir" ;;
        *)
            printf 'Cross-backend restore %s -> %s is not enabled in %s.\n' "$(bootloader_display_name "$source")" "$(bootloader_display_name "$target")" "${SWITCHER_RELEASE:-r43}"
            return 2
            ;;
    esac
}
