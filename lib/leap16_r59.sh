#!/usr/bin/env bash
# leap16-r59: restore the finalized Limine menu contract on the
# systemd-boot -> Limine two-proof edge.
#
# r24/r27 already established the user-visible finalized Limine contract:
# canonical Limine + byte-identical EFI/BOOT must leave exactly one visible
# `/EFI fallback` menu item.  r51/r54 accidentally regressed that contract by
# deleting the temporary direct systemd-boot recovery stanza after the second
# proof and treating a menu with no fallback entry as finalized.
#
# r59 changes no firmware proof choreography.  It changes only the deterministic
# final limine.conf rendering and provides a narrow in-place repair for already
# finalized r54-r58 installations that have the proven primary/fallback firmware
# topology but lost the visible menu entry.

LEAP16_R59_FINAL_FALLBACK_TITLE='/EFI fallback'

leap16_r59_append_final_fallback_block() {
    local src=$1 out=$2
    [[ -r $src ]] || return 1
    grep -Fq '/openSUSE systemd-boot recovery' "$src" && return 1
    grep -Fq '/openSUSE GRUB2 recovery' "$src" && return 1
    grep -Fq "$LEAP16_R59_FINAL_FALLBACK_TITLE" "$src" && return 1
    cat -- "$src" >"$out" || return 1
    cat >>"$out" <<'EOF_R59_FALLBACK'

/EFI fallback
### Standard UEFI fallback executable; byte-identical to canonical Limine
comment: Standard UEFI fallback loader (Limine)
protocol: efi
path: boot():/EFI/BOOT/BOOTX64.EFI
EOF_R59_FALLBACK
}

# Preserve the r54 legacy renderer so an already-written r54-r58 retirement
# authorization can be recognized and upgraded deterministically.
eval "$(declare -f leap16_r54_render_final_limine_conf | sed '1s/leap16_r54_render_final_limine_conf/leap16_r54_render_final_limine_conf_pre_leap16_r59/')"

# Final systemd->Limine rendering must CONVERT the temporary direct systemd
# recovery stanza into the same visible EFI fallback block used by the proven
# GRUB->Limine path, not simply delete the recovery stanza.
leap16_r54_render_final_limine_conf() {
    local out=$1 conf="${PENDING_ESP_MOUNT%/}/limine.conf" expected tmp line a b c d found=0
    expected=$(leap16_r51_meta_value transferred_conf_hash)
    [[ $expected =~ ^[0-9A-Fa-f]{64}$ ]] || { fail 'Transferred Limine config identity is unavailable'; return 1; }
    [[ $(r21_hash_privileged "$conf") == "$expected" ]] || { fail 'Transferred limine.conf changed before finalized fallback-menu rendering'; return 1; }
    tmp=$(mktemp) || return 1
    if [[ -r $conf ]]; then cat -- "$conf" >"$tmp"; else sudo -n cat -- "$conf" >"$tmp" 2>/dev/null; fi \
        || { rm -f -- "$tmp"; return 1; }
    : >"$out" || { rm -f -- "$tmp"; return 1; }
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == '/openSUSE systemd-boot recovery' ]]; then
            IFS= read -r a || { rm -f -- "$tmp" "$out"; return 1; }
            IFS= read -r b || { rm -f -- "$tmp" "$out"; return 1; }
            IFS= read -r c || { rm -f -- "$tmp" "$out"; return 1; }
            IFS= read -r d || { rm -f -- "$tmp" "$out"; return 1; }
            [[ $c == 'protocol: efi' && $d == 'path: boot():/EFI/systemd/systemd-bootx64.efi' ]] \
                || { rm -f -- "$tmp" "$out"; fail 'Temporary systemd-boot recovery block changed before finalized fallback-menu conversion'; return 1; }
            {
                printf '/EFI fallback\n'
                printf '### Standard UEFI fallback executable; byte-identical to canonical Limine\n'
                printf 'comment: Standard UEFI fallback loader (Limine)\n'
                printf 'protocol: efi\n'
                printf 'path: boot():/EFI/BOOT/BOOTX64.EFI\n'
            } >>"$out" || { rm -f -- "$tmp" "$out"; return 1; }
            found=$((found + 1))
        else
            printf '%s\n' "$line" >>"$out" || { rm -f -- "$tmp" "$out"; return 1; }
        fi
    done <"$tmp"
    rm -f -- "$tmp"
    [[ $found == 1 ]] || { rm -f -- "$out"; fail "Expected exactly one temporary systemd-boot recovery block before finalized fallback-menu conversion, found $found"; return 1; }
    r24_final_fallback_block_present "$out" || { rm -f -- "$out"; fail 'Rendered final Limine config does not contain the exact EFI fallback menu contract'; return 1; }
}

