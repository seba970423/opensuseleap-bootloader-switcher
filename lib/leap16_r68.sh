#!/usr/bin/env bash
# leap16-r68
# Hardware r67 GRUB2 -> rEFInd reached a real direct-kernel Leap userspace,
# but automatic resume failed before runtime proof because the Leap runtime
# dispatcher still fell through to the original GRUB2 -> Limine-only validator
# ("Current bootloader is rEFInd, not Limine").
#
# r68 adds the missing Leap-native inbound-rEFInd runtime contract, makes source
# recovery passive while rEFInd is BootCurrent, and tightens PreviousBoot proof
# for openSUSE's /boot/vmlinuz symlink path used with follow_symlinks=true.
# No already hardware-proven non-rEFInd edge is changed.

LEAP16_R68_HARDWARE_NOTE='r67 GRUB2 -> rEFInd: DIRECT-BOOT PROVEN TO USERSPACE; automatic resume dispatcher failed before runtime certification/source cleanup'

leap16_r68_refind_target_pending() {
    [[ ${PENDING_FORMAT:-} == "${R26_PENDING_FORMAT:-5}" && ${PENDING_TARGET:-} == refind ]] || return 1
    case ${PENDING_SOURCE:-} in grub|limine|systemd-boot) return 0 ;; *) return 1 ;; esac
}

# rEFInd records the menu loader path in PreviousBoot.  On Leap with
# follow_symlinks=true the menu entry can legitimately be /boot/vmlinuz while
# that symlink resolves to the exact running /boot/vmlinuz-$(uname -r) payload.
# Accept either the exact versioned name or that exact symlink form, but only
# after proving the symlink resolves byte/path-equivalently to the running
# release.  Protected source EFI chainload names remain an unconditional reject.
if declare -F r33_verify_refind_direct_kernel_launch >/dev/null 2>&1; then
    eval "$(declare -f r33_verify_refind_direct_kernel_launch | sed '1s/r33_verify_refind_direct_kernel_launch/r33_verify_refind_direct_kernel_launch_pre_leap16_r68/')"
