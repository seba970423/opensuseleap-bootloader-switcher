#!/usr/bin/env bash
# leap16-r85: repair the missing rEFInd -> systemd-boot runtime validator.
#
# First hardware run of the final rEFInd/systemd-boot matrix reached the exact
# staged systemd-boot target (BootCurrent == PENDING_TARGET_BOOT_ID) with the
# original rEFInd source still persistent-first.  The r64 root-owned resume
# correctly recognized the rEFInd edge, but its generic runtime-proof call fell
# through every direction-specific overlay and eventually reached Leap's ancient
# GRUB2 -> Limine validator, which rejected the real systemd-boot session with:
#
#   Current bootloader is systemd-boot, not Limine
#
# No source retirement or finalization ran.  r85 adds only the missing outbound
# rEFInd -> systemd-boot runtime dispatcher/validator.  Staging, systemd target
# construction, r64 ownership/finalization, restore payload substitution and all
# other bootloader edges remain unchanged.

leap16_r85_refind_systemd_pending() {
    [[ ${PENDING_SOURCE:-} == refind && ${PENDING_TARGET:-} == systemd-boot ]]
}

leap16_r85_validate_refind_systemd_runtime() {
    local target=${PENDING_TARGET_BOOT_ID^^} source=${PENDING_OLD_BOOT_ID^^}
    local next order first diag

    validate_pending_compatibility || { fail "Pending transaction is incompatible: $PENDING_REASON"; return 1; }
    leap16_r85_refind_systemd_pending || { fail 'r85 runtime validator is restricted to rEFInd -> systemd-boot'; return 1; }
    [[ $PENDING_PHASE == boot-armed || $PENDING_PHASE == runtime-validated ]] || {
        fail "Runtime validation requires boot-armed/runtime-validated state (phase is $PENDING_PHASE)"
        return 1
    }

    detect_bootloader
    [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == "$target" ]] || {
        fail "rEFInd -> systemd-boot runtime proof requires exact systemd-boot Boot$target (detected $(bootloader_display_name "$BOOTLOADER") Boot${BOOT_CURRENT:-unknown})"
        return 1
    }
    nvram_id_matches_path "$target" "$PENDING_TARGET_EFI_PATH" || {
        fail 'BootCurrent systemd-boot NVRAM entry no longer has the recorded exact EFI path'
        return 1
    }
    leap16_nvram_entry_matches_current_esp "$target" || {
        fail 'BootCurrent systemd-boot entry is no longer bound to the transaction ESP'
        return 1
    }
    leap16_require_sudo_session || return 1

    run_validation preflight || return 1

    next=$(pending_bootnext_id)
    if [[ -n $next && ${next^^} != "$target" ]]; then
        fail "BootNext belongs to unrelated Boot${next^^}; refusing runtime certification"
        return 1
    elif [[ -n $next && ${next^^} == "$target" ]]; then
        warn "Firmware still reports consumed transaction BootNext=Boot${next^^}; clearing only that exact transaction value"
        sudo efibootmgr -N >/dev/null || return 1
        [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext remained set after explicit clear'; return 1; }
    else
        ok 'BootNext was consumed/cleared by firmware after the one-time systemd-boot boot'
    fi

    # Before first proof the persistent source-first order is mandatory.  On a
    # retry after proof was already persisted, target-first is also acceptable
    # because r64 finalization may have completed its promotion gate before a
    # later fail-closed check stopped retirement.  In either case the rEFInd
    # recovery bytes/aliases are re-proven below before any further mutation.
    order=$(leap16_current_boot_order) || return 1
    first=${order%%,*}; first=${first^^}
    if [[ $PENDING_PHASE == boot-armed ]]; then
        [[ $first == "$source" ]] || {
            fail "Persistent BootOrder drifted before first proof; expected rEFInd source Boot$source first ($order)"
            return 1
        }
        ok "Persistent BootOrder still keeps rEFInd source Boot$source first"
    else
        [[ $first == "$source" || $first == "$target" ]] || {
            fail "Persistent BootOrder has unexpected first entry during proven-target retry ($order)"
            return 1
        }
    fi

    pending_validate_running_kernel || return 1
    pending_validate_runtime_cmdline_against_source || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    leap16_r34_validate_systemd_boot_chain runtime || return 1
    leap16_r64_verify_refind_source_passive || return 1

    if [[ $PENDING_PHASE == boot-armed ]]; then
        pending_set_phase runtime-validated || { fail 'Runtime proof passed but runtime-validated phase could not be persisted'; return 1; }
        PENDING_PHASE=runtime-validated
    fi
    [[ $PENDING_PHASE == runtime-validated ]] || return 1

    diag=$(pending_capture_runtime_diagnostics runtime-pass-systemd-from-refind | tail -n1 || true)
    [[ -n $diag ]] && printf 'Runtime diagnostic snapshot: %s\n' "$diag"
    r35_write_local_transaction_result runtime-validated \
        "rEFInd -> systemd-boot runtime proof passed. BootCurrent is the exact native systemd-boot target; rEFInd remains ownership-proven recovery and no source retirement has run." || true
    printf '\nRUNTIME-VALIDATED rEFInd -> systemd-boot one-time boot succeeded.\n'
    printf '  BootCurrent: Boot%s -> %s\n' "$target" "$PENDING_TARGET_EFI_PATH"
    printf '  rEFInd Boot%s remains intact until r64 finalization proves the target-native EFI/BOOT topology.\n' "$source"
}

