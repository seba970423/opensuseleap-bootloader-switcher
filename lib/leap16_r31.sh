#!/usr/bin/env bash
# openSUSE Leap 16 r31
#
# Narrow UX/safety layer on top of the hardware-proven r30 GRUB2 <-> Limine
# transaction engine:
#   * add user-owned, validated GRUB2/Limine backups without touching the
#     mandatory transaction-internal ownership snapshots;
#   * expose backup creation/listing/read-only restore planning in the menu;
#   * expose the GRUB2 <-> Limine restore selector through Leap-native staged
#     restore adapters so the write path can earn its hardware proof;
#   * make the deliberate second GRUB2 -> Limine fallback-proof reboot explicit
#     before the user starts the first reboot.
#
# No BootOrder/BootNext/runtime-proof/retirement mechanics are changed here.

LEAP16_R31_BACKUP_PLATFORM="opensuse-leap16"
LEAP16_R31_BACKUP_SCHEMA="leap16-r31-v1"

# r27 owns the safe, non-eval metadata decoder used by the r47 lineage. Extend
# only its key allow-list for the three Leap r31 identity fields; keep the
# parser/decoder itself unchanged.
if declare -F r27_backup_metadata_key_allowed >/dev/null 2>&1; then
    eval "$(declare -f r27_backup_metadata_key_allowed | sed '1s/r27_backup_metadata_key_allowed/r27_backup_metadata_key_allowed_pre_leap16_r31/')"
fi
r27_backup_metadata_key_allowed() {
    case "$1" in
        backup_platform|backup_schema|switcher_release) return 0 ;;
    esac
    declare -F r27_backup_metadata_key_allowed_pre_leap16_r31 >/dev/null 2>&1 || return 1
    r27_backup_metadata_key_allowed_pre_leap16_r31 "$1"
}

leap16_r31_emit_metadata_kv() {
    local key=$1 value=${2-}
    [[ $key =~ ^[a-z_][a-z0-9_]*$ ]] || return 1
    # The inherited metadata loader intentionally accepts only a tiny,
    # source-safe grammar.  Bash printf %q emits backslash-escaped whitespace
    # (for example "openSUSE\ Limine"), which that grammar rejects.  Emit
    # ordinary single-quoted values instead and fail closed on characters the
    # loader cannot represent safely.
    [[ $value != *"'"* && $value != *$'\n'* && $value != *$'\r'* ]] || return 1
    printf "%s='%s'\n" "$key" "$value"
}

# The inherited CachyOS backup layer is structurally useful, but the owned path
# set is distro-specific.  Leap GRUB lives in /boot/grub2 + EFI/OPENSUSE; Leap
# Limine is self-contained on the ESP and has no limine-entry-tool config.
backup_paths_for_bootloader() {
    local bl=$1 esp=${ESP_MOUNT:-/boot/efi} machine_id
    esp=${esp%/}
    case "$bl" in
        grub)
            printf '%s\n' \
                /etc/default/grub \
                /etc/sysconfig/bootloader \
                /boot/grub2 \
                "$esp/EFI/OPENSUSE"
            ;;
        limine)
            machine_id=$(cat /etc/machine-id 2>/dev/null || true)
            printf '%s\n' \
                /etc/default/limine \
                "$esp/limine.conf" \
                "$esp/limine-splash.png" \
                "$esp/EFI/LIMINE"
            [[ -n $machine_id ]] && printf '%s\n' "$esp/$machine_id"
            ;;
        *)
            return 1
            ;;
    esac
}

# Preserve the inherited validator as the structural/integrity base, then add
# Leap-specific identity requirements so an unrelated CachyOS/experimental
# backup cannot silently become a Leap restore candidate.
if declare -F validate_backup >/dev/null 2>&1; then
    eval "$(declare -f validate_backup | sed '1s/validate_backup/validate_backup_pre_leap16_r31/')"
