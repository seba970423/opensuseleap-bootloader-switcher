#!/usr/bin/env bash
# leap16-r36: exact GRUB2 -> systemd-boot candidate rollback repair.
#
# The first real r33 systemd-boot one-shot proved the target boots, but the old
# automatic resume dispatcher failed before promotion.  r34/r35 correctly
# locked finalization for that pre-baseline candidate.  Their pending menu then
# exposed an older Leap GRUB->Limine rollback symbol, whose generic firmware-
# order gate requires a pre-stage firmware baseline that the r33 candidate
# cannot possibly have.
#
# r36 changes only rollback routing for the format-v5 GRUB2 -> systemd-boot
# adapter edge.  Rollback does not retire GRUB2, so it does not need the r34/r35
# source-retirement baseline.  Instead it proves the exact running GRUB source,
# exact transaction-owned systemd-boot candidate, exact source fallback, and a
# source-first live BootOrder.  It then removes only the target ID from the live
# order while every EFI path still exists, deletes exactly the recorded target
# Boot####, removes only the target ownership manifest, restores the recorded
# source fallback, and preserves every non-target live firmware entry in place.
# Hardware-proven GRUB2 <-> Limine code remains untouched.

# Preserve every existing rollback direction and intercept only this new edge.
eval "$(declare -f rollback_pending_candidate | sed '1s/rollback_pending_candidate/rollback_pending_candidate_pre_leap16_r36/')"

LEAP16_R36_ROLLBACK_ORDER=''

leap16_r36_write_local_result() {
    local status=$1 detail=$2 out tmp
    mkdir -p -- "$PENDING_STATE_DIR" || return 1
    chmod 700 -- "$PENDING_STATE_DIR" 2>/dev/null || true
    out="$PENDING_STATE_DIR/${R22_RESULT_FILE_NAME:-last-auto-result.txt}"
    tmp=$(mktemp "$PENDING_STATE_DIR/.result.XXXXXX") || return 1
    {
        printf 'status=%s\n' "$status"
        printf 'time=%s\n' "$(date -Is)"
        printf 'detail=%s\n' "$detail"
    } >"$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 600 -- "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$out"
}

leap16_r36_order_without_exact_target() {
    local order first target source id joined saw_target=0
    local -a ids=() out=()

    order=$(leap16_current_boot_order 2>/dev/null || true)
    [[ -n $order ]] || { fail 'Persistent BootOrder is unavailable before systemd-boot candidate rollback'; return 1; }
    source=${PENDING_OLD_BOOT_ID^^}
    target=${PENDING_TARGET_BOOT_ID^^}
    first=${order%%,*}; first=${first^^}
    [[ $first == "$source" ]] || {
        fail "GRUB2 source Boot$source is not first in the live persistent BootOrder ($order)"
        return 1
    }

    IFS=',' read -ra ids <<<"$order"
    for id in "${ids[@]}"; do
        id=${id^^}
        [[ $id =~ ^[0-9A-F]{4}$ ]] || { fail "Malformed BootOrder member during rollback: ${id:-empty}"; return 1; }
        boot_id_exists "$id" || { fail "Live BootOrder references missing Boot$id; refusing rollback mutation"; return 1; }
        if [[ $id == "$target" ]]; then
            saw_target=1
            continue
        fi
        out+=("$id")
    done

    ((${#out[@]} > 0)) || { fail 'Removing the candidate would leave an empty persistent BootOrder'; return 1; }
    [[ ${out[0]} == "$source" ]] || { fail 'Source-first order would not survive target removal'; return 1; }
    joined=$(IFS=,; printf '%s' "${out[*]}")
    LEAP16_R36_ROLLBACK_ORDER=$joined

    if ((saw_target)); then
        sudo -n efibootmgr -o "$joined" >/dev/null || { fail 'Could not remove the systemd-boot candidate from persistent BootOrder'; return 1; }
        [[ $(leap16_current_boot_order 2>/dev/null || true) == "$joined" ]] || {
            fail 'Firmware did not preserve the exact non-target BootOrder after candidate removal'
            return 1
        }
        ok "Removed only target Boot$target from persistent BootOrder while its EFI path still exists"
    else
        ok "Target Boot$target is already absent from persistent BootOrder; preserving the live non-target order exactly"
    fi
}

leap16_r36_verify_target_manifest_for_rollback() {
    local record=$PENDING_TARGET_MANIFEST kind path identity actual mf partial=0
    [[ -s $record ]] || { fail "Target ownership record is missing/empty: $record"; return 1; }
    while IFS=$'\t' read -r kind path identity; do
        [[ -n $kind && -n $path && -n $identity ]] || { fail 'Malformed target ownership manifest during rollback'; return 1; }
        if ! sudo -n test -e "$path" 2>/dev/null && ! sudo -n test -L "$path" 2>/dev/null && [[ ! -e $path && ! -L $path ]]; then
            partial=1
            continue
        fi
        case "$kind" in
            file)
                actual=$(sudo -n sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || true)
                [[ -n $actual && $actual == "$identity" ]] || { fail "Transaction-owned systemd-boot file changed before rollback: $path"; return 1; }
                ;;
            tree)
                mf="$(dirname -- "$record")/$identity"
                pending_verify_tree_manifest "$path" "$mf" || { fail "Transaction-owned systemd-boot tree changed before rollback: $path"; return 1; }
                ;;
            *) fail "Unknown target ownership kind during rollback: $kind"; return 1 ;;
        esac
    done <"$record"
    ((partial)) && warn 'Recognized idempotent partial systemd-boot candidate cleanup; absent transaction-owned paths will not be recreated'
    return 0
}