# During an authorized retirement retry, a final config containing the visible
# fallback is legitimate even while the pending record still exists.  r51's
# pending-only validator otherwise assumes `/EFI fallback` always means the
# *pre-transfer* systemd payload and would reject the correctly finalized menu.
eval "$(declare -f leap16_validate_limine_recovery_contract | sed '1s/leap16_validate_limine_recovery_contract/leap16_validate_limine_recovery_contract_pre_leap16_r59/')"
leap16_validate_limine_recovery_contract() {
    local conf=$1 fallback="${ESP_MOUNT%/}/EFI/BOOT/BOOTX64.EFI" primary="${ESP_MOUNT%/}/EFI/LIMINE/LIMINE_X64.EFI" fh ph
    if leap16_r51_pending && leap16_r54_retirement_authorized && r24_final_fallback_block_present "$conf"; then
        fh=$(r21_hash_privileged "$fallback")
        ph=$(r21_hash_privileged "$primary")
        [[ -n $fh && -n $ph && $fh == "$ph" ]] || return 1
        LEAP16_LIMINE_RECOVERY_DETAIL='Finalized Limine exposes the byte-identical standard EFI fallback after the systemd-boot two-proof transaction'
        return 0
    fi
    leap16_validate_limine_recovery_contract_pre_leap16_r59 "$@"
}