fi
validate_backup() {
    local dir=$1 esp_rel mid
    BACKUP_VALIDATION_REASON=""
    # Metadata variables are shell globals in the inherited loader. Clear the
    # complete metadata namespace before every validation so a previously read
    # backup cannot make a malformed/older backup inherit stale identity fields.
    unset format_version backup_platform backup_schema switcher_release bootloader payload_policy \
          created_epoch created_iso hostname machine_id esp_source esp_mount esp_uuid \
          root_source root_uuid boot_current boot_label boot_efi_path
    declare -F validate_backup_pre_leap16_r31 >/dev/null 2>&1 || {
        BACKUP_VALIDATION_REASON='inherited backup validator is unavailable'
        return 1
    }
    validate_backup_pre_leap16_r31 "$dir" || return 1
    load_backup_metadata "$dir" || { BACKUP_VALIDATION_REASON='metadata format is invalid'; return 1; }

    [[ ${format_version:-} == 4 ]] || { BACKUP_VALIDATION_REASON='Leap r31 supports only self-contained format v4 backups'; return 1; }
    [[ ${backup_platform:-} == "$LEAP16_R31_BACKUP_PLATFORM" ]] || { BACKUP_VALIDATION_REASON='backup was not created by the openSUSE Leap backup layer'; return 1; }
    [[ ${backup_schema:-} == "$LEAP16_R31_BACKUP_SCHEMA" ]] || { BACKUP_VALIDATION_REASON='unsupported openSUSE Leap backup schema'; return 1; }
    case ${bootloader:-} in
        grub|limine) ;;
        *) BACKUP_VALIDATION_REASON='r31 user backups are enabled only for GRUB2 and Limine'; return 1 ;;
    esac

    esp_rel=${esp_mount:-}; esp_rel=${esp_rel#/}
    [[ -n $esp_rel && $esp_rel != *'..'* ]] || { BACKUP_VALIDATION_REASON='invalid ESP mount metadata'; return 1; }
    case "$bootloader" in
        grub)
            [[ -f $dir/files/etc/default/grub ]] || { BACKUP_VALIDATION_REASON='GRUB backup is missing /etc/default/grub'; return 1; }
            [[ -f $dir/files/boot/grub2/grub.cfg ]] || { BACKUP_VALIDATION_REASON='GRUB backup is missing /boot/grub2/grub.cfg'; return 1; }
            [[ -d $dir/files/$esp_rel/EFI/OPENSUSE ]] || { BACKUP_VALIDATION_REASON='GRUB backup is missing EFI/OPENSUSE'; return 1; }
            [[ -f $dir/grub-shared-efi-boot-reference.tsv ]] || { BACKUP_VALIDATION_REASON='GRUB backup is missing shared EFI/BOOT reference metadata'; return 1; }
            ;;
        limine)
            mid=${machine_id:-}
            [[ -n $mid && $mid != *'/'* && $mid != *'..'* ]] || { BACKUP_VALIDATION_REASON='invalid machine ID in Limine backup'; return 1; }
            grep -Fqx -- '/+openSUSE' "$dir/files/$esp_rel/limine.conf" 2>/dev/null || {
                BACKUP_VALIDATION_REASON='Limine backup does not contain the openSUSE menu group marker'
                return 1
            }
            ;;
    esac
    [[ -s $dir/package-state.txt ]] || { BACKUP_VALIDATION_REASON='RPM package-state snapshot is missing/empty'; return 1; }
    BACKUP_VALIDATION_REASON='valid'
    return 0
}

leap16_r31_capture_grub_shared_recovery_references() {
    local dir=$1 esp=${ESP_MOUNT%/} src name hash out="$dir/grub-shared-efi-boot-reference.tsv"
    mkdir -p -- "$dir/references/EFI-BOOT" || return 1
    printf 'name\tpath\texists\tsha256\n' >"$out" || return 1
    for name in BOOTX64.EFI fallback.efi MokManager.efi; do
        src="$esp/EFI/BOOT/$name"
        if path_exists_for_backup_read "$src"; then
            hash=$(hash_path_for_backup_read sha256sum "$src" || true)
            [[ $hash =~ ^[0-9A-Fa-f]{64}$ ]] || { BACKUP_CREATE_ERROR="could not hash shared EFI/BOOT reference: $src"; return 1; }
            copy_reference_file_readonly "$src" "$dir/references/EFI-BOOT/$name" || { BACKUP_CREATE_ERROR="could not copy shared EFI/BOOT reference: $src"; return 1; }
            [[ $(sha256sum -- "$dir/references/EFI-BOOT/$name" | awk '{print $1}') == "$hash" ]] || { BACKUP_CREATE_ERROR="shared EFI/BOOT reference hash mismatch: $src"; return 1; }
            printf '%s\t%s\t1\t%s\n' "$name" "$src" "$hash" >>"$out" || return 1
        else
            printf '%s\t%s\t0\t\n' "$name" "$src" >>"$out" || return 1
        fi
    done
    return 0
}

# User backup creation is intentionally separate from the mandatory transaction
# ownership snapshot.  Authentication happens only after the user asked for a
# backup; all protected reads after that use the cached sudo session.
create_current_bootloader_backup() {
    CREATED_BACKUP_DIR=""
    BACKUP_CREATE_ERROR=""
    detect_bootloader
    collect_kernels
    case "$BOOTLOADER" in
        grub|limine) ;;
        *) BACKUP_CREATE_ERROR='user backups are enabled only for the current GRUB2 or Limine backend in leap16-r31'; return 2 ;;
    esac

    leap16_require_sudo_session || { BACKUP_CREATE_ERROR='sudo authorization is required to read protected bootloader state'; return 2; }
    if ! run_validation preflight >/dev/null; then
        BACKUP_CREATE_ERROR='preflight validation failed'
        return 2
    fi
    printf '
