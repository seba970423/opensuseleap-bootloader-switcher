#!/usr/bin/env bash
# leap16-r35: harden GRUB2 -> systemd-boot source retirement after the first
# successful one-shot systemd-boot hardware boot.
#
# r34 fixed the wrong automatic-resume dispatcher and the BLS menu layout, but
# review of its finalizer found two ownership/firmware hazards before r34 was
# hardware-tested:
#   1. it removed EFI/OPENSUSE before deleting the GRUB Boot#### aliases, which
#      creates a temporary persistent BootOrder -> missing-EFI window;
#   2. its final alias sweep enumerated the live firmware table instead of
#      deleting only the exact pre-stage GRUB alias set.
#
# r35 keeps the r31-proven GRUB2 <-> Limine layers untouched.  For fresh
# GRUB2 -> systemd-boot stages it records the complete firmware baseline with
# sudo, requires the current same-ESP native-GRUB set to equal that baseline,
# removes those IDs from BootOrder while their EFI files still exist, deletes
# only those ownership-proven IDs, and only then retires EFI/OPENSUSE and the
# remaining GRUB filesystem/config state.

LEAP16_R35_SDBOOT_MARKER='# Managed by openSUSE Bootloader Switcher leap16-r35'
LEAP16_R35_R34_MARKER='# Managed by openSUSE Bootloader Switcher leap16-r34'

# Fresh writers inherited from r34 expand this variable at runtime.  Make new
# r35 candidates self-identifying without editing the already-tested r34 layer.
LEAP16_R34_SDBOOT_MARKER="$LEAP16_R35_SDBOOT_MARKER"
LEAP16_R32_SDBOOT_MANAGED_MARKER="$LEAP16_R35_SDBOOT_MARKER"

# Stale-residue discovery must recognize every switcher-owned Leap layout.
leap16_r33_switcher_entry_marker() {
    local path=$1 first
    first=$(leap16_r32_sdboot_read "$path" 2>/dev/null | head -n1 || true)
    [[ $first == "$LEAP16_R33_R32_MARKER" \
       || $first == "$LEAP16_R33_R33_MARKER" \
       || $first == "$LEAP16_R35_R34_MARKER" \
       || $first == "$LEAP16_R35_SDBOOT_MARKER" ]]
}

# r34's validator is structurally correct.  Let it inspect either an r34 or r35
# clean-menu candidate by temporarily selecting the candidate's actual marker.
eval "$(declare -f leap16_r34_validate_systemd_boot_chain | sed '1s/leap16_r34_validate_systemd_boot_chain/leap16_r34_validate_systemd_boot_chain_pre_leap16_r35/')"
leap16_r34_validate_systemd_boot_chain() {
    local loader="${ESP_MOUNT:-/boot/efi}/loader/loader.conf" marker='' saved=$LEAP16_R34_SDBOOT_MARKER rc
    if sudo -n test -f "$loader" 2>/dev/null || [[ -f $loader ]]; then
        marker=$(leap16_r32_sdboot_read "$loader" 2>/dev/null | head -n1 || true)
    fi
    case "$marker" in
        "$LEAP16_R35_R34_MARKER") LEAP16_R34_SDBOOT_MARKER="$LEAP16_R35_R34_MARKER" ;;
        "$LEAP16_R35_SDBOOT_MARKER") LEAP16_R34_SDBOOT_MARKER="$LEAP16_R35_SDBOOT_MARKER" ;;
    esac
    leap16_r34_validate_systemd_boot_chain_pre_leap16_r35 "$@"
    rc=$?
    LEAP16_R34_SDBOOT_MARKER=$saved
    return "$rc"
}

# r34 captured the right evidence but used an unprivileged efibootmgr read.
# Reuse the pre-r34 source snapshot implementation and capture firmware through
# the already-established non-interactive sudo session.
adapter_source_snapshot() {
    local source=$1 baseline
    adapter_source_snapshot_pre_leap16_r34 "$@" || return $?
    [[ $source == grub ]] || return 0
    baseline="$TRANSACTION_SNAPSHOT_DIR/$LEAP16_R34_FIRMWARE_BASELINE"
    sudo -n efibootmgr -v >"$baseline" || {
        fail 'Could not record the privileged pre-stage firmware baseline for GRUB2 retirement ownership'
        return 1
    }
    chmod 600 -- "$baseline" 2>/dev/null || true
    grep -Eq '^BootCurrent:[[:space:]]+' "$baseline" || { fail 'Pre-stage firmware baseline is incomplete'; return 1; }
    grep -Eq '^BootOrder:[[:space:]]+' "$baseline" || { fail 'Pre-stage firmware baseline has no BootOrder'; return 1; }
    ok 'Recorded the complete privileged pre-stage firmware table for ownership-gated GRUB2 alias retirement'
}

