#!/usr/bin/env bash
# leap16-r71: rEFInd -> GRUB candidate validation must validate the actual
# rEFInd source invariants, not inherit systemd-boot-specific fallback/policy
# assertions from leap16-r38.

leap16_r71_refind_source_fallback_unchanged() {
    local existed expected path current
    if [[ ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == refind:grub ]]; then
        existed=${PENDING_OLD_FALLBACK_EXISTED:-0}
        expected=${PENDING_OLD_FALLBACK_HASH:-}
        path=${PENDING_OLD_FALLBACK_PATH:-${ESP_MOUNT%/}/EFI/BOOT/BOOTX64.EFI}
    else
        existed=${OLD_FALLBACK_EXISTED:-0}
        expected=${OLD_FALLBACK_HASH:-}
        path=${OLD_FALLBACK_PATH:-${ESP_MOUNT%/}/EFI/BOOT/BOOTX64.EFI}
    fi

    case "$existed" in
        1)
            [[ $expected =~ ^[0-9A-Fa-f]{64}$ ]] || { fail 'Recorded rEFInd-source generic fallback hash is invalid'; return 1; }
            current=$(r21_hash_privileged "$path")
            [[ $current == "$expected" ]] || { fail 'Pre-stage generic EFI fallback changed during rEFInd -> GRUB staging'; return 1; }
            ok 'Pre-stage generic EFI fallback remains byte-identical while rEFInd is authoritative'
            ;;
        0)
            if sudo -n test -e "$path" 2>/dev/null || [[ -e $path ]]; then
                fail 'GRUB staging created a generic EFI fallback even though finalized rEFInd had none'
                return 1
            fi
            ok 'Generic EFI fallback remains absent, matching finalized rEFInd source state'
            ;;
        *)
            fail 'Recorded rEFInd-source generic fallback existence state is malformed'
            return 1
            ;;
    esac
}

