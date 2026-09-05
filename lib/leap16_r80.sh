#!/usr/bin/env bash
# leap16-r80: pre-hardware hardening for Limine <-> rEFInd live + restore.
#
# The r64 four-loader adapter already implements all four requested paths.
# r80 applies the ownership lessons learned during the GRUB <-> rEFInd hardware
# campaign before the Limine pair is exercised on hardware:
#   * a Boot#### numeric ID is never claimable merely because it currently
#     resolves to the expected same-ESP path; if that ID existed in the complete
#     pre-stage firmware table, its baseline path+ESP identity must agree;
#   * rEFInd -> Limine converges to exactly one canonical Limine alias and one
#     genuine EFI/BOOT fallback alias before source retirement;
#   * post-stage duplicate aliases are removed from BootOrder before deletion,
#     every deletion is checked, and the exact final topology is re-proven;
#   * fallback-transfer rollback preserves the exact pre-stage fallback alias
#     set and removes only aliases whose IDs were absent before staging.
#
# Backup restore deliberately uses the same staging/runtime/finalization engines,
# so these gates apply equally to live switches and validated backup restores.

LEAP16_R80_LIMINE_PRIMARY_PATH='\EFI\LIMINE\LIMINE_X64.EFI'

leap16_r80_transaction_partuuid() {
    local dev=${PENDING_ESP_SOURCE:-${ESP_SOURCE:-}}
    [[ -n $dev ]] || return 1
    lsblk -no PARTUUID -- "$dev" 2>/dev/null | awk 'NF{print tolower($1); exit}'
}

leap16_r80_baseline_line_for_id() {
    local id=${1^^} baseline
    [[ $id =~ ^[0-9A-F]{4}$ ]] || return 1
    baseline=$(leap16_r64_baseline_path 2>/dev/null || true)
    [[ -n $baseline && -s $baseline ]] || return 1
    grep -Ei "^Boot${id}\\*?[[:space:]]" "$baseline" | head -n1
}

leap16_r80_id_existed_in_baseline() {
    leap16_r80_baseline_line_for_id "$1" >/dev/null 2>&1
}

leap16_r80_require_baseline() {
    local baseline
    baseline=$(leap16_r64_baseline_path 2>/dev/null || true)
    [[ -n $baseline && -s $baseline ]] \
        || { fail 'Complete r64 pre-stage firmware baseline is unavailable; r80 ownership classification is impossible'; return 1; }
}

leap16_r80_baseline_id_matches_path_on_transaction_esp() {
    local id=${1^^} expected=$2 line path norm expected_norm partuuid lower
    line=$(leap16_r80_baseline_line_for_id "$id" 2>/dev/null || true)
    [[ -n $line ]] || return 1
    path=$(efi_path_from_efibootmgr_line "$line" 2>/dev/null || true)
    [[ -n $path ]] || return 1
    norm=$(normalize_efi_path "$path" | tr '[:upper:]' '[:lower:]')
    expected_norm=$(normalize_efi_path "$expected" | tr '[:upper:]' '[:lower:]')
    [[ -n $norm && $norm == "$expected_norm" ]] || return 1
    partuuid=$(leap16_r80_transaction_partuuid 2>/dev/null || true)
    [[ -n $partuuid ]] || return 1
    lower=${line,,}
    [[ $lower == *"gpt,$partuuid,"* ]]
}

leap16_r80_baseline_ids_for_path() {
    local expected=$1 baseline partuuid line id path norm expected_norm lower
    baseline=$(leap16_r64_baseline_path 2>/dev/null || true)
    [[ -n $baseline && -s $baseline ]] || return 1
    partuuid=$(leap16_r80_transaction_partuuid 2>/dev/null || true)
    [[ -n $partuuid ]] || return 1
    expected_norm=$(normalize_efi_path "$expected" | tr '[:upper:]' '[:lower:]')
    [[ -n $expected_norm ]] || return 1
    while IFS= read -r line; do
        [[ $line =~ ^Boot([0-9A-Fa-f]{4})\*?[[:space:]] ]] || continue
        id=${BASH_REMATCH[1]^^}
        path=$(efi_path_from_efibootmgr_line "$line" 2>/dev/null || true)
        [[ -n $path ]] || continue
        norm=$(normalize_efi_path "$path" | tr '[:upper:]' '[:lower:]')
        [[ $norm == "$expected_norm" ]] || continue
        lower=${line,,}; [[ $lower == *"gpt,$partuuid,"* ]] || continue
        printf '%s\n' "$id"
    done <"$baseline" | LC_ALL=C sort -u
}

