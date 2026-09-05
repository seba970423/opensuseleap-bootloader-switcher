#!/usr/bin/env bash
# r41: enable the four remaining direct non-GRUB systemd-boot live edges.
#
# Newly enabled live migrations:
#   Limine       -> systemd-boot
#   systemd-boot -> Limine
#   rEFInd       -> systemd-boot
#   systemd-boot -> rEFInd
#
# The transaction choreography remains the inherited format-v5 adapter engine:
# source validation/snapshot, source-first persistent BootOrder, exact fallback
# preservation, one-time BootNext, root-owned userspace resume, runtime proof,
# ownership-gated source retirement, and final target validation.
#
# r41 does not enable the still-separate rEFInd <-> systemd-boot backup-restore
# pair. This revision only opens the four missing *live migration* directions.

r41_systemd_non_grub_live_edge() {
    case "$1:$2" in
        limine:systemd-boot|systemd-boot:limine|refind:systemd-boot|systemd-boot:refind) return 0 ;;
        *) return 1 ;;
    esac
}

# r30 already admitted Limine <-> systemd-boot format-v5 state for restore, and
# r38 admitted Limine <-> rEFInd. Add only the two previously impossible
# rEFInd <-> systemd-boot directions so their live transactions survive reboot.
eval "$(declare -f load_pending_state | sed '1s/load_pending_state/load_pending_state_pre_r41/')"
load_pending_state() {
    if [[ $(r26_state_format) != "$R26_PENDING_FORMAT" ]]; then
        load_pending_state_pre_r41 "$@"
        return $?
    fi

    if load_pending_state_pre_r41 "$@"; then
        return 0
    fi
    [[ ${PENDING_REASON:-} == 'unsupported r26 adapter migration direction' ]] || return 1
    case "${PENDING_SOURCE:-}:${PENDING_TARGET:-}" in
        refind:systemd-boot|systemd-boot:refind) ;;
        *) return 1 ;;
    esac

    # The inherited parser already decoded the complete record and stopped only
    # at its historical direction gate. Re-apply the same integrity tail checks.
    [[ $PENDING_FORMAT == "$R26_PENDING_FORMAT" ]] || { PENDING_REASON='wrong r26 state format'; return 1; }
    [[ $PENDING_ADAPTER_REVISION == "$R26_ADAPTER_REVISION" ]] || { PENDING_REASON='unsupported adapter-state revision'; return 1; }
    [[ -n $PENDING_MACHINE_ID && -n $PENDING_OLD_BOOT_ID && -n $PENDING_TARGET_BOOT_ID ]] || { PENDING_REASON='missing transaction identity'; return 1; }
    [[ -n $PENDING_SOURCE_CMDLINE ]] || { PENDING_REASON='missing source kernel command line'; return 1; }
    [[ -n $PENDING_SOURCE_MANIFEST && -n $PENDING_TARGET_MANIFEST ]] || { PENDING_REASON='missing adapter ownership manifests'; return 1; }
    PENDING_REASON='valid'
    return 0
}

# Keep the new preflight explicit rather than broadening r26's historical gate.
# Limine targets reuse r37's read-only residue inspection; systemd-boot/rEFInd
# targets retain the exact clean-namespace gate already proven from GRUB.
eval "$(declare -f r26_generic_preflight | sed '1s/r26_generic_preflight/r26_generic_preflight_pre_r41/')"
r26_generic_preflight() {
    local target=$1
    local source=${BOOTLOADER:-unknown}

    if ! r41_systemd_non_grub_live_edge "$source" "$target"; then
        r26_generic_preflight_pre_r41 "$@"
        return $?
    fi

    printf '\n%s adapter preflight:\n' "${SWITCHER_RELEASE:-r41}"
    run_validation preflight || { fail 'Base preflight failed; no boot state was modified'; return 1; }
    is_cachyos || { fail "${SWITCHER_RELEASE:-r41} live adapters are restricted to CachyOS/Arch-like systems"; return 1; }
    if bootcurrent_is_generic_fallback; then
        fail 'The current session was booted through the generic UEFI fallback path.'
        fail 'Adapter transactions require the canonical source NVRAM entry; reboot normally and let firmware follow BootOrder.'
        return 1
    fi
    have sudo && have pacman || { fail 'sudo and pacman are required'; return 1; }
    pending_exists && { fail 'A bootloader transaction is already pending'; return 1; }
    [[ -z ${BOOT_NEXT:-} ]] || { fail "BootNext is already set to Boot${BOOT_NEXT^^}; refusing to overwrite firmware intent"; return 1; }

    printf '\nSource adapter deep gate (%s):\n' "$(bootloader_display_name "$source")"
    adapter_source_validate "$source" || { fail 'The active source adapter failed deep validation; target staging is refused'; return 1; }

    case "$target" in
        limine)
            r37_limine_live_target_preflight || return 1
            ;;
        systemd-boot|refind)
            r26_target_namespace_clean "$target" || return 1
            ;;
        *)
            fail "No ${SWITCHER_RELEASE:-r41} target preflight for $(bootloader_display_name "$target")"
            return 1
            ;;
    esac
    return 0
}

