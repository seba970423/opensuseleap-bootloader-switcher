#!/usr/bin/env bash
# r31: legacy-GRUB-v3 compatibility for generalized cross-backend restore.
#
# r30 generalized the restore matrix across GRUB, Limine and systemd-boot, but
# its new systemd-boot -> GRUB path admitted only format-v4 GRUB backups.  A
# real user backup created earlier in the same project lifetime is format v3
# and is already accepted by the backup integrity/compatibility layer.  r31
# keeps the r30 transaction choreography unchanged and extends only the GRUB
# restore-target contract to compatible v3 backups.
#
# v3 is not blindly trusted.  The policy and generated grub.cfg used as proof
# must be regular files and must themselves be covered by the legacy SHA256SUMS
# manifest.  Their kernel/root/cmdline semantics are then checked exactly as in
# r30 before any write boundary is offered.

r31_backup_manifest_covers() {
    local dir=$1 rel=${2#./}
    [[ -f $dir/SHA256SUMS ]] || return 1
    grep -Fq "  ./$rel" "$dir/SHA256SUMS" || grep -Fq " *./$rel" "$dir/SHA256SUMS"
}

r31_validate_grub_backup_payload() {
    local dir=$1 reference=$2 policy cfg backup_efi root_token mode_token ver kid linux_line initrd_line
    local regular_line='' lts_line='' preferred configured_top rows=0 required
    R30_GRUB_RESTORE_REASON=""

    case ${format_version:-} in
        3|4) ;;
        *) R30_GRUB_RESTORE_REASON='cross-source GRUB restore requires backup format v3 or v4'; return 1 ;;
    esac
    [[ ${bootloader:-} == grub ]] || { R30_GRUB_RESTORE_REASON='selected backup is not a GRUB backup'; return 1; }
    [[ ${payload_policy:-} == bootloader-owned-paths ]] || { R30_GRUB_RESTORE_REASON='unexpected GRUB backup payload policy'; return 1; }
    backup_efi=${boot_efi_path:-}
    [[ -n $backup_efi && ${backup_efi,,} == '\efi\cachyos\grubx64.efi' ]] || { R30_GRUB_RESTORE_REASON='backup does not identify the canonical CachyOS GRUB EFI executable'; return 1; }
    [[ -n $reference ]] || { R30_GRUB_RESTORE_REASON='known-good source runtime command line is empty'; return 1; }

    policy="$dir/files/etc/default/grub"
    cfg="$dir/files/boot/grub/grub.cfg"
    [[ -f $policy && ! -L $policy ]] || { R30_GRUB_RESTORE_REASON='backup is missing a safe /etc/default/grub'; return 1; }
    [[ -f $cfg && ! -L $cfg ]] || { R30_GRUB_RESTORE_REASON='backup is missing a safe /boot/grub/grub.cfg'; return 1; }

    # v4 hashes every backup file automatically.  v3 used the older explicit
    # manifest contract, so prove the exact legacy files we consume as restore
    # evidence are actually integrity-covered before trusting their contents.
    if [[ $format_version == 3 ]]; then
        for required in files/etc/default/grub files/boot/grub/grub.cfg kernel-versions.txt metadata.conf; do
            r31_backup_manifest_covers "$dir" "$required" || {
                R30_GRUB_RESTORE_REASON="legacy GRUB v3 backup does not integrity-cover required restore evidence: $required"
                return 1
            }
        done
    fi

    grep -Fqx 'GRUB_THEME="/usr/share/grub/themes/cachyos/theme.txt"' "$policy" || { R30_GRUB_RESTORE_REASON='backup GRUB policy does not reference the CachyOS theme'; return 1; }
    [[ $(grub_default_value GRUB_DEFAULT "$policy" 2>/dev/null || true) == 0 ]] || { R30_GRUB_RESTORE_REASON='backup GRUB policy is not deterministic (GRUB_DEFAULT=0 missing)'; return 1; }

    root_token=$(tr ' ' '\n' <<<"$reference" | awk '/^root=/{print; exit}')
    mode_token=$(tr ' ' '\n' <<<"$reference" | awk '$0=="rw" || $0=="ro" {print; exit}')
    [[ -n $root_token && -n $mode_token ]] || { R30_GRUB_RESTORE_REASON='source runtime cmdline lacks root= or rw/ro'; return 1; }

    collect_kernels
    preferred=${KERNEL_PKGBASES[0]:-}
    [[ -n $preferred ]] || { R30_GRUB_RESTORE_REASON='could not resolve preferred installed kernel'; return 1; }
    configured_top=$(grub_default_value GRUB_TOP_LEVEL "$policy" 2>/dev/null || true)
    [[ $configured_top == "/boot/vmlinuz-$preferred" ]] || { R30_GRUB_RESTORE_REASON="backup GRUB_TOP_LEVEL does not prefer $preferred"; return 1; }

    for ver in "${KERNEL_VERSIONS[@]}"; do
        kid=$(kernel_pkgbase_for_version "$ver" 2>/dev/null || true)
        [[ -n $kid ]] || { R30_GRUB_RESTORE_REASON="could not resolve pkgbase for installed kernel $ver"; return 1; }
        linux_line=$(grub_linux_line_for_kernel "$cfg" "$kid")
        initrd_line=$(grub_initrd_line_for_kernel "$cfg" "$kid")
        [[ -n $linux_line ]] || { R30_GRUB_RESTORE_REASON="$kid backup grub.cfg has no linux entry"; return 1; }
        [[ -n $initrd_line ]] || { R30_GRUB_RESTORE_REASON="$kid backup grub.cfg has no matching initramfs entry"; return 1; }
        [[ " $linux_line " == *" $root_token "* ]] || { R30_GRUB_RESTORE_REASON="$kid backup GRUB entry does not preserve $root_token"; return 1; }
        [[ " $linux_line " == *" $mode_token "* ]] || { R30_GRUB_RESTORE_REASON="$kid backup GRUB entry does not preserve $mode_token"; return 1; }
        grub_line_has_reference_tokens "$reference" "$linux_line" || { R30_GRUB_RESTORE_REASON="$kid backup GRUB entry lost source runtime token: ${GRUB_MISSING_CMDLINE_TOKEN:-unknown}"; return 1; }
        case "$kid" in
            *-lts) [[ -z $lts_line ]] && lts_line=$(grub_kernel_first_line_number "$cfg" "$kid") ;;
            *) [[ -z $regular_line ]] && regular_line=$(grub_kernel_first_line_number "$cfg" "$kid") ;;
        esac
        ((rows+=1))
    done
    ((rows > 0)) || { R30_GRUB_RESTORE_REASON='backup contains no restorable GRUB kernel entries'; return 1; }
    if [[ -n $regular_line && -n $lts_line ]]; then
        ((regular_line < lts_line)) || { R30_GRUB_RESTORE_REASON='backup grub.cfg does not place the regular kernel before LTS'; return 1; }
    fi
    return 0
}

