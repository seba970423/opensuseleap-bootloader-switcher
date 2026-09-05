#!/usr/bin/env bash
# leap16-r53: accept and safely reuse one firmware-synthesized same-ESP
# generic-fallback Boot#### when starting systemd-boot -> Limine.
#
# Hardware showed that the finalized systemd-boot state can later acquire a
# redundant `UEFI OS` alias for \EFI\BOOT\BOOTX64.EFI even though r48 removed
# all such aliases during its own finalization.  r51 incorrectly treated the
# mere existence of that exact alias as dirty state.  r53 snapshots it as
# pre-existing firmware state, requires it to remain exact through the primary
# proof, and (after EFI/BOOT is transferred to Limine) adopts that same Boot####
# as the genuine Limine fallback.  No pre-confirmation mutation is introduced.

leap16_r53_current_fallback_ids() {
    r21_fallback_ids_now | awk '/^[0-9A-Fa-f]{4}$/{print toupper($0)}' | LC_ALL=C sort -u
}

leap16_r53_current_fallback_alias_gate() {
    local id
    local -a ids=()
    mapfile -t ids < <(leap16_r53_current_fallback_ids)
    ((${#ids[@]} <= 1)) || {
        fail "Generic-fallback NVRAM path is ambiguous before staging (${#ids[@]} exact same-ESP aliases)"
        return 1
    }
    if ((${#ids[@]} == 0)); then
        ok 'No pre-stage generic-fallback NVRAM alias is present'
        return 0
    fi
    id=${ids[0]^^}
    [[ $id != ${BOOT_CURRENT^^} ]] || { fail "Generic-fallback Boot$id unexpectedly equals canonical systemd-boot BootCurrent"; return 1; }
    leap16_boot_entry_is_active "$id" || { fail "Pre-stage generic-fallback Boot$id is not active"; return 1; }
    leap16_nvram_entry_matches_current_esp "$id" || { fail "Pre-stage generic-fallback Boot$id is not bound to the current ESP"; return 1; }
    nvram_id_matches_path "$id" "$LEAP16_R21_FALLBACK_EFI_PATH" || { fail "Pre-stage generic-fallback Boot$id changed EFI path"; return 1; }
    ok "One exact firmware fallback alias is present (Boot$id); it will be frozen in the transaction baseline and reused as Limine fallback if it remains exact"
}

# r51's source gate required zero same-ESP EFI/BOOT aliases.  That is too
# strict for firmware that synthesizes a UEFI OS alias after systemd-boot has
# already finalized.  Keep every other source invariant unchanged.
leap16_r51_systemd_source_gate() {
    local ids order
    leap16_r34_validate_systemd_boot_chain source || return 1
    grep -Eq '^[[:space:]]*LOADER_TYPE=.*systemd-boot' /etc/sysconfig/bootloader 2>/dev/null \
        || { fail 'openSUSE LOADER_TYPE is not systemd-boot'; return 1; }
    ids=$(leap16_r38_current_systemd_ids | paste -sd, -)
    [[ -n $ids && $ids != *,* && ${ids^^} == ${BOOT_CURRENT^^} ]] \
        || { fail "Expected exactly one canonical systemd-boot NVRAM alias matching BootCurrent; found ${ids:-none}"; return 1; }
    order=$(leap16_current_boot_order)
    [[ ${order%%,*} == ${BOOT_CURRENT^^} ]] || { fail "Persistent BootOrder is not source systemd-boot Boot${BOOT_CURRENT^^} first ($order)"; return 1; }
    leap16_r38_source_fallback_exact || return 1
    leap16_r53_current_fallback_alias_gate || return 1
    ok 'Finalized systemd-boot source is canonical and source-first; EFI/BOOT ownership is exact even if firmware exposed one redundant same-path alias'
}

leap16_r53_baseline_fallback_ids() {
    leap16_r43_baseline_fallback_ids | awk '/^[0-9A-Fa-f]{4}$/{print toupper($0)}' | LC_ALL=C sort -u
}

# Before Limine owns EFI/BOOT, the exact same-ESP fallback alias set must equal
# the complete pre-stage firmware baseline.  This freezes a firmware-created
# UEFI OS alias as source recovery state instead of pretending it is absent.
leap16_r53_verify_pretransfer_fallback_alias_set() {
    local baseline_csv current_csv id
    local -a baseline=() current=()
    mapfile -t baseline < <(leap16_r53_baseline_fallback_ids)
    mapfile -t current < <(leap16_r53_current_fallback_ids)
    ((${#baseline[@]} <= 1)) || { fail "Pre-stage firmware baseline contains ${#baseline[@]} same-ESP generic-fallback aliases; ownership is ambiguous"; return 1; }
    baseline_csv=$(IFS=,; printf '%s' "${baseline[*]}")
    current_csv=$(IFS=,; printf '%s' "${current[*]}")
    [[ $current_csv == "$baseline_csv" ]] || {
        fail "Generic-fallback alias set changed since the pre-stage firmware baseline (baseline ${baseline_csv:-none}, current ${current_csv:-none})"
        return 1
    }
    for id in "${baseline[@]}"; do
        leap16_boot_entry_is_active "$id" || { fail "Baseline fallback Boot$id is no longer active"; return 1; }
        leap16_nvram_entry_matches_current_esp "$id" || { fail "Baseline fallback Boot$id changed ESP binding"; return 1; }
        nvram_id_matches_path "$id" "$LEAP16_R21_FALLBACK_EFI_PATH" || { fail "Baseline fallback Boot$id changed EFI path"; return 1; }
    done
    if ((${#baseline[@]} == 1)); then
        ok "Pre-transfer fallback alias remains exactly the frozen firmware baseline: Boot${baseline[0]}"
    else
        ok 'Pre-transfer fallback alias set remains empty exactly as frozen in the firmware baseline'
    fi
}

# Extend the source-recovery proof only for the reverse direct edge and only
# before fallback ownership transfer.  Other proven paths are untouched.
eval "$(declare -f verify_pending_source_recovery_unchanged | sed '1s/verify_pending_source_recovery_unchanged/verify_pending_source_recovery_unchanged_pre_leap16_r53/')"
verify_pending_source_recovery_unchanged() {
    verify_pending_source_recovery_unchanged_pre_leap16_r53 "$@" || return $?
    if leap16_r51_pending && ! leap16_r51_fallback_staged; then
        leap16_r53_verify_pretransfer_fallback_alias_set || return 1
    fi
    return 0
}

# If transfer rollback is needed, preserve baseline fallback aliases and remove
# only aliases that appeared after the baseline.  Restoring EFI/BOOT then makes
# the preserved alias point to the original byte-identical systemd-boot again.
eval "$(declare -f r21_remove_staging_fallback_aliases | sed '1s/r21_remove_staging_fallback_aliases/r21_remove_staging_fallback_aliases_pre_leap16_r53/')"
r21_remove_staging_fallback_aliases() {
    local id b failures=0 keep=0
    local -a baseline=()
    if ! leap16_r51_pending; then
        r21_remove_staging_fallback_aliases_pre_leap16_r53 "$@"
        return $?
    fi
    mapfile -t baseline < <(leap16_r53_baseline_fallback_ids)
    for b in "${baseline[@]}"; do
        boot_id_exists "$b" || { fail "Baseline fallback Boot$b disappeared during transfer rollback"; failures=$((failures + 1)); continue; }
        leap16_nvram_entry_matches_current_esp "$b" || { fail "Baseline fallback Boot$b changed ESP binding during rollback"; failures=$((failures + 1)); continue; }
        nvram_id_matches_path "$b" "$LEAP16_R21_FALLBACK_EFI_PATH" || { fail "Baseline fallback Boot$b changed path during rollback"; failures=$((failures + 1)); continue; }
    done
    while IFS= read -r id; do
        [[ $id =~ ^[0-9A-Fa-f]{4}$ ]] || continue
        id=${id^^}; keep=0
        for b in "${baseline[@]}"; do [[ $id == "$b" ]] && { keep=1; break; }; done
        if ((keep)); then
            ok "Preserved pre-stage firmware fallback Boot$id during rollback"
            continue
        fi
        leap16_nvram_entry_matches_current_esp "$id" || { fail "Refusing to remove post-baseline fallback Boot$id because its ESP binding changed"; failures=$((failures + 1)); continue; }
        nvram_id_matches_path "$id" "$LEAP16_R21_FALLBACK_EFI_PATH" || { fail "Refusing to remove post-baseline fallback Boot$id because its EFI path changed"; failures=$((failures + 1)); continue; }
        if sudo efibootmgr -b "$id" -B >/dev/null 2>&1; then
            ok "Removed post-baseline fallback alias Boot$id during rollback"
        else
            fail "Could not remove post-baseline fallback alias Boot$id during rollback"
            failures=$((failures + 1))
        fi
    done < <(leap16_r53_current_fallback_ids)
    ((failures == 0))
}

leap16_r53_remove_ids_from_bootorder() {
    local remove_csv=$1 order id joined remove=0 r
    local -a current=() out=() removals=()
    IFS=',' read -ra removals <<<"$remove_csv"
    order=$(leap16_current_boot_order) || return 1
    IFS=',' read -ra current <<<"$order"
    for id in "${current[@]}"; do
        id=${id^^}; [[ -n $id ]] || continue; remove=0
        for r in "${removals[@]}"; do [[ -n $r && $id == ${r^^} ]] && { remove=1; break; }; done
        ((remove)) || out+=("$id")
    done
    ((${#out[@]} > 0)) || { fail 'Refusing to empty BootOrder while normalizing post-baseline fallback churn'; return 1; }
    joined=$(IFS=,; printf '%s' "${out[*]}")
    [[ $joined == "$order" ]] || sudo efibootmgr -o "$joined" >/dev/null || return 1
}

# If firmware synthesizes another EFI/BOOT alias after the payload transfer
# while a baseline alias already exists, retire only the post-baseline churn so
# the baseline alias can be adopted deterministically as the Limine fallback.
eval "$(declare -f r21_create_or_adopt_fallback_alias | sed '1s/r21_create_or_adopt_fallback_alias/r21_create_or_adopt_fallback_alias_pre_leap16_r53/')"
r21_create_or_adopt_fallback_alias() {
    local baseline_id id extras_csv=''
    local -a baseline=() current=() extras=()
    if leap16_r51_pending && ! leap16_r51_fallback_staged; then
        mapfile -t baseline < <(leap16_r53_baseline_fallback_ids)
        if ((${#baseline[@]} == 1)); then
            baseline_id=${baseline[0]^^}
            mapfile -t current < <(leap16_r53_current_fallback_ids)
            local saw=0
            for id in "${current[@]}"; do
                if [[ $id == "$baseline_id" ]]; then saw=1; else extras+=("$id"); fi
            done
            ((saw)) || { fail "Pre-stage fallback Boot$baseline_id disappeared before Limine fallback adoption"; return 1; }
            if ((${#extras[@]})); then
                extras_csv=$(IFS=,; printf '%s' "${extras[*]}")
                leap16_r53_remove_ids_from_bootorder "$extras_csv" || return 1
                for id in "${extras[@]}"; do
                    leap16_nvram_entry_matches_current_esp "$id" || { fail "Post-baseline fallback Boot$id changed ESP binding"; return 1; }
                    nvram_id_matches_path "$id" "$LEAP16_R21_FALLBACK_EFI_PATH" || { fail "Post-baseline fallback Boot$id changed EFI path"; return 1; }
                    sudo efibootmgr -b "$id" -B >/dev/null || { fail "Could not delete post-baseline fallback churn Boot$id"; return 1; }
                    ok "Deleted post-baseline fallback churn Boot$id before adopting baseline Boot$baseline_id" >&2
                done
            fi
        fi
    fi
    r21_create_or_adopt_fallback_alias_pre_leap16_r53 "$@"
}

# Same r51 two-proof finalizer, except the pre-transfer boundary now requires
# equality with the frozen baseline rather than the impossible global-zero
# assumption.
leap16_r51_promote_and_stage_fallback() {
    local source=${PENDING_OLD_BOOT_ID^^} target=${PENDING_TARGET_BOOT_ID^^} order conf_hash fallback_hash fallback_id before next primary_manifest
    validate_pending_compatibility || { fail "Pending transaction is incompatible: $PENDING_REASON"; return 1; }
    leap16_r51_pending || return 1
    [[ $PENDING_PHASE == runtime-validated ]] || { fail 'Fallback staging requires primary Limine runtime proof'; return 1; }
    leap16_r51_fallback_staged && { fail 'The Limine fallback proof is already staged'; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == "$target" ]] || { fail 'Fallback staging must run from the canonical runtime-proven Limine session'; return 1; }
    leap16_r51_validate_primary_runtime || return 1
    order=$(leap16_current_boot_order)
    if [[ ${order%%,*} == "$source" ]]; then
        adapter_target_promote "$target" "$source" || { fail 'Could not promote runtime-proven canonical Limine while retaining systemd-boot recovery'; return 1; }
    fi
    [[ $(leap16_current_boot_order | cut -d, -f1,2) == "$target,$source" ]] || { fail 'Canonical Limine/systemd-boot promoted recovery topology is not exact'; return 1; }
    verify_pending_candidate_ownership_unchanged || return 1
    verify_pending_source_recovery_unchanged || return 1
    leap16_r53_verify_pretransfer_fallback_alias_set || return 1

    primary_manifest=$(leap16_r51_primary_manifest_path) || return 1
    cp -f -- "$PENDING_TARGET_MANIFEST" "$primary_manifest" || return 1
    chmod 600 -- "$primary_manifest" 2>/dev/null || true
    conf_hash=$(leap16_r51_rewrite_recovery_to_direct_systemd) || { fail 'Could not redirect Limine recovery directly to canonical systemd-boot before EFI/BOOT transfer'; return 1; }
    if ! r21_atomic_replace "$PENDING_TARGET_EFI_RESOLVED" "$PENDING_OLD_FALLBACK_PATH" "$PENDING_TARGET_EFI_HASH"; then
        leap16_r51_restore_pre_fallback_state || true
        return 1
    fi
    fallback_hash=$(r21_hash_privileged "$PENDING_OLD_FALLBACK_PATH")
    [[ $fallback_hash == "$PENDING_TARGET_EFI_HASH" ]] || { leap16_r51_restore_pre_fallback_state || true; fail 'Limine fallback hash verification failed after transfer'; return 1; }
    fallback_id=$(r21_create_or_adopt_fallback_alias) || { leap16_r51_restore_pre_fallback_state || true; return 1; }
    fallback_id=${fallback_id^^}
    leap16_r51_refresh_target_manifest || { leap16_r51_restore_pre_fallback_state || true; return 1; }
    leap16_r51_write_fallback_meta "$fallback_id" "$fallback_hash" "$conf_hash" || { leap16_r51_restore_pre_fallback_state || true; return 1; }
    order=$(r21_order_primary_fallback_then_existing "$fallback_id") || { leap16_r51_restore_pre_fallback_state || true; return 1; }
    leap16_r51_verify_transferred_limine || { leap16_r51_restore_pre_fallback_state || true; return 1; }
    before=$(leap16_current_boot_order)
    sudo efibootmgr -n "$fallback_id" >/dev/null || { leap16_r51_restore_pre_fallback_state || true; return 1; }
    next=$(pending_bootnext_id)
    if [[ ${next^^} != "$fallback_id" || $(leap16_current_boot_order) != "$before" ]]; then
        [[ ${next^^} == "$fallback_id" ]] && sudo efibootmgr -N >/dev/null 2>&1 || true
        leap16_r51_restore_pre_fallback_state || true
        fail 'Limine fallback BootNext arming changed persistent BootOrder or failed exact verification'
        return 1
    fi
    pending_capture_runtime_diagnostics fallback-armed-limine-from-systemd >/dev/null 2>&1 || true
    printf '\nPRIMARY PROOF COMPLETE. Genuine Limine EFI fallback is now staged for the second proof.\n'
    printf '  Persistent BootOrder: %s\n' "$order"
    printf '  BootNext:             Boot%s -> %s\n' "$fallback_id" "$LEAP16_R21_FALLBACK_EFI_PATH"
    printf '  systemd-boot Boot%s remains intact behind the two Limine paths until that exact fallback BootCurrent is proven.\n' "$source"
}

leap16_r51_plan() {
    printf '\nExact openSUSE systemd-boot -> Limine two-proof plan:\n'
    printf '  1. Re-prove finalized canonical systemd-boot, byte-identical EFI/BOOT, source-first BootOrder and empty BootNext.\n'
    printf '  2. Freeze zero or one exact same-ESP firmware EFI/BOOT alias from the pre-stage table; reject any ambiguous alias set.\n'
    printf '  3. Snapshot exact systemd-boot-owned BLS/payload/EFI state, EFI/BOOT and the complete pre-stage firmware table.\n'
    printf '  4. Stage the pinned Limine EFI + CachyOS r47 theme + exact Leap kernel/initrd copies without touching EFI/BOOT.\n'
    printf '  5. Create one parked canonical Limine Boot####, keep systemd-boot persistent first, and arm only Limine with BootNext.\n'
    printf '  6. After real canonical Limine userspace arrival, prove BootCurrent/kernel/root/cmdline/target ownership while systemd-boot and the frozen fallback alias set remain exact.\n'
    printf '  7. Promote proven canonical Limine, redirect temporary recovery directly to canonical systemd-boot, transfer EFI/BOOT to byte-identical Limine, and reuse the frozen fallback alias when present (otherwise create/adopt one exact alias).\n'
    printf '  8. Require a second real boot whose BootCurrent is that exact EFI/BOOT fallback.\n'
    printf '  9. Only after the second proof: remove systemd-boot from BootOrder/NVRAM, retire exact systemd-owned files, remove the temporary recovery entry, and leave Limine primary + genuine fallback first/second.\n'
    printf '  If either proof fails, ownership-proven systemd-boot recovery remains available.\n'
}
