#!/usr/bin/env bash
# leap16-r42: privilege-stable retry of systemd-boot -> GRUB2 runtime/finalization.
#
# The r41 hardware retry exposed a misleading fail-closed condition in the generic
# r26 ownership verifier.  verify_pending_candidate_ownership_unchanged() hashed
# the target EFI only with `sudo -n`.  A fresh interactive switcher process can
# therefore report "Target EFI executable changed" solely because no cached sudo
# ticket exists, even when the EFI bytes are unchanged.  The r41 output showed no
# sudo acquisition immediately before that gate.
#
# Keep every proven transaction layer untouched.  For only the r38+ reverse
# systemd-boot -> GRUB2 adapter:
#   * acquire/refresh one sudo session before manual runtime proof/finalization;
#   * hash the target EFI through the established r21 privileged/readable helper;
#   * distinguish unreadable EFI state from a real hash mismatch.
# Root-owned automatic resume remains non-interactive because
# leap16_require_sudo_session() returns immediately for EUID 0.

# Reverse candidate ownership must not interpret a missing `sudo -n` ticket as
# an EFI mutation.  Preserve the exact NVRAM path + recorded hash + full target
# ownership-manifest contract.
eval "$(declare -f verify_pending_candidate_ownership_unchanged | sed '1s/verify_pending_candidate_ownership_unchanged/verify_pending_candidate_ownership_unchanged_pre_leap16_r42/')"
verify_pending_candidate_ownership_unchanged() {
    if ! leap16_r38_pending; then
        verify_pending_candidate_ownership_unchanged_pre_leap16_r42 "$@"
        return $?
    fi

    nvram_id_matches_path "$PENDING_TARGET_BOOT_ID" "$PENDING_TARGET_EFI_PATH" \
        || { fail 'Target NVRAM path changed since candidate creation'; return 1; }

    local hash
    hash=$(r21_hash_privileged "$PENDING_TARGET_EFI_RESOLVED")
    [[ $hash =~ ^[0-9A-Fa-f]{64}$ ]] || {
        fail "Could not read/hash target EFI executable: $PENDING_TARGET_EFI_RESOLVED"
        return 1
    }
    [[ ${hash,,} == ${PENDING_TARGET_EFI_HASH,,} ]] || {
        fail "Target EFI executable genuinely changed since candidate creation (expected ${PENDING_TARGET_EFI_HASH,,}, got ${hash,,})"
        return 1
    }

    r26_verify_owned_manifest "$PENDING_TARGET_MANIFEST" || return 1
    ok "$(bootloader_display_name "$PENDING_TARGET") target adapter ownership still matches the transaction manifest"
}

# Manual reverse runtime proof must establish privilege up front.  Root-owned
# automatic resume is unaffected and never prompts.
eval "$(declare -f leap16_r39_validate_grub_runtime | sed '1s/leap16_r39_validate_grub_runtime/leap16_r39_validate_grub_runtime_pre_leap16_r42/')"
leap16_r39_validate_grub_runtime() {
    if leap16_r38_pending; then
        leap16_require_sudo_session || {
            fail 'A valid sudo session is required for exact GRUB2 runtime proof'
            return 1
        }
    fi
    leap16_r39_validate_grub_runtime_pre_leap16_r42 "$@"
}

# Same rule at the destructive boundary.  This also makes an r40/r41 partial
# finalization retry deterministic instead of relying on an old sudo timestamp.
eval "$(declare -f leap16_r38_finalize | sed '1s/leap16_r38_finalize/leap16_r38_finalize_pre_leap16_r42/')"
leap16_r38_finalize() {
    if leap16_r38_pending; then
        leap16_require_sudo_session || {
            fail 'A valid sudo session is required before GRUB2 finalization'
            return 1
        }
    fi
    leap16_r38_finalize_pre_leap16_r42 "$@"
}
