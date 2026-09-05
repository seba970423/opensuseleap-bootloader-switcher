#!/usr/bin/env bash
# leap16-r30: tolerate and normalize same-ESP direct-GRUB alias synthesis
# observed on ASUS after the reconstructed shim BootNext successfully boots.
# The extra alias is never trusted by label or Boot#### number: it must point
# exactly to EFI/OPENSUSE/GRUBX64.EFI on the transaction ESP.

r30_csv_append() {
    local cur=${1:-} val=${2:-}
    [[ -n $val ]] || { printf '%s' "$cur"; return 0; }
    [[ -n $cur ]] && printf '%s,%s' "$cur" "$val" || printf '%s' "$val"
}

r30_validate_reconstructed_runtime_order() {
    r28_rebuilt_reverse_pending || return 1
    local source=${PENDING_OLD_BOOT_ID^^} target=${PENDING_TARGET_BOOT_ID^^}
    local fallback recorded_direct dump order id line path normalized_direct normalized_path
    local core='' extras='' phase=0
    local -a ids=()

    fallback=$(r28_meta_value source_fallback_boot_id 2>/dev/null || true); fallback=${fallback^^}
    recorded_direct=$(r28_meta_value direct_grub_boot_id 2>/dev/null || true); recorded_direct=${recorded_direct^^}
    [[ $source =~ ^[0-9A-F]{4}$ && $fallback =~ ^[0-9A-F]{4}$ && $target =~ ^[0-9A-F]{4}$ && $recorded_direct =~ ^[0-9A-F]{4}$ ]] || {
        fail 'Reconstructed runtime-order metadata is incomplete'
        return 1
    }

    # The parked transaction-created direct alias must still exist even though
    # it intentionally is not part of candidate BootOrder.
    nvram_id_matches_path "$recorded_direct" "$R28_GRUB_DIRECT_PATH" || {
        fail "Recorded parked direct-GRUB Boot$recorded_direct no longer points to $R28_GRUB_DIRECT_PATH"
        return 1
    }
    leap16_nvram_entry_matches_current_esp "$recorded_direct" || {
        fail "Recorded parked direct-GRUB Boot$recorded_direct is no longer bound to the transaction ESP"
        return 1
    }

    dump=$(efibootmgr -v 2>/dev/null || true)
    order=$(awk -F': ' '/^BootOrder:/ {print toupper($2); exit}' <<<"$dump")
    [[ -n $order ]] || { fail 'Current BootOrder is unreadable'; return 1; }
    normalized_direct=$(normalize_efi_path "$R28_GRUB_DIRECT_PATH" | tr '[:upper:]' '[:lower:]')

    IFS=',' read -ra ids <<<"$order"
    for id in "${ids[@]}"; do
        id=${id^^}; [[ -n $id ]] || continue
        line=$(leap16_line_for_id_in_dump "$dump" "$id")
        [[ -n $line ]] || { fail "BootOrder references missing Boot$id"; return 1; }
        leap16_line_is_bbs "$line" && continue

        case $phase in
            0) [[ $id == "$source" ]] || { fail "Reconstructed runtime order no longer starts with source Limine Boot$source (got Boot$id)"; return 1; }; core=$(r30_csv_append "$core" "$id"); phase=1 ;;
            1) [[ $id == "$fallback" ]] || { fail "Reconstructed runtime order lost Limine fallback Boot$fallback in second stable position (got Boot$id)"; return 1; }; core=$(r30_csv_append "$core" "$id"); phase=2 ;;
            2) [[ $id == "$target" ]] || { fail "Reconstructed runtime order lost shim target Boot$target in third stable position (got Boot$id)"; return 1; }; core=$(r30_csv_append "$core" "$id"); phase=3 ;;
            *)
                path=$(efi_path_from_efibootmgr_line "$line" 2>/dev/null || true)
                normalized_path=$(normalize_efi_path "$path" 2>/dev/null | tr '[:upper:]' '[:lower:]')
                [[ -n $path && $normalized_path == "$normalized_direct" ]] || {
                    fail "Unexpected post-target EFI alias Boot$id entered reconstructed runtime BootOrder ($path)"
                    return 1
                }
                leap16_nvram_entry_matches_current_esp "$id" || {
                    fail "Extra direct-GRUB alias Boot$id is not bound to the transaction ESP"
                    return 1
                }
                extras=$(r30_csv_append "$extras" "$id")
                ;;
        esac
    done
    [[ $phase == 3 ]] || { fail 'Reconstructed runtime BootOrder is missing one or more core source/fallback/shim entries'; return 1; }

    LEAP16_ORDER_CURRENT_FULL=$order
    LEAP16_ORDER_CURRENT_STABLE=$core${extras:+,$extras}
    LEAP16_ORDER_EXPECTED_STABLE="$source,$fallback,$target"
    LEAP16_ORDER_REASON='core reconstructed runtime order is exact; any trailing extras are same-ESP direct-GRUB aliases eligible for post-proof normalization'
    R30_RUNTIME_DIRECT_EXTRAS=$extras
    if [[ -n $extras ]]; then
        warn "Firmware/openSUSE synthesized additional same-ESP direct-GRUB alias(es) after the one-shot boot: Boot${extras//,/ Boot}"
    fi
    ok "Reverse runtime core BootOrder is valid ($source,$fallback,$target); synthesized direct-GRUB aliases are ownership-bounded"
    return 0
}