Backup source deep validation:
'
    case "$BOOTLOADER" in
        grub)
            validate_grub_boot_chain current || { BACKUP_CREATE_ERROR='current GRUB2 boot chain failed deep validation'; return 2; }
            ;;
        limine)
            validate_limine_boot_chain current || { BACKUP_CREATE_ERROR='current Limine boot chain failed deep validation'; return 2; }
            if grep -Fqx '# CachyOS Limine theme' "$ESP_MOUNT/limine.conf" 2>/dev/null; then
                validate_cachyos_limine_theme || { BACKUP_CREATE_ERROR='current Limine presentation assets failed validation'; return 2; }
            fi
            ;;
    esac

    local ts dir path rel efi_src
    ts=$(date '+%Y%m%d-%H%M%S')
    dir="$BACKUP_ROOT/${BOOTLOADER}-${ts}"
    mkdir -p -- "$dir/files" || { BACKUP_CREATE_ERROR="could not create backup directory: $dir"; return 3; }
    chmod 700 -- "$BACKUP_ROOT" "$dir" 2>/dev/null || true

    if ! (
        set -e
        leap16_r31_emit_metadata_kv format_version 4
        leap16_r31_emit_metadata_kv backup_platform "$LEAP16_R31_BACKUP_PLATFORM"
        leap16_r31_emit_metadata_kv backup_schema "$LEAP16_R31_BACKUP_SCHEMA"
        leap16_r31_emit_metadata_kv switcher_release "${SWITCHER_RELEASE:-leap16-r31}"
        leap16_r31_emit_metadata_kv bootloader "$BOOTLOADER"
        if [[ $BOOTLOADER == limine ]]; then
            leap16_r31_emit_metadata_kv payload_policy 'config-efi-splash-plus-staged-payload'
        else
            leap16_r31_emit_metadata_kv payload_policy 'opensuse-bootloader-owned-paths'
        fi
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
        rm -rf -- "$dir"
        BACKUP_CREATE_ERROR='could not write source-safe backup metadata'
        return 3
    fi

    efibootmgr -v >"$dir/efibootmgr-v.txt" 2>&1 || true
    findmnt --fstab >"$dir/fstab-parsed.txt" 2>&1 || true
    cp -a -- /etc/fstab "$dir/fstab.reference" 2>/dev/null || true
    if have rpm; then
        rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | LC_ALL=C sort >"$dir/package-state.txt" || true
    else
        : >"$dir/package-state.txt"
    fi
    printf '%s\n' "${KERNEL_VERSIONS[@]}" >"$dir/kernel-versions.txt"
    printf '%s\n' "$(backup_paths_for_bootloader "$BOOTLOADER")" >"$dir/owned-paths.txt"

    while IFS= read -r path; do
        [[ -n $path ]] || continue
        if ! copy_path_into_backup "$path" "$dir"; then
            printf 'Backup error: %s\n' "${BACKUP_CREATE_ERROR:-failed while copying $path}" >&2
            rm -rf -- "$dir"
            return 3
        fi
    done < <(backup_paths_for_bootloader "$BOOTLOADER")

    if [[ $BOOTLOADER == grub ]]; then
        if ! leap16_r31_capture_grub_shared_recovery_references "$dir"; then
            printf 'Backup error: %s\n' "${BACKUP_CREATE_ERROR:-failed while capturing shared GRUB recovery reference state}" >&2
            rm -rf -- "$dir"
            return 3
        fi
    elif [[ $BOOTLOADER == limine ]]; then
        if ! create_limine_backup_references "$dir"; then
            printf 'Backup error: %s\n' "${BACKUP_CREATE_ERROR:-failed while capturing Limine reference state}" >&2
            rm -rf -- "$dir"
            return 3
        fi
    fi

    if [[ -n $ESP_MOUNT && -n $BOOT_EFI_PATH ]]; then
        rel=${BOOT_EFI_PATH//\\//}; rel=${rel#/}; efi_src="$ESP_MOUNT/$rel"
        printf '%s\n' "$efi_src" >"$dir/bootcurrent-efi-source.txt"
        if ! copy_path_into_backup "$efi_src" "$dir"; then
            printf 'Backup error: %s\n' "${BACKUP_CREATE_ERROR:-failed while copying $efi_src}" >&2
            rm -rf -- "$dir"
            return 3
        fi
    else
        : >"$dir/bootcurrent-efi-source.txt"
    fi

    if ! create_manifest_hashes "$dir"; then
        BACKUP_CREATE_ERROR='could not create backup integrity manifest'
        rm -rf -- "$dir"
        return 3
    fi
    CREATED_BACKUP_DIR=$dir
    return 0
}

create_current_bootloader_backup_interactive() {
    local ans rc
    detect_bootloader
    case "$BOOTLOADER" in
        grub|limine) ;;
        *) printf '\nUser backups are currently enabled only for GRUB2 and Limine.\n'; return 1 ;;
    esac
    printf '\nCurrent bootloader: %s\nBackup directory:   %s\n\n' "$(bootloader_display_name "$BOOTLOADER")" "$BACKUP_ROOT"
    read -r -p 'Back up the currently booted bootloader? [y/n]: ' ans
    case "$ans" in
        y|Y|yes|YES)
            create_current_bootloader_backup; rc=$?
            if ((rc == 0)); then
                printf '\nBackup created: %s\n' "$CREATED_BACKUP_DIR"
                if validate_backup_compatibility "$CREATED_BACKUP_DIR"; then
                    printf 'Backup validation: VALID, COMPATIBLE\n'
                else
                    printf 'Backup validation: FAILED (%s)\n' "$BACKUP_COMPATIBILITY_REASON"
                    return 1
                fi
            else
                printf '\nBackup failed safely: %s\n' "${BACKUP_CREATE_ERROR:-unknown backup error}"
                printf 'No bootloader state was modified.\n'
                return "$rc"
            fi
            ;;
        n|N|no|NO|'') printf 'Backup cancelled.\n' ;;
        *) printf 'Unrecognized response. Backup cancelled.\n'; return 1 ;;
    esac
}

