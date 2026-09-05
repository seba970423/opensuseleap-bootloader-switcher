#!/usr/bin/env bash
# leap16-r75: ownership-proven retirement of an orphaned rEFInd target left by
# an earlier, already-finalized rEFInd session.
#
# The normal r64 clean-target gate remains unchanged.  When current GRUB is
# canonical but EFI/refind + /boot/refind_linux.conf still exist without a
# same-ESP rEFInd firmware alias, this layer offers a separate CLEAN action.
# It accepts only the exact switcher-owned r66/r67 shape, snapshots it, removes
# no GRUB or firmware state, and stops.  A later selector run must pass r64's
# original clean-target gate before a new rEFInd transaction can be staged.

R75_REFIND_RESIDUE_SNAPSHOT=''

leap16_r75_refind_root() { printf '%s/EFI/refind\n' "${ESP_MOUNT%/}"; }
leap16_r75_refind_linuxconf() { printf '/boot/refind_linux.conf\n'; }

leap16_r75_path_exists() {
    local path=$1
    sudo -n test -e "$path" 2>/dev/null || sudo -n test -L "$path" 2>/dev/null \
        || [[ -e $path || -L $path ]]
}

leap16_r75_refind_residue_present() {
    local root linuxconf
    root=$(leap16_r75_refind_root); linuxconf=$(leap16_r75_refind_linuxconf)
    leap16_r75_path_exists "$root" || leap16_r75_path_exists "$linuxconf"
}

leap16_r75_refind_ids_csv() {
    leap16_r48_ids_for_current_esp_path "$LEAP16_R64_REFIND_EFI" \
        | awk 'NF{print toupper($0)}' | LC_ALL=C sort -u | paste -sd, -
}

leap16_r75_read_privileged() {
    local path=$1
    if [[ -r $path ]]; then cat -- "$path"; else sudo -n cat -- "$path" 2>/dev/null; fi
}

leap16_r75_refind_tree_shape_safe() {
    local root=$1 unsafe
    sudo -n test -d "$root" 2>/dev/null || [[ -d $root ]] \
        || { fail "Orphan candidate is not a directory: $root"; return 1; }
    ! sudo -n test -L "$root" 2>/dev/null && [[ ! -L $root ]] \
        || { fail "Orphan candidate root is a symlink: $root"; return 1; }
    unsafe=$(sudo -n find "$root" -mindepth 1 -type l -print -quit 2>/dev/null || true)
    [[ -z $unsafe ]] || { fail "Switch-owned rEFInd staging never creates symlinks; refusing residue ownership: $unsafe"; return 1; }
    unsafe=$(sudo -n find "$root" -mindepth 1 ! -type f ! -type d -print -quit 2>/dev/null || true)
    [[ -z $unsafe ]] || { fail "Unexpected special object in rEFInd residue: $unsafe"; return 1; }
    return 0
}

leap16_r75_linuxconf_matches_current_writer() {
    local path=$1 clean expected actual rc=0
    clean=$(r26_refind_cmdline "$(cat /proc/cmdline 2>/dev/null || true)")
    [[ -n $clean ]] || return 1
    expected=$(mktemp) || return 1
    {
        printf '"Boot with standard options" "%s"\n' "$clean"
        printf '"Boot to single-user mode" "%s single"\n' "$clean"
    } >"$expected" || { rm -f -- "$expected"; return 1; }
    actual=$(leap16_hash_file_privileged "$path")
    [[ $actual =~ ^[0-9A-Fa-f]{64}$ && $actual == "$(sha256sum -- "$expected" | awk '{print $1}')" ]] || rc=$?
    rm -f -- "$expected"
    return "$rc"
}