# systemd-boot -> Limine needs the same transaction-owned inactive-residue
# quarantine that r37 proved for rEFInd -> Limine. After quarantine, reuse the
# already-proven r36 Limine target stage instead of maintaining a second copy.
eval "$(declare -f adapter_target_stage | sed '1s/adapter_target_stage/adapter_target_stage_pre_r41/')"
adapter_target_stage() {
    local target=$1
    local source_id=$2
    local original_order=$3
    local reference=$4

    if [[ ${BOOTLOADER:-} == systemd-boot && $target == limine ]]; then
        [[ -n ${TRANSACTION_SNAPSHOT_DIR:-} && -d ${TRANSACTION_SNAPSHOT_DIR:-/nonexistent} ]] || {
            fail 'r41 Limine residue quarantine requires the authoritative systemd-boot source transaction snapshot to exist first.'
            return 1
        }
        if ! r30_prepare_limine_target_residue; then
            fail 'Could not snapshot/verify/clear inactive Limine target residue before fresh live staging.'
            return 1
        fi
        r36_stage_limine_target "$source_id" "$original_order" "$reference"
        return $?
    fi

    adapter_target_stage_pre_r41 "$@"
}

# Open exactly the four remaining direct live edges. Historical/proven routes
# remain delegated to their existing implementations.
eval "$(declare -f operation_supported | sed '1s/operation_supported/operation_supported_pre_r41/')"
operation_supported() {
    local current=$1
    local target=$2
    r41_systemd_non_grub_live_edge "$current" "$target" && return 0
    operation_supported_pre_r41 "$@"
}

# Make the write plan explicit about which backend-specific safeguards are in
# play instead of hiding the new directions behind a generic sentence.
eval "$(declare -f show_operation_plan | sed '1s/show_operation_plan/show_operation_plan_pre_r41/')"
show_operation_plan() {
    local current=$1
    local target=$2

    if ! r41_systemd_non_grub_live_edge "$current" "$target"; then
        show_operation_plan_pre_r41 "$@"
        return $?
    fi

    printf '\n%s adapter transaction plan:\n' "${SWITCHER_RELEASE:-r41}"
    printf '  SOURCE adapter (%s): validate -> snapshot exact ownership/recovery -> retire only after target proof.\n' "$(bootloader_display_name "$current")"
    printf '  TARGET adapter (%s): stage -> deep-validate -> arm -> runtime_validate -> promote -> final_validate.\n' "$(bootloader_display_name "$target")"
    printf '  1. Deep-validate the active source and snapshot its exact adapter-owned state plus shared-fallback ownership.\n'

    case "$target" in
        systemd-boot)
            printf '  2. Require the CachyOS /boot ESP topology and an unambiguous systemd-boot target namespace; foreign BLS entries remain unowned and untouched.\n'
            printf '  3. Install systemd-boot-manager, stage bootctl + sdboot-manage state, then restore the source first in persistent BootOrder and restore the exact pre-stage shared EFI fallback.\n'
            ;;
        refind)
            printf '  2. Require an unambiguous rEFInd target namespace; unknown inactive rEFInd state is refused.\n'
            printf '  3. Run refind-install, re-prove the ESP topology, write the proven CachyOS kernel options, then restore the source first in persistent BootOrder and restore the exact pre-stage shared EFI fallback.\n'
            ;;
        limine)
            printf '  2. Refuse a pre-existing canonical Limine NVRAM entry; transactionally quarantine and verify only inactive Limine filesystem residue after the source snapshot exists.\n'
            printf '  3. Stage the CachyOS-themed Limine kernel/initramfs payload, run limine-install + fallback, then restore systemd-boot first in persistent BootOrder and restore the exact pre-stage shared EFI fallback.\n'
            ;;
    esac

    printf '  4. Deep-validate target + untouched source, commit ownership manifests, then arm the target exactly once with BootNext.\n'
    printf '  5. Install the temporary root-owned resume service and prompt before reboot.\n'
    if [[ $target == refind ]]; then
        printf '  6. After rEFInd reaches userspace, prove BootCurrent/kernel/root/cmdline/ownership plus fresh PreviousBoot direct-kernel evidence.\n'
    else
        printf '  6. After %s reaches userspace, prove BootCurrent/kernel/root/cmdline/ownership through the resume service.\n' "$(bootloader_display_name "$target")"
    fi
    if [[ $target == limine ]]; then
        printf '  7. Only after proof: reconcile any exact source-EFI Limine menu stanza, promote Limine, retire ownership-proven systemd-boot state, materialize target fallback only when safe, and validate again.\n'
    else
        printf '  7. Only after proof: promote the target, retire only ownership-proven source state/fallback, then deep-validate the target again.\n'
    fi
    printf '  If target proof fails, no source cleanup is authorized.\n'
}

# Route the four new directions through the shared source-preserving adapter
# engine. Backup prompting remains the same single backend used everywhere else.
eval "$(declare -f run_live_operation | sed '1s/run_live_operation/run_live_operation_pre_r41/')"
run_live_operation() {
    local target=$1
    local current=${BOOTLOADER:-unknown}

    if ! r41_systemd_non_grub_live_edge "$current" "$target"; then
        run_live_operation_pre_r41 "$@"
        return $?
    fi

    r26_generic_preflight "$target" || return 1
    offer_operation_backup || return 1
    show_operation_plan "$current" "$target"
    confirm_operation "$current" "$target" || { printf '\nOperation cancelled. No boot state was modified.\n'; return 0; }
    printf '\nExecuting %s adapter transaction...\n' "${SWITCHER_RELEASE:-r41}"
    r26_execute_adapter_switch "$target"
}
