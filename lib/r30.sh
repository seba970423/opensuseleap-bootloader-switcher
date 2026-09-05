#!/usr/bin/env bash
# r30: generalized cross-backend backup restore matrix for the three certified
# backup families: GRUB, Limine and systemd-boot.
#
# r29 had three independent restore tunnels:
#   Limine -> restored GRUB
#   GRUB   -> restored Limine
#   GRUB   -> restored systemd-boot
# The underlying r26 adapter transaction engine already knows how to preserve,
# validate and retire GRUB/Limine/systemd-boot source state.  r30 keeps those
# hardware-proven restore tunnels untouched and adds the three missing direct
# cross-backend restore directions:
#   systemd-boot -> restored GRUB
#   systemd-boot -> restored Limine
#   Limine       -> restored systemd-boot
#
# Same-backend restore remains intentionally separate from a switch transaction;
# rEFInd restore remains disabled until its migration adapter earns hardware
# proof and a restore payload contract is defined.

R30_GRUB_RESTORE_REASON=""
R30_LIMINE_RESIDUE_SUBDIR="r30-limine-target-residue"

r30_cross_restore_supported() {
    case "$1:$2" in
        grub:limine|limine:grub|grub:systemd-boot|systemd-boot:grub|limine:systemd-boot|systemd-boot:limine) return 0 ;;
        *) return 1 ;;
    esac
}

# r26 format-5 state is structurally generic, but its original parser admitted
# only the GRUB hub pairs.  Extend only the two new non-GRUB restore pairs; live
# migration support remains unchanged and still uses the r26 certification
# matrix in operation_supported()/run_live_operation().
eval "$(declare -f load_pending_state | sed '1s/load_pending_state/load_pending_state_pre_r30/')"
load_pending_state() {
    if [[ $(r26_state_format) != "$R26_PENDING_FORMAT" ]]; then
        load_pending_state_pre_r30 "$@"
        return $?
    fi

    if load_pending_state_pre_r30 "$@"; then
        return 0
    fi
    [[ ${PENDING_REASON:-} == 'unsupported r26 adapter migration direction' ]] || return 1
    case "${PENDING_SOURCE:-}:${PENDING_TARGET:-}" in
        limine:systemd-boot|systemd-boot:limine) ;;
        *) return 1 ;;
    esac

    # The pre-r30 parser stopped at the direction gate, so finish the remaining
    # format/integrity fields exactly as r26 would for an admitted pair.
    [[ $PENDING_FORMAT == "$R26_PENDING_FORMAT" ]] || { PENDING_REASON='wrong r26 state format'; return 1; }
    [[ $PENDING_ADAPTER_REVISION == "$R26_ADAPTER_REVISION" ]] || { PENDING_REASON='unsupported adapter-state revision'; return 1; }
    [[ -n $PENDING_MACHINE_ID && -n $PENDING_OLD_BOOT_ID && -n $PENDING_TARGET_BOOT_ID ]] || { PENDING_REASON='missing transaction identity'; return 1; }
    [[ -n $PENDING_SOURCE_CMDLINE ]] || { PENDING_REASON='missing source kernel command line'; return 1; }
    [[ -n $PENDING_SOURCE_MANIFEST && -n $PENDING_TARGET_MANIFEST ]] || { PENDING_REASON='missing adapter ownership manifests'; return 1; }
    PENDING_REASON='valid'
    return 0
}

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

    printf '\nr30 cross-backend restore preflight:\n'
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
            # Limine legacy finalization may intentionally leave unproven
            # inactive target residue (for example EFI/LIMINE/*.bak). r30 can
            # preserve such residue exactly at the write boundary, but a live
            # Limine NVRAM entry would make target ownership ambiguous.
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
        *) fail "No r30 restore target gate for $target"; return 1 ;;
    esac
    return 0
}

r30_grub_backup_kernel_set_matches() { r25_grub_backup_kernel_set_matches "$@"; }

