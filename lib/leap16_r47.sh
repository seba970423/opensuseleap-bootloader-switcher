#!/usr/bin/env bash
# leap16-r47: reconcile the shared machine-id ESP namespace between the
# openSUSE systemd-boot adapter and the already hardware-proven Limine adapter.
#
# systemd-boot owns only:
#   ESP/<machine-id>/opensuse-bootloader-switcher
# Limine owns:
#   ESP/<machine-id>/<kernel-id>/...
#
# Earlier systemd-boot retirement correctly removed its owned child tree but
# could leave the now-empty ESP/<machine-id> parent behind.  The proven
# GRUB2->Limine preflight historically treated existence of that parent as
# proof of an existing Limine tree, producing a false collision.  r47 keeps
# the strict Limine ownership gate but distinguishes an empty shared parent
# from real payload, and opportunistically rmdir(2)s that parent after exact
# systemd-owned cleanup.  rmdir is intentionally used: any foreign/remaining
# child makes cleanup a no-op instead of broadening ownership.

leap16_r47_machine_id_parent() {
    local mid
    mid=$(cat /etc/machine-id 2>/dev/null || true)
    [[ -n $mid && -n ${ESP_MOUNT:-} ]] || return 1
    printf '%s/%s\n' "${ESP_MOUNT%/}" "$mid"
}

leap16_r47_machine_id_parent_is_empty_dir() {
    local parent=$1 child
    (sudo -n test -d "$parent" 2>/dev/null || [[ -d $parent ]]) || return 1
    (sudo -n test ! -L "$parent" 2>/dev/null || [[ ! -L $parent ]]) || return 1
    child=$(sudo -n find "$parent" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)
    [[ -z $child ]]
}

leap16_r47_cleanup_empty_machine_id_parent() {
    local parent
    parent=$(leap16_r47_machine_id_parent 2>/dev/null || true)
    [[ -n $parent ]] || return 0
    if leap16_r47_machine_id_parent_is_empty_dir "$parent"; then
        # Never rm -rf this shared parent.  rmdir succeeds only if it is still
        # empty at the exact write boundary.
        if sudo -n rmdir -- "$parent" 2>/dev/null; then
            ok "Removed empty shared machine-id ESP parent left after systemd-boot retirement: $parent"
        fi
    fi
    return 0
}

leap16_r47_limine_machine_namespace_conflicts() {
    local parent=$1 child
    if ! sudo -n test -e "$parent" 2>/dev/null && [[ ! -e $parent ]]; then
        return 1
    fi
    # A symlink/non-directory is never accepted as harmless residue.
    if sudo -n test -L "$parent" 2>/dev/null || [[ -L $parent ]] || \
       ! (sudo -n test -d "$parent" 2>/dev/null || [[ -d $parent ]]); then
        return 0
    fi
    child=$(sudo -n find "$parent" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)
    [[ -n $child ]]
}

