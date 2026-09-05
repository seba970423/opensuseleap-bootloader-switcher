#!/usr/bin/env bash
# openSUSE Leap 16 r29
#
# Hardware recovery layer for an ASUS-observed NVRAM degradation state:
# canonical EFI/LIMINE bytes remain intact, EFI/BOOT is byte-identical Limine,
# the machine is running from the generic fallback Boot####, native GRUB is
# absent, but the explicit canonical "openSUSE Limine" Boot#### disappeared.
#
# r29 repairs only the missing canonical firmware alias first.  It requires a
# diagnostic snapshot before the first write, preserves the working fallback,
# restores canonical-Limine/fallback persistent ordering, captures a second
# diagnostic snapshot, and requires a normal reboot into the repaired canonical
# alias before r28's reconstructed-GRUB transaction may begin.

R29_PRIMARY_PATH='\EFI\LIMINE\LIMINE_X64.EFI'
R29_FALLBACK_ID=''
R29_REPAIRED_PRIMARY_ID=''

r29_ids_for_path() {
    r28_ids_for_path "$@"
}

r29_native_grub_state_absent() {
    local ids
    ids=$(r28_current_native_grub_ids_csv)
    [[ -z $ids ]] || return 1
    (sudo -n test ! -e "$ESP_MOUNT/EFI/OPENSUSE" 2>/dev/null || [[ ! -e $ESP_MOUNT/EFI/OPENSUSE ]]) || return 1
    [[ ! -e /boot/grub2 && ! -e /etc/default/grub ]]
}