r30_validate_grub_backup_payload() {
    local dir=$1 reference=$2 policy cfg backup_efi root_token mode_token ver kid linux_line initrd_line
    local regular_line='' lts_line='' preferred configured_top rows=0
    R30_GRUB_RESTORE_REASON=""

    [[ ${format_version:-} == 4 ]] || { R30_GRUB_RESTORE_REASON='new cross-source GRUB restore requires backup format v4'; return 1; }
    [[ ${bootloader:-} == grub ]] || { R30_GRUB_RESTORE_REASON='selected backup is not a GRUB backup'; return 1; }
    [[ ${payload_policy:-} == bootloader-owned-paths ]] || { R30_GRUB_RESTORE_REASON='unexpected GRUB backup payload policy'; return 1; }
    backup_efi=${boot_efi_path:-}
    [[ -n $backup_efi && ${backup_efi,,} == '\efi\cachyos\grubx64.efi' ]] || { R30_GRUB_RESTORE_REASON='backup does not identify the canonical CachyOS GRUB EFI executable'; return 1; }
    [[ -n $reference ]] || { R30_GRUB_RESTORE_REASON='known-good source runtime command line is empty'; return 1; }

    policy="$dir/files/etc/default/grub"
    cfg="$dir/files/boot/grub/grub.cfg"
    [[ -f $policy && ! -L $policy ]] || { R30_GRUB_RESTORE_REASON='backup is missing a safe /etc/default/grub'; return 1; }
    [[ -f $cfg && ! -L $cfg ]] || { R30_GRUB_RESTORE_REASON='backup is missing a safe /boot/grub/grub.cfg'; return 1; }
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

r30_grub_restore_preflight() {
    local dir=$1 reference
    r30_restore_common_preflight "$dir" grub || return 1
    load_backup_metadata "$dir" || return 1
    [[ ${format_version:-} == 4 ]] || { fail "Cross-source GRUB restore requires backup format v4 (found v${format_version:-unknown})"; return 1; }
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
    r30_validate_grub_backup_payload "$dir" "$reference" || {
        fail "GRUB v4 backup payload failed restore validation: ${R30_GRUB_RESTORE_REASON:-unknown reason}"
        return 1
    }
    ok "GRUB v4 backup policy/grub.cfg are structurally complete and cmdline-equivalent to the proven $(bootloader_display_name "$BOOTLOADER") runtime"
}

r30_systemd_restore_preflight() {
    local dir=$1 reference reason
    r30_restore_common_preflight "$dir" systemd-boot || return 1
    load_backup_metadata "$dir" || return 1
    [[ ${format_version:-} == 4 ]] || { fail "systemd-boot live restore requires backup format v4 (found v${format_version:-unknown})"; return 1; }
    [[ ${esp_mount:-} == "$ESP_MOUNT" ]] || {
        fail "Backup ESP mountpoint (${esp_mount:-unknown}) differs from the current validated topology ($ESP_MOUNT)."
        fail 'The switcher refuses to rewrite backup topology during a live restore.'
        return 1
    }
    [[ $ESP_MOUNT == /boot ]] || { fail "systemd-boot restore currently requires the CachyOS /boot ESP topology; detected $ESP_MOUNT."; return 1; }
    r28_systemd_backup_kernel_set_matches "$dir" || {
        fail 'Installed kernel versions do not exactly match the selected systemd-boot backup.'
        return 1
    }
    reference=$(cat /proc/cmdline 2>/dev/null || true)
    if ! r28_validate_systemd_backup_payload "$dir" "$reference"; then
        reason=${R28_SDBOOT_RESTORE_REASON:-unknown reason}
        reason=${reason//GRUB/source}
        fail "systemd-boot v4 backup payload failed restore validation: $reason"
        return 1
    fi
    ok "systemd-boot v4 backup payload is structurally complete and cmdline-equivalent to the proven $(bootloader_display_name "$BOOTLOADER") runtime"
}

r30_limine_v4_payload_shape_safe() {
    local dir=$1 backup_mount=$2 machine=$3 managed
    managed=$(r23_backup_limine_managed_path "$dir" "$backup_mount" "$machine")
    [[ -d $managed && ! -L $managed ]] || return 1
    ! find "$managed" \( -type l -o \( ! -type f ! -type d \) \) -print -quit 2>/dev/null | grep -q .
}

r30_limine_restore_preflight() {
    local dir=$1 current_cmd backup_cmd
    r30_restore_common_preflight "$dir" limine || return 1
    load_backup_metadata "$dir" || return 1
    [[ ${format_version:-} == 3 || ${format_version:-} == 4 ]] || { fail "Limine live restore requires backup format v3 or v4 (found v${format_version:-unknown})"; return 1; }
    [[ ${esp_mount:-} == "$ESP_MOUNT" ]] || {
        fail "Backup ESP mountpoint (${esp_mount:-unknown}) differs from the current validated topology ($ESP_MOUNT)."
        fail 'The switcher refuses to rewrite backup topology during a live restore.'
        return 1
    }
    r23_limine_restore_kernel_set_matches "$dir" || {
        fail 'Installed kernel versions do not exactly match the selected Limine backup.'
        return 1
    }
    r23_limine_backup_theme_is_cachyos "$dir" "$esp_mount" || { fail 'Selected Limine backup does not contain the captured CachyOS theme block.'; return 1; }
    backup_cmd=$(r23_backup_limine_cmdline "$dir" 2>/dev/null || true)
    current_cmd=$(cat /proc/cmdline 2>/dev/null || true)
    [[ -n $backup_cmd && -n $current_cmd ]] || { fail 'Could not resolve backup/current kernel command line'; return 1; }
    pending_cmdline_equivalent "$backup_cmd" "$current_cmd" || {
        fail "Backup Limine cmdline is not token-equivalent to the currently proven $(bootloader_display_name "$BOOTLOADER") runtime cmdline."
        return 1
    }
    if [[ $format_version == 3 ]]; then
        info 'Legacy Limine v3 backup is reconstructable against the current deeply validated conventional kernel/initramfs artifacts.'
    else
        r30_limine_v4_payload_shape_safe "$dir" "$esp_mount" "$machine_id" || { fail 'Limine v4 managed payload contains an unsafe object or is incomplete'; return 1; }
        info 'Limine v4 backup contains the self-contained config/splash/managed payload tree.'
    fi
    return 0
}

r30_limine_residue_root() {
    local snapshot=${1:-${TRANSACTION_SNAPSHOT_DIR:-}}
    [[ -n $snapshot ]] || return 1
    printf '%s/%s\n' "$snapshot" "$R30_LIMINE_RESIDUE_SUBDIR"
}

r30_prepare_limine_target_residue() {
    local root paths path rel snap count=0
    root=$(r30_limine_residue_root) || return 1
    paths="$root/paths.txt"
    rm -rf -- "$root" 2>/dev/null || true
    mkdir -p -- "$root/files" || return 1
    : >"$paths" || return 1

    while IFS= read -r path; do
        [[ -n $path ]] || continue
        if sudo -n test -e "$path" 2>/dev/null || sudo -n test -L "$path" 2>/dev/null || [[ -e $path || -L $path ]]; then
            if sudo -n test -L "$path" 2>/dev/null || [[ -L $path ]]; then
                fail "Inactive Limine target residue contains a top-level symlink and cannot be snapshotted safely: $path"
                return 1
            fi
            copy_path_into_backup "$path" "$root" || { fail "Could not snapshot inactive Limine target residue: $path"; return 1; }
            rel=${path#/}; snap="$root/files/$rel"
            if sudo -n test -d "$path" 2>/dev/null || [[ -d $path ]]; then
                if find "$snap" -type l -print -quit 2>/dev/null | grep -q .; then
                    fail "Inactive Limine target residue tree contains a symlink and cannot be preserved safely: $path"
                    return 1
                fi
                sudo -n diff -r --no-dereference -- "$path" "$snap" >/dev/null 2>&1 || { fail "Inactive Limine residue snapshot differs from source: $path"; return 1; }
            else
                sudo -n cmp -s -- "$path" "$snap" || { fail "Inactive Limine residue snapshot differs from source: $path"; return 1; }
            fi
            printf '%s\n' "$path" >>"$paths" || return 1
            ((count+=1))
        fi
    done < <(r26_adapter_paths limine)

    printf '%s\n' "$count" >"$root/snapshot-complete" || return 1
    while IFS= read -r path; do
        [[ -n $path ]] || continue
        sudo rm -rf -- "$path" || { fail "Could not clear snapshotted inactive Limine target residue: $path"; return 1; }
        ok "Preserved and cleared inactive Limine target residue before target staging: $path"
    done <"$paths"
    printf '1\n' >"$root/target-cleared" || return 1
    return 0
}

r30_restore_limine_target_residue() {
    local snapshot=${1:-${TRANSACTION_SNAPSHOT_DIR:-}} root paths path rel snap rc=0
    root=$(r30_limine_residue_root "$snapshot" 2>/dev/null || true)
    [[ -n $root && -f $root/snapshot-complete && -f $root/paths.txt ]] || return 0
    paths="$root/paths.txt"

    # Once snapshot-complete exists, every adapter-owned Limine path was either
    # captured in paths.txt or proven absent. Remove candidate leftovers, then
    # restore only the exact pre-stage paths that actually existed.
    while IFS= read -r path; do
        [[ -n $path ]] || continue
        if sudo -n test -e "$path" 2>/dev/null || sudo -n test -L "$path" 2>/dev/null || [[ -e $path || -L $path ]]; then
            sudo rm -rf -- "$path" || rc=1
        fi
    done < <(r26_adapter_paths limine)

    while IFS= read -r path; do
        [[ -n $path ]] || continue
        rel=${path#/}; snap="$root/files/$rel"
        [[ -e $snap || -L $snap ]] || { fail "Limine residue rollback snapshot disappeared: $snap"; rc=1; continue; }
        restore_copy_from_backup "$root" "$rel" || { rc=1; continue; }
        if [[ -d $snap ]]; then
            sudo -n diff -r --no-dereference -- "$path" "$snap" >/dev/null 2>&1 || { fail "Restored inactive Limine residue differs from its snapshot: $path"; rc=1; }
        else
            sudo -n cmp -s -- "$path" "$snap" || { fail "Restored inactive Limine residue differs from its snapshot: $path"; rc=1; }
        fi
        ((rc == 0)) && ok "Restored exact pre-stage inactive Limine target residue: $path"
    done <"$paths"
    return "$rc"
}

# r26 never had a Limine generic target because GRUB <-> Limine stayed on the
# proven legacy engine. Add uncommitted cleanup only for r30's new systemd-boot
# -> restored Limine transaction, including exact inactive-target residue restore.
eval "$(declare -f r26_remove_uncommitted_target_namespaces | sed '1s/r26_remove_uncommitted_target_namespaces/r26_remove_uncommitted_target_namespaces_pre_r30/')"
r26_remove_uncommitted_target_namespaces() {
    local target=$1 path id
    if [[ $target != limine ]]; then
        r26_remove_uncommitted_target_namespaces_pre_r30 "$@"
        return $?
    fi

    while IFS= read -r id; do
        [[ -n $id ]] || continue
        sudo efibootmgr -b "$id" -B >/dev/null 2>&1 || return 1
        ok "Removed uncommitted Limine NVRAM entry Boot$id"
    done < <(r21_nvram_ids_for_esp_path "$(target_expected_efi_path limine)")

    if ! r30_restore_limine_target_residue "${TRANSACTION_SNAPSHOT_DIR:-}"; then
        fail 'Could not restore exact pre-stage inactive Limine target residue during rollback.'
        return 1
    fi
    # If no residue snapshot existed, the target was proven clean before stage.
    if [[ ! -f ${TRANSACTION_SNAPSHOT_DIR:-/nonexistent}/$R30_LIMINE_RESIDUE_SUBDIR/snapshot-complete ]]; then
        while IFS= read -r path; do
            [[ -n $path ]] || continue
            if sudo -n test -e "$path" 2>/dev/null || sudo -n test -L "$path" 2>/dev/null || [[ -e $path || -L $path ]]; then
                sudo rm -rf -- "$path" || return 1
                ok "Removed uncommitted Limine target namespace: $path"
            fi
        done < <(r26_adapter_paths limine)
    fi
    return 0
}

r30_stage_limine_v4_from_backup() {
    local dir=$1 backup_mount=$2 machine=$3 conf splash managed dst_managed
    conf=$(r23_backup_limine_conf_path "$dir" "$backup_mount")
    splash=$(r23_backup_limine_splash_path "$dir" "$backup_mount")
    managed=$(r23_backup_limine_managed_path "$dir" "$backup_mount" "$machine")
    [[ -f $conf && -f $splash && -d $managed ]] || { fail 'Limine v4 backup payload is incomplete'; return 1; }
    r30_limine_v4_payload_shape_safe "$dir" "$backup_mount" "$machine" || { fail 'Limine v4 backup managed tree contains unsafe objects'; return 1; }
    r23_install_limine_policy_from_backup "$dir" || return 1
    [[ ! -e "$ESP_MOUNT/limine.conf" && ! -e "$ESP_MOUNT/$R23_LIMINE_SPLASH_NAME" ]] || { fail 'Limine config/splash appeared after target residue preparation'; return 1; }
    dst_managed="$ESP_MOUNT/$machine"
    [[ ! -e $dst_managed ]] || { fail 'Limine managed payload directory appeared after target residue preparation'; return 1; }
    r28_restore_backup_file "$conf" "$ESP_MOUNT/limine.conf" 0644 || return 1
    r28_restore_backup_file "$splash" "$ESP_MOUNT/$R23_LIMINE_SPLASH_NAME" 0644 || return 1
    sudo cp -a --no-preserve=all -- "$managed" "$dst_managed" || return 1
    ok 'Restored VFAT-safe Limine v4 config, splash and managed kernel/initramfs payload tree'
}

r30_stage_limine_from_backup() {
    local dir=$1 source_id=$2 original_order=$3 reference=$4 target_id='' install_rc=0
    local restore_format backup_mount backup_machine
    load_backup_metadata "$dir" || return 1
    restore_format=$format_version; backup_mount=$esp_mount; backup_machine=$machine_id

    install_target_packages limine || return 1
    have limine-install || { fail 'limine-install is unavailable after package installation'; return 1; }
    have limine-entry-tool || { fail 'limine-entry-tool is unavailable after package installation'; return 1; }

    case "$restore_format" in
        3) r23_stage_limine_from_v3_backup "$dir" || return 1 ;;
        4) r30_stage_limine_v4_from_backup "$dir" "$backup_mount" "$backup_machine" || return 1 ;;
        *) fail 'Unsupported Limine restore format'; return 1 ;;
    esac

    sudo limine-install || install_rc=$?
    if ((install_rc == 0)); then sudo limine-install --fallback || install_rc=$?; fi
    find_nvram_entry_for_target limine || { fail 'Could not find the canonical Limine NVRAM entry after limine-install'; return 1; }
    target_id=$TARGET_NVRAM_ID
    set_source_first_boot_order "$source_id" "$target_id" "$original_order" || return 1
    r26_restore_source_fallback_after_target_stage || return 1
    ((install_rc == 0)) || { fail "limine-install exited with status $install_rc"; return 1; }
    adapter_target_validate limine || return 1
    r26_record_target_adapter limine || return 1
    R26_STAGED_TARGET_ID=${target_id^^}
    ok "Staged validated Limine backup as canonical Boot$R26_STAGED_TARGET_ID"
}

r30_stage_grub_from_backup() {
    local dir=$1 source_id=$2 original_order=$3 reference=$4 target_id
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
    ok "Staged validated GRUB v4 backup policy as canonical Boot$R26_STAGED_TARGET_ID"
}

r30_execute_restored_adapter() {
    local dir=$1 target=$2 stage_fn=$3 source=$BOOTLOADER source_id=${BOOT_CURRENT^^} original_order=$BOOT_ORDER reference target_id
    [[ -n $source_id && -n $original_order ]] || { fail 'Could not capture source NVRAM identity/BootOrder'; return 1; }
    reference=$(cat /proc/cmdline 2>/dev/null || true)
    [[ -n $reference ]] || { fail 'Could not capture known-good source cmdline'; return 1; }

    R26_STAGED_TARGET_ID=""
    adapter_source_snapshot "$source" || return 1
    if [[ $target == limine ]]; then
        if ! r30_prepare_limine_target_residue; then
            fail 'Could not preserve/clear inactive Limine target residue before staging.'
            r26_cleanup_uncommitted_target limine "$original_order" "$source_id" "$source" || true
            return 1
        fi
    fi

    if ! "$stage_fn" "$dir" "$source_id" "$original_order" "$reference"; then
        fail "Restored $(bootloader_display_name "$target") target staging failed before a candidate transaction was committed."
        r26_cleanup_uncommitted_target "$target" "$original_order" "$source_id" "$source" || true
        return 1
    fi
    target_id=${R26_STAGED_TARGET_ID^^}
    if [[ ! $target_id =~ ^[0-9A-F]{4}$ ]]; then
        fail "Restored $(bootloader_display_name "$target") adapter did not publish a valid NVRAM identifier."
        r26_cleanup_uncommitted_target "$target" "$original_order" "$source_id" "$source" || true
        return 1
    fi

    if ! adapter_source_validate "$source"; then
        fail "Source $(bootloader_display_name "$source") validation failed after restore staging; candidate will not be committed."
        r26_cleanup_uncommitted_target "$target" "$original_order" "$source_id" "$source" || true
        return 1
    fi
    if [[ $(pending_bootorder_first) != "$source_id" ]]; then
        fail 'Source is no longer first after restore staging; candidate will not be committed.'
        r26_cleanup_uncommitted_target "$target" "$original_order" "$source_id" "$source" || true
        return 1
    fi

    OPERATION_BACKUP=$dir
    if ! r26_write_pending_adapter "$source" "$target" "$source_id" "$original_order" "$target_id" candidate-ready; then
        fail 'Could not persist the restored adapter transaction; rolling back the uncommitted candidate.'
        r26_cleanup_uncommitted_target "$target" "$original_order" "$source_id" "$source" || true
        return 1
    fi
    load_pending_state || return 1
    verify_pending_source_recovery_unchanged || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1

    printf '\nRESTORE-CANDIDATE-READY %s -> %s transaction staged successfully.\n' "$(bootloader_display_name "$source")" "$(bootloader_display_name "$target")"
    printf 'The restored candidate is source-preserving; %s remains first until real runtime proof.\n' "$(bootloader_display_name "$source")"
    r23_arm_candidate_automatically || return 1
    if ! r22_prepare_resume_bundle; then
        fail 'Could not prepare automatic post-reboot continuation. Clearing transaction BootNext for safety.'
        r22_rollback_automation_arm
        return 1
    fi
    r23_prompt_reboot
}

r30_restore_grub_backup() {
    local dir=$1 ans
    r30_grub_restore_preflight "$dir" || return 1
    printf '\nGRUB v4 cross-backend restore transaction plan:\n'
    printf '  - Keep current %s authoritative while restoring the validated backed-up GRUB policy.\n' "$(bootloader_display_name "$BOOTLOADER")"
    printf '  - Rebuild generated /boot/grub from current CachyOS packages + current validated kernels instead of copying stale generated module metadata.\n'
    printf '  - Keep the source first in persistent BootOrder, deep-validate both sides, then arm restored GRUB exactly once with BootNext.\n'
    printf '  - After a proven GRUB userspace boot, promote GRUB and retire only ownership-proven source state.\n'
    printf '  - /etc/fstab is reference-only and is never rewritten.\n\n'
    offer_operation_backup || return 1
    read -r -p 'Type RESTORE to stage this validated GRUB v4 backup, or anything else to cancel: ' ans
    [[ $ans == RESTORE ]] || { printf 'Restore cancelled. No boot state was modified by the restore.\n'; return 0; }
    r30_grub_restore_preflight "$dir" || { fail 'Write-boundary revalidation failed; no GRUB restore state was staged.'; return 1; }
    load_backup_metadata "$dir" || return 1
    r30_execute_restored_adapter "$dir" grub r30_stage_grub_from_backup
}

r30_restore_systemd_boot_backup() {
    local dir=$1 ans
    r30_systemd_restore_preflight "$dir" || return 1
    printf '\nsystemd-boot v4 cross-backend restore transaction plan:\n'
    printf '  - Restore only adapter-owned systemd-boot state from the validated backup; foreign BLS state stays untouched.\n'
    printf '  - Keep current %s first in persistent BootOrder while the restored systemd-boot candidate is deeply validated.\n' "$(bootloader_display_name "$BOOTLOADER")"
    printf '  - Arm restored systemd-boot exactly once with BootNext; runtime proof is required before source retirement.\n'
    printf '  - /etc/fstab is reference-only and is never rewritten.\n\n'
    offer_operation_backup || return 1
    read -r -p 'Type RESTORE to stage this validated systemd-boot v4 backup, or anything else to cancel: ' ans
    [[ $ans == RESTORE ]] || { printf 'Restore cancelled. No boot state was modified by the restore.\n'; return 0; }
    r30_systemd_restore_preflight "$dir" || { fail 'Write-boundary revalidation failed; no systemd-boot restore state was staged.'; return 1; }
    load_backup_metadata "$dir" || return 1
    r30_execute_restored_adapter "$dir" systemd-boot r28_stage_systemd_boot_from_backup
}

r30_restore_limine_backup() {
    local dir=$1 ans
    r30_limine_restore_preflight "$dir" || return 1
    load_backup_metadata "$dir" || return 1
    printf '\nLimine cross-backend restore transaction plan:\n'
    if [[ $format_version == 3 ]]; then
        printf '  - Legacy v3: restore the backed-up policy and reconstruct the themed managed payload from the current validated kernel/initramfs artifacts.\n'
    else
        printf '  - v4: restore the self-contained Limine config/splash/managed payload using VFAT-safe copy semantics.\n'
    fi
    printf '  - Preserve any inactive Limine target residue exactly before replacement so an uncommitted/pending rollback can put it back.\n'
    printf '  - Keep current %s first in persistent BootOrder while restored Limine is deeply validated.\n' "$(bootloader_display_name "$BOOTLOADER")"
    printf '  - Arm Limine exactly once with BootNext; only a real Limine userspace boot authorizes source retirement.\n'
    printf '  - After runtime proof, materialize a byte-identical Limine generic EFI fallback unless an unrelated pre-existing fallback must be preserved.\n'
    printf '  - /etc/fstab is reference-only and is never rewritten.\n\n'
    offer_operation_backup || return 1
    read -r -p 'Type RESTORE to stage this validated Limine backup, or anything else to cancel: ' ans
    [[ $ans == RESTORE ]] || { printf 'Restore cancelled. No boot state was modified by the restore.\n'; return 0; }
    r30_limine_restore_preflight "$dir" || { fail 'Write-boundary revalidation failed; no Limine restore state was staged.'; return 1; }
    load_backup_metadata "$dir" || return 1
    r30_execute_restored_adapter "$dir" limine r30_stage_limine_from_backup
}

# Pending rollback needs one extra step for r30's systemd-boot -> Limine path:
# after deleting the candidate ownership manifest, restore any exact inactive
# Limine target residue that was preserved before staging.
eval "$(declare -f rollback_pending_candidate | sed '1s/rollback_pending_candidate/rollback_pending_candidate_pre_r30/')"
r30_rollback_pending_limine_restore() {
    validate_pending_compatibility || return 1
    detect_bootloader
    [[ $BOOTLOADER == "$PENDING_SOURCE" && $BOOT_CURRENT == "$PENDING_OLD_BOOT_ID" ]] || { fail "${SWITCHER_RELEASE:-r30} Limine rollback is allowed only from the recorded source session"; return 1; }
    verify_pending_source_recovery_unchanged || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    local next
    next=$(pending_bootnext_id)
    [[ -z $next || $next == "$PENDING_TARGET_BOOT_ID" ]] || { fail "Unrelated BootNext=Boot$next exists; refusing rollback"; return 1; }
    [[ $next != "$PENDING_TARGET_BOOT_ID" ]] || sudo efibootmgr -N >/dev/null || return 1
    r22_disarm_user_resume_bundle || true
    if boot_id_exists "$PENDING_TARGET_BOOT_ID"; then sudo efibootmgr -b "$PENDING_TARGET_BOOT_ID" -B >/dev/null || return 1; fi
    r26_remove_owned_manifest_paths "$PENDING_TARGET_MANIFEST" || return 1
    r30_restore_limine_target_residue "$PENDING_TRANSACTION_SNAPSHOT_DIR" || return 1
    r26_restore_fallback_on_rollback || return 1
    sudo efibootmgr -o "$PENDING_ORIGINAL_BOOT_ORDER" >/dev/null || return 1
    remove_pending_transaction_snapshot || true
    rm -f -- "$PENDING_STATE_FILE"
    ok 'Rolled back the Limine candidate; source state and pre-stage inactive Limine residue remain authoritative.'
}

rollback_pending_candidate() {
    if [[ $(r26_state_format) == "$R26_PENDING_FORMAT" ]]; then
        load_pending_state || return 1
        if [[ $PENDING_TARGET == limine && $PENDING_SOURCE == systemd-boot ]]; then
            r30_rollback_pending_limine_restore
            return $?
        fi
    fi
    rollback_pending_candidate_pre_r30 "$@"
}

# r26 finalizes systemd-boot fallback state after runtime proof. Do the same for
# a Limine target in the new r30 adapter pair: the uploaded v3 backup itself
# proves the canonical Limine EFI and EFI/BOOT fallback are byte-identical.
eval "$(declare -f r26_finalize_target_fallback | sed '1s/r26_finalize_target_fallback/r26_finalize_target_fallback_pre_r30/')"
r26_finalize_target_fallback() {
    if [[ ${PENDING_FORMAT:-} != "$R26_PENDING_FORMAT" || ${PENDING_TARGET:-} != limine ]]; then
        r26_finalize_target_fallback_pre_r30 "$@"
        return $?
    fi
    local fallback="$PENDING_ESP_MOUNT/EFI/BOOT/BOOTX64.EFI" hash
    if [[ $PENDING_OLD_FALLBACK_EXISTED == 1 && $PENDING_SOURCE_FALLBACK_OWNED != 1 ]]; then
        hash=$(sudo -n sha256sum -- "$fallback" 2>/dev/null | awk '{print $1}' || true)
        [[ $hash == "$PENDING_OLD_FALLBACK_HASH" ]] || { fail 'Unrelated pre-existing generic EFI fallback changed before Limine finalization'; return 1; }
        info 'Preserving unrelated pre-existing EFI/BOOT/BOOTX64.EFI; Limine will use its canonical NVRAM entry.'
        return 0
    fi
    sudo mkdir -p -- "$(dirname -- "$fallback")" || return 1
    sudo cp -- "$PENDING_TARGET_EFI_RESOLVED" "$fallback" || return 1
    hash=$(sudo -n sha256sum -- "$fallback" 2>/dev/null | awk '{print $1}' || true)
    [[ $hash == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'Could not materialize byte-identical Limine generic fallback'; return 1; }
    ok 'Installed byte-identical Limine generic EFI fallback after runtime proof'
}

# Keep the already hardware-proven restore tunnels intact; route only the three
# newly missing matrix directions through the generic r30 adapter executor.
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
        *)
            printf 'Cross-backend restore %s -> %s is not enabled in r30.\n' "$(bootloader_display_name "$source")" "$(bootloader_display_name "$target")"
            [[ $source == refind || $target == refind ]] && printf 'rEFInd restore remains disabled until its migration backend is hardware-tested and its backup restore contract is certified.\n'
            return 2
            ;;
    esac
}
