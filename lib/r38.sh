#!/usr/bin/env bash
# r38: enable the two backup-restore directions between Limine and rEFInd.
#
# r37 earned real-hardware proof for the direct rEFInd -> Limine live adapter.
# r35 had already defined a strict format-v4 rEFInd restore contract, but only
# admitted GRUB as its source. r30's Limine restore contract was already generic
# across deeply validated GRUB/systemd-boot sources, but its direction matrix did
# not admit rEFInd. r38 composes those existing source/target contracts without
# weakening the format, topology, ownership, BootNext, runtime-proof, fallback,
# or source-retirement gates.
#
# Newly enabled restore-only edges:
#   Limine -> restored rEFInd v4
#   rEFInd -> restored Limine v3/v4
#
# This does NOT enable the Limine -> rEFInd *live migration* edge; that remains a
# separate certification step. Same-backend restore also remains disabled.

# Extend only the restore matrix. Keep every other r30 route unchanged.
eval "$(declare -f r30_cross_restore_supported | sed '1s/r30_cross_restore_supported/r30_cross_restore_supported_pre_r38/')"
r30_cross_restore_supported() {
    case "$1:$2" in
        limine:refind|refind:limine) return 0 ;;
        *) r30_cross_restore_supported_pre_r38 "$@" ;;
    esac
}

# Format-5 pending state must survive the reboot on the new Limine -> rEFInd
# restore direction. r36 already admits refind:limine, so only add the reverse
# pair if the inherited parser reaches its historical direction gate.
eval "$(declare -f load_pending_state | sed '1s/load_pending_state/load_pending_state_pre_r38/')"
load_pending_state() {
    if [[ $(r26_state_format) != "$R26_PENDING_FORMAT" ]]; then
        load_pending_state_pre_r38 "$@"
        return $?
    fi

    if load_pending_state_pre_r38 "$@"; then
        return 0
    fi
    [[ ${PENDING_REASON:-} == 'unsupported r26 adapter migration direction' ]] || return 1
    case "${PENDING_SOURCE:-}:${PENDING_TARGET:-}" in
        limine:refind|refind:limine) ;;
        *) return 1 ;;
    esac

    [[ $PENDING_FORMAT == "$R26_PENDING_FORMAT" ]] || { PENDING_REASON='wrong r26 state format'; return 1; }
    [[ $PENDING_ADAPTER_REVISION == "$R26_ADAPTER_REVISION" ]] || { PENDING_REASON='unsupported adapter-state revision'; return 1; }
    [[ -n $PENDING_MACHINE_ID && -n $PENDING_OLD_BOOT_ID && -n $PENDING_TARGET_BOOT_ID ]] || { PENDING_REASON='missing transaction identity'; return 1; }
    [[ -n $PENDING_SOURCE_CMDLINE ]] || { PENDING_REASON='missing source kernel command line'; return 1; }
    [[ -n $PENDING_SOURCE_MANIFEST && -n $PENDING_TARGET_MANIFEST ]] || { PENDING_REASON='missing adapter ownership manifests'; return 1; }
    PENDING_REASON='valid'
    return 0
}