leap16_r35_source_grub_ids_csv() {
    local raw csv
    raw=$(leap16_r34_source_grub_ids_from_baseline) || return 1
    csv=$(awk '/^[0-9A-Fa-f]{4}$/{print toupper($0)}' <<<"$raw" | LC_ALL=C sort -u | paste -sd, -)
    [[ -n $csv ]] || { fail 'Pre-stage firmware baseline contains no native GRUB2 aliases on the transaction ESP'; return 1; }
    case ",$csv," in
        *,"${PENDING_OLD_BOOT_ID^^}",*) ;;
        *) fail "Pre-stage GRUB2 ownership set does not contain source Boot${PENDING_OLD_BOOT_ID^^}"; return 1 ;;
    esac
    printf '%s\n' "$csv"
}

leap16_r35_current_grub_ids_csv() {
    r21_current_native_grub_ids | awk 'NF{print toupper($0)}' | LC_ALL=C sort -u | paste -sd, -
}

# Strict ownership equality: no source ID may disappear and no new same-ESP
# GRUB alias may appear between staging and retirement.
leap16_r34_verify_source_grub_ids() {
    local expected current id path
    expected=$(leap16_r35_source_grub_ids_csv) || return 1
    current=$(leap16_r35_current_grub_ids_csv)
    if [[ $current != "$expected" ]]; then
        local current_desc=none
        [[ -n $current ]] && current_desc="Boot${current//,/ Boot}"
        fail "Native GRUB2 firmware alias set drifted since staging (expected Boot${expected//,/ Boot}, current $current_desc)"
        return 1
    fi

    IFS=',' read -ra _r35_ids <<<"$expected"
    for id in "${_r35_ids[@]}"; do
        boot_id_exists "$id" || { fail "Ownership-proven GRUB2 Boot$id disappeared before retirement"; return 1; }
        leap16_nvram_entry_matches_current_esp "$id" || { fail "Ownership-proven GRUB2 Boot$id is no longer bound to the transaction ESP"; return 1; }
        path=$(leap16_boot_entry_line_for_id "$id" | { read -r line; efi_path_from_efibootmgr_line "$line" 2>/dev/null || true; })
        case "$(normalize_efi_path "$path" | tr '[:upper:]' '[:lower:]')" in
            efi/opensuse/shim.efi|efi/opensuse/grubx64.efi|efi/opensuse/grub.efi) ;;
            *) fail "Ownership-proven GRUB2 Boot$id changed EFI path"; return 1 ;;
        esac
    done
    ok "Exact pre-stage native GRUB2 NVRAM ownership set is unchanged: Boot${expected//,/ Boot}"
}

leap16_r35_order_without_source_grub() {
    local sources target order id joined
    local -a ids=() out=()
    sources=$(leap16_r35_source_grub_ids_csv) || return 1
    target=${PENDING_TARGET_BOOT_ID^^}
    order=$(leap16_current_boot_order 2>/dev/null || true)
    [[ -n $order ]] || { fail 'Persistent BootOrder is unavailable before GRUB2 retirement'; return 1; }

    out=("$target")
    IFS=',' read -ra ids <<<"$order"
    for id in "${ids[@]}"; do
        id=${id^^}
        [[ -n $id && $id != "$target" ]] || continue
        case ",$sources," in *,"$id",*) continue ;; esac
        boot_id_exists "$id" && out+=("$id")
    done
    joined=$(IFS=,; printf '%s' "${out[*]}")
    sudo -n efibootmgr -o "$joined" >/dev/null || { fail 'Could not remove source GRUB2 aliases from persistent BootOrder'; return 1; }
    [[ $(pending_bootorder_first) == "$target" ]] || { fail 'systemd-boot lost first position while removing GRUB2 from BootOrder'; return 1; }

    order=$(leap16_current_boot_order 2>/dev/null || true)
    IFS=',' read -ra ids <<<"$sources"
    for id in "${ids[@]}"; do
        case ",${order^^}," in *,"${id^^}",*) fail "Source Boot${id^^} is still present in persistent BootOrder"; return 1 ;; esac
    done
    ok 'Removed ownership-proven GRUB2 IDs from persistent BootOrder while all GRUB EFI files still exist'
}