# opensuse_leap16.sh carried Phase-0 stubs for backup listing long after the
# r31 backup creator/validator became live.  Override those stubs here as well;
# otherwise the main menu can count real backups via discover_backups_quiet(),
# while selectors [4]/[5]/[6] still fall into the obsolete "not ported" text.
# Keep the output contract from the inherited r47 list helper, but validate
# every entry through the Leap r31 validator above.
list_backups() {
    discover_backups_quiet
    ((${#DISCOVERED_BACKUPS[@]})) || { printf 'No backups found in %s\n' "$BACKUP_ROOT"; return 0; }

    local d idx=1
    for d in "${DISCOVERED_BACKUPS[@]}"; do
        if validate_backup_compatibility "$d"; then
            load_backup_metadata "$d" >/dev/null 2>&1 || true
            printf '[%d] %s  [VALID, COMPATIBLE]\n' "$idx" "$(basename "$d")"
        elif validate_backup "$d"; then
            printf '[%d] %s  [VALID, NOT RESTORABLE: %s]\n' "$idx" "$(basename "$d")" "$BACKUP_COMPATIBILITY_REASON"
        else
            printf '[%d] %s  [INVALID: %s]\n' "$idx" "$(basename "$d")" "$BACKUP_VALIDATION_REASON"
        fi
        ((idx++))
    done
}

list_backups_interactive() {
    printf '\nBackups in %s:\n\n' "$BACKUP_ROOT"
    list_backups
}

# Every real GRUB2 <-> Limine live transaction now offers the optional user
# backup after preflight/plan but before STAGE.  The internal transaction
# snapshot remains mandatory and independent.
if declare -F confirm_operation >/dev/null 2>&1; then
    eval "$(declare -f confirm_operation | sed '1s/confirm_operation/confirm_operation_pre_leap16_r31/')"
fi
confirm_operation() {
    local current=$1 target=$2
    case "$current:$target" in
        grub:limine|limine:grub)
            offer_operation_backup || return 1
            ;;
    esac
    confirm_operation_pre_leap16_r31 "$@"
}

# Restore execution -----------------------------------------------------------
#
# r31 backups are Leap-native, while the generic r47 restore dispatchers later
# in the inherited stack are CachyOS/Arch-specific.  Do not expose those by
# merely removing the menu label.  Instead, route only the two hardware-proven
# live edges (GRUB2 <-> Limine) through the existing Leap transaction engines
# and substitute only the backed-up target payload/policy at candidate staging.
# Source-first BootOrder, BootNext, runtime proof, rollback and retirement stay
# owned by the same r30 transaction machinery used by an ordinary switch.

LEAP16_R31_RESTORE_DIR=""

leap16_r31_backup_kernel_set_matches() {
    local dir=$1 current backup
    collect_kernels
    current=$(printf '%s\n' "${KERNEL_VERSIONS[@]}" | sed '/^[[:space:]]*$/d' | LC_ALL=C sort -u)
    backup=$(sed '/^[[:space:]]*$/d' "$dir/kernel-versions.txt" 2>/dev/null | LC_ALL=C sort -u)
    [[ -n $current && $current == "$backup" ]]
}

leap16_r31_restore_identity_preflight() {
    local dir=$1 target=$2
    validate_backup_compatibility "$dir" || { fail "Backup is not compatible: $BACKUP_COMPATIBILITY_REASON"; return 1; }
    load_backup_metadata "$dir" || return 1
    [[ ${bootloader:-} == "$target" ]] || { fail "Selected backup is not a $(bootloader_display_name "$target") backup"; return 1; }
    [[ ${backup_platform:-} == "$LEAP16_R31_BACKUP_PLATFORM" && ${backup_schema:-} == "$LEAP16_R31_BACKUP_SCHEMA" ]] || {
        fail 'Selected backup is not a leap16-r31 native backup'
        return 1
    }
    collect_storage_info
    [[ ${esp_mount:-} == "$ESP_MOUNT" ]] || {
        fail "Backup ESP mountpoint (${esp_mount:-unknown}) differs from the current validated mountpoint ($ESP_MOUNT)"
        fail 'r31 restore refuses to rewrite backed-up topology.'
        return 1
    }
    leap16_r31_backup_kernel_set_matches "$dir" || {
        fail 'Installed kernel versions do not exactly match the selected backup.'
        fail 'Restore is refused rather than applying boot policy/payload to a different kernel set.'
        return 1
    }
    return 0
}

leap16_r31_restore_grub_preflight() {
    local dir=$1 cfg policy syscfg
    leap16_r31_restore_identity_preflight "$dir" grub || return 1
    [[ ${payload_policy:-} == opensuse-bootloader-owned-paths ]] || { fail 'Unexpected GRUB2 backup payload policy'; return 1; }

    detect_bootloader
    [[ $BOOTLOADER == limine ]] || { fail 'GRUB2 backup restore currently requires Limine as the verified source'; return 1; }
    # Reuse the exact finalized-Limine gate that the normal r28 reconstruction
    # path uses.  This keeps the current source/fallback/NVRAM proof unchanged.
    r28_validate_finalized_limine_source || return 1

    policy="$dir/files/etc/default/grub"
    cfg="$dir/files/boot/grub2/grub.cfg"
    syscfg="$dir/files/etc/sysconfig/bootloader"
    [[ -f $policy && ! -L $policy ]] || { fail 'GRUB2 backup is missing a regular /etc/default/grub'; return 1; }
    [[ -f $cfg && ! -L $cfg ]] || { fail 'GRUB2 backup is missing a regular /boot/grub2/grub.cfg'; return 1; }
    if have grub2-script-check; then
        grub2-script-check "$cfg" >/dev/null 2>&1 || { fail 'Backed-up grub.cfg fails grub2-script-check'; return 1; }
    fi
    [[ -n ${ROOT_UUID:-} ]] && grep -Fq -- "root=UUID=$ROOT_UUID" "$cfg" || {
        fail 'Backed-up GRUB2 configuration does not reference the current root UUID'
        return 1
    }
    if [[ -f $syscfg ]]; then
        grep -Eq '^[[:space:]]*LOADER_TYPE=.*grub2-efi' "$syscfg" || {
            fail 'Backed-up /etc/sysconfig/bootloader does not identify grub2-efi'
            return 1
        }
    fi
    ok 'Validated Leap-native GRUB2 backup against the finalized Limine source and current kernel/root topology'
}

leap16_r31_restore_limine_preflight() {
    local dir=$1 esp_rel mid efi splash managed backup_cmd current_cmd raw
    leap16_r31_restore_identity_preflight "$dir" limine || return 1
    [[ ${payload_policy:-} == config-efi-splash-plus-staged-payload ]] || { fail 'Unexpected Limine backup payload policy'; return 1; }

    detect_bootloader
    [[ $BOOTLOADER == grub ]] || { fail 'Limine backup restore currently requires GRUB2 as the verified source'; return 1; }
    # Normal Leap GRUB2 -> Limine preflight proves the source and requires a
    # clean target namespace before any restored target bytes are written.
    run_switch_preflight limine || return 1

    load_backup_metadata "$dir" || return 1
    esp_rel=${esp_mount#/}; mid=${machine_id:-}
    efi="$dir/files/$esp_rel/EFI/LIMINE/LIMINE_X64.EFI"
    splash="$dir/files/$esp_rel/limine-splash.png"
    managed="$dir/files/$esp_rel/$mid"
    [[ -f $efi && ! -L $efi ]] || { fail 'Limine backup is missing a regular EFI/LIMINE/LIMINE_X64.EFI'; return 1; }
    [[ -f $splash && ! -L $splash ]] || { fail 'Limine backup is missing a regular limine-splash.png'; return 1; }
    [[ -d $managed && ! -L $managed ]] || { fail 'Limine backup is missing its managed kernel/initrd tree'; return 1; }
    ! find "$managed" -type l -print -quit 2>/dev/null | grep -q . || { fail 'Limine managed backup tree contains a symlink that VFAT cannot represent safely'; return 1; }
    [[ $(od -An -tx1 -N2 -- "$efi" 2>/dev/null | tr -d '[:space:]') == 4d5a ]] || { fail 'Backed-up Limine EFI executable lacks an MZ header'; return 1; }
    if have file; then
        leap16_is_x86_64_efi_application "$efi" || { fail 'Backed-up Limine executable is not an x86-64 EFI application'; return 1; }
    fi
    [[ $(od -An -tx1 -N8 -- "$splash" 2>/dev/null | tr -d '[:space:]') == 89504e470d0a1a0a ]] || { fail 'Backed-up Limine splash is not a PNG file'; return 1; }

    backup_cmd=$(r23_backup_limine_cmdline "$dir" 2>/dev/null || true)
    raw=$(cat /proc/cmdline 2>/dev/null || true)
    current_cmd=$(r42_portable_limine_cmdline "$raw" 2>/dev/null || true)
    [[ -n $backup_cmd && -n $current_cmd ]] || { fail 'Could not resolve backup/current portable Limine command line'; return 1; }
    pending_cmdline_equivalent "$backup_cmd" "$current_cmd" || {
        fail 'Backed-up Limine kernel command line is not token-equivalent to the current proven GRUB runtime.'
        return 1
    }
    ok 'Validated self-contained Limine backup against the current GRUB2 source and current kernel/root topology'
}

# Restore the backed-up GRUB policy into r28's native openSUSE reconstruction.
# Generated /boot/grub2 modules/config and EFI/OPENSUSE are still rebuilt by the
# installed Leap packages, which avoids blindly replaying stale generated EFI
# metadata while preserving the user's validated GRUB policy.
if declare -F r28_render_grub_default >/dev/null 2>&1; then
    eval "$(declare -f r28_render_grub_default | sed '1s/r28_render_grub_default/r28_render_grub_default_pre_leap16_r31_restore/')"
fi
r28_render_grub_default() {
    local out=$1 src
    if [[ -n ${LEAP16_R31_RESTORE_DIR:-} ]]; then
        src="$LEAP16_R31_RESTORE_DIR/files/etc/default/grub"
        [[ -f $src && ! -L $src ]] || { fail 'Selected GRUB2 backup policy disappeared before staging'; return 1; }
        cat -- "$src" >"$out" || return 1
        ok 'Prepared /etc/default/grub from the selected validated Leap backup'
        return 0
    fi
    declare -F r28_render_grub_default_pre_leap16_r31_restore >/dev/null 2>&1 || return 1
    r28_render_grub_default_pre_leap16_r31_restore "$@"
}

# Freeze the selected Limine backup's EFI+splash bytes into the mandatory
# transaction snapshot.  That prevents a user-owned backup from changing under
# an already-started restore transaction.
if declare -F leap16_prepare_limine_assets >/dev/null 2>&1; then
    eval "$(declare -f leap16_prepare_limine_assets | sed '1s/leap16_prepare_limine_assets/leap16_prepare_limine_assets_pre_leap16_r31_restore/')"
fi
leap16_prepare_limine_assets() {
    local dir=${LEAP16_R31_RESTORE_DIR:-} esp_rel src_efi src_splash dst_efi dst_splash
    if [[ -z $dir ]]; then
        declare -F leap16_prepare_limine_assets_pre_leap16_r31_restore >/dev/null 2>&1 || return 1
        leap16_prepare_limine_assets_pre_leap16_r31_restore "$@"
        return $?
    fi
    [[ -n ${TRANSACTION_SNAPSHOT_DIR:-} && -d $TRANSACTION_SNAPSHOT_DIR ]] || { fail 'Transaction snapshot is unavailable for restored Limine payload freezing'; return 1; }
    load_backup_metadata "$dir" || return 1
    esp_rel=${esp_mount#/}
    src_efi="$dir/files/$esp_rel/EFI/LIMINE/LIMINE_X64.EFI"
    src_splash="$dir/files/$esp_rel/limine-splash.png"
    dst_efi="$TRANSACTION_SNAPSHOT_DIR/BOOTX64.EFI.restore-source"
    dst_splash="$TRANSACTION_SNAPSHOT_DIR/limine-splash.png.restore-source"
    cp -- "$src_efi" "$dst_efi" || return 1
    cp -- "$src_splash" "$dst_splash" || return 1
    [[ $(sha256sum -- "$src_efi" | awk '{print $1}') == $(sha256sum -- "$dst_efi" | awk '{print $1}') ]] || { fail 'Frozen Limine EFI restore source differs from the validated backup'; return 1; }
    [[ $(sha256sum -- "$src_splash" | awk '{print $1}') == $(sha256sum -- "$dst_splash" | awk '{print $1}') ]] || { fail 'Frozen Limine splash restore source differs from the validated backup'; return 1; }
    chmod 600 -- "$dst_efi" "$dst_splash" 2>/dev/null || true
    LEAP16_LIMINE_EFI_SOURCE=$dst_efi
    R23_LIMINE_SPLASH_SOURCE=$dst_splash
    LEAP16_LIMINE_SPLASH_SOURCE_SHA256=$(sha256sum -- "$dst_splash" | awk '{print $1}')
    ok 'Frozen validated Limine backup EFI+splash bytes into the private transaction snapshot'
}

if declare -F write_limine_candidate_policy >/dev/null 2>&1; then
    eval "$(declare -f write_limine_candidate_policy | sed '1s/write_limine_candidate_policy/write_limine_candidate_policy_pre_leap16_r31_restore/')"
fi
write_limine_candidate_policy() {
    local dir=${LEAP16_R31_RESTORE_DIR:-} esp_rel src_default src_conf
    if [[ -z $dir ]]; then
        declare -F write_limine_candidate_policy_pre_leap16_r31_restore >/dev/null 2>&1 || return 1
        write_limine_candidate_policy_pre_leap16_r31_restore "$@"
        return $?
    fi
    [[ ! -e /etc/default/limine ]] || { fail '/etc/default/limine appeared after restore preflight'; return 1; }
    [[ ! -e "$ESP_MOUNT/limine.conf" ]] || { fail 'limine.conf appeared after restore preflight'; return 1; }
    load_backup_metadata "$dir" || return 1
    esp_rel=${esp_mount#/}
    src_default="$dir/files/etc/default/limine"
    src_conf="$dir/files/$esp_rel/limine.conf"
    [[ -f $src_default && -f $src_conf ]] || { fail 'Selected Limine backup policy/config disappeared before staging'; return 1; }
    sudo install -o root -g root -m 0644 -- "$src_default" /etc/default/limine || return 1
    sudo install -o root -g root -m 0644 -- "$src_conf" "$ESP_MOUNT/limine.conf" || return 1
    r23_install_cachyos_limine_splash "$R23_LIMINE_SPLASH_SOURCE" || return 1
    LIMINE_DEFAULT_CREATED=1
    LIMINE_DEFAULT_HASH=$(sha256sum /etc/default/limine 2>/dev/null | awk '{print $1}' || sudo -n sha256sum /etc/default/limine 2>/dev/null | awk '{print $1}' || true)
    [[ $LIMINE_DEFAULT_HASH =~ ^[0-9A-Fa-f]{64}$ ]] || { fail 'Could not hash restored /etc/default/limine'; return 1; }
    ok 'Restored validated Limine policy + limine.conf from backup before managed-payload staging'
}

if declare -F stage_limine_kernel_entries_from_existing_artifacts >/dev/null 2>&1; then
    eval "$(declare -f stage_limine_kernel_entries_from_existing_artifacts | sed '1s/stage_limine_kernel_entries_from_existing_artifacts/stage_limine_kernel_entries_from_existing_artifacts_pre_leap16_r31_restore/')"
fi
stage_limine_kernel_entries_from_existing_artifacts() {
    local dir=${LEAP16_R31_RESTORE_DIR:-} esp_rel mid src dst
    if [[ -z $dir ]]; then
        declare -F stage_limine_kernel_entries_from_existing_artifacts_pre_leap16_r31_restore >/dev/null 2>&1 || return 1
        stage_limine_kernel_entries_from_existing_artifacts_pre_leap16_r31_restore "$@"
        return $?
    fi
    load_backup_metadata "$dir" || return 1
    esp_rel=${esp_mount#/}; mid=${machine_id:-}
    src="$dir/files/$esp_rel/$mid"
    dst="$ESP_MOUNT/$mid"
    [[ -d $src && ! -L $src ]] || { fail 'Selected Limine managed payload disappeared before staging'; return 1; }
    [[ ! -e $dst ]] || { fail "Limine managed target appeared after restore preflight: $dst"; return 1; }
    ! find "$src" -type l -print -quit 2>/dev/null | grep -q . || { fail 'Limine restore payload contains a symlink that VFAT cannot represent safely'; return 1; }
    sudo cp -a --no-preserve=all -- "$src" "$dst" || return 1
    ok 'Restored self-contained Limine managed kernel/initrd tree with VFAT-safe copy semantics'
}

leap16_r31_restore_grub_backup() {
    local dir=$1 ans rc
    leap16_r31_restore_grub_preflight "$dir" || return 1
    printf '\nLeap-native GRUB2 backup restore transaction plan:\n'
    printf '  - Restore the validated backed-up /etc/default/grub policy.\n'
    printf '  - Reconstruct /boot/grub2 + EFI/OPENSUSE with the installed native Leap grub2/shim packages instead of blindly replaying generated EFI/module bytes.\n'
    printf '  - Keep Limine primary/fallback authoritative until the exact reconstructed shim target passes a real runtime proof.\n'
    printf '  - After proof, transfer EFI/BOOT back to native shim and retire only ownership-proven Limine state.\n'
    printf '  - The backed-up /etc/sysconfig/bootloader, /boot/grub2 and EFI/OPENSUSE copies remain integrity/reference evidence; generated target bytes are rebuilt.\n\n'
    offer_operation_backup || return 1
    read -r -p 'Type RESTORE to stage this validated GRUB2 backup, or anything else to cancel: ' ans
    [[ $ans == RESTORE ]] || { printf 'Restore cancelled. No boot state was modified by the restore.\n'; return 0; }
    leap16_r31_restore_grub_preflight "$dir" || { fail 'Write-boundary GRUB2 restore revalidation failed; nothing was staged'; return 1; }
    LEAP16_R31_RESTORE_DIR=$dir
    OPERATION_BACKUP=$dir
    rc=0
    r28_execute_limine_to_rebuilt_grub || rc=$?
    LEAP16_R31_RESTORE_DIR=""
    return "$rc"
}

leap16_r31_restore_limine_backup() {
    local dir=$1 ans rc
    leap16_r31_restore_limine_preflight "$dir" || return 1
    printf '\nLeap-native Limine backup restore transaction plan:\n'
    printf '  - Restore the integrity-validated /etc/default/limine, limine.conf, splash, EFI/LIMINE payload and complete managed kernel/initrd tree.\n'
    printf '  - Keep native GRUB2 first and EFI/BOOT untouched while the restored Limine candidate is deeply validated.\n'
    printf '  - Create exactly one canonical Limine Boot####, arm it once with BootNext and require real runtime proof.\n'
    printf '  - Preserve the existing two-stage canonical + generic-fallback proof before ownership-proven GRUB2 cleanup.\n\n'
    offer_operation_backup || return 1
    read -r -p 'Type RESTORE to stage this validated Limine backup, or anything else to cancel: ' ans
    [[ $ans == RESTORE ]] || { printf 'Restore cancelled. No boot state was modified by the restore.\n'; return 0; }
    leap16_r31_restore_limine_preflight "$dir" || { fail 'Write-boundary Limine restore revalidation failed; nothing was staged'; return 1; }
    LEAP16_R31_RESTORE_DIR=$dir
    OPERATION_BACKUP=$dir
    rc=0
    execute_grub_to_limine || rc=$?
    LEAP16_R31_RESTORE_DIR=""
    return "$rc"
}

# Final Leap dispatch: expose [5] only for the two backends whose live
# transaction engines are hardware-proven on this port.  Same-backend restore
# remains intentionally separate from repair/reinstall, and systemd-boot/rEFInd
# stay locked until their Leap migration backends exist.
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
    detect_bootloader
    source=$BOOTLOADER

    if [[ $source == "$target" ]]; then
        printf '\nSame-backend %s restore is not exposed as a fake switch transaction.\n' "$(bootloader_display_name "$target")"
        [[ $target == grub ]] && printf 'Use GRUB2 repair/reinstall for the currently active backend.\n'
        return 2
    fi

    case "$source:$target" in
        limine:grub) leap16_r31_restore_grub_backup "$dir" ;;
        grub:limine) leap16_r31_restore_limine_backup "$dir" ;;
        *)
            printf 'Restore %s -> %s is not enabled in leap16-r31.\n' "$(bootloader_display_name "$source")" "$(bootloader_display_name "$target")"
            printf 'Only the hardware-proven GRUB2 <-> Limine transaction engines are exposed.\n'
            return 2
            ;;
    esac
}

# Restore planning remains read-only, but selector [5] now executes the
# Leap-native staged restore path described above.
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
    esp_rel=${esp_mount#/}; mid=${machine_id:-}

    printf '\nValidated read-only restore plan:\n'
    printf '  Backup:          %s\n' "$dir"
    printf '  Bootloader:      %s\n' "$(bootloader_display_name "$bootloader")"
    printf '  Original ESP:    %s (%s) mounted at %s\n' "$esp_source" "$esp_uuid" "$esp_mount"
    printf '  Original root:   %s (%s)\n' "$root_source" "$root_uuid"
    printf '  Integrity:       SHA256 manifest valid\n'
    printf '  Compatibility:   machine ID + ESP UUID + root UUID match\n\n'
    case "$bootloader" in
        grub)
            printf 'Captured GRUB2 state:\n'
            printf '  - /etc/default/grub\n'
            [[ -e $dir/files/etc/sysconfig/bootloader ]] && printf '  - /etc/sysconfig/bootloader\n'
            printf '  - /boot/grub2\n'
            printf '  - %s/EFI/OPENSUSE\n' "$esp_mount"
            printf '  - %s/EFI/BOOT/{BOOTX64.EFI,fallback.efi,MokManager.efi} captured as shared recovery/reference evidence only\n' "$esp_mount"
            ;;
        limine)
            printf 'Captured Limine state:\n'
            printf '  - /etc/default/limine\n'
            printf '  - %s/limine.conf\n' "$esp_mount"
            printf '  - %s/limine-splash.png\n' "$esp_mount"
            printf '  - %s/EFI/LIMINE\n' "$esp_mount"
            printf '  - %s/%s managed kernel/initrd tree\n' "$esp_mount" "$mid"
            printf '  - %s/EFI/BOOT/BOOTX64.EFI captured as ownership/reference evidence only\n' "$esp_mount"
            ;;
    esac
    printf '\nRestore execution is available from selector [5] for cross-backend GRUB2 <-> Limine backups.\n'
    printf 'This selector is read-only; no file, package, EFI or NVRAM state was modified.\n'
}

