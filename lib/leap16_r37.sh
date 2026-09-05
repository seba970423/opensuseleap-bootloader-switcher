#!/usr/bin/env bash
# leap16-r37: repair the GRUB2 -> systemd-boot target-runtime source-recovery
# proof and make the r34/r35 firmware baseline visible to the generic Leap
# firmware-order diagnostics/gates.
#
# r36 hardware evidence proved that the root-owned resume service DID execute
# from systemd-boot BootCurrent, and that target kernel/root/cmdline/ownership
# proof passed.  The run then failed because the inherited format-5 source
# recovery verifier finished by calling adapter_source_validate(grub), whose
# active-loader check necessarily rejects a real systemd-boot target session.
# Source recovery must be proved as RECOVERY BYTES/NVRAM while the target is
# running, not by pretending the source is BootCurrent.
#
# r35 also records the complete firmware table as source-firmware-baseline.txt,
# while older generic Leap diagnostics only look for prestage-efibootmgr-v.txt.
# Both files are the same efibootmgr -v evidence shape.  r37 teaches the generic
# resolver to use the r34/r35 baseline for this adapter edge, avoiding false
# "firmware baseline unavailable" reports without changing proven GRUB/Limine.

# Preserve every other direction and all source-active behavior exactly.
eval "$(declare -f verify_pending_source_recovery_unchanged | sed '1s/verify_pending_source_recovery_unchanged/verify_pending_source_recovery_unchanged_pre_leap16_r37/')"

eval "$(declare -f leap16_pending_firmware_baseline_path | sed '1s/leap16_pending_firmware_baseline_path/leap16_pending_firmware_baseline_path_pre_leap16_r37/')"

leap16_r37_verify_grub_recovery_while_systemd_active() {
    local hash baseline

    [[ ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == grub:systemd-boot ]] || {
        fail 'r37 passive source-recovery proof received the wrong transaction direction'
        return 1
    }
    [[ ${BOOTLOADER:-} == systemd-boot && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || {
        fail 'r37 passive GRUB2 recovery proof is restricted to the exact running systemd-boot target session'
        return 1
    }

    # Exact source NVRAM identity and canonical EFI bytes must still exist even
    # though they are intentionally not BootCurrent during target proof.
    nvram_id_matches_path "$PENDING_OLD_BOOT_ID" "$PENDING_OLD_BOOT_EFI_PATH" || {
        fail 'Source GRUB2 NVRAM entry/path changed while systemd-boot target is running'
        return 1
    }
    leap16_nvram_entry_matches_current_esp "$PENDING_OLD_BOOT_ID" || {
        fail 'Source GRUB2 NVRAM entry is no longer bound to the transaction ESP'
        return 1
    }
    hash=$(sudo -n sha256sum -- "$PENDING_SOURCE_EFI_RESOLVED" 2>/dev/null | awk '{print $1}' || true)
    [[ -n $hash && $hash == "$PENDING_SOURCE_EFI_HASH" ]] || {
        fail 'Source GRUB2 EFI executable changed while systemd-boot target is running'
        return 1
    }

    # The source ownership manifest freezes EFI/OPENSUSE, /boot/grub2 and
    # /etc/default/grub byte-for-byte/tree-for-tree.  This is a stronger source
    # recovery assertion than an active-loader identity check can provide here.
    r26_verify_owned_manifest "$PENDING_SOURCE_MANIFEST" || return 1

    if [[ $PENDING_OLD_FALLBACK_EXISTED == 1 ]]; then
        hash=$(sudo -n sha256sum -- "$PENDING_OLD_FALLBACK_PATH" 2>/dev/null | awk '{print $1}' || true)
        [[ -n $PENDING_OLD_FALLBACK_HASH && $hash == "$PENDING_OLD_FALLBACK_HASH" ]] || {
            fail 'Source GRUB2 generic EFI fallback changed before target finalization'
            return 1
        }
    else
        if sudo -n test -e "$PENDING_OLD_FALLBACK_PATH" 2>/dev/null || [[ -e $PENDING_OLD_FALLBACK_PATH ]]; then
            fail 'A generic EFI fallback appeared even though none existed in the source snapshot'
            return 1
        fi
    fi

    # Fresh r34+ candidates also own a complete pre-stage firmware table.  Use
    # it to prove the ENTIRE native openSUSE GRUB alias set (shim + direct GRUB)
    # is unchanged before any promotion/retirement is even considered.
    baseline=$(leap16_r34_baseline_path 2>/dev/null || true)
    if [[ -n $baseline && -s $baseline ]]; then
        leap16_r34_verify_source_grub_ids || return 1
    fi

    ok 'Recorded GRUB2 source recovery NVRAM/files/fallback remain exact while systemd-boot is BootCurrent'
    return 0
}

verify_pending_source_recovery_unchanged() {
    if [[ ${PENDING_FORMAT:-} == "${R26_PENDING_FORMAT:-5}" \
          && ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == grub:systemd-boot ]]; then
        detect_bootloader
        if [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]]; then
            leap16_r37_verify_grub_recovery_while_systemd_active
            return $?
        fi
    fi
    verify_pending_source_recovery_unchanged_pre_leap16_r37 "$@"
}

# The generic Leap firmware-order code predates this adapter edge and looks for
# prestage-efibootmgr-v.txt.  For GRUB2 -> systemd-boot, r34/r35 deliberately
# records the same complete efibootmgr -v evidence as source-firmware-baseline.txt.
# Prefer that exact transaction-owned file when present; otherwise delegate.
leap16_pending_firmware_baseline_path() {
    local baseline
    if [[ ${PENDING_FORMAT:-} == "${R26_PENDING_FORMAT:-5}" \
          && ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == grub:systemd-boot ]]; then
        baseline=$(leap16_r34_baseline_path 2>/dev/null || true)
        if [[ -n $baseline && -r $baseline ]]; then
            printf '%s\n' "$baseline"
            return 0
        fi
    fi
    leap16_pending_firmware_baseline_path_pre_leap16_r37 "$@"
}
