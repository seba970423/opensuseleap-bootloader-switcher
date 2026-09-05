#!/usr/bin/env bash
# r26: adapter-based transaction framework for GRUB/systemd-boot/rEFInd while
# retaining the already hardware-proven GRUB <-> Limine paths unchanged.

R26_PENDING_FORMAT=5
R26_SOURCE_MANIFEST=""
R26_TARGET_MANIFEST=""
R26_SOURCE_EFI_RESOLVED=""
R26_SOURCE_EFI_HASH=""
R26_SOURCE_FALLBACK_OWNED=0
R26_ADAPTER_REVISION=1
R26_STAGED_TARGET_ID=""

PENDING_SOURCE_MANIFEST=""
PENDING_TARGET_MANIFEST=""
PENDING_SOURCE_EFI_RESOLVED=""
PENDING_SOURCE_EFI_HASH=""
PENDING_SOURCE_FALLBACK_OWNED=0
PENDING_ADAPTER_REVISION=""

# Keep all proven legacy implementations callable. The adapter engine is used
# only for the four newly enabled hub directions in r26.
eval "$(declare -f load_pending_state | sed '1s/load_pending_state/load_pending_state_pre_r26/')"
eval "$(declare -f validate_pending_compatibility | sed '1s/validate_pending_compatibility/validate_pending_compatibility_pre_r26/')"
eval "$(declare -f verify_pending_candidate_ownership_unchanged | sed '1s/verify_pending_candidate_ownership_unchanged/verify_pending_candidate_ownership_unchanged_pre_r26/')"
eval "$(declare -f verify_pending_source_recovery_unchanged | sed '1s/verify_pending_source_recovery_unchanged/verify_pending_source_recovery_unchanged_pre_r26/')"
eval "$(declare -f validate_pending_target_deep | sed '1s/validate_pending_target_deep/validate_pending_target_deep_pre_r26/')"
eval "$(declare -f rollback_pending_candidate | sed '1s/rollback_pending_candidate/rollback_pending_candidate_pre_r26/')"
eval "$(declare -f r23_arm_candidate_automatically | sed '1s/r23_arm_candidate_automatically/r23_arm_candidate_automatically_pre_r26/')"
eval "$(declare -f r22_resume_transaction_root | sed '1s/r22_resume_transaction_root/r22_resume_transaction_root_pre_r26/')"
eval "$(declare -f operation_supported | sed '1s/operation_supported/operation_supported_pre_r26/')"
eval "$(declare -f run_live_operation | sed '1s/run_live_operation/run_live_operation_pre_r26/')"
eval "$(declare -f show_operation_plan | sed '1s/show_operation_plan/show_operation_plan_pre_r26/')"
eval "$(declare -f manage_pending_migration | sed '1s/manage_pending_migration/manage_pending_migration_pre_r26/')"

r26_state_format() {
    awk -F'\t' '$1=="format"{print $2; exit}' "$PENDING_STATE_FILE" 2>/dev/null
}

r26_reset_pending_extras() {
    PENDING_SOURCE_MANIFEST="" PENDING_TARGET_MANIFEST=""
    PENDING_SOURCE_EFI_RESOLVED="" PENDING_SOURCE_EFI_HASH=""
    PENDING_SOURCE_FALLBACK_OWNED=0 PENDING_ADAPTER_REVISION=""
}

load_pending_state() {
    r26_reset_pending_extras
    if [[ $(r26_state_format) != "$R26_PENDING_FORMAT" ]]; then
        load_pending_state_pre_r26 "$@"
        return $?
    fi

    pending_reset
    r26_reset_pending_extras
    [[ -f $PENDING_STATE_FILE ]] || { PENDING_REASON='no staged migration exists'; return 1; }
    local key value
    while IFS=$'\t' read -r key value; do
        case "$key" in
            format) PENDING_FORMAT=$value ;;
            phase) PENDING_PHASE=$value ;;
            created) PENDING_CREATED=$value ;;
            machine_id) PENDING_MACHINE_ID=$value ;;
            source) PENDING_SOURCE=$value ;;
            target) PENDING_TARGET=$value ;;
            old_boot_id) PENDING_OLD_BOOT_ID=${value^^} ;;
            old_boot_label) PENDING_OLD_BOOT_LABEL=$value ;;
            old_boot_efi_path) PENDING_OLD_BOOT_EFI_PATH=$value ;;
            old_fallback_path) PENDING_OLD_FALLBACK_PATH=$value ;;
            old_fallback_hash) PENDING_OLD_FALLBACK_HASH=$value ;;
            old_fallback_existed) PENDING_OLD_FALLBACK_EXISTED=$value ;;
            old_fallback_snapshot) PENDING_OLD_FALLBACK_SNAPSHOT=$value ;;
            post_stage_fallback_hash) PENDING_POST_STAGE_FALLBACK_HASH=$value ;;
            transaction_snapshot_dir) PENDING_TRANSACTION_SNAPSHOT_DIR=$value ;;
            original_boot_order) PENDING_ORIGINAL_BOOT_ORDER=$value ;;
            target_boot_id) PENDING_TARGET_BOOT_ID=${value^^} ;;
            target_efi_path) PENDING_TARGET_EFI_PATH=$value ;;
            target_efi_resolved) PENDING_TARGET_EFI_RESOLVED=$value ;;
            target_efi_hash) PENDING_TARGET_EFI_HASH=$value ;;
            source_efi_resolved) PENDING_SOURCE_EFI_RESOLVED=$value ;;
            source_efi_hash) PENDING_SOURCE_EFI_HASH=$value ;;
            source_manifest) PENDING_SOURCE_MANIFEST=$value ;;
            target_manifest) PENDING_TARGET_MANIFEST=$value ;;
            source_fallback_owned) PENDING_SOURCE_FALLBACK_OWNED=$value ;;
            adapter_revision) PENDING_ADAPTER_REVISION=$value ;;
            esp_uuid) PENDING_ESP_UUID=$value ;;
            root_uuid) PENDING_ROOT_UUID=$value ;;
            esp_source) PENDING_ESP_SOURCE=$value ;;
            esp_mount) PENDING_ESP_MOUNT=$value ;;
            backup_path) PENDING_BACKUP_PATH=$value ;;
            diagnostic_path) PENDING_DIAGNOSTIC_PATH=$value ;;
            source_cmdline) PENDING_SOURCE_CMDLINE=$value ;;
            ''|'#'*) ;;
            *) PENDING_REASON="unknown r26 pending-state key: $key"; return 1 ;;
        esac
    done <"$PENDING_STATE_FILE"

    [[ $PENDING_PHASE == candidate-ready || $PENDING_PHASE == boot-armed || $PENDING_PHASE == runtime-validated ]] || { PENDING_REASON='unsupported pending-state phase'; return 1; }
    case "$PENDING_SOURCE:$PENDING_TARGET" in
        grub:systemd-boot|systemd-boot:grub|grub:refind|refind:grub) ;;
        *) PENDING_REASON='unsupported r26 adapter migration direction'; return 1 ;;
    esac
    [[ $PENDING_FORMAT == "$R26_PENDING_FORMAT" ]] || { PENDING_REASON='wrong r26 state format'; return 1; }
    [[ $PENDING_ADAPTER_REVISION == "$R26_ADAPTER_REVISION" ]] || { PENDING_REASON='unsupported adapter-state revision'; return 1; }
    [[ -n $PENDING_MACHINE_ID && -n $PENDING_OLD_BOOT_ID && -n $PENDING_TARGET_BOOT_ID ]] || { PENDING_REASON='missing transaction identity'; return 1; }
    [[ -n $PENDING_SOURCE_CMDLINE ]] || { PENDING_REASON='missing source kernel command line'; return 1; }
    [[ -n $PENDING_SOURCE_MANIFEST && -n $PENDING_TARGET_MANIFEST ]] || { PENDING_REASON='missing adapter ownership manifests'; return 1; }
    PENDING_REASON='valid'
    return 0
}

r26_path_in_snapshot() {
    local p=$1
    [[ -n $p && -n $PENDING_TRANSACTION_SNAPSHOT_DIR ]] || return 1
    pending_path_under "$p" "$PENDING_TRANSACTION_SNAPSHOT_DIR"
}

validate_pending_compatibility() {
    if [[ $(r26_state_format) != "$R26_PENDING_FORMAT" ]]; then
        validate_pending_compatibility_pre_r26 "$@"
        return $?
    fi
    load_pending_state || return 1
    collect_storage_info
    local machine_id
    machine_id=$(cat /etc/machine-id 2>/dev/null || true)
    [[ $machine_id == "$PENDING_MACHINE_ID" ]] || { PENDING_REASON='machine ID mismatch'; return 1; }
    [[ -n $PENDING_ESP_UUID && $ESP_UUID == "$PENDING_ESP_UUID" ]] || { PENDING_REASON='ESP UUID mismatch'; return 1; }
    [[ -n $PENDING_ROOT_UUID && $ROOT_UUID == "$PENDING_ROOT_UUID" ]] || { PENDING_REASON='root UUID mismatch'; return 1; }
    [[ $ESP_SOURCE == "$PENDING_ESP_SOURCE" && $ESP_MOUNT == "$PENDING_ESP_MOUNT" ]] || { PENDING_REASON='ESP source/mount topology changed'; return 1; }
    pending_validate_snapshot_dir || return 1
    r26_path_in_snapshot "$PENDING_SOURCE_MANIFEST" || { PENDING_REASON='source manifest escaped transaction snapshot'; return 1; }
    r26_path_in_snapshot "$PENDING_TARGET_MANIFEST" || { PENDING_REASON='target manifest escaped transaction snapshot'; return 1; }
    [[ -s $PENDING_SOURCE_MANIFEST && -s $PENDING_TARGET_MANIFEST ]] || { PENDING_REASON='adapter ownership manifest is missing/empty'; return 1; }
    [[ $PENDING_SOURCE_EFI_RESOLVED == "$PENDING_ESP_MOUNT/"* ]] || { PENDING_REASON='source EFI path is outside the recorded ESP'; return 1; }
    [[ $PENDING_TARGET_EFI_RESOLVED == "$PENDING_ESP_MOUNT/"* ]] || { PENDING_REASON='target EFI path is outside the recorded ESP'; return 1; }
    pending_hash_is_sha256 "$PENDING_SOURCE_EFI_HASH" || { PENDING_REASON='invalid source EFI hash'; return 1; }
    pending_hash_is_sha256 "$PENDING_TARGET_EFI_HASH" || { PENDING_REASON='invalid target EFI hash'; return 1; }
    [[ $PENDING_SOURCE_FALLBACK_OWNED == 0 || $PENDING_SOURCE_FALLBACK_OWNED == 1 ]] || { PENDING_REASON='invalid fallback ownership flag'; return 1; }
    PENDING_REASON='compatible'
    return 0
}