# r30's common preflight was structurally generic but printed its historical
# implementation revision. Keep the exact safety contract while making the UI
# release-aware and allowing the newly admitted refind:limine restore pair via
# r30_cross_restore_supported().
r30_restore_common_preflight() {
    local dir=$1 target=$2 source
    pending_exists && { fail 'A staged bootloader migration is already pending'; return 1; }
    validate_backup_compatibility "$dir" || { fail "Backup is not compatible: $BACKUP_COMPATIBILITY_REASON"; return 1; }
    load_backup_metadata "$dir" || { fail 'Could not load selected backup metadata'; return 1; }
    [[ ${bootloader:-} == "$target" ]] || { fail "Selected backup is not a $(bootloader_display_name "$target") backup"; return 1; }

    detect_bootloader
    source=$BOOTLOADER
    [[ $source != unknown ]] || { fail 'Could not identify the currently booted source bootloader'; return 1; }
    [[ $source != "$target" ]] || {
        fail "Same-backend $(bootloader_display_name "$target") restore is not modeled as a cross-backend switch transaction."
        fail 'Use the dedicated repair path where available; same-backend rollback needs its own source-preservation design.'
        return 1
    }
    r30_cross_restore_supported "$source" "$target" || {
        fail "Cross-backend restore $(bootloader_display_name "$source") -> $(bootloader_display_name "$target") is not enabled."
        return 1
    }

    printf '\n%s cross-backend restore preflight:\n' "${SWITCHER_RELEASE:-r38}"
    run_validation preflight || { fail 'Base preflight failed; no boot state was modified'; return 1; }
    is_cachyos || { fail 'Live restore is intentionally restricted to CachyOS/Arch-like systems'; return 1; }
    if bootcurrent_is_generic_fallback; then
        fail 'The current session was booted through the generic UEFI fallback path.'
        fail 'Restore transactions require the canonical source NVRAM entry; reboot normally and let firmware follow BootOrder.'
        return 1
    fi
    have sudo && have pacman || { fail 'sudo and pacman are required'; return 1; }
    [[ -z ${BOOT_NEXT:-} ]] || { fail "BootNext is already set to Boot${BOOT_NEXT^^}; refusing to overwrite firmware intent"; return 1; }

    printf '\nSource adapter deep gate (%s):\n' "$(bootloader_display_name "$source")"
    adapter_source_validate "$source" || { fail 'The active source adapter failed deep validation; restore staging is refused'; return 1; }

    case "$target" in
        grub|systemd-boot)
            r26_target_namespace_clean "$target" || return 1
            ;;
        limine)
            if find_nvram_entry_for_target limine; then
                fail "An existing Limine NVRAM entry (Boot$TARGET_NVRAM_ID) already exists before restore staging."
                fail 'Target ownership is ambiguous; refusing to reuse an active/incompletely-retired Limine target.'
                return 1
            fi
            validate_existing_boot_artifacts_for_limine_stage || {
                fail 'Existing conventional kernel/initramfs artifacts are incomplete; refusing Limine restore staging.'
                return 1
            }
            ;;
        *) fail "No ${SWITCHER_RELEASE:-r38} restore target gate for $target"; return 1 ;;
    esac
    return 0
}

# Generalize the already-proven r35 rEFInd-v4 restore contract from GRUB source
# to a deeply validated Limine source. Nothing about the target payload contract
# changes: exact v4 backup, exact kernel set, /boot ESP topology, immutable tree
# restore, fresh vars/PreviousBoot, and direct-kernel runtime proof are retained.
r35_refind_restore_preflight() {
    local dir=$1 reference source
    pending_exists && { fail 'A staged bootloader migration is already pending'; return 1; }
    validate_backup_compatibility "$dir" || { fail "Backup is not compatible: $BACKUP_COMPATIBILITY_REASON"; return 1; }
    load_backup_metadata "$dir" || { fail 'Could not load selected backup metadata'; return 1; }
    [[ ${bootloader:-} == refind ]] || { fail 'Selected backup is not a rEFInd backup'; return 1; }

    detect_bootloader
    source=$BOOTLOADER
    case "$source" in
        grub|limine) ;;
        refind)
            fail 'Same-backend rEFInd restore is not modeled as a cross-backend switch transaction.'
            return 1
            ;;
        *)
            fail "${SWITCHER_RELEASE:-r38} transactional rEFInd backup restore is not enabled from $(bootloader_display_name "$source")."
            return 1
            ;;
    esac

    printf '\n%s rEFInd restore preflight:\n' "${SWITCHER_RELEASE:-r38}"
    run_validation preflight || { fail 'Base preflight failed; no boot state was modified'; return 1; }
    is_cachyos || { fail 'rEFInd live restore is intentionally restricted to CachyOS/Arch-like systems'; return 1; }
    if bootcurrent_is_generic_fallback; then
        fail 'The current session was booted through the generic UEFI fallback path.'
        fail "Restore transactions require the canonical $(bootloader_display_name "$source") source NVRAM entry; reboot normally first."
        return 1
    fi
    have sudo && have pacman || { fail 'sudo and pacman are required'; return 1; }
    [[ -z ${BOOT_NEXT:-} ]] || { fail "BootNext is already set to Boot${BOOT_NEXT^^}; refusing to overwrite firmware intent"; return 1; }

    printf '\nSource adapter deep gate (%s):\n' "$(bootloader_display_name "$source")"
    adapter_source_validate "$source" || { fail "The active $(bootloader_display_name "$source") source failed deep validation; rEFInd restore staging is refused"; return 1; }
    r26_target_namespace_clean refind || return 1

    load_backup_metadata "$dir" || return 1
    [[ ${format_version:-} == 4 ]] || { fail "rEFInd live restore requires backup format v4 (found v${format_version:-unknown})"; return 1; }
    [[ ${esp_mount:-} == "$ESP_MOUNT" ]] || {
        fail "Backup ESP mountpoint (${esp_mount:-unknown}) differs from the current validated topology ($ESP_MOUNT)."
        fail 'The switcher refuses to rewrite backup topology during a live restore.'
        return 1
    }
    [[ $ESP_MOUNT == /boot ]] || {
        fail "${SWITCHER_RELEASE:-r38} rEFInd restore currently certifies the CachyOS /boot ESP topology only; detected $ESP_MOUNT."
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
    ok "rEFInd v4 immutable EFI/config payload is structurally complete and cmdline-equivalent to the proven $(bootloader_display_name "$source") runtime"
    info 'EFI/refind/vars is intentionally not restored; rEFInd recreates/updates that mutable runtime namespace on boot.'
    info '/etc/refind.d remains reference/package state and is not rewritten by the live restore backend.'
}