# Preserve the proven GRUB2->Limine function byte-for-byte in its historical
# layer; r47 reproduces the same gate sequence with only the machine-id
# collision predicate narrowed from "parent exists" to "parent has content".
eval "$(declare -f run_switch_preflight | sed '1s/run_switch_preflight/run_switch_preflight_pre_leap16_r47/')"
run_switch_preflight() {
    local target=${1:-} current_order first machine_id
    printf '\nLeap 16 GRUB2 -> Limine write preflight:\n'
    [[ $target == limine ]] || { fail 'this Leap transaction only admits the GRUB2 -> Limine target'; return 1; }
    run_validation preflight || { printf '\nPreflight failed. Nothing was modified.\n'; return 1; }
    is_leap16 || { fail 'This port slice requires openSUSE Leap 16.x'; return 1; }
    [[ $BOOTLOADER == grub ]] || { fail 'this transaction requires the proven native openSUSE GRUB2 source'; return 1; }
    case "$(normalize_efi_path "${BOOT_EFI_PATH:-}" | tr '[:upper:]' '[:lower:]')" in
        efi/opensuse/shim.efi|efi/opensuse/grubx64.efi|efi/opensuse/grub.efi) ;;
        *) fail 'BootCurrent is not the canonical native openSUSE GRUB2/shim NVRAM path'; return 1 ;;
    esac
    pending_exists && { fail 'A staged migration is already pending; the Leap adapter will not stack transactions'; return 1; }
    [[ -z ${BOOT_NEXT:-} ]] || { fail "BootNext is already set to Boot${BOOT_NEXT^^}; the Leap adapter refuses to overwrite unrelated one-time intent"; return 1; }
    current_order=$(leap16_current_boot_order)
    [[ -n $current_order ]] || { fail 'Persistent BootOrder could not be read'; return 1; }
    first=${current_order%%,*}
    [[ ${first^^} == ${BOOT_CURRENT^^} ]] || { fail "Canonical source Boot${BOOT_CURRENT^^} is not first in persistent BootOrder ($current_order)"; return 1; }

    have sudo || { fail 'sudo is required for the candidate stage'; return 1; }
    if sudo -n true 2>/dev/null; then :; elif [[ -t 0 ]]; then sudo -v || return 1; else fail 'sudo credentials are unavailable in this non-interactive session'; return 1; fi
    for _cmd in efibootmgr lsblk findmnt sha256sum b2sum tar od cmp stat df; do have "$_cmd" || { fail "Required command is missing: $_cmd"; return 1; }; done
    (have curl || have wget || [[ -n ${BOOTLOADER_SWITCHER_LIMINE_ARCHIVE:-} ]]) || { fail 'curl or wget is required unless BOOTLOADER_SWITCHER_LIMINE_ARCHIVE points to the pinned archive'; return 1; }
    efibootmgr --help 2>&1 | grep -q -- '--create-only' || { fail 'Installed efibootmgr does not support --create-only'; return 1; }

    validate_grub_boot_chain current || { fail 'Native openSUSE GRUB2 deep validation failed; refusing the write boundary'; return 1; }
    find_nvram_entry_for_target limine && { fail "A Limine Boot#### already exists at the exact target path (Boot$TARGET_NVRAM_ID)"; return 1; }
    [[ $(count_nvram_entries_for_target limine) == 0 ]] || { fail 'Pre-existing Limine NVRAM state is ambiguous'; return 1; }
    path_exists_on_esp_privileged "$(target_expected_efi_path limine)" && { fail 'Target Limine EFI executable already exists'; return 1; }
    sudo -n test -d "$ESP_MOUNT/EFI/LIMINE" 2>/dev/null && { fail 'EFI/LIMINE already exists; the Leap adapter requires a clean target namespace'; return 1; }
    sudo -n test -e "$ESP_MOUNT/limine.conf" 2>/dev/null && { fail 'limine.conf already exists; the Leap adapter requires a clean target namespace'; return 1; }
    sudo -n test -e "$ESP_MOUNT/$R23_LIMINE_SPLASH_NAME" 2>/dev/null && { fail "$R23_LIMINE_SPLASH_NAME already exists; the Leap adapter requires a clean target namespace"; return 1; }
    [[ ! -e /etc/default/limine ]] || { fail '/etc/default/limine already exists; the Leap adapter refuses to overwrite it'; return 1; }
    machine_id=$(cat /etc/machine-id 2>/dev/null || true)
    [[ -n $machine_id ]] || { fail 'Machine ID is unavailable'; return 1; }
    if leap16_r47_limine_machine_namespace_conflicts "$ESP_MOUNT/$machine_id"; then
        fail "r47 managed Limine directory already contains payload: $ESP_MOUNT/$machine_id"
        return 1
    elif sudo -n test -d "$ESP_MOUNT/$machine_id" 2>/dev/null || [[ -d $ESP_MOUNT/$machine_id ]]; then
        ok "Empty shared machine-id ESP parent is harmless and may be reused by Limine: $ESP_MOUNT/$machine_id"
    fi
    sudo -n test -f "$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI" 2>/dev/null || { fail 'Shared EFI/BOOT/BOOTX64.EFI fallback is missing; the Leap adapter requires the existing GRUB2 recovery path'; return 1; }

    collect_kernels
    ((${#KERNEL_VERSIONS[@]} > 0)) || { fail 'No complete Leap kernel/initrd pairs are available for Limine'; return 1; }
    leap16_verify_esp_capacity || return 1
    ok 'GRUB2 -> Limine preflight passed: clean Limine target, exact GRUB2 source, BootNext empty, source first in BootOrder'
}

# Central manifest retirement catches finalized systemd-boot source cleanup and
# backup-restore convergence.  The helper is harmless for all other manifests.
eval "$(declare -f r26_remove_owned_manifest_paths | sed '1s/r26_remove_owned_manifest_paths/r26_remove_owned_manifest_paths_pre_leap16_r47/')"
r26_remove_owned_manifest_paths() {
    local record=$1 rc=0 root
    r26_remove_owned_manifest_paths_pre_leap16_r47 "$@" || rc=$?
    ((rc == 0)) || return "$rc"
    root=$(leap16_r32_sdboot_payload_root 2>/dev/null || true)
    if [[ -n $root ]] && grep -Fq $'tree\t'"$root"$'\t' "$record" 2>/dev/null; then
        leap16_r47_cleanup_empty_machine_id_parent
    fi
    return 0
}

# Candidate rollback and stale-uncommitted cleanup use bespoke removers rather
# than r26_remove_owned_manifest_paths, so hook the same empty-parent cleanup
# there as well.
eval "$(declare -f leap16_r36_remove_target_manifest_paths | sed '1s/leap16_r36_remove_target_manifest_paths/leap16_r36_remove_target_manifest_paths_pre_leap16_r47/')"
leap16_r36_remove_target_manifest_paths() {
    leap16_r36_remove_target_manifest_paths_pre_leap16_r47 "$@" || return $?
    leap16_r47_cleanup_empty_machine_id_parent
}

eval "$(declare -f leap16_r33_remove_recoverable_systemd_residue | sed '1s/leap16_r33_remove_recoverable_systemd_residue/leap16_r33_remove_recoverable_systemd_residue_pre_leap16_r47/')"
leap16_r33_remove_recoverable_systemd_residue() {
    leap16_r33_remove_recoverable_systemd_residue_pre_leap16_r47 "$@" || return $?
    leap16_r47_cleanup_empty_machine_id_parent
}
