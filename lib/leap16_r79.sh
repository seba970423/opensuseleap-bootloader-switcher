#!/usr/bin/env bash
# leap16-r79: fix r77/r78 rEFInd -> GRUB duplicate normalization when the
# transaction-owned direct-GRUB alias is deliberately parked outside BootOrder.
#
# Hardware evidence from r78:
#   runtime-proven shim: Boot0002
#   rEFInd recovery:     Boot0000
#   recorded direct:     Boot0001 (parked outside BootOrder by design)
#   firmware duplicate:  Boot0003
#   runtime BootOrder:   0000,0002,0003
# After promotion/fallback transfer the order became 0002,0000,0003.  r77 then
# refused cleanup because it incorrectly required Boot0001 to already be in
# BootOrder *before* the final-order function whose job is to insert Boot0001.
#
# Keep every ownership gate from r77.  The only semantic correction is that the
# recorded direct alias must exist with exact path+ESP identity, but may remain
# parked outside BootOrder until final normalization.  Post-stage duplicates are
# still removed from BootOrder first, then deleted, then the inherited final
# order installs shim,direct and removes rEFInd recovery from persistent order.

leap16_r77_normalize_refind_grub_direct_aliases_after_proof() {
    leap16_r77_refind_grub_runtime_validated \
        || { fail 'Direct-GRUB duplicate normalization requires runtime-validated rEFInd -> GRUB state'; return 1; }

    local target=${PENDING_TARGET_BOOT_ID^^} recorded baseline id order extras_csv='' ids_after
    local -a ids=() extras=()
    recorded=$(leap16_r64_grub_direct_id 2>/dev/null || true); recorded=${recorded^^}
    [[ $target =~ ^[0-9A-F]{4}$ && $recorded =~ ^[0-9A-F]{4}$ ]] \
        || { fail 'Recorded shim/direct GRUB identities are unavailable during duplicate normalization'; return 1; }
    [[ ${BOOTLOADER:-} == grub && ${BOOT_CURRENT^^} == "$target" ]] \
        || { fail "Duplicate-GRUB normalization requires runtime-proven shim Boot$target as BootCurrent"; return 1; }
    boot_id_exists "$target" && nvram_id_matches_path "$target" "$R28_GRUB_SHIM_PATH" && leap16_nvram_entry_matches_current_esp "$target" \
        || { fail "Runtime-proven shim Boot$target is not exact during duplicate normalization"; return 1; }
    boot_id_exists "$recorded" && nvram_id_matches_path "$recorded" "$R28_GRUB_DIRECT_PATH" && leap16_nvram_entry_matches_current_esp "$recorded" \
        || { fail "Recorded direct-GRUB Boot$recorded is not exact during duplicate normalization"; return 1; }

    mapfile -t ids < <(leap16_r77_current_direct_grub_ids)
    ((${#ids[@]} > 0)) || { fail 'No same-ESP direct-GRUB alias exists during duplicate normalization'; return 1; }
    case " ${ids[*]} " in *" $recorded "*) ;; *) fail "Recorded direct-GRUB Boot$recorded disappeared from alias set (${ids[*]})"; return 1 ;; esac
    ((${#ids[@]} == 1)) && { ok "Canonical direct-GRUB alias remains unique: Boot$recorded"; return 0; }

    baseline=$(leap16_r64_baseline_path 2>/dev/null || true)
    [[ -n $baseline && -s $baseline ]] \
        || { fail 'Pre-stage firmware baseline is unavailable; duplicate direct-GRUB aliases cannot be ownership-bounded'; return 1; }

    for id in "${ids[@]}"; do
        id=${id^^}; [[ $id != "$recorded" ]] || continue
        if grep -Eq "^Boot${id}\\*?[[:space:]]" "$baseline"; then
            fail "Duplicate direct-GRUB Boot$id reused a pre-stage firmware ID; refusing to claim or delete it"
            return 1
        fi
        nvram_id_matches_path "$id" "$R28_GRUB_DIRECT_PATH" \
            || { fail "Duplicate direct-GRUB Boot$id changed canonical path"; return 1; }
        leap16_nvram_entry_matches_current_esp "$id" \
            || { fail "Duplicate direct-GRUB Boot$id is not bound to the transaction ESP"; return 1; }
        extras+=("$id")
    done
    ((${#extras[@]} > 0)) || return 0
    extras_csv=$(IFS=,; printf '%s' "${extras[*]}")

    order=$(leap16_current_boot_order) || return 1
    leap16_order_has_id "$order" "$target" || { fail "Runtime-proven shim Boot$target disappeared from BootOrder"; return 1; }
    # Boot$recorded is intentionally allowed to remain parked outside BootOrder
    # until leap16_r64_final_grub_order() installs the final shim,direct prefix.
    if leap16_order_has_id "$order" "$recorded"; then
        ok "Recorded direct-GRUB Boot$recorded is already represented in BootOrder before final normalization"
    else
        ok "Recorded direct-GRUB Boot$recorded remains safely parked outside BootOrder until final normalization"
    fi
    leap16_r77_rewrite_order_without_ids "$extras_csv" >/dev/null || return 1

    for id in "${extras[@]}"; do
        id=${id^^}
        leap16_order_has_id "$(leap16_current_boot_order)" "$id" \
            && { fail "Duplicate direct-GRUB Boot$id remained in BootOrder before deletion"; return 1; }
        sudo efibootmgr -b "$id" -B >/dev/null \
            || { fail "Could not delete bounded duplicate direct-GRUB Boot$id"; return 1; }
        boot_id_exists "$id" && { fail "Firmware still exposes duplicate direct-GRUB Boot$id after deletion"; return 1; }
        ok "Deleted post-stage duplicate direct-GRUB alias Boot$id after removing it from BootOrder"
    done

    ids_after=$(leap16_r77_current_direct_grub_ids | paste -sd, -)
    [[ ${ids_after^^} == "$recorded" ]] \
        || { fail "Direct-GRUB alias normalization did not converge to recorded Boot$recorded (remaining: ${ids_after:-none})"; return 1; }
    ok "Canonical direct-GRUB alias set normalized to recorded Boot$recorded"
}

# Keep matrix status conservative: the automatic r78 GRUB -> rEFInd edge is now
# hardware-proven end-to-end, while rEFInd -> GRUB still needs a fresh automatic
# rerun after r79.  Expose the current release in the matrix heading/ledger.
if declare -F leap16_r64_print_matrix >/dev/null 2>&1; then
    eval "$(declare -f leap16_r64_print_matrix | sed '1s/leap16_r64_print_matrix/leap16_r64_print_matrix_pre_leap16_r79/')"
fi
leap16_r64_print_matrix() {
    local out
    out=$(leap16_r64_print_matrix_pre_leap16_r79 "$@") || return $?
    out=${out//openSUSE Leap 16 bootloader matrix — leap16-r77/openSUSE Leap 16 bootloader matrix — leap16-r79}
    printf '%s\n' "$out"
    cat <<'MATRIX79'

r79 hardware note:
  - r78 GRUB2 -> rEFInd completed automatic runtime proof + automatic finalization on hardware: HW-PROVEN.
  - r78 rEFInd -> GRUB reached runtime-validated GRUB automatically, transferred EFI/BOOT, then failed closed because r77 incorrectly required the parked direct-GRUB alias to already be in BootOrder before final normalization.
  - r79 permits the recorded exact direct-GRUB alias to remain parked until final-order installation; ownership-bounded post-stage duplicates are still removed from BootOrder before deletion.
MATRIX79
}
