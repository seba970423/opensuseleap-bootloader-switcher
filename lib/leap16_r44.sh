#!/usr/bin/env bash
# leap16-r44: systemd-boot user backups + backup-before-switch parity +
# full interactive transaction transcript for the proven GRUB2 <-> systemd-boot
# matrix.
#
# This is deliberately an overlay on r43.  It does not alter the r31 proven
# GRUB2 <-> Limine transaction engine or the r43 firmware/fallback mechanics.
#
# New scope:
#   * user-owned systemd-boot backup creation/validation;
#   * GRUB2 <-> systemd-boot cross-backend restore using the already-proven
#     staged/runtime-proof engines;
#   * restore the missing user backup prompt on both normal systemd switch
#     directions;
#   * capture the interactive pre-reboot migration transcript instead of only
#     the root-owned resume half.

LEAP16_R44_SYSTEMD_BACKUP_SCHEMA='leap16-r44-systemd-v1'
LEAP16_R44_SYSTEMD_PAYLOAD_POLICY='opensuse-systemd-boot-owned-paths'
LEAP16_R44_DIAG_POINTER='r44-user-diagnostic-dir.txt'
LEAP16_R44_RESTORE_DIR=''
LEAP16_R44_TRANSACTION_DIAG_DIR=''

# ---------------------------------------------------------------------------
# systemd-boot backup ownership
# ---------------------------------------------------------------------------

if declare -F backup_paths_for_bootloader >/dev/null 2>&1; then
    eval "$(declare -f backup_paths_for_bootloader | sed '1s/backup_paths_for_bootloader/backup_paths_for_bootloader_pre_leap16_r44/')"
fi
backup_paths_for_bootloader() {
    local bl=$1 esp=${ESP_MOUNT:-/boot/efi} root ver
    esp=${esp%/}
    if [[ $bl != systemd-boot ]]; then
        backup_paths_for_bootloader_pre_leap16_r44 "$@"
        return $?
    fi

    root=$(leap16_r32_sdboot_payload_root) || return 1
    printf '%s\n' \
        /etc/sysconfig/bootloader \
        "$esp/EFI/systemd" \
        "$esp/loader/loader.conf" \
        "$root"
    [[ -e /etc/kernel/cmdline || -L /etc/kernel/cmdline ]] && printf '%s\n' /etc/kernel/cmdline
    collect_kernels
    for ver in "${KERNEL_VERSIONS[@]}"; do
        leap16_r32_sdboot_entry_path "$ver"
    done
}

leap16_r44_capture_systemd_shared_recovery_reference() {
    local dir=$1 esp=${ESP_MOUNT%/} src hash canonical_hash out
    src="$esp/EFI/BOOT/BOOTX64.EFI"
    out="$dir/systemd-shared-efi-boot-reference.tsv"
    mkdir -p -- "$dir/references/EFI-BOOT" || return 1
    printf 'name\tpath\texists\tsha256\n' >"$out" || return 1
    if path_exists_for_backup_read "$src"; then
        hash=$(hash_path_for_backup_read sha256sum "$src" || true)
        canonical_hash=$(hash_path_for_backup_read sha256sum "$esp/EFI/systemd/systemd-bootx64.efi" || true)
        [[ $hash =~ ^[0-9A-Fa-f]{64}$ && $canonical_hash =~ ^[0-9A-Fa-f]{64}$ ]] || {
            BACKUP_CREATE_ERROR='could not hash systemd-boot canonical/generic EFI reference state'
            return 1
        }
        [[ $hash == "$canonical_hash" ]] || {
            BACKUP_CREATE_ERROR='generic EFI fallback is not byte-identical to canonical systemd-boot at backup time'
            return 1
        }
        copy_reference_file_readonly "$src" "$dir/references/EFI-BOOT/BOOTX64.EFI" || {
            BACKUP_CREATE_ERROR='could not copy systemd-boot generic EFI fallback reference'
            return 1
        }
        [[ $(sha256sum -- "$dir/references/EFI-BOOT/BOOTX64.EFI" | awk '{print $1}') == "$hash" ]] || {
            BACKUP_CREATE_ERROR='systemd-boot generic fallback reference hash mismatch'
            return 1
        }
        printf 'BOOTX64.EFI\t%s\t1\t%s\n' "$src" "$hash" >>"$out" || return 1
    else
        BACKUP_CREATE_ERROR='finalized systemd-boot has no generic EFI fallback to record'
        return 1
    fi
    return 0
}