r26_manifest_token() {
    local path=$1
    printf '%s' "$path" | sha256sum | awk '{print substr($1,1,16)}'
}

r26_record_owned_path() {
    local record=$1 path=$2 token mf hash
    if ! sudo -n test -e "$path" 2>/dev/null && ! sudo -n test -L "$path" 2>/dev/null && [[ ! -e $path && ! -L $path ]]; then
        return 0
    fi
    if sudo -n test -d "$path" 2>/dev/null || [[ -d $path ]]; then
        token=$(r26_manifest_token "$path")
        mf="$TRANSACTION_SNAPSHOT_DIR/tree-$token.tsv"
        write_privileged_tree_manifest "$path" "$mf" || { fail "Could not snapshot exact ownership tree: $path"; return 1; }
        printf 'tree\t%s\t%s\n' "$path" "$(basename -- "$mf")" >>"$record" || return 1
    elif sudo -n test -f "$path" 2>/dev/null || [[ -f $path ]]; then
        hash=$(sudo -n sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || true)
        [[ $hash =~ ^[0-9A-Fa-f]{64}$ ]] || { fail "Could not hash ownership file: $path"; return 1; }
        printf 'file\t%s\t%s\n' "$path" "$hash" >>"$record" || return 1
    else
        fail "Unsupported ownership object type: $path"
        return 1
    fi
}

r26_verify_owned_manifest() {
    local record=$1 kind path identity actual mf
    [[ -s $record ]] || { fail "Ownership record is missing/empty: $record"; return 1; }
    while IFS=$'\t' read -r kind path identity; do
        [[ -n $kind && -n $path && -n $identity ]] || return 1
        case "$kind" in
            file)
                actual=$(sudo -n sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || true)
                [[ -n $actual && $actual == "$identity" ]] || { fail "Ownership-proven file changed/missing: $path"; return 1; }
                ;;
            tree)
                mf="$(dirname -- "$record")/$identity"
                pending_verify_tree_manifest "$path" "$mf" || { fail "Ownership-proven tree changed/missing: $path"; return 1; }
                ;;
            *) fail "Unknown ownership manifest record type: $kind"; return 1 ;;
        esac
    done <"$record"
    return 0
}

r26_remove_owned_manifest_paths() {
    local record=$1 kind path identity
    r26_verify_owned_manifest "$record" || return 1
    # Remove files before trees only when they are separate namespaces. The
    # manifests used here intentionally contain no parent+child duplicates.
    while IFS=$'\t' read -r kind path identity; do
        case "$kind" in
            file) sudo rm -f -- "$path" || return 1 ;;
            tree) sudo rm -rf -- "$path" || return 1 ;;
        esac
        ok "Retired ownership-proven source path: $path"
    done <"$record"
}

r26_systemd_entry_paths() {
    # CachyOS sdboot-manage writes one deterministic BLS entry per kernel
    # directly under loader/entries, plus an optional -fallback entry when a
    # fallback initramfs exists. Never claim the entire loader/entries tree:
    # unrelated/foreign BLS entries must survive both staging and retirement.
    local ver kid dir="${ESP_MOUNT%/}/loader/entries"
    collect_kernels
    for ver in "${KERNEL_VERSIONS[@]}"; do
        kid=$(kernel_pkgbase_for_version "$ver" 2>/dev/null || true)
        [[ -n $kid ]] || continue
        printf '%s\n' "$dir/$kid.conf" "$dir/$kid-fallback.conf"
    done
}

r26_adapter_paths() {
    local bl=$1 machine_id
    machine_id=$(cat /etc/machine-id 2>/dev/null || true)
    case "$bl" in
        grub)
            printf '%s\n' /boot/grub "$ESP_MOUNT/EFI/CACHYOS" /etc/default/grub
            ;;
        limine)
            printf '%s\n' "$ESP_MOUNT/EFI/LIMINE" "$ESP_MOUNT/limine.conf" "$ESP_MOUNT/limine-splash.png" /etc/default/limine
            [[ -n $machine_id ]] && printf '%s\n' "$ESP_MOUNT/$machine_id"
            ;;
        systemd-boot)
            printf '%s\n' "$ESP_MOUNT/EFI/systemd" "$ESP_MOUNT/loader/loader.conf" /etc/sdboot-manage.conf.d/90-cachyos-bootloader-switcher.conf
            r26_systemd_entry_paths
            ;;
        refind)
            printf '%s\n' "$ESP_MOUNT/EFI/refind" /boot/refind_linux.conf
            ;;
    esac
}

r26_adapter_validate() {
    local bl=$1 mode=${2:-migration}
    case "$bl" in
        grub) validate_grub_boot_chain "$mode" && validate_cachyos_grub_theme ;;
        limine) validate_limine_boot_chain "$mode" && validate_cachyos_limine_theme ;;
        systemd-boot) validate_systemd_boot_chain "$mode" ;;
        refind) validate_refind_boot_chain "$mode" ;;
        *) fail "No adapter validator for $bl"; return 1 ;;
    esac
}

# Explicit source/target adapter contract. These named functions make the r26
# composition model testable without writing pair-specific transaction logic.
adapter_source_validate() { r26_adapter_validate "$1" source; }
adapter_target_validate() { r26_adapter_validate "$1" target; }
adapter_target_runtime_validate() { r26_adapter_validate "$1" runtime; }
adapter_target_final_validate() { r26_adapter_validate "$1" final; }
adapter_source_preserve_recovery() { verify_pending_source_recovery_unchanged; }
adapter_target_arm() { r23_arm_candidate_automatically; }
adapter_target_promote() {
    local target_id=$1 source_id=$2
    set_target_first_preserving_other_entries "$target_id" "$source_id" >/dev/null || return 1
    [[ $(pending_bootorder_first) == "${target_id^^}" ]]
}
adapter_source_retire() { r26_retire_source_adapter; }

r26_snapshot_source_adapter() {
    local source=$1 path source_record fallback snapshot_hash
    R26_SOURCE_EFI_RESOLVED=$(resolve_efi_path_on_esp_privileged "$BOOT_EFI_PATH" 2>/dev/null || true)
    [[ -n $R26_SOURCE_EFI_RESOLVED ]] || { fail 'Could not resolve active source EFI executable'; return 1; }
    R26_SOURCE_EFI_HASH=$(sudo -n sha256sum -- "$R26_SOURCE_EFI_RESOLVED" 2>/dev/null | awk '{print $1}' || true)
    [[ $R26_SOURCE_EFI_HASH =~ ^[0-9A-Fa-f]{64}$ ]] || { fail 'Could not hash active source EFI executable'; return 1; }

    mkdir -p -- "$PENDING_STATE_DIR" || return 1
    chmod 700 -- "$PENDING_STATE_DIR" 2>/dev/null || true
    TRANSACTION_SNAPSHOT_DIR=$(mktemp -d "$PENDING_STATE_DIR/.prestage.XXXXXX") || return 1
    chmod 700 -- "$TRANSACTION_SNAPSHOT_DIR" 2>/dev/null || true
    source_record="$TRANSACTION_SNAPSHOT_DIR/source-owned.tsv"
    : >"$source_record" || return 1
    while IFS= read -r path; do
        [[ -n $path ]] || continue
        r26_record_owned_path "$source_record" "$path" || return 1
    done < <(r26_adapter_paths "$source")
    [[ -s $source_record ]] || { fail "Source adapter $source produced an empty ownership record"; return 1; }
    R26_SOURCE_MANIFEST=$source_record

    OLD_FALLBACK_PATH="$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"
    OLD_FALLBACK_EXISTED=0 OLD_FALLBACK_HASH="" OLD_FALLBACK_SNAPSHOT="" R26_SOURCE_FALLBACK_OWNED=0 POST_STAGE_FALLBACK_HASH=""
    if sudo -n test -f "$OLD_FALLBACK_PATH" 2>/dev/null || [[ -f $OLD_FALLBACK_PATH ]]; then
        OLD_FALLBACK_EXISTED=1
        OLD_FALLBACK_HASH=$(sudo -n sha256sum -- "$OLD_FALLBACK_PATH" 2>/dev/null | awk '{print $1}' || true)
        [[ $OLD_FALLBACK_HASH =~ ^[0-9A-Fa-f]{64}$ ]] || { fail 'Could not hash existing generic UEFI fallback'; return 1; }
        OLD_FALLBACK_SNAPSHOT="$TRANSACTION_SNAPSHOT_DIR/BOOTX64.EFI.before"
        sudo -n cat -- "$OLD_FALLBACK_PATH" >"$OLD_FALLBACK_SNAPSHOT" 2>/dev/null || cat -- "$OLD_FALLBACK_PATH" >"$OLD_FALLBACK_SNAPSHOT" || return 1
        snapshot_hash=$(sha256sum -- "$OLD_FALLBACK_SNAPSHOT" | awk '{print $1}')
        [[ $snapshot_hash == "$OLD_FALLBACK_HASH" ]] || { fail 'Generic fallback snapshot hash mismatch'; return 1; }
        [[ $OLD_FALLBACK_HASH == "$R26_SOURCE_EFI_HASH" ]] && R26_SOURCE_FALLBACK_OWNED=1
    fi
    ok "Snapshotted $(bootloader_display_name "$source") source adapter ownership and recovery state"
}

