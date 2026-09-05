#!/usr/bin/env bash
# leap16-r61: enable the hardware-proven Limine <-> systemd-boot user-backup
# restore matrix and finish the r60 staged-diagnostic scratch cleanup.
#
# Restore scope is deliberately narrow:
#   * Limine source -> restored systemd-boot v4 backup reuses the proven r48
#     direct edge. Only r44's validated target-payload substitution is enabled.
#   * systemd-boot source -> restored Limine v4 backup reuses the proven r51
#     two-proof edge. Only r31's validated target-payload substitution is enabled.
#   * Source-first ordering, BootNext, runtime proof, fallback transfer, rollback,
#     ownership manifests, retirement and automatic resume remain unchanged.
#
# Diagnostic scope:
#   * once staged-efibootmgr-v.txt is valid, do not recapture it;
#   * remove interrupted .staged-efibootmgr-v.* atomic scratch files both while
#     binding the pending transaction and during trusted resume synchronization.

LEAP16_R61_RESTORE_PAIR='limine<->systemd-boot'

# ---------------------------------------------------------------------------
# r60 diagnostic scratch housekeeping
# ---------------------------------------------------------------------------

leap16_r61_cleanup_staged_capture_scratch() {
    local diag=$1
    [[ -n $diag && -d $diag && ! -L $diag ]] || return 0
    find "$diag" -mindepth 1 -maxdepth 1 -type f -name '.staged-efibootmgr-v.*' -delete 2>/dev/null || true
}

# Replace r60's atomic staged capture with an idempotent version. A valid staged
# table is immutable diagnostic evidence for this transaction; later calls only
# refresh the pending-state copy and clean abandoned atomic scratch files.
leap16_r44_diag_bind_pending() {
    [[ -n ${LEAP16_R44_TRANSACTION_DIAG_DIR:-} && -d $LEAP16_R44_TRANSACTION_DIAG_DIR && ! -L $LEAP16_R44_TRANSACTION_DIAG_DIR ]] || return 0
    local snap=${PENDING_TRANSACTION_SNAPSHOT_DIR:-${TRANSACTION_SNAPSHOT_DIR:-}} tmp='' staged
    [[ -n $snap && -d $snap ]] || return 0
    printf '%s\n' "$LEAP16_R44_TRANSACTION_DIAG_DIR" >"$snap/$LEAP16_R44_DIAG_POINTER" 2>/dev/null || true
    chmod 600 -- "$snap/$LEAP16_R44_DIAG_POINTER" 2>/dev/null || true

    staged="$LEAP16_R44_TRANSACTION_DIAG_DIR/staged-efibootmgr-v.txt"
    leap16_r61_cleanup_staged_capture_scratch "$LEAP16_R44_TRANSACTION_DIAG_DIR"
    if ! leap16_r60_valid_efibootmgr_dump "$staged"; then
        tmp=$(mktemp -- "$LEAP16_R44_TRANSACTION_DIAG_DIR/.staged-efibootmgr-v.XXXXXX") || tmp=''
        if [[ -n $tmp ]]; then
            if efibootmgr -v >"$tmp" 2>&1 && leap16_r60_valid_efibootmgr_dump "$tmp"; then
                chmod 600 -- "$tmp" 2>/dev/null || true
                mv -f -- "$tmp" "$staged" || rm -f -- "$tmp"
            else
                rm -f -- "$tmp"
            fi
        fi
    fi
    leap16_r61_cleanup_staged_capture_scratch "$LEAP16_R44_TRANSACTION_DIAG_DIR"
    [[ -n ${PENDING_STATE_FILE:-} && -r ${PENDING_STATE_FILE:-} ]] \
        && cp -- "$PENDING_STATE_FILE" "$LEAP16_R44_TRANSACTION_DIAG_DIR/pending-migration.tsv" 2>/dev/null || true
}

if declare -F r13_sync_root_diagnostics_to_user >/dev/null 2>&1; then
    eval "$(declare -f r13_sync_root_diagnostics_to_user | sed '1s/r13_sync_root_diagnostics_to_user/r13_sync_root_diagnostics_to_user_pre_leap16_r61/')"
fi