# r30's second reboot is deliberate: canonical Limine is proven first, then the
# genuine EFI/BOOT fallback is BootNext-tested before GRUB retirement.  Keep the
# proof model exactly as-is, but disclose the automatic follow-up reboot before
# the user starts the first boot test.
r13_prompt_reboot() {
    local answer
    printf '\nThe one-shot boot test and root-owned automatic resume service are armed.\n'
    if r21_fallback_meta_exists 2>/dev/null; then
        printf 'This reboot is the final fallback proof: it targets the explicit Limine EFI fallback.\n'
        printf 'Native GRUB2 remains intact until that exact fallback BootCurrent proof succeeds.\n'
        printf 'No additional automatic reboot is expected after this fallback proof completes.\n'
        read -r -p 'Reboot now for the final fallback proof? [y/N]: ' answer
    else
        printf 'The next boot targets canonical Limine.\n'
        printf 'IMPORTANT: if canonical Limine passes runtime proof, the resume service will automatically stage the genuine EFI fallback and reboot the machine ONE MORE TIME to prove it before GRUB2 cleanup.\n'
        printf 'That second reboot is intentional; no firmware-menu selection or terminal command is required.\n'
        printf 'GRUB2 remains intact until the fallback proof succeeds.\n'
        read -r -p 'Reboot now and authorize the possible automatic second reboot? [y/N]: ' answer
    fi
    case "$answer" in
        y|Y|yes|YES)
            printf 'Rebooting now. No firmware-menu selection is required.\n'
            sudo systemctl reboot
            ;;
        *)
            if r21_fallback_meta_exists 2>/dev/null; then
                printf 'Reboot deferred. The final fallback BootNext and temporary resume service remain armed for the next normal reboot.\n'
            else
                printf 'Reboot deferred. BootNext and the temporary resume service remain armed. When you next reboot normally, a successful canonical proof may trigger the one automatic follow-up fallback reboot described above.\n'
            fi
            ;;
    esac
}
