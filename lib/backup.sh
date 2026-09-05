#!/usr/bin/env bash

DISCOVERED_BACKUPS=()
BACKUP_VALIDATION_REASON=""
BACKUP_COMPATIBILITY_REASON=""
CREATED_BACKUP_DIR=""
BACKUP_CREATE_ERROR=""

backup_paths_for_bootloader() {
    local bl=$1 esp=${ESP_MOUNT:-/boot}
    esp=${esp%/}
    case "$bl" in
        grub) printf '%s\n' /etc/default/grub /etc/grub.d /boot/grub ;;
        # Limine keeps limine.conf at the root of the detected ESP.  Do not
        # hard-code /boot: a valid existing topology may mount the ESP elsewhere.
        limine)
            local machine_id
            machine_id=$(cat /etc/machine-id 2>/dev/null || true)
            printf '%s\n' /etc/limine-entry-tool.conf /etc/default/limine "$esp/limine.conf" "$esp/limine-splash.png" "$esp/EFI/LIMINE"
            [[ -n $machine_id ]] && printf '%s\n' "$esp/$machine_id"
            ;;
        refind) printf '%s\n' "$esp/EFI/refind" /boot/refind_linux.conf /etc/refind.d ;;
        systemd-boot) printf '%s\n' "$esp/loader" "$esp/EFI/systemd" /etc/sdboot-manage.conf /etc/sdboot-manage.conf.d /etc/kernel/cmdline ;;
    esac
}