fi
r33_verify_refind_direct_kernel_launch() {
    if ! is_leap16 || [[ ${PENDING_TARGET:-} != refind ]]; then
        r33_verify_refind_direct_kernel_launch_pre_leap16_r68 "$@"
        return $?
    fi

    local running expected previous lower_previous normalized source_efi_base boot_dir
    local versioned symlink resolved_versioned resolved_symlink
    running=${R33_RUNNING_KERNEL_RELEASE:-$(uname -r)}
    boot_dir=${LEAP16_R68_BOOT_DIR:-/boot}; boot_dir=${boot_dir%/}
    versioned="$boot_dir/vmlinuz-$running"; symlink="$boot_dir/vmlinuz"
    [[ -f $versioned ]] || { fail "rEFInd runtime proof cannot find the running Leap kernel payload $versioned"; return 1; }
    expected="vmlinuz-$running"

    previous=$(r33_refind_previous_boot_text 2>/dev/null || true)
    [[ -n $previous ]] || { fail 'rEFInd runtime proof could not read PreviousBoot from disk-backed vars or EFI NVRAM'; return 1; }
    lower_previous=${previous,,}
    source_efi_base=${PENDING_OLD_BOOT_EFI_PATH##*\\}; source_efi_base=${source_efi_base##*/}
    if [[ -n $source_efi_base && $lower_previous == *"${source_efi_base,,}"* ]]; then
        fail "rEFInd PreviousBoot shows the protected source EFI loader was chainloaded ($source_efi_base); direct-kernel runtime proof is refused"
        return 1
    fi

    if [[ $lower_previous == *"${expected,,}"* ]]; then
        ok "rEFInd PreviousBoot proves direct launch of the running openSUSE Leap kernel ($expected)"
        return 0
    fi

    # Normalize the rEFInd text form (for example: 'Boot \\boot\\vmlinuz from root').
    normalized=${lower_previous//\\//}
    normalized=$(printf '%s' "$normalized" | tr -s '[:space:]' ' ')
    if [[ $normalized =~ ^[[:space:]]*boot[[:space:]]+/boot/vmlinuz[[:space:]]+from[[:space:]]+.+$ \
          || $normalized =~ ^[[:space:]]*boot[[:space:]]+boot/vmlinuz[[:space:]]+from[[:space:]]+.+$ ]]; then
        [[ -L $symlink ]] || { fail "PreviousBoot names /boot/vmlinuz, but $symlink is not a symlink on this Leap runtime"; return 1; }
        resolved_versioned=$(readlink -f -- "$versioned" 2>/dev/null || true)
        resolved_symlink=$(readlink -f -- "$symlink" 2>/dev/null || true)
        [[ -n $resolved_versioned && -n $resolved_symlink && $resolved_symlink == "$resolved_versioned" && -f $resolved_symlink ]] || {
            fail "PreviousBoot names /boot/vmlinuz, but the symlink does not resolve to the exact running kernel $versioned"
            return 1
        }
        ok "rEFInd PreviousBoot proves direct launch through Leap /boot/vmlinuz symlink -> $versioned"
        return 0
    fi

    fail "rEFInd PreviousBoot does not prove the running openSUSE Leap kernel was launched directly (expected $expected or exact /boot/vmlinuz symlink; recorded: $previous)"
    return 1
}


# A few UEFI implementations can synthesize a duplicate Boot#### entry when an
# EFI program is launched.  r64 already tolerates this for an outgoing rEFInd
# source.  Do the symmetric thing for an inbound rEFInd target, but only after
# direct-kernel runtime proof: the recorded target ID must remain present, every
# extra must resolve to the exact canonical same-ESP path, and an extra ID must
# not have existed in the pre-stage firmware baseline.
leap16_r68_normalize_refind_target_aliases_after_proof() {
    leap16_r68_refind_target_pending || { fail 'r68 target-alias normalization received a non-rEFInd-target transaction'; return 1; }
    [[ ${BOOTLOADER:-} == refind && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || {
        fail 'r68 target-alias normalization requires the exact running rEFInd target session'
        return 1
    }

    local target=${PENDING_TARGET_BOOT_ID^^} baseline order id joined found=0
    local -a aliases=() extras=() current=() out=()
    mapfile -t aliases < <(leap16_r48_ids_for_current_esp_path "$LEAP16_R64_REFIND_EFI" | LC_ALL=C sort -u)
    ((${#aliases[@]} > 0)) || { fail 'No canonical same-ESP rEFInd NVRAM alias is visible after runtime proof'; return 1; }
    for id in "${aliases[@]}"; do [[ ${id^^} == "$target" ]] && found=1; done
    ((found)) || { fail "Recorded rEFInd target Boot$target disappeared from the canonical alias set"; return 1; }
    ((${#aliases[@]} == 1)) && { ok "Canonical rEFInd target alias remains unique: Boot$target"; return 0; }

    baseline=$(leap16_r64_baseline_path 2>/dev/null || true)
    [[ -n $baseline && -s $baseline ]] || { fail 'Pre-stage firmware baseline is unavailable; duplicate rEFInd target aliases cannot be ownership-bounded'; return 1; }
    for id in "${aliases[@]}"; do
        id=${id^^}; [[ $id != "$target" ]] || continue
        if grep -Eq "^Boot${id}\*?[[:space:]]" "$baseline"; then
            fail "Duplicate canonical rEFInd alias Boot$id reused a pre-stage firmware ID; refusing to claim or delete it"
            return 1
        fi
        nvram_id_matches_path "$id" "$LEAP16_R64_REFIND_EFI" || { fail "Duplicate rEFInd Boot$id changed canonical path"; return 1; }
        leap16_nvram_entry_matches_current_esp "$id" || { fail "Duplicate rEFInd Boot$id is not bound to the transaction ESP"; return 1; }
        extras+=("$id")
    done

    order=$(leap16_current_boot_order 2>/dev/null || true)
    [[ -n $order ]] || { fail 'BootOrder is unavailable while normalizing duplicate rEFInd target aliases'; return 1; }
    leap16_order_has_id "$order" "$target" || { fail "Recorded rEFInd target Boot$target disappeared from persistent BootOrder"; return 1; }
    IFS=',' read -ra current <<<"$order"
    for id in "${current[@]}"; do
        id=${id^^}; [[ -n $id ]] || continue
        case " ${extras[*]} " in *" $id "*) continue ;; esac
        boot_id_exists "$id" && out+=("$id")
    done
    ((${#out[@]} > 0)) || return 1
    joined=$(IFS=,; printf '%s' "${out[*]}")
    [[ $joined == "$order" ]] || sudo efibootmgr -o "$joined" >/dev/null || return 1
    for id in "${extras[@]}"; do
        leap16_order_has_id "$(leap16_current_boot_order)" "$id" && { fail "Duplicate rEFInd Boot$id remained in BootOrder before deletion"; return 1; }
        sudo efibootmgr -b "$id" -B >/dev/null || { fail "Could not delete bounded duplicate rEFInd target Boot$id"; return 1; }
        boot_id_exists "$id" && { fail "Firmware still exposes duplicate rEFInd target Boot$id after deletion"; return 1; }
        ok "Deleted post-stage duplicate canonical rEFInd target alias Boot$id after removing it from BootOrder"
    done
    mapfile -t aliases < <(leap16_r48_ids_for_current_esp_path "$LEAP16_R64_REFIND_EFI" | LC_ALL=C sort -u)
    ((${#aliases[@]} == 1)) && [[ ${aliases[0]^^} == "$target" ]] || { fail 'Canonical rEFInd target alias set did not normalize back to the recorded target ID'; return 1; }
    ok "Canonical rEFInd target alias set normalized to recorded Boot$target"
}

# Re-run the duplicate-target normalization immediately after final promotion.
# This catches firmware that creates an alias in response to the BootOrder write
# itself, before any source EFI bytes can be retired.
if declare -F leap16_r34_target_first_keep_recovery >/dev/null 2>&1; then
    eval "$(declare -f leap16_r34_target_first_keep_recovery | sed '1s/leap16_r34_target_first_keep_recovery/leap16_r34_target_first_keep_recovery_pre_leap16_r68/')"
fi
leap16_r34_target_first_keep_recovery() {
    leap16_r34_target_first_keep_recovery_pre_leap16_r68 "$@" || return $?
    if leap16_r68_refind_target_pending && [[ ${BOOTLOADER:-} == refind && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} && ${PENDING_PHASE:-} == runtime-validated ]]; then
        leap16_r68_normalize_refind_target_aliases_after_proof || return 1
    fi
}

# While an inbound rEFInd target is running, the source must be proved as
# passive recovery state.  Calling adapter_source_validate() here is invalid:
# that active-source validator naturally rejects a real rEFInd BootCurrent.
# Freeze/verify exact NVRAM path+ESP, EFI hash, ownership manifest, fallback,
# and every baseline source path instead.
leap16_r68_verify_source_recovery_while_refind_active() {
    leap16_r68_refind_target_pending || { fail 'r68 passive source proof received a non-rEFInd-target transaction'; return 1; }
    [[ ${BOOTLOADER:-} == refind && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || {
        fail 'r68 passive source proof is restricted to the exact running rEFInd target session'
        return 1
    }

    local source=${PENDING_SOURCE} source_id=${PENDING_OLD_BOOT_ID^^} hash fallback=${PENDING_OLD_FALLBACK_PATH:-}
    boot_id_exists "$source_id" || { fail "Recorded source Boot$source_id disappeared while rEFInd is running"; return 1; }
    nvram_id_matches_path "$source_id" "$PENDING_OLD_BOOT_EFI_PATH" || { fail "Recorded source Boot$source_id changed EFI path while rEFInd is running"; return 1; }
    leap16_nvram_entry_matches_current_esp "$source_id" || { fail "Recorded source Boot$source_id changed ESP binding while rEFInd is running"; return 1; }
    hash=$(r21_hash_privileged "$PENDING_SOURCE_EFI_RESOLVED" 2>/dev/null || true)
    [[ -n $hash && $hash == "$PENDING_SOURCE_EFI_HASH" ]] || { fail 'Recorded source EFI executable changed while rEFInd is running'; return 1; }
    r26_verify_owned_manifest "$PENDING_SOURCE_MANIFEST" || return 1

    if [[ ${PENDING_OLD_FALLBACK_EXISTED:-0} == 1 ]]; then
        [[ -n $fallback ]] || { fail 'Recorded source fallback path is missing from pending state'; return 1; }
        hash=$(r21_hash_privileged "$fallback" 2>/dev/null || true)
        [[ -n $hash && $hash == "$PENDING_OLD_FALLBACK_HASH" ]] || { fail 'Recorded source generic EFI fallback changed while rEFInd is running'; return 1; }
    elif [[ -n $fallback ]] && (sudo -n test -e "$fallback" 2>/dev/null || [[ -e $fallback ]]); then
        fail 'A generic EFI fallback appeared although none existed in the source snapshot'
        return 1
    fi

    leap16_r64_verify_source_alias_superset "$source" || return 1

    # The adapter source manifest is the authoritative passive recovery proof:
    # it freezes the source-owned EFI/config/payload trees byte-for-byte.  Do
    # not add an active-loader validator here for any source backend; that is
    # exactly the class of mistake that caused the r67 resume failure.
    ok "Recorded $(bootloader_display_name "$source") source recovery remains exact passive state while rEFInd is BootCurrent"
}

if declare -F verify_pending_source_recovery_unchanged >/dev/null 2>&1; then
    eval "$(declare -f verify_pending_source_recovery_unchanged | sed '1s/verify_pending_source_recovery_unchanged/verify_pending_source_recovery_unchanged_pre_leap16_r68/')"
fi
verify_pending_source_recovery_unchanged() {
    if leap16_r68_refind_target_pending && [[ ${BOOTLOADER:-} == refind && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]]; then
        leap16_r68_verify_source_recovery_while_refind_active
        return $?
    fi
    verify_pending_source_recovery_unchanged_pre_leap16_r68 "$@"
}

leap16_r68_validate_refind_target_runtime() {
    validate_pending_compatibility || { fail "Pending rEFInd transaction is incompatible: $PENDING_REASON"; return 1; }
    leap16_r68_refind_target_pending || { fail 'r68 rEFInd runtime validator received the wrong transaction direction'; return 1; }
    [[ $PENDING_PHASE == boot-armed || $PENDING_PHASE == runtime-validated ]] || {
        fail "rEFInd runtime validation requires boot-armed/runtime-validated state (phase is $PENDING_PHASE)"
        return 1
    }

    detect_bootloader
    [[ $BOOTLOADER == refind ]] || { fail "Current bootloader is $(bootloader_display_name "$BOOTLOADER"), not rEFInd"; return 1; }
    [[ ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail "rEFInd runtime proof requires BootCurrent=Boot${PENDING_TARGET_BOOT_ID^^} (found Boot${BOOT_CURRENT:-unknown})"; return 1; }
    nvram_id_matches_path "$PENDING_TARGET_BOOT_ID" "$PENDING_TARGET_EFI_PATH" || { fail 'BootCurrent rEFInd NVRAM entry no longer has the recorded exact EFI path'; return 1; }
    leap16_nvram_entry_matches_current_esp "$PENDING_TARGET_BOOT_ID" || { fail 'BootCurrent rEFInd NVRAM entry is no longer bound to the transaction ESP'; return 1; }
    leap16_require_sudo_session || return 1

    run_validation preflight || return 1
    validate_pending_compatibility || { fail "Pending rEFInd transaction became incompatible during runtime preflight: $PENDING_REASON"; return 1; }

    local next order first diag source_name
    next=$(pending_bootnext_id 2>/dev/null || true)
    if [[ -n $next && ${next^^} != ${PENDING_TARGET_BOOT_ID^^} ]]; then
        fail "BootNext belongs to unrelated Boot${next^^}; refusing to alter it or certify rEFInd runtime"
        return 1
    elif [[ -n $next ]]; then
        warn "Firmware still reports consumed transaction BootNext=Boot${next^^}; clearing it to restore one-shot semantics"
        sudo efibootmgr -N >/dev/null || { fail 'Could not clear consumed rEFInd BootNext'; return 1; }
        [[ -z $(pending_bootnext_id 2>/dev/null || true) ]] || { fail 'BootNext remained set after explicit clear'; return 1; }
        ok 'Consumed rEFInd BootNext is now clear'
    else
        ok 'BootNext was consumed/cleared by firmware after the one-time rEFInd boot'
    fi

    order=$(leap16_current_boot_order 2>/dev/null || true); first=${order%%,*}; first=${first^^}
    [[ -n $order && $first == ${PENDING_OLD_BOOT_ID^^} ]] || {
        fail "Persistent BootOrder changed before rEFInd runtime certification; expected source Boot${PENDING_OLD_BOOT_ID^^} first (found ${order:-unavailable})"
        return 1
    }
    ok "Persistent BootOrder still keeps source $(bootloader_display_name "$PENDING_SOURCE") Boot${PENDING_OLD_BOOT_ID^^} first"

    pending_validate_running_kernel || return 1
    pending_validate_runtime_cmdline_against_source || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    leap16_r68_normalize_refind_target_aliases_after_proof || return 1
    printf '\nDeep rEFInd validation from the actually booted target session:\n'
    validate_pending_target_deep || return 1
    printf '\nRe-validating the untouched source as passive recovery:\n'
    leap16_r68_verify_source_recovery_while_refind_active || return 1

    if [[ $PENDING_PHASE == boot-armed ]]; then
        pending_set_phase runtime-validated || { fail 'rEFInd runtime checks passed but phase could not be persisted; source cleanup remains forbidden'; return 1; }
        PENDING_PHASE=runtime-validated
    fi
    [[ $PENDING_PHASE == runtime-validated ]] || return 1
    diag=$(pending_capture_runtime_diagnostics runtime-pass-refind | tail -n1 || true)
    [[ -n $diag ]] && printf 'Runtime diagnostic snapshot: %s\n' "$diag"
    source_name=$(bootloader_display_name "$PENDING_SOURCE")
    r35_write_local_transaction_result runtime-validated "$source_name -> rEFInd runtime proof passed. BootCurrent is canonical rEFInd, PreviousBoot proves direct Leap kernel launch, and source cleanup has not yet run." || true
    printf '\nRUNTIME-VALIDATED %s -> rEFInd one-time boot succeeded.\n' "$source_name"
    printf 'Canonical rEFInd BootCurrent + direct-kernel PreviousBoot proof are now persisted.\n'
    printf 'Persistent BootOrder is still source-first; source retirement remains a separate ownership-gated finalization.\n'
}

# Fix the exact r67 latent dispatch failure.  r64 handled rEFInd->Limine
# specially but inbound *->rEFInd fell through to Leap's ancient Limine-only
# validator.  Intercept only inbound rEFInd target state and preserve every
# other effective runtime path byte-for-byte through delegation.
if declare -F validate_pending_target_runtime >/dev/null 2>&1; then
    eval "$(declare -f validate_pending_target_runtime | sed '1s/validate_pending_target_runtime/validate_pending_target_runtime_pre_leap16_r68/')"
fi
validate_pending_target_runtime() {
    if leap16_r68_refind_target_pending; then
        leap16_r68_validate_refind_target_runtime
    else
        validate_pending_target_runtime_pre_leap16_r68 "$@"
    fi
}

# Make the matrix/audit output explicitly record what r67 hardware proved.
if declare -F leap16_r64_print_matrix >/dev/null 2>&1; then
    eval "$(declare -f leap16_r64_print_matrix | sed '1s/leap16_r64_print_matrix/leap16_r64_print_matrix_pre_leap16_r68/')"
fi
leap16_r64_print_matrix() {
    leap16_r64_print_matrix_pre_leap16_r68 "$@" | sed '1s/leap16-r67/leap16-r68/'
    cat <<'TXT'

r68 hardware note:
  r67 GRUB2 -> rEFInd reached canonical rEFInd BootCurrent and direct-booted Leap to userspace.
  Automatic resume then SAFE-FAILED before runtime certification/source cleanup because inbound rEFInd incorrectly fell through to the Limine-only Leap runtime validator.
  r68 adds the missing inbound-rEFInd runtime dispatcher/passive-source proof and exact /boot/vmlinuz PreviousBoot symlink proof.
TXT
}