r38_restore_refind_backup() {
    local dir=$1 ans source
    r35_refind_restore_preflight "$dir" || return 1
    source=$BOOTLOADER
    printf '\nrEFInd v4 cross-backend restore transaction plan:\n'
    printf '  - Keep current %s authoritative while staging the validated backed-up rEFInd candidate.\n' "$(bootloader_display_name "$source")"
    printf '  - Restore the immutable EFI/refind tree and /boot/refind_linux.conf exactly; do not restore stale EFI/refind/vars runtime evidence.\n'
    printf '  - Leave /etc/refind.d untouched; it is backup reference/package state, not adapter-owned live restore state.\n'
    printf '  - Keep %s first in persistent BootOrder, deep-validate both sides, then arm restored rEFInd exactly once with BootNext.\n' "$(bootloader_display_name "$source")"
    printf '  - Require a real rEFInd userspace boot plus PreviousBoot direct-kernel proof before %s retirement.\n' "$(bootloader_display_name "$source")"
    printf '  - /etc/fstab is reference-only and is never rewritten.\n\n'
    offer_operation_backup || return 1
    read -r -p 'Type RESTORE to stage this validated rEFInd v4 backup, or anything else to cancel: ' ans
    [[ $ans == RESTORE ]] || { printf 'Restore cancelled. No boot state was modified by the restore.\n'; return 0; }
    r35_refind_restore_preflight "$dir" || { fail 'Write-boundary revalidation failed; no rEFInd restore state was staged.'; return 1; }
    load_backup_metadata "$dir" || return 1
    r30_execute_restored_adapter "$dir" refind r35_stage_refind_from_backup
}

# The interactive restore matrix now opens only the two Limine <-> rEFInd backup
# directions. Other rEFInd/non-GRUB pairs remain deliberately closed.
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
        grub:refind|limine:refind) r38_restore_refind_backup "$dir" ;;
        refind:limine) r30_restore_limine_backup "$dir" ;;
        *)
            printf 'Cross-backend restore %s -> %s is not enabled in %s.\n' "$(bootloader_display_name "$source")" "$(bootloader_display_name "$target")" "${SWITCHER_RELEASE:-r38}"
            [[ $source == refind || $target == refind ]] && printf '%s enables only GRUB/Limine -> restored rEFInd and rEFInd -> restored Limine; other non-GRUB rEFInd restore pairs remain disabled.\n' "${SWITCHER_RELEASE:-r38}"
            return 2
            ;;
    esac
}
