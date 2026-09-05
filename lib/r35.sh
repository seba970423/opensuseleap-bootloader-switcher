#!/usr/bin/env bash
# r35: rEFInd v4 transactional backup restore + transaction-result truthfulness.
#
# Hardware work through r34 proved GRUB -> rEFInd end-to-end, including direct
# kernel PreviousBoot proof, ownership-gated GRUB retirement, and post-cleanup
# deep validation. r35 therefore enables the first rEFInd backup restore target:
# a compatible v4 rEFInd snapshot may be restored from a deeply validated GRUB
# source through the same r26 BootNext/runtime-proof transaction engine.
#
# The rEFInd backup is intentionally broader than the restore write set. r35
# restores only boot-critical adapter-owned state:
#   * EFI/refind immutable install/config tree, EXCLUDING EFI/refind/vars
#   * /boot/refind_linux.conf
# /etc/refind.d remains a captured diagnostic/package snapshot and is not
# rewritten by the live restore backend.
#
# r35 also fixes misleading stale status after manual recovery/finalization.
# The inherited on-disk result filename is retained for compatibility, but the
# UI now describes it as the last recorded transaction event; successful manual
# runtime validation/finalization refreshes that record.

R35_REFIND_RESTORE_REASON=""

r35_refind_backup_root() {
    local dir=$1 backup_mount=$2 rel
    rel=${backup_mount#/}
    [[ -n $rel && $rel != *'..'* ]] || return 1
    printf '%s/files/%s/EFI/refind\n' "$dir" "$rel"
}

r35_refind_backup_kernel_set_matches() {
    r28_systemd_backup_kernel_set_matches "$@"
}

# Emit a metadata-independent byte/shape manifest. The mutable rEFInd vars
# namespace is deliberately omitted; it is regenerated/updated by rEFInd itself
# and r33 already excludes it from immutable runtime ownership proof.
r35_refind_tree_manifest() {
    local root=${1%/} out=$2 mode=${3:-user} path rel type hash count=0
    local -a finder
    : >"$out" || return 1
    [[ -n $root ]] || return 1

    if [[ $mode == protected ]]; then
        sudo -n test -d "$root" 2>/dev/null || return 1
        sudo -n test -L "$root" 2>/dev/null && return 1
        finder=(sudo -n find "$root" -mindepth 1 -print0)
    else
        [[ -d $root && ! -L $root ]] || return 1
        finder=(find "$root" -mindepth 1 -print0)
    fi

    while IFS= read -r -d '' path; do
        rel=${path#"$root"/}
        [[ -n $rel ]] || continue
        [[ $rel == vars || $rel == vars/* ]] && continue
        [[ $rel != *$'\n'* && $rel != *$'\r'* && $rel != *$'\t'* ]] || return 1

        if [[ $mode == protected ]]; then
            if sudo -n test -L "$path" 2>/dev/null; then
                return 1
            elif sudo -n test -f "$path" 2>/dev/null; then
                type=f
                hash=$(sudo -n sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || true)
            elif sudo -n test -d "$path" 2>/dev/null; then
                type=d
                hash='-'
            else
                return 1
            fi
        else
            if [[ -L $path ]]; then
                return 1
            elif [[ -f $path ]]; then
                type=f
                hash=$(sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || true)
            elif [[ -d $path ]]; then
                type=d
                hash='-'
            else
                return 1
            fi
        fi
        [[ $type == d || $hash =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
        printf '%s\t%s\t%s\n' "$type" "$hash" "$rel" >>"$out" || return 1
        ((count+=1))
    done < <("${finder[@]}" 2>/dev/null | LC_ALL=C sort -z)

    ((count > 0))
}

r35_validate_refind_backup_payload() {
    local dir=$1 reference=$2 backup_root conf linuxconf efi options list m
    R35_REFIND_RESTORE_REASON=""

    [[ ${format_version:-} == 4 ]] || { R35_REFIND_RESTORE_REASON='rEFInd live restore requires backup format v4'; return 1; }
    [[ ${bootloader:-} == refind ]] || { R35_REFIND_RESTORE_REASON='selected backup is not a rEFInd backup'; return 1; }
    [[ ${payload_policy:-} == bootloader-owned-paths ]] || { R35_REFIND_RESTORE_REASON='unexpected rEFInd backup payload policy'; return 1; }
    [[ -n ${boot_efi_path:-} && ${boot_efi_path,,} == '\efi\refind\refind_x64.efi' ]] || { R35_REFIND_RESTORE_REASON='backup does not identify the canonical rEFInd EFI executable'; return 1; }
    [[ -n $reference ]] || { R35_REFIND_RESTORE_REASON='known-good source runtime command line is empty'; return 1; }

    backup_root=$(r35_refind_backup_root "$dir" "${esp_mount:-}") || { R35_REFIND_RESTORE_REASON='invalid backup ESP mount metadata'; return 1; }
    conf="$backup_root/refind.conf"
    efi="$backup_root/refind_x64.efi"
    linuxconf="$dir/files/boot/refind_linux.conf"

    [[ -d $backup_root && ! -L $backup_root ]] || { R35_REFIND_RESTORE_REASON='backup is missing a safe EFI/refind tree'; return 1; }
    [[ -f $conf && ! -L $conf ]] || { R35_REFIND_RESTORE_REASON='backup is missing a safe refind.conf'; return 1; }
    [[ -f $efi && ! -L $efi ]] || { R35_REFIND_RESTORE_REASON='backup is missing a safe refind_x64.efi'; return 1; }
    [[ -f $linuxconf && ! -L $linuxconf ]] || { R35_REFIND_RESTORE_REASON='backup is missing a safe /boot/refind_linux.conf'; return 1; }

    m=$(mktemp) || return 1
    if ! r35_refind_tree_manifest "$backup_root" "$m" user; then
        rm -f -- "$m"
        R35_REFIND_RESTORE_REASON='backup EFI/refind immutable tree contains an unsafe object or is empty'
        return 1
    fi
    rm -f -- "$m"

    list=$(refind_kernel_list_value "$conf" 2>/dev/null || true)
    [[ $list == "$REFIND_CACHYOS_KERNEL_LIST" ]] || {
        R35_REFIND_RESTORE_REASON="backup extra_kernel_version_strings does not match CachyOS reference (${list:-unset})"
        return 1
    }

    options=$(refind_standard_options "$linuxconf" 2>/dev/null || true)
    [[ -n $options ]] || { R35_REFIND_RESTORE_REASON='backup refind_linux.conf has no standard options line'; return 1; }
    pending_cmdline_equivalent "$options" "$reference" || {
        R35_REFIND_RESTORE_REASON='backup rEFInd standard options are not token-equivalent to the currently proven GRUB runtime command line'
        return 1
    }
    grep -Eq '^"Boot to single-user mode"[[:space:]]+".+[[:space:]]single"$' "$linuxconf" || {
        R35_REFIND_RESTORE_REASON='backup refind_linux.conf is missing the single-user options line'
        return 1
    }
    return 0
}

r35_refind_restore_preflight() {
    local dir=$1 reference
    pending_exists && { fail 'A staged bootloader migration is already pending'; return 1; }
    validate_backup_compatibility "$dir" || { fail "Backup is not compatible: $BACKUP_COMPATIBILITY_REASON"; return 1; }
    load_backup_metadata "$dir" || { fail 'Could not load selected backup metadata'; return 1; }
    [[ ${bootloader:-} == refind ]] || { fail 'Selected backup is not a rEFInd backup'; return 1; }

    detect_bootloader
    [[ $BOOTLOADER == grub ]] || {
        fail 'r35 transactional rEFInd backup restore currently requires the verified source bootloader to be GRUB.'
        fail 'Same-backend rEFInd rollback and non-GRUB restore sources remain deliberately disabled.'
        return 1
    }

    printf '\nr35 rEFInd restore preflight:\n'
    run_validation preflight || { fail 'Base preflight failed; no boot state was modified'; return 1; }
    is_cachyos || { fail 'rEFInd live restore is intentionally restricted to CachyOS/Arch-like systems'; return 1; }
    if bootcurrent_is_generic_fallback; then
        fail 'The current session was booted through the generic UEFI fallback path.'
        fail 'Restore transactions require the canonical GRUB source NVRAM entry; reboot normally first.'
        return 1
    fi
    have sudo && have pacman || { fail 'sudo and pacman are required'; return 1; }
    [[ -z ${BOOT_NEXT:-} ]] || { fail "BootNext is already set to Boot${BOOT_NEXT^^}; refusing to overwrite firmware intent"; return 1; }

    printf '\nSource adapter deep gate (GRUB):\n'
    adapter_source_validate grub || { fail 'The active GRUB source failed deep validation; rEFInd restore staging is refused'; return 1; }
    r26_target_namespace_clean refind || return 1

    load_backup_metadata "$dir" || return 1
    [[ ${format_version:-} == 4 ]] || { fail "rEFInd live restore requires backup format v4 (found v${format_version:-unknown})"; return 1; }
    [[ ${esp_mount:-} == "$ESP_MOUNT" ]] || {
        fail "Backup ESP mountpoint (${esp_mount:-unknown}) differs from the current validated topology ($ESP_MOUNT)."
        fail 'The switcher refuses to rewrite backup topology during a live restore.'
        return 1
    }
    [[ $ESP_MOUNT == /boot ]] || {
        fail "r35 rEFInd restore currently certifies the CachyOS /boot ESP topology only; detected $ESP_MOUNT."
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
    ok 'rEFInd v4 immutable EFI/config payload is structurally complete and cmdline-equivalent to the proven GRUB runtime'
    info 'EFI/refind/vars is intentionally not restored; rEFInd recreates/updates that mutable runtime namespace on boot.'
    info '/etc/refind.d remains reference/package state and is not rewritten by the live restore backend.'
}

r35_restore_refind_immutable_tree() {
    local src=${1%/} dst=${2%/} item base src_manifest dst_manifest
    src_manifest=$(mktemp) || return 1
    dst_manifest=$(mktemp) || { rm -f -- "$src_manifest"; return 1; }

    if ! r35_refind_tree_manifest "$src" "$src_manifest" user; then
        rm -f -- "$src_manifest" "$dst_manifest"
        fail 'Could not build safe immutable manifest for backed-up EFI/refind tree'
        return 1
    fi

    sudo rm -rf -- "$dst" || { rm -f -- "$src_manifest" "$dst_manifest"; return 1; }
    sudo mkdir -p -- "$dst" || { rm -f -- "$src_manifest" "$dst_manifest"; return 1; }

    while IFS= read -r -d '' item; do
        base=$(basename -- "$item")
        [[ $base == vars ]] && continue
        if [[ -L $item || ( ! -f $item && ! -d $item ) ]]; then
            rm -f -- "$src_manifest" "$dst_manifest"
            fail "Unsafe object appeared in backed-up rEFInd tree during restore: $item"
            return 1
        fi
        sudo cp -a --no-preserve=all -- "$item" "$dst/" || { rm -f -- "$src_manifest" "$dst_manifest"; return 1; }
    done < <(find "$src" -mindepth 1 -maxdepth 1 -print0 2>/dev/null | LC_ALL=C sort -z)

    # Do not carry a stale PreviousBoot into the candidate. The first real rEFInd
    # test boot must create fresh runtime evidence that r33 can certify.
    sudo rm -rf -- "$dst/vars" 2>/dev/null || true

    if ! r35_refind_tree_manifest "$dst" "$dst_manifest" protected; then
        rm -f -- "$src_manifest" "$dst_manifest"
        fail 'Could not verify restored immutable EFI/refind tree'
        return 1
    fi
    LC_ALL=C sort -o "$src_manifest" "$src_manifest"
    LC_ALL=C sort -o "$dst_manifest" "$dst_manifest"
    if ! cmp -s -- "$src_manifest" "$dst_manifest"; then
        rm -f -- "$src_manifest" "$dst_manifest"
        fail 'Restored immutable EFI/refind tree does not byte/shape-match the validated backup'
        return 1
    fi
    rm -f -- "$src_manifest" "$dst_manifest"
    ok 'Restored byte-identical immutable rEFInd EFI/config tree; mutable vars were intentionally omitted'
}

r35_stage_refind_from_backup() {
    local dir=$1 source_id=$2 original_order=$3 reference=$4 target_id backup_root linuxconf
    local expected_source=$ESP_SOURCE expected_mount=$ESP_MOUNT expected_fstype=$ESP_FSTYPE expected_uuid=$ESP_UUID

    [[ -n $expected_source && -n $expected_mount && -n $expected_fstype && -n $expected_uuid ]] || {
        fail 'rEFInd restore staging requires a fully resolved ESP identity before refind-install'
        return 1
    }
    load_backup_metadata "$dir" || return 1
    backup_root=$(r35_refind_backup_root "$dir" "$esp_mount") || return 1
    linuxconf="$dir/files/boot/refind_linux.conf"

    install_target_packages refind || return 1
    have refind-install || { fail 'refind-install is unavailable after package installation'; return 1; }

    # Use refind-install only to establish the canonical firmware target. The
    # actual candidate bytes/config come from the integrity-validated backup.
    sudo refind-install || return 1
    r32_verify_refind_post_install_esp "$expected_source" "$expected_mount" "$expected_fstype" "$expected_uuid" || return 1
    r35_restore_refind_immutable_tree "$backup_root" "$ESP_MOUNT/EFI/refind" || return 1
    r28_restore_backup_file "$linuxconf" /boot/refind_linux.conf 0644 || return 1

    find_nvram_entry_for_target refind || { fail 'Could not find the canonical rEFInd NVRAM entry after refind-install'; return 1; }
    target_id=$TARGET_NVRAM_ID
    set_source_first_boot_order "$source_id" "$target_id" "$original_order" || return 1
    r26_restore_source_fallback_after_target_stage || return 1
    adapter_target_validate refind || return 1
    r26_record_target_adapter refind || return 1
    R26_STAGED_TARGET_ID=${target_id^^}
    ok "Staged validated rEFInd v4 backup as canonical Boot$R26_STAGED_TARGET_ID"
}

r35_restore_refind_backup() {
    local dir=$1 ans
    r35_refind_restore_preflight "$dir" || return 1
    printf '\nrEFInd v4 cross-backend restore transaction plan:\n'
    printf '  - Keep current GRUB authoritative while staging the validated backed-up rEFInd candidate.\n'
    printf '  - Restore the immutable EFI/refind tree and /boot/refind_linux.conf exactly; do not restore stale EFI/refind/vars runtime evidence.\n'
    printf '  - Leave /etc/refind.d untouched; it is backup reference/package state, not adapter-owned live restore state.\n'
    printf '  - Keep GRUB first in persistent BootOrder, deep-validate both sides, then arm restored rEFInd exactly once with BootNext.\n'
    printf '  - Require a real rEFInd userspace boot plus PreviousBoot direct-kernel proof before GRUB retirement.\n'
    printf '  - /etc/fstab is reference-only and is never rewritten.\n\n'
    offer_operation_backup || return 1
    read -r -p 'Type RESTORE to stage this validated rEFInd v4 backup, or anything else to cancel: ' ans
    [[ $ans == RESTORE ]] || { printf 'Restore cancelled. No boot state was modified by the restore.\n'; return 0; }
    r35_refind_restore_preflight "$dir" || { fail 'Write-boundary revalidation failed; no rEFInd restore state was staged.'; return 1; }
    load_backup_metadata "$dir" || return 1
    r30_execute_restored_adapter "$dir" refind r35_stage_refind_from_backup
}

# r35 adds exactly one new restore route: verified GRUB source -> rEFInd v4
# backup target. Existing proven restore dispatch remains untouched.
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
        grub:refind) r35_restore_refind_backup "$dir" ;;
        *)
            printf 'Cross-backend restore %s -> %s is not enabled in r35.\n' "$(bootloader_display_name "$source")" "$(bootloader_display_name "$target")"
            [[ $source == refind || $target == refind ]] && printf 'r35 certifies only GRUB -> restored rEFInd; same-backend and non-GRUB rEFInd restore sources remain disabled.\n'
            return 2
            ;;
    esac
}

r35_write_local_transaction_result() {
    local status=$1 detail=$2 out tmp
    # Root-owned automatic resume has its own trusted resume.conf writer. Do not
    # bypass that ownership model; this helper is for the interactive/user path.
    [[ -z ${R22_RESUME_BUNDLE:-} ]] || return 0
    mkdir -p -- "$PENDING_STATE_DIR" || return 1
    chmod 700 -- "$PENDING_STATE_DIR" 2>/dev/null || true
    out="$PENDING_STATE_DIR/$R22_RESULT_FILE_NAME"
    tmp=$(mktemp "$PENDING_STATE_DIR/.result.XXXXXX") || return 1
    {
        printf 'status=%s\n' "$status"
        printf 'time=%s\n' "$(date -Is)"
        printf 'detail=%s\n' "$detail"
    } >"$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 600 -- "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$out"
}

# The filename remains last-auto-result.txt for backward compatibility, but it
# now records both automatic and manual transaction outcomes.
r22_show_last_auto_result() {
    local f="$PENDING_STATE_DIR/$R22_RESULT_FILE_NAME"
    [[ -f $f ]] || return 0
    if pending_exists; then
        printf 'Last transaction result:\n'
    else
        printf 'Last recorded transaction event (historical; no migration is pending):\n'
    fi
    sed 's/^/  /' "$f" 2>/dev/null || true
    printf '\n'
}

# Preserve the inherited runtime validator for legacy state, but correct r26+
# adapter UX and refresh the user-visible result record after manual recovery.
eval "$(declare -f validate_pending_target_runtime | sed '1s/validate_pending_target_runtime/validate_pending_target_runtime_pre_r35/')"
validate_pending_target_runtime() {
    if [[ ${PENDING_FORMAT:-} != "$R26_PENDING_FORMAT" ]]; then
        validate_pending_target_runtime_pre_r35 "$@"
        return $?
    fi

    validate_pending_compatibility || { fail "Pending migration is not compatible: $PENDING_REASON"; return 1; }
    [[ $PENDING_PHASE == boot-armed || $PENDING_PHASE == runtime-validated ]] || {
        fail "Runtime validation requires a tool-armed one-time boot (phase is $PENDING_PHASE)"
        return 1
    }
    detect_bootloader
    [[ $BOOTLOADER == "$PENDING_TARGET" ]] || { fail "Current bootloader is $BOOTLOADER, not the recorded target $PENDING_TARGET"; return 1; }
    [[ $BOOT_CURRENT == "$PENDING_TARGET_BOOT_ID" ]] || { fail "Runtime proof requires BootCurrent=Boot$PENDING_TARGET_BOOT_ID (found Boot${BOOT_CURRENT:-unknown})"; return 1; }
    nvram_id_matches_path "$PENDING_TARGET_BOOT_ID" "$PENDING_TARGET_EFI_PATH" || { fail 'BootCurrent target NVRAM entry does not have the exact recorded EFI path'; return 1; }

    run_validation preflight || return 1
    validate_pending_compatibility || { fail "Pending migration became incompatible during runtime preflight: $PENDING_REASON"; return 1; }

    local next first diag source_name target_name
    next=$(pending_bootnext_id)
    if [[ -n $next && $next != "$PENDING_TARGET_BOOT_ID" ]]; then
        fail "BootNext now belongs to unrelated Boot$next; refusing to alter it or certify the runtime"
        return 1
    elif [[ $next == "$PENDING_TARGET_BOOT_ID" ]]; then
        warn "Firmware still reports transaction BootNext=Boot$next after target boot; clearing it to restore one-shot semantics"
        sudo efibootmgr -N >/dev/null || { fail 'Could not clear the consumed transaction BootNext'; return 1; }
        [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext remained set after explicit clear'; return 1; }
        ok 'BootNext is now cleared; future normal boots follow persistent source-first BootOrder'
    else
        ok 'BootNext is consumed/cleared after the one-time target boot'
    fi

    first=$(pending_bootorder_first)
    [[ $first == "$PENDING_OLD_BOOT_ID" ]] || { fail "Persistent BootOrder changed; expected source Boot$PENDING_OLD_BOOT_ID first, found Boot${first:-unknown}"; return 1; }
    ok "Persistent BootOrder still keeps source Boot$PENDING_OLD_BOOT_ID first"

    pending_validate_running_kernel || return 1
    pending_validate_runtime_cmdline_against_source || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    printf '\nDeep target validation from the actually booted target session:\n'
    validate_pending_target_deep || return 1
    printf '\nRe-validating the untouched source recovery path after target boot:\n'
    verify_pending_source_recovery_unchanged || return 1

    diag=$(pending_capture_runtime_diagnostics runtime-pass | tail -n1 || true)
    [[ -n $diag ]] && printf 'Runtime diagnostic snapshot: %s\n' "$diag"
    pending_set_phase runtime-validated || { fail 'Runtime checks passed but phase could not be persisted; no cleanup is permitted'; return 1; }
    PENDING_PHASE=runtime-validated
    source_name=$(bootloader_display_name "$PENDING_SOURCE")
    target_name=$(bootloader_display_name "$PENDING_TARGET")
    r35_write_local_transaction_result runtime-validated "$source_name -> $target_name runtime validation passed manually. Target Boot$PENDING_TARGET_BOOT_ID is proven; source cleanup has not yet run." || true

    printf '\nRUNTIME-VALIDATED %s -> %s one-time boot succeeded.\n' "$source_name" "$target_name"
    printf 'BootCurrent proves the recorded target EFI entry actually booted.\n'
    printf 'The actual target /proc/cmdline matches the recorded known-good source cmdline.\n'
    printf 'Persistent BootOrder is still source-first and BootNext is clear.\n'
    printf 'This exact adapter target state now has runtime proof. FINALIZE is eligible from Manage pending/staged migration.\n'
}

# Manual finalization used to leave a stale automatic-resume failure displayed
# forever. Refresh the result record only after the inherited finalizer returns
# success. Automatic root resume still writes its own result through r22.
eval "$(declare -f r26_finalize_adapter_transaction | sed '1s/r26_finalize_adapter_transaction/r26_finalize_adapter_transaction_pre_r35/')"
r26_finalize_adapter_transaction() {
    local source target target_id source_name target_name rc
    source=${PENDING_SOURCE:-}
    target=${PENDING_TARGET:-}
    target_id=${PENDING_TARGET_BOOT_ID:-}
    r26_finalize_adapter_transaction_pre_r35 "$@"
    rc=$?
    ((rc == 0)) || return "$rc"
    source_name=$(bootloader_display_name "$source")
    target_name=$(bootloader_display_name "$target")
    r35_write_local_transaction_result success "$source_name -> $target_name finalized successfully after validated runtime proof. Target Boot$target_id is first in persistent BootOrder; source cleanup was ownership-gated." || true
    return 0
}
