#!/usr/bin/env bash
# leap16-r38: open the hardware-next matrix edge, systemd-boot -> native GRUB2.
#
# r37 completed the forward GRUB2 -> systemd-boot hardware proof.  This layer
# deliberately leaves that proven edge and all r31 GRUB2 <-> Limine code alone.
# It adds only the reverse systemd-boot -> GRUB2 transaction, using the same
# source-first -> BootNext -> runtime-proof -> promotion -> retirement model.
#
# Candidate topology:
#   source Boot#### -> \EFI\systemd\systemd-bootx64.efi remains first
#   EFI/BOOT/BOOTX64.EFI remains byte-identical to source systemd-boot
#   parked direct GRUB alias -> \EFI\OPENSUSE\GRUBX64.EFI (outside BootOrder)
#   parked shim target      -> \EFI\OPENSUSE\SHIM.EFI (last in BootOrder)
#
# Final topology after exact shim runtime proof:
#   shim target first, direct GRUB second
#   EFI/BOOT/BOOTX64.EFI byte-identical to proven shim
#   exact source systemd-boot Boot#### + owned BLS/payload/EFI state retired
#   LOADER_TYPE=grub2-efi

LEAP16_R38_META='r38-systemd-to-grub.tsv'
LEAP16_R38_REVERSE_STAGING=0
LEAP16_R38_DIRECT_ID=''
LEAP16_R38_TARGET_ID=''

leap16_r38_pending() {
    [[ ${PENDING_FORMAT:-} == ${R26_PENDING_FORMAT:-5} \
       && ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == systemd-boot:grub ]]
}

leap16_r38_meta_path() {
    local snap=${PENDING_TRANSACTION_SNAPSHOT_DIR:-${TRANSACTION_SNAPSHOT_DIR:-}}
    [[ -n $snap ]] || return 1
    printf '%s/%s\n' "$snap" "$LEAP16_R38_META"
}

leap16_r38_meta_value() {
    local key=$1 p
    p=$(leap16_r38_meta_path) || return 1
    awk -F'\t' -v k="$key" '$1==k{print $2; exit}' "$p" 2>/dev/null
}

leap16_r38_write_meta() {
    local direct=${1^^} target=${2^^} p
    [[ $direct =~ ^[0-9A-F]{4}$ && $target =~ ^[0-9A-F]{4}$ ]] || return 1
    p=$(leap16_r38_meta_path) || return 1
    {
        printf 'direction\tsystemd-boot:grub\n'
        printf 'direct_grub_boot_id\t%s\n' "$direct"
        printf 'target_shim_boot_id\t%s\n' "$target"
        printf 'direct_grub_path\t%s\n' "$R28_GRUB_DIRECT_PATH"
        printf 'target_shim_path\t%s\n' "$R28_GRUB_SHIM_PATH"
    } >"$p" || return 1
    chmod 600 -- "$p" 2>/dev/null || true
}

