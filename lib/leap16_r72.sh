#!/usr/bin/env bash
# leap16-r72: exact pre-commit cleanup for rEFInd -> native GRUB staging.
#
# r70 exposed that r26's generic GRUB uncommitted cleanup still described the
# old CachyOS target namespace.  Native Leap GRUB staging creates two NVRAM
# aliases (shim + parked direct GRUB) and owns EFI/OPENSUSE + /boot/grub2 +
# /etc/default/grub.  On a pre-commit failure the generic cleanup could remove
# only the shim alias and /etc/default/grub, leaving a bootable half-GRUB
# fossil behind.  r72 intercepts only source=rEFInd,target=GRUB and restores the
# exact source-first state proved before staging.

leap16_r72_remove_uncommitted_grub_aliases_for_path() {
    local wanted=$1 role=$2 id rc=0
    while IFS= read -r id; do
        id=${id^^}
        [[ $id =~ ^[0-9A-F]{4}$ ]] || continue
        # The rEFInd -> GRUB preflight requires the native GRUB namespace and
        # same-ESP aliases to be absent. Therefore every exact same-ESP alias
        # now visible at these paths is bounded to this uncommitted stage (or
        # firmware churn caused by it) and may be deleted before target bytes.
        sudo efibootmgr -b "$id" -B >/dev/null 2>&1 || { fail "Could not delete uncommitted $role Boot$id"; rc=1; continue; }
        ok "Removed uncommitted $role NVRAM entry Boot$id"
    done < <(leap16_r48_ids_for_current_esp_path "$wanted")
    return "$rc"
}

leap16_r72_bootnext_is_native_grub_alias() {
    local id=${1^^}
    [[ $id =~ ^[0-9A-F]{4}$ ]] || return 1
    leap16_nvram_entry_matches_current_esp "$id" || return 1
    nvram_id_matches_path "$id" "$R28_GRUB_SHIM_PATH" && return 0
    nvram_id_matches_path "$id" "$R28_GRUB_DIRECT_PATH"
}

