#!/usr/bin/env bash
# leap16-r56: finish r55's recovered-source topology after a real canonical
# systemd-boot reboot, before allowing a fresh systemd-boot -> Limine attempt.
#
# r55 intentionally restored:
#   systemd-boot first, stranded Limine second, EFI/BOOT alias third,
# with EFI/BOOT still byte-identical to systemd-boot.  That is a safe recovery
# topology, not a clean finalized systemd source.  r56 adds the missing second
# half: after BootCurrent proves canonical systemd-boot, freeze exact stranded
# Limine ownership, persist a cleanup authorization checkpoint, then retire only
# that stranded Limine state and the redundant EFI/BOOT NVRAM alias.  EFI/BOOT
# bytes themselves remain systemd-boot.  Cleanup is idempotently resumable.

LEAP16_R56_SAFE_DETAIL_PREFIX='Recovered the stranded pre-transfer systemd-boot -> Limine state.'
LEAP16_R56_CLEANUP_DIR_NAME='.r56-recovered-source-cleanup'
LEAP16_R56_STATE_NAME='authorization.tsv'
LEAP16_R56_MANIFEST_NAME='stranded-limine-owned.tsv'

leap16_r56_cleanup_dir() { printf '%s/%s\n' "$PENDING_STATE_DIR" "$LEAP16_R56_CLEANUP_DIR_NAME"; }
leap16_r56_state_path() { printf '%s/%s\n' "$(leap16_r56_cleanup_dir)" "$LEAP16_R56_STATE_NAME"; }
leap16_r56_manifest_path() { printf '%s/%s\n' "$(leap16_r56_cleanup_dir)" "$LEAP16_R56_MANIFEST_NAME"; }

leap16_r56_state_value() {
    local key=$1 p
    p=$(leap16_r56_state_path)
    awk -F'\t' -v k="$key" '$1==k{print $2;exit}' "$p" 2>/dev/null
}

leap16_r56_safe_result_matches() {
    local status detail
    status=$(leap16_r55_last_result_value status 2>/dev/null || true)
    detail=$(leap16_r55_last_result_value detail 2>/dev/null || true)
    [[ $status == safe-fallback && $detail == "$LEAP16_R56_SAFE_DETAIL_PREFIX"* ]]
}

leap16_r56_exact_one_limine_id() {
    local ids
    ids=$(leap16_r48_ids_for_current_esp_path '\EFI\LIMINE\LIMINE_X64.EFI' | paste -sd, -)
    [[ -n $ids && $ids != *,* ]] || return 1
    printf '%s\n' "${ids^^}"
}

leap16_r56_exact_recovered_topology_quiet() {
    local systemd limine fallback order
    pending_exists && return 1
    leap16_r56_safe_result_matches || return 1
    detect_bootloader
    [[ ${BOOTLOADER:-} == systemd-boot && ${BOOT_CURRENT:-} =~ ^[0-9A-Fa-f]{4}$ ]] || return 1
    systemd=${BOOT_CURRENT^^}
    nvram_id_matches_path "$systemd" "$LEAP16_R32_SDBOOT_EFI" >/dev/null 2>&1 || return 1
    limine=$(leap16_r56_exact_one_limine_id 2>/dev/null) || return 1
    fallback=$(leap16_r55_exact_one_fallback_id 2>/dev/null) || return 1
    [[ $systemd != "$limine" && $systemd != "$fallback" && $limine != "$fallback" ]] || return 1
    order=$(leap16_current_boot_order 2>/dev/null || true)
    [[ $order == "$systemd,$limine,$fallback"* ]] || return 1
    return 0
}

leap16_r56_authorized() {
    local p m mh
    p=$(leap16_r56_state_path); m=$(leap16_r56_manifest_path)
    [[ -s $p && -s $m ]] || return 1
    [[ $(leap16_r56_state_value format) == 1 && $(leap16_r56_state_value purpose) == r55-recovered-source-cleanup ]] || return 1
    mh=$(sha256sum -- "$m" 2>/dev/null | awk '{print $1}' || true)
    [[ $mh =~ ^[0-9A-Fa-f]{64}$ && $mh == $(leap16_r56_state_value limine_manifest_hash) ]] || return 1
    return 0
}