leap16_r75_prove_orphaned_refind_residue() {
    local root linuxconf marker conf marker_text managed_count ids
    root=$(leap16_r75_refind_root); linuxconf=$(leap16_r75_refind_linuxconf)
    marker="$root/.opensuse-bootloader-switcher-source"; conf="$root/refind.conf"

    leap16_r75_refind_tree_shape_safe "$root" || return 1
    (sudo -n test -f "$linuxconf" 2>/dev/null || [[ -f $linuxconf ]]) \
        && ! sudo -n test -L "$linuxconf" 2>/dev/null && [[ ! -L $linuxconf ]] \
        || { fail "A safe regular $linuxconf is required to prove the paired residue"; return 1; }
    (sudo -n test -f "$marker" 2>/dev/null || [[ -f $marker ]]) \
        && ! sudo -n test -L "$marker" 2>/dev/null && [[ ! -L $marker ]] \
        || { fail 'The exact r66 controlled-binary ownership marker is missing or unsafe'; return 1; }
    marker_text=$(leap16_r75_read_privileged "$marker" 2>/dev/null || true)
    [[ $marker_text == "$LEAP16_R66_REFIND_DOWNLOAD_MARKER" ]] \
        || { fail 'The rEFInd source marker is not the exact r66 controlled-staging identity'; return 1; }
    (sudo -n test -f "$conf" 2>/dev/null || [[ -f $conf ]]) \
        && ! sudo -n test -L "$conf" 2>/dev/null && [[ ! -L $conf ]] \
        || { fail 'Managed rEFInd configuration is missing or unsafe'; return 1; }
    managed_count=$(leap16_r75_read_privileged "$conf" 2>/dev/null | grep -Fxc "$LEAP16_R64_REFIND_MARKER" || true)
    [[ $managed_count == 1 ]] || { fail 'rEFInd config does not contain exactly one switcher policy marker'; return 1; }
    leap16_r75_linuxconf_matches_current_writer "$linuxconf" \
        || { fail 'refind_linux.conf is not byte-identical to the switcher writer for the current proven kernel command line'; return 1; }
    ids=$(leap16_r75_refind_ids_csv)
    [[ -z $ids ]] || { fail "Canonical rEFInd firmware alias(es) still exist: Boot${ids//,/ Boot}"; return 1; }
    validate_refind_boot_chain residue \
        || { fail 'The orphan candidate failed the unchanged deep Leap rEFInd validator'; return 1; }
    ok 'Proved a complete switcher-owned r66/r67 rEFInd filesystem residue with no canonical same-ESP firmware alias'
}

leap16_r75_cleanup_preflight() {
    printf '\n%s orphaned-rEFInd cleanup preflight:\n' "${SWITCHER_RELEASE:-leap16-r75}"
    pending_exists && { fail 'A staged migration is already pending; residue cleanup will not stack transactions'; return 1; }
    run_validation preflight || { fail 'Base preflight failed; no boot state was modified'; return 1; }
    is_leap16 || { fail 'This cleanup backend is restricted to openSUSE Leap 16'; return 1; }
    leap16_require_sudo_session || return 1
    detect_bootloader
    [[ $BOOTLOADER == grub ]] || { fail 'Orphaned-rEFInd cleanup is available only from current GRUB2'; return 1; }
    leap16_r73_current_is_native_grub_path \
        || { fail 'BootCurrent is not a native openSUSE shim/direct-GRUB alias on this ESP'; return 1; }
    [[ -z ${BOOT_NEXT:-} ]] || { fail "BootNext is already set to Boot${BOOT_NEXT^^}"; return 1; }
    local p
    for p in efibootmgr find tar sha256sum cmp; do have "$p" || { fail "$p is required for safe residue cleanup"; return 1; }; done
    validate_grub_boot_chain current \
        || { fail 'Canonical GRUB source validation failed; residue cleanup is forbidden'; return 1; }
    leap16_r75_prove_orphaned_refind_residue || return 1
    ok 'Cleanup preflight passed; GRUB is canonical and remains authoritative'
}