# Copy one absolute source path into files/<absolute-path-without-leading-slash>.
# Protected sources are read with cached sudo credentials only. Authentication is
# performed by preflight before this function runs; copy helpers never prompt.
# The privileged side writes only an archive stream to stdout. Extraction into
# the user's backup directory always runs unprivileged.
copy_path_into_backup() {
    local src=$1 dstroot=$2 rel parent base dest_parent dest_path
    local -a ps

    BACKUP_CREATE_ERROR=""
    [[ $src == /* ]] || { BACKUP_CREATE_ERROR="refusing non-absolute backup source: $src"; return 1; }
    rel=${src#/}
    case "/$rel/" in
        */../*|*/./*) BACKUP_CREATE_ERROR="refusing unsafe backup source path: $src"; return 1 ;;
    esac

    # Missing optional bootloader-owned paths are fine. Because ESP traversal can
    # itself be protected, consult sudo non-interactively before deciding missing.
    if [[ ! -e $src && ! -L $src ]]; then
        if ! sudo -n test -e "$src" 2>/dev/null && ! sudo -n test -L "$src" 2>/dev/null; then
            return 0
        fi
    fi

    parent=$(dirname -- "$rel")
    base=$(basename -- "$rel")
    dest_parent="$dstroot/files/$parent"
    dest_path="$dest_parent/$base"
    mkdir -p -- "$dest_parent" || { BACKUP_CREATE_ERROR="could not create backup destination for $src"; return 1; }

    if cp -a -- "$src" "$dest_parent/" 2>/dev/null; then
        return 0
    fi

    # cp may have left a partial destination before hitting a protected child.
    # Remove only that path inside the newly-created backup tree before retrying.
    rm -rf -- "$dest_path" 2>/dev/null || {
        BACKUP_CREATE_ERROR="could not clear partial backup copy for $src"
        return 1
    }

    # Do NOT test stdin/stdout for a TTY here. This function is intentionally
    # called from a while-read loop whose stdin is a process-substitution pipe.
    # Preflight already handled authentication; protected reads must now be -n.
    if ! sudo -n true 2>/dev/null; then
        BACKUP_CREATE_ERROR="sudo authorization expired/unavailable while reading protected source: $src"
        return 1
    fi

    printf 'Reading protected source for backup: %s\n' "$src" >&2
    sudo -n tar -C / -cf - -- "$rel" | tar --no-same-owner -C "$dstroot/files" -xf -
    ps=("${PIPESTATUS[@]}")
    if (( ${ps[0]:-1} != 0 || ${ps[1]:-1} != 0 )); then
        BACKUP_CREATE_ERROR="privileged read/extraction failed for: $src"
        return 1
    fi
    return 0
}

path_exists_for_backup_read() {
    local path=$1
    [[ -e $path || -L $path ]] || sudo -n test -e "$path" 2>/dev/null || sudo -n test -L "$path" 2>/dev/null
}

hash_path_for_backup_read() {
    local algo=$1 path=$2
    case "$algo" in sha256sum|b2sum) ;; *) return 2 ;; esac
    if [[ -r $path ]]; then
        "$algo" -- "$path" 2>/dev/null | awk '{print $1}'
    else
        sudo -n "$algo" -- "$path" 2>/dev/null | awk '{print $1}'
    fi
}

copy_reference_file_readonly() {
    local src=$1 dst=$2
    path_exists_for_backup_read "$src" || return 1
    mkdir -p -- "$(dirname -- "$dst")" || return 1
    if [[ -r $src ]]; then
        cat -- "$src" >"$dst"
    else
        sudo -n cat -- "$src" >"$dst"
    fi
}

create_limine_backup_references() {
    local dir=$1 esp=${ESP_MOUNT%/} esp_rel conf_copy fallback fallback_hash snapshot_hash
    local ver kid kernel_uri initrd_uri kernel_path initrd_path kernel_b2 initrd_b2
    esp_rel=${esp#/}
    conf_copy="$dir/files/$esp_rel/limine.conf"
    [[ -f $conf_copy ]] || { BACKUP_CREATE_ERROR="Limine backup is missing the generated $esp/limine.conf snapshot"; return 1; }

    # EFI/BOOT is a shared fallback namespace.  Preserve its bytes and identity
    # as reference evidence, but do not classify it as a directly owned Limine
    # restore path.  A future restore must prove ownership before touching it.
    fallback="$esp/EFI/BOOT/BOOTX64.EFI"
    {
        printf 'path=%q\n' "$fallback"
        if path_exists_for_backup_read "$fallback"; then
            fallback_hash=$(hash_path_for_backup_read sha256sum "$fallback" || true)
            [[ -n $fallback_hash ]] || { BACKUP_CREATE_ERROR='could not hash the current EFI fallback executable'; return 1; }
            printf 'exists=1\nsha256=%q\n' "$fallback_hash"
        else
            printf 'exists=0\nsha256=\n'
        fi
    } >"$dir/limine-fallback-reference.conf" || return 1

    if path_exists_for_backup_read "$fallback"; then
        copy_reference_file_readonly "$fallback" "$dir/references/EFI-BOOT-BOOTX64.EFI" || {
            BACKUP_CREATE_ERROR='could not snapshot the current shared EFI fallback executable'
            return 1
        }
        snapshot_hash=$(sha256sum -- "$dir/references/EFI-BOOT-BOOTX64.EFI" | awk '{print $1}')
        [[ $snapshot_hash == "$fallback_hash" ]] || {
            BACKUP_CREATE_ERROR='EFI fallback reference snapshot hash mismatch'
            return 1
        }
    fi

    # Record exact Limine URIs and BLAKE2b-512 identities. Format v4 also
    # copies the complete machine-id managed payload tree, so these references
    # become an integrity map for a self-contained restore. Legacy v3 backups
    # keep only the reference map and are restored by validated reconstruction.
    printf 'kernel_id\tversion\tkernel_uri\tkernel_b2\tinitramfs_uri\tinitramfs_b2\n' >"$dir/limine-staged-reference.tsv"
    for ver in "${KERNEL_VERSIONS[@]}"; do
        kid=$(kernel_pkgbase_for_version "$ver" 2>/dev/null || true)
        [[ -n $kid ]] || continue
        kernel_uri=$(limine_conf_field_for_kernel "$kid" path "$conf_copy" 2>/dev/null || true)
        initrd_uri=$(limine_conf_field_for_kernel "$kid" module_path "$conf_copy" 2>/dev/null || true)
        kernel_b2='' initrd_b2=''
        [[ -n $kernel_uri ]] || { BACKUP_CREATE_ERROR="$kid has no kernel path in the backed-up limine.conf"; return 1; }
        [[ -n $initrd_uri ]] || { BACKUP_CREATE_ERROR="$kid has no initramfs module_path in the backed-up limine.conf"; return 1; }
        kernel_path=$(resolve_limine_boot_uri "$kernel_uri" 2>/dev/null || true)
        initrd_path=$(resolve_limine_boot_uri "$initrd_uri" 2>/dev/null || true)
        [[ -n $kernel_path && -n $initrd_path ]] || { BACKUP_CREATE_ERROR="$kid has an invalid boot(): URI in limine.conf"; return 1; }
        path_exists_for_backup_read "$kernel_path" || { BACKUP_CREATE_ERROR="$kid staged kernel is missing: $kernel_path"; return 1; }
        path_exists_for_backup_read "$initrd_path" || { BACKUP_CREATE_ERROR="$kid staged initramfs is missing: $initrd_path"; return 1; }
        kernel_b2=$(hash_path_for_backup_read b2sum "$kernel_path" || true)
        initrd_b2=$(hash_path_for_backup_read b2sum "$initrd_path" || true)
        [[ $kernel_b2 =~ ^[0-9A-Fa-f]{128}$ ]] || { BACKUP_CREATE_ERROR="could not BLAKE2-hash $kid staged kernel"; return 1; }
        [[ $initrd_b2 =~ ^[0-9A-Fa-f]{128}$ ]] || { BACKUP_CREATE_ERROR="could not BLAKE2-hash $kid staged initramfs"; return 1; }
        if [[ $kernel_uri == *#* ]]; then
            [[ ${kernel_uri##*#} == "$kernel_b2" ]] || { BACKUP_CREATE_ERROR="$kid staged kernel hash does not match backed-up limine.conf"; return 1; }
        fi
        if [[ $initrd_uri == *#* ]]; then
            [[ ${initrd_uri##*#} == "$initrd_b2" ]] || { BACKUP_CREATE_ERROR="$kid staged initramfs hash does not match backed-up limine.conf"; return 1; }
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$kid" "$ver" "$kernel_uri" "$kernel_b2" "$initrd_uri" "$initrd_b2" >>"$dir/limine-staged-reference.tsv"
    done
    return 0
}

create_manifest_hashes() {
    local dir=$1
    # v4 hashes every payload/reference/metadata file automatically.  This
    # avoids accidentally adding a new backup component without protecting it.
    (
        cd "$dir" || exit 1
        find . -type f ! -name SHA256SUMS -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 -r sha256sum
    ) > "$dir/SHA256SUMS"
}

create_current_bootloader_backup() {
    CREATED_BACKUP_DIR=""
    BACKUP_CREATE_ERROR=""
    detect_bootloader; collect_kernels
    if ! run_validation preflight >/dev/null; then
        BACKUP_CREATE_ERROR='preflight validation failed'
        return 2
    fi
    if [[ $BOOTLOADER == unknown ]]; then
        BACKUP_CREATE_ERROR='currently booted bootloader could not be identified safely'
        return 2
    fi

    local ts dir path rel efi_src
    ts=$(date '+%Y%m%d-%H%M%S')
    dir="$BACKUP_ROOT/${BOOTLOADER}-${ts}"
    mkdir -p -- "$dir/files" || { BACKUP_CREATE_ERROR="could not create backup directory: $dir"; return 3; }
    chmod 700 -- "$BACKUP_ROOT" "$dir" 2>/dev/null || true

    {
        printf 'format_version=4\n'
        printf 'bootloader=%q\n' "$BOOTLOADER"
        if [[ $BOOTLOADER == limine ]]; then printf 'payload_policy=%q\n' 'config-efi-splash-plus-staged-payload'; else printf 'payload_policy=%q\n' 'bootloader-owned-paths'; fi
        printf 'created_epoch=%q\n' "$(date +%s)"
        printf 'created_iso=%q\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
        printf 'hostname=%q\n' "$(hostname)"
        printf 'machine_id=%q\n' "$(cat /etc/machine-id 2>/dev/null || true)"
        printf 'esp_source=%q\n' "$ESP_SOURCE"
        printf 'esp_mount=%q\n' "$ESP_MOUNT"
        printf 'esp_uuid=%q\n' "$ESP_UUID"
        printf 'root_source=%q\n' "$ROOT_SOURCE"
        printf 'root_uuid=%q\n' "$ROOT_UUID"
        printf 'boot_current=%q\n' "$BOOT_CURRENT"
        printf 'boot_label=%q\n' "$BOOT_LABEL"
        printf 'boot_efi_path=%q\n' "$BOOT_EFI_PATH"
    } > "$dir/metadata.conf"

    efibootmgr -v > "$dir/efibootmgr-v.txt" 2>&1 || true
    findmnt --fstab > "$dir/fstab-parsed.txt" 2>&1 || true
    cp -a -- /etc/fstab "$dir/fstab.reference" 2>/dev/null || true
    pacman -Q > "$dir/package-state.txt" 2>/dev/null || true
    printf '%s\n' "${KERNEL_VERSIONS[@]}" > "$dir/kernel-versions.txt"

    while IFS= read -r path; do
        [[ -n $path ]] || continue
        if ! copy_path_into_backup "$path" "$dir"; then
            printf 'Backup error: %s\n' "${BACKUP_CREATE_ERROR:-failed while copying $path}" >&2
            rm -rf -- "$dir"
            return 3
        fi
    done < <(backup_paths_for_bootloader "$BOOTLOADER")

    if [[ $BOOTLOADER == limine ]]; then
        if ! create_limine_backup_references "$dir"; then
            printf 'Backup error: %s\n' "${BACKUP_CREATE_ERROR:-failed while capturing Limine reference state}" >&2
            rm -rf -- "$dir"
            return 3
        fi
    fi

    if [[ -n $ESP_MOUNT && -n $BOOT_EFI_PATH ]]; then
        rel=${BOOT_EFI_PATH//\\//}; rel=${rel#/}; efi_src="$ESP_MOUNT/$rel"
        printf '%s\n' "$efi_src" > "$dir/bootcurrent-efi-source.txt"
        if ! copy_path_into_backup "$efi_src" "$dir"; then
            printf 'Backup error: %s\n' "${BACKUP_CREATE_ERROR:-failed while copying $efi_src}" >&2
            rm -rf -- "$dir"
            return 3
        fi
    else
        : > "$dir/bootcurrent-efi-source.txt"
    fi

    if ! create_manifest_hashes "$dir"; then
        BACKUP_CREATE_ERROR='could not create backup integrity manifest'
        printf 'Backup error: %s\n' "$BACKUP_CREATE_ERROR" >&2
        rm -rf -- "$dir"
        return 3
    fi
    CREATED_BACKUP_DIR=$dir
    return 0
}

load_backup_metadata() {
    local dir=$1 bad
    bad=$(grep -Ev '^[a-z_][a-z0-9_]*=(\x27[^\x27]*\x27|[^[:space:];&|<>`$()]*)$|^[a-z_][a-z0-9_]*=$' "$dir/metadata.conf" 2>/dev/null || true)
    [[ -z $bad ]] || return 1
    # shellcheck disable=SC1090
    source "$dir/metadata.conf"
}

backup_limine_v4_payloads_match_references() {
    local dir=$1 esp_rel=$2 refs
    refs="$dir/limine-staged-reference.tsv"
    local kid ver kernel_uri kernel_b2 initrd_uri initrd_b2 rel path actual uri_hash rows=0
    while IFS=$'\t' read -r kid ver kernel_uri kernel_b2 initrd_uri initrd_b2; do
        [[ $kid == kernel_id ]] && continue
        [[ -n $kid && -n $kernel_uri && -n $initrd_uri ]] || return 1
        for pair in "kernel:$kernel_uri:$kernel_b2" "initramfs:$initrd_uri:$initrd_b2"; do
            local kind rest uri expected
            kind=${pair%%:*}
            rest=${pair#*:}
            uri=${rest%:*}
            expected=${rest##*:}
            [[ $uri == boot\(\):/* ]] || return 1
            rel=${uri#boot():/}; rel=${rel%%#*}
            [[ -n $rel && $rel != /* && $rel != *'..'* ]] || return 1
            path="$dir/files/$esp_rel/$rel"
            [[ -f $path ]] || return 1
            actual=$(b2sum -- "$path" 2>/dev/null | awk '{print $1}' || true)
            [[ $actual =~ ^[0-9A-Fa-f]{128}$ && $actual == "$expected" ]] || return 1
            if [[ $uri == *#* ]]; then
                uri_hash=${uri##*#}
                [[ $uri_hash == "$actual" ]] || return 1
            fi
        done
        ((rows++))
    done <"$refs"
    ((rows > 0))
}

validate_backup() {
    local dir=$1
    BACKUP_VALIDATION_REASON=""
    [[ -d $dir ]] || { BACKUP_VALIDATION_REASON='backup directory is missing'; return 1; }
    [[ -f $dir/metadata.conf && -f $dir/SHA256SUMS ]] || { BACKUP_VALIDATION_REASON='manifest files are missing'; return 1; }
    load_backup_metadata "$dir" || { BACKUP_VALIDATION_REASON='metadata format is invalid'; return 1; }
    case "${format_version:-}" in 2|3|4) ;; *) BACKUP_VALIDATION_REASON='unsupported backup format'; return 1 ;; esac
    case "${bootloader:-}" in grub|limine|refind|systemd-boot) ;; *) BACKUP_VALIDATION_REASON='unknown bootloader type'; return 1;; esac
    (cd "$dir" && sha256sum -c SHA256SUMS >/dev/null 2>&1) || { BACKUP_VALIDATION_REASON='integrity check failed'; return 1; }
    [[ -n ${machine_id:-} ]] || { BACKUP_VALIDATION_REASON='machine ID missing'; return 1; }

    if [[ $format_version == 3 && $bootloader == limine ]]; then
        local esp_rel=${esp_mount:-}
        esp_rel=${esp_rel#/}
        [[ -n $esp_rel && $esp_rel != *'..'* ]] || { BACKUP_VALIDATION_REASON='invalid ESP mount metadata in Limine v3 backup'; return 1; }
        [[ -f $dir/files/$esp_rel/limine.conf ]] || { BACKUP_VALIDATION_REASON='Limine v3 backup is missing limine.conf'; return 1; }
        [[ -d $dir/files/$esp_rel/EFI/LIMINE ]] || { BACKUP_VALIDATION_REASON='Limine v3 backup is missing EFI/LIMINE'; return 1; }
        [[ -f $dir/limine-staged-reference.tsv ]] || { BACKUP_VALIDATION_REASON='Limine v3 backup is missing staged-kernel reference metadata'; return 1; }
        [[ -f $dir/limine-fallback-reference.conf ]] || { BACKUP_VALIDATION_REASON='Limine v3 backup is missing EFI fallback reference metadata'; return 1; }
        local staged_rows kernel_rows
        staged_rows=$(awk -F '\t' 'NR>1 && NF==6 && $1!="" && $2!="" && $3!="" && $4 ~ /^[0-9A-Fa-f]{128}$/ && $5!="" && $6 ~ /^[0-9A-Fa-f]{128}$/ {n++} END{print n+0}' "$dir/limine-staged-reference.tsv")
        kernel_rows=$(grep -cve '^[[:space:]]*$' "$dir/kernel-versions.txt" 2>/dev/null || true)
        [[ $staged_rows -gt 0 && $staged_rows -eq $kernel_rows ]] || { BACKUP_VALIDATION_REASON='Limine v3 staged-kernel reference metadata is incomplete'; return 1; }
    fi

    if [[ $format_version == 4 && $bootloader == limine ]]; then
        local esp_rel=${esp_mount:-} mid
        esp_rel=${esp_rel#/}
        mid=${machine_id:-}
        [[ -n $esp_rel && $esp_rel != *'..'* ]] || { BACKUP_VALIDATION_REASON='invalid ESP mount metadata in Limine v4 backup'; return 1; }
        [[ -n $mid && $mid != *'/'* && $mid != *'..'* ]] || { BACKUP_VALIDATION_REASON='invalid machine ID in Limine v4 backup'; return 1; }
        [[ -f $dir/files/$esp_rel/limine.conf ]] || { BACKUP_VALIDATION_REASON='Limine v4 backup is missing limine.conf'; return 1; }
        [[ -f $dir/files/$esp_rel/limine-splash.png ]] || { BACKUP_VALIDATION_REASON='Limine v4 backup is missing the CachyOS Limine splash'; return 1; }
        [[ -d $dir/files/$esp_rel/EFI/LIMINE ]] || { BACKUP_VALIDATION_REASON='Limine v4 backup is missing EFI/LIMINE'; return 1; }
        [[ -d $dir/files/$esp_rel/$mid ]] || { BACKUP_VALIDATION_REASON='Limine v4 backup is missing its managed kernel/initramfs payload tree'; return 1; }
        [[ -f $dir/limine-staged-reference.tsv && -f $dir/limine-fallback-reference.conf ]] || { BACKUP_VALIDATION_REASON='Limine v4 reference metadata is incomplete'; return 1; }
        local staged_rows kernel_rows
        staged_rows=$(awk -F '\t' 'NR>1 && NF==6 && $1!="" && $2!="" && $3!="" && $4 ~ /^[0-9A-Fa-f]{128}$/ && $5!="" && $6 ~ /^[0-9A-Fa-f]{128}$/ {n++} END{print n+0}' "$dir/limine-staged-reference.tsv")
        kernel_rows=$(grep -cve '^[[:space:]]*$' "$dir/kernel-versions.txt" 2>/dev/null || true)
        [[ $staged_rows -gt 0 && $staged_rows -eq $kernel_rows ]] || { BACKUP_VALIDATION_REASON='Limine v4 staged-kernel reference metadata is incomplete'; return 1; }
        backup_limine_v4_payloads_match_references "$dir" "$esp_rel" || { BACKUP_VALIDATION_REASON='Limine v4 managed payload bytes do not match their recorded BLAKE2 references'; return 1; }
    fi
    BACKUP_VALIDATION_REASON='valid'
}

validate_backup_compatibility() {
    local dir=$1
    BACKUP_COMPATIBILITY_REASON=""
    validate_backup "$dir" || { BACKUP_COMPATIBILITY_REASON="$BACKUP_VALIDATION_REASON"; return 1; }
    load_backup_metadata "$dir" || return 1
    if [[ $bootloader == limine && $format_version == 2 ]]; then
        BACKUP_COMPATIBILITY_REASON='legacy Limine v2 backup lacks the required limine.conf/staged-reference completeness guarantees'
        return 1
    fi
    [[ -r /etc/machine-id && $(cat /etc/machine-id) == "$machine_id" ]] || { BACKUP_COMPATIBILITY_REASON='different machine ID'; return 1; }
    collect_storage_info
    [[ -n $esp_uuid && -n $ESP_UUID && $esp_uuid == "$ESP_UUID" ]] || { BACKUP_COMPATIBILITY_REASON='ESP UUID mismatch/unresolved'; return 1; }
    [[ -n $root_uuid && -n $ROOT_UUID && $root_uuid == "$ROOT_UUID" ]] || { BACKUP_COMPATIBILITY_REASON='root UUID mismatch/unresolved'; return 1; }
    BACKUP_COMPATIBILITY_REASON='compatible'
}

discover_backups_quiet() {
    DISCOVERED_BACKUPS=(); [[ -d $BACKUP_ROOT ]] || return 0
    local d
    while IFS= read -r -d '' d; do [[ -f $d/metadata.conf ]] && DISCOVERED_BACKUPS+=("$d"); done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
}

list_backups() {
    discover_backups_quiet
    ((${#DISCOVERED_BACKUPS[@]})) || { printf 'No backups found in %s\n' "$BACKUP_ROOT"; return 0; }
    local d idx=1
    for d in "${DISCOVERED_BACKUPS[@]}"; do
        if validate_backup_compatibility "$d"; then
            load_backup_metadata "$d" >/dev/null 2>&1 || true
            if [[ ${bootloader:-} == limine && ${format_version:-} == 3 ]]; then
                printf '[%d] %s  [VALID, COMPATIBLE, LEGACY RECONSTRUCTABLE]\n' "$idx" "$(basename "$d")"
            else
                printf '[%d] %s  [VALID, COMPATIBLE]\n' "$idx" "$(basename "$d")"
            fi
        elif validate_backup "$d"; then
            printf '[%d] %s  [VALID, NOT RESTORABLE: %s]\n' "$idx" "$(basename "$d")" "$BACKUP_COMPATIBILITY_REASON"
        else
            printf '[%d] %s  [INVALID: %s]\n' "$idx" "$(basename "$d")" "$BACKUP_VALIDATION_REASON"
        fi
        ((idx++))
    done
}

create_current_bootloader_backup_interactive() {
    detect_bootloader
    [[ $BOOTLOADER != unknown ]] || { printf '\nCannot safely identify the currently booted bootloader. Backup aborted.\n'; return 1; }
    printf '\nCurrent bootloader: %s\nBackup directory:   %s\n\n' "$BOOTLOADER" "$BACKUP_ROOT"
    read -r -p 'Back up the currently booted bootloader? [y/n]: ' ans
    case "$ans" in
        y|Y|yes|YES)
            local rc
            create_current_bootloader_backup; rc=$?
            if ((rc == 0)); then
                printf '\nBackup created: %s\n' "$CREATED_BACKUP_DIR"
                if validate_backup_compatibility "$CREATED_BACKUP_DIR"; then printf 'Backup validation: VALID, COMPATIBLE\n'; else printf 'Backup validation: FAILED (%s)\n' "$BACKUP_COMPATIBILITY_REASON"; fi
            else
                printf '\nBackup failed safely: %s\n' "${BACKUP_CREATE_ERROR:-unknown backup error}"
                printf 'No bootloader state was modified.\n'
            fi ;;
        n|N|no|NO) printf 'Backup cancelled.\n' ;;
        '') printf 'No selection entered. Backup cancelled.\n' ;;
        *) printf 'Unrecognized response. Backup cancelled.\n' ;;
    esac
}

list_backups_interactive() { printf '\nBackups in %s:\n\n' "$BACKUP_ROOT"; list_backups; }

restore_plan_interactive() {
    discover_backups_quiet
    ((${#DISCOVERED_BACKUPS[@]})) || { printf '\nNo backups found.\n'; return 0; }
    printf '\n'; list_backups; printf '\n'
    read -r -p 'Select backup number to inspect, or Enter to cancel: ' n
    [[ -n $n ]] || return 0
    [[ $n =~ ^[0-9]+$ ]] && ((n>=1 && n<=${#DISCOVERED_BACKUPS[@]})) || { printf 'Invalid selection.\n'; return 1; }
    local dir=${DISCOVERED_BACKUPS[n-1]}
    validate_backup_compatibility "$dir" || { printf 'Restore plan refused: %s.\n' "$BACKUP_COMPATIBILITY_REASON"; return 1; }
    load_backup_metadata "$dir"; collect_storage_info
    printf '\nValidated read-only restore plan:\n  Backup:          %s\n  Bootloader:      %s\n  Original ESP:    %s (%s) mounted at %s\n  Current ESP:     %s (%s) mounted at %s\n  Original root:   %s (%s)\n\n' "$dir" "$bootloader" "$esp_source" "$esp_uuid" "$esp_mount" "$ESP_SOURCE" "$ESP_UUID" "$ESP_MOUNT" "$root_source" "$root_uuid"
    ok 'Backup integrity is valid.'; ok 'Machine ID matches.'; ok 'ESP UUID matches.'; ok 'Root UUID matches.'
    if [[ $bootloader == limine && $format_version == 3 ]]; then
        info 'Legacy Limine v3 restore mode: reconstruct themed Limine from the backed-up policy plus the current validated kernel/initramfs artifacts.'
    elif [[ $bootloader == limine && $format_version == 4 ]]; then
        info 'Limine v4 restore mode: restore the self-contained themed config/splash/managed payload, then install the current Limine EFI binary.'
    fi
    info 'This menu is read-only; choose Restore a validated backup to execute the supported restore transaction.'
}