adapter_source_snapshot() { r26_snapshot_source_adapter "$1"; }

r26_restore_source_fallback_after_target_stage() {
    local current snapshot_hash
    if ((OLD_FALLBACK_EXISTED)); then
        [[ -f $OLD_FALLBACK_SNAPSHOT ]] || { fail 'Source fallback snapshot disappeared'; return 1; }
        snapshot_hash=$(sha256sum -- "$OLD_FALLBACK_SNAPSHOT" | awk '{print $1}')
        [[ $snapshot_hash == "$OLD_FALLBACK_HASH" ]] || return 1
        sudo mkdir -p -- "$(dirname -- "$OLD_FALLBACK_PATH")" || return 1
        sudo install -m 0644 -- "$OLD_FALLBACK_SNAPSHOT" "$OLD_FALLBACK_PATH" || return 1
        current=$(sudo -n sha256sum -- "$OLD_FALLBACK_PATH" 2>/dev/null | awk '{print $1}' || true)
        [[ $current == "$OLD_FALLBACK_HASH" ]] || { fail 'Could not restore source fallback after target staging'; return 1; }
        POST_STAGE_FALLBACK_HASH=$current
        ok 'Restored the pre-stage generic UEFI fallback while the source remains authoritative'
    else
        if sudo -n test -f "$OLD_FALLBACK_PATH" 2>/dev/null; then
            sudo rm -f -- "$OLD_FALLBACK_PATH" || return 1
            ok 'Removed target-created generic fallback during candidate phase because the source had none'
        fi
        POST_STAGE_FALLBACK_HASH=""
    fi
}

r26_record_target_adapter() {
    local target=$1 path record
    TARGET_EFI_RESOLVED=$(resolve_efi_path_on_esp_privileged "$(target_expected_efi_path "$target")" 2>/dev/null || true)
    [[ -n $TARGET_EFI_RESOLVED ]] || { fail 'Could not resolve staged target EFI executable'; return 1; }
    TARGET_EFI_HASH=$(sudo -n sha256sum -- "$TARGET_EFI_RESOLVED" 2>/dev/null | awk '{print $1}' || true)
    [[ $TARGET_EFI_HASH =~ ^[0-9A-Fa-f]{64}$ ]] || { fail 'Could not hash staged target EFI executable'; return 1; }
    record="$TRANSACTION_SNAPSHOT_DIR/target-owned.tsv"
    : >"$record" || return 1
    while IFS= read -r path; do
        [[ -n $path ]] || continue
        r26_record_owned_path "$record" "$path" || return 1
    done < <(r26_adapter_paths "$target")
    [[ -s $record ]] || { fail "Target adapter $target produced an empty ownership record"; return 1; }
    R26_TARGET_MANIFEST=$record
    ok "Recorded exact $(bootloader_display_name "$target") target adapter ownership manifest"
}

r26_nonloader_cmdline_tokens() {
    local token
    for token in $1; do
        case "$token" in BOOT_IMAGE=*|boot_image=*|initrd=*|root=*|rw|ro) continue ;; esac
        printf '%s ' "$token"
    done | sed 's/[[:space:]]*$//'
}

r26_write_sdboot_policy() {
    local reference=$1 opts loader tmp
    opts=$(r26_nonloader_cmdline_tokens "$reference")
    sudo install -d -o root -g root -m 0755 /etc/sdboot-manage.conf.d || return 1
    tmp=$(mktemp) || return 1
    cat >"$tmp" <<POLICY
# Managed by CachyOS Bootloader Switcher ${SWITCHER_RELEASE:-r26}.
# Preserve the known-good non-loader cmdline while sdboot-manage supplies root/rw.
LINUX_OPTIONS="$opts"
DEFAULT_ENTRY="manual"
# Never clear the BLS directory: other operating systems may own entries here.
REMOVE_EXISTING="no"
OVERWRITE_EXISTING="yes"
PRESERVE_FOREIGN="yes"
POLICY
    sudo install -o root -g root -m 0644 "$tmp" /etc/sdboot-manage.conf.d/90-cachyos-bootloader-switcher.conf || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    loader="$ESP_MOUNT/loader/loader.conf"
    tmp=$(mktemp) || return 1
    cat >"$tmp" <<LOADER
default linux-cachyos.conf
timeout 5
console-mode keep
LOADER
    sudo install -d -m 0755 -- "$ESP_MOUNT/loader/entries" || { rm -f "$tmp"; return 1; }
    sudo install -m 0644 -- "$tmp" "$loader" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
}

r26_patch_refind_config() {
    local conf="$ESP_MOUNT/EFI/refind/refind.conf" tmp
    tmp=$(mktemp) || return 1
    sudo -n cat -- "$conf" >"$tmp" 2>/dev/null || cat -- "$conf" >"$tmp" || { rm -f "$tmp"; return 1; }
    awk -v list="$REFIND_CACHYOS_KERNEL_LIST" '
        BEGIN{done=0}
        /^[[:space:]]*#?[[:space:]]*extra_kernel_version_strings[[:space:]]+/ {
            if (!done) { print "extra_kernel_version_strings " list; done=1 }
            next
        }
        {print}
        END{if(!done) print "extra_kernel_version_strings " list}
    ' "$tmp" >"$tmp.new" || { rm -f "$tmp" "$tmp.new"; return 1; }
    sudo install -m 0644 -- "$tmp.new" "$conf" || { rm -f "$tmp" "$tmp.new"; return 1; }
    rm -f "$tmp" "$tmp.new"
}

r26_refind_cmdline() {
    # rEFInd needs the real kernel command line, including root= and rw/ro, but
    # loader-generated BOOT_IMAGE=/initrd= tokens are not portable between
    # bootloaders and must not be baked into refind_linux.conf.
    local token
    for token in $1; do
        case "$token" in BOOT_IMAGE=*|boot_image=*|initrd=*) continue ;; esac
        printf '%s ' "$token"
    done | sed 's/[[:space:]]*$//'
}

r26_write_refind_linux_conf() {
    local reference=$1 clean tmp
    clean=$(r26_refind_cmdline "$reference")
    [[ -n $clean ]] || { fail 'Could not derive a portable rEFInd kernel command line'; return 1; }
    tmp=$(mktemp) || return 1
    cat >"$tmp" <<EOF2
"Boot with standard options" "$clean"
"Boot to single-user mode" "$clean single"
EOF2
    sudo install -o root -g root -m 0644 "$tmp" /boot/refind_linux.conf || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
}

r26_stage_systemd_boot_target() {
    local source_id=$1 original_order=$2 reference=$3 target_id
    [[ $ESP_MOUNT == /boot ]] || {
        fail "${SWITCHER_RELEASE:-r26} systemd-boot adapter currently requires the detected ESP to be mounted at /boot because CachyOS sdboot-manage scans the ESP root for vmlinuz-* artifacts."
        fail "Detected ESP is $ESP_MOUNT. ${SWITCHER_RELEASE:-r26} refuses to rewrite /etc/fstab or move kernels to force a different topology."
        return 1
    }
    install_target_packages systemd-boot || return 1
    have bootctl || { fail 'bootctl is unavailable after package installation'; return 1; }
    have sdboot-manage || { fail 'sdboot-manage is unavailable after package installation'; return 1; }
    # Keep bootctl staging narrow and reversible: do not create a random-seed
    # payload or an entry-token directory that is unrelated to this transaction.
    sudo bootctl --esp-path="$ESP_MOUNT" --random-seed=no --make-entry-directory=no install || return 1
    r26_write_sdboot_policy "$reference" || return 1
    sudo sdboot-manage --esp-path="$ESP_MOUNT" gen || return 1
    # sdboot-manage may update loader defaults. Re-assert the deterministic
    # regular-kernel-first CachyOS transaction policy after entry generation.
    r26_write_sdboot_policy "$reference" || return 1
    find_nvram_entry_for_target systemd-boot || { fail 'Could not find the canonical systemd-boot NVRAM entry'; return 1; }
    target_id=$TARGET_NVRAM_ID
    set_source_first_boot_order "$source_id" "$target_id" "$original_order" || return 1
    r26_restore_source_fallback_after_target_stage || return 1
    adapter_target_validate systemd-boot || return 1
    r26_record_target_adapter systemd-boot || return 1
    R26_STAGED_TARGET_ID=${target_id^^}
    ok "Staged canonical systemd-boot NVRAM target as Boot$R26_STAGED_TARGET_ID"
}