leap16_r35_delete_source_grub_nvram_exact() {
    local sources id
    local -a ids=() ordered=()
    sources=$(leap16_r35_source_grub_ids_csv) || return 1
    IFS=',' read -ra ids <<<"$sources"

    # Delete secondary aliases first and the recorded source BootCurrent alias
    # last.  None of them is in BootOrder at this point, so no persistent order
    # ever references a deleted entry.
    for id in "${ids[@]}"; do
        [[ ${id^^} == ${PENDING_OLD_BOOT_ID^^} ]] || ordered+=("${id^^}")
    done
    ordered+=("${PENDING_OLD_BOOT_ID^^}")

    for id in "${ordered[@]}"; do
        boot_id_exists "$id" || { fail "Ownership-proven GRUB2 Boot$id disappeared before exact deletion"; return 1; }
        sudo -n efibootmgr -b "$id" -B >/dev/null || { fail "Could not delete ownership-proven GRUB2 Boot$id"; return 1; }
        boot_id_exists "$id" && { fail "Firmware still exposes GRUB2 Boot$id after deletion"; return 1; }
        boot_id_exists "${PENDING_TARGET_BOOT_ID^^}" || { fail 'systemd-boot target NVRAM entry disappeared during GRUB2 alias retirement'; return 1; }
        nvram_id_matches_path "$PENDING_TARGET_BOOT_ID" "$PENDING_TARGET_EFI_PATH" || { fail 'systemd-boot target NVRAM path changed during GRUB2 alias retirement'; return 1; }
        [[ $(pending_bootorder_first) == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail 'systemd-boot is no longer first after GRUB2 alias deletion'; return 1; }
        ok "Deleted ownership-proven GRUB2 Boot$id only after it was absent from persistent BootOrder"
    done

    [[ -z $(leap16_r35_current_grub_ids_csv) ]] || { fail 'A same-ESP native GRUB2 alias remains after exact baseline-owned deletion'; return 1; }
    ok 'No native GRUB2 NVRAM aliases remain on the transaction ESP'
}

leap16_r35_remove_grub_source_files_after_nvram() {
    local record=$PENDING_SOURCE_MANIFEST kind path identity have_grub=0 have_efi=0 have_default=0
    r26_verify_owned_manifest "$record" || return 1
    while IFS=$'\t' read -r kind path identity; do
        case "$path" in
            /boot/grub2) have_grub=1 ;;
            "$PENDING_ESP_MOUNT/EFI/OPENSUSE") have_efi=1 ;;
            /etc/default/grub) have_default=1 ;;
            *) fail "Unexpected GRUB2 source ownership path in adapter manifest: $path"; return 1 ;;
        esac
    done <"$record"
    ((have_grub == 1 && have_efi == 1 && have_default == 1)) || { fail 'GRUB2 source ownership manifest is incomplete for r35 retirement'; return 1; }

    sudo -n rm -rf -- "$PENDING_ESP_MOUNT/EFI/OPENSUSE" || return 1
    ok 'Removed ownership-proven EFI/OPENSUSE only after every source GRUB2 Boot#### was out of BootOrder and deleted'
    sudo -n rm -rf -- /boot/grub2 || return 1
    ok 'Removed ownership-proven /boot/grub2 tree'
    sudo -n rm -f -- /etc/default/grub || return 1
    ok 'Removed ownership-proven /etc/default/grub'
}

leap16_r35_verify_final_fallback() {
    local fallback="$PENDING_ESP_MOUNT/EFI/BOOT/BOOTX64.EFI" actual expected
    actual=$(sudo -n sha256sum -- "$fallback" 2>/dev/null | awk '{print $1}' || true)
    if [[ $PENDING_OLD_FALLBACK_EXISTED == 1 && $PENDING_SOURCE_FALLBACK_OWNED != 1 ]]; then
        expected=$PENDING_OLD_FALLBACK_HASH
        [[ -n $expected && $actual == "$expected" ]] || { fail 'Unrelated pre-existing EFI fallback was not preserved byte-for-byte'; return 1; }
        ok 'Unrelated pre-existing generic EFI fallback remains byte-identical'
    else
        expected=$PENDING_TARGET_EFI_HASH
        [[ -n $expected && $actual == "$expected" ]] || { fail 'Final generic EFI fallback is not byte-identical to the proven systemd-boot EFI'; return 1; }
        ok 'Generic EFI fallback is byte-identical to the proven systemd-boot EFI'
    fi
}