leap16_r56_validate_systemd_anchor() {
    local systemd expected hash fallback_hash
    systemd=$(leap16_r56_state_value systemd_boot_id); systemd=${systemd^^}
    expected=$(leap16_r56_state_value systemd_efi_hash)
    [[ $systemd =~ ^[0-9A-F]{4}$ && $expected =~ ^[0-9A-Fa-f]{64}$ ]] || { fail 'r56 cleanup authorization has invalid systemd anchor metadata'; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == "$systemd" ]] || { fail "Recovered-source cleanup must run from canonical systemd-boot Boot$systemd"; return 1; }
    nvram_id_matches_path "$systemd" "$LEAP16_R32_SDBOOT_EFI" || { fail "Canonical systemd-boot Boot$systemd changed EFI path"; return 1; }
    leap16_nvram_entry_matches_current_esp "$systemd" || { fail "Canonical systemd-boot Boot$systemd changed ESP binding"; return 1; }
    hash=$(r21_hash_privileged "${ESP_MOUNT%/}/EFI/systemd/systemd-bootx64.efi")
    [[ $hash == "$expected" ]] || { fail 'Canonical systemd-boot EFI bytes changed after cleanup authorization'; return 1; }
    leap16_r34_validate_systemd_boot_chain recovery || return 1
    fallback_hash=$(r21_hash_privileged "${ESP_MOUNT%/}/EFI/BOOT/BOOTX64.EFI")
    [[ $fallback_hash == "$expected" ]] || { fail 'EFI/BOOT is no longer byte-identical to the recovered systemd-boot source'; return 1; }
    return 0
}

leap16_r56_write_limine_manifest() {
    local dir manifest saved had=0 path
    dir=$(leap16_r56_cleanup_dir); manifest=$(leap16_r56_manifest_path)
    mkdir -p -- "$dir" || return 1
    chmod 700 -- "$dir" 2>/dev/null || true
    [[ ! -e $manifest ]] || { fail 'r56 cleanup manifest unexpectedly already exists before authorization'; return 1; }
    if [[ ${TRANSACTION_SNAPSHOT_DIR+x} ]]; then saved=$TRANSACTION_SNAPSHOT_DIR; had=1; fi
    TRANSACTION_SNAPSHOT_DIR=$dir
    : >"$manifest" || return 1
    while IFS= read -r path; do
        [[ -n $path ]] || continue
        r26_record_owned_path "$manifest" "$path" || {
            rm -f -- "$manifest"
            if ((had)); then TRANSACTION_SNAPSHOT_DIR=$saved; else unset TRANSACTION_SNAPSHOT_DIR; fi
            return 1
        }
    done < <(r26_adapter_paths limine)
    if ((had)); then TRANSACTION_SNAPSHOT_DIR=$saved; else unset TRANSACTION_SNAPSHOT_DIR; fi
    [[ -s $manifest ]] || { fail 'Could not freeze any stranded Limine-owned state'; return 1; }
}