leap16_r80_current_ids_for_path() {
    local expected=$1 id raw
    # Do not hide a firmware-enumeration failure behind process-substitution
    # success: ownership decisions require a complete current alias set.
    raw=$(leap16_r48_ids_for_current_esp_path "$expected") || return 1
    while IFS= read -r id; do
        id=${id^^}; [[ $id =~ ^[0-9A-F]{4}$ ]] || continue
        leap16_nvram_entry_matches_current_esp "$id" || continue
        nvram_id_matches_path "$id" "$expected" || continue
        printf '%s\n' "$id"
    done <<<"$raw" | LC_ALL=C sort -u
}

# Limine -> rEFInd source retirement: a current source-path alias is claimable
# only when either (a) the same numeric ID was already the same path on this ESP
# in the complete pre-stage table, or (b) that numeric ID did not exist at all
# before staging.  Reuse of a baseline ID from any unrelated entry fails closed.
leap16_r80_verify_limine_source_alias_claims() {
    local path id raw
    [[ ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == limine:refind ]] || return 0
    leap16_r80_require_baseline || return 1
    for path in "$LEAP16_R80_LIMINE_PRIMARY_PATH" "$LEAP16_R21_FALLBACK_EFI_PATH"; do
        raw=$(leap16_r80_current_ids_for_path "$path") || return 1
        while IFS= read -r id; do
            id=${id^^}; [[ $id =~ ^[0-9A-F]{4}$ ]] || continue
            leap16_nvram_entry_matches_current_esp "$id" \
                || { fail "Limine source Boot$id changed ESP binding before retirement"; return 1; }
            nvram_id_matches_path "$id" "$path" \
                || { fail "Limine source Boot$id changed EFI path before retirement"; return 1; }
            if leap16_r80_id_existed_in_baseline "$id"; then
                leap16_r80_baseline_id_matches_path_on_transaction_esp "$id" "$path" \
                    || { fail "Limine source-path Boot$id reuses a pre-stage firmware ID that belonged to another path/ESP; refusing retirement"; return 1; }
            fi
        done <<<"$raw"
    done
    ok 'Every current Limine source alias is baseline-owned at the same path/ESP or uses a post-stage firmware ID'
}

if declare -F leap16_r64_verify_source_alias_superset >/dev/null 2>&1; then
    eval "$(declare -f leap16_r64_verify_source_alias_superset | sed '1s/leap16_r64_verify_source_alias_superset/leap16_r64_verify_source_alias_superset_pre_leap16_r80/')"
fi
leap16_r64_verify_source_alias_superset() {
    leap16_r64_verify_source_alias_superset_pre_leap16_r80 "$@" || return $?
    if [[ ${1:-} == limine && ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == limine:refind ]]; then
        leap16_r80_verify_limine_source_alias_claims || return 1
    fi
    return 0
}

leap16_r80_current_limine_primary_ids() {
    leap16_r80_current_ids_for_path "$LEAP16_R80_LIMINE_PRIMARY_PATH"
}

leap16_r80_current_limine_fallback_ids() {
    leap16_r80_current_ids_for_path "$LEAP16_R21_FALLBACK_EFI_PATH"
}

