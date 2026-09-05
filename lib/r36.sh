#!/usr/bin/env bash
# r36: first direct non-GRUB live adapter edge (rEFInd -> Limine) plus
# release-aware user-facing adapter labels.
#
# The dangerous transaction choreography remains the inherited format-5 r26
# adapter engine. r36 opens only the rEFInd -> Limine live direction after
# composing the already-proven rEFInd source contract with a fresh Limine
# target stage. Other non-GRUB live edges remain closed until separately
# reviewed and hardware-tested.

# r30 extended the format-5 parser only for its Limine <-> systemd-boot restore
# pairs. Admit the new rEFInd -> Limine live pair without broadening the matrix.
eval "$(declare -f load_pending_state | sed '1s/load_pending_state/load_pending_state_pre_r36/')"
load_pending_state() {
    if [[ $(r26_state_format) != "$R26_PENDING_FORMAT" ]]; then
        load_pending_state_pre_r36 "$@"
        return $?
    fi

    if load_pending_state_pre_r36 "$@"; then
        return 0
    fi
    [[ ${PENDING_REASON:-} == 'unsupported r26 adapter migration direction' ]] || return 1
    case "${PENDING_SOURCE:-}:${PENDING_TARGET:-}" in
        refind:limine) ;;
        *) return 1 ;;
    esac

    # The inherited parser already decoded the complete format-5 record before
    # stopping at its old direction gate. Re-apply the remaining integrity
    # checks exactly as the adapter engine requires.
    [[ $PENDING_FORMAT == "$R26_PENDING_FORMAT" ]] || { PENDING_REASON='wrong r26 state format'; return 1; }
    [[ $PENDING_ADAPTER_REVISION == "$R26_ADAPTER_REVISION" ]] || { PENDING_REASON='unsupported adapter-state revision'; return 1; }
    [[ -n $PENDING_MACHINE_ID && -n $PENDING_OLD_BOOT_ID && -n $PENDING_TARGET_BOOT_ID ]] || { PENDING_REASON='missing transaction identity'; return 1; }
    [[ -n $PENDING_SOURCE_CMDLINE ]] || { PENDING_REASON='missing source kernel command line'; return 1; }
    [[ -n $PENDING_SOURCE_MANIFEST && -n $PENDING_TARGET_MANIFEST ]] || { PENDING_REASON='missing adapter ownership manifests'; return 1; }
    PENDING_REASON='valid'
    return 0
}

# A fresh live Limine target must start from an unambiguous namespace. The
# restore engine can preserve historical inactive Limine residue, but the new
# live edge intentionally stays narrower: if any Limine-owned live path or
# canonical NVRAM entry is already present, do not guess ownership.
r36_limine_live_target_clean() {
    local path
    if find_nvram_entry_for_target limine; then
        fail "Target Limine NVRAM entry Boot$TARGET_NVRAM_ID already exists; ownership is ambiguous."
        return 1
    fi
    while IFS= read -r path; do
        [[ -n $path ]] || continue
        if sudo -n test -e "$path" 2>/dev/null || sudo -n test -L "$path" 2>/dev/null || [[ -e $path || -L $path ]]; then
            fail "Target Limine namespace already exists: $path"
            fail 'r36 live migration refuses to reuse inactive Limine residue; remove/restore it through an ownership-proven path first.'
            return 1
        fi
    done < <(r26_adapter_paths limine)
    validate_existing_boot_artifacts_for_limine_stage || {
        fail 'Existing conventional kernel/initramfs artifacts are incomplete; refusing Limine live staging.'
        return 1
    }
    return 0
}

# Compose a fresh CachyOS-themed Limine target inside the generic adapter
# transaction. Limine may touch BootOrder and EFI/BOOT while installing, so the
# source is restored first immediately and the shared fallback is returned to
# the exact pre-stage source state until runtime proof.
r36_stage_limine_target() {
    local source_id=$1 original_order=$2 reference=$3 target_id='' install_rc=0
    : "$reference" # policy generation intentionally reads the proven running /proc/cmdline

    install_target_packages limine || return 1
    have limine-install || { fail 'limine-install is unavailable after package installation'; return 1; }
    have limine-entry-tool || { fail 'limine-entry-tool is unavailable after package installation'; return 1; }

    write_limine_candidate_policy || return 1
    stage_limine_kernel_entries_from_existing_artifacts || return 1

    sudo limine-install || install_rc=$?
    if ((install_rc == 0)); then
        sudo limine-install --fallback || install_rc=$?
    fi

    if find_nvram_entry_for_target limine; then
        target_id=${TARGET_NVRAM_ID^^}
        set_source_first_boot_order "$source_id" "$target_id" "$original_order" || {
            fail "Could not restore $(bootloader_display_name "${BOOTLOADER:-source}") as the persistent first BootOrder entry after Limine installation."
            return 1
        }
    else
        [[ -n $original_order ]] && sudo efibootmgr -o "$original_order" >/dev/null 2>&1 || true
    fi

    # limine-install --fallback is allowed to create/touch the shared fallback
    # during staging, but the candidate does not own that path yet. Restore the
    # exact pre-stage source/foreign fallback until Limine earns runtime proof.
    r26_restore_source_fallback_after_target_stage || return 1

    ((install_rc == 0)) || { fail "limine-install exited with status $install_rc after potentially touching EFI/NVRAM state"; return 1; }
    [[ $target_id =~ ^[0-9A-F]{4}$ ]] || { fail 'Could not find the canonical Limine NVRAM entry after limine-install'; return 1; }

    adapter_target_validate limine || return 1
    r26_record_target_adapter limine || return 1
    R26_STAGED_TARGET_ID=$target_id
    ok "Staged canonical CachyOS-themed Limine NVRAM target as Boot$R26_STAGED_TARGET_ID"
}