# Replace only the new systemd-boot edge finalizer.  The hardware-proven
# GRUB2/Limine finalizers remain inherited and byte-identical.
leap16_r34_finalize_grub_to_systemd() {
    validate_pending_compatibility || { fail "Pending migration is not compatible: $PENDING_REASON"; return 1; }
    leap16_r34_sdboot_pending || { fail 'r35 finalizer is restricted to GRUB2 -> systemd-boot'; return 1; }
    [[ $PENDING_PHASE == runtime-validated ]] || { fail 'Finalization requires runtime-validated systemd-boot state'; return 1; }
    [[ -s $(leap16_r34_baseline_path 2>/dev/null || printf /nonexistent) ]] || {
        fail 'This candidate predates the complete r34/r35 pre-stage firmware baseline.'
        fail 'GRUB2 retirement is intentionally locked. Reboot normally to GRUB2, roll back this candidate, then restage with r35.'
        return 1
    }
    detect_bootloader
    [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail 'Finalization must run from the exact runtime-proven systemd-boot target session'; return 1; }
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext must be clear before persistent finalization'; return 1; }
    run_validation preflight || return 1
    pending_validate_running_kernel || return 1
    pending_validate_runtime_cmdline_against_source || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    leap16_r34_validate_systemd_boot_chain runtime || return 1
    verify_pending_source_recovery_unchanged || return 1
    leap16_r34_verify_source_grub_ids || return 1

    printf '\nFINALIZE hardware-proven GRUB2 -> systemd-boot:\n'
    printf '  - promote Boot%s first while every GRUB2 recovery alias/file still exists\n' "$PENDING_TARGET_BOOT_ID"
    printf '  - transfer the generic EFI fallback only after exact runtime proof and target promotion\n'
    printf '  - remove only the pre-stage-owned GRUB2 IDs from BootOrder while their EFI paths still exist\n'
    printf '  - delete exactly those GRUB2 Boot#### aliases, then retire EFI/OPENSUSE + /boot/grub2 + /etc/default/grub\n'

    leap16_r34_target_first_keep_recovery || { fail 'Could not promote systemd-boot while retaining source recovery aliases'; return 1; }
    verify_pending_candidate_ownership_unchanged || { fail 'Target changed after promotion; no GRUB cleanup was attempted'; return 1; }
    leap16_r34_validate_systemd_boot_chain target || { fail 'Target validation failed after promotion; no GRUB cleanup was attempted'; return 1; }
    verify_pending_source_recovery_unchanged || { fail 'GRUB2 recovery changed after promotion; no cleanup was attempted'; return 1; }
    leap16_r34_verify_source_grub_ids || return 1

    leap16_r34_transfer_systemd_fallback || return 1
    r26_verify_owned_manifest "$PENDING_SOURCE_MANIFEST" || return 1

    # Firmware-safe retirement order: BootOrder first, then exact NVRAM IDs,
    # then filesystem bytes.  At no point can persistent BootOrder reference a
    # GRUB EFI path that we have already deleted.
    leap16_r35_order_without_source_grub || return 1
    leap16_r35_delete_source_grub_nvram_exact || return 1
    leap16_r35_remove_grub_source_files_after_nvram || return 1
    leap16_r34_set_loader_policy_systemd || return 1

    detect_bootloader
    [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail 'Target identity changed during finalization'; return 1; }
    [[ $(pending_bootorder_first) == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail 'systemd-boot is not first in persistent BootOrder after GRUB2 retirement'; return 1; }
    [[ -z $(r21_current_native_grub_ids | awk 'NF') ]] || { fail 'A same-ESP native GRUB2 NVRAM alias remains after retirement'; return 1; }
    [[ ! -e /boot/grub2 && ! -e /etc/default/grub ]] || { fail 'Native GRUB2 filesystem state remains after retirement'; return 1; }
    sudo -n test ! -e "$PENDING_ESP_MOUNT/EFI/OPENSUSE" 2>/dev/null || { fail 'EFI/OPENSUSE remains after retirement'; return 1; }
    leap16_r35_verify_final_fallback || return 1
    validate_target_state systemd-boot || return 1
    leap16_r34_validate_systemd_boot_chain final || return 1

    pending_capture_runtime_diagnostics finalized-systemd-boot >/dev/null 2>&1 || true
    remove_pending_transaction_snapshot || warn 'Could not remove private transaction snapshot after successful finalization'
    rm -f -- "$PENDING_STATE_FILE"
    printf '\nFINALIZED GRUB2 -> systemd-boot successfully.\n'
    printf 'systemd-boot Boot%s is persistent first; exact pre-stage GRUB2 aliases/files are retired without an orphaned-BootOrder window.\n' "$PENDING_TARGET_BOOT_ID"
    return 0
}

# r34's adapter finalizer wrapper calls leap16_r34_finalize_grub_to_systemd by
# name, so the replacement above is automatically used for this edge.
