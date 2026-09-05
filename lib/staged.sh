#!/usr/bin/env bash

PENDING_STATE_DIR="${BOOTLOADER_SWITCHER_STATE_DIR:-$HOME/.local/state/cachyos-bootloader-switcher}"
PENDING_STATE_FILE="$PENDING_STATE_DIR/pending-migration.tsv"

# Common transaction fields.
PENDING_FORMAT=""
PENDING_PHASE=""
PENDING_CREATED=""
PENDING_MACHINE_ID=""
PENDING_SOURCE=""
PENDING_TARGET=""
PENDING_OLD_BOOT_ID=""
PENDING_OLD_BOOT_LABEL=""
PENDING_OLD_BOOT_EFI_PATH=""
PENDING_OLD_FALLBACK_PATH=""
PENDING_OLD_FALLBACK_HASH=""
PENDING_OLD_FALLBACK_WAS_GRUB="0"
PENDING_OLD_FALLBACK_EXISTED="0"
PENDING_OLD_FALLBACK_SNAPSHOT=""
PENDING_POST_STAGE_FALLBACK_HASH=""
PENDING_TRANSACTION_SNAPSHOT_DIR=""
PENDING_ORIGINAL_BOOT_ORDER=""
PENDING_TARGET_BOOT_ID=""
PENDING_TARGET_EFI_PATH=""
PENDING_TARGET_EFI_RESOLVED=""
PENDING_TARGET_EFI_HASH=""
PENDING_ESP_UUID=""
PENDING_ROOT_UUID=""
PENDING_ESP_SOURCE=""
PENDING_ESP_MOUNT=""
PENDING_BACKUP_PATH=""
PENDING_DIAGNOSTIC_PATH=""
PENDING_SOURCE_CMDLINE=""
PENDING_REASON=""

# format=2, GRUB -> Limine fields (kept compatible with r15 candidate state).
PENDING_OLD_GRUB_EFI_RESOLVED=""
PENDING_OLD_GRUB_HASH=""
PENDING_LIMINE_CONF_PATH=""
PENDING_LIMINE_CONF_HASH=""
PENDING_LIMINE_MANAGED_DIR=""
PENDING_LIMINE_DEFAULT_CREATED="0"
PENDING_LIMINE_DEFAULT_HASH=""

# format=4, Limine -> GRUB fields. format=3 remains readable for compatibility.
PENDING_SOURCE_LIMINE_EFI_RESOLVED=""
PENDING_SOURCE_LIMINE_EFI_HASH=""
PENDING_SOURCE_LIMINE_CONF_PATH=""
PENDING_SOURCE_LIMINE_CONF_HASH=""
PENDING_SOURCE_LIMINE_DEFAULT_HASH=""
PENDING_SOURCE_LIMINE_MANAGED_DIR=""
PENDING_SOURCE_LIMINE_MANAGED_HASH=""
PENDING_GRUB_CFG_PATH=""
PENDING_GRUB_CFG_HASH=""
PENDING_GRUB_DIR=""
PENDING_GRUB_DEFAULT_CREATED="0"
PENDING_GRUB_DEFAULT_HASH=""
PENDING_GRUB_ARTIFACT_MANIFEST=""
PENDING_GRUB_DIR_MANIFEST=""
PENDING_GRUB_EFI_DIR=""
PENDING_GRUB_EFI_DIR_MANIFEST=""

pending_exists() { [[ -f $PENDING_STATE_FILE ]]; }

pending_reset() {
    PENDING_FORMAT="" PENDING_PHASE="" PENDING_CREATED="" PENDING_MACHINE_ID=""
    PENDING_SOURCE="" PENDING_TARGET="" PENDING_OLD_BOOT_ID=""
    PENDING_OLD_BOOT_LABEL="" PENDING_OLD_BOOT_EFI_PATH=""
    PENDING_OLD_FALLBACK_PATH="" PENDING_OLD_FALLBACK_HASH=""
    PENDING_OLD_FALLBACK_WAS_GRUB="0" PENDING_OLD_FALLBACK_EXISTED="0"
    PENDING_OLD_FALLBACK_SNAPSHOT="" PENDING_POST_STAGE_FALLBACK_HASH=""
    PENDING_TRANSACTION_SNAPSHOT_DIR="" PENDING_ORIGINAL_BOOT_ORDER=""
    PENDING_TARGET_BOOT_ID="" PENDING_TARGET_EFI_PATH=""
    PENDING_TARGET_EFI_RESOLVED="" PENDING_TARGET_EFI_HASH=""
    PENDING_ESP_UUID="" PENDING_ROOT_UUID="" PENDING_ESP_SOURCE="" PENDING_ESP_MOUNT=""
    PENDING_BACKUP_PATH="" PENDING_DIAGNOSTIC_PATH="" PENDING_SOURCE_CMDLINE="" PENDING_REASON=""

    PENDING_OLD_GRUB_EFI_RESOLVED="" PENDING_OLD_GRUB_HASH=""
    PENDING_LIMINE_CONF_PATH="" PENDING_LIMINE_CONF_HASH="" PENDING_LIMINE_MANAGED_DIR=""
    PENDING_LIMINE_DEFAULT_CREATED="0" PENDING_LIMINE_DEFAULT_HASH=""

    PENDING_SOURCE_LIMINE_EFI_RESOLVED="" PENDING_SOURCE_LIMINE_EFI_HASH=""
    PENDING_SOURCE_LIMINE_CONF_PATH="" PENDING_SOURCE_LIMINE_CONF_HASH=""
    PENDING_SOURCE_LIMINE_DEFAULT_HASH="" PENDING_SOURCE_LIMINE_MANAGED_DIR=""
    PENDING_SOURCE_LIMINE_MANAGED_HASH="" PENDING_GRUB_CFG_PATH="" PENDING_GRUB_CFG_HASH=""
    PENDING_GRUB_DIR="" PENDING_GRUB_DEFAULT_CREATED="0" PENDING_GRUB_DEFAULT_HASH=""
    PENDING_GRUB_ARTIFACT_MANIFEST="" PENDING_GRUB_DIR_MANIFEST=""
    PENDING_GRUB_EFI_DIR="" PENDING_GRUB_EFI_DIR_MANIFEST=""
}

pending_safe_value() {
    local v=${1:-}
    [[ $v != *$'\n'* && $v != *$'\r'* && $v != *$'\t'* ]]
}

write_pending_grub_to_limine() {
    local old_id=$1 original_order=$2 target_id=$3 phase=${4:-candidate-ready}
    local machine_id created source_cmdline tmp values=() v
    machine_id=$(cat /etc/machine-id 2>/dev/null || true)
    created=$(date --iso-8601=seconds 2>/dev/null || date)
    source_cmdline=$(cat /proc/cmdline 2>/dev/null || true)

    values=("$phase" "$machine_id" "$old_id" "$BOOT_LABEL" "$BOOT_EFI_PATH"
            "${OLD_GRUB_EFI_RESOLVED:-}" "${OLD_GRUB_HASH:-}"
            "${OLD_FALLBACK_PATH:-}" "${OLD_FALLBACK_HASH:-}" "${OLD_FALLBACK_WAS_GRUB:-0}" "${OLD_FALLBACK_EXISTED:-0}" "${OLD_FALLBACK_SNAPSHOT:-}" "${POST_STAGE_FALLBACK_HASH:-}" "${TRANSACTION_SNAPSHOT_DIR:-}" "$original_order"
            "$target_id" "$(target_expected_efi_path limine)" "${TARGET_EFI_RESOLVED:-}" "${TARGET_EFI_HASH:-}"
            "${TARGET_LIMINE_CONF_PATH:-}" "${TARGET_LIMINE_CONF_HASH:-}" "${TARGET_LIMINE_MANAGED_DIR:-}"
            "${LIMINE_DEFAULT_CREATED:-0}" "${LIMINE_DEFAULT_HASH:-}"
            "$ESP_UUID" "$ROOT_UUID" "$ESP_SOURCE" "$ESP_MOUNT"
            "${OPERATION_BACKUP:-}" "${LIMINE_DIAGNOSTIC_DIR:-}" "$source_cmdline")
    for v in "${values[@]}"; do
        pending_safe_value "$v" || { fail 'Refusing to write pending state containing unsafe control characters'; return 1; }
    done

    mkdir -p -- "$PENDING_STATE_DIR" || return 1
    chmod 700 -- "$PENDING_STATE_DIR" 2>/dev/null || true
    tmp=$(mktemp "$PENDING_STATE_DIR/.pending.XXXXXX") || return 1
    chmod 600 -- "$tmp" 2>/dev/null || true
    {
        printf 'format\t2\n'
        printf 'phase\t%s\n' "$phase"
        printf 'created\t%s\n' "$created"
        printf 'machine_id\t%s\n' "$machine_id"
        printf 'source\tgrub\n'
        printf 'target\tlimine\n'
        printf 'old_boot_id\t%s\n' "$old_id"
        printf 'old_boot_label\t%s\n' "$BOOT_LABEL"
        printf 'old_boot_efi_path\t%s\n' "$BOOT_EFI_PATH"
        printf 'old_grub_efi_resolved\t%s\n' "${OLD_GRUB_EFI_RESOLVED:-}"
        printf 'old_grub_hash\t%s\n' "${OLD_GRUB_HASH:-}"
        printf 'old_fallback_path\t%s\n' "${OLD_FALLBACK_PATH:-}"
        printf 'old_fallback_hash\t%s\n' "${OLD_FALLBACK_HASH:-}"
        printf 'old_fallback_was_grub\t%s\n' "${OLD_FALLBACK_WAS_GRUB:-0}"
        printf 'old_fallback_existed\t%s\n' "${OLD_FALLBACK_EXISTED:-0}"
        printf 'old_fallback_snapshot\t%s\n' "${OLD_FALLBACK_SNAPSHOT:-}"
        printf 'post_stage_fallback_hash\t%s\n' "${POST_STAGE_FALLBACK_HASH:-}"
        printf 'transaction_snapshot_dir\t%s\n' "${TRANSACTION_SNAPSHOT_DIR:-}"
        printf 'original_boot_order\t%s\n' "$original_order"
        printf 'target_boot_id\t%s\n' "$target_id"
        printf 'target_efi_path\t%s\n' "$(target_expected_efi_path limine)"
        printf 'target_efi_resolved\t%s\n' "${TARGET_EFI_RESOLVED:-}"
        printf 'target_efi_hash\t%s\n' "${TARGET_EFI_HASH:-}"
        printf 'limine_conf_path\t%s\n' "${TARGET_LIMINE_CONF_PATH:-}"
        printf 'limine_conf_hash\t%s\n' "${TARGET_LIMINE_CONF_HASH:-}"
        printf 'limine_managed_dir\t%s\n' "${TARGET_LIMINE_MANAGED_DIR:-}"
        printf 'limine_default_created\t%s\n' "${LIMINE_DEFAULT_CREATED:-0}"
        printf 'limine_default_hash\t%s\n' "${LIMINE_DEFAULT_HASH:-}"
        printf 'esp_uuid\t%s\n' "$ESP_UUID"
        printf 'root_uuid\t%s\n' "$ROOT_UUID"
        printf 'esp_source\t%s\n' "$ESP_SOURCE"
        printf 'esp_mount\t%s\n' "$ESP_MOUNT"
        printf 'backup_path\t%s\n' "${OPERATION_BACKUP:-}"
        printf 'diagnostic_path\t%s\n' "${LIMINE_DIAGNOSTIC_DIR:-}"
        printf 'source_cmdline\t%s\n' "$source_cmdline"
    } >"$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$PENDING_STATE_FILE"
}