leap16_r38_validate_meta() {
    local p direct target
    p=$(leap16_r38_meta_path) || { PENDING_REASON='r38 reverse metadata path is unavailable'; return 1; }
    [[ -s $p ]] || { PENDING_REASON='r38 reverse metadata is missing'; return 1; }
    [[ -z ${PENDING_TRANSACTION_SNAPSHOT_DIR:-} ]] || pending_path_under "$p" "$PENDING_TRANSACTION_SNAPSHOT_DIR" \
        || { PENDING_REASON='r38 reverse metadata escaped the transaction snapshot'; return 1; }
    [[ $(leap16_r38_meta_value direction) == systemd-boot:grub ]] || { PENDING_REASON='r38 reverse direction marker is wrong'; return 1; }
    direct=$(leap16_r38_meta_value direct_grub_boot_id); target=$(leap16_r38_meta_value target_shim_boot_id)
    [[ ${direct^^} =~ ^[0-9A-F]{4}$ && ${target^^} =~ ^[0-9A-F]{4}$ ]] || { PENDING_REASON='r38 GRUB firmware IDs are malformed'; return 1; }
    [[ -z ${PENDING_TARGET_BOOT_ID:-} || ${target^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { PENDING_REASON='r38 target shim ID disagrees with pending target'; return 1; }
    [[ $(leap16_r38_meta_value direct_grub_path) == "$R28_GRUB_DIRECT_PATH" ]] || { PENDING_REASON='r38 direct-GRUB path is unexpected'; return 1; }
    [[ $(leap16_r38_meta_value target_shim_path) == "$R28_GRUB_SHIM_PATH" ]] || { PENDING_REASON='r38 shim path is unexpected'; return 1; }
    return 0
}

leap16_r38_current_systemd_ids() {
    r21_nvram_ids_for_esp_path "$LEAP16_R32_SDBOOT_EFI" | awk '/^[0-9A-Fa-f]{4}$/{print toupper($0)}' | LC_ALL=C sort -u
}

leap16_r38_native_grub_ids() {
    r28_current_native_grub_ids_csv
}

leap16_r38_source_fallback_exact() {
    local canonical fallback ch fh
    canonical=$(resolve_efi_path_on_esp_privileged "$LEAP16_R32_SDBOOT_EFI" 2>/dev/null || true)
    fallback="${ESP_MOUNT%/}/EFI/BOOT/BOOTX64.EFI"
    [[ -n $canonical ]] || { fail 'Canonical systemd-boot EFI is unavailable'; return 1; }
    (sudo -n test -f "$fallback" 2>/dev/null || [[ -f $fallback ]]) || { fail 'Finalized systemd-boot source has no generic EFI fallback'; return 1; }
    ch=$(r21_hash_privileged "$canonical")
    fh=$(r21_hash_privileged "$fallback")
    [[ $ch =~ ^[0-9A-Fa-f]{64}$ && $ch == "$fh" ]] || { fail 'Generic EFI fallback is not byte-identical to canonical systemd-boot'; return 1; }
    ok 'Canonical systemd-boot and generic EFI fallback are byte-identical'
}

leap16_r38_target_namespace_clean() {
    local ids
    ids=$(leap16_r38_native_grub_ids)
    [[ -z $ids ]] || { fail "Native GRUB2 NVRAM aliases already exist: Boot${ids//,/ Boot}"; return 1; }
    for p in "${ESP_MOUNT%/}/EFI/OPENSUSE" /boot/grub2 /etc/default/grub; do
        if sudo -n test -e "$p" 2>/dev/null || sudo -n test -L "$p" 2>/dev/null || [[ -e $p || -L $p ]]; then
            fail "Native GRUB2 target namespace already exists: $p"
            return 1
        fi
    done
    return 0
}

leap16_r38_grub_tools_ready() {
    local p
    for p in grub2-mkconfig grub2-script-check grub2-install grub2-probe grub2-mkrelpath shim-install efibootmgr rpm iconv; do
        have "$p" || return 1
    done
    [[ -f $R28_THEME_SOURCE/theme.txt ]] || return 1
    shim-install --help 2>&1 | grep -q -- '--no-nvram' || return 1
    shim-install --help 2>&1 | grep -q -- '--efi-directory' || return 1
    shim-install --help 2>&1 | grep -q -- '--config-file' || return 1
    efibootmgr --help 2>&1 | grep -q -- '--create-only' || return 1
}

leap16_r38_install_grub_packages_if_needed() {
    if rpm -q grub2-common grub2-x86_64-efi shim >/dev/null 2>&1 && leap16_r38_grub_tools_ready; then
        ok 'Native openSUSE GRUB2/shim package/tool set is already installed'
        return 0
    fi
    have zypper || { fail 'zypper is required to install the native openSUSE GRUB2/shim package set'; return 1; }
    printf 'Installing native openSUSE GRUB2/shim packages without weak dependencies...\n'
    sudo zypper --non-interactive --no-recommends install grub2-common grub2-x86_64-efi shim || return 1
    rpm -q grub2-common grub2-x86_64-efi shim >/dev/null 2>&1 || { fail 'Native GRUB2/shim RPM set is incomplete after installation'; return 1; }
    leap16_r38_grub_tools_ready || { fail 'Native GRUB2 reconstruction tools are incomplete after package installation'; return 1; }
    ok 'Native openSUSE GRUB2/shim package/tool set is ready'
}

leap16_r38_preflight() {
    local target=$1 ids order
    [[ ${BOOTLOADER:-} == systemd-boot && $target == grub ]] || return 1
    printf '\n%s systemd-boot -> GRUB2 switch preflight:\n' "${SWITCHER_RELEASE:-leap16-r38}"
    run_validation preflight || { fail 'Base preflight failed; no boot state was modified'; return 1; }
    is_leap16 || { fail 'This backend is restricted to openSUSE Leap 16'; return 1; }
    leap16_require_sudo_session || return 1
    bootcurrent_is_generic_fallback && { fail 'Canonical systemd-boot BootCurrent is required; current session came through generic fallback'; return 1; }
    pending_exists && { fail 'A bootloader transaction is already pending'; return 1; }
    [[ -z ${BOOT_NEXT:-} ]] || { fail "BootNext is already set to Boot${BOOT_NEXT^^}"; return 1; }
    leap16_r34_validate_systemd_boot_chain source || { fail 'Current systemd-boot source failed deep validation'; return 1; }
    grep -Eq '^[[:space:]]*LOADER_TYPE=.*systemd-boot' /etc/sysconfig/bootloader 2>/dev/null \
        || { fail 'openSUSE LOADER_TYPE is not systemd-boot'; return 1; }
    ids=$(leap16_r38_current_systemd_ids | paste -sd, -)
    [[ -n $ids && $ids != *,* && ${ids^^} == ${BOOT_CURRENT^^} ]] || { fail "Expected exactly one canonical systemd-boot NVRAM alias matching BootCurrent; found ${ids:-none}"; return 1; }
    order=$(leap16_current_boot_order)
    [[ ${order%%,*} == ${BOOT_CURRENT^^} ]] || { fail "Persistent BootOrder is not source systemd-boot Boot${BOOT_CURRENT^^} first ($order)"; return 1; }
    leap16_r38_source_fallback_exact || return 1
    leap16_r38_target_namespace_clean || return 1
    if ! rpm -q grub2-common grub2-x86_64-efi shim >/dev/null 2>&1 || ! leap16_r38_grub_tools_ready; then
        have zypper || { fail 'GRUB2 packages/tools are incomplete and zypper is unavailable'; return 1; }
        warn 'Native GRUB2/shim packages or tools are incomplete; the write stage will install the native RPM set with --no-recommends.'
    else
        ok 'Native openSUSE GRUB2/shim reconstruction prerequisites are already installed'
    fi
    ok 'systemd-boot -> GRUB2 preflight passed; systemd-boot remains authoritative until exact GRUB runtime proof'
}

leap16_r38_plan() {
    printf '\nExact openSUSE systemd-boot -> GRUB2 candidate plan:\n'
    printf '  1. Re-prove finalized canonical systemd-boot, its byte-identical EFI fallback, empty BootNext and source-first persistent BootOrder.\n'
    printf '  2. Require a completely absent native GRUB2 namespace/NVRAM set before staging.\n'
    printf '  3. Snapshot exact systemd-boot source ownership, generic fallback and complete firmware table.\n'
    printf '  4. Reconstruct native /boot/grub2 + EFI/OPENSUSE with grub2-mkconfig + shim-install --no-nvram; restore systemd-boot EFI/BOOT immediately if shim-install touches it.\n'
    printf '  5. Create one parked direct-GRUB alias and one parked shim target with efibootmgr --create-only; direct GRUB stays outside BootOrder.\n'
    printf '  6. Keep systemd-boot first, append only shim last, deep-validate both sides, then arm shim once with BootNext.\n'
    printf '  7. After real GRUB userspace arrival, prove BootCurrent/kernel/root/cmdline/GRUB ownership while systemd-boot recovery remains exact.\n'
    printf '  8. Only after proof: promote shim, transfer EFI/BOOT to byte-identical shim, put direct GRUB second, remove source systemd-boot from BootOrder/NVRAM while its EFI still exists, then retire only ownership-proven systemd-boot files.\n'
    printf '  9. Set LOADER_TYPE=grub2-efi and require final deep GRUB validation.\n'
    printf '  If GRUB proof fails, systemd-boot is not retired.\n'
}

leap16_r38_validate_grub_files_candidate() {
    local failures=0 ver line shim direct fallback_hash expected_fallback
    printf '\nReconstructed native openSUSE GRUB2 candidate validation:\n'
    shim=$(resolve_efi_path_on_esp_privileged "$R28_GRUB_SHIM_PATH" 2>/dev/null || true)
    direct=$(resolve_efi_path_on_esp_privileged "$R28_GRUB_DIRECT_PATH" 2>/dev/null || true)
    [[ -n $shim ]] && ok "Native shim exists: $shim" || { fail 'Native openSUSE shim is missing'; ((failures++)); }
    [[ -n $direct ]] && ok "Native direct GRUB EFI exists: $direct" || { fail 'Native openSUSE GRUBX64.EFI is missing'; ((failures++)); }
    [[ -f /boot/grub2/grub.cfg ]] && ok '/boot/grub2/grub.cfg exists' || { fail '/boot/grub2/grub.cfg is missing'; ((failures++)); }
    [[ -f /etc/default/grub ]] && ok '/etc/default/grub exists' || { fail '/etc/default/grub is missing'; ((failures++)); }
    leap16_grub_cfg_script_check >/dev/null 2>&1 && ok 'grub2-script-check accepts reconstructed grub.cfg' || { fail 'grub2-script-check rejected reconstructed grub.cfg'; ((failures++)); }
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
    expected_fallback=${PENDING_OLD_FALLBACK_HASH:-${OLD_FALLBACK_HASH:-}}
    fallback_hash=$(r21_hash_privileged "${ESP_MOUNT%/}/EFI/BOOT/BOOTX64.EFI")
    [[ -n $expected_fallback && $fallback_hash == "$expected_fallback" ]] \
        && ok 'systemd-boot-owned generic EFI fallback remains byte-identical to the pre-stage source' \
        || { fail 'systemd-boot-owned generic EFI fallback changed during GRUB staging'; ((failures++)); }
    grep -Eq '^[[:space:]]*LOADER_TYPE=.*systemd-boot' /etc/sysconfig/bootloader 2>/dev/null \
        && ok 'LOADER_TYPE remains systemd-boot while the source is authoritative' \
        || { fail 'LOADER_TYPE changed before GRUB runtime proof'; ((failures++)); }
    ((failures == 0))
}

leap16_r38_direct_id() {
    if leap16_r38_pending; then
        leap16_r38_meta_value direct_grub_boot_id | tr '[:lower:]' '[:upper:]'
    else
        printf '%s\n' "${LEAP16_R38_DIRECT_ID^^}"
    fi
}

leap16_r38_target_id() {
    if leap16_r38_pending; then
        printf '%s\n' "${PENDING_TARGET_BOOT_ID^^}"
    else
        printf '%s\n' "${LEAP16_R38_TARGET_ID^^}"
    fi
}

leap16_r38_validate_grub_candidate() {
    local target direct order
    target=$(leap16_r38_target_id); direct=$(leap16_r38_direct_id)
    [[ $target =~ ^[0-9A-F]{4}$ && $direct =~ ^[0-9A-F]{4}$ ]] || { fail 'GRUB candidate firmware IDs are unavailable'; return 1; }
    leap16_boot_entry_is_active "$target" || { fail "Shim target Boot$target is not active"; return 1; }
    nvram_id_matches_path "$target" "$R28_GRUB_SHIM_PATH" || { fail "Boot$target does not point to $R28_GRUB_SHIM_PATH"; return 1; }
    leap16_nvram_entry_matches_current_esp "$target" || { fail "Boot$target is not bound to the transaction ESP"; return 1; }
    leap16_boot_entry_is_active "$direct" || { fail "Direct GRUB Boot$direct is not active"; return 1; }
    nvram_id_matches_path "$direct" "$R28_GRUB_DIRECT_PATH" || { fail "Boot$direct does not point to $R28_GRUB_DIRECT_PATH"; return 1; }
    leap16_nvram_entry_matches_current_esp "$direct" || { fail "Direct GRUB Boot$direct is not bound to the transaction ESP"; return 1; }
    order=$(leap16_current_boot_order)
    leap16_order_has_id "$order" "$direct" && { fail "Parked direct GRUB Boot$direct entered BootOrder before finalization"; return 1; }
    leap16_r38_validate_grub_files_candidate || return 1
    ok "Native GRUB2 candidate is exact: shim Boot$target; direct Boot$direct parked outside BootOrder; systemd-boot fallback unchanged"
}

leap16_r38_install_native_grub_files() {
    local tmp default_hash
    tmp=$(mktemp) || return 1
    r28_render_grub_default "$tmp" || { rm -f -- "$tmp"; return 1; }
    default_hash=$(sha256sum -- "$tmp" | awk '{print $1}')
    [[ $default_hash =~ ^[0-9A-Fa-f]{64}$ ]] || { rm -f -- "$tmp"; return 1; }
    sudo install -m 0644 -- "$tmp" /etc/default/grub || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
    [[ $(r21_hash_privileged /etc/default/grub) == "$default_hash" ]] || { fail 'Installed /etc/default/grub does not match generated transaction bytes'; return 1; }

    sudo mkdir -p -- /boot/grub2/themes || return 1
    sudo cp -a -- "$R28_THEME_SOURCE" /boot/grub2/themes/ || return 1
    sudo grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null || { fail 'grub2-mkconfig failed while reconstructing native openSUSE GRUB2'; return 1; }
    leap16_grub_cfg_script_check >/dev/null 2>&1 || { fail 'Generated grub.cfg failed grub2-script-check before EFI installation'; return 1; }

    sudo shim-install --no-nvram --efi-directory="$ESP_MOUNT" --config-file=/boot/grub2/grub.cfg >/dev/null || {
        fail 'shim-install --no-nvram failed while reconstructing native openSUSE EFI state'
        return 1
    }
    r28_capture_generated_boot_aux || return 1
    r26_restore_source_fallback_after_target_stage || return 1
    r28_restore_source_boot_aux || { fail 'Could not restore source EFI/BOOT auxiliary files after shim-install'; return 1; }
    sudo grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null || return 1
    r26_restore_source_fallback_after_target_stage || return 1
    r28_restore_source_boot_aux || return 1

    [[ -z $(r28_ids_for_path "$R28_GRUB_SHIM_PATH") ]] || { fail 'shim-install --no-nvram unexpectedly created a shim NVRAM alias'; return 1; }
    [[ -z $(r28_ids_for_path "$R28_GRUB_DIRECT_PATH") ]] || { fail 'shim-install --no-nvram unexpectedly created a direct-GRUB NVRAM alias'; return 1; }
    return 0
}

# Add a complete source firmware baseline for the new reverse edge too.
eval "$(declare -f adapter_source_snapshot | sed '1s/adapter_source_snapshot/adapter_source_snapshot_pre_leap16_r38/')"
adapter_source_snapshot() {
    local source=$1 baseline
    adapter_source_snapshot_pre_leap16_r38 "$@" || return $?
    [[ $source == systemd-boot ]] || return 0
    baseline="$TRANSACTION_SNAPSHOT_DIR/$LEAP16_R34_FIRMWARE_BASELINE"
    sudo -n efibootmgr -v >"$baseline" || { fail 'Could not record the privileged pre-stage firmware baseline for systemd-boot retirement ownership'; return 1; }
    chmod 600 -- "$baseline" 2>/dev/null || true
    grep -Eq '^BootCurrent:[[:space:]]+' "$baseline" || { fail 'Pre-stage firmware baseline is incomplete'; return 1; }
    grep -Eq '^BootOrder:[[:space:]]+' "$baseline" || { fail 'Pre-stage firmware baseline has no BootOrder'; return 1; }
    ok 'Recorded complete pre-stage firmware table for ownership-gated systemd-boot retirement'
}

# Stage native Leap GRUB instead of the inherited CachyOS /boot/grub + EFI/CACHYOS layout.
eval "$(declare -f r26_stage_grub_target | sed '1s/r26_stage_grub_target/r26_stage_grub_target_pre_leap16_r38/')"
r26_stage_grub_target() {
    local source_id=$1 original_order=$2 reference=$3 direct target
    if [[ ${BOOTLOADER:-} != systemd-boot ]]; then
        r26_stage_grub_target_pre_leap16_r38 "$@"
        return $?
    fi
    leap16_r38_install_grub_packages_if_needed || return 1
    r28_snapshot_source_boot_aux || return 1
    leap16_r38_install_native_grub_files || return 1

    r28_create_alias_create_only "$R28_GRUB_DIRECT_LABEL" "$R28_GRUB_DIRECT_PATH" || return 1
    direct=$R28_CREATED_ALIAS_ID
    r28_create_alias_create_only "$R28_GRUB_SHIM_LABEL" "$R28_GRUB_SHIM_PATH" || return 1
    target=$R28_CREATED_ALIAS_ID
    LEAP16_R38_DIRECT_ID=${direct^^}; LEAP16_R38_TARGET_ID=${target^^}

    set_source_first_boot_order "$source_id" "$target" "$original_order" || return 1
    ! leap16_order_has_id "$(leap16_current_boot_order)" "$direct" || { fail 'Direct GRUB alias entered BootOrder during candidate staging'; return 1; }
    r26_restore_source_fallback_after_target_stage || return 1
    r28_restore_source_boot_aux || return 1

    LEAP16_R38_REVERSE_STAGING=1
    leap16_r38_validate_grub_candidate || { LEAP16_R38_REVERSE_STAGING=0; return 1; }
    r26_record_target_adapter grub || { LEAP16_R38_REVERSE_STAGING=0; return 1; }
    leap16_r38_write_meta "$direct" "$target" || { LEAP16_R38_REVERSE_STAGING=0; return 1; }
    LEAP16_R38_REVERSE_STAGING=0
    R26_STAGED_TARGET_ID=${target^^}
    ok "Staged native openSUSE shim target as Boot${target^^}; direct GRUB Boot${direct^^} is parked outside BootOrder"
}

# Candidate GRUB validation must not insist GRUB is BootCurrent before the one-shot.
eval "$(declare -f r26_adapter_validate | sed '1s/r26_adapter_validate/r26_adapter_validate_pre_leap16_r38/')"
r26_adapter_validate() {
    local bl=$1 mode=${2:-migration}
    if [[ $bl == grub && ( ${LEAP16_R38_REVERSE_STAGING:-0} == 1 || ( ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == systemd-boot:grub && ${BOOTLOADER:-} != grub ) ) ]]; then
        leap16_r38_validate_grub_candidate
        return $?
    fi
    r26_adapter_validate_pre_leap16_r38 "$@"
}

# Require sidecar firmware ownership for every persisted reverse transaction.
eval "$(declare -f validate_pending_compatibility | sed '1s/validate_pending_compatibility/validate_pending_compatibility_pre_leap16_r38/')"
validate_pending_compatibility() {
    validate_pending_compatibility_pre_leap16_r38 "$@" || return $?
    if leap16_r38_pending; then
        leap16_r38_validate_meta || return 1
        [[ -s "$PENDING_TRANSACTION_SNAPSHOT_DIR/r28-efi-boot-aux-before.tsv" ]] || { PENDING_REASON='r38 pre-stage EFI/BOOT auxiliary record is missing'; return 1; }
        [[ -s "$PENDING_TRANSACTION_SNAPSHOT_DIR/r28-efi-boot-aux-generated.tsv" ]] || { PENDING_REASON='r38 generated GRUB EFI/BOOT auxiliary record is missing'; return 1; }
        [[ -s "$PENDING_TRANSACTION_SNAPSHOT_DIR/$LEAP16_R34_FIRMWARE_BASELINE" ]] || { PENDING_REASON='r38 pre-stage firmware baseline is missing'; return 1; }
    fi
    return 0
}

leap16_r38_verify_direct_alias() {
    local direct
    direct=$(leap16_r38_direct_id)
    [[ $direct =~ ^[0-9A-F]{4}$ ]] || { fail 'Recorded direct GRUB alias is unavailable'; return 1; }
    boot_id_exists "$direct" || { fail "Recorded direct GRUB Boot$direct disappeared"; return 1; }
    nvram_id_matches_path "$direct" "$R28_GRUB_DIRECT_PATH" || { fail "Recorded direct GRUB Boot$direct changed path"; return 1; }
    leap16_nvram_entry_matches_current_esp "$direct" || { fail "Recorded direct GRUB Boot$direct changed ESP binding"; return 1; }
    ok "Recorded parked direct GRUB alias remains exact: Boot$direct"
}

eval "$(declare -f verify_pending_candidate_ownership_unchanged | sed '1s/verify_pending_candidate_ownership_unchanged/verify_pending_candidate_ownership_unchanged_pre_leap16_r38/')"
verify_pending_candidate_ownership_unchanged() {
    verify_pending_candidate_ownership_unchanged_pre_leap16_r38 "$@" || return $?
    leap16_r38_pending || return 0
    leap16_r38_verify_direct_alias
}

# Cleanup must remove both GRUB aliases and the native Leap target namespace.
eval "$(declare -f r26_remove_uncommitted_target_namespaces | sed '1s/r26_remove_uncommitted_target_namespaces/r26_remove_uncommitted_target_namespaces_pre_leap16_r38/')"
r26_remove_uncommitted_target_namespaces() {
    local target=$1 path id
    if [[ ${BOOTLOADER:-} != systemd-boot || $target != grub ]]; then
        r26_remove_uncommitted_target_namespaces_pre_leap16_r38 "$@"
        return $?
    fi
    for path in "$R28_GRUB_SHIM_PATH" "$R28_GRUB_DIRECT_PATH"; do
        while IFS= read -r id; do
            [[ -n $id ]] || continue
            sudo efibootmgr -b "$id" -B >/dev/null 2>&1 || return 1
            ok "Removed uncommitted native GRUB2 NVRAM alias Boot$id"
        done < <(r28_ids_for_path "$path")
    done
    r26_restore_source_fallback_after_target_stage || true
    r28_restore_source_boot_aux || true
    for path in /etc/default/grub /boot/grub2 "${ESP_MOUNT%/}/EFI/OPENSUSE"; do
        if sudo -n test -e "$path" 2>/dev/null || sudo -n test -L "$path" 2>/dev/null || [[ -e $path || -L $path ]]; then
            sudo rm -rf -- "$path" || return 1
            ok "Removed uncommitted native GRUB2 target namespace: $path"
        fi
    done
    return 0
}

leap16_r38_order_without_target() {
    local target=${PENDING_TARGET_BOOT_ID^^} order id joined
    local -a ids=() out=()
    order=$(leap16_current_boot_order) || return 1
    IFS=',' read -ra ids <<<"$order"
    for id in "${ids[@]}"; do
        id=${id^^}
        [[ -n $id && $id != "$target" ]] || continue
        boot_id_exists "$id" && out+=("$id")
    done
    ((${#out[@]} > 0)) || { fail 'Rollback would leave an empty persistent BootOrder'; return 1; }
    joined=$(IFS=,; printf '%s' "${out[*]}")
    sudo efibootmgr -o "$joined" >/dev/null || return 1
    [[ $(pending_bootorder_first) == ${PENDING_OLD_BOOT_ID^^} ]] || { fail 'Source systemd-boot is not first after removing the GRUB target from BootOrder'; return 1; }
    ok "Removed only GRUB shim Boot$target from persistent BootOrder while its EFI still exists"
}

leap16_r38_rollback() {
    local next direct target source answer
    validate_pending_compatibility || { fail "Pending reverse transaction is incompatible: $PENDING_REASON"; return 1; }
    leap16_r38_pending || return 1
    detect_bootloader
    source=${PENDING_OLD_BOOT_ID^^}; target=${PENDING_TARGET_BOOT_ID^^}; direct=$(leap16_r38_direct_id)
    [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == "$source" ]] || { fail "Rollback requires recorded systemd-boot source Boot$source"; return 1; }
    run_validation preflight || return 1
    verify_pending_source_recovery_unchanged || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    next=$(pending_bootnext_id)
    [[ -z $next || ${next^^} == "$target" ]] || { fail "Unrelated BootNext=Boot$next exists; refusing rollback"; return 1; }
    printf '\nExact systemd-boot -> GRUB2 candidate rollback:\n'
    printf '  - keep source systemd-boot Boot%s and its EFI fallback byte-identical\n' "$source"
    printf '  - remove shim Boot%s from BootOrder before deleting it\n' "$target"
    printf '  - delete only recorded shim Boot%s + parked direct GRUB Boot%s\n' "$target" "$direct"
    printf '  - remove only transaction-owned EFI/OPENSUSE + /boot/grub2 + /etc/default/grub\n'
    read -r -p 'Type ROLLBACK to remove this exact GRUB2 candidate: ' answer
    [[ $answer == ROLLBACK ]] || { printf 'Rollback cancelled. No state was modified.\n'; return 0; }
    [[ -z $next ]] || sudo efibootmgr -N >/dev/null || return 1
    r22_disarm_user_resume_bundle || true
    leap16_r38_order_without_target || return 1
    boot_id_exists "$target" && sudo efibootmgr -b "$target" -B >/dev/null || true
    boot_id_exists "$direct" && sudo efibootmgr -b "$direct" -B >/dev/null || true
    r26_remove_owned_manifest_paths "$PENDING_TARGET_MANIFEST" || return 1
    r26_restore_fallback_on_rollback || return 1
    r28_restore_source_boot_aux || return 1
    [[ -z $(leap16_r38_native_grub_ids) ]] || { fail 'A native GRUB2 alias remains after rollback'; return 1; }
    verify_pending_source_recovery_unchanged || return 1
    remove_pending_transaction_snapshot || true
    rm -f -- "$PENDING_STATE_FILE"
    r35_write_local_transaction_result success "systemd-boot -> GRUB2 candidate rolled back exactly. systemd-boot Boot$source remains authoritative; shim Boot$target, direct GRUB Boot$direct and only transaction-owned GRUB files were removed." || true
    ok 'ROLLBACK-COMPLETE. systemd-boot remains authoritative; the GRUB2 candidate is fully removed.'
}

# Route rollback for this edge to the exact two-alias cleanup above.
eval "$(declare -f rollback_pending_candidate | sed '1s/rollback_pending_candidate/rollback_pending_candidate_pre_leap16_r38/')"
rollback_pending_candidate() {
    if leap16_r38_pending; then
        leap16_r38_rollback
    else
        rollback_pending_candidate_pre_leap16_r38 "$@"
    fi
}

leap16_r38_set_loader_policy_grub() {
    local tmp
    [[ -f /etc/sysconfig/bootloader ]] || return 0
    tmp=$(mktemp) || return 1
    awk '
        BEGIN{done=0}
        /^[[:space:]]*LOADER_TYPE=/ {print "LOADER_TYPE=grub2-efi"; done=1; next}
        {print}
        END{if(!done) print "LOADER_TYPE=grub2-efi"}
    ' /etc/sysconfig/bootloader >"$tmp" || { rm -f -- "$tmp"; return 1; }
    sudo install -m 0644 -- "$tmp" /etc/sysconfig/bootloader || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
    ok 'Updated openSUSE bootloader policy to LOADER_TYPE=grub2-efi after exact GRUB runtime proof'
}

leap16_r38_transfer_grub_fallback() {
    local fallback="$PENDING_OLD_FALLBACK_PATH" hash
    if r28_transfer_complete; then
        [[ $(r21_hash_privileged "$fallback") == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'Fallback-transfer marker exists but EFI/BOOT is not the proven shim'; return 1; }
        ok 'Recovered persisted GRUB fallback-transfer checkpoint'
        return 0
    fi
    printf '\nTRANSFERRING generic EFI fallback to runtime-proven native openSUSE shim:\n'
    r21_atomic_replace "$PENDING_TARGET_EFI_RESOLVED" "$fallback" "$PENDING_TARGET_EFI_HASH" || return 1
    hash=$(r21_hash_privileged "$fallback")
    [[ $hash == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'EFI/BOOT did not become byte-identical to the proven openSUSE shim'; return 1; }
    r28_install_generated_boot_aux || return 1
    r28_mark_transfer_complete || return 1
    ok 'EFI/BOOT ownership transfer to runtime-proven native openSUSE shim is transaction-persisted'
}

leap16_r38_final_grub_order_without_systemd() {
    local target=${PENDING_TARGET_BOOT_ID^^} direct source=${PENDING_OLD_BOOT_ID^^} order id joined
    direct=$(leap16_r38_direct_id)
    local -a ids=() out=("$target" "$direct")
    order=$(leap16_current_boot_order) || return 1
    IFS=',' read -ra ids <<<"$order"
    for id in "${ids[@]}"; do
        id=${id^^}
        [[ -n $id && $id != "$target" && $id != "$direct" && $id != "$source" ]] || continue
        boot_id_exists "$id" && out+=("$id")
    done
    joined=$(IFS=,; printf '%s' "${out[*]}")
    sudo efibootmgr -o "$joined" >/dev/null || return 1
    order=$(leap16_current_boot_order)
    [[ $order == "$target,$direct"* ]] || { fail "Final GRUB BootOrder does not begin shim/direct ($order)"; return 1; }
    ! leap16_order_has_id "$order" "$source" || { fail "Source systemd-boot Boot$source remains in persistent BootOrder"; return 1; }
    ok "Removed source systemd-boot Boot$source from BootOrder while canonical systemd EFI still exists; GRUB shim/direct are first"
}

leap16_r38_finalize() {
    local source target direct
    validate_pending_compatibility || { fail "Pending reverse transaction is incompatible: $PENDING_REASON"; return 1; }
    leap16_r38_pending || return 1
    [[ $PENDING_PHASE == runtime-validated ]] || { fail 'Finalization requires runtime-validated GRUB2 state'; return 1; }
    source=${PENDING_OLD_BOOT_ID^^}; target=${PENDING_TARGET_BOOT_ID^^}; direct=$(leap16_r38_direct_id)
    detect_bootloader
    [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == "$target" ]] || { fail "Finalization must run from runtime-proven shim Boot$target"; return 1; }
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext must be clear before persistent finalization'; return 1; }
    run_validation preflight || return 1
    pending_validate_running_kernel || return 1
    pending_validate_runtime_cmdline_against_source || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_grub_boot_chain runtime || return 1
    verify_pending_source_recovery_unchanged || return 1
    leap16_r38_verify_direct_alias || return 1

    printf '\nFINALIZE hardware-proven systemd-boot -> GRUB2:\n'
    printf '  - promote shim Boot%s first while systemd-boot recovery still exists\n' "$target"
    printf '  - transfer EFI/BOOT only after runtime proof and GRUB promotion\n'
    printf '  - make direct GRUB Boot%s second and remove source Boot%s from BootOrder while source EFI still exists\n' "$direct" "$source"
    printf '  - delete exact source systemd-boot Boot%s, then retire only its ownership-manifest files\n' "$source"

    leap16_r34_target_first_keep_recovery || { fail 'Could not promote GRUB shim while retaining source recovery'; return 1; }
    validate_grub_boot_chain target || { fail 'GRUB2 validation failed after promotion; source cleanup was not attempted'; return 1; }
    verify_pending_candidate_ownership_unchanged || return 1
    verify_pending_source_recovery_unchanged || { fail 'systemd-boot recovery changed after GRUB promotion; no cleanup was attempted'; return 1; }

    leap16_r38_transfer_grub_fallback || return 1
    # Source fallback ownership has now intentionally transferred.  Verify its
    # remaining canonical/BLS ownership directly instead of the pre-transfer
    # fallback hash gate before source retirement.
    r26_verify_owned_manifest "$PENDING_SOURCE_MANIFEST" || return 1
    boot_id_exists "$source" || { fail "Source systemd-boot Boot$source disappeared before safe retirement"; return 1; }
    nvram_id_matches_path "$source" "$PENDING_OLD_BOOT_EFI_PATH" || { fail 'Source systemd-boot NVRAM path changed before retirement'; return 1; }

    leap16_r38_final_grub_order_without_systemd || return 1
    sudo efibootmgr -b "$source" -B >/dev/null || { fail "Could not delete source systemd-boot Boot$source"; return 1; }
    boot_id_exists "$source" && { fail "Source systemd-boot Boot$source still exists after deletion"; return 1; }
    ok "Deleted exact source systemd-boot Boot$source only after it was absent from persistent BootOrder"

    r26_remove_owned_manifest_paths "$PENDING_SOURCE_MANIFEST" || return 1
    sudo rmdir -- "$PENDING_ESP_MOUNT/loader/entries" 2>/dev/null || true
    sudo rmdir -- "$PENDING_ESP_MOUNT/loader" 2>/dev/null || true
    ok 'Removed only ownership-proven systemd-boot EFI/BLS/payload state after source NVRAM retirement'
    leap16_r38_set_loader_policy_grub || return 1

    detect_bootloader
    [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == "$target" ]] || { fail 'Final GRUB2 BootCurrent identity changed during source retirement'; return 1; }
    [[ $(pending_bootorder_first) == "$target" ]] || { fail 'GRUB shim is not first after systemd-boot retirement'; return 1; }
    [[ $(leap16_current_boot_order) == "$target,$direct"* ]] || { fail 'Direct GRUB is not second after finalization'; return 1; }
    [[ -z $(leap16_r38_current_systemd_ids) ]] || { fail 'A canonical systemd-boot NVRAM alias remains after retirement'; return 1; }
    path_exists_on_esp_privileged "$LEAP16_R32_SDBOOT_EFI" && { fail 'Canonical EFI/systemd payload remains after retirement'; return 1; }
    [[ $(r21_hash_privileged "$PENDING_ESP_MOUNT/EFI/BOOT/BOOTX64.EFI") == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'Final generic EFI fallback is not byte-identical to the proven shim'; return 1; }
    validate_target_state grub || return 1
    validate_grub_boot_chain final || return 1
    leap16_r38_verify_direct_alias || return 1

    pending_capture_runtime_diagnostics finalized-grub-from-systemd >/dev/null 2>&1 || true
    remove_pending_transaction_snapshot || true
    rm -f -- "$PENDING_STATE_FILE"
    r35_write_local_transaction_result success "systemd-boot -> native openSUSE GRUB2 finalized after exact runtime proof. Shim Boot$target is first, direct GRUB Boot$direct second, EFI/BOOT is shim-owned, and exact source systemd-boot NVRAM/BLS/payload ownership was retired." || true
    printf '\nFINALIZED systemd-boot -> native openSUSE GRUB2 successfully.\n'
    printf 'Shim Boot%s is persistent first; direct GRUB Boot%s is second; EFI/BOOT is byte-identical shim; exact source systemd-boot state is retired.\n' "$target" "$direct"
}

# Use the reverse-specific retirement/fallback topology instead of r26's
# single-alias source cleanup (which is not firmware-safe enough for this board).
eval "$(declare -f r26_finalize_adapter_transaction | sed '1s/r26_finalize_adapter_transaction/r26_finalize_adapter_transaction_pre_leap16_r38/')"
r26_finalize_adapter_transaction() {
    if leap16_r38_pending; then
        leap16_r38_finalize
    else
        r26_finalize_adapter_transaction_pre_leap16_r38 "$@"
    fi
}

# Expose exactly the newly hardware-next reverse edge.
eval "$(declare -f operation_supported | sed '1s/operation_supported/operation_supported_pre_leap16_r38/')"
operation_supported() {
    [[ $1:$2 == systemd-boot:grub ]] && return 0
    operation_supported_pre_leap16_r38 "$@"
}

eval "$(declare -f run_live_operation | sed '1s/run_live_operation/run_live_operation_pre_leap16_r38/')"
run_live_operation() {
    local target=${1:-} current
    detect_bootloader
    current=$BOOTLOADER
    if [[ $current:$target != systemd-boot:grub ]]; then
        run_live_operation_pre_leap16_r38 "$@"
        return $?
    fi
    leap16_r38_preflight "$target" || return 1
    leap16_r38_plan
    printf '\nNo systemd-boot user backup/restore integration is enabled in %s; only the mandatory private transaction snapshot is created.\n' "${SWITCHER_RELEASE:-leap16-r38}"
    confirm_operation "$current" "$target" || { printf '\nOperation cancelled. No boot state was modified.\n'; return 0; }
    printf '\nRe-running the complete systemd-boot -> GRUB2 preflight at the write boundary...\n'
    leap16_r38_preflight "$target" || { printf '\nWrite-boundary revalidation failed. Nothing was modified.\n'; return 1; }
    LEAP16_R38_REVERSE_STAGING=1
    r26_execute_adapter_switch grub
    local rc=$?
    LEAP16_R38_REVERSE_STAGING=0
    return "$rc"
}

# Pending UX: keep the generic r26 menu mechanics but make the edge explicit.
eval "$(declare -f pending_banner | sed '1s/pending_banner/pending_banner_pre_leap16_r38/')"
pending_banner() {
    if pending_exists && validate_pending_compatibility >/dev/null 2>&1 && leap16_r38_pending; then
        detect_bootloader
        printf 'Pending/staged migration: systemd-boot -> GRUB2  [%s]' "$PENDING_PHASE"
        case "$PENDING_PHASE:$BOOTLOADER" in
            candidate-ready:systemd-boot) printf '  [NATIVE GRUB2 TARGET PARKED]\n' ;;
            boot-armed:systemd-boot) printf '  [GRUB2 BootNext + AUTO-RESUME ARMED]\n' ;;
            boot-armed:grub) printf '  [GRUB2 ACTIVE; RUNTIME PROOF AVAILABLE]\n' ;;
            runtime-validated:grub) printf '  [GRUB2 RUNTIME PROVEN; FINALIZATION ELIGIBLE]\n' ;;
            *) printf '  [CURRENT: %s]\n' "$(bootloader_display_name "$BOOTLOADER")" ;;
        esac
        return 0
    fi
    pending_banner_pre_leap16_r38 "$@"
}

# Correct the stale r37 manual-finalization record when the *current* machine
# proves the finalized systemd-only topology.  This is display-only; it does not
# rewrite history or any boot state.
eval "$(declare -f r22_show_last_auto_result | sed '1s/r22_show_last_auto_result/r22_show_last_auto_result_pre_leap16_r38/')"
r22_show_last_auto_result() {
    local f="$PENDING_STATE_DIR/${R22_RESULT_FILE_NAME:-last-auto-result.txt}" detail=''
    if ! pending_exists && [[ -f $f ]]; then
        detail=$(sed -n 's/^detail=//p' "$f" 2>/dev/null | head -n1 || true)
        if [[ $detail == 'systemd-boot booted, but exact runtime proof failed; persistent promotion/GRUB2 retirement were NOT attempted.' ]]; then
            detect_bootloader
            if [[ $BOOTLOADER == systemd-boot \
                  && -z $(r28_current_native_grub_ids_csv) \
                  && ! -e /boot/grub2 && ! -e /etc/default/grub \
                  && $(leap16_current_boot_order) == "${BOOT_CURRENT^^}" \
                  && $(r21_hash_privileged "${ESP_MOUNT%/}/EFI/BOOT/BOOTX64.EFI") == $(r21_hash_privileged "${ESP_MOUNT%/}/EFI/systemd/systemd-bootx64.efi") ]]; then
                printf 'Last recorded transaction event:\n'
                printf '  [NOTE] The stored r36 automatic-resume failure predates the later manual r37 runtime proof/finalization.\n'
                printf '  [CURRENT] Finalized systemd-boot topology is physically present; the stale failure record is superseded by current state.\n\n'
                return 0
            fi
        fi
    fi
    r22_show_last_auto_result_pre_leap16_r38 "$@"
}