leap16_r71_refind_loader_policy_unchanged() {
    local value
    # Finalized Leap rEFInd deliberately uses the same openSUSE compatibility
    # policy as finalized Limine because openSUSE has no native LOADER_TYPE for
    # rEFInd.  Do not reuse the systemd-boot-specific r38 assertion here.
    value=$(awk -F= '
        /^[[:space:]]*LOADER_TYPE[[:space:]]*=/ {
            v=$2; sub(/^[[:space:]]+/,"",v); sub(/[[:space:]]+$/,"",v);
            print v; exit
        }
    ' /etc/sysconfig/bootloader 2>/dev/null || true)
    value=${value#\"}; value=${value%\"}
    value=${value#\'}; value=${value%\'}
    [[ $value == grub2-efi ]] \
        && { ok 'LOADER_TYPE remains the finalized rEFInd compatibility value grub2-efi before GRUB runtime proof'; return 0; }
    fail 'Finalized rEFInd compatibility LOADER_TYPE changed before GRUB runtime proof'
    return 1
}

leap16_r71_validate_grub_files_from_refind() {
    local failures=0 ver line shim direct
    printf '\nReconstructed native openSUSE GRUB2 candidate validation from rEFInd:\n'

    shim=$(resolve_efi_path_on_esp_privileged "$R28_GRUB_SHIM_PATH" 2>/dev/null || true)
    direct=$(resolve_efi_path_on_esp_privileged "$R28_GRUB_DIRECT_PATH" 2>/dev/null || true)
    [[ -n $shim ]] && ok "Native shim exists: $shim" || { fail 'Native openSUSE shim is missing'; ((failures++)); }
    [[ -n $direct ]] && ok "Native direct GRUB EFI exists: $direct" || { fail 'Native openSUSE GRUBX64.EFI is missing'; ((failures++)); }
    [[ -f /boot/grub2/grub.cfg ]] && ok '/boot/grub2/grub.cfg exists' || { fail '/boot/grub2/grub.cfg is missing'; ((failures++)); }
    [[ -f /etc/default/grub ]] && ok '/etc/default/grub exists' || { fail '/etc/default/grub is missing'; ((failures++)); }
    leap16_grub_cfg_script_check >/dev/null 2>&1 && ok 'grub2-script-check accepts reconstructed grub.cfg' \
        || { fail 'grub2-script-check rejected reconstructed grub.cfg'; ((failures++)); }

    collect_kernels
    for ver in "${KERNEL_VERSIONS[@]}"; do
        [[ -e /boot/vmlinuz-$ver && -e /boot/initrd-$ver ]] || { fail "Kernel/initrd pair disappeared for $ver"; ((failures++)); continue; }
        line=$(leap16_grub_cfg_grep -F -- "/boot/vmlinuz-$ver" 2>/dev/null | head -n1 || true)
        [[ -n $line ]] && ok "grub.cfg contains kernel $ver" || { fail "grub.cfg has no entry for kernel $ver"; ((failures++)); }
    done
    [[ -n ${ROOT_UUID:-} ]] && leap16_grub_cfg_grep -Fq -- "root=UUID=$ROOT_UUID" >/dev/null 2>&1 \
        && ok 'reconstructed grub.cfg carries the detected root UUID' \
        || { fail 'reconstructed grub.cfg does not carry the detected root UUID'; ((failures++)); }
    validate_cachyos_grub_theme || ((failures++))

    leap16_r71_refind_source_fallback_unchanged || ((failures++))
    leap16_r71_refind_loader_policy_unchanged || ((failures++))
    ((failures == 0))
}

# r64's candidate wrapper is specific to the rEFInd -> GRUB edge, but its
# filesystem sub-validator came from r38 and therefore asserted systemd-boot
# source policy.  Replace only this wrapper; leave r38 itself byte-for-byte
# available to the already hardware-proven systemd-boot -> GRUB path.
if declare -F leap16_r64_validate_grub_candidate >/dev/null 2>&1; then
    eval "$(declare -f leap16_r64_validate_grub_candidate | sed '1s/leap16_r64_validate_grub_candidate/leap16_r64_validate_grub_candidate_pre_leap16_r71/')"
fi
leap16_r64_validate_grub_candidate() {
    local direct target order
    if [[ ${BOOTLOADER:-} != refind && ${PENDING_SOURCE:-}:${PENDING_TARGET:-} != refind:grub ]]; then
        leap16_r64_validate_grub_candidate_pre_leap16_r71 "$@"
        return $?
    fi
    direct=${LEAP16_R64_STAGED_GRUB_DIRECT:-$(leap16_r64_grub_direct_id 2>/dev/null || true)}
    target=${LEAP16_R64_STAGED_GRUB_TARGET:-${PENDING_TARGET_BOOT_ID:-}}
    direct=${direct^^}; target=${target^^}
    [[ $direct =~ ^[0-9A-F]{4}$ && $target =~ ^[0-9A-F]{4}$ ]] || { fail 'GRUB candidate alias identities are incomplete'; return 1; }
    boot_id_exists "$target" && nvram_id_matches_path "$target" "$R28_GRUB_SHIM_PATH" && leap16_nvram_entry_matches_current_esp "$target" \
        || { fail "GRUB shim target Boot$target is not exact"; return 1; }
    boot_id_exists "$direct" && nvram_id_matches_path "$direct" "$R28_GRUB_DIRECT_PATH" && leap16_nvram_entry_matches_current_esp "$direct" \
        || { fail "Direct GRUB target Boot$direct is not exact"; return 1; }
    order=$(leap16_current_boot_order)
    leap16_order_has_id "$order" "$direct" && { fail "Parked direct GRUB Boot$direct entered BootOrder before finalization"; return 1; }
    leap16_r71_validate_grub_files_from_refind || return 1
    ok "Native GRUB2 candidate is exact: shim Boot$target; direct Boot$direct parked outside BootOrder; rEFInd source fallback/policy unchanged"
}