write_pending_limine_to_grub() {
    local old_id=$1 original_order=$2 target_id=$3 phase=${4:-candidate-ready}
    local machine_id created source_cmdline tmp values=() v
    machine_id=$(cat /etc/machine-id 2>/dev/null || true)
    created=$(date --iso-8601=seconds 2>/dev/null || date)
    source_cmdline=$(cat /proc/cmdline 2>/dev/null || true)

    values=("$phase" "$machine_id" "$old_id" "$BOOT_LABEL" "$BOOT_EFI_PATH"
            "${SOURCE_LIMINE_EFI_RESOLVED:-}" "${SOURCE_LIMINE_EFI_HASH:-}"
            "${SOURCE_LIMINE_CONF_PATH:-}" "${SOURCE_LIMINE_CONF_HASH:-}" "${SOURCE_LIMINE_DEFAULT_HASH:-}"
            "${SOURCE_LIMINE_MANAGED_DIR:-}" "${SOURCE_LIMINE_MANAGED_HASH:-}"
            "${OLD_FALLBACK_PATH:-}" "${OLD_FALLBACK_HASH:-}" "${OLD_FALLBACK_EXISTED:-0}" "${OLD_FALLBACK_SNAPSHOT:-}" "${POST_STAGE_FALLBACK_HASH:-}" "${TRANSACTION_SNAPSHOT_DIR:-}"
            "$original_order" "$target_id" "$(target_expected_efi_path grub)" "${TARGET_EFI_RESOLVED:-}" "${TARGET_EFI_HASH:-}"
            "${TARGET_GRUB_CFG_PATH:-}" "${TARGET_GRUB_CFG_HASH:-}" "${TARGET_GRUB_DIR:-}" "${GRUB_DEFAULT_CREATED:-0}" "${GRUB_DEFAULT_HASH:-}"
            "${GRUB_ARTIFACT_MANIFEST:-}" "${GRUB_DIR_MANIFEST:-}" "${TARGET_GRUB_EFI_DIR:-}" "${GRUB_EFI_DIR_MANIFEST:-}"
            "$ESP_UUID" "$ROOT_UUID" "$ESP_SOURCE" "$ESP_MOUNT" "${OPERATION_BACKUP:-}" "${GRUB_DIAGNOSTIC_DIR:-}" "$source_cmdline")
    for v in "${values[@]}"; do
        pending_safe_value "$v" || { fail 'Refusing to write pending state containing unsafe control characters'; return 1; }
    done

    mkdir -p -- "$PENDING_STATE_DIR" || return 1
    chmod 700 -- "$PENDING_STATE_DIR" 2>/dev/null || true
    tmp=$(mktemp "$PENDING_STATE_DIR/.pending.XXXXXX") || return 1
    chmod 600 -- "$tmp" 2>/dev/null || true
    {
        printf 'format\t4\n'
        printf 'phase\t%s\n' "$phase"
        printf 'created\t%s\n' "$created"
        printf 'machine_id\t%s\n' "$machine_id"
        printf 'source\tlimine\n'
        printf 'target\tgrub\n'
        printf 'old_boot_id\t%s\n' "$old_id"
        printf 'old_boot_label\t%s\n' "$BOOT_LABEL"
        printf 'old_boot_efi_path\t%s\n' "$BOOT_EFI_PATH"
        printf 'source_limine_efi_resolved\t%s\n' "${SOURCE_LIMINE_EFI_RESOLVED:-}"
        printf 'source_limine_efi_hash\t%s\n' "${SOURCE_LIMINE_EFI_HASH:-}"
        printf 'source_limine_conf_path\t%s\n' "${SOURCE_LIMINE_CONF_PATH:-}"
        printf 'source_limine_conf_hash\t%s\n' "${SOURCE_LIMINE_CONF_HASH:-}"
        printf 'source_limine_default_hash\t%s\n' "${SOURCE_LIMINE_DEFAULT_HASH:-}"
        printf 'source_limine_managed_dir\t%s\n' "${SOURCE_LIMINE_MANAGED_DIR:-}"
        printf 'source_limine_managed_hash\t%s\n' "${SOURCE_LIMINE_MANAGED_HASH:-}"
        printf 'old_fallback_path\t%s\n' "${OLD_FALLBACK_PATH:-}"
        printf 'old_fallback_hash\t%s\n' "${OLD_FALLBACK_HASH:-}"
        printf 'old_fallback_existed\t%s\n' "${OLD_FALLBACK_EXISTED:-0}"
        printf 'old_fallback_snapshot\t%s\n' "${OLD_FALLBACK_SNAPSHOT:-}"
        printf 'post_stage_fallback_hash\t%s\n' "${POST_STAGE_FALLBACK_HASH:-}"
        printf 'transaction_snapshot_dir\t%s\n' "${TRANSACTION_SNAPSHOT_DIR:-}"
        printf 'original_boot_order\t%s\n' "$original_order"
        printf 'target_boot_id\t%s\n' "$target_id"
        printf 'target_efi_path\t%s\n' "$(target_expected_efi_path grub)"
        printf 'target_efi_resolved\t%s\n' "${TARGET_EFI_RESOLVED:-}"
        printf 'target_efi_hash\t%s\n' "${TARGET_EFI_HASH:-}"
        printf 'grub_cfg_path\t%s\n' "${TARGET_GRUB_CFG_PATH:-}"
        printf 'grub_cfg_hash\t%s\n' "${TARGET_GRUB_CFG_HASH:-}"
        printf 'grub_dir\t%s\n' "${TARGET_GRUB_DIR:-}"
        printf 'grub_default_created\t%s\n' "${GRUB_DEFAULT_CREATED:-0}"
        printf 'grub_default_hash\t%s\n' "${GRUB_DEFAULT_HASH:-}"
        printf 'grub_artifact_manifest\t%s\n' "${GRUB_ARTIFACT_MANIFEST:-}"
        printf 'grub_dir_manifest\t%s\n' "${GRUB_DIR_MANIFEST:-}"
        printf 'grub_efi_dir\t%s\n' "${TARGET_GRUB_EFI_DIR:-}"
        printf 'grub_efi_dir_manifest\t%s\n' "${GRUB_EFI_DIR_MANIFEST:-}"
        printf 'esp_uuid\t%s\n' "$ESP_UUID"
        printf 'root_uuid\t%s\n' "$ROOT_UUID"
        printf 'esp_source\t%s\n' "$ESP_SOURCE"
        printf 'esp_mount\t%s\n' "$ESP_MOUNT"
        printf 'backup_path\t%s\n' "${OPERATION_BACKUP:-}"
        printf 'diagnostic_path\t%s\n' "${GRUB_DIAGNOSTIC_DIR:-}"
        printf 'source_cmdline\t%s\n' "$source_cmdline"
    } >"$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$PENDING_STATE_FILE"
}

pending_set_phase() {
    local new_phase=$1 tmp
    pending_safe_value "$new_phase" || return 1
    [[ -f $PENDING_STATE_FILE ]] || return 1
    tmp=$(mktemp "$PENDING_STATE_DIR/.phase.XXXXXX") || return 1
    chmod 600 -- "$tmp" 2>/dev/null || true
    awk -F'\t' -v OFS='\t' -v p="$new_phase" '$1=="phase"{$2=p} {print}' "$PENDING_STATE_FILE" >"$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$PENDING_STATE_FILE"
}