leap16_r56_authorize_cleanup() {
    local dir state manifest tmp systemd limine fallback order sh lh fh mh diag old_staging=${LEAP16_R51_STAGING:-0}
    leap16_r56_exact_recovered_topology_quiet || { fail 'The exact r55 recovered-source topology is not present'; return 1; }
    leap16_require_sudo_session || return 1
    detect_bootloader
    run_validation preflight || return 1
    [[ -z ${BOOT_NEXT:-} ]] || { fail "BootNext=Boot${BOOT_NEXT^^} exists; refusing recovered-source cleanup"; return 1; }
    systemd=${BOOT_CURRENT^^}
    limine=$(leap16_r56_exact_one_limine_id) || { fail 'Expected exactly one stranded canonical Limine alias'; return 1; }
    fallback=$(leap16_r55_exact_one_fallback_id) || { fail 'Expected exactly one redundant same-ESP EFI/BOOT alias'; return 1; }
    order=$(leap16_current_boot_order)

    leap16_r34_validate_systemd_boot_chain recovery || return 1
    leap16_r55_systemd_recovery_bytes_exact || return 1
    LEAP16_R51_STAGING=1
    validate_limine_boot_chain recovery || { LEAP16_R51_STAGING=$old_staging; fail 'Stranded Limine recovery installation failed exact validation'; return 1; }
    LEAP16_R51_STAGING=$old_staging
    leap16_nvram_entry_matches_current_esp "$limine" || { fail "Stranded Limine Boot$limine changed ESP binding"; return 1; }
    nvram_id_matches_path "$limine" '\EFI\LIMINE\LIMINE_X64.EFI' || { fail "Stranded Limine Boot$limine changed EFI path"; return 1; }
    leap16_nvram_entry_matches_current_esp "$fallback" || { fail "Fallback Boot$fallback changed ESP binding"; return 1; }
    nvram_id_matches_path "$fallback" "$LEAP16_R21_FALLBACK_EFI_PATH" || { fail "Fallback Boot$fallback changed EFI path"; return 1; }

    sh=$(r21_hash_privileged "${ESP_MOUNT%/}/EFI/systemd/systemd-bootx64.efi")
    lh=$(r21_hash_privileged "${ESP_MOUNT%/}/EFI/LIMINE/LIMINE_X64.EFI")
    fh=$(r21_hash_privileged "${ESP_MOUNT%/}/EFI/BOOT/BOOTX64.EFI")
    [[ $sh =~ ^[0-9A-Fa-f]{64}$ && $lh =~ ^[0-9A-Fa-f]{64}$ && $fh == "$sh" && $lh != "$sh" ]] \
        || { fail 'Recovered systemd/Limine/fallback byte ownership is not the expected pre-transfer topology'; return 1; }

    diag=$(leap16_capture_diagnostics r56-recovered-source-pre-cleanup 2>/dev/null || true)
    [[ -n $diag ]] && printf 'Pre-cleanup diagnostic snapshot: %s\n' "$diag" || warn 'Could not capture pre-cleanup diagnostics'

    dir=$(leap16_r56_cleanup_dir); state=$(leap16_r56_state_path); manifest=$(leap16_r56_manifest_path)
    rm -rf -- "$dir" 2>/dev/null || true
    mkdir -p -- "$dir" || return 1
    chmod 700 -- "$dir" 2>/dev/null || true
    leap16_r56_write_limine_manifest || return 1
    mh=$(sha256sum -- "$manifest" | awk '{print $1}')
    tmp="$state.tmp.$$"
    {
        printf 'format\t1\n'
        printf 'purpose\tr55-recovered-source-cleanup\n'
        printf 'systemd_boot_id\t%s\n' "$systemd"
        printf 'limine_boot_id\t%s\n' "$limine"
        printf 'fallback_boot_id\t%s\n' "$fallback"
        printf 'esp_uuid\t%s\n' "$ESP_UUID"
        printf 'root_uuid\t%s\n' "$ROOT_UUID"
        printf 'original_boot_order\t%s\n' "$order"
        printf 'systemd_efi_hash\t%s\n' "$sh"
        printf 'limine_efi_hash\t%s\n' "$lh"
        printf 'fallback_hash\t%s\n' "$fh"
        printf 'limine_manifest_hash\t%s\n' "$mh"
        printf 'authorized_at\t%s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
    } >"$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 600 -- "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$state" || { rm -f -- "$tmp"; return 1; }
    ok 'Persisted RECOVERED-SOURCE-CLEANUP-AUTHORIZED checkpoint after a real canonical systemd-boot reboot'
}