# Override only the r30 GRUB payload/preflight contract.  The generic r30
# source-preserving adapter executor remains the write engine.
r30_validate_grub_backup_payload() { r31_validate_grub_backup_payload "$@"; }

r30_grub_restore_preflight() {
    local dir=$1 reference
    r30_restore_common_preflight "$dir" grub || return 1
    load_backup_metadata "$dir" || return 1
    case ${format_version:-} in
        3|4) ;;
        *) fail "Cross-source GRUB restore requires backup format v3 or v4 (found v${format_version:-unknown})"; return 1 ;;
    esac
    [[ ${esp_mount:-} == "$ESP_MOUNT" ]] || {
        fail "Backup ESP mountpoint (${esp_mount:-unknown}) differs from the current validated topology ($ESP_MOUNT)."
        fail 'The switcher refuses to rewrite backup topology during a live restore.'
        return 1
    }
    r30_grub_backup_kernel_set_matches "$dir" || {
        fail 'Installed kernel versions do not exactly match the selected GRUB backup.'
        return 1
    }
    reference=$(cat /proc/cmdline 2>/dev/null || true)
    r31_validate_grub_backup_payload "$dir" "$reference" || {
        fail "GRUB v${format_version:-unknown} backup payload failed restore validation: ${R30_GRUB_RESTORE_REASON:-unknown reason}"
        return 1
    }
    if [[ $format_version == 3 ]]; then
        ok "Legacy GRUB v3 policy/grub.cfg are integrity-covered, structurally complete, and cmdline-equivalent to the proven $(bootloader_display_name "$BOOTLOADER") runtime"
    else
        ok "GRUB v4 backup policy/grub.cfg are structurally complete and cmdline-equivalent to the proven $(bootloader_display_name "$BOOTLOADER") runtime"
    fi
}