# Load last so only the one missing direction is intercepted.  Every existing
# runtime validator (including inbound * -> rEFInd, rEFInd -> GRUB/Limine and
# all non-rEFInd edges) remains byte-for-byte reachable through delegation.
if declare -F validate_pending_target_runtime >/dev/null 2>&1; then
    eval "$(declare -f validate_pending_target_runtime | sed '1s/validate_pending_target_runtime/validate_pending_target_runtime_pre_leap16_r85/')"
fi
validate_pending_target_runtime() {
    if leap16_r85_refind_systemd_pending; then
        leap16_r85_validate_refind_systemd_runtime
    else
        validate_pending_target_runtime_pre_leap16_r85 "$@"
    fi
}

# Keep the matrix honest: the first r84 hardware run proves target arrival only;
# the edge remains HW-PENDING until r85 completes runtime proof + r64 retirement.
leap16_r64_print_matrix() {
    cat <<'MATRIX'
openSUSE Leap 16 bootloader matrix — leap16-r85

Legend:
  HW-PROVEN       completed automatically on real hardware with exact final topology
  HW-PENDING      implemented; complete hardware evidence still required
  —               same-backend; not a cross-loader edge

LIVE SWITCH MATRIX (source rows -> target columns)
                 GRUB2        Limine       systemd-boot  rEFInd
  GRUB2          —            HW-PROVEN    HW-PROVEN     HW-PROVEN
  Limine         HW-PROVEN    —            HW-PROVEN     HW-PROVEN
  systemd-boot   HW-PROVEN    HW-PROVEN    —             HW-PENDING
  rEFInd         HW-PROVEN    HW-PROVEN    HW-PENDING    —

CROSS-LOADER RESTORE MATRIX (active source -> restored backup target)
                 GRUB2        Limine       systemd-boot  rEFInd
  GRUB2          —            HW-PROVEN    HW-PROVEN     HW-PROVEN
  Limine         HW-PROVEN    —            HW-PROVEN     HW-PROVEN
  systemd-boot   HW-PROVEN    HW-PROVEN    —             HW-PENDING
  rEFInd         HW-PROVEN    HW-PROVEN    HW-PENDING    —

BACKUP BACKENDS
  GRUB2          HW-PROVEN
  Limine         HW-PROVEN
  systemd-boot   HW-PROVEN
  rEFInd         HW-PROVEN

r85 evidence scope:
  - Sep 5 r84 hardware staged rEFInd Boot0001 -> systemd-boot Boot0000 correctly.
  - BootNext=0000 booted the exact systemd-boot target while persistent BootOrder
    remained recovery-first as 0001,0000.
  - The r64 root-owned resume then reached a stale Limine-only runtime validator
    and failed with "Current bootloader is systemd-boot, not Limine".
  - No systemd-boot runtime proof, promotion, EFI/BOOT transfer or rEFInd
    retirement was authorized by that failed run.
  - r85 adds the missing exact rEFInd -> systemd-boot runtime validator; the same
    path also covers restored-systemd backup targets from an active rEFInd source.
  - Both systemd-boot <-> rEFInd live and restore directions remain HW-PENDING
    until complete end-to-end hardware finalization evidence is captured.
MATRIX
}