r26_stage_refind_target() {
    local source_id=$1 original_order=$2 reference=$3 target_id
    install_target_packages refind || return 1
    have refind-install || { fail 'refind-install is unavailable after package installation'; return 1; }
    sudo refind-install || return 1
    [[ -f "$ESP_MOUNT/EFI/refind/refind.conf" ]] || sudo -n test -f "$ESP_MOUNT/EFI/refind/refind.conf" 2>/dev/null || { fail 'refind-install did not create the expected refind.conf on the detected ESP'; return 1; }
    r26_patch_refind_config || return 1
    r26_write_refind_linux_conf "$reference" || return 1
    find_nvram_entry_for_target refind || { fail 'Could not find the canonical rEFInd NVRAM entry'; return 1; }
    target_id=$TARGET_NVRAM_ID
    set_source_first_boot_order "$source_id" "$target_id" "$original_order" || return 1
    r26_restore_source_fallback_after_target_stage || return 1
    adapter_target_validate refind || return 1
    r26_record_target_adapter refind || return 1
    R26_STAGED_TARGET_ID=${target_id^^}
    ok "Staged canonical rEFInd NVRAM target as Boot$R26_STAGED_TARGET_ID"
}

r26_stage_grub_target() {
    local source_id=$1 original_order=$2 reference=$3 target_id
    install_target_packages grub || return 1
    have grub-install || { fail 'grub-install is unavailable after package installation'; return 1; }
    have grub-mkconfig || { fail 'grub-mkconfig is unavailable after package installation'; return 1; }
    write_grub_candidate_policy || return 1
    sudo grub-install --target=x86_64-efi --efi-directory="$ESP_MOUNT" --bootloader-id=cachyos --force || return 1
    find_nvram_entry_for_target grub || { fail 'Could not find canonical GRUB NVRAM entry after grub-install'; return 1; }
    target_id=$TARGET_NVRAM_ID
    set_source_first_boot_order "$source_id" "$target_id" "$original_order" || return 1
    r26_restore_source_fallback_after_target_stage || return 1
    sudo grub-mkconfig -o /boot/grub/grub.cfg || return 1
    adapter_target_validate grub || return 1
    r26_record_target_adapter grub || return 1
    R26_STAGED_TARGET_ID=${target_id^^}
    ok "Staged canonical GRUB NVRAM target as Boot$R26_STAGED_TARGET_ID"
}

adapter_target_stage() {
    local target=$1 source_id=$2 original_order=$3 reference=$4
    case "$target" in
        grub) r26_stage_grub_target "$source_id" "$original_order" "$reference" ;;
        systemd-boot) r26_stage_systemd_boot_target "$source_id" "$original_order" "$reference" ;;
        refind) r26_stage_refind_target "$source_id" "$original_order" "$reference" ;;
        *) fail "${SWITCHER_RELEASE:-r26} generic target staging is not enabled for $target"; return 1 ;;
    esac
}

r26_write_pending_adapter() {
    local source=$1 target=$2 source_id=$3 original_order=$4 target_id=$5 phase=${6:-candidate-ready}
    local machine_id created source_cmdline tmp v values=()
    machine_id=$(cat /etc/machine-id 2>/dev/null || true)
    created=$(date --iso-8601=seconds 2>/dev/null || date)
    source_cmdline=$(cat /proc/cmdline 2>/dev/null || true)
    values=("$phase" "$machine_id" "$source" "$target" "$source_id" "$BOOT_LABEL" "$BOOT_EFI_PATH" "$R26_SOURCE_EFI_RESOLVED" "$R26_SOURCE_EFI_HASH" "$R26_SOURCE_MANIFEST" "$R26_TARGET_MANIFEST" "$R26_SOURCE_FALLBACK_OWNED" "$original_order" "$target_id" "$(target_expected_efi_path "$target")" "$TARGET_EFI_RESOLVED" "$TARGET_EFI_HASH" "$ESP_UUID" "$ROOT_UUID" "$ESP_SOURCE" "$ESP_MOUNT" "${OPERATION_BACKUP:-}" "$source_cmdline")
    for v in "${values[@]}"; do pending_safe_value "$v" || { fail 'Refusing unsafe control characters in r26 transaction state'; return 1; }; done
    mkdir -p -- "$PENDING_STATE_DIR" || return 1
    chmod 700 -- "$PENDING_STATE_DIR" 2>/dev/null || true
    tmp=$(mktemp "$PENDING_STATE_DIR/.pending.XXXXXX") || return 1
    chmod 600 "$tmp" 2>/dev/null || true
    {
        printf 'format\t%s\n' "$R26_PENDING_FORMAT"
        printf 'adapter_revision\t%s\n' "$R26_ADAPTER_REVISION"
        printf 'phase\t%s\n' "$phase"
        printf 'created\t%s\n' "$created"
        printf 'machine_id\t%s\n' "$machine_id"
        printf 'source\t%s\n' "$source"
        printf 'target\t%s\n' "$target"
        printf 'old_boot_id\t%s\n' "${source_id^^}"
        printf 'old_boot_label\t%s\n' "$BOOT_LABEL"
        printf 'old_boot_efi_path\t%s\n' "$BOOT_EFI_PATH"
        printf 'source_efi_resolved\t%s\n' "$R26_SOURCE_EFI_RESOLVED"
        printf 'source_efi_hash\t%s\n' "$R26_SOURCE_EFI_HASH"
        printf 'source_manifest\t%s\n' "$R26_SOURCE_MANIFEST"
        printf 'source_fallback_owned\t%s\n' "$R26_SOURCE_FALLBACK_OWNED"
        printf 'old_fallback_path\t%s\n' "${OLD_FALLBACK_PATH:-}"
        printf 'old_fallback_hash\t%s\n' "${OLD_FALLBACK_HASH:-}"
        printf 'old_fallback_existed\t%s\n' "${OLD_FALLBACK_EXISTED:-0}"
        printf 'old_fallback_snapshot\t%s\n' "${OLD_FALLBACK_SNAPSHOT:-}"
        printf 'post_stage_fallback_hash\t%s\n' "${POST_STAGE_FALLBACK_HASH:-}"
        printf 'transaction_snapshot_dir\t%s\n' "$TRANSACTION_SNAPSHOT_DIR"
        printf 'original_boot_order\t%s\n' "$original_order"
        printf 'target_boot_id\t%s\n' "${target_id^^}"
        printf 'target_efi_path\t%s\n' "$(target_expected_efi_path "$target")"
        printf 'target_efi_resolved\t%s\n' "$TARGET_EFI_RESOLVED"
        printf 'target_efi_hash\t%s\n' "$TARGET_EFI_HASH"
        printf 'target_manifest\t%s\n' "$R26_TARGET_MANIFEST"
        printf 'esp_uuid\t%s\n' "$ESP_UUID"
        printf 'root_uuid\t%s\n' "$ROOT_UUID"
        printf 'esp_source\t%s\n' "$ESP_SOURCE"
        printf 'esp_mount\t%s\n' "$ESP_MOUNT"
        printf 'backup_path\t%s\n' "${OPERATION_BACKUP:-}"
        printf 'diagnostic_path\t\n'
        printf 'source_cmdline\t%s\n' "$source_cmdline"
    } >"$tmp" || { rm -f "$tmp"; return 1; }
    mv -f -- "$tmp" "$PENDING_STATE_FILE"
}

r26_target_namespace_clean() {
    local target=$1 path
    if find_nvram_entry_for_target "$target"; then
        fail "Target $(bootloader_display_name "$target") NVRAM entry Boot$TARGET_NVRAM_ID already exists; ownership is ambiguous."
        return 1
    fi
    case "$target" in
        grub)
            for path in "$ESP_MOUNT/EFI/CACHYOS" /boot/grub /etc/default/grub; do
                if sudo -n test -e "$path" 2>/dev/null || [[ -e $path ]]; then fail "Target GRUB namespace already exists: $path"; return 1; fi
            done
            ;;
        systemd-boot)
            [[ $ESP_MOUNT == /boot ]] || {
                fail "${SWITCHER_RELEASE:-r26} systemd-boot adapter currently supports the CachyOS /boot ESP topology only; detected $ESP_MOUNT."
                fail 'The switcher will not rewrite fstab or move kernel artifacts to force compatibility.'
                return 1
            }
            # loader/entries itself is a shared BLS namespace. Its existence is
            # fine; only paths the CachyOS adapter would own are conflicts.
            for path in "$ESP_MOUNT/EFI/systemd" "$ESP_MOUNT/loader/loader.conf" /etc/sdboot-manage.conf.d/90-cachyos-bootloader-switcher.conf; do
                if sudo -n test -e "$path" 2>/dev/null || [[ -e $path ]]; then fail "Target systemd-boot namespace already exists: $path"; return 1; fi
            done
            while IFS= read -r path; do
                [[ -n $path ]] || continue
                if sudo -n test -e "$path" 2>/dev/null || [[ -e $path ]]; then
                    fail "Target systemd-boot CachyOS entry already exists: $path"
                    return 1
                fi
            done < <(r26_systemd_entry_paths)
            ;;
        refind)
            for path in "$ESP_MOUNT/EFI/refind" /boot/refind_linux.conf; do
                if sudo -n test -e "$path" 2>/dev/null || [[ -e $path ]]; then fail "Target rEFInd namespace already exists: $path"; return 1; fi
            done
            ;;
    esac
    return 0
}