# r54-r58 retirement authorizations may already bind the old deterministic
# final config (temporary recovery stanza removed, no visible fallback).  Do not
# invalidate an already-earned two-proof authorization.  If such an authorized
# transaction is resumed, accept only the exact old hash and deterministically
# upgrade it by appending the exact r27 fallback block.
eval "$(declare -f leap16_r54_finalize_limine_conf_idempotent | sed '1s/leap16_r54_finalize_limine_conf_idempotent/leap16_r54_finalize_limine_conf_idempotent_pre_leap16_r59/')"
leap16_r54_finalize_limine_conf_idempotent() {
    local conf="${PENDING_ESP_MOUNT%/}/limine.conf" transferred auth_final current tmp legacy legacy_hash new_hash stripped
    transferred=$(leap16_r54_auth_value transferred_conf_hash)
    auth_final=$(leap16_r54_auth_value final_conf_hash)
    current=$(r21_hash_privileged "$conf")

    # New r59 authorization/current state: exact final block already present.
    if r24_final_fallback_block_present "$conf"; then
        if [[ $current == "$auth_final" ]]; then
            ok 'Visible EFI fallback menu contract is already finalized in limine.conf' >&2
            printf '%s\n' "$current"
            return 0
        fi
        # Compatibility with an old r54-r58 authorization whose final hash was
        # the same config with the exact fallback block absent.
        stripped=$(mktemp) || return 1
        awk '
            BEGIN{skip=0; seen=0}
            $0=="/EFI fallback" {skip=4; seen++; next}
            skip>0 {skip--; next}
            {print}
            END{if(seen!=1) exit 7}
        ' "$conf" >"$stripped" || { rm -f -- "$stripped"; fail 'Could not verify legacy authorized Limine config beneath the final fallback block'; return 1; }
        legacy_hash=$(sha256sum -- "$stripped" | awk '{print $1}')
        rm -f -- "$stripped"
        [[ $legacy_hash == "$auth_final" ]] || { fail 'Finalized Limine config does not match either the current or legacy retirement authorization'; return 1; }
        ok 'Upgraded legacy r54-r58 retirement authorization to the visible EFI fallback menu contract' >&2
        printf '%s\n' "$current"
        return 0
    fi

    # If current is the transferred pre-retirement config, render r59 final.
    if [[ $current == "$transferred" ]]; then
        tmp=$(mktemp) || return 1
        leap16_r54_render_final_limine_conf "$tmp" || { rm -f -- "$tmp"; return 1; }
        new_hash=$(sha256sum -- "$tmp" | awk '{print $1}')
        if [[ $auth_final != "$new_hash" ]]; then
            # Old authorization: prove its final hash equals the legacy r54
            # deterministic renderer before allowing the r59 upgrade.
            legacy=$(mktemp) || { rm -f -- "$tmp"; return 1; }
            leap16_r54_render_final_limine_conf_pre_leap16_r59 "$legacy" || { rm -f -- "$tmp" "$legacy"; return 1; }
            legacy_hash=$(sha256sum -- "$legacy" | awk '{print $1}')
            rm -f -- "$legacy"
            [[ $legacy_hash == "$auth_final" ]] || { rm -f -- "$tmp"; fail 'Retirement authorization matches neither r59 nor legacy deterministic final Limine config'; return 1; }
        fi
        r21_atomic_replace "$tmp" "$conf" "$new_hash" || { rm -f -- "$tmp"; return 1; }
        rm -f -- "$tmp"
        ok 'Converted temporary systemd-boot recovery menu entry into visible EFI fallback' >&2
        printf '%s\n' "$new_hash"
        return 0
    fi

    # Legacy r54-r58 final config may already be installed while retirement is
    # still pending.  It is safe to upgrade only if its hash is the authorized
    # legacy final hash and it contains no temporary/fallback stanza.
    if [[ $current == "$auth_final" ]] \
        && ! grep -Fq '/EFI fallback' "$conf" \
        && ! grep -Fq '/openSUSE systemd-boot recovery' "$conf" \
        && ! grep -Fq '/openSUSE GRUB2 recovery' "$conf"; then
        tmp=$(mktemp) || return 1
        leap16_r59_append_final_fallback_block "$conf" "$tmp" || { rm -f -- "$tmp"; return 1; }
        new_hash=$(sha256sum -- "$tmp" | awk '{print $1}')
        r21_atomic_replace "$tmp" "$conf" "$new_hash" || { rm -f -- "$tmp"; return 1; }
        rm -f -- "$tmp"
        ok 'Upgraded already-installed legacy r54-r58 final Limine menu to expose EFI fallback' >&2
        printf '%s\n' "$new_hash"
        return 0
    fi

    fail 'limine.conf is neither the authorized transferred state nor an exact current/legacy final configuration'
    return 1
}

