#!/usr/bin/env bash
# r28: transactional systemd-boot v4 live restore.
#
# r27 could create and validate systemd-boot snapshot backups but deliberately
# refused live restore.  r28 adds the missing executor while preserving the
# r26 adapter transaction model: a verified GRUB source remains authoritative,
# the restored systemd-boot candidate is staged into a clean owned namespace,
# BootNext tests it exactly once, and GRUB is retired only after real userspace
# runtime proof.
#
# The backup captures a wider diagnostic snapshot of /boot/loader, but restore
# intentionally consumes only adapter-owned state.  Foreign BLS entries,
# random-seed/keys, and other shared loader namespace content are never copied
# from the backup or deleted by this restore path.

R28_SDBOOT_RESTORE_REASON=""

r28_backup_file_path() {
    local dir=$1 absolute=$2 rel
    [[ $absolute == /* ]] || return 1
    rel=${absolute#/}
    [[ -n $rel && $rel != *'/../'* && $rel != ../* && $rel != *'/./'* ]] || return 1
    printf '%s/files/%s\n' "$dir" "$rel"
}

r28_systemd_backup_esp_path() {
    local dir=$1 backup_mount=$2 rel=${backup_mount#/}
    [[ -n $rel && $rel != *'..'* ]] || return 1
    printf '%s/files/%s\n' "$dir" "$rel"
}

r28_systemd_backup_kernel_set_matches() {
    local dir=$1 current backup
    collect_kernels
    current=$(printf '%s\n' "${KERNEL_VERSIONS[@]}" | sed '/^$/d' | LC_ALL=C sort -u)
    backup=$(sed '/^[[:space:]]*$/d' "$dir/kernel-versions.txt" 2>/dev/null | LC_ALL=C sort -u)
    [[ -n $current && $current == "$backup" ]]
}

r28_backup_regular_file() {
    [[ -f $1 && ! -L $1 ]]
}

r28_sdboot_backup_entry_field() {
    local file=$1 key=$2
    awk -v k="$key" '
        BEGIN{IGNORECASE=1}
        $1==k { $1=""; sub(/^[[:space:]]+/, ""); print; exit }
    ' "$file" 2>/dev/null
}

r28_sdboot_backup_entry_validate() {
    local file=$1 kid=$2 reference=$3 fallback=${4:-0}
    local linux initrd options expected_initrd
    r28_backup_regular_file "$file" || { R28_SDBOOT_RESTORE_REASON="missing or unsafe backup BLS entry: $file"; return 1; }
    linux=$(r28_sdboot_backup_entry_field "$file" linux 2>/dev/null || true)
    initrd=$(awk 'BEGIN{IGNORECASE=1} $1=="initrd" {print $2}' "$file" 2>/dev/null | tail -n1)
    options=$(r28_sdboot_backup_entry_field "$file" options 2>/dev/null || true)
    [[ $linux == "/vmlinuz-$kid" ]] || { R28_SDBOOT_RESTORE_REASON="$kid backup entry has unexpected linux path (${linux:-unset})"; return 1; }
    if ((fallback)); then expected_initrd="/initramfs-$kid-fallback.img"; else expected_initrd="/initramfs-$kid.img"; fi
    [[ $initrd == "$expected_initrd" ]] || { R28_SDBOOT_RESTORE_REASON="$kid backup entry has unexpected initrd path (${initrd:-unset})"; return 1; }
    [[ -n $options ]] || { R28_SDBOOT_RESTORE_REASON="$kid backup entry has no options line"; return 1; }
    pending_cmdline_equivalent "$options" "$reference" || {
        R28_SDBOOT_RESTORE_REASON="$kid backup entry command line is not token-equivalent to the currently proven GRUB runtime command line"
        return 1
    }
    return 0
}

r28_validate_systemd_backup_payload() {
    local dir=$1 reference=$2 backup_mount=${esp_mount:-} root loader entries efi policy backup_efi_path
    local ver kid entry fallback_entry current_payload rows=0
    R28_SDBOOT_RESTORE_REASON=""

    [[ ${format_version:-} == 4 ]] || { R28_SDBOOT_RESTORE_REASON="systemd-boot live restore requires backup format v4"; return 1; }
    [[ ${bootloader:-} == systemd-boot ]] || { R28_SDBOOT_RESTORE_REASON="selected backup is not a systemd-boot backup"; return 1; }
    [[ ${payload_policy:-} == bootloader-owned-paths ]] || { R28_SDBOOT_RESTORE_REASON="unexpected systemd-boot backup payload policy"; return 1; }
    backup_efi_path=${boot_efi_path:-}
    [[ -n $backup_efi_path && ${backup_efi_path,,} == '\efi\systemd\systemd-bootx64.efi' ]] || { R28_SDBOOT_RESTORE_REASON="backup does not identify the canonical systemd-boot EFI executable"; return 1; }
    [[ -n $reference ]] || { R28_SDBOOT_RESTORE_REASON="known-good GRUB runtime command line is empty"; return 1; }

    root=$(r28_systemd_backup_esp_path "$dir" "$backup_mount") || { R28_SDBOOT_RESTORE_REASON="invalid backup ESP mount path"; return 1; }
    loader="$root/loader/loader.conf"
    entries="$root/loader/entries"
    efi="$root/EFI/systemd/systemd-bootx64.efi"
    policy="$dir/files/etc/sdboot-manage.conf.d/90-cachyos-bootloader-switcher.conf"

    r28_backup_regular_file "$efi" || { R28_SDBOOT_RESTORE_REASON="backup is missing the canonical systemd-boot EFI executable"; return 1; }
    r28_backup_regular_file "$loader" || { R28_SDBOOT_RESTORE_REASON="backup is missing loader.conf"; return 1; }
    r28_backup_regular_file "$policy" || { R28_SDBOOT_RESTORE_REASON="backup is missing the switcher sdboot-manage policy drop-in"; return 1; }
    [[ -d $entries && ! -L $entries ]] || { R28_SDBOOT_RESTORE_REASON="backup is missing a safe loader/entries directory"; return 1; }

    grep -Eq '^[[:space:]]*default[[:space:]]+linux-cachyos(\.conf)?[[:space:]]*$' "$loader" || { R28_SDBOOT_RESTORE_REASON="backup loader.conf does not prefer linux-cachyos"; return 1; }
    grep -Eq '^[[:space:]]*timeout[[:space:]]+5[[:space:]]*$' "$loader" || { R28_SDBOOT_RESTORE_REASON="backup loader.conf timeout is not 5"; return 1; }
    grep -Eq '^[[:space:]]*console-mode[[:space:]]+keep[[:space:]]*$' "$loader" || { R28_SDBOOT_RESTORE_REASON="backup loader.conf is missing console-mode keep"; return 1; }
    grep -Eq '^[[:space:]]*REMOVE_EXISTING="?no"?[[:space:]]*$' "$policy" || { R28_SDBOOT_RESTORE_REASON="backup sdboot-manage policy would not preserve the shared BLS namespace"; return 1; }
    grep -Eq '^[[:space:]]*OVERWRITE_EXISTING="?yes"?[[:space:]]*$' "$policy" || { R28_SDBOOT_RESTORE_REASON="backup sdboot-manage policy does not allow deterministic CachyOS entry refresh"; return 1; }
    grep -Eq '^[[:space:]]*PRESERVE_FOREIGN="?yes"?[[:space:]]*$' "$policy" || { R28_SDBOOT_RESTORE_REASON="backup sdboot-manage policy does not preserve foreign entries"; return 1; }

    collect_kernels
    for ver in "${KERNEL_VERSIONS[@]}"; do
        kid=$(kernel_pkgbase_for_version "$ver" 2>/dev/null || true)
        [[ -n $kid ]] || { R28_SDBOOT_RESTORE_REASON="could not resolve pkgbase for installed kernel $ver"; return 1; }
        entry="$entries/$kid.conf"
        r28_sdboot_backup_entry_validate "$entry" "$kid" "$reference" 0 || return 1
        current_payload="${ESP_MOUNT%/}/vmlinuz-$kid"
        sdboot_path_exists "$current_payload" || { R28_SDBOOT_RESTORE_REASON="current shared kernel payload is missing: $current_payload"; return 1; }
        current_payload="${ESP_MOUNT%/}/initramfs-$kid.img"
        sdboot_path_exists "$current_payload" || { R28_SDBOOT_RESTORE_REASON="current shared initramfs payload is missing: $current_payload"; return 1; }
        ((rows+=1))

        fallback_entry="$entries/$kid-fallback.conf"
        if [[ -e $fallback_entry || -L $fallback_entry ]]; then
            r28_sdboot_backup_entry_validate "$fallback_entry" "$kid" "$reference" 1 || return 1
            current_payload="${ESP_MOUNT%/}/initramfs-$kid-fallback.img"
            sdboot_path_exists "$current_payload" || { R28_SDBOOT_RESTORE_REASON="backup has a fallback entry but current fallback initramfs is missing: $current_payload"; return 1; }
        fi
    done
    ((rows > 0)) || { R28_SDBOOT_RESTORE_REASON="backup contains no restorable CachyOS kernel entries"; return 1; }
    return 0
}

r28_systemd_restore_preflight() {
    local dir=$1 reference
    pending_exists && { fail 'A staged bootloader migration is already pending'; return 1; }
    validate_backup_compatibility "$dir" || { fail "Backup is not compatible: $BACKUP_COMPATIBILITY_REASON"; return 1; }
    load_backup_metadata "$dir" || { fail 'Could not load selected backup metadata'; return 1; }
    [[ $bootloader == systemd-boot ]] || { fail 'Selected backup is not a systemd-boot backup'; return 1; }
    [[ $format_version == 4 ]] || { fail "systemd-boot live restore requires backup format v4 (found v${format_version:-unknown})"; return 1; }

    detect_bootloader
    [[ $BOOTLOADER == grub ]] || {
        fail 'Transactional systemd-boot restore currently requires the verified source bootloader to be GRUB.'
        fail 'Restore through another source adapter is not certified yet.'
        return 1
    }
    r26_generic_preflight systemd-boot || return 1
    [[ ${esp_mount:-} == "$ESP_MOUNT" ]] || {
        fail "Backup ESP mountpoint (${esp_mount:-unknown}) differs from the current validated topology ($ESP_MOUNT)."
        fail 'The switcher refuses to rewrite backup topology during a live restore.'
        return 1
    }
    [[ $ESP_MOUNT == /boot ]] || {
        fail "systemd-boot restore currently requires the CachyOS /boot ESP topology; detected $ESP_MOUNT."
        return 1
    }
    r28_systemd_backup_kernel_set_matches "$dir" || {
        fail 'Installed kernel versions do not exactly match the selected systemd-boot backup.'
        fail 'The backed-up BLS entries are not allowed to point at a different current kernel set.'
        return 1
    }
    reference=$(cat /proc/cmdline 2>/dev/null || true)
    r28_validate_systemd_backup_payload "$dir" "$reference" || {
        fail "systemd-boot v4 backup payload failed restore validation: ${R28_SDBOOT_RESTORE_REASON:-unknown reason}"
        return 1
    }
    ok 'systemd-boot v4 backup payload is structurally complete and cmdline-equivalent to the proven GRUB runtime'
    return 0
}

r28_restore_backup_file() {
    local src=$1 dst=$2 mode=${3:-0644} esp_prefix src_hash dst_hash
    r28_backup_regular_file "$src" || { fail "Unsafe/missing backup file: $src"; return 1; }
    src_hash=$(sha256sum -- "$src" 2>/dev/null | awk '{print $1}' || true)
    [[ $src_hash =~ ^[0-9A-Fa-f]{64}$ ]] || { fail "Could not hash backup restore file: $src"; return 1; }

    esp_prefix=${ESP_MOUNT%/}
    if [[ -n $esp_prefix && $dst == "$esp_prefix/"* ]]; then
        # FAT/VFAT has no Unix ownership/mode/xattr semantics. Restore bytes
        # only, just like the r25 VFAT-safe restore helper, and never follow a
        # target symlink that may have appeared after preflight.
        sudo mkdir -p -- "$(dirname -- "$dst")" || return 1
        if sudo test -e "$dst" 2>/dev/null || sudo test -L "$dst" 2>/dev/null; then
            sudo test -d "$dst" 2>/dev/null && { fail "Expected restore file path became a directory: $dst"; return 1; }
            sudo rm -f -- "$dst" || return 1
        fi
        sudo cp --no-preserve=all -- "$src" "$dst" || return 1
    else
        sudo install -d -o root -g root -m 0755 -- "$(dirname -- "$dst")" || return 1
        if sudo test -L "$dst" 2>/dev/null; then sudo rm -f -- "$dst" || return 1; fi
        sudo install -o root -g root -m "$mode" -- "$src" "$dst" || return 1
    fi

    dst_hash=$(sudo -n sha256sum -- "$dst" 2>/dev/null | awk '{print $1}' || sha256sum -- "$dst" 2>/dev/null | awk '{print $1}' || true)
    [[ $dst_hash == "$src_hash" ]] || { fail "Restored file bytes do not match the validated backup: $dst"; return 1; }
    return 0
}
r28_stage_systemd_boot_from_backup() {
    local dir=$1 source_id=$2 original_order=$3 reference=$4 target_id
    local backup_root loader_src efi_src policy_src ver kid entry_src fallback_src dst
    backup_root=$(r28_systemd_backup_esp_path "$dir" "${esp_mount:-}") || return 1

    install_target_packages systemd-boot || return 1
    have bootctl || { fail 'bootctl is unavailable after package installation'; return 1; }
    have sdboot-manage || { fail 'sdboot-manage is unavailable after package installation'; return 1; }

    # bootctl creates the canonical firmware entry, but r28 does not let it own
    # unrelated random-seed/entry-token state and does not use sdboot-manage gen:
    # the validated v4 BLS entries themselves are the restore payload.
    sudo bootctl --esp-path="$ESP_MOUNT" --random-seed=no --make-entry-directory=no install || return 1

    efi_src="$backup_root/EFI/systemd/systemd-bootx64.efi"
    loader_src="$backup_root/loader/loader.conf"
    policy_src="$dir/files/etc/sdboot-manage.conf.d/90-cachyos-bootloader-switcher.conf"
    r28_restore_backup_file "$efi_src" "$ESP_MOUNT/EFI/systemd/systemd-bootx64.efi" 0644 || return 1
    r28_restore_backup_file "$loader_src" "$ESP_MOUNT/loader/loader.conf" 0644 || return 1
    r28_restore_backup_file "$policy_src" /etc/sdboot-manage.conf.d/90-cachyos-bootloader-switcher.conf 0644 || return 1

    collect_kernels
    for ver in "${KERNEL_VERSIONS[@]}"; do
        kid=$(kernel_pkgbase_for_version "$ver" 2>/dev/null || true)
        [[ -n $kid ]] || return 1
        entry_src="$backup_root/loader/entries/$kid.conf"
        dst="$ESP_MOUNT/loader/entries/$kid.conf"
        r28_restore_backup_file "$entry_src" "$dst" 0644 || return 1
        fallback_src="$backup_root/loader/entries/$kid-fallback.conf"
        if [[ -f $fallback_src && ! -L $fallback_src ]]; then
            r28_restore_backup_file "$fallback_src" "$ESP_MOUNT/loader/entries/$kid-fallback.conf" 0644 || return 1
        fi
    done

    find_nvram_entry_for_target systemd-boot || { fail 'Could not find the canonical systemd-boot NVRAM entry after bootctl install'; return 1; }
    target_id=$TARGET_NVRAM_ID
    set_source_first_boot_order "$source_id" "$target_id" "$original_order" || return 1
    r26_restore_source_fallback_after_target_stage || return 1
    adapter_target_validate systemd-boot || return 1
    r26_record_target_adapter systemd-boot || return 1
    R26_STAGED_TARGET_ID=${target_id^^}
    ok "Staged validated systemd-boot v4 backup as canonical Boot$R26_STAGED_TARGET_ID"
}

r28_execute_systemd_boot_restore() {
    local dir=$1 source=grub source_id=${BOOT_CURRENT^^} original_order=$BOOT_ORDER reference target_id
    [[ -n $source_id && -n $original_order ]] || { fail 'Could not capture source GRUB NVRAM identity/BootOrder'; return 1; }
    reference=$(cat /proc/cmdline 2>/dev/null || true)
    [[ -n $reference ]] || { fail 'Could not capture known-good GRUB source cmdline'; return 1; }

    R26_STAGED_TARGET_ID=""
    adapter_source_snapshot "$source" || return 1
    if ! r28_stage_systemd_boot_from_backup "$dir" "$source_id" "$original_order" "$reference"; then
        fail 'Restored systemd-boot target staging failed before a candidate transaction was committed.'
        r26_cleanup_uncommitted_target systemd-boot "$original_order" "$source_id" "$source" || true
        return 1
    fi
    target_id=${R26_STAGED_TARGET_ID^^}
    if [[ ! $target_id =~ ^[0-9A-F]{4}$ ]]; then
        fail 'Restored systemd-boot adapter did not publish a valid NVRAM identifier.'
        r26_cleanup_uncommitted_target systemd-boot "$original_order" "$source_id" "$source" || true
        return 1
    fi

    if ! adapter_source_validate "$source"; then
        fail 'Source GRUB validation failed after systemd-boot restore staging; candidate will not be committed.'
        r26_cleanup_uncommitted_target systemd-boot "$original_order" "$source_id" "$source" || true
        return 1
    fi
    if [[ $(pending_bootorder_first) != "$source_id" ]]; then
        fail 'Source GRUB is no longer first after restore staging; candidate will not be committed.'
        r26_cleanup_uncommitted_target systemd-boot "$original_order" "$source_id" "$source" || true
        return 1
    fi

    OPERATION_BACKUP=$dir
    if ! r26_write_pending_adapter "$source" systemd-boot "$source_id" "$original_order" "$target_id" candidate-ready; then
        fail 'Could not persist the restored systemd-boot adapter transaction; rolling back the uncommitted candidate.'
        r26_cleanup_uncommitted_target systemd-boot "$original_order" "$source_id" "$source" || true
        return 1
    fi
    load_pending_state || return 1
    verify_pending_source_recovery_unchanged || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1

    printf '\nRESTORE-CANDIDATE-READY GRUB -> systemd-boot transaction staged successfully.\n'
    printf 'The restored v4 candidate is source-preserving; GRUB remains first until real runtime proof.\n'
    r23_arm_candidate_automatically || return 1
    if ! r22_prepare_resume_bundle; then
        fail 'Could not prepare automatic post-reboot continuation. Clearing transaction BootNext for safety.'
        r22_rollback_automation_arm
        return 1
    fi
    r23_prompt_reboot
}

restore_systemd_boot_backup() {
    local dir=$1 ans
    r28_systemd_restore_preflight "$dir" || return 1
    load_backup_metadata "$dir" || return 1

    printf '\nsystemd-boot v4 restore transaction plan:\n'
    printf '  - Restore only adapter-owned state from the validated backup: EFI/systemd/systemd-bootx64.efi, loader.conf, exact CachyOS BLS entries, and the switcher sdboot-manage policy drop-in.\n'
    printf '  - Foreign loader/entries files, loader random-seed/keys, and unrelated shared BLS state are NOT copied, overwritten, or claimed.\n'
    printf '  - Install/refresh systemd-boot-manager and use bootctl only to create the canonical firmware target; backed-up BLS entries are restored directly instead of regenerated.\n'
    printf '  - Keep current GRUB first in persistent BootOrder while the restored candidate is deeply validated.\n'
    printf '  - Arm restored systemd-boot exactly once through BootNext and install the temporary root-owned resume service.\n'
    printf '  - After a proven systemd-boot userspace boot, automatically promote it and retire only ownership-proven GRUB state.\n'
    printf '  - If target proof fails, GRUB cleanup is not authorized.\n'
    printf '  - /etc/fstab is reference-only and will NOT be restored or rewritten.\n\n'

    offer_operation_backup || return 1
    read -r -p 'Type RESTORE to stage this validated systemd-boot v4 backup, or anything else to cancel: ' ans
    [[ $ans == RESTORE ]] || { printf 'Restore cancelled. No boot state was modified by the restore.\n'; return 0; }

    # The optional source-backup offer loads its own metadata while validating
    # that backup. Re-run the selected systemd-boot preflight at the actual
    # write boundary so selected-backup metadata/integrity and target cleanliness
    # are proven again immediately before staging.
    r28_systemd_restore_preflight "$dir" || {
        fail 'Write-boundary revalidation failed; no systemd-boot restore state was staged.'
        return 1
    }
    load_backup_metadata "$dir" || return 1
    r28_execute_systemd_boot_restore "$dir"
}

# Override the restore dispatcher so r28 exposes systemd-boot live restore while
# leaving the proven GRUB/Limine restore implementations untouched.
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
        systemd-boot) restore_systemd_boot_backup "$dir" ;;
        *) printf 'Live restore for %s backups is not implemented in this release.\n' "$bootloader"; return 2 ;;
    esac
}