r26_generic_preflight() {
    local target=$1
    printf '\n%s adapter preflight:\n' "${SWITCHER_RELEASE:-r26}"
    run_validation preflight || { fail 'Base preflight failed; no boot state was modified'; return 1; }
    is_cachyos || { fail "${SWITCHER_RELEASE:-r26} live adapters are restricted to CachyOS/Arch-like systems"; return 1; }
    if bootcurrent_is_generic_fallback; then
        fail 'The current session was booted through the generic UEFI fallback path.'
        fail 'Adapter transactions require the canonical source NVRAM entry; reboot normally and let firmware follow BootOrder.'
        return 1
    fi
    have sudo && have pacman || { fail 'sudo and pacman are required'; return 1; }
    pending_exists && { fail 'A bootloader transaction is already pending'; return 1; }
    [[ -z ${BOOT_NEXT:-} ]] || { fail "BootNext is already set to Boot${BOOT_NEXT^^}; refusing to overwrite firmware intent"; return 1; }
    case "$BOOTLOADER:$target" in
        grub:systemd-boot|systemd-boot:grub|grub:refind|refind:grub) ;;
        *) fail "This direction is not routed through the ${SWITCHER_RELEASE:-r26} adapter engine"; return 1 ;;
    esac
    printf '\nSource adapter deep gate (%s):\n' "$(bootloader_display_name "$BOOTLOADER")"
    adapter_source_validate "$BOOTLOADER" || { fail 'The active source adapter failed deep validation; target staging is refused'; return 1; }
    r26_target_namespace_clean "$target" || return 1
    return 0
}

r26_remove_uncommitted_target_namespaces() {
    local target=$1 path id
    # This helper is called only after r26_target_namespace_clean proved these
    # target namespaces absent before staging. Anything now present at these
    # exact paths was created by this uncommitted staging attempt.
    while IFS= read -r id; do
        [[ -n $id ]] || continue
        sudo efibootmgr -b "$id" -B >/dev/null 2>&1 || return 1
        ok "Removed uncommitted $(bootloader_display_name "$target") NVRAM entry Boot$id"
    done < <(r21_nvram_ids_for_esp_path "$(target_expected_efi_path "$target")")

    case "$target" in
        grub)
            for path in /etc/default/grub /boot/grub "$ESP_MOUNT/EFI/CACHYOS"; do
                if sudo -n test -e "$path" 2>/dev/null || sudo -n test -L "$path" 2>/dev/null || [[ -e $path || -L $path ]]; then
                    sudo rm -rf -- "$path" || return 1
                    ok "Removed uncommitted GRUB target namespace: $path"
                fi
            done
            ;;
        systemd-boot)
            # Remove only deterministic CachyOS entries created by this staging
            # attempt. Foreign BLS entries in loader/entries are never claimed.
            while IFS= read -r path; do
                [[ -n $path ]] || continue
                if sudo -n test -e "$path" 2>/dev/null || sudo -n test -L "$path" 2>/dev/null || [[ -e $path || -L $path ]]; then
                    sudo rm -f -- "$path" || return 1
                    ok "Removed uncommitted systemd-boot CachyOS entry: $path"
                fi
            done < <(r26_systemd_entry_paths)
            for path in /etc/sdboot-manage.conf.d/90-cachyos-bootloader-switcher.conf "$ESP_MOUNT/loader/loader.conf" "$ESP_MOUNT/EFI/systemd"; do
                if sudo -n test -e "$path" 2>/dev/null || sudo -n test -L "$path" 2>/dev/null || [[ -e $path || -L $path ]]; then
                    sudo rm -rf -- "$path" || return 1
                    ok "Removed uncommitted systemd-boot target namespace: $path"
                fi
            done
            sudo rmdir -- "$ESP_MOUNT/loader/entries" 2>/dev/null || true
            sudo rmdir -- "$ESP_MOUNT/loader" 2>/dev/null || true
            ;;
        refind)
            for path in /boot/refind_linux.conf "$ESP_MOUNT/EFI/refind"; do
                if sudo -n test -e "$path" 2>/dev/null || sudo -n test -L "$path" 2>/dev/null || [[ -e $path || -L $path ]]; then
                    sudo rm -rf -- "$path" || return 1
                    ok "Removed uncommitted rEFInd target namespace: $path"
                fi
            done
            ;;
    esac
}

r26_cleanup_uncommitted_target() {
    local target=$1 original_order=$2 source_id=$3 source=$4 rc=0
    warn "Rolling back the uncommitted $(bootloader_display_name "$target") staging attempt."
    # Clear a transaction-owned BootNext if an installer unexpectedly set one.
    local next
    next=$(pending_bootnext_id 2>/dev/null || true)
    if [[ -n $next ]]; then
        local target_id=""
        find_nvram_entry_for_target "$target" >/dev/null 2>&1 && target_id=${TARGET_NVRAM_ID^^}
        if [[ -n $target_id && ${next^^} == "$target_id" ]]; then
            sudo efibootmgr -N >/dev/null 2>&1 || rc=1
        fi
    fi
    r26_remove_uncommitted_target_namespaces "$target" || rc=1
    r26_restore_source_fallback_after_target_stage || rc=1
    [[ -n $original_order ]] && sudo efibootmgr -o "$original_order" >/dev/null 2>&1 || rc=1
    if [[ -n $source_id && $(pending_bootorder_first 2>/dev/null || true) != "${source_id^^}" ]]; then
        fail 'Could not prove source-first BootOrder after uncommitted target rollback.'
        rc=1
    fi
    detect_bootloader
    if [[ $BOOTLOADER != "$source" || $BOOT_CURRENT != "${source_id^^}" ]]; then
        fail 'Could not re-identify the original source BootCurrent after uncommitted rollback.'
        rc=1
    fi
    if [[ -n ${R26_SOURCE_EFI_HASH:-} && -n ${R26_SOURCE_EFI_RESOLVED:-} ]]; then
        local source_hash
        source_hash=$(sudo -n sha256sum -- "$R26_SOURCE_EFI_RESOLVED" 2>/dev/null | awk '{print $1}' || true)
        [[ $source_hash == "$R26_SOURCE_EFI_HASH" ]] || { fail 'Source EFI bytes changed during failed target staging/rollback.'; rc=1; }
    fi
    if [[ -n ${R26_SOURCE_MANIFEST:-} && -s ${R26_SOURCE_MANIFEST:-/nonexistent} ]]; then
        r26_verify_owned_manifest "$R26_SOURCE_MANIFEST" || rc=1
    fi
    adapter_source_validate "$source" || rc=1
    [[ -n ${TRANSACTION_SNAPSHOT_DIR:-} ]] && rm -rf -- "$TRANSACTION_SNAPSHOT_DIR" 2>/dev/null || true
    if ((rc == 0)); then
        ok 'Uncommitted target staging was rolled back; the source remains authoritative.'
    else
        fail 'Best-effort rollback could not prove every source recovery invariant. Do not reboot until firmware state is inspected.'
    fi
    return "$rc"
}

r26_execute_adapter_switch() {
    local target=$1 source=$BOOTLOADER source_id=${BOOT_CURRENT^^} original_order=$BOOT_ORDER reference target_id
    [[ -n $source_id && -n $original_order ]] || { fail 'Could not capture source NVRAM identity/BootOrder'; return 1; }
    reference=$(cat /proc/cmdline 2>/dev/null || true)
    [[ -n $reference ]] || { fail 'Could not capture known-good source cmdline'; return 1; }

    R26_STAGED_TARGET_ID=""
    adapter_source_snapshot "$source" || return 1
    if ! adapter_target_stage "$target" "$source_id" "$original_order" "$reference"; then
        fail 'Target staging failed before a candidate transaction was committed.'
        r26_cleanup_uncommitted_target "$target" "$original_order" "$source_id" "$source" || true
        return 1
    fi
    target_id=${R26_STAGED_TARGET_ID^^}
    if [[ ! $target_id =~ ^[0-9A-F]{4}$ ]]; then
        fail 'Target adapter did not publish a valid NVRAM identifier.'
        r26_cleanup_uncommitted_target "$target" "$original_order" "$source_id" "$source" || true
        return 1
    fi

    # Re-establish source proof after all target installers have touched EFI.
    if ! adapter_source_validate "$source"; then
        fail 'Source adapter validation failed after target staging; candidate will not be committed.'
        r26_cleanup_uncommitted_target "$target" "$original_order" "$source_id" "$source" || true
        return 1
    fi
    if [[ $(pending_bootorder_first) != "$source_id" ]]; then
        fail 'Source is no longer first after target staging; candidate will not be committed.'
        r26_cleanup_uncommitted_target "$target" "$original_order" "$source_id" "$source" || true
        return 1
    fi
    if ! r26_write_pending_adapter "$source" "$target" "$source_id" "$original_order" "$target_id" candidate-ready; then
        fail 'Could not persist the adapter transaction; rolling back the uncommitted candidate.'
        r26_cleanup_uncommitted_target "$target" "$original_order" "$source_id" "$source" || true
        return 1
    fi
    load_pending_state || return 1
    verify_pending_source_recovery_unchanged || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1

    printf '\nCANDIDATE-READY %s -> %s adapter transaction staged successfully.\n' "$(bootloader_display_name "$source")" "$(bootloader_display_name "$target")"
    printf 'The source remains first in persistent BootOrder until the target earns runtime proof.\n'
    r23_arm_candidate_automatically || return 1
    if ! r22_prepare_resume_bundle; then
        fail 'Could not prepare automatic post-reboot continuation. Clearing transaction BootNext for safety.'
        r22_rollback_automation_arm
        return 1
    fi
    r23_prompt_reboot
}