leap16_r72_cleanup_uncommitted_refind_to_grub() {
    local original_order=$1 source_id=${2^^} rc=0 next order
    warn 'Rolling back the uncommitted native GRUB2 staging attempt from rEFInd with the Leap-owned two-alias cleanup.'

    [[ $source_id =~ ^[0-9A-F]{4}$ && -n $original_order ]] || { fail 'r72 cleanup did not receive a valid recorded source identity/order'; return 1; }
    detect_bootloader
    [[ ${BOOTLOADER:-} == refind && ${BOOT_CURRENT^^} == "$source_id" ]] || {
        fail 'r72 uncommitted cleanup requires the still-running recorded rEFInd source session'
        return 1
    }

    # Refuse to erase unrelated firmware intent. A BootNext created by GRUB
    # staging itself is safe to clear; anything else is a hard stop.
    next=$(pending_bootnext_id 2>/dev/null || true)
    if [[ -n $next ]]; then
        if leap16_r72_bootnext_is_native_grub_alias "$next"; then
            sudo efibootmgr -N >/dev/null 2>&1 || { fail 'Could not clear transaction-owned native-GRUB BootNext'; rc=1; }
        else
            fail "Unrelated BootNext=Boot${next^^} appeared during failed rEFInd -> GRUB staging; refusing destructive cleanup"
            return 1
        fi
    fi

    # Delete firmware aliases while their target EFI files still exist.
    leap16_r72_remove_uncommitted_grub_aliases_for_path "$R28_GRUB_SHIM_PATH" 'GRUB2 shim' || rc=1
    leap16_r72_remove_uncommitted_grub_aliases_for_path "$R28_GRUB_DIRECT_PATH" 'direct GRUB2' || rc=1

    # These exact namespaces were proven absent by leap16_r38_target_namespace_clean
    # before the write boundary, so anything now present is stage-owned.
    sudo rm -rf -- "${ESP_MOUNT%/}/EFI/OPENSUSE" /boot/grub2 || rc=1
    sudo rm -f -- /etc/default/grub || rc=1
    ((rc == 0)) && ok 'Removed uncommitted native openSUSE GRUB filesystem namespaces: EFI/OPENSUSE, /boot/grub2, /etc/default/grub'

    # shim-install may have touched EFI/BOOT auxiliary files and generic
    # fallback bytes. Restore both from the source snapshot before restoring
    # persistent firmware order.
    r28_restore_source_boot_aux || { fail 'Could not restore pre-stage EFI/BOOT fallback.efi/MokManager.efi state'; rc=1; }
    r26_restore_source_fallback_after_target_stage || { fail 'Could not restore pre-stage generic EFI fallback state'; rc=1; }

    sudo efibootmgr -o "$original_order" >/dev/null 2>&1 || { fail 'Could not restore the exact pre-stage BootOrder'; rc=1; }

    # Prove there is no native-GRUB alias residue before calling rollback done.
    [[ -z $(leap16_r48_ids_for_current_esp_path "$R28_GRUB_SHIM_PATH" | awk 'NF') ]] \
        || { fail 'A same-ESP GRUB shim alias remains after uncommitted cleanup'; rc=1; }
    [[ -z $(leap16_r48_ids_for_current_esp_path "$R28_GRUB_DIRECT_PATH" | awk 'NF') ]] \
        || { fail 'A same-ESP direct-GRUB alias remains after uncommitted cleanup'; rc=1; }
    [[ -z $(pending_bootnext_id 2>/dev/null || true) ]] || { fail 'BootNext remains after uncommitted cleanup'; rc=1; }
    order=$(leap16_current_boot_order 2>/dev/null || true)
    [[ $order == "$original_order" ]] || { fail "BootOrder differs after cleanup (expected $original_order, got ${order:-empty})"; rc=1; }

    detect_bootloader
    [[ ${BOOTLOADER:-} == refind && ${BOOT_CURRENT^^} == "$source_id" ]] \
        || { fail 'Recorded rEFInd source identity changed during uncommitted cleanup'; rc=1; }

    if [[ -n ${R26_SOURCE_EFI_HASH:-} && -n ${R26_SOURCE_EFI_RESOLVED:-} ]]; then
        local source_hash
        source_hash=$(r21_hash_privileged "$R26_SOURCE_EFI_RESOLVED" 2>/dev/null || true)
        [[ $source_hash == "$R26_SOURCE_EFI_HASH" ]] || { fail 'rEFInd source EFI bytes changed during failed GRUB staging/cleanup'; rc=1; }
    fi
    if [[ -n ${R26_SOURCE_MANIFEST:-} && -s ${R26_SOURCE_MANIFEST:-/nonexistent} ]]; then
        r26_verify_owned_manifest "$R26_SOURCE_MANIFEST" || rc=1
    fi
    adapter_source_validate refind || rc=1

    if ((rc == 0)); then
        [[ -n ${TRANSACTION_SNAPSHOT_DIR:-} && -d $TRANSACTION_SNAPSHOT_DIR ]] && rm -rf -- "$TRANSACTION_SNAPSHOT_DIR" 2>/dev/null || true
        ok 'Uncommitted rEFInd -> GRUB staging was rolled back exactly; rEFInd remains authoritative and no native-GRUB alias/filesystem residue remains.'
    else
        fail 'r72 could not prove an exact rEFInd -> GRUB pre-commit rollback. Snapshot evidence was preserved; do not reboot until the firmware/filesystem state is inspected.'
    fi
    return "$rc"
}

# r26 owns the generic pre-commit failure path. Intercept only the exact
# rEFInd -> GRUB case; every already-proven direction keeps its historical
# cleanup implementation unchanged.
if declare -F r26_cleanup_uncommitted_target >/dev/null 2>&1; then
    eval "$(declare -f r26_cleanup_uncommitted_target | sed '1s/r26_cleanup_uncommitted_target/r26_cleanup_uncommitted_target_pre_leap16_r72/')"
fi
r26_cleanup_uncommitted_target() {
    local target=$1 original_order=$2 source_id=$3 source=$4
    if [[ $source == refind && $target == grub ]]; then
        leap16_r72_cleanup_uncommitted_refind_to_grub "$original_order" "$source_id"
    else
        r26_cleanup_uncommitted_target_pre_leap16_r72 "$@"
    fi
}