leap16_r75_cleanup_plan() {
    printf '\nOwnership-gated orphaned-rEFInd cleanup plan:\n'
    printf '  1. Re-prove canonical native GRUB, empty BootNext, and the complete switcher-owned r66/r67 residue shape.\n'
    printf '  2. Snapshot EFI/refind, /boot/refind_linux.conf, exact hashes/manifests, and the complete firmware table before deletion.\n'
    printf '  3. Revalidate every proof at the write boundary, then remove only those two rEFInd paths.\n'
    printf '  4. Require the unchanged r64 clean-target gate, canonical GRUB validation, and byte-identical firmware state.\n'
    printf '  5. Stop. Select rEFInd again in a new run to begin a clean GRUB2 -> rEFInd transaction.\n'
    printf '  No GRUB file, Boot#### variable, BootOrder, BootNext, or EFI/BOOT fallback is modified.\n'
}

leap16_r75_snapshot_residue() {
    local root linuxconf parent base hash
    root=$(leap16_r75_refind_root); linuxconf=$(leap16_r75_refind_linuxconf)
    mkdir -p -- "$PENDING_STATE_DIR" || return 1
    chmod 700 -- "$PENDING_STATE_DIR" 2>/dev/null || true
    R75_REFIND_RESIDUE_SNAPSHOT=$(mktemp -d "$PENDING_STATE_DIR/.refind-residue.XXXXXX") || return 1
    chmod 700 -- "$R75_REFIND_RESIDUE_SNAPSHOT" 2>/dev/null || true
    write_privileged_tree_manifest "$root" "$R75_REFIND_RESIDUE_SNAPSHOT/refind.manifest.tsv" || return 1
    [[ -s $R75_REFIND_RESIDUE_SNAPSHOT/refind.manifest.tsv ]] || return 1
    parent=$(dirname -- "$root"); base=$(basename -- "$root")
    sudo tar -C "$parent" -cpf - "$base" >"$R75_REFIND_RESIDUE_SNAPSHOT/refind.tar" || return 1
    tar -tf "$R75_REFIND_RESIDUE_SNAPSHOT/refind.tar" >/dev/null || return 1
    hash=$(leap16_hash_file_privileged "$linuxconf")
    [[ $hash =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
    printf '%s\n' "$hash" >"$R75_REFIND_RESIDUE_SNAPSHOT/refind-linux.sha256" || return 1
    parent=$(dirname -- "$linuxconf"); base=$(basename -- "$linuxconf")
    sudo tar -C "$parent" -cpf - "$base" >"$R75_REFIND_RESIDUE_SNAPSHOT/refind-linux.tar" || return 1
    tar -tf "$R75_REFIND_RESIDUE_SNAPSHOT/refind-linux.tar" >/dev/null || return 1
    sudo -n efibootmgr -v >"$R75_REFIND_RESIDUE_SNAPSHOT/efibootmgr-v.txt" || return 1
    [[ -s $R75_REFIND_RESIDUE_SNAPSHOT/efibootmgr-v.txt ]] || return 1
    ok 'Created the mandatory exact rollback snapshot and firmware baseline'
}

leap16_r75_snapshot_still_exact() {
    local root linuxconf expected current
    root=$(leap16_r75_refind_root); linuxconf=$(leap16_r75_refind_linuxconf)
    pending_verify_tree_manifest "$root" "$R75_REFIND_RESIDUE_SNAPSHOT/refind.manifest.tsv" || return 1
    expected=$(cat "$R75_REFIND_RESIDUE_SNAPSHOT/refind-linux.sha256" 2>/dev/null || true)
    current=$(leap16_hash_file_privileged "$linuxconf")
    [[ $expected =~ ^[0-9A-Fa-f]{64}$ && $current == "$expected" ]] || return 1
    return 0
}

leap16_r75_firmware_unchanged() {
    local current rc=0
    current=$(mktemp) || return 1
    sudo -n efibootmgr -v >"$current" || { rm -f -- "$current"; return 1; }
    cmp -s -- "$R75_REFIND_RESIDUE_SNAPSHOT/efibootmgr-v.txt" "$current" || rc=$?
    rm -f -- "$current"
    return "$rc"
}

leap16_r75_restore_residue_snapshot() {
    local root linuxconf parent expected
    root=$(leap16_r75_refind_root); linuxconf=$(leap16_r75_refind_linuxconf)
    [[ -n $R75_REFIND_RESIDUE_SNAPSHOT && -d $R75_REFIND_RESIDUE_SNAPSHOT ]] || return 1
    sudo rm -rf -- "$root" || return 1
    parent=$(dirname -- "$root"); sudo mkdir -p -- "$parent" || return 1
    sudo tar -C "$parent" -xpf "$R75_REFIND_RESIDUE_SNAPSHOT/refind.tar" || return 1
    pending_verify_tree_manifest "$root" "$R75_REFIND_RESIDUE_SNAPSHOT/refind.manifest.tsv" || return 1
    sudo rm -f -- "$linuxconf" || return 1
    parent=$(dirname -- "$linuxconf")
    sudo tar -C "$parent" -xpf "$R75_REFIND_RESIDUE_SNAPSHOT/refind-linux.tar" || return 1
    expected=$(cat "$R75_REFIND_RESIDUE_SNAPSHOT/refind-linux.sha256" 2>/dev/null || true)
    [[ $expected =~ ^[0-9A-Fa-f]{64}$ && $(leap16_hash_file_privileged "$linuxconf") == "$expected" ]] || return 1
    leap16_r75_firmware_unchanged || return 1
    validate_grub_boot_chain current || return 1
    ok 'Restored the exact rEFInd residue snapshot; canonical GRUB and firmware intent remain unchanged'
}

leap16_r75_execute_cleanup() {
    local root linuxconf rc=0
    root=$(leap16_r75_refind_root); linuxconf=$(leap16_r75_refind_linuxconf)
    R75_REFIND_RESIDUE_SNAPSHOT=''
    if ! leap16_r75_snapshot_residue; then
        fail 'Could not create the mandatory residue rollback snapshot'
        [[ -z $R75_REFIND_RESIDUE_SNAPSHOT ]] || rm -rf -- "$R75_REFIND_RESIDUE_SNAPSHOT" 2>/dev/null || true
        R75_REFIND_RESIDUE_SNAPSHOT=''
        return 1
    fi
    if ! leap16_r75_cleanup_preflight || ! leap16_r75_snapshot_still_exact || ! leap16_r75_firmware_unchanged; then
        fail 'Write-boundary residue/firmware proof changed; nothing was deleted'
        rm -rf -- "$R75_REFIND_RESIDUE_SNAPSHOT" 2>/dev/null || true
        R75_REFIND_RESIDUE_SNAPSHOT=''
        return 1
    fi
    sudo rm -rf -- "$root" || rc=$?
    ((rc != 0)) || sudo rm -f -- "$linuxconf" || rc=$?
    if ((rc == 0)); then
        leap16_r64_refind_namespace_clean || rc=$?
        ((rc != 0)) || validate_grub_boot_chain current || rc=$?
        ((rc != 0)) || leap16_r75_firmware_unchanged || { fail 'Firmware state changed even though cleanup issued no firmware write'; rc=1; }
    fi
    if ((rc != 0)); then
        fail 'Residue cleanup was not proven complete; restoring the exact snapshot'
        if leap16_r75_restore_residue_snapshot; then
            rm -rf -- "$R75_REFIND_RESIDUE_SNAPSHOT" 2>/dev/null || true
            R75_REFIND_RESIDUE_SNAPSHOT=''
            return 1
        fi
        fail "Automatic residue restoration failed; recovery evidence remains at $R75_REFIND_RESIDUE_SNAPSHOT"
        return 1
    fi
    rm -rf -- "$R75_REFIND_RESIDUE_SNAPSHOT" 2>/dev/null || true
    R75_REFIND_RESIDUE_SNAPSHOT=''
    printf '\nOwnership-proven orphaned rEFInd residue was removed successfully.\n'
    printf 'Canonical GRUB and the complete firmware table are unchanged. Re-run the switcher and select rEFInd to stage a clean transaction.\n'
}

leap16_r75_run_cleanup_inner() {
    local answer
    leap16_r75_cleanup_preflight || return 1
    leap16_r75_cleanup_plan
    printf '\nA user backup is not offered for inactive orphan residue; an exact mandatory rollback snapshot is created before deletion.\n'
    read -r -p 'Type CLEAN to retire only this ownership-proven residue, or anything else to cancel: ' answer
    [[ $answer == CLEAN ]] || { printf '\nCleanup cancelled. No boot state was modified.\n'; return 0; }
    printf '\nRe-running all cleanup proofs at the write boundary...\n'
    leap16_r75_cleanup_preflight || { printf '\nWrite-boundary revalidation failed. Nothing was modified.\n'; return 1; }
    leap16_r75_execute_cleanup
}

# Intercept only GRUB -> rEFInd when the target namespace is non-empty.  Clean
# targets continue through the unchanged r74/r64 staging path.
if declare -F run_live_operation >/dev/null 2>&1; then
    eval "$(declare -f run_live_operation | sed '1s/run_live_operation/run_live_operation_pre_leap16_r75/')"
fi
run_live_operation() {
    local target=${1:-} current
    detect_bootloader; current=$BOOTLOADER
    if [[ $current:$target == grub:refind ]] && leap16_r75_refind_residue_present; then
        leap16_r44_with_transaction_transcript "$current" "$target" cleanup leap16_r75_run_cleanup_inner
        return $?
    fi
    run_live_operation_pre_leap16_r75 "$@"
}

# Final fresh-process boundary. Preserve every earlier executor and admit only
# the fixed, zero-argument GRUB -> rEFInd cleanup contract.
leap16_r46_transcript_child() {
    local diag=${1:-} expected_current=${2:-} target=${3:-} kind=${4:-} command=${5:-}
    shift 5 || true
    [[ -n $diag && -d $diag && ! -L $diag ]] || { printf '[FAIL] Invalid r46 transaction diagnostics directory\n' >&2; return 2; }
    case "$command" in
        leap16_r44_run_systemd_edge_inner|\
        leap16_r44_restore_grub_backup_from_systemd|\
        leap16_r44_restore_systemd_backup|\
        leap16_r51_run_systemd_to_limine_inner|\
        leap16_r61_restore_systemd_backup_from_limine|\
        leap16_r61_restore_limine_backup_from_systemd|\
        leap16_r64_run_refind_edge_inner|\
        leap16_r64_restore_refind_backup|\
        leap16_r64_restore_grub_backup_from_refind|\
        leap16_r64_restore_limine_backup_from_refind|\
        leap16_r64_restore_systemd_backup_from_refind|\
        leap16_r73_run_repair_inner|\
        leap16_r75_run_cleanup_inner) ;;
        *) printf '[FAIL] Refusing unknown r46 transcript child command: %s\n' "$command" >&2; return 2 ;;
    esac
    declare -F "$command" >/dev/null 2>&1 || { printf '[FAIL] r46 transcript child command is unavailable: %s\n' "$command" >&2; return 2; }
    case "$command" in
        leap16_r73_run_repair_inner)
            [[ $expected_current == grub && $target == grub && $kind == repair && $# == 0 ]] \
                || { printf '[FAIL] Invalid r73 repair transcript-child contract\n' >&2; return 2; }
            ;;
        leap16_r75_run_cleanup_inner)
            [[ $expected_current == grub && $target == refind && $kind == cleanup && $# == 0 ]] \
                || { printf '[FAIL] Invalid r75 cleanup transcript-child contract\n' >&2; return 2; }
            ;;
    esac
    LEAP16_R44_TRANSACTION_DIAG_DIR=$diag
    detect_bootloader
    [[ $BOOTLOADER == "$expected_current" ]] || {
        printf '[FAIL] Bootloader changed before transcript child start: expected %s, detected %s\n' "$expected_current" "$BOOTLOADER" >&2
        return 1
    }
    "$command" "$@"
}