verify_pending_candidate_ownership_unchanged() {
    if [[ ${PENDING_FORMAT:-} != "$R26_PENDING_FORMAT" ]]; then
        verify_pending_candidate_ownership_unchanged_pre_r26 "$@"
        return $?
    fi
    nvram_id_matches_path "$PENDING_TARGET_BOOT_ID" "$PENDING_TARGET_EFI_PATH" || { fail 'Target NVRAM path changed since candidate creation'; return 1; }
    local hash
    hash=$(sudo -n sha256sum -- "$PENDING_TARGET_EFI_RESOLVED" 2>/dev/null | awk '{print $1}' || true)
    [[ -n $hash && $hash == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'Target EFI executable changed since candidate creation'; return 1; }
    r26_verify_owned_manifest "$PENDING_TARGET_MANIFEST" || return 1
    ok "$(bootloader_display_name "$PENDING_TARGET") target adapter ownership still matches the transaction manifest"
}

verify_pending_source_recovery_unchanged() {
    if [[ ${PENDING_FORMAT:-} != "$R26_PENDING_FORMAT" ]]; then
        verify_pending_source_recovery_unchanged_pre_r26 "$@"
        return $?
    fi
    nvram_id_matches_path "$PENDING_OLD_BOOT_ID" "$PENDING_OLD_BOOT_EFI_PATH" || { fail 'Source NVRAM entry/path changed'; return 1; }
    local hash
    hash=$(sudo -n sha256sum -- "$PENDING_SOURCE_EFI_RESOLVED" 2>/dev/null | awk '{print $1}' || true)
    [[ -n $hash && $hash == "$PENDING_SOURCE_EFI_HASH" ]] || { fail 'Source EFI executable changed'; return 1; }
    r26_verify_owned_manifest "$PENDING_SOURCE_MANIFEST" || return 1
    if [[ $PENDING_OLD_FALLBACK_EXISTED == 1 ]]; then
        hash=$(sudo -n sha256sum -- "$PENDING_OLD_FALLBACK_PATH" 2>/dev/null | awk '{print $1}' || true)
        [[ $hash == "$PENDING_OLD_FALLBACK_HASH" ]] || { fail 'Source generic fallback changed while source is authoritative'; return 1; }
    else
        if sudo -n test -f "$PENDING_OLD_FALLBACK_PATH" 2>/dev/null; then fail 'A generic fallback appeared after source snapshot and is not transaction-owned'; return 1; fi
    fi
    adapter_source_validate "$PENDING_SOURCE" || return 1
    ok "Recorded $(bootloader_display_name "$PENDING_SOURCE") source adapter recovery state is unchanged"
}

validate_pending_target_deep() {
    if [[ ${PENDING_FORMAT:-} != "$R26_PENDING_FORMAT" ]]; then
        validate_pending_target_deep_pre_r26 "$@"
        return $?
    fi
    validate_target_state "$PENDING_TARGET" || return 1
    adapter_target_validate "$PENDING_TARGET"
}

r23_arm_candidate_automatically() {
    validate_pending_compatibility || { fail "Pending migration is not compatible: $PENDING_REASON"; return 1; }
    if [[ $PENDING_FORMAT != "$R26_PENDING_FORMAT" ]]; then
        r23_arm_candidate_automatically_pre_r26 "$@"
        return $?
    fi
    [[ $PENDING_PHASE == candidate-ready ]] || { fail 'Automatic arming requires candidate-ready'; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == "$PENDING_SOURCE" && $BOOT_CURRENT == "$PENDING_OLD_BOOT_ID" ]] || { fail 'Automatic arming requires the recorded source session'; return 1; }
    run_validation preflight || return 1
    verify_pending_source_recovery_unchanged || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext is already owned by another request'; return 1; }
    [[ $(pending_bootorder_first) == "$PENDING_OLD_BOOT_ID" ]] || { fail 'Persistent BootOrder is no longer source-first'; return 1; }
    sudo efibootmgr -n "$PENDING_TARGET_BOOT_ID" >/dev/null || return 1
    [[ $(pending_bootnext_id) == "$PENDING_TARGET_BOOT_ID" ]] || { sudo efibootmgr -N >/dev/null 2>&1 || true; fail 'BootNext verification failed'; return 1; }
    pending_set_phase boot-armed || { sudo efibootmgr -N >/dev/null 2>&1 || true; fail 'Could not persist boot-armed phase'; return 1; }
    PENDING_PHASE=boot-armed
    ok "Armed one-time $(bootloader_display_name "$PENDING_TARGET") test as BootNext=Boot$PENDING_TARGET_BOOT_ID"
    ok "Persistent BootOrder remains source $(bootloader_display_name "$PENDING_SOURCE") Boot$PENDING_OLD_BOOT_ID first until runtime proof"
}

r26_restore_fallback_on_rollback() {
    if [[ $PENDING_OLD_FALLBACK_EXISTED == 1 ]]; then
        [[ -f $PENDING_OLD_FALLBACK_SNAPSHOT ]] || { fail 'Fallback rollback snapshot is missing'; return 1; }
        [[ $(sha256sum "$PENDING_OLD_FALLBACK_SNAPSHOT" | awk '{print $1}') == "$PENDING_OLD_FALLBACK_HASH" ]] || return 1
        sudo mkdir -p -- "$(dirname -- "$PENDING_OLD_FALLBACK_PATH")" || return 1
        sudo install -m 0644 -- "$PENDING_OLD_FALLBACK_SNAPSHOT" "$PENDING_OLD_FALLBACK_PATH" || return 1
    else
        sudo rm -f -- "$PENDING_OLD_FALLBACK_PATH" 2>/dev/null || true
    fi
}

rollback_pending_candidate() {
    if [[ ${PENDING_FORMAT:-} != "$R26_PENDING_FORMAT" ]]; then
        rollback_pending_candidate_pre_r26 "$@"
        return $?
    fi
    validate_pending_compatibility || return 1
    detect_bootloader
    [[ $BOOTLOADER == "$PENDING_SOURCE" && $BOOT_CURRENT == "$PENDING_OLD_BOOT_ID" ]] || { fail 'r26 rollback is allowed only from the recorded source session'; return 1; }
    verify_pending_source_recovery_unchanged || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    local next
    next=$(pending_bootnext_id)
    [[ -z $next || $next == "$PENDING_TARGET_BOOT_ID" ]] || { fail "Unrelated BootNext=Boot$next exists; refusing rollback"; return 1; }
    [[ $next != "$PENDING_TARGET_BOOT_ID" ]] || sudo efibootmgr -N >/dev/null || return 1
    r22_disarm_user_resume_bundle || true
    if boot_id_exists "$PENDING_TARGET_BOOT_ID"; then sudo efibootmgr -b "$PENDING_TARGET_BOOT_ID" -B >/dev/null || return 1; fi
    r26_remove_owned_manifest_paths "$PENDING_TARGET_MANIFEST" || return 1
    r26_restore_fallback_on_rollback || return 1
    sudo efibootmgr -o "$PENDING_ORIGINAL_BOOT_ORDER" >/dev/null || return 1
    remove_pending_transaction_snapshot || true
    rm -f -- "$PENDING_STATE_FILE"
    ok "Rolled back the ${SWITCHER_RELEASE:-r26} adapter candidate; source state remains authoritative"
}

r26_remove_fallback_aliases() {
    local id
    while IFS= read -r id; do
        [[ -n $id && $id != "$PENDING_TARGET_BOOT_ID" && $id != "$PENDING_OLD_BOOT_ID" ]] || continue
        sudo efibootmgr -b "$id" -B >/dev/null 2>&1 || return 1
        ok "Removed source-owned generic fallback firmware alias Boot$id"
    done < <(r21_nvram_ids_for_esp_path '\EFI\BOOT\BOOTX64.EFI')
}

r26_retire_source_adapter() {
    validate_pending_compatibility || return 1
    [[ $PENDING_FORMAT == "$R26_PENDING_FORMAT" ]] || return 1
    verify_pending_source_recovery_unchanged || return 1
    if boot_id_exists "$PENDING_OLD_BOOT_ID"; then
        nvram_id_matches_path "$PENDING_OLD_BOOT_ID" "$PENDING_OLD_BOOT_EFI_PATH" || { fail 'Source NVRAM path changed before retirement'; return 1; }
        sudo efibootmgr -b "$PENDING_OLD_BOOT_ID" -B >/dev/null || return 1
        ok "Removed source $(bootloader_display_name "$PENDING_SOURCE") NVRAM entry Boot$PENDING_OLD_BOOT_ID"
    fi
    r26_remove_owned_manifest_paths "$PENDING_SOURCE_MANIFEST" || return 1
    if [[ $PENDING_SOURCE == systemd-boot ]]; then
        # The entries directory is shared and deliberately never owned as a
        # tree. Remove only now-empty directories; foreign entries keep them.
        sudo rmdir -- "$PENDING_ESP_MOUNT/loader/entries" 2>/dev/null || true
        sudo rmdir -- "$PENDING_ESP_MOUNT/loader" 2>/dev/null || true
    fi
    if [[ $PENDING_SOURCE_FALLBACK_OWNED == 1 && $PENDING_OLD_FALLBACK_EXISTED == 1 ]]; then
        local hash
        hash=$(sudo -n sha256sum -- "$PENDING_OLD_FALLBACK_PATH" 2>/dev/null | awk '{print $1}' || true)
        [[ $hash == "$PENDING_OLD_FALLBACK_HASH" ]] || { fail 'Source-owned fallback changed before retirement'; return 1; }
        sudo rm -f -- "$PENDING_OLD_FALLBACK_PATH" || return 1
        ok 'Removed ownership-proven source generic EFI fallback payload'
        r26_remove_fallback_aliases || return 1
    fi
}