# Same staging procedure as r30; only the user-visible version label changes.
r30_stage_grub_from_backup() {
    local dir=$1 source_id=$2 original_order=$3 reference=$4 target_id restore_version=${format_version:-unknown}
    install_target_packages grub || return 1
    have grub-install && have grub-mkconfig && have grub-probe && have grub-script-check || { fail 'Required GRUB tooling is unavailable after package installation'; return 1; }

    r25_install_grub_policy_from_backup "$dir" || return 1
    sudo mkdir -p /boot/grub || return 1
    sudo grub-install --target=x86_64-efi --efi-directory="$ESP_MOUNT" --bootloader-id=cachyos --force || return 1
    find_nvram_entry_for_target grub || { fail 'Could not find canonical GRUB NVRAM entry after grub-install'; return 1; }
    target_id=$TARGET_NVRAM_ID
    set_source_first_boot_order "$source_id" "$target_id" "$original_order" || return 1
    r26_restore_source_fallback_after_target_stage || return 1
    sudo grub-mkconfig -o /boot/grub/grub.cfg || return 1
    adapter_target_validate grub || return 1
    r26_record_target_adapter grub || return 1
    R26_STAGED_TARGET_ID=${target_id^^}
    ok "Staged validated GRUB v$restore_version backup policy as canonical Boot$R26_STAGED_TARGET_ID"
}

r30_restore_grub_backup() {
    local dir=$1 ans restore_version
    r30_grub_restore_preflight "$dir" || return 1
    load_backup_metadata "$dir" || return 1
    restore_version=$format_version
    printf '\nGRUB v%s cross-backend restore transaction plan:\n' "$restore_version"
    if [[ $restore_version == 3 ]]; then
        printf '  - Legacy v3: use only integrity-covered backed-up GRUB policy/config evidence; generated /boot/grub is rebuilt from the current CachyOS packages and validated kernel set.\n'
    else
        printf '  - Restore the validated backed-up GRUB policy while rebuilding generated /boot/grub from the current CachyOS packages and validated kernel set.\n'
    fi
    printf '  - Keep current %s authoritative while staging restored GRUB.\n' "$(bootloader_display_name "$BOOTLOADER")"
    printf '  - Keep the source first in persistent BootOrder, deep-validate both sides, then arm restored GRUB exactly once with BootNext.\n'
    printf '  - After a proven GRUB userspace boot, promote GRUB and retire only ownership-proven source state.\n'
    printf '  - /etc/fstab is reference-only and is never rewritten.\n\n'
    offer_operation_backup || return 1
    read -r -p "Type RESTORE to stage this validated GRUB v$restore_version backup, or anything else to cancel: " ans
    [[ $ans == RESTORE ]] || { printf 'Restore cancelled. No boot state was modified by the restore.\n'; return 0; }
    r30_grub_restore_preflight "$dir" || { fail 'Write-boundary revalidation failed; no GRUB restore state was staged.'; return 1; }
    load_backup_metadata "$dir" || return 1
    r30_execute_restored_adapter "$dir" grub r30_stage_grub_from_backup
}

# Surface the format version in the backup chooser.  It is operationally
# relevant now that compatible legacy backups intentionally remain supported.
list_backups() {
    discover_backups_quiet
    ((${#DISCOVERED_BACKUPS[@]})) || { printf 'No backups found in %s\n' "$BACKUP_ROOT"; return 0; }
    local d idx=1 version
    for d in "${DISCOVERED_BACKUPS[@]}"; do
        if validate_backup_compatibility "$d"; then
            load_backup_metadata "$d" >/dev/null 2>&1 || true
            version=${format_version:-?}
            if [[ ${bootloader:-} == limine && ${format_version:-} == 3 ]]; then
                printf '[%d] %s  [v%s, VALID, COMPATIBLE, LEGACY RECONSTRUCTABLE]\n' "$idx" "$(basename "$d")" "$version"
            else
                printf '[%d] %s  [v%s, VALID, COMPATIBLE]\n' "$idx" "$(basename "$d")" "$version"
            fi
        elif validate_backup "$d"; then
            load_backup_metadata "$d" >/dev/null 2>&1 || true
            version=${format_version:-?}
            printf '[%d] %s  [v%s, VALID, NOT RESTORABLE: %s]\n' "$idx" "$(basename "$d")" "$version" "$BACKUP_COMPATIBILITY_REASON"
        else
            printf '[%d] %s  [INVALID: %s]\n' "$idx" "$(basename "$d")" "$BACKUP_VALIDATION_REASON"
        fi
        ((idx++))
    done
}