# Extend the adapter target contract only for Limine. Existing target staging
# stays exactly on the inherited implementations.
eval "$(declare -f adapter_target_stage | sed '1s/adapter_target_stage/adapter_target_stage_pre_r36/')"
adapter_target_stage() {
    local target=$1 source_id=$2 original_order=$3 reference=$4
    if [[ $target == limine ]]; then
        r36_stage_limine_target "$source_id" "$original_order" "$reference"
        return $?
    fi
    adapter_target_stage_pre_r36 "$@"
}

# Route exactly one new live edge through the generic adapter preflight.
eval "$(declare -f r26_generic_preflight | sed '1s/r26_generic_preflight/r26_generic_preflight_pre_r36/')"
r26_generic_preflight() {
    local target=$1
    if [[ ${BOOTLOADER:-} != refind || $target != limine ]]; then
        r26_generic_preflight_pre_r36 "$@"
        return $?
    fi

    printf '\n%s adapter preflight:\n' "${SWITCHER_RELEASE:-r36}"
    run_validation preflight || { fail 'Base preflight failed; no boot state was modified'; return 1; }
    is_cachyos || { fail "${SWITCHER_RELEASE:-r36} live adapters are restricted to CachyOS/Arch-like systems"; return 1; }
    if bootcurrent_is_generic_fallback; then
        fail 'The current session was booted through the generic UEFI fallback path.'
        fail 'Adapter transactions require the canonical source NVRAM entry; reboot normally and let firmware follow BootOrder.'
        return 1
    fi
    have sudo && have pacman || { fail 'sudo and pacman are required'; return 1; }
    pending_exists && { fail 'A bootloader transaction is already pending'; return 1; }
    [[ -z ${BOOT_NEXT:-} ]] || { fail "BootNext is already set to Boot${BOOT_NEXT^^}; refusing to overwrite firmware intent"; return 1; }

    printf '\nSource adapter deep gate (%s):\n' "$(bootloader_display_name "$BOOTLOADER")"
    adapter_source_validate "$BOOTLOADER" || { fail 'The active source adapter failed deep validation; target staging is refused'; return 1; }
    r36_limine_live_target_clean || return 1
    return 0
}

# Admit only rEFInd -> Limine in addition to the already-enabled matrix.
eval "$(declare -f operation_supported | sed '1s/operation_supported/operation_supported_pre_r36/')"
operation_supported() {
    local current=$1 target=$2
    [[ $current == refind && $target == limine ]] && return 0
    operation_supported_pre_r36 "$@"
}

# User-facing plan for the first direct non-GRUB live edge.
eval "$(declare -f show_operation_plan | sed '1s/show_operation_plan/show_operation_plan_pre_r36/')"
show_operation_plan() {
    local current=$1 target=$2
    if [[ $current == refind && $target == limine ]]; then
        printf '\n%s adapter transaction plan:\n' "${SWITCHER_RELEASE:-r36}"
        printf '  SOURCE adapter (rEFInd): validate -> snapshot immutable state -> preserve recovery -> retire only after Limine proof.\n'
        printf '  TARGET adapter (Limine): stage -> deep-validate -> arm -> runtime_validate -> promote -> final_validate.\n'
        printf '  1. Deep-validate the active rEFInd source and snapshot its exact immutable ownership/recovery state.\n'
        printf '  2. Require a clean/unambiguous Limine target namespace; no inactive Limine residue is silently reused.\n'
        printf '  3. Install the CachyOS Limine stack, generate the captured CachyOS theme/policy from the proven runtime cmdline, and stage every installed kernel/initramfs.\n'
        printf '  4. Run limine-install plus its fallback stage, then immediately restore rEFInd first in persistent BootOrder and restore the exact pre-stage shared EFI fallback.\n'
        printf '  5. Deep-validate Limine and re-prove the untouched rEFInd source before arming Limine exactly once with BootNext.\n'
        printf '  6. After Limine reaches userspace, prove BootCurrent/kernel/root/cmdline/ownership through the temporary resume service.\n'
        printf '  7. Only after proof: promote Limine, retire ownership-proven rEFInd state, materialize the Limine fallback only when the shared fallback is transaction-safe, and validate Limine again.\n'
        printf '  If any gate fails, rEFInd remains authoritative and source cleanup is not authorized.\n'
        return 0
    fi
    show_operation_plan_pre_r36 "$@"
}

# Route only the new edge; all existing legacy/hub operations continue through
# their inherited dispatch unchanged.
eval "$(declare -f run_live_operation | sed '1s/run_live_operation/run_live_operation_pre_r36/')"
run_live_operation() {
    local target=$1 current=$BOOTLOADER
    if [[ $current == refind && $target == limine ]]; then
        r26_generic_preflight "$target" || return 1
        offer_operation_backup || return 1
        show_operation_plan "$current" "$target"
        confirm_operation "$current" "$target" || { printf '\nOperation cancelled. No boot state was modified.\n'; return 0; }
        printf '\nExecuting %s adapter transaction...\n' "${SWITCHER_RELEASE:-r36}"
        r26_execute_adapter_switch "$target"
        return $?
    fi
    run_live_operation_pre_r36 "$@"
}