r26_finalize_target_fallback() {
    # systemd-boot conventionally provides EFI/BOOT/BOOTX64.EFI, but that path
    # is globally shared. Never overwrite a pre-existing fallback that was not
    # proven to belong to the retiring source bootloader.
    [[ $PENDING_TARGET == systemd-boot ]] || return 0
    local fallback="$PENDING_ESP_MOUNT/EFI/BOOT/BOOTX64.EFI" hash

    if [[ $PENDING_OLD_FALLBACK_EXISTED == 1 && $PENDING_SOURCE_FALLBACK_OWNED != 1 ]]; then
        hash=$(sudo -n sha256sum -- "$fallback" 2>/dev/null | awk '{print $1}' || true)
        [[ $hash == "$PENDING_OLD_FALLBACK_HASH" ]] || {
            fail 'Unrelated pre-existing generic EFI fallback changed before systemd-boot finalization'
            return 1
        }
        info 'Preserving unrelated pre-existing EFI/BOOT/BOOTX64.EFI; systemd-boot will use its canonical NVRAM entry.'
        return 0
    fi

    sudo mkdir -p -- "$(dirname -- "$fallback")" || return 1
    sudo cp -- "$PENDING_TARGET_EFI_RESOLVED" "$fallback" || return 1
    hash=$(sudo -n sha256sum -- "$fallback" 2>/dev/null | awk '{print $1}' || true)
    [[ $hash == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'Could not materialize byte-identical systemd-boot generic fallback'; return 1; }
    ok 'Installed byte-identical systemd-boot generic EFI fallback after runtime proof'
}

r26_finalize_adapter_transaction() {
    validate_pending_compatibility || { fail "Pending migration is not compatible: $PENDING_REASON"; return 1; }
    [[ $PENDING_FORMAT == "$R26_PENDING_FORMAT" && $PENDING_PHASE == runtime-validated ]] || { fail "${SWITCHER_RELEASE:-r26} FINALIZE requires runtime-validated adapter state"; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == "$PENDING_TARGET" && $BOOT_CURRENT == "$PENDING_TARGET_BOOT_ID" ]] || { fail 'FINALIZE must run from the recorded target session'; return 1; }
    run_validation preflight || return 1
    pending_validate_running_kernel || return 1
    pending_validate_runtime_cmdline_against_source || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    adapter_target_runtime_validate "$PENDING_TARGET" || return 1
    verify_pending_source_recovery_unchanged || return 1
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext must be clear before adapter finalization'; return 1; }

    printf '\nFINALIZE adapter transaction %s -> %s:\n' "$(bootloader_display_name "$PENDING_SOURCE")" "$(bootloader_display_name "$PENDING_TARGET")"
    printf '  - promote the runtime-proven target first in persistent BootOrder\n'
    printf '  - retire only exact ownership-proven source NVRAM/config/EFI state\n'
    printf '  - validate the target again after cleanup\n'

    adapter_target_promote "$PENDING_TARGET_BOOT_ID" "$PENDING_OLD_BOOT_ID" || { fail 'Could not promote target first in persistent BootOrder'; return 1; }
    ok "Persistent BootOrder now starts with target Boot$PENDING_TARGET_BOOT_ID"
    verify_pending_candidate_ownership_unchanged || { fail 'Target changed after promotion; source cleanup was NOT attempted'; return 1; }
    adapter_target_validate "$PENDING_TARGET" || { fail 'Target deep validation failed after promotion; source cleanup was NOT attempted'; return 1; }
    adapter_source_retire || return 1
    r26_finalize_target_fallback || return 1

    detect_bootloader
    [[ $BOOTLOADER == "$PENDING_TARGET" && $BOOT_CURRENT == "$PENDING_TARGET_BOOT_ID" ]] || { fail 'Target identity changed during finalization'; return 1; }
    [[ $(pending_bootorder_first) == "$PENDING_TARGET_BOOT_ID" ]] || { fail 'Target is not first in persistent BootOrder after source retirement'; return 1; }
    boot_id_exists "$PENDING_OLD_BOOT_ID" && { fail 'Source NVRAM entry still exists after retirement'; return 1; }
    validate_target_state "$PENDING_TARGET" || return 1
    adapter_target_final_validate "$PENDING_TARGET" || return 1

    local diag
    diag=$(pending_capture_runtime_diagnostics "finalized-$PENDING_TARGET" | tail -n1 || true)
    [[ -n $diag ]] && printf 'Finalization diagnostic snapshot: %s\n' "$diag"
    remove_pending_transaction_snapshot || true
    rm -f -- "$PENDING_STATE_FILE"
    printf '\nFINALIZED %s -> %s successfully through the %s adapter engine.\n' "$(bootloader_display_name "$PENDING_SOURCE")" "$(bootloader_display_name "$PENDING_TARGET")" "${SWITCHER_RELEASE:-r26}"
    printf '%s Boot%s is first in persistent BootOrder; source cleanup was ownership-gated.\n' "$(bootloader_display_name "$PENDING_TARGET")" "$PENDING_TARGET_BOOT_ID"
}

r22_resume_transaction_root() {
    r22_root_bundle_preflight || return 1
    if [[ $(r26_state_format) != "$R26_PENDING_FORMAT" ]]; then
        r22_resume_transaction_root_pre_r26 "$@"
        return $?
    fi
    local bundle conf detail
    bundle=$R22_RESUME_BUNDLE
    conf="$bundle/resume.conf"
    printf 'CachyOS Bootloader Switcher %s automatic adapter transaction resume\n' "${SWITCHER_RELEASE:-r26}"
    printf 'Bundle: %s\n' "$bundle"
    load_pending_state || { r22_write_user_result "$conf" failed "Invalid root-owned ${SWITCHER_RELEASE:-r26} adapter state: $PENDING_REASON" || true; r22_remove_resume_service_files; return 1; }
    validate_pending_compatibility || { r22_write_user_result "$conf" failed "Incompatible root-owned ${SWITCHER_RELEASE:-r26} adapter state: $PENDING_REASON" || true; r22_remove_resume_service_files; return 1; }
    detect_bootloader
    if [[ $BOOTLOADER == "$PENDING_SOURCE" && $BOOT_CURRENT == "$PENDING_OLD_BOOT_ID" ]]; then
        r22_resume_source_fallback "$conf"
        return $?
    fi
    if [[ $BOOTLOADER != "$PENDING_TARGET" || $BOOT_CURRENT != "$PENDING_TARGET_BOOT_ID" ]]; then
        r22_write_user_result "$conf" failed 'Automatic adapter resume saw an unexpected BootCurrent/bootloader identity; no source cleanup was attempted.' || true
        r22_remove_resume_service_files
        return 1
    fi
    case "$PENDING_PHASE" in
        boot-armed)
            validate_pending_target_runtime || { r22_write_user_result "$conf" failed "The automatically booted $PENDING_TARGET target failed runtime validation; source cleanup was not attempted." || true; r22_remove_resume_service_files; return 1; }
            PENDING_PHASE=runtime-validated
            r22_sync_user_phase_from_root "$conf" runtime-validated || true
            ;;
        runtime-validated) printf 'Automatic resume: runtime proof already persisted; continuing adapter finalization.\n' ;;
        *) r22_write_user_result "$conf" failed "Unexpected ${SWITCHER_RELEASE:-r26} resume phase: $PENDING_PHASE" || true; r22_remove_resume_service_files; return 1 ;;
    esac
    r26_finalize_adapter_transaction || { r22_write_user_result "$conf" failed "Runtime proof passed but ${SWITCHER_RELEASE:-r26} ownership-gated $PENDING_SOURCE -> $PENDING_TARGET finalization failed." || true; r22_remove_resume_service_files; return 1; }
    detail="$(bootloader_display_name "$PENDING_SOURCE") -> $(bootloader_display_name "$PENDING_TARGET") finalized automatically through the ${SWITCHER_RELEASE:-r26} adapter engine. Target Boot$PENDING_TARGET_BOOT_ID is first in persistent BootOrder."
    r22_cleanup_user_shadow_after_success "$conf"
    r22_write_user_result "$conf" success "$detail" || true
    r22_remove_resume_service_files
    rm -rf -- "$bundle" 2>/dev/null || true
    return 0
}

operation_supported() {
    local current=$1 target=$2
    operation_supported_pre_r26 "$current" "$target" && return 0
    case "$current:$target" in
        grub:systemd-boot|systemd-boot:grub|grub:refind|refind:grub) return 0 ;;
        *) return 1 ;;
    esac
}

show_operation_plan() {
    local current=$1 target=$2
    case "$current:$target" in
        grub:systemd-boot|systemd-boot:grub|grub:refind|refind:grub)
            printf '\n%s adapter transaction plan:\n' "${SWITCHER_RELEASE:-r26}"
            printf '  SOURCE adapter (%s): validate -> snapshot -> preserve recovery -> retire only after target proof.\n' "$(bootloader_display_name "$current")"
            printf '  TARGET adapter (%s): stage -> validate -> arm -> runtime_validate -> promote -> final_validate.\n' "$(bootloader_display_name "$target")"
            printf '  1. Deep-validate the current source boot chain and record exact ownership manifests.\n'
            printf '  2. Stage the target without changing /etc/fstab and restore the source as first persistent BootOrder item.\n'
            case "$target" in
                systemd-boot) printf '  3. Install systemd-boot-manager, bootctl systemd-boot, CachyOS sdboot-manage entries, and deterministic regular-kernel-first loader.conf.\n' ;;
                refind) printf '  3. Install rEFInd, preserve the known-good cmdline in /boot/refind_linux.conf, and apply the CachyOS kernel-version scan list.\n' ;;
                grub) printf '  3. Install CachyOS GRUB + theme, generate grub.cfg from current source-shared kernels/initramfs, and preserve regular-before-LTS order.\n' ;;
            esac
            printf '  4. Deep-validate target + source again, then arm target BootNext exactly once.\n'
            printf '  5. Install the temporary root-owned one-shot resume service and prompt before reboot.\n'
            printf '  6. After target reaches userspace, automatically prove BootCurrent/kernel/root/cmdline/ownership.\n'
            printf '  7. Only after proof: promote target, retire ownership-proven source state, then deep-validate target again.\n'
            printf '  If target proof fails, no source cleanup is authorized.\n'
            ;;
        *) show_operation_plan_pre_r26 "$@" ;;
    esac
}

