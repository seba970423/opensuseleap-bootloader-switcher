#!/usr/bin/env bash
# leap16-r58: repair the r57 runtime integration break in the identity-based
# EFI/BOOT alias verifier and add a real loaded-overlay smoke contract.
#
# r57's synthetic selftest accidentally mocked a helper that did not exist in
# production (`leap16_r56_validate_current_fallback_alias`).  Hardware therefore
# reached the primary Limine proof successfully and then automatic resume died
# with `command not found` before any fallback transfer or source retirement.
#
# Keep r57's identity model unchanged: Boot#### is an ephemeral firmware handle;
# validate the currently resolved exact EFI/BOOT alias by active state, current
# ESP binding and exact path, with no frozen-ID equality requirement.

leap16_r58_validate_current_fallback_alias() {
    local id=${1^^}
    [[ $id =~ ^[0-9A-F]{4}$ ]] || {
        fail "Current EFI/BOOT fallback identity has invalid Boot#### handle: ${1:-none}"
        return 1
    }

    # A fallback alias is a third identity.  It must never alias either the
    # recorded source or canonical target NVRAM variable even if firmware has
    # reused numeric handles elsewhere.
    if [[ ${PENDING_OLD_BOOT_ID:-} =~ ^[0-9A-Fa-f]{4}$ && $id == ${PENDING_OLD_BOOT_ID^^} ]]; then
        fail "Current EFI/BOOT fallback Boot$id collides with the recorded systemd-boot source identity"
        return 1
    fi
    if [[ ${PENDING_TARGET_BOOT_ID:-} =~ ^[0-9A-Fa-f]{4}$ && $id == ${PENDING_TARGET_BOOT_ID^^} ]]; then
        fail "Current EFI/BOOT fallback Boot$id collides with the canonical Limine target identity"
        return 1
    fi

    boot_id_exists "$id" || {
        fail "Current EFI/BOOT fallback Boot$id no longer exists"
        return 1
    }
    leap16_boot_entry_is_active "$id" || {
        fail "Current EFI/BOOT fallback Boot$id is not active"
        return 1
    }
    leap16_nvram_entry_matches_current_esp "$id" || {
        fail "Current EFI/BOOT fallback Boot$id is not bound to the transaction ESP"
        return 1
    }
    nvram_id_matches_path "$id" "$LEAP16_R21_FALLBACK_EFI_PATH" || {
        fail "Current EFI/BOOT fallback Boot$id changed EFI path"
        return 1
    }
    return 0
}

# Compatibility shim for the mistaken symbol referenced by r57.  Keep the old
# overlay byte-identical; runtime calls are resolved after all overlays load.
leap16_r56_validate_current_fallback_alias() {
    leap16_r58_validate_current_fallback_alias "$@"
}