leap16_r36_remove_target_manifest_paths() {
    local record=$PENDING_TARGET_MANIFEST kind path identity
    leap16_r36_verify_target_manifest_for_rollback || return 1
    while IFS=$'\t' read -r kind path identity; do
        [[ -n $kind && -n $path && -n $identity ]] || { fail 'Malformed target ownership manifest during rollback'; return 1; }
        if ! sudo -n test -e "$path" 2>/dev/null && ! sudo -n test -L "$path" 2>/dev/null && [[ ! -e $path && ! -L $path ]]; then
            continue
        fi
        case "$kind" in
            file) sudo -n rm -f -- "$path" || return 1 ;;
            tree) sudo -n rm -rf -- "$path" || return 1 ;;
            *) fail "Unknown target ownership kind during rollback: $kind"; return 1 ;;
        esac
        ok "Removed ownership-proven systemd-boot candidate path: $path"
    done <"$record"

    # loader/entries is deliberately shared and never transaction-owned.  Drop
    # only empty directories; foreign BLS entries make rmdir harmlessly fail.
    sudo -n rmdir -- "$PENDING_ESP_MOUNT/loader/entries" 2>/dev/null || true
    sudo -n rmdir -- "$PENDING_ESP_MOUNT/loader" 2>/dev/null || true
}

leap16_r36_verify_target_paths_absent() {
    local record=$PENDING_TARGET_MANIFEST kind path identity
    while IFS=$'\t' read -r kind path identity; do
        [[ -n $path ]] || return 1
        if sudo -n test -e "$path" 2>/dev/null || sudo -n test -L "$path" 2>/dev/null || [[ -e $path || -L $path ]]; then
            fail "Transaction-owned systemd-boot candidate path remains after rollback: $path"
            return 1
        fi
    done <"$record"
    ok 'All ownership-proven systemd-boot candidate paths are absent after rollback'
}

leap16_r36_verify_rollback_fallback() {
    local actual
    if [[ $PENDING_OLD_FALLBACK_EXISTED == 1 ]]; then
        actual=$(sudo -n sha256sum -- "$PENDING_OLD_FALLBACK_PATH" 2>/dev/null | awk '{print $1}' || true)
        [[ -n $PENDING_OLD_FALLBACK_HASH && $actual == "$PENDING_OLD_FALLBACK_HASH" ]] || {
            fail 'Generic EFI fallback does not match the exact pre-stage GRUB2 bytes after rollback'
            return 1
        }
        ok 'Generic EFI fallback is byte-identical to the recorded pre-stage GRUB2 fallback'
    else
        if sudo -n test -e "$PENDING_OLD_FALLBACK_PATH" 2>/dev/null || [[ -e $PENDING_OLD_FALLBACK_PATH ]]; then
            fail 'Generic EFI fallback exists even though it was absent before staging'
            return 1
        fi
        ok 'Generic EFI fallback remains absent exactly as recorded before staging'
    fi
}