run_live_operation() {
    local target=$1 current=$BOOTLOADER
    if ! operation_supported "$current" "$target"; then
        printf '\nThe %s -> %s live backend is not enabled in %s.\n' "$(bootloader_display_name "$current")" "$(bootloader_display_name "$target")" "${SWITCHER_RELEASE:-r26}"
        printf '%s enables the currently certified live adapter matrix; unsupported direct non-GRUB edges remain closed until explicitly enabled and hardware-tested.\n' "${SWITCHER_RELEASE:-r26}"
        printf 'Other direct non-GRUB adapter paths remain disabled until each path is explicitly enabled and hardware-tested.\n'
        return 2
    fi
    case "$current:$target" in
        grub:systemd-boot|systemd-boot:grub|grub:refind|refind:grub)
            r26_generic_preflight "$target" || return 1
            offer_operation_backup || return 1
            show_operation_plan "$current" "$target"
            confirm_operation "$current" "$target" || { printf '\nOperation cancelled. No boot state was modified.\n'; return 0; }
            printf '\nExecuting %s adapter transaction...\n' "${SWITCHER_RELEASE:-r26}"
            r26_execute_adapter_switch "$target"
            ;;
        *) run_live_operation_pre_r26 "$@" ;;
    esac
}

r26_resume_service_state() {
    local state
    state=$(systemctl show -p ActiveState --value cachyos-bootloader-switcher-resume.service 2>/dev/null || true)
    printf '%s\n' "${state:-not-found}"
}

r26_rearm_candidate_with_resume() {
    validate_pending_compatibility || return 1
    [[ $PENDING_FORMAT == "$R26_PENDING_FORMAT" && $PENDING_PHASE == candidate-ready ]] || { fail "Adapter re-arm requires candidate-ready ${SWITCHER_RELEASE:-r26} state"; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == "$PENDING_SOURCE" && $BOOT_CURRENT == "$PENDING_OLD_BOOT_ID" ]] || { fail 'Adapter re-arm requires the recorded source session'; return 1; }
    run_validation preflight || return 1
    verify_pending_source_recovery_unchanged || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1
    r23_arm_candidate_automatically || return 1
    if ! r22_prepare_resume_bundle; then
        fail 'Could not prepare automatic post-reboot continuation. Clearing the newly armed BootNext.'
        r22_rollback_automation_arm
        return 1
    fi
    r23_prompt_reboot
}

r26_rearm_runtime_validated_target() {
    validate_pending_compatibility || return 1
    [[ $PENDING_FORMAT == "$R26_PENDING_FORMAT" && $PENDING_PHASE == runtime-validated ]] || { fail "Validated-target return requires runtime-validated ${SWITCHER_RELEASE:-r26} state"; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == "$PENDING_SOURCE" && $BOOT_CURRENT == "$PENDING_OLD_BOOT_ID" ]] || { fail 'Validated-target return requires the recorded source session'; return 1; }
    run_validation preflight || return 1
    verify_pending_source_recovery_unchanged || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext is already owned by another request'; return 1; }
    [[ $(pending_bootorder_first) == "$PENDING_OLD_BOOT_ID" ]] || { fail 'Persistent BootOrder is no longer source-first'; return 1; }
    sudo efibootmgr -n "$PENDING_TARGET_BOOT_ID" >/dev/null || return 1
    if [[ $(pending_bootnext_id) != "$PENDING_TARGET_BOOT_ID" ]]; then
        sudo efibootmgr -N >/dev/null 2>&1 || true
        fail 'BootNext verification failed while returning to the runtime-proven target'
        return 1
    fi
    if ! r22_prepare_resume_bundle; then
        fail 'Could not prepare automatic finalization continuation. Clearing only the newly armed BootNext; runtime proof is preserved.'
        sudo efibootmgr -N >/dev/null 2>&1 || true
        return 1
    fi
    ok "Armed one-time return to runtime-validated $(bootloader_display_name "$PENDING_TARGET") Boot$PENDING_TARGET_BOOT_ID"
    printf 'The target already has runtime proof. Every ownership/runtime gate will be rechecked before automatic finalization.\n'
    r23_prompt_reboot
}

manage_pending_migration() {
    if [[ $(r26_state_format) != "$R26_PENDING_FORMAT" ]]; then
        manage_pending_migration_pre_r26 "$@"
        return $?
    fi

    pending_exists || { printf '\nNo pending/staged migration exists.\n'; return 0; }
    validate_pending_compatibility || { printf '\nPending %s adapter state is invalid/incompatible: %s\n' "${SWITCHER_RELEASE:-r26}" "$PENDING_REASON"; return 1; }
    detect_bootloader
    show_pending_details

    local choice next svc
    svc=$(r26_resume_service_state)

    if [[ $BOOTLOADER == "$PENDING_TARGET" && $BOOT_CURRENT == "$PENDING_TARGET_BOOT_ID" ]]; then
        case "$PENDING_PHASE" in
            boot-armed|runtime-validated)
                if [[ $svc == active || $svc == activating ]]; then
                    printf '\nAutomatic post-boot validation/finalization is still running in the background.\n'
                    printf 'Service state: %s\n' "$svc"
                    printf 'Do not reboot or start a second finalizer; wait for this transaction to finish.\n'
                    return 0
                fi
                ;;
        esac
        case "$PENDING_PHASE" in
            boot-armed)
                printf '\nThe target booted, but the automatic resume service is not currently running.\n'
                printf '[1] Run runtime validation now\n[2] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in 1) validate_pending_target_runtime ;; 2|'') return 0 ;; *) printf 'Invalid selection.\n'; return 1 ;; esac
                return $?
                ;;
            runtime-validated)
                printf '\nRuntime proof is recorded and the target session is active, but automatic finalization is not running.\n'
                printf '[1] Re-check every gate and FINALIZE now\n[2] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in 1) r26_finalize_adapter_transaction ;; 2|'') return 0 ;; *) printf 'Invalid selection.\n'; return 1 ;; esac
                return $?
                ;;
            candidate-ready)
                printf '\nThe target was booted manually before this transaction was armed. This session is not accepted as runtime proof.\n'
                printf 'Reboot normally to the source, then re-arm the transaction from this menu.\n'
                return 1
                ;;
        esac
    fi

    if [[ $BOOTLOADER == "$PENDING_SOURCE" && $BOOT_CURRENT == "$PENDING_OLD_BOOT_ID" ]]; then
        case "$PENDING_PHASE" in
            candidate-ready)
                printf '\nThe source is active and the validated adapter target is parked.\n'
                printf '[1] Re-run source + target validation\n'
                printf '[2] Re-arm automated one-time %s test + resume service\n' "$(bootloader_display_name "$PENDING_TARGET")"
                printf '[3] Roll back the staged target\n[4] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) run_validation preflight && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep ;;
                    2) r26_rearm_candidate_with_resume ;;
                    3) rollback_pending_candidate ;;
                    4|'') return 0 ;;
                    *) printf 'Invalid selection.\n'; return 1 ;;
                esac
                return $?
                ;;
            boot-armed)
                next=$(pending_bootnext_id)
                if [[ $next == "$PENDING_TARGET_BOOT_ID" ]]; then
                    printf '\nThe one-time target boot is armed and waiting for the next normal reboot.\n'
                    printf '[1] Re-check source/candidate integrity\n[2] Cancel BootNext and park candidate\n[3] Roll back target\n[4] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in
                        1) run_validation preflight && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged ;;
                        2) cancel_pending_one_time_boot ;;
                        3) rollback_pending_candidate ;;
                        4|'') return 0 ;;
                        *) printf 'Invalid selection.\n'; return 1 ;;
                    esac
                    return $?
                elif [[ -z $next ]]; then
                    printf '\nThe one-time request was consumed/cleared without target runtime proof.\n'
                    printf '[1] Revalidate and return to candidate-ready\n[2] Roll back target\n[3] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in 1) reset_consumed_test_to_candidate_ready ;; 2) rollback_pending_candidate ;; 3|'') return 0 ;; *) printf 'Invalid selection.\n'; return 1 ;; esac
                    return $?
                fi
                fail "BootNext belongs to unrelated Boot$next; the switcher will not touch it."
                return 1
                ;;
            runtime-validated)
                printf '\nRuntime proof is already recorded, but persistent source-first BootOrder brought the source back.\n'
                printf '[1] Re-arm proven %s target + automatic FINALIZE\n' "$(bootloader_display_name "$PENDING_TARGET")"
                printf '[2] Re-check source/candidate ownership\n[3] Roll back target\n[4] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) r26_rearm_runtime_validated_target ;;
                    2) run_validation preflight && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep ;;
                    3) rollback_pending_candidate ;;
                    4|'') return 0 ;;
                    *) printf 'Invalid selection.\n'; return 1 ;;
                esac
                return $?
                ;;
        esac
    fi

    fail 'The active boot session matches neither the recorded source nor target. No transaction writes were attempted.'
    return 1
}
