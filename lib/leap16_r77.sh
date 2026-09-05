#!/usr/bin/env bash
# leap16-r77: close the rEFInd -> native GRUB duplicate-direct-alias hole.
#
# Hardware evidence from the r76 automatic run showed ASUS/openSUSE creating a
# second same-ESP \EFI\OPENSUSE\GRUBX64.EFI alias (with firmware optional data)
# during the one-shot shim boot.  r76 correctly retired rEFInd, but its final
# GRUB order only required the recorded shim/direct prefix and therefore left
# the synthesized direct-GRUB alias in BootOrder/NVRAM.
#
# r77 treats that alias exactly like the already-proven r30/r68 duplicate
# classes: tolerate it during read-only runtime proof, then only after persisted
# runtime proof prove exact path+ESP ownership and absence from the complete
# pre-stage firmware baseline, remove it from BootOrder first, delete it, and
# converge to the recorded direct-GRUB identity before source retirement.

leap16_r77_refind_grub_runtime_validated() {
    [[ ${PENDING_FORMAT:-} == "${R26_PENDING_FORMAT:-5}" \
       && ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == refind:grub \
       && ${PENDING_PHASE:-} == runtime-validated ]]
}

leap16_r77_current_direct_grub_ids() {
    local id
    while IFS= read -r id; do
        id=${id^^}; [[ $id =~ ^[0-9A-F]{4}$ ]] || continue
        leap16_nvram_entry_matches_current_esp "$id" || continue
        nvram_id_matches_path "$id" "$R28_GRUB_DIRECT_PATH" || continue
        printf '%s\n' "$id"
    done < <(leap16_r48_ids_for_current_esp_path "$R28_GRUB_DIRECT_PATH") | LC_ALL=C sort -u
}