r13_sync_root_diagnostics_to_user() {
    local conf=$1 bundle=$2 status=${3:-resume} rc=0 diag dest uid gid real_dest real_diag
    r13_sync_root_diagnostics_to_user_pre_leap16_r61 "$@" || rc=$?
    [[ -f $bundle/$LEAP16_R44_DIAG_POINTER ]] || return "$rc"
    diag=$(head -n1 -- "$bundle/$LEAP16_R44_DIAG_POINTER" 2>/dev/null || true)
    dest=$(r22_conf_value "$conf" user_diagnostic_root)
    uid=$(r22_conf_value "$conf" user_uid); gid=$(r22_conf_value "$conf" user_gid)
    [[ -n $diag && -n $dest && $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ ]] || return "$rc"
    real_dest=$(r22_realpath_m "$dest"); real_diag=$(r22_realpath_m "$diag")
    [[ $real_diag == "$real_dest/"* && $real_diag != "$real_dest" && -d $diag && ! -L $diag ]] || return "$rc"
    leap16_r61_cleanup_staged_capture_scratch "$diag"
    return "$rc"
}

# ---------------------------------------------------------------------------
# Limine source -> restored systemd-boot backup (proven r48 edge)
# ---------------------------------------------------------------------------

leap16_r61_restore_systemd_from_limine_preflight() {
    local dir=$1 raw current_cmd
    validate_backup_compatibility "$dir" || { fail "Backup is not compatible: $BACKUP_COMPATIBILITY_REASON"; return 1; }
    load_backup_metadata "$dir" || return 1
    [[ ${bootloader:-} == systemd-boot && ${backup_schema:-} == "$LEAP16_R44_SYSTEMD_BACKUP_SCHEMA" ]] \
        || { fail 'Selected backup is not a native Leap systemd-boot v4 backup'; return 1; }

    detect_bootloader
    [[ $BOOTLOADER == limine ]] || { fail 'This restore edge requires finalized Limine as the verified source'; return 1; }
    leap16_r48_preflight systemd-boot || return 1
    leap16_r31_backup_kernel_set_matches "$dir" \
        || { fail 'Installed kernel versions do not exactly match the selected systemd-boot backup'; return 1; }

    raw=$(cat /proc/cmdline 2>/dev/null || true)
    current_cmd=$(r42_portable_limine_cmdline "$raw" 2>/dev/null || true)
    [[ -n $current_cmd ]] || { fail 'Could not derive the portable current Limine runtime command line'; return 1; }
    BACKUP_VALIDATION_REASON=''
    leap16_r44_systemd_backup_payload_valid "$dir" "$current_cmd" \
        || { fail "${BACKUP_VALIDATION_REASON:-systemd-boot backup payload validation failed}"; return 1; }
    ok 'Validated self-contained systemd-boot backup against the finalized Limine source and current kernel/root topology'
}

leap16_r61_restore_systemd_backup_from_limine() {
    local dir=$1 ans rc=0
    leap16_r61_restore_systemd_from_limine_preflight "$dir" || return 1
    printf '\nLeap-native systemd-boot backup restore transaction plan from Limine:\n'
    printf '  - restore exact validated EFI/systemd, loader.conf, BLS entries and managed kernel/initrd payload;\n'
    printf '  - keep canonical Limine primary + exact Limine EFI fallback authoritative during staging;\n'
    printf '  - arm exactly one restored systemd-boot BootNext and require real runtime proof;\n'
    printf '  - only after proof, promote systemd-boot, transfer EFI/BOOT to systemd-boot, and retire exact ownership-proven Limine state.\n\n'
    offer_operation_backup || return 1
    read -r -p 'Type RESTORE to stage this validated systemd-boot backup, or anything else to cancel: ' ans
    [[ $ans == RESTORE ]] || { printf 'Restore cancelled. No boot state was modified by the restore.\n'; return 0; }
    leap16_r61_restore_systemd_from_limine_preflight "$dir" \
        || { fail 'Write-boundary Limine -> systemd-boot restore revalidation failed; nothing was staged'; return 1; }

    LEAP16_R44_RESTORE_DIR=$dir
    OPERATION_BACKUP=$dir
    r26_execute_adapter_switch systemd-boot || rc=$?
    LEAP16_R44_RESTORE_DIR=''
    leap16_r44_diag_bind_pending
    return "$rc"
}

