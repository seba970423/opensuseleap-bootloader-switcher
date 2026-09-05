#!/usr/bin/env bash
# leap16-r43: normalize pre-stage generic-fallback NVRAM aliases during the
# hardware-proven systemd-boot -> GRUB2 retirement path.
#
# r42 correctly retired canonical systemd-boot state, but hardware testing left
# a pre-stage `UEFI OS` Boot#### pointing at \EFI\BOOT\BOOTX64.EFI in the final
# GRUB BootOrder.  The fallback FILE itself was already transferred to, and
# proven byte-identical with, the runtime-proven openSUSE shim.  The surviving
# NVRAM alias is therefore redundant; keeping the file is the recovery policy.
#
# This layer changes only the reverse systemd-boot -> GRUB2 final-order helper.
# A baseline generic-fallback Boot#### may be normalized away only when all of
# these are true:
#   * it existed in the complete pre-stage firmware baseline;
#   * that baseline entry was on the transaction ESP and exactly EFI/BOOT;
#   * if still live, the same Boot#### still resolves to that same ESP/path;
#   * GRUB runtime proof is already persisted and fallback transfer is complete;
#   * EFI/BOOT/BOOTX64.EFI is byte-identical to the proven target shim.
# The NVRAM alias is removed from BootOrder before the variable is deleted.  The
# EFI/BOOT file is never removed by this normalization.

LEAP16_R43_FALLBACK_PATH='\EFI\BOOT\BOOTX64.EFI'

leap16_r43_baseline_fallback_ids() {
    local baseline line id path norm partuuid lower
    baseline=$(leap16_r34_baseline_path 2>/dev/null || true)
    [[ -n $baseline && -s $baseline ]] || return 1
    partuuid=$(lsblk -no PARTUUID -- "$PENDING_ESP_SOURCE" 2>/dev/null | awk 'NF{print tolower($1); exit}')
    [[ -n $partuuid ]] || return 1

    while IFS= read -r line; do
        [[ $line =~ ^Boot([0-9A-Fa-f]{4})\*? ]] || continue
        id=${BASH_REMATCH[1]^^}
        path=$(efi_path_from_efibootmgr_line "$line" 2>/dev/null || true)
        [[ -n $path ]] || continue
        norm=$(normalize_efi_path "$path" | tr '[:upper:]' '[:lower:]')
        [[ $norm == efi/boot/bootx64.efi ]] || continue
        lower=${line,,}
        [[ $lower == *"$partuuid"* ]] || continue
        printf '%s\n' "$id"
    done <"$baseline" | LC_ALL=C sort -u
}