# Runtime proof stays read-only.  r29 failed before cmdline/ownership proof only
# because the generic firmware-order gate rejected a path-owned extra alias.
eval "$(declare -f r15_validate_grub_target_runtime | sed '1s/r15_validate_grub_target_runtime/r15_validate_grub_target_runtime_pre_r30/')"
r15_validate_grub_target_runtime() {
    if ! r28_rebuilt_reverse_pending; then
        r15_validate_grub_target_runtime_pre_r30 "$@"
        return $?
    fi
    validate_pending_compatibility || { fail "Pending reconstructed reverse migration is incompatible: $PENDING_REASON"; return 1; }
    [[ $PENDING_PHASE == boot-armed || $PENDING_PHASE == runtime-validated ]] || { fail "Runtime proof is not allowed from phase $PENDING_PHASE"; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail "Runtime proof requires reconstructed GRUB2 Boot$PENDING_TARGET_BOOT_ID as BootCurrent"; return 1; }
    leap16_require_sudo_session || return 1
    leap16_stage_diagnostic runtime-arrival
    run_validation preflight || return 1
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext was not consumed/cleared by firmware'; return 1; }
    pending_validate_running_kernel || return 1
    r30_validate_reconstructed_runtime_order || return 1
    pending_validate_runtime_cmdline_against_source || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1
    verify_pending_source_recovery_unchanged || return 1
    pending_set_phase runtime-validated || return 1
    PENDING_PHASE=runtime-validated
    leap16_stage_diagnostic runtime-pass
    printf '\nRUNTIME-VALIDATED Limine -> reconstructed GRUB2 one-shot boot succeeded.\n'
    printf '  BootCurrent proof: Boot%s -> %s\n' "$PENDING_TARGET_BOOT_ID" "$PENDING_TARGET_EFI_PATH"
    printf '  BootNext: clear\n'
    printf '  Persistent source/fallback/shim order remains intact until promotion.\n'
}

r30_normalize_reconstructed_direct_aliases() {
    r28_rebuilt_reverse_pending || return 0
    [[ ${PENDING_PHASE:-} == runtime-validated ]] || { fail 'Direct-GRUB alias normalization requires runtime-validated state'; return 1; }
    local recorded id ids_after order
    recorded=$(r28_meta_value direct_grub_boot_id 2>/dev/null || true); recorded=${recorded^^}
    [[ $recorded =~ ^[0-9A-F]{4}$ ]] || { fail 'Recorded direct-GRUB identity is unavailable'; return 1; }
    nvram_id_matches_path "$recorded" "$R28_GRUB_DIRECT_PATH" || { fail "Recorded direct-GRUB Boot$recorded changed path before normalization"; return 1; }
    leap16_nvram_entry_matches_current_esp "$recorded" || { fail "Recorded direct-GRUB Boot$recorded changed ESP before normalization"; return 1; }
    order=$(leap16_current_boot_order 2>/dev/null || true)

    # Keep the transaction-created parked direct alias.  r28 deliberately owns
    # that identity and its pre-promotion validators require it to remain
    # outside BootOrder.  Any firmware/openSUSE-created duplicate is tolerated
    # during read-only runtime proof, then removed here only after the complete
    # proof has been persisted as runtime-validated.
    while IFS= read -r id; do
        [[ $id =~ ^[0-9A-F]{4}$ ]] || continue
        id=${id^^}
        [[ $id == "$recorded" ]] && continue
        leap16_nvram_entry_matches_current_esp "$id" || { fail "Refusing to remove duplicate direct-GRUB Boot$id: ESP ownership changed"; return 1; }
        leap16_order_has_id "$order" "$id" || { fail "Duplicate direct-GRUB Boot$id exists outside BootOrder; refusing to guess its provenance"; return 1; }
        sudo efibootmgr -b "$id" -B >/dev/null || { fail "Could not remove synthesized duplicate direct-GRUB Boot$id"; return 1; }
        ok "Removed synthesized duplicate direct-GRUB alias Boot$id; retained transaction-owned parked Boot$recorded"
    done < <(r28_ids_for_path "$R28_GRUB_DIRECT_PATH")

    ids_after=$(r28_ids_for_path "$R28_GRUB_DIRECT_PATH" | tr '\n' ' ' | xargs 2>/dev/null || true)
    [[ $ids_after == "$recorded" ]] || { fail "Direct-GRUB alias normalization did not converge to recorded Boot$recorded (remaining: ${ids_after:-none})"; return 1; }
    order=$(leap16_current_boot_order 2>/dev/null || true)
    leap16_order_has_id "$order" "$recorded" && { fail "Recorded parked direct-GRUB Boot$recorded entered BootOrder during normalization"; return 1; }
    leap16_stage_diagnostic runtime-direct-alias-normalized >/dev/null 2>&1 || true
    return 0
}

# The write happens only after the complete runtime proof has persisted.  This
# makes the later r28 exact-one-direct-alias retirement gates true again.
eval "$(declare -f r15_promote_and_finalize_grub | sed '1s/r15_promote_and_finalize_grub/r15_promote_and_finalize_grub_pre_r30/')"
r15_promote_and_finalize_grub() {
    if r28_rebuilt_reverse_pending && [[ ${PENDING_PHASE:-} == runtime-validated ]]; then
        r30_normalize_reconstructed_direct_aliases || return 1
    fi
    r15_promote_and_finalize_grub_pre_r30 "$@"
}
