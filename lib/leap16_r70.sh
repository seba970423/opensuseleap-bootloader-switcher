#!/usr/bin/env bash
# openSUSE Leap 16 r70
#
# rEFInd backup metadata literal-path fix.
#
# r64 compared the decoded canonical BootCurrent EFI path with an unquoted
# lowercased RHS inside [[ ... == ... ]].  In Bash the unquoted RHS is a pattern,
# so the backslashes in a firmware path such as \EFI\refind\refind_x64.efi are
# consumed as pattern escapes.  Identical raw EFI paths can therefore compare
# unequal.  r70 keeps the entire backup schema/payload contract unchanged and
# makes only the identity comparison literal.

leap16_r70_efi_path_equal_ci() {
    local actual=${1-} expected=${2-}
    [[ -n $actual && -n $expected && ${actual,,} == "${expected,,}" ]]
}

# Preserve the effective r69 validator for every non-rEFInd backup.  Re-state
# only the rEFInd identity branch so the raw firmware path is compared as data,
# not as a Bash glob pattern.  The effective r67/r66 payload validator remains
# in force through leap16_r64_refind_backup_payload_valid().
if declare -F validate_backup >/dev/null 2>&1; then
    eval "$(declare -f validate_backup | sed '1s/validate_backup/validate_backup_pre_leap16_r70/')"
fi
validate_backup() {
    local dir=$1

    unset format_version backup_platform backup_schema switcher_release bootloader payload_policy \
          created_epoch created_iso hostname machine_id esp_source esp_mount esp_uuid \
          root_source root_uuid boot_current boot_label boot_efi_path

    if load_backup_metadata "$dir" 2>/dev/null && [[ ${bootloader:-} != refind ]]; then
        validate_backup_pre_leap16_r70 "$dir"
        return $?
    fi

    BACKUP_VALIDATION_REASON=''
    declare -F validate_backup_pre_leap16_r31 >/dev/null 2>&1 \
        || { BACKUP_VALIDATION_REASON='structural backup validator unavailable'; return 1; }
    validate_backup_pre_leap16_r31 "$dir" || return 1
    load_backup_metadata "$dir" || { BACKUP_VALIDATION_REASON='metadata format is invalid'; return 1; }

    [[ ${format_version:-} == 4 ]] \
        || { BACKUP_VALIDATION_REASON='rEFInd backup requires self-contained format v4'; return 1; }
    [[ ${backup_platform:-} == "$LEAP16_R31_BACKUP_PLATFORM" ]] \
        || { BACKUP_VALIDATION_REASON='rEFInd backup is not from the Leap layer'; return 1; }
    [[ ${backup_schema:-} == "$LEAP16_R64_REFIND_BACKUP_SCHEMA" ]] \
        || { BACKUP_VALIDATION_REASON='unsupported Leap rEFInd backup schema'; return 1; }
    [[ ${bootloader:-} == refind ]] \
        || { BACKUP_VALIDATION_REASON='rEFInd validator received wrong backend'; return 1; }
    [[ ${payload_policy:-} == "$LEAP16_R64_REFIND_PAYLOAD_POLICY" ]] \
        || { BACKUP_VALIDATION_REASON='unexpected rEFInd backup payload policy'; return 1; }
    leap16_r70_efi_path_equal_ci "${boot_efi_path:-}" "$LEAP16_R64_REFIND_EFI" \
        || { BACKUP_VALIDATION_REASON='backup does not identify canonical rEFInd BootCurrent path'; return 1; }

    leap16_r64_refind_backup_payload_valid "$dir" || return 1
    BACKUP_VALIDATION_REASON='valid'
    return 0
}

# Keep the r69 implementation/proof matrix status and expose the r70 audit fix
# in the heading so hardware logs identify the effective revision accurately.
if declare -F leap16_r64_print_matrix >/dev/null 2>&1; then
    eval "$(declare -f leap16_r64_print_matrix | sed '1s/leap16_r64_print_matrix/leap16_r64_print_matrix_pre_leap16_r70/')"
fi
leap16_r64_print_matrix() {
    leap16_r64_print_matrix_pre_leap16_r70 | sed '1s/leap16-r69/leap16-r70/'
    printf '\nr70 backup fix: canonical rEFInd BootCurrent metadata is compared literally; raw UEFI backslashes are never interpreted as Bash pattern escapes.\n'
}