# ---------------------------------------------------------------------------
# systemd-boot source -> restored Limine backup (proven r51 two-proof edge)
# ---------------------------------------------------------------------------

leap16_r61_validate_limine_backup_payload_for_systemd_source() {
    local dir=$1 esp_rel mid efi splash managed backup_cmd raw current_cmd
    load_backup_metadata "$dir" || return 1
    esp_rel=${esp_mount#/}; mid=${machine_id:-}
    efi="$dir/files/$esp_rel/EFI/LIMINE/LIMINE_X64.EFI"
    splash="$dir/files/$esp_rel/limine-splash.png"
    managed="$dir/files/$esp_rel/$mid"

    [[ -f $efi && ! -L $efi ]] || { fail 'Limine backup is missing a regular EFI/LIMINE/LIMINE_X64.EFI'; return 1; }
    [[ -f $splash && ! -L $splash ]] || { fail 'Limine backup is missing a regular limine-splash.png'; return 1; }
    [[ -d $managed && ! -L $managed ]] || { fail 'Limine backup is missing its managed kernel/initrd tree'; return 1; }
    ! find "$managed" -type l -print -quit 2>/dev/null | grep -q . \
        || { fail 'Limine managed backup tree contains a symlink that VFAT cannot represent safely'; return 1; }
    [[ $(od -An -tx1 -N2 -- "$efi" 2>/dev/null | tr -d '[:space:]') == 4d5a ]] \
        || { fail 'Backed-up Limine EFI executable lacks an MZ header'; return 1; }
    if have file; then
        leap16_is_x86_64_efi_application "$efi" \
            || { fail 'Backed-up Limine executable is not an x86-64 EFI application'; return 1; }
    fi
    [[ $(od -An -tx1 -N8 -- "$splash" 2>/dev/null | tr -d '[:space:]') == 89504e470d0a1a0a ]] \
        || { fail 'Backed-up Limine splash is not a PNG file'; return 1; }

    backup_cmd=$(r23_backup_limine_cmdline "$dir" 2>/dev/null || true)
    raw=$(cat /proc/cmdline 2>/dev/null || true)
    current_cmd=$(r42_portable_limine_cmdline "$raw" 2>/dev/null || true)
    [[ -n $backup_cmd && -n $current_cmd ]] || { fail 'Could not resolve backup/current portable Limine command line'; return 1; }
    pending_cmdline_equivalent "$backup_cmd" "$current_cmd" || {
        fail 'Backed-up Limine kernel command line is not token-equivalent to the current proven systemd-boot runtime.'
        return 1
    }
    return 0
}

leap16_r61_restore_limine_from_systemd_preflight() {
    local dir=$1
    leap16_r31_restore_identity_preflight "$dir" limine || return 1
    [[ ${payload_policy:-} == config-efi-splash-plus-staged-payload ]] \
        || { fail 'Unexpected Limine backup payload policy'; return 1; }

    detect_bootloader
    [[ $BOOTLOADER == systemd-boot ]] || { fail 'This restore edge requires finalized systemd-boot as the verified source'; return 1; }
    leap16_r51_preflight limine || return 1
    leap16_r61_validate_limine_backup_payload_for_systemd_source "$dir" || return 1
    ok 'Validated self-contained Limine backup against the finalized systemd-boot source and current kernel/root topology'
}

leap16_r61_restore_limine_backup_from_systemd() {
    local dir=$1 ans rc=0
    leap16_r61_restore_limine_from_systemd_preflight "$dir" || return 1
    printf '\nLeap-native Limine backup restore transaction plan from systemd-boot:\n'
    printf '  - restore the integrity-validated /etc/default/limine, limine.conf, splash, EFI/LIMINE payload and complete managed kernel/initrd tree;\n'
    printf '  - keep canonical systemd-boot + byte-identical systemd EFI/BOOT authoritative through the first Limine proof;\n'
    printf '  - arm exactly one restored canonical Limine BootNext and require real runtime proof;\n'
    printf '  - preserve the proven second reboot through the exact Limine EFI/BOOT fallback before retiring ownership-proven systemd-boot state.\n\n'
    offer_operation_backup || return 1
    read -r -p 'Type RESTORE to stage this validated Limine backup, or anything else to cancel: ' ans
    [[ $ans == RESTORE ]] || { printf 'Restore cancelled. No boot state was modified by the restore.\n'; return 0; }
    leap16_r61_restore_limine_from_systemd_preflight "$dir" \
        || { fail 'Write-boundary systemd-boot -> Limine restore revalidation failed; nothing was staged'; return 1; }

    LEAP16_R31_RESTORE_DIR=$dir
    OPERATION_BACKUP=$dir
    r26_execute_adapter_switch limine || rc=$?
    LEAP16_R31_RESTORE_DIR=''
    leap16_r44_diag_bind_pending
    return "$rc"
}

# ---------------------------------------------------------------------------
# Final Leap restore selector + read-only plan wording
# ---------------------------------------------------------------------------

restore_backup_interactive() {
    local n dir target source
    discover_backups_quiet
    ((${#DISCOVERED_BACKUPS[@]})) || { printf '\nNo backups found.\n'; return 0; }
    printf '\n'; list_backups; printf '\n'
    read -r -p 'Select backup number to restore, or Enter to cancel: ' n
    [[ -n $n ]] || return 0
    [[ $n =~ ^[0-9]+$ ]] && ((n>=1 && n<=${#DISCOVERED_BACKUPS[@]})) || { printf 'Invalid selection.\n'; return 1; }
    dir=${DISCOVERED_BACKUPS[n-1]}
    validate_backup_compatibility "$dir" || { printf 'Restore refused: %s\n' "$BACKUP_COMPATIBILITY_REASON"; return 1; }
    load_backup_metadata "$dir" || return 1
    target=$bootloader
    detect_bootloader; source=$BOOTLOADER

    if [[ $source == "$target" ]]; then
        printf '\nSame-backend %s restore is not exposed as a fake switch transaction.\n' "$(bootloader_display_name "$target")"
        [[ $target == grub ]] && printf 'Use GRUB2 repair/reinstall for the currently active backend.\n'
        return 2
    fi

    case "$source:$target" in
        limine:grub) leap16_r31_restore_grub_backup "$dir" ;;
        grub:limine) leap16_r31_restore_limine_backup "$dir" ;;
        systemd-boot:grub) leap16_r44_with_transaction_transcript "$source" "$target" restore leap16_r44_restore_grub_backup_from_systemd "$dir" ;;
        grub:systemd-boot) leap16_r44_with_transaction_transcript "$source" "$target" restore leap16_r44_restore_systemd_backup "$dir" ;;
        limine:systemd-boot) leap16_r44_with_transaction_transcript "$source" "$target" restore leap16_r61_restore_systemd_backup_from_limine "$dir" ;;
        systemd-boot:limine) leap16_r44_with_transaction_transcript "$source" "$target" restore leap16_r61_restore_limine_backup_from_systemd "$dir" ;;
        *)
            printf 'Restore %s -> %s is not enabled in %s.\n' "$(bootloader_display_name "$source")" "$(bootloader_display_name "$target")" "${SWITCHER_RELEASE:-leap16-r61}"
            printf 'Enabled restore matrix: every cross-backend pair among GRUB2, Limine, and systemd-boot. rEFInd remains locked.\n'
            return 2
            ;;
    esac
}

if declare -F restore_plan_interactive >/dev/null 2>&1; then
    eval "$(declare -f restore_plan_interactive | sed '1s/restore_plan_interactive/restore_plan_interactive_pre_leap16_r61/')"
fi
restore_plan_interactive() {
    # Keep the existing detailed payload report. r61 changes only its now-stale
    # final availability sentence, so capture/patch the text without adding a
    # second selector prompt or duplicating the validator/report implementation.
    local tmp rc=0
    tmp=$(mktemp) || return 1
    restore_plan_interactive_pre_leap16_r61 "$@" >"$tmp"
    rc=$?
    sed \
        -e 's/Restore execution is enabled from GRUB2 through the proven GRUB2 -> systemd-boot transaction engine\./Restore execution is enabled from GRUB2 or Limine through the proven target-specific transaction engine./' \
        -e 's/Restore execution is available from selector \[5\] on its hardware-proven cross-backend matrix\./Restore execution is available from selector [5] on the complete hardware-proven GRUB2 \<-> Limine \<-> systemd-boot cross-backend matrix./' \
        -- "$tmp"
    rm -f -- "$tmp"
    return "$rc"
}