leap16_r44_systemd_backup_payload_valid() {
    local dir=$1 esp_rel mid root_rel ver entry linux initrd options expected_default default marker sortkey
    local -a _r44_backup_kernels=()
    local current_cmd=${2:-}
    esp_rel=${esp_mount:-}; esp_rel=${esp_rel#/}
    mid=${machine_id:-}
    [[ -n $esp_rel && $esp_rel != *'..'* ]] || { BACKUP_VALIDATION_REASON='invalid ESP mount metadata in systemd-boot backup'; return 1; }
    [[ -n $mid && $mid != *'/'* && $mid != *'..'* ]] || { BACKUP_VALIDATION_REASON='invalid machine ID in systemd-boot backup'; return 1; }

    local canonical="$dir/files/$esp_rel/EFI/systemd/systemd-bootx64.efi"
    local loader="$dir/files/$esp_rel/loader/loader.conf"
    local payload="$dir/files/$esp_rel/$mid/opensuse-bootloader-switcher"
    [[ -f $canonical && ! -L $canonical ]] || { BACKUP_VALIDATION_REASON='systemd-boot backup is missing canonical EFI/systemd/systemd-bootx64.efi'; return 1; }
    local efi_shape
    efi_shape=$(find "$dir/files/$esp_rel/EFI/systemd" -mindepth 1 -maxdepth 1 -printf '%y:%f\n' 2>/dev/null | LC_ALL=C sort)
    [[ $efi_shape == 'f:systemd-bootx64.efi' ]] || { BACKUP_VALIDATION_REASON='systemd-boot EFI/systemd backup namespace is not exactly the canonical x64 EFI file'; return 1; }
    [[ -f $loader && ! -L $loader ]] || { BACKUP_VALIDATION_REASON='systemd-boot backup is missing loader.conf'; return 1; }
    [[ -d $payload && ! -L $payload ]] || { BACKUP_VALIDATION_REASON='systemd-boot backup is missing the managed kernel/initrd payload tree'; return 1; }
    ! find "$payload" -type l -print -quit 2>/dev/null | grep -q . || { BACKUP_VALIDATION_REASON='systemd-boot managed payload contains a symlink'; return 1; }
    [[ $(od -An -tx1 -N2 -- "$canonical" 2>/dev/null | tr -d '[:space:]') == 4d5a ]] || { BACKUP_VALIDATION_REASON='systemd-boot EFI executable lacks an MZ header'; return 1; }
    if have file; then
        leap16_is_x86_64_efi_application "$canonical" || { BACKUP_VALIDATION_REASON='systemd-boot backup canonical EFI is not an x86-64 EFI application'; return 1; }
    fi

    mapfile -t _r44_backup_kernels < <(sed '/^[[:space:]]*$/d' "$dir/kernel-versions.txt" 2>/dev/null)
    ((${#_r44_backup_kernels[@]} > 0)) || { BACKUP_VALIDATION_REASON='systemd-boot backup has no recorded kernels'; return 1; }
    expected_default="opensuse-${_r44_backup_kernels[0]}.conf"
    default=$(awk '$1=="default"{print $2;exit}' "$loader" 2>/dev/null || true)
    [[ $default == "$expected_default" ]] || { BACKUP_VALIDATION_REASON="systemd-boot loader.conf default is unexpected (${default:-unset})"; return 1; }
    marker=$(head -n1 -- "$loader" 2>/dev/null || true)
    [[ $marker == "$LEAP16_R34_SDBOOT_MARKER" ]] || { BACKUP_VALIDATION_REASON='systemd-boot loader.conf ownership marker is not recognized'; return 1; }

    root_rel="/$mid/opensuse-bootloader-switcher"

    # Exact ownership shape: do not silently absorb stale switcher-owned BLS
    # entries or stale managed kernel directories into a user backup.
    local f base owned actual expected found child
    local -a actual_owned_entries=() expected_owned_entries=() actual_payload_dirs=() expected_payload_dirs=()
    for ver in "${_r44_backup_kernels[@]}"; do
        expected_owned_entries+=("opensuse-$ver.conf")
        expected_payload_dirs+=("$ver")
    done
    if [[ -d $dir/files/$esp_rel/loader/entries ]]; then
        while IFS= read -r -d '' f; do
            [[ $(head -n1 -- "$f" 2>/dev/null || true) == "$LEAP16_R34_SDBOOT_MARKER" ]] || continue
            actual_owned_entries+=("$(basename -- "$f")")
        done < <(find "$dir/files/$esp_rel/loader/entries" -mindepth 1 -maxdepth 1 -type f -name 'opensuse-*.conf' -print0 2>/dev/null | sort -z)
    fi
    mapfile -t actual_owned_entries < <(printf '%s\n' "${actual_owned_entries[@]}" | sed '/^$/d' | LC_ALL=C sort -u)
    mapfile -t expected_owned_entries < <(printf '%s\n' "${expected_owned_entries[@]}" | LC_ALL=C sort -u)
    [[ $(printf '%s\n' "${actual_owned_entries[@]}") == $(printf '%s\n' "${expected_owned_entries[@]}") ]] || { BACKUP_VALIDATION_REASON='systemd-boot backup has stale/missing switcher-owned BLS entries'; return 1; }

    while IFS= read -r -d '' child; do actual_payload_dirs+=("$(basename -- "$child")"); done < <(find "$payload" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
    mapfile -t actual_payload_dirs < <(printf '%s\n' "${actual_payload_dirs[@]}" | sed '/^$/d' | LC_ALL=C sort -u)
    mapfile -t expected_payload_dirs < <(printf '%s\n' "${expected_payload_dirs[@]}" | LC_ALL=C sort -u)
    [[ $(printf '%s\n' "${actual_payload_dirs[@]}") == $(printf '%s\n' "${expected_payload_dirs[@]}") ]] || { BACKUP_VALIDATION_REASON='systemd-boot managed payload has stale/missing kernel directories'; return 1; }
    for child in "$payload"/*; do
        [[ -d $child ]] || continue
        found=$(find "$child" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | LC_ALL=C sort)
        [[ $found == $'initrd\nlinux' ]] || { BACKUP_VALIDATION_REASON="systemd-boot managed payload directory $(basename -- "$child") is not exactly linux+initrd"; return 1; }
    done

    for ver in "${_r44_backup_kernels[@]}"; do
        entry="$dir/files/$esp_rel/loader/entries/opensuse-$ver.conf"
        [[ -f $entry && ! -L $entry ]] || { BACKUP_VALIDATION_REASON="systemd-boot backup is missing BLS entry for $ver"; return 1; }
        [[ $(head -n1 -- "$entry" 2>/dev/null || true) == "$LEAP16_R34_SDBOOT_MARKER" ]] || { BACKUP_VALIDATION_REASON="systemd-boot BLS ownership marker is wrong for $ver"; return 1; }
        [[ $(awk '$1=="title"{$1="";sub(/^[[:space:]]+/,"");print;exit}' "$entry") == 'openSUSE Leap 16' ]] || { BACKUP_VALIDATION_REASON="systemd-boot BLS title is wrong for $ver"; return 1; }
        [[ $(awk '$1=="version"{print $2;exit}' "$entry") == "$ver" ]] || { BACKUP_VALIDATION_REASON="systemd-boot BLS version is wrong for $ver"; return 1; }
        sortkey=$(awk '$1=="sort-key"{print $2;exit}' "$entry")
        [[ $sortkey == opensuse ]] || { BACKUP_VALIDATION_REASON="systemd-boot BLS sort-key is wrong for $ver"; return 1; }
        linux=$(awk '$1=="linux"{print $2;exit}' "$entry")
        initrd=$(awk '$1=="initrd"{print $2;exit}' "$entry")
        options=$(awk '$1=="options"{$1="";sub(/^[[:space:]]+/,"");print;exit}' "$entry")
        [[ $linux == "$root_rel/$ver/linux" && -f "$dir/files/$esp_rel/${linux#/}" ]] || { BACKUP_VALIDATION_REASON="systemd-boot kernel payload path is wrong/missing for $ver"; return 1; }
        [[ $initrd == "$root_rel/$ver/initrd" && -f "$dir/files/$esp_rel/${initrd#/}" ]] || { BACKUP_VALIDATION_REASON="systemd-boot initrd payload path is wrong/missing for $ver"; return 1; }
        [[ -n $options ]] || { BACKUP_VALIDATION_REASON="systemd-boot BLS options are empty for $ver"; return 1; }
        [[ -n ${root_uuid:-} ]] && grep -Eq "(^|[[:space:]])root=UUID=${root_uuid//./\.}([[:space:]]|$)" <<<"$options" || { BACKUP_VALIDATION_REASON="systemd-boot BLS options do not carry the backed-up root UUID for $ver"; return 1; }
        if [[ -n $current_cmd ]]; then
            pending_cmdline_equivalent "$options" "$current_cmd" || { BACKUP_VALIDATION_REASON="systemd-boot BLS options for $ver are not token-equivalent to the current source cmdline"; return 1; }
        fi
    done

    [[ -f $dir/systemd-shared-efi-boot-reference.tsv ]] || { BACKUP_VALIDATION_REASON='systemd-boot backup is missing shared EFI fallback reference metadata'; return 1; }
    local row_hash ref_hash
    row_hash=$(awk -F '\t' '$1=="BOOTX64.EFI" && $3=="1"{print $4;exit}' "$dir/systemd-shared-efi-boot-reference.tsv" 2>/dev/null || true)
    ref_hash=$(sha256sum -- "$dir/references/EFI-BOOT/BOOTX64.EFI" 2>/dev/null | awk '{print $1}' || true)
    [[ $row_hash =~ ^[0-9A-Fa-f]{64}$ && $row_hash == "$ref_hash" ]] || { BACKUP_VALIDATION_REASON='systemd-boot shared EFI fallback reference is inconsistent'; return 1; }
    [[ $(sha256sum -- "$canonical" | awk '{print $1}') == "$row_hash" ]] || { BACKUP_VALIDATION_REASON='backed-up generic EFI fallback is not byte-identical to canonical systemd-boot'; return 1; }
    return 0
}

# r31 intentionally rejected systemd-boot.  Delegate its proven GRUB/Limine
# checks unchanged; use the original structural validator only for the new
# systemd format, then apply Leap-specific topology/ownership gates.
if declare -F validate_backup >/dev/null 2>&1; then
    eval "$(declare -f validate_backup | sed '1s/validate_backup/validate_backup_pre_leap16_r44/')"
fi
validate_backup() {
    local dir=$1
    unset format_version backup_platform backup_schema switcher_release bootloader payload_policy \
          created_epoch created_iso hostname machine_id esp_source esp_mount esp_uuid \
          root_source root_uuid boot_current boot_label boot_efi_path

    # Fast path: all r31 GRUB/Limine backups retain the exact proven validator.
    if load_backup_metadata "$dir" 2>/dev/null && [[ ${bootloader:-} != systemd-boot ]]; then
        validate_backup_pre_leap16_r44 "$dir"
        return $?
    fi

    BACKUP_VALIDATION_REASON=''
    declare -F validate_backup_pre_leap16_r31 >/dev/null 2>&1 || { BACKUP_VALIDATION_REASON='structural backup validator is unavailable'; return 1; }
    validate_backup_pre_leap16_r31 "$dir" || return 1
    load_backup_metadata "$dir" || { BACKUP_VALIDATION_REASON='metadata format is invalid'; return 1; }
    [[ ${format_version:-} == 4 ]] || { BACKUP_VALIDATION_REASON='systemd-boot backups require self-contained format v4'; return 1; }
    [[ ${backup_platform:-} == "$LEAP16_R31_BACKUP_PLATFORM" ]] || { BACKUP_VALIDATION_REASON='backup was not created by the openSUSE Leap backup layer'; return 1; }
    [[ ${backup_schema:-} == "$LEAP16_R44_SYSTEMD_BACKUP_SCHEMA" ]] || { BACKUP_VALIDATION_REASON='unsupported systemd-boot backup schema'; return 1; }
    [[ ${bootloader:-} == systemd-boot ]] || { BACKUP_VALIDATION_REASON='systemd-boot validator received the wrong backend'; return 1; }
    [[ ${payload_policy:-} == "$LEAP16_R44_SYSTEMD_PAYLOAD_POLICY" ]] || { BACKUP_VALIDATION_REASON='unexpected systemd-boot backup payload policy'; return 1; }
    leap16_r44_systemd_backup_payload_valid "$dir" || return 1
    [[ -s $dir/package-state.txt ]] || { BACKUP_VALIDATION_REASON='RPM package-state snapshot is missing/empty'; return 1; }
    grep -Eq '^systemd-boot-[^[:space:]]+' "$dir/package-state.txt" || { BACKUP_VALIDATION_REASON='RPM package-state does not contain systemd-boot'; return 1; }
    local esp_rel=${esp_mount#/}
    grep -Eq '^[[:space:]]*LOADER_TYPE=.*systemd-boot' "$dir/files/etc/sysconfig/bootloader" 2>/dev/null || { BACKUP_VALIDATION_REASON='backed-up openSUSE bootloader policy does not identify systemd-boot'; return 1; }
    BACKUP_VALIDATION_REASON='valid'
    return 0
}

if declare -F create_current_bootloader_backup >/dev/null 2>&1; then
    eval "$(declare -f create_current_bootloader_backup | sed '1s/create_current_bootloader_backup/create_current_bootloader_backup_pre_leap16_r44/')"
fi
create_current_bootloader_backup() {
    detect_bootloader
    if [[ $BOOTLOADER != systemd-boot ]]; then
        create_current_bootloader_backup_pre_leap16_r44 "$@"
        return $?
    fi

    CREATED_BACKUP_DIR=''; BACKUP_CREATE_ERROR=''
    collect_kernels
    leap16_require_sudo_session || { BACKUP_CREATE_ERROR='sudo authorization is required to read protected bootloader state'; return 2; }
    run_validation preflight >/dev/null || { BACKUP_CREATE_ERROR='preflight validation failed'; return 2; }
    printf '\nBackup source deep validation:\n'
    leap16_r34_validate_systemd_boot_chain current || { BACKUP_CREATE_ERROR='current systemd-boot chain failed deep validation'; return 2; }
    leap16_r38_source_fallback_exact || { BACKUP_CREATE_ERROR='current systemd-boot generic fallback failed exact validation'; return 2; }
    grep -Eq '^[[:space:]]*LOADER_TYPE=.*systemd-boot' /etc/sysconfig/bootloader 2>/dev/null || { BACKUP_CREATE_ERROR='openSUSE LOADER_TYPE is not systemd-boot'; return 2; }

    local ts dir path rel efi_src
    ts=$(date '+%Y%m%d-%H%M%S')
    dir="$BACKUP_ROOT/systemd-boot-$ts"
    mkdir -p -- "$dir/files" || { BACKUP_CREATE_ERROR="could not create backup directory: $dir"; return 3; }
    chmod 700 -- "$BACKUP_ROOT" "$dir" 2>/dev/null || true

    if ! (
        set -e
        leap16_r31_emit_metadata_kv format_version 4
        leap16_r31_emit_metadata_kv backup_platform "$LEAP16_R31_BACKUP_PLATFORM"
        leap16_r31_emit_metadata_kv backup_schema "$LEAP16_R44_SYSTEMD_BACKUP_SCHEMA"
        leap16_r31_emit_metadata_kv switcher_release "${SWITCHER_RELEASE:-leap16-r44}"
        leap16_r31_emit_metadata_kv bootloader systemd-boot
        leap16_r31_emit_metadata_kv payload_policy "$LEAP16_R44_SYSTEMD_PAYLOAD_POLICY"
        leap16_r31_emit_metadata_kv created_epoch "$(date +%s)"
        leap16_r31_emit_metadata_kv created_iso "$(date --iso-8601=seconds 2>/dev/null || date)"
        leap16_r31_emit_metadata_kv hostname "$(hostname)"
        leap16_r31_emit_metadata_kv machine_id "$(cat /etc/machine-id 2>/dev/null || true)"
        leap16_r31_emit_metadata_kv esp_source "$ESP_SOURCE"
        leap16_r31_emit_metadata_kv esp_mount "$ESP_MOUNT"
        leap16_r31_emit_metadata_kv esp_uuid "$ESP_UUID"
        leap16_r31_emit_metadata_kv root_source "$ROOT_SOURCE"
        leap16_r31_emit_metadata_kv root_uuid "$ROOT_UUID"
        leap16_r31_emit_metadata_kv boot_current "$BOOT_CURRENT"
        leap16_r31_emit_metadata_kv boot_label "$BOOT_LABEL"
        leap16_r31_emit_metadata_kv boot_efi_path "$BOOT_EFI_PATH"
    ) >"$dir/metadata.conf"; then
        rm -rf -- "$dir"; BACKUP_CREATE_ERROR='could not write source-safe backup metadata'; return 3
    fi

    efibootmgr -v >"$dir/efibootmgr-v.txt" 2>&1 || true
    findmnt --fstab >"$dir/fstab-parsed.txt" 2>&1 || true
    cp -a -- /etc/fstab "$dir/fstab.reference" 2>/dev/null || true
    if have rpm; then rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | LC_ALL=C sort >"$dir/package-state.txt" || true; else : >"$dir/package-state.txt"; fi
    printf '%s\n' "${KERNEL_VERSIONS[@]}" >"$dir/kernel-versions.txt"
    backup_paths_for_bootloader systemd-boot >"$dir/owned-paths.txt" || { rm -rf -- "$dir"; BACKUP_CREATE_ERROR='could not enumerate systemd-boot owned paths'; return 3; }

    while IFS= read -r path; do
        [[ -n $path ]] || continue
        copy_path_into_backup "$path" "$dir" || { rm -rf -- "$dir"; return 3; }
    done <"$dir/owned-paths.txt"
    leap16_r44_capture_systemd_shared_recovery_reference "$dir" || { rm -rf -- "$dir"; return 3; }

    if [[ -n $ESP_MOUNT && -n $BOOT_EFI_PATH ]]; then
        rel=${BOOT_EFI_PATH//\\//}; rel=${rel#/}; efi_src="$ESP_MOUNT/$rel"
        printf '%s\n' "$efi_src" >"$dir/bootcurrent-efi-source.txt"
        copy_path_into_backup "$efi_src" "$dir" || { rm -rf -- "$dir"; return 3; }
    else
        : >"$dir/bootcurrent-efi-source.txt"
    fi

    create_manifest_hashes "$dir" || { rm -rf -- "$dir"; BACKUP_CREATE_ERROR='could not create backup integrity manifest'; return 3; }
    validate_backup "$dir" || { BACKUP_CREATE_ERROR="new systemd-boot backup failed self-validation: $BACKUP_VALIDATION_REASON"; rm -rf -- "$dir"; return 3; }
    CREATED_BACKUP_DIR=$dir
    return 0
}

# Let selector [3] expose the new backend too.
create_current_bootloader_backup_interactive() {
    local ans rc
    detect_bootloader
    case "$BOOTLOADER" in grub|limine|systemd-boot) ;; *) printf '\nUser backups are currently enabled for GRUB2, Limine, and systemd-boot.\n'; return 1 ;; esac
    printf '\nCurrent bootloader: %s\nBackup directory:   %s\n\n' "$(bootloader_display_name "$BOOTLOADER")" "$BACKUP_ROOT"
    read -r -p 'Back up the currently booted bootloader? [y/n]: ' ans
    case "$ans" in
        y|Y|yes|YES)
            create_current_bootloader_backup; rc=$?
            if ((rc == 0)); then
                printf '\nBackup created: %s\n' "$CREATED_BACKUP_DIR"
                if validate_backup_compatibility "$CREATED_BACKUP_DIR"; then printf 'Backup validation: VALID, COMPATIBLE\n'; else printf 'Backup validation: FAILED (%s)\n' "$BACKUP_COMPATIBILITY_REASON"; fi
            else
                printf '\nBackup failed safely: %s\nNo bootloader state was modified.\n' "${BACKUP_CREATE_ERROR:-unknown backup error}"
            fi
            ;;
        n|N|no|NO) printf 'Backup cancelled.\n' ;;
        '') printf 'No selection entered. Backup cancelled.\n' ;;
        *) printf 'Unrecognized response. Backup cancelled.\n' ;;
    esac
}

# ---------------------------------------------------------------------------
# Cross-backend systemd-boot restore on the already-proven GRUB/systemd edges
# ---------------------------------------------------------------------------

leap16_r44_restore_systemd_preflight() {
    local dir=$1 current_cmd
    validate_backup_compatibility "$dir" || { fail "Backup is not compatible: $BACKUP_COMPATIBILITY_REASON"; return 1; }
    load_backup_metadata "$dir" || return 1
    [[ $bootloader == systemd-boot && $backup_schema == "$LEAP16_R44_SYSTEMD_BACKUP_SCHEMA" ]] || { fail 'Selected backup is not an r44 systemd-boot backup'; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == grub ]] || { fail 'systemd-boot backup restore currently requires GRUB2 as the verified source'; return 1; }
    leap16_r32_systemd_preflight systemd-boot || return 1
    leap16_r31_backup_kernel_set_matches "$dir" || { fail 'Installed kernel versions do not exactly match the selected systemd-boot backup'; return 1; }
    current_cmd=$(leap16_r32_portable_cmdline "$(cat /proc/cmdline 2>/dev/null || true)")
    [[ -n $current_cmd ]] || { fail 'Could not derive current portable GRUB runtime command line'; return 1; }
    BACKUP_VALIDATION_REASON=''
    leap16_r44_systemd_backup_payload_valid "$dir" "$current_cmd" || { fail "$BACKUP_VALIDATION_REASON"; return 1; }
    ok 'Validated self-contained systemd-boot backup against the current GRUB2 source and kernel/root topology'
}

# Freeze/write exact backed-up systemd-owned ESP bytes during the normal r32
# candidate stage.  Source GRUB policy and EFI/BOOT remain untouched until the
# normal runtime-proof/finalization engine authorizes transfer.
if declare -F leap16_r32_write_systemd_boot_candidate >/dev/null 2>&1; then
    eval "$(declare -f leap16_r32_write_systemd_boot_candidate | sed '1s/leap16_r32_write_systemd_boot_candidate/leap16_r32_write_systemd_boot_candidate_pre_leap16_r44/')"
fi
leap16_r32_write_systemd_boot_candidate() {
    local dir=${LEAP16_R44_RESTORE_DIR:-}
    if [[ -z $dir ]]; then
        leap16_r32_write_systemd_boot_candidate_pre_leap16_r44 "$@"
        return $?
    fi
    load_backup_metadata "$dir" || return 1
    local esp_rel=${esp_mount#/} mid=${machine_id:-} srcbase dstroot ver src
    srcbase="$dir/files/$esp_rel"
    dstroot="${ESP_MOUNT%/}"
    [[ -d $srcbase/EFI/systemd && -f $srcbase/loader/loader.conf ]] || { fail 'Selected systemd-boot backup disappeared before staging'; return 1; }
    ! find "$srcbase/EFI/systemd" "$srcbase/$mid/opensuse-bootloader-switcher" -type l -print -quit 2>/dev/null | grep -q . || { fail 'Selected systemd-boot backup contains a symlink in a VFAT target tree'; return 1; }

    sudo install -d -m 0755 -- "$dstroot/EFI" "$dstroot/loader/entries" "$dstroot/$mid" || return 1
    sudo cp -a --no-preserve=all -- "$srcbase/EFI/systemd" "$dstroot/EFI/systemd" || return 1
    sudo install -m 0644 -- "$srcbase/loader/loader.conf" "$dstroot/loader/loader.conf" || return 1
    collect_kernels
    for ver in "${KERNEL_VERSIONS[@]}"; do
        src="$srcbase/loader/entries/opensuse-$ver.conf"
        [[ -f $src && ! -L $src ]] || { fail "Restored systemd-boot BLS entry disappeared for $ver"; return 1; }
        sudo install -m 0644 -- "$src" "$dstroot/loader/entries/opensuse-$ver.conf" || return 1
    done
    sudo cp -a --no-preserve=all -- "$srcbase/$mid/opensuse-bootloader-switcher" "$dstroot/$mid/opensuse-bootloader-switcher" || return 1
    ok 'Restored exact validated systemd-boot EFI/BLS/kernel payload bytes into the parked target namespace'
}

leap16_r44_restore_systemd_backup() {
    local dir=$1 ans rc
    leap16_r44_restore_systemd_preflight "$dir" || return 1
    printf '\nLeap-native systemd-boot backup restore transaction plan:\n'
    printf '  - restore exact validated EFI/systemd, loader.conf, BLS entries and managed kernel/initrd payload;\n'
    printf '  - keep GRUB2 first and keep the GRUB-owned generic EFI fallback unchanged during staging;\n'
    printf '  - arm exactly one systemd-boot BootNext and require real runtime proof;\n'
    printf '  - only after proof, promote systemd-boot, transfer EFI/BOOT ownership, and retire exact GRUB2 source state.\n\n'
    offer_operation_backup || return 1
    read -r -p 'Type RESTORE to stage this validated systemd-boot backup, or anything else to cancel: ' ans
    [[ $ans == RESTORE ]] || { printf 'Restore cancelled. No boot state was modified by the restore.\n'; return 0; }
    leap16_r44_restore_systemd_preflight "$dir" || { fail 'Write-boundary systemd-boot restore revalidation failed; nothing was staged'; return 1; }
    LEAP16_R44_RESTORE_DIR=$dir
    OPERATION_BACKUP=$dir
    rc=0
    r26_execute_adapter_switch systemd-boot || rc=$?
    LEAP16_R44_RESTORE_DIR=''
    return "$rc"
}

leap16_r44_restore_grub_from_systemd_preflight() {
    local dir=$1 cfg policy syscfg
    validate_backup_compatibility "$dir" || { fail "Backup is not compatible: $BACKUP_COMPATIBILITY_REASON"; return 1; }
    load_backup_metadata "$dir" || return 1
    [[ $bootloader == grub ]] || { fail 'Selected backup is not a GRUB2 backup'; return 1; }
    [[ $backup_platform == "$LEAP16_R31_BACKUP_PLATFORM" && $backup_schema == "$LEAP16_R31_BACKUP_SCHEMA" ]] || { fail 'Selected GRUB2 backup is not a native Leap backup'; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == systemd-boot ]] || { fail 'GRUB2 backup restore on this path requires systemd-boot as the verified source'; return 1; }
    leap16_r38_preflight grub || return 1
    leap16_r31_backup_kernel_set_matches "$dir" || { fail 'Installed kernel versions do not exactly match the selected GRUB2 backup'; return 1; }
    policy="$dir/files/etc/default/grub"; cfg="$dir/files/boot/grub2/grub.cfg"; syscfg="$dir/files/etc/sysconfig/bootloader"
    [[ -f $policy && ! -L $policy && -f $cfg && ! -L $cfg ]] || { fail 'Selected GRUB2 backup policy/config is incomplete'; return 1; }
    have grub2-script-check && grub2-script-check "$cfg" >/dev/null 2>&1 || { fail 'Backed-up grub.cfg fails grub2-script-check'; return 1; }
    [[ -n ${ROOT_UUID:-} ]] && grep -Fq -- "root=UUID=$ROOT_UUID" "$cfg" || { fail 'Backed-up GRUB2 config does not reference the current root UUID'; return 1; }
    [[ ! -f $syscfg ]] || grep -Eq '^[[:space:]]*LOADER_TYPE=.*grub2-efi' "$syscfg" || { fail 'Backed-up bootloader policy does not identify grub2-efi'; return 1; }
    ok 'Validated native GRUB2 backup against the finalized systemd-boot source and current kernel/root topology'
}

leap16_r44_restore_grub_backup_from_systemd() {
    local dir=$1 ans rc
    leap16_r44_restore_grub_from_systemd_preflight "$dir" || return 1
    printf '\nLeap-native GRUB2 backup restore transaction plan from systemd-boot:\n'
    printf '  - restore the validated backed-up /etc/default/grub policy;\n'
    printf '  - reconstruct /boot/grub2 + EFI/OPENSUSE with native Leap GRUB2/shim tooling;\n'
    printf '  - keep systemd-boot authoritative and EFI/BOOT systemd-owned until a real GRUB runtime proof;\n'
    printf '  - only after proof, transfer EFI/BOOT to shim and retire exact systemd-boot source state.\n\n'
    offer_operation_backup || return 1
    read -r -p 'Type RESTORE to stage this validated GRUB2 backup, or anything else to cancel: ' ans
    [[ $ans == RESTORE ]] || { printf 'Restore cancelled. No boot state was modified by the restore.\n'; return 0; }
    leap16_r44_restore_grub_from_systemd_preflight "$dir" || { fail 'Write-boundary GRUB2 restore revalidation failed; nothing was staged'; return 1; }
    LEAP16_R31_RESTORE_DIR=$dir
    OPERATION_BACKUP=$dir
    LEAP16_R38_REVERSE_STAGING=1
    rc=0
    r26_execute_adapter_switch grub || rc=$?
    LEAP16_R38_REVERSE_STAGING=0
    LEAP16_R31_RESTORE_DIR=''
    return "$rc"
}

# Extend selector [5] only across already-proven switch engines.  Limine <->
# systemd-boot restore remains locked until that switch matrix is hardware-proven.
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
        *)
            printf 'Restore %s -> %s is not enabled in %s.\n' "$(bootloader_display_name "$source")" "$(bootloader_display_name "$target")" "${SWITCHER_RELEASE:-leap16-r44}"
            printf 'Enabled restore matrices: GRUB2 <-> Limine and GRUB2 <-> systemd-boot.\n'
            return 2
            ;;
    esac
}

# Add the new backup contents to the read-only restore plan without rewriting
# the proven r31 plan for GRUB/Limine.
restore_plan_interactive() {
    local n dir esp_rel mid
    discover_backups_quiet
    ((${#DISCOVERED_BACKUPS[@]})) || { printf '\nNo backups found.\n'; return 0; }
    printf '\n'; list_backups; printf '\n'
    read -r -p 'Select backup number to inspect, or Enter to cancel: ' n
    [[ -n $n ]] || return 0
    [[ $n =~ ^[0-9]+$ ]] && ((n>=1 && n<=${#DISCOVERED_BACKUPS[@]})) || { printf 'Invalid selection.\n'; return 1; }
    dir=${DISCOVERED_BACKUPS[n-1]}
    validate_backup_compatibility "$dir" || { printf 'Restore plan refused: %s.\n' "$BACKUP_COMPATIBILITY_REASON"; return 1; }
    load_backup_metadata "$dir" || return 1
    if [[ $bootloader != systemd-boot ]]; then
        # Re-implement the compact proven r31 read-only report to avoid a second
        # selector prompt from delegating to the old interactive function.
        esp_rel=${esp_mount#/}; mid=${machine_id:-}
        printf '\nValidated read-only restore plan:\n  Backup:          %s\n  Bootloader:      %s\n  Original ESP:    %s (%s) mounted at %s\n  Original root:   %s (%s)\n  Integrity:       SHA256 manifest valid\n  Compatibility:   machine ID + ESP UUID + root UUID match\n\n' "$dir" "$(bootloader_display_name "$bootloader")" "$esp_source" "$esp_uuid" "$esp_mount" "$root_source" "$root_uuid"
        case "$bootloader" in
            grub) printf 'Captured GRUB2 state: /etc/default/grub, /etc/sysconfig/bootloader, /boot/grub2, EFI/OPENSUSE, shared EFI/BOOT reference evidence.\n' ;;
            limine) printf 'Captured Limine state: policy, limine.conf, splash, EFI/LIMINE and complete managed kernel/initrd tree.\n' ;;
        esac
        printf '\nRestore execution is available from selector [5] on its hardware-proven cross-backend matrix.\n'
        return 0
    fi
    mid=${machine_id:-}
    printf '\nValidated read-only restore plan:\n'
    printf '  Backup:          %s\n  Bootloader:      systemd-boot\n' "$dir"
    printf '  Original ESP:    %s (%s) mounted at %s\n' "$esp_source" "$esp_uuid" "$esp_mount"
    printf '  Original root:   %s (%s)\n' "$root_source" "$root_uuid"
    printf '  Integrity:       SHA256 manifest valid\n  Compatibility:   machine ID + ESP UUID + root UUID match\n\n'
    printf 'Captured systemd-boot state:\n'
    printf '  - %s/EFI/systemd/systemd-bootx64.efi\n' "$esp_mount"
    printf '  - %s/loader/loader.conf + exact openSUSE per-kernel BLS entries\n' "$esp_mount"
    printf '  - %s/%s/opensuse-bootloader-switcher managed kernel/initrd tree\n' "$esp_mount" "$mid"
    printf '  - /etc/sysconfig/bootloader (+ /etc/kernel/cmdline when present) as policy/reference evidence\n'
    printf '  - %s/EFI/BOOT/BOOTX64.EFI as byte-exact shared fallback reference evidence\n' "$esp_mount"
    printf '\nRestore execution is enabled from GRUB2 through the proven GRUB2 -> systemd-boot transaction engine.\n'
}

# ---------------------------------------------------------------------------
# Backup-before-switch parity and interactive stage transcript
# ---------------------------------------------------------------------------

leap16_r44_diag_begin() {
    local current=$1 target=$2 kind=${3:-transaction} stamp safe root
    safe="${kind}-${current}-to-${target}"; safe=${safe//[^A-Za-z0-9._-]/-}
    stamp=$(date +%Y%m%d-%H%M%S)
    root=${LEAP16_DIAGNOSTIC_ROOT:-${HOME:-/tmp}/opensuse-bootloader-diagnostics}
    LEAP16_R44_TRANSACTION_DIAG_DIR="$root/${stamp}-$safe"
    mkdir -p -- "$LEAP16_R44_TRANSACTION_DIAG_DIR" || { LEAP16_R44_TRANSACTION_DIAG_DIR=''; return 1; }
    chmod 700 -- "$LEAP16_R44_TRANSACTION_DIAG_DIR" 2>/dev/null || true
    printf 'release=%s\nkind=%s\ndirection=%s:%s\nstarted_at=%s\n' "${SWITCHER_RELEASE:-leap16-r44}" "$kind" "$current" "$target" "$(date --iso-8601=seconds 2>/dev/null || date)" >"$LEAP16_R44_TRANSACTION_DIAG_DIR/transaction.conf"
    efibootmgr -v >"$LEAP16_R44_TRANSACTION_DIAG_DIR/pre-stage-efibootmgr-v.txt" 2>&1 || true
    return 0
}

leap16_r44_diag_bind_pending() {
    [[ -n ${LEAP16_R44_TRANSACTION_DIAG_DIR:-} && -d $LEAP16_R44_TRANSACTION_DIAG_DIR ]] || return 0
    local snap=${PENDING_TRANSACTION_SNAPSHOT_DIR:-${TRANSACTION_SNAPSHOT_DIR:-}}
    [[ -n $snap && -d $snap ]] || return 0
    printf '%s\n' "$LEAP16_R44_TRANSACTION_DIAG_DIR" >"$snap/$LEAP16_R44_DIAG_POINTER" 2>/dev/null || true
    chmod 600 -- "$snap/$LEAP16_R44_DIAG_POINTER" 2>/dev/null || true
    efibootmgr -v >"$LEAP16_R44_TRANSACTION_DIAG_DIR/staged-efibootmgr-v.txt" 2>&1 || true
    [[ -n ${PENDING_STATE_FILE:-} && -r ${PENDING_STATE_FILE:-} ]] && cp -- "$PENDING_STATE_FILE" "$LEAP16_R44_TRANSACTION_DIAG_DIR/pending-migration.tsv" 2>/dev/null || true
}

# After the proven resume-bundle builder copies the transaction snapshot, add a
# root-owned copy of the user transcript pointer.  The resume code never trusts
# it for boot decisions; it is diagnostics metadata only.
if declare -F r22_prepare_resume_bundle >/dev/null 2>&1; then
    eval "$(declare -f r22_prepare_resume_bundle | sed '1s/r22_prepare_resume_bundle/r22_prepare_resume_bundle_pre_leap16_r44/')"
fi
r22_prepare_resume_bundle() {
    leap16_r44_diag_bind_pending
    r22_prepare_resume_bundle_pre_leap16_r44 "$@" || return $?
    local pointer="$PENDING_STATE_DIR/r22-resume-bundle.path" bundle src
    bundle=$(head -n1 -- "$pointer" 2>/dev/null || true)
    src="${PENDING_TRANSACTION_SNAPSHOT_DIR:-}/$LEAP16_R44_DIAG_POINTER"
    if [[ -n $bundle && -f $src ]] && r22_safe_bundle_path "$bundle"; then
        sudo -n install -o root -g root -m 0600 -- "$src" "$bundle/$LEAP16_R44_DIAG_POINTER" >/dev/null 2>&1 || true
    fi
    return 0
}

# Preserve the old checkpoint sync, then aggregate the root resume transcript
# and checkpoint directories into the same user-created transaction folder.
if declare -F r13_sync_root_diagnostics_to_user >/dev/null 2>&1; then
    eval "$(declare -f r13_sync_root_diagnostics_to_user | sed '1s/r13_sync_root_diagnostics_to_user/r13_sync_root_diagnostics_to_user_pre_leap16_r44/')"
fi
r13_sync_root_diagnostics_to_user() {
    local conf=$1 bundle=$2 status=${3:-resume} rc=0 diag dest uid gid real_dest real_diag d base
    r13_sync_root_diagnostics_to_user_pre_leap16_r44 "$@" || rc=$?
    [[ -f $bundle/$LEAP16_R44_DIAG_POINTER ]] || return "$rc"
    diag=$(head -n1 -- "$bundle/$LEAP16_R44_DIAG_POINTER" 2>/dev/null || true)
    dest=$(r22_conf_value "$conf" user_diagnostic_root); uid=$(r22_conf_value "$conf" user_uid); gid=$(r22_conf_value "$conf" user_gid)
    [[ -n $diag && -n $dest && $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ ]] || return "$rc"
    real_dest=$(r22_realpath_m "$dest"); real_diag=$(r22_realpath_m "$diag")
    [[ $real_diag == "$real_dest/"* && $real_diag != "$real_dest" && -d $diag && ! -L $diag ]] || return "$rc"
    install -d -o "$uid" -g "$gid" -m 0700 -- "$diag/checkpoints" || return "$rc"
    if [[ -f $bundle/automatic-resume.log ]]; then
        install -o "$uid" -g "$gid" -m 0600 -- "$bundle/automatic-resume.log" "$diag/resume.log" || true
    fi
    if [[ -d $bundle/diagnostics ]]; then
        while IFS= read -r -d '' d; do
            base=$(basename -- "$d")
            rm -rf -- "$diag/checkpoints/$base" 2>/dev/null || true
            cp -a -- "$d" "$diag/checkpoints/$base" 2>/dev/null || continue
            chown -R "$uid:$gid" -- "$diag/checkpoints/$base" 2>/dev/null || true
        done < <(find "$bundle/diagnostics" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    fi
    printf 'resume_status=%s\nresume_synced_at=%s\n' "$status" "$(date --iso-8601=seconds 2>/dev/null || date)" >"$diag/resume-result.txt" 2>/dev/null || true
    chown "$uid:$gid" "$diag/resume-result.txt" 2>/dev/null || true
    return "$rc"
}

# Run an interactive systemd-edge switch/restore with stdout+stderr mirrored to
# a persistent pre-reboot transcript.  The root resume layer later appends its
# own log/checkpoints to this same directory through the pointer above.
leap16_r44_with_transaction_transcript() {
    local current=$1 target=$2 kind=$3 command=$4 rc=0 log
    shift 4
    leap16_r44_diag_begin "$current" "$target" "$kind" || {
        warn 'Could not create the full transaction transcript directory; normal checkpoint diagnostics remain available'
        "$command" "$@"
        return $?
    }
    log="$LEAP16_R44_TRANSACTION_DIAG_DIR/stage.log"
    exec 8>&1 9>&2
    exec > >(tee -a "$log") 2>&1
    "$command" "$@" || rc=$?
    exec 1>&8 2>&9
    exec 8>&- 9>&-
    printf 'stage_exit=%s\nstage_finished_at=%s\n' "$rc" "$(date --iso-8601=seconds 2>/dev/null || date)" >>"$LEAP16_R44_TRANSACTION_DIAG_DIR/transaction.conf" 2>/dev/null || true
    printf 'Transaction transcript: %s\n' "$LEAP16_R44_TRANSACTION_DIAG_DIR"
    return "$rc"
}

# Replace only the two systemd matrix dispatches.  This restores the same user
# backup offer that GRUB2 <-> Limine already had, while keeping mandatory private
# transaction snapshots independent of the user's answer.
if declare -F run_live_operation >/dev/null 2>&1; then
    eval "$(declare -f run_live_operation | sed '1s/run_live_operation/run_live_operation_pre_leap16_r44/')"
fi
leap16_r44_run_systemd_edge_inner() {
    local target=$1 current=$BOOTLOADER rc=0
    case "$current:$target" in
        grub:systemd-boot)
            leap16_r32_systemd_preflight "$target" || return 1
            offer_operation_backup || return 1
            show_operation_plan "$current" "$target"
            confirm_operation "$current" "$target" || { printf '\nOperation cancelled. No boot state was modified.\n'; return 0; }
            printf '\nRe-running the complete systemd-boot preflight at the write boundary...\n'
            leap16_r32_systemd_preflight "$target" || { printf '\nWrite-boundary revalidation failed. Nothing was modified.\n'; return 1; }
            r26_execute_adapter_switch systemd-boot || rc=$?
            ;;
        systemd-boot:grub)
            leap16_r38_preflight "$target" || return 1
            offer_operation_backup || return 1
            leap16_r38_plan
            confirm_operation "$current" "$target" || { printf '\nOperation cancelled. No boot state was modified.\n'; return 0; }
            printf '\nRe-running the complete systemd-boot -> GRUB2 preflight at the write boundary...\n'
            leap16_r38_preflight "$target" || { printf '\nWrite-boundary revalidation failed. Nothing was modified.\n'; return 1; }
            LEAP16_R38_REVERSE_STAGING=1
            r26_execute_adapter_switch grub || rc=$?
            LEAP16_R38_REVERSE_STAGING=0
            ;;
        *) return 2 ;;
    esac
    leap16_r44_diag_bind_pending
    return "$rc"
}

run_live_operation() {
    local target=${1:-} current rc=0
    detect_bootloader; current=$BOOTLOADER
    case "$current:$target" in
        grub:systemd-boot|systemd-boot:grub)
            leap16_r44_with_transaction_transcript "$current" "$target" switch leap16_r44_run_systemd_edge_inner "$target"
            return $?
            ;;
        *) run_live_operation_pre_leap16_r44 "$@" ;;
    esac
}
