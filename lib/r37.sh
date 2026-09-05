#!/usr/bin/env bash
# r37: make the direct rEFInd -> Limine live edge tolerant of historical,
# inactive Limine filesystem residue without weakening ownership guarantees.
#
# r36 required a pristine Limine namespace. Real hardware exposed an old
# /boot/EFI/LIMINE tree left from earlier hardware testing. r37 reuses r30's
# already-proven residue snapshot/restore machinery: after the active rEFInd
# source is snapshotted, every inactive adapter-owned Limine filesystem path is
# copied into the transaction snapshot, byte/tree-verified, and cleared before
# fresh Limine staging. Uncommitted rollback and explicit pending rollback put
# those exact bytes back. Successful runtime proof discards the quarantine only
# after the new Limine target has earned finalization authority.
#
# A pre-existing canonical Limine NVRAM entry is still refused. Recreating an
# exact foreign Boot#### identity is not deterministic, so r37 does not pretend
# that such firmware state can be quarantined losslessly.

# Read-only preflight for historical Limine filesystem residue. This does not
# mutate anything: the actual snapshot+clear happens only after STAGE and only
# after the rEFInd source adapter snapshot exists.
r37_limine_live_target_preflight() {
    local path found=0

    if find_nvram_entry_for_target limine; then
        fail "Target Limine NVRAM entry Boot$TARGET_NVRAM_ID already exists; firmware ownership is ambiguous."
        fail "${SWITCHER_RELEASE:-r37} will preserve inactive Limine filesystem residue, but it will not delete/recreate an unowned canonical Limine Boot#### entry."
        return 1
    fi

    while IFS= read -r path; do
        [[ -n $path ]] || continue
        if sudo -n test -e "$path" 2>/dev/null || sudo -n test -L "$path" 2>/dev/null || [[ -e $path || -L $path ]]; then
            found=1
            if sudo -n test -L "$path" 2>/dev/null || [[ -L $path ]]; then
                fail "Inactive Limine target residue is a top-level symlink and cannot be quarantined safely: $path"
                return 1
            fi
            if sudo -n test -d "$path" 2>/dev/null || [[ -d $path ]]; then
                if sudo -n find "$path" -type l -print -quit 2>/dev/null | grep -q .; then
                    fail "Inactive Limine target residue tree contains a symlink and cannot be quarantined safely: $path"
                    return 1
                fi
            elif ! sudo -n test -f "$path" 2>/dev/null && [[ ! -f $path ]]; then
                fail "Inactive Limine target residue is not a regular file/directory: $path"
                return 1
            fi
            info "Inactive Limine target residue detected and eligible for transactional quarantine at write time: $path"
        fi
    done < <(r26_adapter_paths limine)

    ((found == 0)) && ok 'Limine target filesystem namespace is clean' || \
        info 'Inactive Limine filesystem residue will be snapshotted, verified, cleared, and rollback-protected only after STAGE.'

    validate_existing_boot_artifacts_for_limine_stage || {
        fail 'Existing conventional kernel/initramfs artifacts are incomplete; refusing Limine live staging.'
        return 1
    }
    return 0
}

# Replace r36's pristine-target gate with the transactional residue-aware gate.
r36_limine_live_target_clean() {
    r37_limine_live_target_preflight
}

# r26 snapshots the authoritative rEFInd source immediately before calling the
# target stage. Interpose at that point so r30's residue quarantine lives inside
# the same transaction snapshot and is therefore available to both uncommitted
# and committed rollback paths.
eval "$(declare -f adapter_target_stage | sed '1s/adapter_target_stage/adapter_target_stage_pre_r37/')"
adapter_target_stage() {
    local target=$1 source_id=$2 original_order=$3 reference=$4
    if [[ ${BOOTLOADER:-} == refind && $target == limine ]]; then
        [[ -n ${TRANSACTION_SNAPSHOT_DIR:-} && -d ${TRANSACTION_SNAPSHOT_DIR:-/nonexistent} ]] || {
            fail 'r37 Limine residue quarantine requires the authoritative source transaction snapshot to exist first.'
            return 1
        }
        if ! r30_prepare_limine_target_residue; then
            fail 'Could not snapshot/verify/clear inactive Limine target residue before fresh live staging.'
            return 1
        fi
        r36_stage_limine_target "$source_id" "$original_order" "$reference"
        return $?
    fi
    adapter_target_stage_pre_r37 "$@"
}