r29_fallback_only_topology_candidate() {
    local fallback
    local -a primary_ids=() fallback_ids=()
    [[ ${BOOTLOADER:-} == limine ]] || return 1
    mapfile -t primary_ids < <(r29_ids_for_path "$R29_PRIMARY_PATH")
    mapfile -t fallback_ids < <(r29_ids_for_path "$LEAP16_R21_FALLBACK_EFI_PATH")
    ((${#primary_ids[@]} == 0 && ${#fallback_ids[@]} == 1)) || return 1
    fallback=${fallback_ids[0]^^}
    [[ ${BOOT_CURRENT^^} == "$fallback" ]] || return 1
    r29_native_grub_state_absent
}

r29_validate_fallback_only_limine_source() {
    local primary_file fallback_file ph fh order fallback
    local -a primary_ids=() fallback_ids=()
    R29_FALLBACK_ID=''

    pending_exists && { fail 'A staged migration is already pending; fallback-only Limine repair will not stack transactions'; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == limine ]] || { fail 'Fallback-only recovery requires Limine to be the running bootloader'; return 1; }
    run_validation preflight || return 1
    [[ -z ${BOOT_NEXT:-} ]] || { fail "BootNext is already set to Boot${BOOT_NEXT^^}"; return 1; }
    leap16_require_sudo_session || return 1

    mapfile -t primary_ids < <(r29_ids_for_path "$R29_PRIMARY_PATH")
    ((${#primary_ids[@]} == 0)) || { fail 'Canonical Limine NVRAM alias already exists; fallback-only repair is not applicable'; return 1; }
    mapfile -t fallback_ids < <(r29_ids_for_path "$LEAP16_R21_FALLBACK_EFI_PATH")
    ((${#fallback_ids[@]} == 1)) || { fail 'Expected exactly one generic Limine fallback alias on the current ESP'; return 1; }
    fallback=${fallback_ids[0]^^}
    leap16_boot_entry_is_active "$fallback" || { fail "Fallback Boot$fallback is not active"; return 1; }
    leap16_nvram_entry_matches_current_esp "$fallback" || { fail "Fallback Boot$fallback is not bound to the detected ESP"; return 1; }
    [[ ${BOOT_CURRENT^^} == "$fallback" ]] || { fail "Recovery must run from the exact fallback Boot$fallback (BootCurrent=${BOOT_CURRENT^^})"; return 1; }
    order=$(leap16_current_boot_order)
    [[ ${order%%,*} == "$fallback" ]] || { fail "Fallback Boot$fallback is not persistent first ($order)"; return 1; }

    primary_file="$ESP_MOUNT/EFI/LIMINE/LIMINE_X64.EFI"
    fallback_file="$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"
    (sudo -n test -f "$primary_file" 2>/dev/null || [[ -f $primary_file ]]) || { fail 'Canonical Limine EFI executable is missing even though only its NVRAM alias should be degraded'; return 1; }
    (sudo -n test -f "$fallback_file" 2>/dev/null || [[ -f $fallback_file ]]) || { fail 'Generic EFI fallback executable is missing'; return 1; }
    ph=$(r21_hash_privileged "$primary_file")
    fh=$(r21_hash_privileged "$fallback_file")
    [[ $ph =~ ^[0-9A-Fa-f]{64}$ && $ph == "$fh" ]] || { fail 'Canonical and fallback Limine EFI payloads are not byte-identical'; return 1; }

    r29_native_grub_state_absent || { fail 'Native openSUSE GRUB2 files or firmware aliases exist; refusing fallback-only Limine repair'; return 1; }
    validate_limine_boot_chain current || return 1
    validate_cachyos_limine_theme || return 1

    R29_FALLBACK_ID=$fallback
    ok "Detected fallback-only Limine recovery state: Boot$fallback -> EFI/BOOT/BOOTX64.EFI is live; canonical EFI/LIMINE bytes are intact but their Boot#### alias is missing"
}

r29_order_primary_fallback_existing() {
    local primary=${1^^} fallback=${2^^} order id joined seen
    local -a current=() out=("$primary" "$fallback")
    order=$(leap16_current_boot_order) || return 1
    IFS=',' read -ra current <<<"$order"
    for id in "${current[@]}"; do
        id=${id^^}
        [[ -n $id && $id != "$primary" && $id != "$fallback" ]] || continue
        boot_id_exists "$id" || continue
        seen=0
        local x
        for x in "${out[@]}"; do [[ $x == "$id" ]] && { seen=1; break; }; done
        ((seen)) || out+=("$id")
    done
    joined=$(IFS=,; printf '%s' "${out[*]}")
    sudo efibootmgr -o "$joined" >/dev/null || return 1
    order=$(leap16_current_boot_order)
    [[ $order == "$primary,$fallback"* ]] || { fail "Repaired persistent BootOrder is not canonical-Limine/fallback first ($order)"; return 1; }
    printf '%s\n' "$order"
}

r29_capture_required_repair_diagnostic() {
    local phase=$1 out
    out=$(leap16_capture_required_diagnostic "$phase" 2>/dev/null || true)
    [[ -n $out && -d $out ]] || { fail "Required $phase diagnostic snapshot could not be created"; return 1; }
    printf '%s\n' "$out"
}

r29_repair_canonical_limine_alias() {
    local topology disk part primary fallback order prediag postdiag ph fh
    local -a ids=() fallback_ids=()

    r29_validate_fallback_only_limine_source || return 1
    prediag=$(r29_capture_required_repair_diagnostic r29-fallback-only-prewrite) || return 1
    printf 'Pre-write diagnostic snapshot: %s\n' "$prediag"

    topology=$(leap16_esp_disk_part) || { fail 'Could not derive ESP disk/partition for canonical Limine alias repair'; return 1; }
    disk=${topology%%$'\t'*}; part=${topology#*$'\t'}
    sudo efibootmgr --create-only --disk "$disk" --part "$part" --label "$LEAP16_LIMINE_NVRAM_LABEL" --loader "$R29_PRIMARY_PATH" >/dev/null || {
        fail 'Could not recreate the canonical openSUSE Limine Boot#### alias'
        r29_capture_required_repair_diagnostic r29-canonical-create-failed >/dev/null 2>&1 || true
        return 1
    }

    mapfile -t ids < <(r29_ids_for_path "$R29_PRIMARY_PATH")
    if ((${#ids[@]} != 1)); then
        fail 'Canonical alias repair did not leave exactly one EFI/LIMINE Boot#### on this ESP'
        r29_capture_required_repair_diagnostic r29-canonical-create-ambiguous >/dev/null 2>&1 || true
        return 1
    fi
    primary=${ids[0]^^}
    leap16_boot_entry_is_active "$primary" || { fail "Repaired canonical Boot$primary is not active"; return 1; }
    leap16_nvram_entry_matches_current_esp "$primary" || { fail "Repaired canonical Boot$primary is not bound to this ESP"; return 1; }

    # ASUS may renumber/synthesize firmware aliases while variables are being
    # created. Re-discover fallback ownership by ESP/path instead of trusting
    # the historical fallback ID observed before the write.
    mapfile -t fallback_ids < <(r29_ids_for_path "$LEAP16_R21_FALLBACK_EFI_PATH")
    if ((${#fallback_ids[@]} != 1)); then
        fail 'The working generic Limine fallback disappeared or became ambiguous during canonical alias repair'
        r29_capture_required_repair_diagnostic r29-fallback-changed-during-repair >/dev/null 2>&1 || true
        return 1
    fi
    fallback=${fallback_ids[0]^^}
    leap16_boot_entry_is_active "$fallback" || { fail "Fallback Boot$fallback is no longer active"; return 1; }
    leap16_nvram_entry_matches_current_esp "$fallback" || { fail "Fallback Boot$fallback no longer belongs to this ESP"; return 1; }

    ph=$(r21_hash_privileged "$ESP_MOUNT/EFI/LIMINE/LIMINE_X64.EFI")
    fh=$(r21_hash_privileged "$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI")
    [[ $ph =~ ^[0-9A-Fa-f]{64}$ && $ph == "$fh" ]] || { fail 'Limine primary/fallback byte identity changed during NVRAM repair'; return 1; }
    r29_native_grub_state_absent || { fail 'Native GRUB state appeared during canonical Limine repair'; return 1; }
    [[ -z $(pending_bootnext_id 2>/dev/null || true) ]] || { fail 'BootNext appeared during canonical Limine repair'; return 1; }

    order=$(r29_order_primary_fallback_existing "$primary" "$fallback") || {
        r29_capture_required_repair_diagnostic r29-order-repair-failed >/dev/null 2>&1 || true
        return 1
    }
    postdiag=$(r29_capture_required_repair_diagnostic r29-fallback-only-repaired) || return 1
    R29_REPAIRED_PRIMARY_ID=$primary
    R29_FALLBACK_ID=$fallback

    printf '\nFALLBACK-ONLY LIMINE TOPOLOGY REPAIRED.\n'
    printf '  Canonical: Boot%s -> EFI/LIMINE/LIMINE_X64.EFI\n' "$primary"
    printf '  Fallback:  Boot%s -> EFI/BOOT/BOOTX64.EFI\n' "$fallback"
    printf '  BootOrder: %s\n' "$order"
    printf '  BootNext:  unset\n'
    printf '  Diagnostics: %s\n' "$postdiag"
    printf '\nNo GRUB files or aliases were created by this repair. Reboot normally once so firmware proves the repaired canonical Limine Boot%s; then select GRUB2 again to enter the r28 reconstructed-GRUB transaction.\n' "$primary"
}

r29_fallback_only_repair_plan() {
    printf '\nASUS fallback-only Limine recovery plan:\n'
    printf '  1. Re-prove that BootCurrent is the exact generic EFI fallback and that EFI/BOOT is byte-identical to canonical EFI/LIMINE.\n'
    printf '  2. Require native GRUB2 NVRAM/files/config to remain absent.\n'
    printf '  3. Capture a required timestamped diagnostic snapshot BEFORE the first firmware write.\n'
    printf '  4. Recreate exactly one openSUSE Limine Boot#### -> EFI/LIMINE/LIMINE_X64.EFI with --create-only.\n'
    printf '  5. Re-discover the generic fallback by ESP/path in case firmware renumbers it, then restore canonical-Limine/fallback persistent order.\n'
    printf '  6. Re-prove byte identity, zero GRUB state and empty BootNext; capture a required post-repair diagnostic snapshot.\n'
    printf '  7. Reboot normally once into repaired canonical Limine before attempting GRUB reconstruction.\n'
}

r29_prompt_reboot_after_repair() {
    local answer
    read -r -p 'Reboot now to prove the repaired canonical Limine entry? [y/N]: ' answer
    case "$answer" in
        y|Y|yes|YES) printf 'Rebooting normally; persistent BootOrder should select repaired canonical Limine first.\n'; sudo systemctl reboot ;;
        *) printf 'Reboot deferred. Do not manually change BootOrder/BootNext; reboot normally before starting Limine -> GRUB2 reconstruction.\n' ;;
    esac
}

# Save r28's dispatcher and intercept only the observed fallback-only Limine
# degradation. Healthy finalized Limine and every other operation remain on the
# previously tested r28/r27 stack.
eval "$(declare -f run_live_operation | sed '1s/run_live_operation/run_live_operation_pre_r29/')"
run_live_operation() {
    local target=${1:-} current answer
    detect_bootloader
    current=$BOOTLOADER
    if [[ $current:$target == limine:grub ]] && r29_fallback_only_topology_candidate; then
        r29_validate_fallback_only_limine_source || return 1
        r29_fallback_only_repair_plan
        printf '\nThis recovery writes only NVRAM ordering/identity; both Limine EFI payloads remain untouched.\n'
        read -r -p 'Type REPAIR to recreate the canonical Limine firmware alias, or anything else to cancel: ' answer
        [[ $answer == REPAIR ]] || { printf '\nOperation cancelled. No boot state was modified.\n'; return 0; }
        printf '\nRe-running fallback-only recovery validation at the write boundary...\n'
        r29_validate_fallback_only_limine_source || { printf '\nWrite-boundary revalidation failed. Nothing was modified.\n'; return 1; }
        r29_repair_canonical_limine_alias || return 1
        r29_prompt_reboot_after_repair
        return 0
    fi
    run_live_operation_pre_r29 "$@"
}