leap16_r80_validate_limine_keep_aliases() {
    local target=${PENDING_TARGET_BOOT_ID^^} fallback
    leap16_r80_require_baseline || return 1
    fallback=$(leap16_r64_limine_fallback_id 2>/dev/null || true); fallback=${fallback^^}
    [[ $target =~ ^[0-9A-F]{4}$ && $fallback =~ ^[0-9A-F]{4}$ ]] \
        || { fail 'Recorded Limine primary/fallback identities are unavailable'; return 1; }

    boot_id_exists "$target" && leap16_nvram_entry_matches_current_esp "$target" && nvram_id_matches_path "$target" "$LEAP16_R80_LIMINE_PRIMARY_PATH" \
        || { fail "Recorded Limine primary Boot$target is not exact"; return 1; }
    # Limine target namespace was clean at preflight, so the recorded primary ID
    # must not recycle any pre-stage firmware handle, even an unrelated one.
    if leap16_r80_id_existed_in_baseline "$target"; then
        fail "Recorded Limine primary Boot$target reuses a pre-stage firmware ID; refusing ownership"
        return 1
    fi

    boot_id_exists "$fallback" && leap16_nvram_entry_matches_current_esp "$fallback" && nvram_id_matches_path "$fallback" "$LEAP16_R21_FALLBACK_EFI_PATH" \
        || { fail "Recorded Limine fallback Boot$fallback is not exact"; return 1; }
    # The fallback may legitimately be a pre-stage same-ESP EFI/BOOT alias that
    # r64 adopted.  If its ID existed before staging, its baseline identity must
    # be exactly that path on this ESP; otherwise it must be a new ID.
    if leap16_r80_id_existed_in_baseline "$fallback"; then
        leap16_r80_baseline_id_matches_path_on_transaction_esp "$fallback" "$LEAP16_R21_FALLBACK_EFI_PATH" \
            || { fail "Recorded Limine fallback Boot$fallback reuses an unrelated pre-stage firmware ID"; return 1; }
    fi
    return 0
}

leap16_r80_collect_poststage_duplicates() {
    local path=$1 keep=${2^^} id raw
    raw=$(leap16_r80_current_ids_for_path "$path") || return 1
    while IFS= read -r id; do
        id=${id^^}; [[ $id =~ ^[0-9A-F]{4}$ && $id != "$keep" ]] || continue
        leap16_nvram_entry_matches_current_esp "$id" \
            || { fail "Duplicate Boot$id changed ESP binding" >&2; return 1; }
        nvram_id_matches_path "$id" "$path" \
            || { fail "Duplicate Boot$id changed expected EFI path" >&2; return 1; }
        if leap16_r80_id_existed_in_baseline "$id"; then
            fail "Duplicate Boot$id reuses a pre-stage firmware ID; refusing to claim or delete it" >&2
            return 1
        fi
        printf '%s\n' "$id"
    done <<<"$raw"
}