leap16_r56_manifest_remaining_is_owned_subset() {
    local record kind path identity actual mf
    record=$(leap16_r56_manifest_path)
    [[ -s $record ]] || { fail 'r56 stranded Limine ownership manifest is missing'; return 1; }
    while IFS=$'\t' read -r kind path identity; do
        [[ -n $kind && -n $path && -n $identity ]] || return 1
        case "$kind" in
            file)
                if ! sudo -n test -e "$path" 2>/dev/null && ! sudo -n test -L "$path" 2>/dev/null && [[ ! -e $path && ! -L $path ]]; then
                    continue
                fi
                actual=$(sudo -n sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || true)
                [[ $actual == "$identity" ]] || { fail "Remaining stranded Limine file changed after cleanup authorization: $path"; return 1; }
                ;;
            tree)
                mf="$(dirname -- "$record")/$identity"
                leap16_r54_tree_remaining_is_owned_subset "$path" "$mf" || return 1
                ;;
            *) fail "Unknown r56 ownership record type: $kind"; return 1 ;;
        esac
    done <"$record"
}

leap16_r56_remove_manifest_idempotent() {
    local record kind path identity
    record=$(leap16_r56_manifest_path)
    leap16_r56_manifest_remaining_is_owned_subset || return 1
    while IFS=$'\t' read -r kind path identity; do
        case "$kind" in
            file)
                if sudo -n test -e "$path" 2>/dev/null || sudo -n test -L "$path" 2>/dev/null || [[ -e $path || -L $path ]]; then
                    sudo rm -f -- "$path" || return 1
                    ok "Retired stranded ownership-proven Limine path: $path"
                fi
                ;;
            tree)
                if sudo -n test -e "$path" 2>/dev/null || sudo -n test -L "$path" 2>/dev/null || [[ -e $path || -L $path ]]; then
                    sudo rm -rf -- "$path" || return 1
                    ok "Retired stranded ownership-proven Limine path: $path"
                fi
                ;;
        esac
    done <"$record"
    leap16_r47_cleanup_empty_machine_id_parent || true
}

leap16_r56_order_without_recovery_aliases() {
    local systemd limine fallback order id joined
    local -a current=() out=()
    systemd=$(leap16_r56_state_value systemd_boot_id); systemd=${systemd^^}
    limine=$(leap16_r56_state_value limine_boot_id); limine=${limine^^}
    fallback=$(leap16_r56_state_value fallback_boot_id); fallback=${fallback^^}
    order=$(leap16_current_boot_order) || return 1
    out=("$systemd")
    IFS=',' read -ra current <<<"$order"
    for id in "${current[@]}"; do
        id=${id^^}
        [[ -n $id && $id != "$systemd" && $id != "$limine" && $id != "$fallback" ]] || continue
        boot_id_exists "$id" && out+=("$id")
    done
    joined=$(IFS=,; printf '%s' "${out[*]}")
    sudo efibootmgr -o "$joined" >/dev/null || return 1
    order=$(leap16_current_boot_order)
    [[ ${order%%,*} == "$systemd" ]] || { fail "Final recovered systemd BootOrder is not Boot$systemd first ($order)"; return 1; }
    ! leap16_order_has_id "$order" "$limine" || { fail "Stranded Limine Boot$limine remains in BootOrder"; return 1; }
    ! leap16_order_has_id "$order" "$fallback" || { fail "Redundant fallback Boot$fallback remains in BootOrder"; return 1; }
    ok 'Removed stranded Limine + redundant EFI fallback aliases from persistent BootOrder while all referenced EFI paths still exist'
}

leap16_r56_delete_recovery_alias_if_present() {
    local id=$1 expected=$2 label=$3
    id=${id^^}
    boot_id_exists "$id" || { info "$label Boot$id is already absent"; return 0; }
    leap16_nvram_entry_matches_current_esp "$id" || { fail "$label Boot$id changed ESP binding"; return 1; }
    nvram_id_matches_path "$id" "$expected" || { fail "$label Boot$id changed EFI path"; return 1; }
    sudo efibootmgr -b "$id" -B >/dev/null || return 1
    ok "Deleted $label Boot$id after it was removed from BootOrder"
}

