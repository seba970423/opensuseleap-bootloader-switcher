#!/usr/bin/env bash
# leap16-r49: make Limine -> systemd-boot finalization phase-aware after the
# target has already been promoted first in BootOrder.
#
# r48 correctly promoted the runtime-proven systemd-boot Boot#### first, but
# then re-used the r48 source-recovery verifier whose final clause still
# demanded Limine primary/fallback to remain first/second.  That contradiction
# intentionally failed closed before fallback transfer or source retirement,
# leaving a safe target-first + intact-Limine recovery topology.  r49 accepts
# exactly that transaction-owned promoted topology while preserving every
# source byte/path/manifest/fallback ownership check.

leap16_r49_verify_limine_recovery_after_systemd_promotion() {
    local source=${PENDING_OLD_BOOT_ID^^} target=${PENDING_TARGET_BOOT_ID^^}
    local fallback ids order fallback_hash
    local -a order_ids=()

    leap16_r48_pending || { fail 'r49 promoted recovery proof is restricted to Limine -> systemd-boot'; return 1; }
    [[ ${PENDING_PHASE:-} == runtime-validated ]] || { fail 'r49 promoted recovery proof requires runtime-validated state'; return 1; }

    # Reuse the complete pre-r48 format-v5 source proof.  That checks the exact
    # primary Limine NVRAM path, source EFI hash, source ownership manifest,
    # Limine fallback hash, and deep Limine/theme validation, but does not bake
    # in the r48 source-first ordering assertion that promotion intentionally
    # invalidates.
    verify_pending_source_recovery_unchanged_pre_leap16_r48 "$@" || return $?

    leap16_r48_validate_meta || { fail "$PENDING_REASON"; return 1; }
    fallback=$(leap16_r48_fallback_id) || { fail 'Could not resolve the ownership-proven Limine fallback Boot####'; return 1; }

    boot_id_exists "$source" || { fail "Ownership-proven Limine primary Boot$source disappeared after systemd-boot promotion"; return 1; }
    leap16_nvram_entry_matches_current_esp "$source" || { fail "Limine primary Boot$source changed ESP ownership after promotion"; return 1; }
    nvram_id_matches_path "$source" "$PENDING_OLD_BOOT_EFI_PATH" || { fail "Limine primary Boot$source changed EFI path after promotion"; return 1; }

    boot_id_exists "$fallback" || { fail "Ownership-proven Limine fallback Boot$fallback disappeared after systemd-boot promotion"; return 1; }
    leap16_nvram_entry_matches_current_esp "$fallback" || { fail "Limine fallback Boot$fallback changed ESP ownership after promotion"; return 1; }
    nvram_id_matches_path "$fallback" "$LEAP16_R21_FALLBACK_EFI_PATH" || { fail "Limine fallback Boot$fallback changed EFI path after promotion"; return 1; }

    ids=$(leap16_r48_current_fallback_ids | paste -sd, -)
    [[ ${ids^^} == "$fallback" ]] || { fail "Limine fallback alias set changed after promotion (expected Boot$fallback, found ${ids:-none})"; return 1; }

    fallback_hash=$(r21_hash_privileged "$PENDING_OLD_FALLBACK_PATH" 2>/dev/null || true)
    [[ -n $fallback_hash && $fallback_hash == "$PENDING_OLD_FALLBACK_HASH" ]] || { fail 'Limine generic fallback bytes changed before the deliberate systemd-boot fallback transfer'; return 1; }

    order=$(leap16_current_boot_order)
    IFS=',' read -ra order_ids <<<"$order"
    [[ ${order_ids[0]:-} == "$target" ]] || { fail "Promoted topology no longer has systemd-boot Boot$target first ($order)"; return 1; }
    [[ ${order_ids[1]:-} == "$source" ]] || { fail "Promoted topology no longer has Limine primary Boot$source second ($order)"; return 1; }
    [[ ${order_ids[2]:-} == "$fallback" ]] || { fail "Promoted topology no longer has Limine fallback Boot$fallback third ($order)"; return 1; }

    ok "Phase-aware recovery proof accepted promoted topology: systemd-boot Boot$target first, Limine primary Boot$source second, Limine fallback Boot$fallback third"
}

# Preserve r48's strict source-first proof before promotion.  Once the exact
# runtime-proven systemd-boot target is already first, switch to the equally
# strict promoted-topology proof above.  This also makes an r48 transaction
# stranded at the safe post-promotion checkpoint resumable under r49.
eval "$(declare -f verify_pending_source_recovery_unchanged | sed '1s/verify_pending_source_recovery_unchanged/verify_pending_source_recovery_unchanged_pre_leap16_r49/')"
verify_pending_source_recovery_unchanged() {
    local order first
    if leap16_r48_pending && [[ ${PENDING_PHASE:-} == runtime-validated ]]; then
        detect_bootloader
        if [[ ${BOOTLOADER:-} == systemd-boot && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]]; then
            order=$(leap16_current_boot_order 2>/dev/null || true)
            first=${order%%,*}; first=${first^^}
            if [[ -n $first && $first == ${PENDING_TARGET_BOOT_ID^^} ]]; then
                leap16_r49_verify_limine_recovery_after_systemd_promotion "$@"
                return $?
            fi
        fi
    fi
    verify_pending_source_recovery_unchanged_pre_leap16_r49 "$@"
}