# Narrow repair for an already-finalized r54-r58 systemd->Limine installation
# whose firmware fallback is proven but whose visible menu entry was lost by the
# old final renderer.  This mutates ONLY limine.conf.
leap16_r59_repair_finalized_limine_menu() {
    local conf="${ESP_MOUNT%/}/limine.conf" ids primary fallback ph fh before tmp new_hash after
    pending_exists && { fail 'An active transaction exists; use the pending migration manager instead of finalized-menu repair'; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == limine ]] || { fail 'Finalized Limine menu repair requires a currently booted Limine installation'; return 1; }
    leap16_require_sudo_session || return 1
    run_validation preflight || return 1
    ids=$(r24_current_final_ids) || return 1
    primary=${ids%%$'\t'*}; fallback=${ids#*$'\t'}
    ph=$(r21_hash_privileged "${ESP_MOUNT%/}/EFI/LIMINE/LIMINE_X64.EFI")
    fh=$(r21_hash_privileged "${ESP_MOUNT%/}/EFI/BOOT/BOOTX64.EFI")
    [[ -n $ph && $ph == "$fh" ]] || { fail 'EFI/BOOT is not byte-identical to canonical Limine; refusing a presentation-only repair'; return 1; }
    [[ -z $(leap16_r38_current_systemd_ids | awk 'NF') ]] || { fail 'A canonical systemd-boot NVRAM alias still exists; this is not a finalized systemd->Limine state'; return 1; }
    [[ -r $conf ]] || { fail "Limine config is unreadable: $conf"; return 1; }
    grep -Fq '/openSUSE systemd-boot recovery' "$conf" && { fail 'Temporary systemd-boot recovery entry is still present; use the pending transaction flow'; return 1; }
    grep -Fq '/openSUSE GRUB2 recovery' "$conf" && { fail 'Temporary GRUB2 recovery entry is still present; refusing to reinterpret an unfinished transaction'; return 1; }
    if r24_final_fallback_block_present "$conf"; then
        ok "Finalized Limine menu already exposes EFI fallback; firmware paths remain Boot$primary + Boot$fallback"
        return 0
    fi
    grep -Fq '/EFI fallback' "$conf" && { fail 'A non-canonical EFI fallback stanza already exists; refusing to guess'; return 1; }

    printf '\nFinalized Limine menu repair (r59):\n'
    printf '  Firmware primary:  Boot%s -> \\EFI\\LIMINE\\LIMINE_X64.EFI\n' "$primary"
    printf '  Firmware fallback: Boot%s -> \\EFI\\BOOT\\BOOTX64.EFI\n' "$fallback"
    printf '  Both EFI payloads are already byte-identical Limine.\n'
    printf '  NVRAM, EFI payloads, kernel entries and boot order are NOT changed.\n'
    printf '  Only /boot/efi/limine.conf regains one visible "EFI fallback" menu item.\n\n'
    read -r -p 'Type APPLY to repair the menu, or anything else to cancel: ' after
    [[ $after == APPLY ]] || { printf '\nOperation cancelled. Nothing was modified.\n'; return 0; }

    before=$(r21_hash_privileged "$conf")
    tmp=$(mktemp) || return 1
    if [[ -r $conf ]]; then cat -- "$conf" >"$tmp.src"; else sudo -n cat -- "$conf" >"$tmp.src" 2>/dev/null; fi \
        || { rm -f -- "$tmp" "$tmp.src"; return 1; }
    leap16_r59_append_final_fallback_block "$tmp.src" "$tmp" || { rm -f -- "$tmp" "$tmp.src"; return 1; }
    rm -f -- "$tmp.src"
    new_hash=$(sha256sum -- "$tmp" | awk '{print $1}')
    [[ $new_hash != "$before" ]] || { rm -f -- "$tmp"; fail 'Generated finalized Limine menu did not change'; return 1; }
    r21_atomic_replace "$tmp" "$conf" "$new_hash" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
    r24_final_fallback_block_present "$conf" || { fail 'Visible EFI fallback menu entry was written but did not verify'; return 1; }
    [[ $(r21_hash_privileged "${ESP_MOUNT%/}/EFI/LIMINE/LIMINE_X64.EFI") == "$ph" \
       && $(r21_hash_privileged "${ESP_MOUNT%/}/EFI/BOOT/BOOTX64.EFI") == "$fh" ]] \
        || { fail 'EFI payload changed during menu-only repair'; return 1; }
    [[ $(r24_current_final_ids) == "$ids" ]] || { fail 'Firmware primary/fallback topology changed during menu-only repair'; return 1; }
    validate_cachyos_limine_theme || return 1
    leap16_stage_diagnostic r59-finalized-limine-menu-repair >/dev/null 2>&1 || true
    ok 'Restored the visible EFI fallback menu entry without changing firmware or EFI payload ownership'
}

# Use the r59 repair only for the exact legacy finalized no-fallback presentation
# state.  Otherwise preserve the existing current-Limine maintenance behavior.
eval "$(declare -f run_live_operation | sed '1s/run_live_operation/run_live_operation_pre_leap16_r59/')"
run_live_operation() {
    local target=${1:-} conf
    detect_bootloader
    if [[ $BOOTLOADER == limine && $target == limine ]] && ! pending_exists; then
        conf="${ESP_MOUNT%/}/limine.conf"
        if [[ -r $conf ]] \
            && ! grep -Fq '/EFI fallback' "$conf" \
            && ! grep -Fq '/openSUSE systemd-boot recovery' "$conf" \
            && ! grep -Fq '/openSUSE GRUB2 recovery' "$conf"; then
            leap16_r59_repair_finalized_limine_menu
            return $?
        fi
    fi
    run_live_operation_pre_leap16_r59 "$@"
}