leap16_r80_normalize_limine_aliases_after_fallback_proof() {
    [[ ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == refind:limine \
       && ${PENDING_PHASE:-} == runtime-validated ]] \
        || { fail 'Limine alias normalization requires runtime-validated rEFInd -> Limine state'; return 1; }
    leap16_r64_limine_fallback_staged \
        || { fail 'Limine alias normalization requires the second-proof fallback to be staged'; return 1; }

    local target=${PENDING_TARGET_BOOT_ID^^} fallback id remove_csv primary_csv fallback_csv
    local -a primary_extras=() fallback_extras=() removals=()
    fallback=$(leap16_r64_limine_fallback_id) || return 1; fallback=${fallback^^}
    leap16_r80_validate_limine_keep_aliases || return 1

    local primary_raw fallback_raw
    primary_raw=$(leap16_r80_collect_poststage_duplicates "$LEAP16_R80_LIMINE_PRIMARY_PATH" "$target") || return 1
    fallback_raw=$(leap16_r80_collect_poststage_duplicates "$LEAP16_R21_FALLBACK_EFI_PATH" "$fallback") || return 1
    [[ -z $primary_raw ]] || mapfile -t primary_extras <<<"$primary_raw"
    [[ -z $fallback_raw ]] || mapfile -t fallback_extras <<<"$fallback_raw"
    removals=("${primary_extras[@]}" "${fallback_extras[@]}")

    if ((${#removals[@]})); then
        remove_csv=$(IFS=,; printf '%s' "${removals[*]}")
        leap16_r77_rewrite_order_without_ids "$remove_csv" >/dev/null || return 1
        for id in "${removals[@]}"; do
            id=${id^^}
            leap16_order_has_id "$(leap16_current_boot_order)" "$id" \
                && { fail "Duplicate Limine/fallback Boot$id remained in BootOrder before deletion"; return 1; }
            sudo efibootmgr -b "$id" -B >/dev/null \
                || { fail "Could not delete bounded post-stage Limine/fallback Boot$id"; return 1; }
            boot_id_exists "$id" \
                && { fail "Firmware still exposes duplicate Limine/fallback Boot$id after deletion"; return 1; }
            ok "Deleted post-stage Limine/fallback duplicate Boot$id after removing it from BootOrder"
        done
    fi

    primary_raw=$(leap16_r80_current_limine_primary_ids) || return 1
    fallback_raw=$(leap16_r80_current_limine_fallback_ids) || return 1
    primary_csv=${primary_raw//$'\n'/,}
    fallback_csv=${fallback_raw//$'\n'/,}
    [[ ${primary_csv^^} == "$target" ]] \
        || { fail "Canonical Limine alias set did not converge to recorded Boot$target (remaining: ${primary_csv:-none})"; return 1; }
    [[ ${fallback_csv^^} == "$fallback" ]] \
        || { fail "Limine fallback alias set did not converge to recorded Boot$fallback (remaining: ${fallback_csv:-none})"; return 1; }
    ok "Limine NVRAM aliases are unique: primary Boot$target, fallback Boot$fallback"
}

leap16_r80_assert_exact_limine_topology() {
    local mode=${1:-pre-retirement} target=${PENDING_TARGET_BOOT_ID^^} fallback order pids fids hash next primary_raw fallback_raw refind_raw
    fallback=$(leap16_r64_limine_fallback_id) || return 1; fallback=${fallback^^}
    leap16_r80_validate_limine_keep_aliases || return 1
    primary_raw=$(leap16_r80_current_limine_primary_ids) || return 1
    fallback_raw=$(leap16_r80_current_limine_fallback_ids) || return 1
    pids=${primary_raw//$'\n'/,}
    fids=${fallback_raw//$'\n'/,}
    [[ ${pids^^} == "$target" ]] || { fail "Expected exactly one canonical Limine alias Boot$target; found ${pids:-none}"; return 1; }
    [[ ${fids^^} == "$fallback" ]] || { fail "Expected exactly one Limine fallback alias Boot$fallback; found ${fids:-none}"; return 1; }
    order=$(leap16_current_boot_order) || return 1
    [[ $order == "$target,$fallback"* ]] || { fail "Final Limine BootOrder does not begin $target,$fallback ($order)"; return 1; }
    next=$(pending_bootnext_id 2>/dev/null || true)
    [[ -z $next ]] || { fail "BootNext=Boot${next^^} remains during final Limine topology proof"; return 1; }
    hash=$(r21_hash_privileged "$PENDING_OLD_FALLBACK_PATH")
    [[ -n $hash && $hash == "$PENDING_TARGET_EFI_HASH" ]] \
        || { fail 'EFI/BOOT is not byte-identical to the proven canonical Limine EFI'; return 1; }
    if [[ $mode == final ]]; then
        refind_raw=$(leap16_r64_current_refind_source_ids) || return 1
        [[ -z $(printf '%s\n' "$refind_raw" | awk 'NF') ]] \
            || { fail 'Canonical rEFInd source alias remains in final Limine topology'; return 1; }
    fi
    ok "Exact Limine topology proven ($mode): one primary, one fallback, canonical first/second order"
}

# Normalize before and after the final BootOrder write.  Some firmware creates
# aliases on boot, some on order changes; both are bounded by the same baseline.
if declare -F leap16_r64_final_limine_order >/dev/null 2>&1; then
    eval "$(declare -f leap16_r64_final_limine_order | sed '1s/leap16_r64_final_limine_order/leap16_r64_final_limine_order_pre_leap16_r80/')"
fi
leap16_r64_final_limine_order() {
    if [[ ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == refind:limine ]] && leap16_r64_limine_fallback_staged; then
        leap16_r80_normalize_limine_aliases_after_fallback_proof || return 1
        leap16_r64_final_limine_order_pre_leap16_r80 "$@" || return $?
        leap16_r80_normalize_limine_aliases_after_fallback_proof || return 1
        leap16_r80_assert_exact_limine_topology pre-retirement || return 1
        return 0
    fi
    leap16_r64_final_limine_order_pre_leap16_r80 "$@"
}

# Strict fallback-transfer rollback for rEFInd -> Limine.  Preserve only the
# exact pre-stage same-ESP EFI/BOOT aliases; remove only new IDs, and refuse any
# current fallback alias that recycled an unrelated baseline ID.
if declare -F leap16_r64_restore_pre_limine_fallback_state >/dev/null 2>&1; then
    eval "$(declare -f leap16_r64_restore_pre_limine_fallback_state | sed '1s/leap16_r64_restore_pre_limine_fallback_state/leap16_r64_restore_pre_limine_fallback_state_pre_leap16_r80/')"
fi
leap16_r64_restore_pre_limine_fallback_state() {
    if [[ ${PENDING_SOURCE:-}:${PENDING_TARGET:-} != refind:limine ]] || ! leap16_r64_limine_fallback_staged; then
        leap16_r64_restore_pre_limine_fallback_state_pre_leap16_r80 "$@"
        return $?
    fi

    local fallback next id b baseline_csv current_csv remove_csv pre primary_hash pm
    local -a baseline=() current=() extras=()
    fallback=$(leap16_r64_limine_fallback_id) || return 1; fallback=${fallback^^}
    next=$(pending_bootnext_id 2>/dev/null || true)
    if [[ -n $next ]]; then
        [[ ${next^^} == "$fallback" ]] || { fail "Unrelated BootNext=Boot${next^^} blocks Limine fallback rollback"; return 1; }
        sudo efibootmgr -N >/dev/null || { fail 'Could not clear transaction-owned fallback BootNext during rollback'; return 1; }
        [[ -z $(pending_bootnext_id 2>/dev/null || true) ]] || { fail 'BootNext remained set after rollback clear'; return 1; }
    fi

    local baseline_raw current_raw
    leap16_r80_require_baseline || return 1
    baseline_raw=$(leap16_r80_baseline_ids_for_path "$LEAP16_R21_FALLBACK_EFI_PATH") || return 1
    [[ -z $baseline_raw ]] || mapfile -t baseline <<<"$baseline_raw"
    ((${#baseline[@]} <= 1)) || { fail "Pre-stage baseline contains ${#baseline[@]} same-ESP EFI/BOOT aliases; rollback ownership is ambiguous"; return 1; }
    current_raw=$(leap16_r80_current_limine_fallback_ids) || return 1
    [[ -z $current_raw ]] || mapfile -t current <<<"$current_raw"

    # Prove baseline-owned aliases still exist unchanged before any mutation.
    for b in "${baseline[@]}"; do
        boot_id_exists "$b" || { fail "Baseline fallback Boot$b disappeared; exact rollback is impossible"; return 1; }
        leap16_nvram_entry_matches_current_esp "$b" && nvram_id_matches_path "$b" "$LEAP16_R21_FALLBACK_EFI_PATH" \
            || { fail "Baseline fallback Boot$b changed path/ESP; exact rollback is impossible"; return 1; }
    done

    for id in "${current[@]}"; do
        id=${id^^}; [[ $id =~ ^[0-9A-F]{4}$ ]] || continue
        local keep=0
        for b in "${baseline[@]}"; do [[ $id == ${b^^} ]] && { keep=1; break; }; done
        ((keep)) && continue
        if leap16_r80_id_existed_in_baseline "$id"; then
            fail "Fallback Boot$id reuses a pre-stage firmware ID from another entry; refusing rollback deletion"
            return 1
        fi
        leap16_nvram_entry_matches_current_esp "$id" && nvram_id_matches_path "$id" "$LEAP16_R21_FALLBACK_EFI_PATH" \
            || { fail "Post-stage fallback Boot$id changed path/ESP; refusing rollback deletion"; return 1; }
        extras+=("$id")
    done

    if ((${#extras[@]})); then
        remove_csv=$(IFS=,; printf '%s' "${extras[*]}")
        leap16_r77_rewrite_order_without_ids "$remove_csv" >/dev/null || return 1
        for id in "${extras[@]}"; do
            leap16_order_has_id "$(leap16_current_boot_order)" "$id" \
                && { fail "Post-stage fallback Boot$id remained in BootOrder before rollback deletion"; return 1; }
            sudo efibootmgr -b "$id" -B >/dev/null \
                || { fail "Could not delete post-stage fallback Boot$id during rollback"; return 1; }
            boot_id_exists "$id" && { fail "Post-stage fallback Boot$id remains after rollback deletion"; return 1; }
            ok "Removed post-stage fallback Boot$id during exact rollback"
        done
    fi

    current_raw=$(leap16_r80_current_limine_fallback_ids) || return 1
    current_csv=${current_raw//$'\n'/,}
    baseline_csv=$(IFS=,; printf '%s' "${baseline[*]}")
    [[ ${current_csv^^} == ${baseline_csv^^} ]] \
        || { fail "Fallback alias set did not return to pre-stage baseline (baseline ${baseline_csv:-none}, current ${current_csv:-none})"; return 1; }

    if [[ ${PENDING_OLD_FALLBACK_EXISTED:-0} == 1 ]]; then
        [[ -f ${PENDING_OLD_FALLBACK_SNAPSHOT:-} ]] || { fail 'Pre-stage fallback snapshot is missing'; return 1; }
        r21_atomic_replace "$PENDING_OLD_FALLBACK_SNAPSHOT" "$PENDING_OLD_FALLBACK_PATH" "$PENDING_OLD_FALLBACK_HASH" || return 1
    else
        sudo rm -f -- "$PENDING_OLD_FALLBACK_PATH" || return 1
        (sudo -n test ! -e "$PENDING_OLD_FALLBACK_PATH" 2>/dev/null || [[ ! -e $PENDING_OLD_FALLBACK_PATH ]]) \
            || { fail 'Generic fallback file remained although it was absent before staging'; return 1; }
    fi

    pre=$(leap16_r64_limine_preconf_path) || return 1
    primary_hash=$(leap16_r64_meta_value limine_primary_conf_hash)
    [[ -f $pre && $primary_hash =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
    r21_atomic_replace "$pre" "${PENDING_ESP_MOUNT%/}/limine.conf" "$primary_hash" || return 1
    pm=$(leap16_r64_limine_primary_manifest_path)
    [[ -s $pm ]] && cp -f -- "$pm" "$PENDING_TARGET_MANIFEST" || leap16_r64_refresh_limine_manifest || return 1
    r21_order_primary_then_source_recovery || return 1
    leap16_r64_write_meta refind:limine '' "$primary_hash" || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    leap16_r64_verify_refind_source_passive || return 1

    current_raw=$(leap16_r80_current_limine_fallback_ids) || return 1
    current_csv=${current_raw//$'\n'/,}
    [[ ${current_csv^^} == ${baseline_csv^^} ]] \
        || { fail "Final rollback fallback alias set drifted from baseline (baseline ${baseline_csv:-none}, current ${current_csv:-none})"; return 1; }
    ok 'Restored exact pre-stage EFI/BOOT alias/byte topology and primary-Limine + rEFInd recovery state'
}

# Replace the r64 rEFInd -> Limine finalizer with the same two-proof contract,
# but make target normalization and final topology proof strict and retry-safe.
if declare -F leap16_r64_retire_refind_after_limine_fallback_proof >/dev/null 2>&1; then
    eval "$(declare -f leap16_r64_retire_refind_after_limine_fallback_proof | sed '1s/leap16_r64_retire_refind_after_limine_fallback_proof/leap16_r64_retire_refind_after_limine_fallback_proof_pre_leap16_r80/')"
fi
leap16_r64_retire_refind_after_limine_fallback_proof() {
    local target=${PENDING_TARGET_BOOT_ID^^} fallback final_hash detail
    [[ ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == refind:limine ]] \
        || { leap16_r64_retire_refind_after_limine_fallback_proof_pre_leap16_r80 "$@"; return $?; }

    leap16_r64_validate_limine_fallback_runtime || return 1
    fallback=$(leap16_r64_limine_fallback_id) || return 1; fallback=${fallback^^}

    # Normalize firmware churn while rEFInd recovery is still intact.
    leap16_r80_normalize_limine_aliases_after_fallback_proof || return 1

    # Freeze the final Limine config/manifest before deleting recovery source.
    final_hash=$(leap16_r64_remove_limine_refind_recovery_block) || return 1
    leap16_r64_refresh_limine_manifest || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_limine_boot_chain migration || return 1
    [[ $(r21_hash_privileged "${PENDING_ESP_MOUNT%/}/limine.conf") == "$final_hash" ]] \
        || { fail 'Final Limine config hash changed before rEFInd retirement'; return 1; }
    leap16_r64_verify_refind_source_passive || return 1
    leap16_r51_set_final_limine_policy || return 1

    # Install exact primary/fallback order and re-normalize aliases created by
    # that order write.  The source EFI still exists at this boundary.
    leap16_r64_final_limine_order || return 1
    leap16_r80_assert_exact_limine_topology pre-retirement || return 1
    leap16_r64_verify_refind_source_passive || return 1
    r26_verify_owned_manifest "$PENDING_SOURCE_MANIFEST" || return 1

    leap16_r64_delete_refind_source || return 1

    # Source retirement can itself provoke firmware churn; bound it again and
    # require exact-one primary/fallback identities before success is recorded.
    leap16_r80_normalize_limine_aliases_after_fallback_proof || return 1
    detect_bootloader
    [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == "$fallback" ]] \
        || { fail "Final Limine proof requires BootCurrent=Boot$fallback"; return 1; }
    leap16_r80_assert_exact_limine_topology final || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_limine_boot_chain migration || return 1
    [[ $(r21_hash_privileged "${PENDING_ESP_MOUNT%/}/limine.conf") == "$final_hash" ]] || return 1
    pending_capture_runtime_diagnostics finalized-limine-from-refind >/dev/null 2>&1 || true

    if [[ -n ${PENDING_BACKUP_PATH:-} ]]; then
        detail="rEFInd -> restored Limine backup completed with two independent runtime proofs. Primary Limine Boot$target is first; genuine Limine fallback Boot$fallback second; duplicate target aliases are ownership-normalized; exact rEFInd source retired. Backup: $PENDING_BACKUP_PATH"
    else
        detail="rEFInd -> Limine completed with two independent runtime proofs. Primary Limine Boot$target is first; genuine Limine fallback Boot$fallback second; duplicate target aliases are ownership-normalized; exact rEFInd source retired."
    fi
    r35_write_local_transaction_result success "$detail" || true
    remove_pending_transaction_snapshot || true
    rm -f -- "$PENDING_STATE_FILE"
    printf '\nFINALIZED rEFInd -> Limine after canonical + EFI/BOOT proofs.\n'
}

# Matrix evidence entering the Limine <-> rEFInd campaign.  r80 changes no
# HW-PENDING Limine/rEFInd cell to proven; it only records the now-complete
# GRUB/rEFInd live+restore hardware results from Sep 5.
leap16_r64_print_matrix() {
    cat <<'MATRIX'
openSUSE Leap 16 bootloader matrix — leap16-r80

Legend:
  HW-PROVEN       completed automatically on real hardware with exact final topology
  HW-PENDING      implemented + regression-covered; complete hardware run pending
  —               same-backend; not a cross-loader edge

LIVE SWITCH MATRIX (source rows -> target columns)
                 GRUB2        Limine       systemd-boot  rEFInd
  GRUB2          —            HW-PROVEN    HW-PROVEN     HW-PROVEN
  Limine         HW-PROVEN    —            HW-PROVEN     HW-PENDING
  systemd-boot   HW-PROVEN    HW-PROVEN    —             HW-PENDING
  rEFInd         HW-PROVEN    HW-PENDING    HW-PENDING    —

CROSS-LOADER RESTORE MATRIX (active source -> restored backup target)
                 GRUB2        Limine       systemd-boot  rEFInd
  GRUB2          —            HW-PROVEN    HW-PROVEN     HW-PROVEN
  Limine         HW-PROVEN    —            HW-PROVEN     HW-PENDING
  systemd-boot   HW-PROVEN    HW-PROVEN    —             HW-PENDING
  rEFInd         HW-PROVEN    HW-PENDING    HW-PENDING    —

BACKUP BACKENDS
  GRUB2          HW-PROVEN
  Limine         HW-PROVEN
  systemd-boot   HW-PROVEN
  rEFInd         HW-PROVEN

r80 hardware scope:
  - GRUB2 <-> rEFInd live and cross-loader restore are HW-PROVEN in both directions.
  - Limine <-> rEFInd live and cross-loader restore remain HW-PENDING.
  - r80 applies complete pre-stage Boot#### ownership checks, exact-one Limine primary/fallback final topology, and strict fallback-transfer rollback before that campaign.
MATRIX
}