leap16_r56_finish_recovered_cleanup() {
    local systemd limine fallback state diag
    leap16_r56_authorized || leap16_r56_authorize_cleanup || return 1
    state=$(leap16_r56_state_path)
    [[ $(leap16_r56_state_value esp_uuid) == "$ESP_UUID" && $(leap16_r56_state_value root_uuid) == "$ROOT_UUID" ]] \
        || { fail 'r56 cleanup authorization no longer matches this ESP/root filesystem'; return 1; }
    leap16_require_sudo_session || return 1
    [[ -z ${BOOT_NEXT:-} ]] || { fail "BootNext=Boot${BOOT_NEXT^^} exists; refusing cleanup"; return 1; }
    leap16_r56_validate_systemd_anchor || return 1
    leap16_r56_manifest_remaining_is_owned_subset || return 1

    systemd=$(leap16_r56_state_value systemd_boot_id); systemd=${systemd^^}
    limine=$(leap16_r56_state_value limine_boot_id); limine=${limine^^}
    fallback=$(leap16_r56_state_value fallback_boot_id); fallback=${fallback^^}

    printf '\nCompleting r55 recovered-source cleanup after the real systemd-boot reboot:\n'
    printf '  - keep canonical systemd-boot Boot%s and its EFI/BOOT bytes untouched\n' "$systemd"
    printf '  - retire stranded Limine Boot%s + only its frozen owned files\n' "$limine"
    printf '  - retire redundant EFI/BOOT NVRAM alias Boot%s, but KEEP EFI/BOOT itself as systemd-boot\n' "$fallback"
    printf '  - leave unrelated firmware entries untouched\n\n'

    leap16_r56_order_without_recovery_aliases || return 1
    leap16_r56_delete_recovery_alias_if_present "$fallback" "$LEAP16_R21_FALLBACK_EFI_PATH" 'redundant EFI fallback' || return 1
    leap16_r56_delete_recovery_alias_if_present "$limine" '\EFI\LIMINE\LIMINE_X64.EFI' 'stranded Limine' || return 1
    leap16_r56_remove_manifest_idempotent || return 1

    leap16_r56_validate_systemd_anchor || return 1
    [[ $(count_nvram_entries_for_target limine) == 0 ]] || { fail 'A canonical Limine NVRAM alias remains after recovered-source cleanup'; return 1; }
    [[ -z $(leap16_r53_current_fallback_ids | awk 'NF') ]] || { fail 'A same-ESP EFI/BOOT NVRAM alias remains after recovered-source cleanup'; return 1; }
    [[ $(leap16_current_boot_order | cut -d, -f1) == "$systemd" ]] || { fail 'Canonical systemd-boot is not first after recovered-source cleanup'; return 1; }
    [[ $(r21_hash_privileged "${ESP_MOUNT%/}/EFI/BOOT/BOOTX64.EFI") == $(leap16_r56_state_value systemd_efi_hash) ]] \
        || { fail 'Final EFI/BOOT bytes changed during recovered-source cleanup'; return 1; }

    detect_bootloader
    diag=$(leap16_capture_diagnostics r56-recovered-source-cleanup-pass 2>/dev/null || true)
    [[ -n $diag ]] && printf 'Post-cleanup diagnostic snapshot: %s\n' "$diag" || warn 'Recovered-source cleanup passed but the final diagnostic snapshot could not be created'
    rm -rf -- "$(leap16_r56_cleanup_dir)" 2>/dev/null || warn 'Could not remove completed r56 cleanup checkpoint directory'
    # Replace the r55 safe-fallback result with a clean, non-recovery historical result.
    local f="$PENDING_STATE_DIR/${R22_RESULT_FILE_NAME:-last-auto-result.txt}" tmp
    tmp=$(mktemp) || return 1
    {
        printf 'status=success\n'
        printf 'time=%s\n' "$(date -Is)"
        printf 'detail=Recovered-source cleanup completed after a real canonical systemd-boot reboot. Stranded Limine NVRAM/files and the redundant EFI/BOOT NVRAM alias were retired; EFI/BOOT remains byte-identical to canonical systemd-boot.\n'
    } >"$tmp"
    install -m 0600 -- "$tmp" "$f" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"

    printf '\nRECOVERED SYSTEMD-BOOT SOURCE IS CLEAN.\n'
    printf 'Canonical systemd-boot Boot%s remains first; EFI/BOOT remains systemd-boot; stranded Limine recovery state is retired.\n' "$systemd"
    printf 'A fresh systemd-boot -> Limine transaction can now be staged from a genuinely clean source.\n'
}