leap16_r77_rewrite_order_without_ids() {
    local remove_csv=$1 order id joined skip rid
    local -a cur=() out=() remove=()
    order=$(leap16_current_boot_order) || return 1
    IFS=',' read -ra remove <<<"$remove_csv"
    IFS=',' read -ra cur <<<"$order"
    for id in "${cur[@]}"; do
        id=${id^^}; [[ $id =~ ^[0-9A-F]{4}$ ]] || continue
        skip=0
        for rid in "${remove[@]}"; do
            [[ -n $rid && $id == ${rid^^} ]] && { skip=1; break; }
        done
        ((skip)) && continue
        boot_id_exists "$id" && out+=("$id")
    done
    ((${#out[@]} > 0)) || { fail 'Refusing to install an empty BootOrder during duplicate-GRUB normalization'; return 1; }
    joined=$(IFS=,; printf '%s' "${out[*]}")
    [[ $joined == "$order" ]] || sudo efibootmgr -o "$joined" >/dev/null \
        || { fail 'Could not remove duplicate direct-GRUB aliases from BootOrder'; return 1; }
    printf '%s\n' "$joined"
}

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
    leap16_order_has_id "$order" "$recorded" || { fail "Recorded direct-GRUB Boot$recorded is not represented in BootOrder before final normalization"; return 1; }
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

# Normalize immediately before the final GRUB order is installed, then repeat
# after that BootOrder write.  Some firmware synthesizes aliases in response to
# the boot itself, and some does it in response to an order update.
if declare -F leap16_r64_final_grub_order >/dev/null 2>&1; then
    eval "$(declare -f leap16_r64_final_grub_order | sed '1s/leap16_r64_final_grub_order/leap16_r64_final_grub_order_pre_leap16_r77/')"
fi
leap16_r64_final_grub_order() {
    if leap16_r77_refind_grub_runtime_validated; then
        leap16_r77_normalize_refind_grub_direct_aliases_after_proof || return 1
        leap16_r64_final_grub_order_pre_leap16_r77 "$@" || return $?
        leap16_r77_normalize_refind_grub_direct_aliases_after_proof || return 1
        local target=${PENDING_TARGET_BOOT_ID^^} direct order ids
        direct=$(leap16_r64_grub_direct_id) || return 1; direct=${direct^^}
        order=$(leap16_current_boot_order) || return 1
        [[ $order == "$target,$direct"* ]] || { fail 'Final GRUB order lost canonical shim/direct prefix after duplicate normalization'; return 1; }
        ids=$(leap16_r77_current_direct_grub_ids | paste -sd, -)
        [[ ${ids^^} == "$direct" ]] || { fail "Final GRUB direct alias set is not unique (found ${ids:-none})"; return 1; }
        return 0
    fi
    leap16_r64_final_grub_order_pre_leap16_r77 "$@"
}

# Tighten r76's diagnostic-only final report so an r76-style trailing duplicate
# can no longer be labeled as an exact finalized topology.
if declare -F leap16_r76_write_final_refind_edge_order_report >/dev/null 2>&1; then
    eval "$(declare -f leap16_r76_write_final_refind_edge_order_report | sed '1s/leap16_r76_write_final_refind_edge_order_report/leap16_r76_write_final_refind_edge_order_report_pre_leap16_r77/')"
fi
leap16_r76_write_final_refind_edge_order_report() {
    local out=$1 direction=${PENDING_SOURCE:-}:${PENDING_TARGET:-}
    leap16_r76_write_final_refind_edge_order_report_pre_leap16_r77 "$@" || return $?
    [[ $direction == refind:grub ]] || return 0
    local direct ids
    direct=$(leap16_r64_grub_direct_id 2>/dev/null || true); direct=${direct^^}
    ids=$(leap16_r77_current_direct_grub_ids | paste -sd, -)
    if [[ $direct =~ ^[0-9A-F]{4}$ && ${ids^^} != "$direct" ]]; then
        sed -i \
            -e 's/^assessment=.*/assessment=fail/' \
            -e "s|^reason=.*|reason=finalized direct-GRUB alias set is not unique (expected $direct; found ${ids:-none})|" \
            "$out"
    fi
}

# Recovery for the already-finalized r76 hardware residue.  This is an explicit
# same-backend NVRAM-only action: no boot files are rewritten.  It is offered
# through the existing GRUB2 (repair/reinstall) selector only when the current
# GRUB filesystem is already deeply valid and the sole defect is duplicate
# same-ESP direct-GRUB aliases.
leap16_r77_grub_duplicate_residue_shape() {
    [[ ${BOOTLOADER:-} == grub ]] || return 1
    local order shim direct_count
    order=$(leap16_current_boot_order 2>/dev/null || true); [[ -n $order ]] || return 1
    shim=${order%%,*}; shim=${shim^^}
    [[ $shim == ${BOOT_CURRENT^^} ]] || return 1
    nvram_id_matches_path "$shim" "$R28_GRUB_SHIM_PATH" || return 1
    leap16_nvram_entry_matches_current_esp "$shim" || return 1
    direct_count=$(leap16_r77_current_direct_grub_ids | awk 'NF{n++} END{print n+0}')
    ((direct_count > 1))
}

leap16_r77_cleanup_finalized_grub_duplicates_inner() {
    pending_exists && { fail 'A staged migration is pending; finalized GRUB alias cleanup will not stack transactions'; return 1; }
    leap16_require_sudo_session || return 1
    run_validation preflight || return 1
    validate_grub_boot_chain current || { fail 'Current GRUB filesystem/boot chain is not deeply valid; duplicate-only cleanup is refused'; return 1; }
    [[ -z $(pending_bootnext_id 2>/dev/null || true) ]] || { fail 'BootNext is set; duplicate-only GRUB cleanup is refused'; return 1; }

    local order shim keep id new_order ids_after
    local -a cur=() direct_ids=() extras=() out=()
    order=$(leap16_current_boot_order) || return 1
    IFS=',' read -ra cur <<<"$order"
    ((${#cur[@]} >= 2)) || { fail 'Canonical GRUB BootOrder needs shim first and direct GRUB second'; return 1; }
    shim=${cur[0]^^}; keep=${cur[1]^^}
    [[ $shim == ${BOOT_CURRENT^^} ]] || { fail "Current Boot${BOOT_CURRENT^^} is not the first persistent shim alias"; return 1; }
    nvram_id_matches_path "$shim" "$R28_GRUB_SHIM_PATH" && leap16_nvram_entry_matches_current_esp "$shim" \
        || { fail "First/current Boot$shim is not the canonical same-ESP shim"; return 1; }
    nvram_id_matches_path "$keep" "$R28_GRUB_DIRECT_PATH" && leap16_nvram_entry_matches_current_esp "$keep" \
        || { fail "Second persistent Boot$keep is not canonical same-ESP direct GRUB"; return 1; }

    mapfile -t direct_ids < <(leap16_r77_current_direct_grub_ids)
    ((${#direct_ids[@]} > 1)) || { ok "Direct-GRUB alias set is already unique: Boot$keep"; return 0; }
    case " ${direct_ids[*]} " in *" $keep "*) ;; *) fail "Second persistent Boot$keep is missing from direct-GRUB alias set"; return 1 ;; esac
    for id in "${direct_ids[@]}"; do id=${id^^}; [[ $id == "$keep" ]] || extras+=("$id"); done

    printf '\nFinalized native GRUB duplicate-alias cleanup:\n'
    printf '  Keep shim Boot%s first and direct GRUB Boot%s second.\n' "$shim" "$keep"
    printf '  Remove only exact same-ESP duplicate direct-GRUB alias(es): Boot%s\n' "$(IFS=' Boot'; printf '%s' "${extras[*]}")"
    printf '  No EFI/GRUB filesystem bytes will be changed.\n\n'
    read -r -p 'Type CLEAN to normalize NVRAM, or anything else to cancel: ' answer
    [[ $answer == CLEAN ]] || { printf 'Cleanup cancelled. No boot state was modified.\n'; return 0; }

    # Re-prove at the write boundary.
    detect_bootloader
    [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == "$shim" ]] || { fail 'GRUB identity changed before cleanup write boundary'; return 1; }
    validate_grub_boot_chain current || return 1
    order=$(leap16_current_boot_order) || return 1
    [[ $order == "$shim,$keep"* ]] || { fail 'Canonical shim/direct leading order changed before cleanup'; return 1; }

    for id in "${cur[@]}"; do
        id=${id^^}; [[ $id =~ ^[0-9A-F]{4}$ ]] || continue
        case " ${extras[*]} " in *" $id "*) continue ;; esac
        boot_id_exists "$id" && out+=("$id")
    done
    new_order=$(IFS=,; printf '%s' "${out[*]}")
    sudo efibootmgr -o "$new_order" >/dev/null || { fail 'Could not remove duplicate direct-GRUB aliases from BootOrder'; return 1; }
    for id in "${extras[@]}"; do
        leap16_order_has_id "$(leap16_current_boot_order)" "$id" && { fail "Duplicate direct-GRUB Boot$id remained in BootOrder before deletion"; return 1; }
        sudo efibootmgr -b "$id" -B >/dev/null || { fail "Could not delete duplicate direct-GRUB Boot$id"; return 1; }
        boot_id_exists "$id" && { fail "Duplicate direct-GRUB Boot$id remains visible after deletion"; return 1; }
        ok "Removed ownership-bounded duplicate direct-GRUB Boot$id"
    done
    ids_after=$(leap16_r77_current_direct_grub_ids | paste -sd, -)
    [[ ${ids_after^^} == "$keep" ]] || { fail "Direct-GRUB cleanup did not converge to Boot$keep (remaining: ${ids_after:-none})"; return 1; }
    [[ $(leap16_current_boot_order) == "$shim,$keep"* ]] || { fail 'Final BootOrder is not canonical shim/direct first/second'; return 1; }
    validate_grub_boot_chain current || return 1
    ok "Finalized native GRUB NVRAM topology is canonical: shim Boot$shim first, direct GRUB Boot$keep second, no duplicate direct aliases"
}

if declare -F run_live_operation >/dev/null 2>&1; then
    eval "$(declare -f run_live_operation | sed '1s/run_live_operation/run_live_operation_pre_leap16_r77/')"
fi
run_live_operation() {
    local target=${1:-} current
    detect_bootloader; current=$BOOTLOADER
    if [[ $current:$target == grub:grub ]] && leap16_r77_grub_duplicate_residue_shape; then
        leap16_r44_with_transaction_transcript "$current" "$target" cleanup leap16_r77_cleanup_finalized_grub_duplicates_inner
        return $?
    fi
    run_live_operation_pre_leap16_r77 "$@"
}

# Update matrix evidence: the r76 automatic rEFInd -> GRUB run reached and
# finalized the intended target, but the firmware-synthesized duplicate direct
# alias escaped normalization.  Keep the edge HW-PENDING until r77 closes that
# cleanup automatically on hardware.
leap16_r64_print_matrix() {
    cat <<'MATRIX'
openSUSE Leap 16 bootloader matrix — leap16-r77

Legend:
  HW-PROVEN       completed automatically on real hardware with exact final topology
  HW-PENDING      implemented + regression-covered; complete hardware run pending
  —               same-backend; not a cross-loader edge

LIVE SWITCH MATRIX (source rows -> target columns)
                 GRUB2        Limine       systemd-boot  rEFInd
  GRUB2          —            HW-PROVEN    HW-PROVEN     HW-PROVEN
  Limine         HW-PROVEN    —            HW-PROVEN     HW-PENDING
  systemd-boot   HW-PROVEN    HW-PROVEN    —             HW-PENDING
  rEFInd         HW-PENDING   HW-PENDING    HW-PENDING    —

CROSS-LOADER RESTORE MATRIX (active source -> restored backup target)
                 GRUB2        Limine       systemd-boot  rEFInd
  GRUB2          —            HW-PROVEN    HW-PROVEN     HW-PENDING
  Limine         HW-PROVEN    —            HW-PROVEN     HW-PENDING
  systemd-boot   HW-PROVEN    HW-PROVEN    —             HW-PENDING
  rEFInd         HW-PENDING   HW-PENDING    HW-PENDING    —

BACKUP BACKENDS
  GRUB2          HW-PROVEN
  Limine         HW-PROVEN
  systemd-boot   HW-PROVEN
  rEFInd         HW-PROVEN

r76/r77 hardware checkpoint:
  GRUB2 -> rEFInd is HW-PROVEN automatically.
  rEFInd -> GRUB reached automatic runtime proof and source retirement under r76, but ASUS synthesized Boot0003 -> EFI/OPENSUSE/GRUBX64.EFI during the one-shot boot.
  r76 retained recorded direct GRUB Boot0001 but accepted the duplicate because final validation checked only the shim/direct prefix and recorded alias, not uniqueness.
  r77 ownership-bounds and deletes post-stage same-path/same-ESP direct-GRUB duplicates after runtime proof and requires exact-one direct-GRUB final topology. The edge remains HW-PENDING until rerun.
MATRIX
}