leap16_r36_rollback_grub_to_systemd() {
    local next answer count target source final_order

    validate_pending_compatibility || { fail "Pending migration is not compatible: $PENDING_REASON"; return 1; }
    leap16_r34_sdboot_pending || { fail 'r36 systemd-boot rollback received the wrong transaction direction'; return 1; }
    leap16_require_sudo_session || return 1
    detect_bootloader
    source=${PENDING_OLD_BOOT_ID^^}
    target=${PENDING_TARGET_BOOT_ID^^}
    [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == "$source" ]] || {
        fail "Exact systemd-boot candidate rollback requires the recorded GRUB2 source session Boot$source"
        return 1
    }
    run_validation preflight || return 1

    # This is deliberately independent of leap16_validate_pending_firmware_order:
    # a pre-r34/r35 candidate has no firmware baseline.  Rollback never claims
    # or retires source aliases; it needs only exact source + target ownership.
    verify_pending_source_recovery_unchanged || return 1
    leap16_r36_verify_target_manifest_for_rollback || return 1
    count=$(count_nvram_entries_for_target systemd-boot)
    if boot_id_exists "$target"; then
        nvram_id_matches_path "$target" "$PENDING_TARGET_EFI_PATH" || { fail 'Recorded systemd-boot target NVRAM path changed before rollback'; return 1; }
        leap16_nvram_entry_matches_current_esp "$target" || { fail 'Recorded systemd-boot target moved off the transaction ESP'; return 1; }
        [[ $count == 1 ]] || { fail "Expected exactly one systemd-boot NVRAM candidate before rollback, found $count"; return 1; }
    else
        [[ $count == 0 ]] || { fail "Recorded target Boot$target is absent but another systemd-boot NVRAM entry exists"; return 1; }
        warn "Target Boot$target is already absent; accepting idempotent partial rollback recovery without recreating it"
    fi

    next=$(pending_bootnext_id)
    [[ -z $next || ${next^^} == "$target" ]] || { fail "BootNext belongs to unrelated Boot${next^^}; refusing rollback"; return 1; }

    # Prove the live order can be reduced safely before asking for the write.
    final_order=$(leap16_current_boot_order 2>/dev/null || true)
    [[ ${final_order%%,*} == "$source" ]] || { fail "GRUB2 source Boot$source is no longer persistent first"; return 1; }

    printf '\nExact GRUB2 -> systemd-boot candidate rollback:\n'
    printf '  - keep GRUB2 Boot%s authoritative and leave every GRUB2 EFI/config byte untouched\n' "$source"
    printf '  - remove only systemd-boot candidate Boot%s from the live persistent order, preserving every other current entry\n' "$target"
    printf '  - delete exactly Boot%s only after it is no longer referenced by BootOrder\n' "$target"
    printf '  - remove only the transaction ownership manifest for systemd-boot and restore the recorded source EFI fallback\n'
    printf '  - no r34/r35 source-retirement firmware baseline is required because GRUB2 is not being retired\n\n'
    read -r -p 'Type ROLLBACK to remove this exact systemd-boot candidate: ' answer
    [[ $answer == ROLLBACK ]] || { printf 'Rollback cancelled. No boot state was modified.\n'; return 0; }

    # Re-prove the exact identities at the write boundary.
    detect_bootloader
    [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == "$source" ]] || { fail 'Source identity changed at the rollback write boundary'; return 1; }
    verify_pending_source_recovery_unchanged || return 1
    leap16_r36_verify_target_manifest_for_rollback || return 1
    count=$(count_nvram_entries_for_target systemd-boot)
    if boot_id_exists "$target"; then
        nvram_id_matches_path "$target" "$PENDING_TARGET_EFI_PATH" || { fail 'Target NVRAM path changed at the rollback write boundary'; return 1; }
        leap16_nvram_entry_matches_current_esp "$target" || { fail 'Target NVRAM entry moved off the transaction ESP at the rollback write boundary'; return 1; }
        [[ $count == 1 ]] || { fail 'systemd-boot candidate NVRAM ownership changed at the rollback write boundary'; return 1; }
    else
        [[ $count == 0 ]] || { fail 'Another systemd-boot NVRAM entry appeared at the rollback write boundary'; return 1; }
    fi
    next=$(pending_bootnext_id)
    [[ -z $next || ${next^^} == "$target" ]] || { fail "BootNext changed to unrelated Boot${next^^} at the rollback write boundary"; return 1; }

    [[ -z $next ]] || sudo -n efibootmgr -N >/dev/null || return 1
    r22_disarm_user_resume_bundle || true

    # Never create a BootOrder -> missing-EFI window: remove the target from the
    # order first, then delete its exact variable, then its exact filesystem set.
    leap16_r36_order_without_exact_target || return 1
    if boot_id_exists "$target"; then
        nvram_id_matches_path "$target" "$PENDING_TARGET_EFI_PATH" || { fail 'Target NVRAM path changed after BootOrder removal'; return 1; }
        sudo -n efibootmgr -b "$target" -B >/dev/null || { fail "Could not delete exact systemd-boot candidate Boot$target"; return 1; }
        boot_id_exists "$target" && { fail "Firmware still exposes candidate Boot$target after deletion"; return 1; }
        ok "Deleted exact systemd-boot candidate Boot$target after removing it from persistent BootOrder"
    else
        ok "Candidate Boot$target was already absent; no NVRAM entry was recreated during rollback recovery"
    fi
    [[ $(count_nvram_entries_for_target systemd-boot) == 0 ]] || { fail 'A systemd-boot NVRAM entry remains after exact candidate deletion'; return 1; }

    leap16_r36_remove_target_manifest_paths || return 1
    leap16_r36_verify_target_paths_absent || return 1
    r26_restore_fallback_on_rollback || return 1
    leap16_r36_verify_rollback_fallback || return 1

    final_order=$(leap16_current_boot_order 2>/dev/null || true)
    [[ $final_order == "$LEAP16_R36_ROLLBACK_ORDER" ]] || { fail "Non-target persistent BootOrder changed during rollback (expected $LEAP16_R36_ROLLBACK_ORDER, got ${final_order:-empty})"; return 1; }
    [[ ${final_order%%,*} == "$source" ]] || { fail 'GRUB2 source is not first after candidate rollback'; return 1; }
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext unexpectedly remains after candidate rollback'; return 1; }

    detect_bootloader
    [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == "$source" ]] || { fail 'GRUB2 source identity changed after candidate cleanup'; return 1; }
    run_validation preflight || return 1
    adapter_source_validate grub || return 1
    ok 'GRUB2 source remains authoritative and deeply valid after exact systemd-boot candidate cleanup'

    leap16_r36_write_local_result success "GRUB2 -> systemd-boot candidate rolled back exactly. GRUB2 Boot$source remains authoritative; target Boot$target and only transaction-owned systemd-boot state were removed." || true
    rm -f -- "$PENDING_STATE_FILE"
    remove_pending_transaction_snapshot || warn 'Could not remove the private transaction snapshot directory'
    pending_reset
    ok 'ROLLBACK-COMPLETE. GRUB2 remains authoritative; the systemd-boot candidate is fully removed.'
}

rollback_pending_candidate() {
    if [[ $(r26_state_format 2>/dev/null || true) == "${R26_PENDING_FORMAT:-5}" ]]; then
        load_pending_state || return 1
        if leap16_r34_sdboot_pending; then
            leap16_r36_rollback_grub_to_systemd
            return $?
        fi
    fi
    rollback_pending_candidate_pre_leap16_r36 "$@"
}