load_pending_state() {
    pending_reset
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
            old_grub_efi_resolved) PENDING_OLD_GRUB_EFI_RESOLVED=$value ;;
            old_grub_hash) PENDING_OLD_GRUB_HASH=$value ;;
            old_fallback_path) PENDING_OLD_FALLBACK_PATH=$value ;;
            old_fallback_hash) PENDING_OLD_FALLBACK_HASH=$value ;;
            old_fallback_was_grub) PENDING_OLD_FALLBACK_WAS_GRUB=$value ;;
            old_fallback_existed) PENDING_OLD_FALLBACK_EXISTED=$value ;;
            old_fallback_snapshot) PENDING_OLD_FALLBACK_SNAPSHOT=$value ;;
            post_stage_fallback_hash) PENDING_POST_STAGE_FALLBACK_HASH=$value ;;
            transaction_snapshot_dir) PENDING_TRANSACTION_SNAPSHOT_DIR=$value ;;
            original_boot_order) PENDING_ORIGINAL_BOOT_ORDER=$value ;;
            target_boot_id) PENDING_TARGET_BOOT_ID=${value^^} ;;
            target_efi_path) PENDING_TARGET_EFI_PATH=$value ;;
            target_efi_resolved) PENDING_TARGET_EFI_RESOLVED=$value ;;
            target_efi_hash) PENDING_TARGET_EFI_HASH=$value ;;
            limine_conf_path) PENDING_LIMINE_CONF_PATH=$value ;;
            limine_conf_hash) PENDING_LIMINE_CONF_HASH=$value ;;
            limine_managed_dir) PENDING_LIMINE_MANAGED_DIR=$value ;;
            limine_default_created) PENDING_LIMINE_DEFAULT_CREATED=$value ;;
            limine_default_hash) PENDING_LIMINE_DEFAULT_HASH=$value ;;
            source_limine_efi_resolved) PENDING_SOURCE_LIMINE_EFI_RESOLVED=$value ;;
            source_limine_efi_hash) PENDING_SOURCE_LIMINE_EFI_HASH=$value ;;
            source_limine_conf_path) PENDING_SOURCE_LIMINE_CONF_PATH=$value ;;
            source_limine_conf_hash) PENDING_SOURCE_LIMINE_CONF_HASH=$value ;;
            source_limine_default_hash) PENDING_SOURCE_LIMINE_DEFAULT_HASH=$value ;;
            source_limine_managed_dir) PENDING_SOURCE_LIMINE_MANAGED_DIR=$value ;;
            source_limine_managed_hash) PENDING_SOURCE_LIMINE_MANAGED_HASH=$value ;;
            grub_cfg_path) PENDING_GRUB_CFG_PATH=$value ;;
            grub_cfg_hash) PENDING_GRUB_CFG_HASH=$value ;;
            grub_dir) PENDING_GRUB_DIR=$value ;;
            grub_default_created) PENDING_GRUB_DEFAULT_CREATED=$value ;;
            grub_default_hash) PENDING_GRUB_DEFAULT_HASH=$value ;;
            grub_artifact_manifest) PENDING_GRUB_ARTIFACT_MANIFEST=$value ;;
            grub_dir_manifest) PENDING_GRUB_DIR_MANIFEST=$value ;;
            grub_efi_dir) PENDING_GRUB_EFI_DIR=$value ;;
            grub_efi_dir_manifest) PENDING_GRUB_EFI_DIR_MANIFEST=$value ;;
            esp_uuid) PENDING_ESP_UUID=$value ;;
            root_uuid) PENDING_ROOT_UUID=$value ;;
            esp_source) PENDING_ESP_SOURCE=$value ;;
            esp_mount) PENDING_ESP_MOUNT=$value ;;
            backup_path) PENDING_BACKUP_PATH=$value ;;
            diagnostic_path) PENDING_DIAGNOSTIC_PATH=$value ;;
            source_cmdline) PENDING_SOURCE_CMDLINE=$value ;;
            ''|'#'*) ;;
            *) PENDING_REASON="unknown pending-state key: $key"; return 1 ;;
        esac
    done <"$PENDING_STATE_FILE"

    [[ $PENDING_PHASE == candidate-ready || $PENDING_PHASE == boot-armed || $PENDING_PHASE == runtime-validated ]] || { PENDING_REASON='unsupported pending-state phase'; return 1; }
    case "$PENDING_FORMAT:$PENDING_SOURCE:$PENDING_TARGET" in
        2:grub:limine|3:limine:grub|4:limine:grub) ;;
        *) PENDING_REASON='unsupported pending-state format/migration type'; return 1 ;;
    esac
    [[ -n $PENDING_OLD_BOOT_ID && -n $PENDING_TARGET_BOOT_ID ]] || { PENDING_REASON='missing NVRAM identifiers'; return 1; }
    [[ -n $PENDING_MACHINE_ID ]] || { PENDING_REASON='missing machine identity'; return 1; }
    [[ -n $PENDING_SOURCE_CMDLINE ]] || { PENDING_REASON='missing source kernel command line'; return 1; }
    PENDING_REASON='valid'
    return 0
}

pending_hash_is_sha256_or_empty() {
    local v=${1:-}
    [[ -z $v || $v =~ ^[0-9A-Fa-f]{64}$ ]]
}

pending_hash_is_sha256() {
    local v=${1:-}
    [[ $v =~ ^[0-9A-Fa-f]{64}$ ]]
}

pending_path_under() {
    local child=$1 parent=$2 child_real parent_real
    [[ -n $child && -n $parent ]] || return 1
    child_real=$(safe_realpath "$child")
    parent_real=$(safe_realpath "$parent")
    [[ $child_real == "$parent_real" || $child_real == "$parent_real/"* ]]
}

pending_validate_snapshot_dir() {
    [[ -n $PENDING_TRANSACTION_SNAPSHOT_DIR ]] || return 0
    pending_path_under "$PENDING_TRANSACTION_SNAPSHOT_DIR" "$PENDING_STATE_DIR" || { PENDING_REASON='transaction snapshot directory is outside the tool state directory'; return 1; }
    [[ $(safe_realpath "$PENDING_TRANSACTION_SNAPSHOT_DIR") != $(safe_realpath "$PENDING_STATE_DIR") ]] || { PENDING_REASON='transaction snapshot directory resolves to the state root itself'; return 1; }
    [[ $(basename -- "$PENDING_TRANSACTION_SNAPSHOT_DIR") == .prestage.* ]] || { PENDING_REASON='transaction snapshot directory has an unexpected name'; return 1; }
    return 0
}

pending_validate_fallback_metadata() {
    local expected_fallback
    expected_fallback=$(safe_realpath "$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI")
    [[ $(safe_realpath "$PENDING_OLD_FALLBACK_PATH") == "$expected_fallback" ]] || { PENDING_REASON='pending fallback path does not match the current ESP fallback path'; return 1; }
    pending_hash_is_sha256_or_empty "$PENDING_OLD_FALLBACK_HASH" || { PENDING_REASON='invalid old fallback hash format'; return 1; }
    pending_hash_is_sha256_or_empty "$PENDING_POST_STAGE_FALLBACK_HASH" || { PENDING_REASON='invalid post-stage fallback hash format'; return 1; }
    [[ $PENDING_OLD_FALLBACK_EXISTED == 0 || $PENDING_OLD_FALLBACK_EXISTED == 1 ]] || { PENDING_REASON='invalid fallback-existed marker'; return 1; }
    if [[ $PENDING_OLD_FALLBACK_EXISTED == 1 ]]; then
        pending_hash_is_sha256 "$PENDING_OLD_FALLBACK_HASH" || { PENDING_REASON='fallback existed but its hash is missing'; return 1; }
        [[ -n $PENDING_OLD_FALLBACK_SNAPSHOT && -n $PENDING_TRANSACTION_SNAPSHOT_DIR ]] || { PENDING_REASON='fallback existed but rollback snapshot metadata is missing'; return 1; }
        pending_path_under "$PENDING_OLD_FALLBACK_SNAPSHOT" "$PENDING_TRANSACTION_SNAPSHOT_DIR" || { PENDING_REASON='fallback snapshot is outside the transaction snapshot directory'; return 1; }
        [[ -f $PENDING_OLD_FALLBACK_SNAPSHOT ]] || { PENDING_REASON='recorded pre-stage fallback snapshot is missing'; return 1; }
        [[ $(sha256sum -- "$PENDING_OLD_FALLBACK_SNAPSHOT" 2>/dev/null | awk '{print $1}' || true) == "$PENDING_OLD_FALLBACK_HASH" ]] || { PENDING_REASON='recorded pre-stage fallback snapshot hash mismatch'; return 1; }
    fi
    return 0
}