leap16_r43_verify_baseline_fallback_aliases_for_retirement() {
    local target=${PENDING_TARGET_BOOT_ID^^} source=${PENDING_OLD_BOOT_ID^^} direct id path norm hash raw desc
    local -a aliases=()

    direct=$(leap16_r38_direct_id) || return 1
    direct=${direct^^}
    [[ $direct =~ ^[0-9A-F]{4}$ ]] || {
        fail 'Recorded direct-GRUB identity is unavailable before fallback-alias normalization'
        return 1
    }

    [[ ${PENDING_PHASE:-} == runtime-validated ]] || {
        fail 'Generic-fallback NVRAM alias normalization requires runtime-validated GRUB2 state'
        return 1
    }
    r28_transfer_complete || {
        fail 'Generic-fallback NVRAM alias normalization is forbidden before fallback ownership transfer'
        return 1
    }
    hash=$(r21_hash_privileged "$PENDING_ESP_MOUNT/EFI/BOOT/BOOTX64.EFI")
    [[ $hash =~ ^[0-9A-Fa-f]{64}$ && ${hash,,} == ${PENDING_TARGET_EFI_HASH,,} ]] || {
        fail 'EFI/BOOT is not byte-identical to the runtime-proven GRUB shim; fallback alias normalization is forbidden'
        return 1
    }

    raw=$(leap16_r43_baseline_fallback_ids) || {
        fail 'Could not derive baseline generic-fallback aliases from the exact pre-stage firmware table'
        return 1
    }
    if [[ -n $raw ]]; then mapfile -t aliases <<<"$raw"; fi
    for id in "${aliases[@]}"; do
        [[ $id =~ ^[0-9A-F]{4}$ ]] || return 1
        [[ $id != "$target" && $id != "$direct" && $id != "$source" ]] || {
            fail "Refusing to normalize Boot$id because it collides with a canonical transaction identity"
            return 1
        }
        # Missing is acceptable on a retry: this alias is redundant by design
        # and may already have been deleted by an earlier partial finalization.
        boot_id_exists "$id" || continue
        leap16_nvram_entry_matches_current_esp "$id" || {
            fail "Baseline generic-fallback Boot$id changed ESP binding"
            return 1
        }
        path=$(leap16_r39_entry_path_for_id "$id" 2>/dev/null || true)
        norm=$(normalize_efi_path "$path" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        [[ $norm == efi/boot/bootx64.efi ]] || {
            fail "Baseline generic-fallback Boot$id changed EFI path"
            return 1
        }
    done

    if ((${#aliases[@]})); then
        desc=$(printf "Boot%s " "${aliases[@]}")
        ok "Baseline generic-fallback alias set is eligible for NVRAM-only normalization: ${desc% }"
    else
        ok 'No pre-stage generic-fallback NVRAM alias requires normalization'
    fi
}

# Replace r41's final-order helper only for the reverse adapter.  Preserve every
# unrelated current firmware entry, but no longer preserve baseline-owned
# same-ESP EFI/BOOT aliases after that fallback has been transferred to shim.
eval "$(declare -f leap16_r38_final_grub_order_without_systemd | sed '1s/leap16_r38_final_grub_order_without_systemd/leap16_r38_final_grub_order_without_systemd_pre_leap16_r43/')"
leap16_r38_final_grub_order_without_systemd() {
    local target source direct order id joined retired hash path raw
    local -a ids=() out=() churn=() fallback_aliases=()

    if ! leap16_r38_pending; then
        leap16_r38_final_grub_order_without_systemd_pre_leap16_r43 "$@"
        return $?
    fi

    target=${PENDING_TARGET_BOOT_ID^^}
    source=${PENDING_OLD_BOOT_ID^^}
    direct=$(leap16_r38_direct_id) || return 1
    [[ $direct =~ ^[0-9A-Fa-f]{4}$ ]] || {
        fail 'Recorded direct-GRUB firmware identity is unavailable during finalization'
        return 1
    }
    direct=${direct^^}
    out=("$target" "$direct")

    retired=$(leap16_r39_churn_retired_path) || return 1
    mapfile -t churn < <(leap16_r39_recorded_churn_ids)
    [[ -e $retired ]] || leap16_r39_verify_recorded_churn || return 1
    leap16_r43_verify_baseline_fallback_aliases_for_retirement || return 1
    raw=$(leap16_r43_baseline_fallback_ids) || {
        fail 'Could not reload baseline generic-fallback alias set at the final BootOrder boundary'
        return 1
    }
    if [[ -n $raw ]]; then mapfile -t fallback_aliases <<<"$raw"; fi

    order=$(leap16_current_boot_order) || return 1
    IFS=',' read -ra ids <<<"$order"
    for id in "${ids[@]}"; do
        local owned=0 c
        id=${id^^}
        [[ -n $id && $id != "$target" && $id != "$direct" && $id != "$source" ]] || continue
        for c in "${churn[@]}"; do [[ $id == "$c" ]] && { owned=1; break; }; done
        if (( ! owned )); then
            for c in "${fallback_aliases[@]}"; do [[ $id == "$c" ]] && { owned=1; break; }; done
        fi
        ((owned)) && continue
        boot_id_exists "$id" && out+=("$id")
    done

    joined=$(IFS=,; printf '%s' "${out[*]}")
    sudo efibootmgr -o "$joined" >/dev/null || {
        fail 'Could not normalize final GRUB BootOrder'
        return 1
    }
    order=$(leap16_current_boot_order)
    [[ $order == "$target,$direct"* ]] || {
        fail "Final GRUB BootOrder does not begin shim/direct ($order)"
        return 1
    }
    ! leap16_order_has_id "$order" "$source" || {
        fail "Source systemd-boot Boot$source remains in persistent BootOrder"
        return 1
    }
    for id in "${churn[@]}" "${fallback_aliases[@]}"; do
        [[ -n $id ]] || continue
        leap16_order_has_id "$order" "$id" && {
            fail "Owned/redundant firmware alias Boot$id remains in persistent BootOrder"
            return 1
        }
    done
    ok 'Removed source systemd-boot, recorded firmware churn, and redundant baseline EFI-fallback aliases from BootOrder while all referenced EFI files still exist'

    # Normalize baseline generic-fallback NVRAM aliases first.  The actual
    # EFI/BOOT file remains present and byte-identical to shim throughout.
    for id in "${fallback_aliases[@]}"; do
        [[ -n $id ]] || continue
        if boot_id_exists "$id"; then
            leap16_nvram_entry_matches_current_esp "$id" || {
                fail "Refusing to delete baseline fallback Boot$id because its ESP binding changed"
                return 1
            }
            path=$(leap16_r39_entry_path_for_id "$id" 2>/dev/null || true)
            [[ $(normalize_efi_path "$path" 2>/dev/null | tr '[:upper:]' '[:lower:]') == efi/boot/bootx64.efi ]] || {
                fail "Refusing to delete baseline fallback Boot$id because its EFI path changed"
                return 1
            }
            sudo efibootmgr -b "$id" -B >/dev/null || {
                fail "Could not delete redundant baseline generic-fallback Boot$id"
                return 1
            }
            ok "Deleted redundant baseline generic-fallback Boot$id after removing it from BootOrder; EFI/BOOT file was preserved"
        fi
    done

    if [[ ! -e $retired ]]; then
        for id in "${churn[@]}"; do
            [[ -n $id ]] || continue
            if boot_id_exists "$id"; then
                sudo efibootmgr -b "$id" -B >/dev/null || {
                    fail "Could not delete ownership-recorded firmware-churn Boot$id"
                    return 1
                }
                ok "Deleted ownership-recorded post-stage firmware-churn Boot$id after removing it from BootOrder"
            fi
        done
        : >"$retired" || return 1
        chmod 600 -- "$retired" 2>/dev/null || true
    fi

    leap16_r39_verify_recorded_churn || return 1
    [[ -z $(r21_nvram_ids_for_esp_path "$LEAP16_R43_FALLBACK_PATH") ]] || {
        fail 'A same-ESP generic EFI fallback NVRAM alias remains after final GRUB normalization'
        return 1
    }
    hash=$(r21_hash_privileged "$PENDING_ESP_MOUNT/EFI/BOOT/BOOTX64.EFI")
    [[ $hash =~ ^[0-9A-Fa-f]{64}$ && ${hash,,} == ${PENDING_TARGET_EFI_HASH,,} ]] || {
        fail 'Generic fallback file changed while its redundant NVRAM alias was normalized'
        return 1
    }
    ok 'No generic EFI-fallback NVRAM alias remains; EFI/BOOT itself remains byte-identical to the proven GRUB shim'
}
