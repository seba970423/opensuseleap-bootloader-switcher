#!/usr/bin/env bash
# r40: enable the direct Limine -> rEFInd live adapter edge.
#
# The underlying source/target contracts are already exercised on real hardware:
# Limine has served as a deeply validated source for restored-rEFInd v4, and
# rEFInd live target staging/runtime proof is proven from GRUB. r40 composes
# those same contracts for a fresh live rEFInd target without weakening the
# source-preservation, fallback, BootNext, ownership, or runtime-proof gates.
#
# Newly enabled live edge:
#   Limine -> rEFInd
#
# This does not open the still-disabled direct systemd-boot non-GRUB edges.

# The format-v5 parser already admits limine:refind through r38 because the
# backup-restore direction uses the same source/target transaction state. No
# pending-state format change is needed here.

# Keep this live preflight narrow and explicit. A fresh rEFInd target must have
# an unambiguous namespace; unlike restore, live staging does not overwrite an
# inactive rEFInd tree whose ownership is unknown.
eval "$(declare -f r26_generic_preflight | sed '1s/r26_generic_preflight/r26_generic_preflight_pre_r40/')"
r26_generic_preflight() {
    local target=$1
    if [[ ${BOOTLOADER:-} != limine || $target != refind ]]; then
        r26_generic_preflight_pre_r40 "$@"
        return $?
    fi

    printf '\n%s adapter preflight:\n' "${SWITCHER_RELEASE:-r40}"
    run_validation preflight || { fail 'Base preflight failed; no boot state was modified'; return 1; }
    is_cachyos || { fail "${SWITCHER_RELEASE:-r40} live adapters are restricted to CachyOS/Arch-like systems"; return 1; }
    if bootcurrent_is_generic_fallback; then
        fail 'The current session was booted through the generic UEFI fallback path.'
        fail 'Adapter transactions require the canonical Limine source NVRAM entry; reboot normally and let firmware follow BootOrder.'
        return 1
    fi
    have sudo && have pacman || { fail 'sudo and pacman are required'; return 1; }
    pending_exists && { fail 'A bootloader transaction is already pending'; return 1; }
    [[ -z ${BOOT_NEXT:-} ]] || { fail "BootNext is already set to Boot${BOOT_NEXT^^}; refusing to overwrite firmware intent"; return 1; }

    printf '\nSource adapter deep gate (Limine):\n'
    adapter_source_validate limine || { fail 'The active Limine source adapter failed deep validation; rEFInd staging is refused'; return 1; }
    r26_target_namespace_clean refind || return 1
    return 0
}

# Open exactly the reverse live edge of r37. Everything else keeps the inherited
# matrix, so systemd-boot <-> rEFInd/Limine live paths remain closed.
eval "$(declare -f operation_supported | sed '1s/operation_supported/operation_supported_pre_r40/')"
operation_supported() {
    local current=$1 target=$2
    [[ $current == limine && $target == refind ]] && return 0
    operation_supported_pre_r40 "$@"
}

# Describe the exact live transaction being executed. The generic r32 rEFInd
# target stage performs post-refind-install ESP identity proof and restores the
# source fallback/BootOrder before candidate ownership is recorded.
eval "$(declare -f show_operation_plan | sed '1s/show_operation_plan/show_operation_plan_pre_r40/')"
show_operation_plan() {
    local current=$1 target=$2
    if [[ $current == limine && $target == refind ]]; then
        printf '\n%s adapter transaction plan:\n' "${SWITCHER_RELEASE:-r40}"
        printf '  SOURCE adapter (Limine): validate -> snapshot exact state/fallback -> preserve recovery -> retire only after rEFInd proof.\n'
        printf '  TARGET adapter (rEFInd): fresh stage -> deep-validate -> arm -> runtime_validate -> promote -> final_validate.\n'
        printf '  1. Deep-validate active Limine and snapshot its exact adapter-owned state plus shared-fallback ownership.\n'
        printf '  2. Require an empty/unambiguous rEFInd target namespace; live staging never reuses unknown inactive rEFInd residue.\n'
        printf '  3. Install rEFInd, re-prove the exact ESP topology after refind-install, apply the CachyOS kernel scan list, and write refind_linux.conf from the proven Limine runtime cmdline.\n'
        printf '  4. Restore Limine first in persistent BootOrder and restore the exact pre-stage Limine/foreign EFI fallback while Limine remains authoritative.\n'
        printf '  5. Deep-validate rEFInd and re-prove untouched Limine before arming rEFInd exactly once with BootNext.\n'
        printf '  6. After rEFInd reaches userspace, require BootCurrent/kernel/root/cmdline/ownership plus fresh PreviousBoot direct-kernel proof.\n'
        printf '  7. Only after proof: promote rEFInd, retire ownership-proven Limine state/fallback, and deep-validate rEFInd again.\n'
        printf '  If any gate fails, Limine remains authoritative and source cleanup is not authorized.\n'
        return 0
    fi
    show_operation_plan_pre_r40 "$@"
}

# Route only Limine -> rEFInd through the already-proven generic adapter engine.
# r26_execute_adapter_switch ultimately uses the r32-hardened live rEFInd target
# stage and the r33 direct-kernel PreviousBoot runtime proof.
eval "$(declare -f run_live_operation | sed '1s/run_live_operation/run_live_operation_pre_r40/')"
run_live_operation() {
    local target=$1 current=$BOOTLOADER
    if [[ $current == limine && $target == refind ]]; then
        r26_generic_preflight "$target" || return 1
        offer_operation_backup || return 1
        show_operation_plan "$current" "$target"
        confirm_operation "$current" "$target" || { printf '\nOperation cancelled. No boot state was modified.\n'; return 0; }
        printf '\nExecuting %s adapter transaction...\n' "${SWITCHER_RELEASE:-r40}"
        r26_execute_adapter_switch "$target"
        return $?
    fi
    run_live_operation_pre_r40 "$@"
}