validate_pending_owned_paths() {
    local machine_id expected_target expected_old actual_target actual_old
    machine_id=$(cat /etc/machine-id 2>/dev/null || true)
    expected_target=$(safe_realpath "$ESP_MOUNT/$(normalize_efi_path "$(target_expected_efi_path "$PENDING_TARGET")")")
    expected_old=$(safe_realpath "$ESP_MOUNT/$(normalize_efi_path "$PENDING_OLD_BOOT_EFI_PATH")")
    actual_target=$(safe_realpath "$PENDING_TARGET_EFI_RESOLVED")

    [[ ${actual_target,,} == ${expected_target,,} ]] || { PENDING_REASON='pending target EFI path does not match the expected target path/current ESP'; return 1; }
    pending_hash_is_sha256 "$PENDING_TARGET_EFI_HASH" || { PENDING_REASON='invalid/missing target EFI hash'; return 1; }
    pending_validate_snapshot_dir || return 1
    pending_validate_fallback_metadata || return 1

    case "$PENDING_SOURCE:$PENDING_TARGET" in
        grub:limine)
            actual_old=$(safe_realpath "$PENDING_OLD_GRUB_EFI_RESOLVED")
            [[ ${actual_old,,} == ${expected_old,,} ]] || { PENDING_REASON='pending source GRUB EFI path does not match its recorded firmware path/current ESP'; return 1; }
            [[ $(safe_realpath "$PENDING_LIMINE_CONF_PATH") == $(safe_realpath "$ESP_MOUNT/limine.conf") ]] || { PENDING_REASON='pending limine.conf path does not match current ESP'; return 1; }
            [[ $(safe_realpath "$PENDING_LIMINE_MANAGED_DIR") == $(safe_realpath "$ESP_MOUNT/$machine_id") ]] || { PENDING_REASON='pending Limine managed directory does not match current ESP/machine ID'; return 1; }
            pending_hash_is_sha256 "$PENDING_OLD_GRUB_HASH" || { PENDING_REASON='invalid/missing source GRUB EFI hash'; return 1; }
            pending_hash_is_sha256 "$PENDING_LIMINE_CONF_HASH" || { PENDING_REASON='invalid/missing limine.conf hash'; return 1; }
            pending_hash_is_sha256_or_empty "$PENDING_LIMINE_DEFAULT_HASH" || { PENDING_REASON='invalid /etc/default/limine hash'; return 1; }
            [[ $PENDING_LIMINE_DEFAULT_CREATED == 0 || $PENDING_LIMINE_DEFAULT_CREATED == 1 ]] || { PENDING_REASON='invalid Limine-default ownership marker'; return 1; }
            ;;
        limine:grub)
            actual_old=$(safe_realpath "$PENDING_SOURCE_LIMINE_EFI_RESOLVED")
            [[ ${actual_old,,} == ${expected_old,,} ]] || { PENDING_REASON='pending source Limine EFI path does not match its recorded firmware path/current ESP'; return 1; }
            [[ $(safe_realpath "$PENDING_SOURCE_LIMINE_CONF_PATH") == $(safe_realpath "$ESP_MOUNT/limine.conf") ]] || { PENDING_REASON='pending source limine.conf path does not match current ESP'; return 1; }
            [[ $(safe_realpath "$PENDING_SOURCE_LIMINE_MANAGED_DIR") == $(safe_realpath "$ESP_MOUNT/$machine_id") ]] || { PENDING_REASON='pending source Limine managed directory does not match current ESP/machine ID'; return 1; }
            [[ $(safe_realpath "$PENDING_GRUB_CFG_PATH") == $(safe_realpath /boot/grub/grub.cfg) ]] || { PENDING_REASON='pending grub.cfg path is unexpected'; return 1; }
            [[ $(safe_realpath "$PENDING_GRUB_DIR") == $(safe_realpath /boot/grub) ]] || { PENDING_REASON='pending GRUB directory path is unexpected'; return 1; }
            [[ ${PENDING_GRUB_EFI_DIR,,} == ${ESP_MOUNT,,}/efi/cachyos ]] || { PENDING_REASON='pending GRUB EFI directory path is unexpected'; return 1; }
            pending_hash_is_sha256 "$PENDING_SOURCE_LIMINE_EFI_HASH" || { PENDING_REASON='invalid/missing source Limine EFI hash'; return 1; }
            pending_hash_is_sha256 "$PENDING_SOURCE_LIMINE_CONF_HASH" || { PENDING_REASON='invalid/missing source limine.conf hash'; return 1; }
            pending_hash_is_sha256 "$PENDING_SOURCE_LIMINE_DEFAULT_HASH" || { PENDING_REASON='invalid/missing source /etc/default/limine hash'; return 1; }
            pending_hash_is_sha256 "$PENDING_SOURCE_LIMINE_MANAGED_HASH" || { PENDING_REASON='invalid/missing source Limine managed-tree fingerprint'; return 1; }
            pending_hash_is_sha256 "$PENDING_GRUB_CFG_HASH" || { PENDING_REASON='invalid/missing grub.cfg hash'; return 1; }
            pending_hash_is_sha256 "$PENDING_GRUB_DEFAULT_HASH" || { PENDING_REASON='invalid/missing /etc/default/grub hash'; return 1; }
            [[ $PENDING_GRUB_DEFAULT_CREATED == 1 ]] || { PENDING_REASON='GRUB default ownership marker is not transaction-owned'; return 1; }
            local manifest
            for manifest in "$PENDING_GRUB_ARTIFACT_MANIFEST" "$PENDING_GRUB_DIR_MANIFEST" "$PENDING_GRUB_EFI_DIR_MANIFEST"; do
                [[ -n $manifest && -n $PENDING_TRANSACTION_SNAPSHOT_DIR ]] || { PENDING_REASON='GRUB ownership manifest metadata is missing'; return 1; }
                pending_path_under "$manifest" "$PENDING_TRANSACTION_SNAPSHOT_DIR" || { PENDING_REASON='GRUB ownership manifest is outside the transaction snapshot directory'; return 1; }
                [[ -s $manifest ]] || { PENDING_REASON='GRUB ownership manifest is missing/empty'; return 1; }
            done
            ;;
        *) PENDING_REASON='unsupported pending migration direction'; return 1 ;;
    esac
    return 0
}

validate_pending_compatibility() {
    load_pending_state || return 1
    collect_storage_info
    local machine_id
    machine_id=$(cat /etc/machine-id 2>/dev/null || true)
    [[ $machine_id == "$PENDING_MACHINE_ID" ]] || { PENDING_REASON='machine ID mismatch'; return 1; }
    [[ -n $PENDING_ESP_UUID && $ESP_UUID == "$PENDING_ESP_UUID" ]] || { PENDING_REASON='ESP UUID mismatch'; return 1; }
    [[ -n $PENDING_ROOT_UUID && $ROOT_UUID == "$PENDING_ROOT_UUID" ]] || { PENDING_REASON='root UUID mismatch'; return 1; }
    [[ $ESP_SOURCE == "$PENDING_ESP_SOURCE" && $ESP_MOUNT == "$PENDING_ESP_MOUNT" ]] || { PENDING_REASON='ESP source/mount topology changed'; return 1; }
    validate_pending_owned_paths || return 1
    PENDING_REASON='compatible'
    return 0
}

boot_id_exists() {
    local id=${1^^}
    efibootmgr 2>/dev/null | grep -Eqi "^Boot${id}\\*?[[:space:]]"
}

boot_entry_path_for_id() {
    local id=${1^^} line
    line=$(efibootmgr -v 2>/dev/null | awk -v id="$id" 'BEGIN{IGNORECASE=1} $0 ~ "^Boot" id {print; exit}')
    [[ -n $line ]] || return 1
    efi_path_from_efibootmgr_line "$line"
}

nvram_id_matches_path() {
    local id=$1 expected=$2 actual actual_norm expected_norm
    actual=$(boot_entry_path_for_id "$id" 2>/dev/null || true)
    [[ -n $actual && -n $expected ]] || return 1
    actual_norm=$(normalize_efi_path "$actual")
    expected_norm=$(normalize_efi_path "$expected")
    [[ ${actual_norm,,} == ${expected_norm,,} ]]
}

set_source_first_boot_order() {
    local old_id=${1^^} target_id=${2^^} original_order=$3
    local -a ids=() original=()
    local id joined current_order first

    boot_id_exists "$old_id" || { fail "Source boot entry Boot$old_id is no longer present; refusing to alter BootOrder"; return 1; }
    boot_id_exists "$target_id" || { fail "Target boot entry Boot$target_id is missing; refusing to alter BootOrder"; return 1; }

    ids+=("$old_id")
    IFS=',' read -ra original <<<"$original_order"
    for id in "${original[@]}"; do
        id=${id^^}
        [[ -n $id && $id != "$old_id" && $id != "$target_id" ]] || continue
        boot_id_exists "$id" && ids+=("$id")
    done
    ids+=("$target_id")
    joined=$(IFS=,; printf '%s' "${ids[*]}")

    sudo efibootmgr -o "$joined" >/dev/null || return 1
    current_order=$(efibootmgr 2>/dev/null | awk -F': ' '/^BootOrder:/ {print $2; exit}')
    first=${current_order%%,*}
    [[ ${first^^} == "$old_id" ]] || { fail "BootOrder verification failed; expected source Boot$old_id first"; return 1; }
    ok "BootOrder keeps source Boot$old_id as the normal persistent default"
}

pending_banner() {
    pending_exists || return 0
    if validate_pending_compatibility >/dev/null 2>&1; then
        detect_bootloader
        printf 'Pending/staged migration: %s -> %s  [%s]' "$(bootloader_display_name "$PENDING_SOURCE")" "$(bootloader_display_name "$PENDING_TARGET")" "$PENDING_PHASE"
        case "$PENDING_PHASE:$BOOTLOADER" in
            candidate-ready:$PENDING_SOURCE) printf '  [SOURCE ACTIVE; READY TO ARM]\n' ;;
            candidate-ready:$PENDING_TARGET) printf '  [TARGET BOOTED MANUALLY; NOT CERTIFIED]\n' ;;
            boot-armed:$PENDING_SOURCE)
                if [[ ${BOOT_NEXT^^} == "$PENDING_TARGET_BOOT_ID" ]]; then
                    printf '  [ONE-TIME TARGET BOOT ARMED]\n'
                elif [[ -z $BOOT_NEXT ]]; then
                    printf '  [ONE-TIME REQUEST CONSUMED/CLEARED; SOURCE ACTIVE]\n'
                else
                    printf '  [SOURCE ACTIVE; EXTERNAL BootNext=%s]\n' "$BOOT_NEXT"
                fi
                ;;
            boot-armed:$PENDING_TARGET) printf '  [TARGET ACTIVE; RUNTIME VALIDATION REQUIRED]\n' ;;
            runtime-validated:$PENDING_TARGET) printf '  [TARGET RUNTIME VALIDATED]\n' ;;
            runtime-validated:$PENDING_SOURCE) printf '  [RUNTIME PROOF RECORDED; SOURCE ACTIVE]\n' ;;
            *) printf '  [CURRENT BOOTLOADER: %s]\n' "$(bootloader_display_name "$BOOTLOADER")" ;;
        esac
    else
        printf 'Pending/staged migration state: [INVALID/INCOMPATIBLE: %s]\n' "$PENDING_REASON"
    fi
}

show_pending_details() {
    validate_pending_compatibility || { printf 'Pending state is not usable: %s\n' "$PENDING_REASON"; return 1; }
    printf '\nStaged migration details:\n'
    printf '  Phase:               %s\n' "$PENDING_PHASE"
    printf '  Created:             %s\n' "$PENDING_CREATED"
    printf '  Source:              %s (Boot%s)\n' "$(bootloader_display_name "$PENDING_SOURCE")" "$PENDING_OLD_BOOT_ID"
    printf '  Target:              %s (Boot%s)\n' "$(bootloader_display_name "$PENDING_TARGET")" "$PENDING_TARGET_BOOT_ID"
    printf '  Original BootOrder:  %s\n' "$PENDING_ORIGINAL_BOOT_ORDER"
    printf '  ESP:                 %s (%s) at %s\n' "$PENDING_ESP_SOURCE" "$PENDING_ESP_UUID" "$PENDING_ESP_MOUNT"
    printf '  Root UUID:           %s\n' "$PENDING_ROOT_UUID"
    [[ -n $PENDING_BACKUP_PATH ]] && printf '  Backup:              %s\n' "$PENDING_BACKUP_PATH"
    [[ -n $PENDING_DIAGNOSTIC_PATH ]] && printf '  Diagnostics:         %s\n' "$PENDING_DIAGNOSTIC_PATH"
    printf '  Source cmdline:      %s\n' "$PENDING_SOURCE_CMDLINE"
}