leap16_r56_cleanup_menu() {
    local choice
    printf '\nRecovered systemd-boot source cleanup is required before another migration.\n'
    printf 'The r55 recovery booted successfully, but its temporary Limine + EFI-fallback NVRAM recovery topology is still present.\n\n'
    printf '[1] Finish recovered-source cleanup\n'
    printf '[2] Re-check current recovery topology (read-only)\n'
    printf '[3] Back\n\n'
    read -r -p 'Select an option: ' choice
    case "$choice" in
        1) leap16_r56_finish_recovered_cleanup ;;
        2)
            detect_bootloader
            printf '\nBootCurrent: Boot%s (%s)\n' "${BOOT_CURRENT:-unknown}" "$(bootloader_display_name "$BOOTLOADER")"
            printf 'BootOrder:   %s\n' "$(leap16_current_boot_order 2>/dev/null || printf unknown)"
            if leap16_r56_authorized; then ok 'A persisted r56 recovered-source cleanup authorization exists';
            elif leap16_r56_exact_recovered_topology_quiet; then ok 'Exact post-r55 recovered-source topology is present and eligible for cleanup authorization';
            else fail 'The expected post-r55 recovered-source topology is not exact'; fi
            ;;
        *) return 0 ;;
    esac
}

# Selector [2] owns the recovery lifecycle.  A persisted authorization must win
# even after partial deletion makes the original three-entry signature vanish.
eval "$(declare -f manage_pending_migration | sed '1s/manage_pending_migration/manage_pending_migration_pre_leap16_r56/')"
manage_pending_migration() {
    if ! pending_exists && { leap16_r56_authorized || leap16_r56_exact_recovered_topology_quiet; }; then
        leap16_r56_cleanup_menu
        return $?
    fi
    manage_pending_migration_pre_leap16_r56 "$@"
}

# Prevent a fresh switch from being offered as writable while the r55 recovery
# topology still needs source cleanup.  Selector [2] tells the user exactly what
# to do instead of letting r51 fail later on "pre-existing Limine".
eval "$(declare -f operation_supported | sed '1s/operation_supported/operation_supported_pre_leap16_r56/')"
operation_supported() {
    if [[ $1:$2 == systemd-boot:limine ]] && ! pending_exists && { leap16_r56_authorized || leap16_r56_exact_recovered_topology_quiet; }; then
        return 1
    fi
    operation_supported_pre_leap16_r56 "$@"
}


# The r51 dispatcher directly catches systemd-boot -> Limine before consulting
# operation_supported(), so intercept it here as well.  Do not let a user walk
# into a confusing "pre-existing Limine" preflight after r55 recovery.
eval "$(declare -f run_live_operation | sed '1s/run_live_operation/run_live_operation_pre_leap16_r56/')"
run_live_operation() {
    local target=${1:-} current
    detect_bootloader; current=$BOOTLOADER
    if [[ $current:$target == systemd-boot:limine ]] && ! pending_exists && { leap16_r56_authorized || leap16_r56_exact_recovered_topology_quiet; }; then
        printf '\nA recovered-source cleanup is still required before a fresh systemd-boot -> Limine migration.\n'
        printf 'The canonical systemd-boot reboot succeeded, so selector [2] can now retire only the temporary r55 Limine/fallback recovery state.\n'
        printf 'No new candidate was staged.\n'
        return 2
    fi
    run_live_operation_pre_leap16_r56 "$@"
}

# Banner the missing recovery cleanup explicitly.
eval "$(declare -f pending_banner | sed '1s/pending_banner/pending_banner_pre_leap16_r56/')"
pending_banner() {
    pending_banner_pre_leap16_r56 "$@"
    if ! pending_exists && { leap16_r56_authorized || leap16_r56_exact_recovered_topology_quiet; }; then
        printf 'Recovery cleanup required: canonical systemd-boot has now booted, but r55 temporary Limine/fallback recovery state still exists. Use selector [2] before starting another migration.\n'
    fi
}