# r30 already makes uncommitted target cleanup residue-aware for every Limine
# target. Extend the committed/manual rollback path to the new rEFInd -> Limine
# live direction as well.
r37_rollback_pending_refind_limine() {
    validate_pending_compatibility || return 1
    detect_bootloader
    [[ $BOOTLOADER == "$PENDING_SOURCE" && $BOOT_CURRENT == "$PENDING_OLD_BOOT_ID" ]] || {
        fail "${SWITCHER_RELEASE:-r37} rollback is allowed only from the recorded rEFInd source session"
        return 1
    }
    verify_pending_source_recovery_unchanged || return 1
    verify_pending_candidate_ownership_unchanged || return 1

    local next
    next=$(pending_bootnext_id)
    [[ -z $next || $next == "$PENDING_TARGET_BOOT_ID" ]] || {
        fail "Unrelated BootNext=Boot$next exists; refusing rollback"
        return 1
    }
    [[ $next != "$PENDING_TARGET_BOOT_ID" ]] || sudo efibootmgr -N >/dev/null || return 1
    r22_disarm_user_resume_bundle || true

    if boot_id_exists "$PENDING_TARGET_BOOT_ID"; then
        sudo efibootmgr -b "$PENDING_TARGET_BOOT_ID" -B >/dev/null || return 1
    fi
    r26_remove_owned_manifest_paths "$PENDING_TARGET_MANIFEST" || return 1
    r30_restore_limine_target_residue "$PENDING_TRANSACTION_SNAPSHOT_DIR" || return 1
    r26_restore_fallback_on_rollback || return 1
    sudo efibootmgr -o "$PENDING_ORIGINAL_BOOT_ORDER" >/dev/null || return 1
    remove_pending_transaction_snapshot || true
    rm -f -- "$PENDING_STATE_FILE"
    ok "Rolled back the ${SWITCHER_RELEASE:-r37} rEFInd -> Limine candidate; exact pre-stage inactive Limine filesystem residue was restored and rEFInd remains authoritative."
}

eval "$(declare -f rollback_pending_candidate | sed '1s/rollback_pending_candidate/rollback_pending_candidate_pre_r37/')"
rollback_pending_candidate() {
    if [[ $(r26_state_format) == "$R26_PENDING_FORMAT" ]]; then
        load_pending_state || return 1
        if [[ $PENDING_SOURCE == refind && $PENDING_TARGET == limine ]]; then
            r37_rollback_pending_refind_limine
            return $?
        fi
    fi
    rollback_pending_candidate_pre_r37 "$@"
}

# Update the r36 plan text so the UI describes what r37 will actually do.
eval "$(declare -f show_operation_plan | sed '1s/show_operation_plan/show_operation_plan_pre_r37/')"
show_operation_plan() {
    local current=$1 target=$2
    if [[ $current == refind && $target == limine ]]; then
        printf '\n%s adapter transaction plan:\n' "${SWITCHER_RELEASE:-r37}"
        printf '  SOURCE adapter (rEFInd): validate -> snapshot immutable state -> preserve recovery -> retire only after Limine proof.\n'
        printf '  TARGET adapter (Limine): quarantine inactive residue -> fresh stage -> deep-validate -> arm -> runtime_validate -> promote -> final_validate.\n'
        printf '  1. Deep-validate the active rEFInd source and snapshot its exact immutable ownership/recovery state.\n'
        printf '  2. If inactive Limine filesystem residue exists, snapshot and byte/tree-verify it inside the transaction, then clear only those adapter-owned paths. A pre-existing canonical Limine NVRAM entry is still refused.\n'
        printf '  3. Install the CachyOS Limine stack, generate the captured CachyOS theme/policy from the proven runtime cmdline, and stage every installed kernel/initramfs.\n'
        printf '  4. Run limine-install plus its fallback stage, then immediately restore rEFInd first in persistent BootOrder and restore the exact pre-stage shared EFI fallback.\n'
        printf '  5. Deep-validate Limine and re-prove the untouched rEFInd source before arming Limine exactly once with BootNext.\n'
        printf '  6. After Limine reaches userspace, prove BootCurrent/kernel/root/cmdline/ownership through the temporary resume service.\n'
        printf '  7. Only after proof: promote Limine, retire ownership-proven rEFInd state, materialize the Limine fallback only when the shared fallback is transaction-safe, and validate Limine again.\n'
        printf '  If staging/rollback fails before proof, the exact quarantined Limine residue is restored and rEFInd remains authoritative.\n'
        return 0
    fi
    show_operation_plan_pre_r37 "$@"
}