pending_verify_file_manifest() {
    local manifest=$1 expected_root=${2:-} hash path actual count=0
    [[ -s $manifest ]] || return 1
    while IFS=$'\t' read -r hash path; do
        pending_hash_is_sha256 "$hash" || return 1
        [[ $path == /* && $path != *$'\n'* && $path != *$'\r'* && $path != *$'\t'* ]] || return 1
        [[ -z $expected_root ]] || pending_path_under "$path" "$expected_root" || return 1
        actual=$(sudo -n sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || true)
        [[ -n $actual && $actual == "$hash" ]] || return 1
        ((count++))
    done <"$manifest"
    ((count > 0))
}

pending_verify_grub_artifact_manifest() {
    local manifest=$1 expected_root=${2:-/boot} ownership hash path actual count=0
    [[ -s $manifest ]] || return 1
    if [[ ${PENDING_FORMAT:-} == 3 ]]; then
        pending_verify_file_manifest "$manifest" "$expected_root"
        return $?
    fi
    while IFS=$'\t' read -r ownership hash path; do
        [[ $ownership == created || $ownership == shared ]] || return 1
        pending_hash_is_sha256 "$hash" || return 1
        [[ $path == /* && $path != *$'\n'* && $path != *$'\r'* && $path != *$'\t'* ]] || return 1
        pending_path_under "$path" "$expected_root" || return 1
        actual=$(sudo -n sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || true)
        [[ -n $actual && $actual == "$hash" ]] || return 1
        ((count++))
    done <"$manifest"
    ((count > 0))
}

pending_verify_tree_manifest() {
    local root=$1 manifest=$2 tmp path type identity target
    [[ -s $manifest ]] || return 1
    tmp=$(mktemp) || return 1
    : >"$tmp"
    while IFS= read -r -d '' path; do
        [[ $path != *$'\n'* && $path != *$'\r'* && $path != *$'\t'* ]] || { rm -f -- "$tmp"; return 1; }
        if sudo -n test -L "$path" 2>/dev/null; then
            type=l
            target=$(sudo -n readlink -- "$path" 2>/dev/null || true)
            [[ $target != *$'\n'* && $target != *$'\r'* && $target != *$'\t'* ]] || { rm -f -- "$tmp"; return 1; }
            identity=$(printf '%s' "$target" | sha256sum | awk '{print $1}')
        elif sudo -n test -f "$path" 2>/dev/null; then
            type=f
            identity=$(sudo -n sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || true)
        elif sudo -n test -d "$path" 2>/dev/null; then
            type=d
            identity='-'
        else
            rm -f -- "$tmp"
            return 1
        fi
        [[ -n $identity ]] || { rm -f -- "$tmp"; return 1; }
        printf '%s\t%s\t%s\n' "$type" "$identity" "$path" >>"$tmp"
    done < <(sudo -n find "$root" -mindepth 1 -print0 2>/dev/null | LC_ALL=C sort -z)
    LC_ALL=C sort -o "$tmp" "$tmp"
    if cmp -s <(LC_ALL=C sort "$manifest") "$tmp"; then
        rm -f -- "$tmp"
        return 0
    fi
    rm -f -- "$tmp"
    return 1
}

verify_pending_candidate_ownership_unchanged() {
    local current_hash
    [[ -f $PENDING_STATE_FILE ]] || return 1
    nvram_id_matches_path "$PENDING_TARGET_BOOT_ID" "$PENDING_TARGET_EFI_PATH" || { fail 'Staged target NVRAM path changed since candidate creation'; return 1; }
    current_hash=$(sudo -n sha256sum -- "$PENDING_TARGET_EFI_RESOLVED" 2>/dev/null | awk '{print $1}' || true)
    [[ -n $current_hash && $current_hash == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'Staged target EFI executable changed since candidate creation'; return 1; }

    case "$PENDING_SOURCE:$PENDING_TARGET" in
        grub:limine)
            current_hash=$(sudo -n sha256sum -- "$PENDING_LIMINE_CONF_PATH" 2>/dev/null | awk '{print $1}' || true)
            [[ -n $current_hash && $current_hash == "$PENDING_LIMINE_CONF_HASH" ]] || { fail 'Staged limine.conf changed since candidate creation'; return 1; }
            if [[ $PENDING_LIMINE_DEFAULT_CREATED == 1 ]]; then
                current_hash=$(sha256sum /etc/default/limine 2>/dev/null | awk '{print $1}' || sudo -n sha256sum /etc/default/limine 2>/dev/null | awk '{print $1}' || true)
                [[ -n $current_hash && $current_hash == "$PENDING_LIMINE_DEFAULT_HASH" ]] || { fail '/etc/default/limine changed since candidate creation'; return 1; }
            fi
            sudo -n test -d "$PENDING_LIMINE_MANAGED_DIR" 2>/dev/null || { fail 'Staged Limine managed kernel directory disappeared'; return 1; }
            ok 'Candidate ownership metadata still matches the staged Limine state'
            ;;
        limine:grub)
            current_hash=$(sudo -n sha256sum -- "$PENDING_GRUB_CFG_PATH" 2>/dev/null | awk '{print $1}' || sha256sum -- "$PENDING_GRUB_CFG_PATH" 2>/dev/null | awk '{print $1}' || true)
            [[ -n $current_hash && $current_hash == "$PENDING_GRUB_CFG_HASH" ]] || { fail 'Staged grub.cfg changed since candidate creation'; return 1; }
            current_hash=$(sha256sum /etc/default/grub 2>/dev/null | awk '{print $1}' || sudo -n sha256sum /etc/default/grub 2>/dev/null | awk '{print $1}' || true)
            [[ -n $current_hash && $current_hash == "$PENDING_GRUB_DEFAULT_HASH" ]] || { fail '/etc/default/grub changed since candidate creation'; return 1; }
            pending_verify_grub_artifact_manifest "$PENDING_GRUB_ARTIFACT_MANIFEST" /boot || { fail 'One or more GRUB kernel/initramfs artifacts (created or source-shared) changed'; return 1; }
            pending_verify_tree_manifest "$PENDING_GRUB_DIR" "$PENDING_GRUB_DIR_MANIFEST" || { fail '/boot/grub tree differs from the exact candidate manifest'; return 1; }
            pending_verify_tree_manifest "$PENDING_GRUB_EFI_DIR" "$PENDING_GRUB_EFI_DIR_MANIFEST" || { fail 'GRUB EFI namespace differs from the exact candidate manifest'; return 1; }
            ok 'Candidate ownership metadata still matches the staged GRUB state'
            ;;
        *) fail 'Unsupported staged target ownership validator'; return 1 ;;
    esac
}

verify_pending_source_recovery_unchanged() {
    local current_hash order first managed_hash fallback_hash
    nvram_id_matches_path "$PENDING_OLD_BOOT_ID" "$PENDING_OLD_BOOT_EFI_PATH" || { fail 'Recorded source NVRAM path changed'; return 1; }
    order=$(efibootmgr 2>/dev/null | awk -F': ' '/^BootOrder:/ {print $2; exit}')
    first=${order%%,*}
    [[ ${first^^} == "$PENDING_OLD_BOOT_ID" ]] || { fail "Persistent BootOrder no longer has source Boot$PENDING_OLD_BOOT_ID first"; return 1; }

    case "$PENDING_SOURCE" in
        grub)
            current_hash=$(sudo -n sha256sum -- "$PENDING_OLD_GRUB_EFI_RESOLVED" 2>/dev/null | awk '{print $1}' || true)
            [[ -n $current_hash && $current_hash == "$PENDING_OLD_GRUB_HASH" ]] || { fail 'Recorded source GRUB EFI executable changed since candidate creation'; return 1; }
            validate_grub_boot_chain current || { fail 'Source GRUB boot chain no longer passes deep validation'; return 1; }
            ok 'Source GRUB recovery path still matches the recorded candidate transaction'
            ;;
        limine)
            current_hash=$(sudo -n sha256sum -- "$PENDING_SOURCE_LIMINE_EFI_RESOLVED" 2>/dev/null | awk '{print $1}' || true)
            [[ -n $current_hash && $current_hash == "$PENDING_SOURCE_LIMINE_EFI_HASH" ]] || { fail 'Recorded source Limine EFI executable changed since candidate creation'; return 1; }
            current_hash=$(sudo -n sha256sum -- "$PENDING_SOURCE_LIMINE_CONF_PATH" 2>/dev/null | awk '{print $1}' || sha256sum -- "$PENDING_SOURCE_LIMINE_CONF_PATH" 2>/dev/null | awk '{print $1}' || true)
            [[ -n $current_hash && $current_hash == "$PENDING_SOURCE_LIMINE_CONF_HASH" ]] || { fail 'Recorded source limine.conf changed since candidate creation'; return 1; }
            current_hash=$(sha256sum /etc/default/limine 2>/dev/null | awk '{print $1}' || sudo -n sha256sum /etc/default/limine 2>/dev/null | awk '{print $1}' || true)
            [[ -n $current_hash && $current_hash == "$PENDING_SOURCE_LIMINE_DEFAULT_HASH" ]] || { fail 'Recorded source /etc/default/limine changed since candidate creation'; return 1; }
            managed_hash=$(hash_directory_tree_privileged "$PENDING_SOURCE_LIMINE_MANAGED_DIR" 2>/dev/null || true)
            [[ -n $managed_hash && $managed_hash == "$PENDING_SOURCE_LIMINE_MANAGED_HASH" ]] || { fail 'Recorded source Limine managed kernel tree changed since candidate creation'; return 1; }
            if [[ $PENDING_OLD_FALLBACK_EXISTED == 1 ]]; then
                fallback_hash=$(sudo -n sha256sum -- "$PENDING_OLD_FALLBACK_PATH" 2>/dev/null | awk '{print $1}' || true)
                [[ -n $fallback_hash && $fallback_hash == "$PENDING_OLD_FALLBACK_HASH" ]] || { fail 'Source Limine UEFI fallback changed since candidate creation'; return 1; }
            else
                (sudo -n test ! -e "$PENDING_OLD_FALLBACK_PATH" 2>/dev/null && [[ ! -e $PENDING_OLD_FALLBACK_PATH ]]) || { fail 'A UEFI fallback appeared although the source Limine state had none'; return 1; }
            fi
            validate_limine_boot_chain migration || { fail 'Source Limine boot chain no longer passes deep validation'; return 1; }
            ok 'Source Limine recovery path still matches the recorded candidate transaction'
            ;;
        *) fail 'Unsupported pending source recovery validator'; return 1 ;;
    esac
}

rollback_pending_fallback_state() {
    local fallback=$PENDING_OLD_FALLBACK_PATH current_hash snapshot_hash
    if [[ $PENDING_OLD_FALLBACK_EXISTED == 1 ]]; then
        [[ -f $PENDING_OLD_FALLBACK_SNAPSHOT ]] || { fail 'Recorded pre-stage fallback snapshot is missing; refusing rollback'; return 1; }
        snapshot_hash=$(sha256sum -- "$PENDING_OLD_FALLBACK_SNAPSHOT" 2>/dev/null | awk '{print $1}' || true)
        [[ -n $snapshot_hash && $snapshot_hash == "$PENDING_OLD_FALLBACK_HASH" ]] || { fail 'Pre-stage fallback snapshot no longer matches its recorded hash'; return 1; }
        current_hash=$(sudo -n sha256sum -- "$fallback" 2>/dev/null | awk '{print $1}' || true)
        if [[ $current_hash == "$PENDING_OLD_FALLBACK_HASH" ]]; then
            ok 'UEFI fallback is already identical to the pre-stage state'
            return 0
        fi
        if [[ -n $PENDING_POST_STAGE_FALLBACK_HASH ]]; then
            [[ $current_hash == "$PENDING_POST_STAGE_FALLBACK_HASH" ]] || { fail 'UEFI fallback changed after staging; refusing to overwrite it during rollback'; return 1; }
        else
            [[ ! -e $fallback ]] || { fail 'UEFI fallback state no longer matches recorded post-stage absence'; return 1; }
        fi
        sudo mkdir -p -- "$(dirname -- "$fallback")" || return 1
        sudo install -m 0644 -- "$PENDING_OLD_FALLBACK_SNAPSHOT" "$fallback" || return 1
        ok 'Restored the pre-stage UEFI fallback executable'
    else
        if sudo -n test -f "$fallback" 2>/dev/null; then
            current_hash=$(sudo -n sha256sum -- "$fallback" 2>/dev/null | awk '{print $1}' || true)
            [[ -n $PENDING_POST_STAGE_FALLBACK_HASH && $current_hash == "$PENDING_POST_STAGE_FALLBACK_HASH" ]] || { fail 'Fallback was absent before staging but current fallback is not transaction-owned'; return 1; }
            sudo rm -f -- "$fallback" || return 1
            ok 'Removed transaction-created UEFI fallback executable'
        fi
    fi
    return 0
}

remove_pending_transaction_snapshot() {
    [[ -n $PENDING_TRANSACTION_SNAPSHOT_DIR ]] || return 0
    pending_path_under "$PENDING_TRANSACTION_SNAPSHOT_DIR" "$PENDING_STATE_DIR" || { warn 'Transaction snapshot path failed safety check; leaving it in place'; return 1; }
    [[ $(safe_realpath "$PENDING_TRANSACTION_SNAPSHOT_DIR") != $(safe_realpath "$PENDING_STATE_DIR") ]] || { warn 'Refusing to remove the state root as a transaction snapshot'; return 1; }
    [[ $(basename -- "$PENDING_TRANSACTION_SNAPSHOT_DIR") == .prestage.* ]] || { warn 'Transaction snapshot name failed safety check; leaving it in place'; return 1; }
    rm -rf -- "$PENDING_TRANSACTION_SNAPSHOT_DIR"
}

rollback_pending_grub_to_limine() {
    detect_bootloader
    [[ $BOOTLOADER == grub ]] || { fail 'GRUB -> Limine rollback is allowed only while booted through the recorded source GRUB entry'; return 1; }
    [[ $BOOT_CURRENT == "$PENDING_OLD_BOOT_ID" ]] || { fail "Rollback requires BootCurrent=Boot$PENDING_OLD_BOOT_ID"; return 1; }
    run_validation preflight || return 1
    verify_pending_source_recovery_unchanged || return 1
    verify_pending_candidate_ownership_unchanged || return 1

    local next answer current_hash
    next=$(efibootmgr 2>/dev/null | awk -F': ' '/^BootNext:/ {print toupper($2); exit}')
    if [[ -n $next && $next != "$PENDING_TARGET_BOOT_ID" ]]; then fail "BootNext belongs to Boot$next, not this transaction; refusing rollback"; return 1; fi
    printf '\nRollback will remove only target Limine state that this transaction created.\n'
    read -r -p 'Type ROLLBACK to abandon the staged Limine candidate: ' answer
    [[ $answer == ROLLBACK ]] || { printf 'Rollback cancelled.\n'; return 0; }

    [[ -n $next ]] && sudo efibootmgr -N >/dev/null 2>&1 || true
    set_source_first_boot_order "$PENDING_OLD_BOOT_ID" "$PENDING_TARGET_BOOT_ID" "$PENDING_ORIGINAL_BOOT_ORDER" || return 1
    rollback_pending_fallback_state || return 1
    if boot_id_exists "$PENDING_TARGET_BOOT_ID"; then
        nvram_id_matches_path "$PENDING_TARGET_BOOT_ID" "$PENDING_TARGET_EFI_PATH" || { fail 'Target NVRAM path changed; refusing deletion'; return 1; }
        sudo efibootmgr -b "$PENDING_TARGET_BOOT_ID" -B >/dev/null || return 1
        ok "Removed staged Limine NVRAM entry Boot$PENDING_TARGET_BOOT_ID"
    fi
    if sudo -n test -f "$PENDING_TARGET_EFI_RESOLVED" 2>/dev/null; then
        current_hash=$(sudo -n sha256sum -- "$PENDING_TARGET_EFI_RESOLVED" 2>/dev/null | awk '{print $1}' || true)
        [[ $current_hash == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'Target Limine EFI changed; refusing deletion'; return 1; }
        sudo rm -f -- "$PENDING_TARGET_EFI_RESOLVED" || return 1
        sudo rmdir -- "$(dirname -- "$PENDING_TARGET_EFI_RESOLVED")" 2>/dev/null || true
    fi
    if sudo -n test -f "$PENDING_LIMINE_CONF_PATH" 2>/dev/null; then sudo rm -f -- "$PENDING_LIMINE_CONF_PATH" || return 1; fi
    if sudo -n test -d "$PENDING_LIMINE_MANAGED_DIR" 2>/dev/null; then sudo rm -rf -- "$PENDING_LIMINE_MANAGED_DIR" || return 1; fi
    if [[ $PENDING_LIMINE_DEFAULT_CREATED == 1 && -f /etc/default/limine ]]; then sudo rm -f -- /etc/default/limine || return 1; fi
    remove_pending_transaction_snapshot || warn 'Could not remove private transaction snapshot directory'
    rm -f -- "$PENDING_STATE_FILE"
    ok 'Staged Limine candidate rolled back. GRUB boot state remains active.'
}

rollback_pending_limine_to_grub() {
    detect_bootloader
    [[ $BOOTLOADER == limine ]] || { fail 'Limine -> GRUB rollback is allowed only while booted through the recorded source Limine entry'; return 1; }
    [[ $BOOT_CURRENT == "$PENDING_OLD_BOOT_ID" ]] || { fail "Rollback requires BootCurrent=Boot$PENDING_OLD_BOOT_ID"; return 1; }
    run_validation preflight || return 1
    verify_pending_source_recovery_unchanged || return 1
    verify_pending_candidate_ownership_unchanged || return 1

    local next answer hash path
    next=$(efibootmgr 2>/dev/null | awk -F': ' '/^BootNext:/ {print toupper($2); exit}')
    if [[ -n $next && $next != "$PENDING_TARGET_BOOT_ID" ]]; then fail "BootNext belongs to Boot$next, not this transaction; refusing rollback"; return 1; fi
    printf '\nRollback will remove only GRUB state proven to belong to this transaction.\n'
    printf 'Limine remains the active source and will remain first in BootOrder.\n'
    read -r -p 'Type ROLLBACK to abandon the staged GRUB candidate: ' answer
    [[ $answer == ROLLBACK ]] || { printf 'Rollback cancelled.\n'; return 0; }

    [[ -n $next ]] && sudo efibootmgr -N >/dev/null 2>&1 || true
    set_source_first_boot_order "$PENDING_OLD_BOOT_ID" "$PENDING_TARGET_BOOT_ID" "$PENDING_ORIGINAL_BOOT_ORDER" || return 1
    rollback_pending_fallback_state || return 1

    if boot_id_exists "$PENDING_TARGET_BOOT_ID"; then
        nvram_id_matches_path "$PENDING_TARGET_BOOT_ID" "$PENDING_TARGET_EFI_PATH" || { fail 'Target GRUB NVRAM path changed; refusing deletion'; return 1; }
        sudo efibootmgr -b "$PENDING_TARGET_BOOT_ID" -B >/dev/null || return 1
        ok "Removed staged GRUB NVRAM entry Boot$PENDING_TARGET_BOOT_ID"
    fi

    # Exact tree manifests were verified above; recursive removal is therefore
    # limited to namespaces that were absent before staging and are unchanged.
    sudo rm -rf -- "$PENDING_GRUB_EFI_DIR" || return 1
    ok 'Removed unchanged transaction-owned GRUB EFI namespace'
    sudo rm -rf -- "$PENDING_GRUB_DIR" || return 1
    ok 'Removed unchanged transaction-owned /boot/grub tree'

    if [[ $PENDING_FORMAT == 3 ]]; then
        while IFS=$'\t' read -r hash path; do
            [[ -n $hash && -n $path ]] || continue
            local current_hash
            current_hash=$(sudo -n sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || true)
            [[ $current_hash == "$hash" ]] || { fail "GRUB artifact changed before rollback: $path"; return 1; }
            sudo rm -f -- "$path" || return 1
            ok "Removed unchanged transaction-owned GRUB boot artifact: $path"
        done <"$PENDING_GRUB_ARTIFACT_MANIFEST"
    else
        local ownership
        while IFS=$'\t' read -r ownership hash path; do
            [[ -n $ownership && -n $hash && -n $path ]] || continue
            local current_hash
            current_hash=$(sudo -n sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || true)
            [[ $current_hash == "$hash" ]] || { fail "GRUB artifact changed before rollback: $path"; return 1; }
            case "$ownership" in
                created)
                    sudo rm -f -- "$path" || return 1
                    ok "Removed unchanged transaction-created GRUB boot artifact: $path"
                    ;;
                shared)
                    ok "Preserved unchanged source-shared boot artifact: $path"
                    ;;
                *) fail "Unknown GRUB artifact ownership marker: $ownership"; return 1 ;;
            esac
        done <"$PENDING_GRUB_ARTIFACT_MANIFEST"
    fi

    if [[ $PENDING_GRUB_DEFAULT_CREATED == 1 && -f /etc/default/grub ]]; then
        local current_default
        current_default=$(sha256sum /etc/default/grub 2>/dev/null | awk '{print $1}' || sudo -n sha256sum /etc/default/grub 2>/dev/null | awk '{print $1}' || true)
        [[ $current_default == "$PENDING_GRUB_DEFAULT_HASH" ]] || { fail '/etc/default/grub changed before rollback; refusing deletion'; return 1; }
        sudo rm -f -- /etc/default/grub || return 1
        ok 'Removed unchanged transaction-owned /etc/default/grub'
    fi

    remove_pending_transaction_snapshot || warn 'Could not remove private transaction snapshot directory'
    rm -f -- "$PENDING_STATE_FILE"
    ok 'Staged GRUB candidate rolled back. Limine boot state remains active.'
}

rollback_pending_candidate() {
    validate_pending_compatibility || { fail "Pending migration is not compatible: $PENDING_REASON"; return 1; }
    case "$PENDING_SOURCE:$PENDING_TARGET" in
        grub:limine) rollback_pending_grub_to_limine ;;
        limine:grub) rollback_pending_limine_to_grub ;;
        *) fail 'Unsupported staged rollback direction'; return 1 ;;
    esac
}

validate_pending_target_deep() {
    case "$PENDING_TARGET" in
        limine) validate_target_state limine && validate_limine_boot_chain migration ;;
        grub) validate_target_state grub && validate_grub_boot_chain migration ;;
        *) fail 'Deep validation is not implemented for this staged target'; return 1 ;;
    esac
}

pending_bootnext_id() {
    efibootmgr 2>/dev/null | awk -F': ' '/^BootNext:/ {print toupper($2); exit}'
}

pending_bootorder_first() {
    local order
    order=$(efibootmgr 2>/dev/null | awk -F': ' '/^BootOrder:/ {print toupper($2); exit}')
    printf '%s\n' "${order%%,*}"
}

pending_normalize_cmdline() {
    local input=$1 token
    for token in $input; do
        case "$token" in
            BOOT_IMAGE=*|boot_image=*|initrd=*) continue ;;
        esac
        printf '%s\n' "$token"
    done | LC_ALL=C sort -u
}

pending_cmdline_equivalent() {
    local left right
    left=$(pending_normalize_cmdline "$1")
    right=$(pending_normalize_cmdline "$2")
    [[ $left == "$right" ]]
}

pending_cmdline_first_token() {
    local cmdline=$1 pattern=$2 token
    for token in $cmdline; do
        case "$token" in
            $pattern) printf '%s\n' "$token"; return 0 ;;
        esac
    done
    return 1
}

pending_validate_running_kernel() {
    local running ver
    running=$(uname -r 2>/dev/null || true)
    [[ -n $running ]] || { fail 'Could not determine the currently running kernel release'; return 1; }
    collect_kernels
    for ver in "${KERNEL_VERSIONS[@]}"; do
        if [[ $ver == "$running" ]]; then
            ok "Running kernel release is one of the installed validated kernels ($running)"
            return 0
        fi
    done
    fail "Running kernel release $running is not present in the installed kernel set"
    return 1
}

pending_validate_runtime_cmdline_against_source() {
    local current source_root current_root source_mode current_mode
    current=$(cat /proc/cmdline 2>/dev/null || true)
    [[ -n $current ]] || { fail 'Current /proc/cmdline is empty; runtime proof cannot continue'; return 1; }
    [[ -n $PENDING_SOURCE_CMDLINE ]] || { fail 'Recorded known-good source cmdline is unavailable'; return 1; }

    if pending_cmdline_equivalent "$PENDING_SOURCE_CMDLINE" "$current"; then
        ok 'Actual target /proc/cmdline is token-equivalent to the recorded known-good source cmdline'
    else
        fail 'Actual target /proc/cmdline differs from the recorded known-good source cmdline'
        printf '       recorded source: %s\n' "$PENDING_SOURCE_CMDLINE"
        printf '       current target:  %s\n' "$current"
        return 1
    fi

    source_root=$(pending_cmdline_first_token "$PENDING_SOURCE_CMDLINE" 'root=*' 2>/dev/null || true)
    current_root=$(pending_cmdline_first_token "$current" 'root=*' 2>/dev/null || true)
    if [[ -n $source_root && $current_root == "$source_root" ]]; then
        ok "Runtime root argument matches the recorded source ($current_root)"
    elif [[ -n $source_root ]]; then
        fail "Runtime root argument changed: source=$source_root current=${current_root:-missing}"
        return 1
    fi

    source_mode=$(pending_cmdline_first_token "$PENDING_SOURCE_CMDLINE" 'rw' 2>/dev/null || pending_cmdline_first_token "$PENDING_SOURCE_CMDLINE" 'ro' 2>/dev/null || true)
    current_mode=$(pending_cmdline_first_token "$current" 'rw' 2>/dev/null || pending_cmdline_first_token "$current" 'ro' 2>/dev/null || true)
    if [[ -n $source_mode && $current_mode == "$source_mode" ]]; then
        ok "Runtime root mount-mode token matches the recorded source ($current_mode)"
    elif [[ -n $source_mode ]]; then
        fail "Runtime root mount-mode changed: source=$source_mode current=${current_mode:-missing}"
        return 1
    fi

    if [[ $current_root == root=UUID=* && -n ${PENDING_ROOT_UUID:-} ]]; then
        if [[ ${current_root#root=UUID=} == "$PENDING_ROOT_UUID" ]]; then
            ok 'Runtime root=UUID identity matches the transaction root filesystem UUID'
        else
            fail "Runtime root UUID (${current_root#root=UUID=}) does not match transaction root UUID $PENDING_ROOT_UUID"
            return 1
        fi
    fi
    return 0
}

pending_capture_runtime_diagnostics() {
    local phase=${1:-runtime} dir target_diag=''
    case "$PENDING_TARGET" in
        grub) target_diag=$(capture_grub_diagnostics "$phase" 2>/dev/null | tail -n1 || true) ;;
        limine) target_diag=$(capture_limine_diagnostics "$phase" 2>/dev/null | tail -n1 || true) ;;
    esac
    if [[ -n $target_diag && -d $target_diag ]]; then
        dir=$target_diag
    else
        dir="$HOME/cachyos-bootloader-diagnostics/$(date +%Y%m%d-%H%M%S)-$phase"
        mkdir -p -- "$dir" || return 1
        chmod 700 -- "$dir" 2>/dev/null || true
    fi
    printf '%s\n' "$PENDING_SOURCE_CMDLINE" >"$dir/recorded-source-cmdline.txt" 2>/dev/null || true
    cat /proc/cmdline >"$dir/runtime-target-cmdline.txt" 2>/dev/null || true
    uname -a >"$dir/uname-a.txt" 2>&1 || true
    efibootmgr -v >"$dir/efibootmgr-runtime-v.txt" 2>&1 || true
    printf '%s\n' "$dir"
}

arm_pending_one_time_boot() {
    validate_pending_compatibility || { fail "Pending migration is not compatible: $PENDING_REASON"; return 1; }
    [[ $PENDING_PHASE == candidate-ready ]] || { fail "One-time boot can only be armed from candidate-ready (current phase: $PENDING_PHASE)"; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == "$PENDING_SOURCE" && $BOOT_CURRENT == "$PENDING_OLD_BOOT_ID" ]] || {
        fail "Arming requires the recorded source $(bootloader_display_name "$PENDING_SOURCE") Boot$PENDING_OLD_BOOT_ID to be running"
        return 1
    }

    run_validation preflight || return 1
    validate_pending_compatibility || { fail "Pending migration became incompatible during preflight: $PENDING_REASON"; return 1; }
    verify_pending_source_recovery_unchanged || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    printf '\nRe-validating the candidate immediately before BootNext arming:\n'
    validate_pending_target_deep || { fail 'Candidate deep validation failed; BootNext was NOT set'; return 1; }

    local next first answer
    next=$(pending_bootnext_id)
    [[ -z $next ]] || { fail "BootNext is already set to Boot$next; refusing to overwrite firmware intent"; return 1; }
    first=$(pending_bootorder_first)
    [[ $first == "$PENDING_OLD_BOOT_ID" ]] || { fail "Persistent BootOrder no longer starts with source Boot$PENDING_OLD_BOOT_ID"; return 1; }
    nvram_id_matches_path "$PENDING_TARGET_BOOT_ID" "$PENDING_TARGET_EFI_PATH" || { fail 'Target NVRAM entry no longer has the recorded exact EFI path'; return 1; }

    printf '\nOne-time boot transaction:\n'
    printf '  Persistent BootOrder stays source-first: Boot%s (%s)\n' "$PENDING_OLD_BOOT_ID" "$(bootloader_display_name "$PENDING_SOURCE")"
    printf '  BootNext will be set once to:           Boot%s (%s)\n' "$PENDING_TARGET_BOOT_ID" "$(bootloader_display_name "$PENDING_TARGET")"
    printf '  Source cleanup remains locked until this exact candidate passes post-boot runtime validation.\n'
    printf '  If the target does not boot, the next normal firmware boot returns to the source BootOrder.\n\n'
    read -r -p 'Type ARM to set the one-time BootNext entry, or anything else to cancel: ' answer
    [[ $answer == ARM ]] || { printf 'BootNext arming cancelled.\n'; return 0; }

    sudo efibootmgr -n "$PENDING_TARGET_BOOT_ID" >/dev/null || { fail 'efibootmgr could not set BootNext'; return 1; }
    next=$(pending_bootnext_id)
    if [[ $next != "$PENDING_TARGET_BOOT_ID" ]]; then
        sudo efibootmgr -N >/dev/null 2>&1 || true
        fail "BootNext verification failed after arming (expected Boot$PENDING_TARGET_BOOT_ID, found ${next:-none})"
        return 1
    fi
    if ! pending_set_phase boot-armed; then
        sudo efibootmgr -N >/dev/null 2>&1 || true
        fail 'Could not persist boot-armed transaction phase; BootNext was cleared for safety'
        return 1
    fi
    ok "BootNext is armed exactly once for target Boot$PENDING_TARGET_BOOT_ID"
    ok "Persistent BootOrder remains source Boot$PENDING_OLD_BOOT_ID first"
    printf '\nOne-time test boot is ARMED. r21 will not reboot automatically.\n'
    printf 'Reboot normally when ready. After the target boots, run this tool and choose:\n'
    printf '  [2] Manage pending/staged migration\n'
    printf 'Then run the post-boot runtime validation before any further reboot.\n'
}

cancel_pending_one_time_boot() {
    validate_pending_compatibility || return 1
    [[ $PENDING_PHASE == boot-armed ]] || { fail 'No boot-armed transaction is pending'; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == "$PENDING_SOURCE" && $BOOT_CURRENT == "$PENDING_OLD_BOOT_ID" ]] || { fail 'BootNext cancellation is allowed only while the recorded source is still running'; return 1; }
    local next answer
    next=$(pending_bootnext_id)
    [[ $next == "$PENDING_TARGET_BOOT_ID" ]] || { fail "Expected BootNext=Boot$PENDING_TARGET_BOOT_ID, found ${next:-none}; refusing to clear unrelated firmware state"; return 1; }
    read -r -p 'Type CANCEL to clear this transaction BootNext and return to candidate-ready: ' answer
    [[ $answer == CANCEL ]] || { printf 'Cancellation aborted.\n'; return 0; }
    sudo efibootmgr -N >/dev/null || return 1
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext is still present after cancellation'; return 1; }
    pending_set_phase candidate-ready || { fail 'BootNext cleared but pending phase update failed; inspect the state file before proceeding'; return 1; }
    ok 'One-time BootNext cleared; candidate returned to candidate-ready state'
}

reset_consumed_test_to_candidate_ready() {
    validate_pending_compatibility || return 1
    [[ $PENDING_PHASE == boot-armed ]] || return 1
    detect_bootloader
    [[ $BOOTLOADER == "$PENDING_SOURCE" && $BOOT_CURRENT == "$PENDING_OLD_BOOT_ID" ]] || { fail 'Reset requires the recorded source bootloader to be active'; return 1; }
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext is still set; this test has not been consumed/cleared'; return 1; }
    run_validation preflight || return 1
    verify_pending_source_recovery_unchanged || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1
    pending_set_phase candidate-ready || return 1
    ok 'No target runtime proof was recorded; transaction safely returned to candidate-ready for another test or rollback'
}

validate_pending_target_runtime() {
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

    local next first diag
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
    printf '\nRUNTIME-VALIDATED %s -> %s one-time boot succeeded.\n' "$(bootloader_display_name "$PENDING_SOURCE")" "$(bootloader_display_name "$PENDING_TARGET")"
    printf 'BootCurrent proves the recorded target EFI entry actually booted.\n'
    printf 'The actual target /proc/cmdline matches the recorded known-good source cmdline.\n'
    printf 'Persistent BootOrder is still source-first and BootNext is clear.\n'
    if declare -F r21_theme_required >/dev/null 2>&1 && r21_theme_required; then
        printf 'This exact CachyOS-themed target state now has runtime proof. FINALIZE is eligible from Manage pending/staged migration.\n'
    else
        printf 'This runtime proof predates r21 CachyOS theme parity. FINALIZE remains locked until the themed candidate is rebuilt and re-tested.\n'
    fi
}

manage_pending_migration() {
    pending_exists || { printf '\nNo pending/staged migration exists.\n'; return 0; }
    validate_pending_compatibility || { printf '\nPending migration state is invalid/incompatible: %s\n' "$PENDING_REASON"; return 1; }
    detect_bootloader
    show_pending_details

    if [[ $BOOTLOADER == "$PENDING_TARGET" ]]; then
        case "$PENDING_PHASE" in
            boot-armed)
                printf '\nThe one-time target boot is running now. No source cleanup is allowed.\n'
                printf '[1] Run post-boot runtime validation\n'
                printf '[2] Back\n\n'
                local choice
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) validate_pending_target_runtime ;;
                    2|'') return 0 ;;
                    *) printf 'Invalid selection.\n'; return 1 ;;
                esac
                ;;
            runtime-validated)
                printf '\nThis target boot already passed the r20 runtime gate. FINALIZE remains locked.\n'
                printf '[1] Re-run runtime validation\n'
                printf '[2] Back\n\n'
                local choice
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) validate_pending_target_runtime ;;
                    2|'') return 0 ;;
                    *) printf 'Invalid selection.\n'; return 1 ;;
                esac
                ;;
            candidate-ready)
                printf '\nThe target was booted without this transaction being armed by r20.\n'
                printf 'This session is NOT accepted as runtime proof. Persistent source cleanup remains locked.\n'
                printf 'Reboot normally to the source (which is still first in BootOrder), then arm the test through this menu.\n'
                return 1
                ;;
        esac
    elif [[ $BOOTLOADER == "$PENDING_SOURCE" ]]; then
        case "$PENDING_PHASE" in
            candidate-ready)
                printf '\nThe source %s bootloader is active and the candidate is parked.\n' "$(bootloader_display_name "$PENDING_SOURCE")"
                printf '[1] Re-run deep validation of the staged %s candidate\n' "$(bootloader_display_name "$PENDING_TARGET")"
                printf '[2] Arm one-time test boot to %s (BootNext only)\n' "$(bootloader_display_name "$PENDING_TARGET")"
                printf '[3] Roll back the staged %s candidate\n' "$(bootloader_display_name "$PENDING_TARGET")"
                printf '[4] Back\n\n'
                local choice
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) run_validation preflight && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep ;;
                    2) arm_pending_one_time_boot ;;
                    3) rollback_pending_candidate ;;
                    4|'') return 0 ;;
                    *) printf 'Invalid selection.\n'; return 1 ;;
                esac
                ;;
            boot-armed)
                local next choice
                next=$(pending_bootnext_id)
                if [[ $next == "$PENDING_TARGET_BOOT_ID" ]]; then
                    printf '\nOne-time target boot is ARMED and waiting for the next reboot.\n'
                    printf '[1] Re-check source/candidate integrity (leave BootNext armed)\n'
                    printf '[2] Cancel this one-time BootNext and return to candidate-ready\n'
                    printf '[3] Roll back the staged candidate\n'
                    printf '[4] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in
                        1) run_validation preflight && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged ;;
                        2) cancel_pending_one_time_boot ;;
                        3) rollback_pending_candidate ;;
                        4|'') return 0 ;;
                        *) printf 'Invalid selection.\n'; return 1 ;;
                    esac
                elif [[ -z $next ]]; then
                    printf '\nThe transaction is marked boot-armed, but BootNext is no longer present and the source is active.\n'
                    printf 'No target runtime success was recorded. The one-time request was consumed/cleared or the target did not reach validation.\n'
                    printf '[1] Revalidate everything and return to candidate-ready\n'
                    printf '[2] Roll back the staged candidate\n'
                    printf '[3] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in
                        1) reset_consumed_test_to_candidate_ready ;;
                        2) rollback_pending_candidate ;;
                        3|'') return 0 ;;
                        *) printf 'Invalid selection.\n'; return 1 ;;
                    esac
                else
                    printf '\nBootNext belongs to unrelated Boot%s. r20 will not touch it.\n' "$next"
                    return 1
                fi
                ;;
            runtime-validated)
                printf '\nA successful target runtime proof is already recorded, but the source is active again because persistent BootOrder remained source-first.\n'
                printf 'r20 still does not expose FINALIZE/source cleanup.\n'
                printf '[1] Re-check source and candidate ownership\n'
                printf '[2] Roll back/abandon the staged target\n'
                printf '[3] Back\n\n'
                local choice
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) run_validation preflight && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged ;;
                    2) rollback_pending_candidate ;;
                    3|'') return 0 ;;
                    *) printf 'Invalid selection.\n'; return 1 ;;
                esac
                ;;
        esac
    else
        printf '\nCurrent bootloader is neither the recorded source nor target. Pending migration management is refused.\n'
        return 1
    fi
}
