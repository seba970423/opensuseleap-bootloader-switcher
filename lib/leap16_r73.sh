#!/usr/bin/env bash
# leap16-r73: fail-closed, same-backend repair for a bootable but incomplete
# native openSUSE Leap GRUB2 installation.
#
# This deliberately does not call the inherited CachyOS repair implementation.
# It reconstructs the missing native policy/theme/grub.cfg layer while the
# currently running shim/direct-GRUB EFI executable remains byte-for-byte
# untouched. Only after that repaired state passes the normal deep validator
# may native shim-install refresh the EFI payload; NVRAM is normalized last.

R73_REPAIR_SNAPSHOT=''
R73_FILESYSTEM_PROVEN=0

leap16_r73_ids_for_native_path() {
    leap16_r48_ids_for_current_esp_path "$1"
}

leap16_r73_current_is_native_grub_path() {
    local current=${BOOT_CURRENT^^} id
    for id in $(leap16_r73_ids_for_native_path "$R28_GRUB_SHIM_PATH") \
              $(leap16_r73_ids_for_native_path "$R28_GRUB_DIRECT_PATH"); do
        [[ ${id^^} == "$current" ]] && return 0
    done
    return 1
}

leap16_r73_validate_existing_bootable_core() {
    local failures=0 ver line shim direct
    printf '\nBootable native GRUB2 core gate (policy-independent):\n'
    detect_bootloader
    [[ $BOOTLOADER == grub ]] && ok 'Currently booted backend is GRUB2' \
        || { fail 'Current backend is not GRUB2'; ((failures++)); }
    leap16_r73_current_is_native_grub_path \
        && ok "BootCurrent=Boot${BOOT_CURRENT^^} is a native openSUSE shim/direct-GRUB alias on this ESP" \
        || { fail 'BootCurrent is not bound to the native openSUSE shim/direct-GRUB path on this ESP'; ((failures++)); }
    shim=$(resolve_efi_path_on_esp_privileged "$R28_GRUB_SHIM_PATH" 2>/dev/null || true)
    direct=$(resolve_efi_path_on_esp_privileged "$R28_GRUB_DIRECT_PATH" 2>/dev/null || true)
    [[ -n $shim ]] && ok "Native shim exists: $shim" || { fail 'Native openSUSE shim is missing'; ((failures++)); }
    [[ -n $direct ]] && ok "Native direct GRUB EFI exists: $direct" || { fail 'Native openSUSE GRUBX64.EFI is missing'; ((failures++)); }
    if have file; then
        [[ -z $shim ]] || leap16_is_x86_64_efi_application "$shim" \
            || { fail 'Native shim is not an x86-64 EFI application'; ((failures++)); }
        [[ -z $direct ]] || leap16_is_x86_64_efi_application "$direct" \
            || { fail 'Native direct GRUB payload is not an x86-64 EFI application'; ((failures++)); }
    fi
    [[ -f /boot/grub2/grub.cfg ]] && ok '/boot/grub2/grub.cfg exists' || { fail '/boot/grub2/grub.cfg is missing'; ((failures++)); }
    leap16_grub_cfg_script_check >/dev/null 2>&1 && ok 'grub2-script-check accepts the currently bootable grub.cfg' \
        || { fail 'The currently bootable grub.cfg failed grub2-script-check'; ((failures++)); }
    collect_kernels
    ((${#KERNEL_VERSIONS[@]} > 0)) || { fail 'No complete installed kernel/initrd pairs were found'; ((failures++)); }
    for ver in "${KERNEL_VERSIONS[@]}"; do
        line=$(leap16_grub_cfg_grep -F -- "/boot/vmlinuz-$ver" 2>/dev/null | head -n1 || true)
        [[ -n $line ]] && ok "Current grub.cfg contains kernel $ver" \
            || { fail "Current grub.cfg has no entry for kernel $ver"; ((failures++)); }
    done
    [[ -n ${ROOT_UUID:-} ]] && leap16_grub_cfg_grep -Fq -- "root=UUID=$ROOT_UUID" >/dev/null 2>&1 \
        && ok 'Current grub.cfg carries the detected root UUID' \
        || { fail 'Current grub.cfg does not carry the detected root UUID'; ((failures++)); }
    grep -Eq '^[[:space:]]*LOADER_TYPE=.*grub2-efi' /etc/sysconfig/bootloader 2>/dev/null \
        && ok 'openSUSE LOADER_TYPE is grub2-efi' \
        || { fail 'openSUSE LOADER_TYPE is not grub2-efi'; ((failures++)); }
    ((failures == 0))
}

leap16_r73_repair_preflight() {
    printf '\n%s native GRUB2 repair preflight:\n' "${SWITCHER_RELEASE:-leap16-r73}"
    pending_exists && { fail 'A staged migration is already pending; same-backend repair will not stack transactions'; return 1; }
    run_validation preflight || { fail 'Base preflight failed; no boot state was modified'; return 1; }
    is_leap16 || { fail 'This repair backend is restricted to openSUSE Leap 16'; return 1; }
    leap16_require_sudo_session || return 1
    [[ -z ${BOOT_NEXT:-} ]] || { fail "BootNext is already set to Boot${BOOT_NEXT^^}; refusing to overwrite firmware intent"; return 1; }
    [[ ! -e /etc/default/grub && ! -L /etc/default/grub ]] \
        || { fail '/etc/default/grub already exists; r73 only repairs the proven missing-policy contamination shape'; return 1; }
    local p
    for p in grub2-mkconfig grub2-script-check grub2-probe shim-install efibootmgr rpm iconv tar; do
        have "$p" || { fail "$p is required for Leap-native GRUB2 repair"; return 1; }
    done
    rpm -q grub2-common grub2-x86_64-efi shim >/dev/null 2>&1 \
        || { fail 'Installed openSUSE GRUB2/shim RPM set is incomplete'; return 1; }
    [[ -f $R28_THEME_SOURCE/theme.txt ]] \
        || { fail "Packaged native openSUSE GRUB theme is missing: $R28_THEME_SOURCE/theme.txt"; return 1; }
    shim-install --help 2>&1 | grep -q -- '--no-nvram' \
        || { fail 'Installed shim-install lacks --no-nvram'; return 1; }
    shim-install --help 2>&1 | grep -q -- '--efi-directory' \
        || { fail 'Installed shim-install lacks --efi-directory'; return 1; }
    shim-install --help 2>&1 | grep -q -- '--config-file' \
        || { fail 'Installed shim-install lacks --config-file'; return 1; }
    leap16_r73_validate_existing_bootable_core || {
        fail 'The retained GRUB core is not independently bootable; refusing in-place reconstruction'
        return 1
    }
    ok 'Repair is applicable: native policy/config proof will precede any package-owned EFI refresh'
}

leap16_r73_repair_plan() {
    printf '\nFail-closed Leap-native GRUB2 repair plan:\n'
    printf '  1. Re-prove the running native shim/direct-GRUB path, current grub.cfg, every installed kernel/initrd, root UUID, packages and LOADER_TYPE=grub2-efi.\n'
    printf '  2. Snapshot the current grub.cfg, native theme, EFI/OPENSUSE and EFI/BOOT state; record that /etc/default/grub is absent.\n'
    printf '  3. Generate the Leap-native /etc/default/grub policy, copy the packaged openSUSE theme, and build a candidate with grub2-mkconfig.\n'
    printf '  4. Validate the candidate before replacing the bootable grub.cfg; on failure restore the exact pre-repair filesystem state.\n'
    printf '  5. Deep-validate the repaired running GRUB chain with the existing strict policy/theme gates while current EFI bytes are still untouched.\n'
    printf '  6. Refresh native shim/direct/fallback EFI files with shim-install --no-nvram; prove firmware state was unchanged and deep-validate the complete result.\n'
    printf '  7. Only after those proofs, create/retain one shim alias and one direct-GRUB alias, remove only duplicate same-ESP aliases, and set shim/direct first in BootOrder.\n'
    printf '  8. Re-run deep validation and exact NVRAM topology checks. No kernel regeneration, mkinitcpio, /boot/grub, grub-install, or CachyOS EFI namespace is used.\n'
}

leap16_r73_snapshot_efi_tree() {
    local name=$1 path="$ESP_MOUNT/EFI/$1" manifest="$R73_REPAIR_SNAPSHOT/efi-$1.manifest.tsv"
    if sudo -n test -e "$path" 2>/dev/null || [[ -e $path ]]; then
        printf 'present\n' >"$R73_REPAIR_SNAPSHOT/efi-$name.state" || return 1
        write_privileged_tree_manifest "$path" "$manifest" || return 1
        [[ -s $manifest ]] || return 1
        sudo tar -C "$ESP_MOUNT/EFI" -cpf - "$name" >"$R73_REPAIR_SNAPSHOT/efi-$name.tar" || return 1
        tar -tf "$R73_REPAIR_SNAPSHOT/efi-$name.tar" >/dev/null || return 1
    else
        printf 'absent\n' >"$R73_REPAIR_SNAPSHOT/efi-$name.state" || return 1
    fi
}

leap16_r73_snapshot_filesystem() {
    local cfg_hash
    mkdir -p -- "$PENDING_STATE_DIR" || return 1
    chmod 700 -- "$PENDING_STATE_DIR" 2>/dev/null || true
    R73_REPAIR_SNAPSHOT=$(mktemp -d "$PENDING_STATE_DIR/.grub-repair.XXXXXX") || return 1
    chmod 700 -- "$R73_REPAIR_SNAPSHOT" 2>/dev/null || true
    sudo tar -C /boot/grub2 -cpf - grub.cfg >"$R73_REPAIR_SNAPSHOT/grub.cfg.tar" || return 1
    [[ $(tar -tf "$R73_REPAIR_SNAPSHOT/grub.cfg.tar" 2>/dev/null) == grub.cfg ]] || return 1
    cfg_hash=$(leap16_hash_file_privileged /boot/grub2/grub.cfg)
    [[ $cfg_hash =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
    printf '%s\n' "$cfg_hash" >"$R73_REPAIR_SNAPSHOT/grub.cfg.sha256" || return 1
    if sudo -n test -e "$R21_GRUB_THEME_DIR" 2>/dev/null || [[ -e $R21_GRUB_THEME_DIR ]]; then
        printf 'present\n' >"$R73_REPAIR_SNAPSHOT/theme.state" || return 1
        write_privileged_tree_manifest "$R21_GRUB_THEME_DIR" "$R73_REPAIR_SNAPSHOT/theme.manifest.tsv" || return 1
        [[ -s $R73_REPAIR_SNAPSHOT/theme.manifest.tsv ]] || return 1
        sudo tar -C "$(dirname -- "$R21_GRUB_THEME_DIR")" -cpf - "$(basename -- "$R21_GRUB_THEME_DIR")" \
            >"$R73_REPAIR_SNAPSHOT/theme.tar" || return 1
        tar -tf "$R73_REPAIR_SNAPSHOT/theme.tar" >/dev/null || return 1
    else
        printf 'absent\n' >"$R73_REPAIR_SNAPSHOT/theme.state" || return 1
    fi
    leap16_r73_snapshot_efi_tree OPENSUSE || return 1
    leap16_r73_snapshot_efi_tree BOOT || return 1
    printf 'absent\n' >"$R73_REPAIR_SNAPSHOT/default-grub.state" || return 1
    ok 'Snapshotted the exact pre-repair GRUB policy/config/theme and EFI/OPENSUSE + EFI/BOOT state'
}

leap16_r73_restore_efi_tree() {
    local name=$1 path="$ESP_MOUNT/EFI/$1" state
    state=$(cat "$R73_REPAIR_SNAPSHOT/efi-$name.state" 2>/dev/null || true)
    sudo rm -rf -- "$path" || return 1
    if [[ $state == present ]]; then
        sudo mkdir -p -- "$ESP_MOUNT/EFI" || return 1
        sudo tar -C "$ESP_MOUNT/EFI" -xpf "$R73_REPAIR_SNAPSHOT/efi-$name.tar" || return 1
        pending_verify_tree_manifest "$path" "$R73_REPAIR_SNAPSHOT/efi-$name.manifest.tsv" || return 1
    elif [[ $state != absent ]]; then
        return 1
    elif sudo -n test -e "$path" 2>/dev/null || [[ -e $path ]]; then
        return 1
    fi
}

leap16_r73_restore_filesystem_snapshot() {
    local state expected
    [[ -n $R73_REPAIR_SNAPSHOT && -d $R73_REPAIR_SNAPSHOT ]] || return 1
    sudo rm -f -- /etc/default/grub || return 1
    sudo tar -C /boot/grub2 -xpf "$R73_REPAIR_SNAPSHOT/grub.cfg.tar" || return 1
    expected=$(cat "$R73_REPAIR_SNAPSHOT/grub.cfg.sha256" 2>/dev/null || true)
    [[ $expected =~ ^[0-9A-Fa-f]{64}$ && $(leap16_hash_file_privileged /boot/grub2/grub.cfg) == "$expected" ]] || return 1
    state=$(cat "$R73_REPAIR_SNAPSHOT/theme.state" 2>/dev/null || true)
    sudo rm -rf -- "$R21_GRUB_THEME_DIR" || return 1
    if [[ $state == present ]]; then
        sudo mkdir -p -- "$(dirname -- "$R21_GRUB_THEME_DIR")" || return 1
        sudo tar -C "$(dirname -- "$R21_GRUB_THEME_DIR")" -xpf "$R73_REPAIR_SNAPSHOT/theme.tar" || return 1
        pending_verify_tree_manifest "$R21_GRUB_THEME_DIR" "$R73_REPAIR_SNAPSHOT/theme.manifest.tsv" || return 1
    elif [[ $state != absent ]]; then
        return 1
    elif sudo -n test -e "$R21_GRUB_THEME_DIR" 2>/dev/null || [[ -e $R21_GRUB_THEME_DIR ]]; then
        return 1
    fi
    leap16_r73_restore_efi_tree OPENSUSE || return 1
    leap16_r73_restore_efi_tree BOOT || return 1
    ok 'Restored the exact pre-repair filesystem state; the original bootable GRUB path remains authoritative'
}

leap16_r73_validate_candidate_cfg() {
    local cfg=$1 ver
    sudo grub2-script-check "$cfg" >/dev/null 2>&1 || { fail 'grub2-script-check rejected the generated repair candidate'; return 1; }
    collect_kernels
    for ver in "${KERNEL_VERSIONS[@]}"; do
        sudo grep -Fq -- "/boot/vmlinuz-$ver" "$cfg" \
            || { fail "Repair candidate has no entry for kernel $ver"; return 1; }
    done
    [[ -n ${ROOT_UUID:-} ]] && sudo grep -Fq -- "root=UUID=$ROOT_UUID" "$cfg" \
        || { fail 'Repair candidate does not carry the detected root UUID'; return 1; }
    grep -Fqx 'GRUB_THEME=/boot/grub2/themes/openSUSE/theme.txt' /etc/default/grub \
        || { fail 'Generated policy does not select the native openSUSE theme'; return 1; }
    [[ -f $R21_GRUB_THEME_PATH ]] || { fail 'Installed native openSUSE theme is incomplete'; return 1; }
    ok 'Generated grub.cfg candidate passed syntax, kernel, root and native-theme policy validation'
}

leap16_r73_ids_csv_for_path() {
    leap16_r73_ids_for_native_path "$1" | awk 'NF{print toupper($0)}' | LC_ALL=C sort -u | paste -sd, -
}

leap16_r73_validate_native_efi_payload() {
    local shim direct fallback bootcsv text
    shim=$(resolve_efi_path_on_esp_privileged "$R28_GRUB_SHIM_PATH" 2>/dev/null || true)
    direct=$(resolve_efi_path_on_esp_privileged "$R28_GRUB_DIRECT_PATH" 2>/dev/null || true)
    [[ -n $shim && -n $direct ]] || { fail 'shim-install did not leave both native shim and direct-GRUB EFI files'; return 1; }
    if have file; then
        leap16_is_x86_64_efi_application "$shim" || { fail 'Refreshed shim is not an x86-64 EFI application'; return 1; }
        leap16_is_x86_64_efi_application "$direct" || { fail 'Refreshed direct GRUB is not an x86-64 EFI application'; return 1; }
    fi
    bootcsv="$ESP_MOUNT/EFI/OPENSUSE/boot.csv"
    (sudo -n test -f "$bootcsv" 2>/dev/null || [[ -f $bootcsv ]]) || { fail 'Native openSUSE boot.csv is missing'; return 1; }
    if [[ -r $bootcsv ]]; then
        text=$(iconv -f UTF-16 -t UTF-8 "$bootcsv" 2>/dev/null | tr -d '\r\n' || true)
    else
        text=$(sudo -n iconv -f UTF-16 -t UTF-8 "$bootcsv" 2>/dev/null | tr -d '\r\n' || true)
    fi
    [[ ${text,,} == 'shim.efi,opensuse-secureboot' ]] \
        || { fail "Native openSUSE boot.csv has unexpected content: ${text:-unreadable}"; return 1; }
    fallback="$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"
    (sudo -n test -f "$fallback" 2>/dev/null || [[ -f $fallback ]]) || { fail 'Native generic EFI fallback is missing'; return 1; }
    [[ $(leap16_hash_file_privileged "$fallback") == $(leap16_hash_file_privileged "$shim") ]] \
        || { fail 'Generic EFI fallback is not byte-identical to native openSUSE shim'; return 1; }
    ok 'Native shim/direct-GRUB, boot.csv and byte-identical shim fallback are complete'
}

leap16_r73_remove_unexpected_no_nvram_ids() {
    local path=$1 before=$2 id
    while IFS= read -r id; do
        id=${id^^}; [[ $id =~ ^[0-9A-F]{4}$ ]] || continue
        [[ ,$before, == *,$id,* ]] && continue
        [[ $id != ${BOOT_CURRENT^^} ]] || { fail "shim-install unexpectedly replaced current identity with Boot$id; refusing deletion"; return 1; }
        leap16_nvram_entry_matches_current_esp "$id" && nvram_id_matches_path "$id" "$path" \
            || { fail "Unexpected Boot$id is not ownership-proven to the native GRUB path/current ESP"; return 1; }
        sudo efibootmgr -b "$id" -B >/dev/null || return 1
        ok "Removed unexpected shim-install --no-nvram alias Boot$id"
    done < <(leap16_r73_ids_for_native_path "$path")
}

leap16_r73_restore_no_nvram_baseline() {
    local order=$1 shim_before=$2 direct_before=$3 next
    leap16_r73_remove_unexpected_no_nvram_ids "$R28_GRUB_SHIM_PATH" "$shim_before" || return 1
    leap16_r73_remove_unexpected_no_nvram_ids "$R28_GRUB_DIRECT_PATH" "$direct_before" || return 1
    next=$(pending_bootnext_id 2>/dev/null || true)
    if [[ -n $next ]]; then
        leap16_nvram_entry_matches_current_esp "$next" \
            && { nvram_id_matches_path "$next" "$R28_GRUB_SHIM_PATH" || nvram_id_matches_path "$next" "$R28_GRUB_DIRECT_PATH"; } \
            || { fail "Unrelated BootNext=Boot${next^^} appeared during shim-install; refusing to clear it"; return 1; }
        sudo efibootmgr -N >/dev/null || return 1
    fi
    sudo efibootmgr -o "$order" >/dev/null || return 1
    [[ $(leap16_current_boot_order) == "$order" ]] || return 1
    [[ $(leap16_r73_ids_csv_for_path "$R28_GRUB_SHIM_PATH") == "$shim_before" ]] || return 1
    [[ $(leap16_r73_ids_csv_for_path "$R28_GRUB_DIRECT_PATH") == "$direct_before" ]] || return 1
    [[ -z $(pending_bootnext_id 2>/dev/null || true) ]] || return 1
    ok 'Restored exact pre-shim-install firmware intent after a --no-nvram contract violation'
}

leap16_r73_refresh_native_efi() {
    local order_before order_after shim_before direct_before shim_after direct_after next_after install_rc=0 changed=0
    order_before=$(leap16_current_boot_order) || return 1
    shim_before=$(leap16_r73_ids_csv_for_path "$R28_GRUB_SHIM_PATH")
    direct_before=$(leap16_r73_ids_csv_for_path "$R28_GRUB_DIRECT_PATH")
    sudo shim-install --no-nvram --efi-directory="$ESP_MOUNT" --config-file=/boot/grub2/grub.cfg >/dev/null || install_rc=$?
    order_after=$(leap16_current_boot_order 2>/dev/null || true)
    shim_after=$(leap16_r73_ids_csv_for_path "$R28_GRUB_SHIM_PATH")
    direct_after=$(leap16_r73_ids_csv_for_path "$R28_GRUB_DIRECT_PATH")
    next_after=$(pending_bootnext_id 2>/dev/null || true)
    [[ $order_after == "$order_before" && $shim_after == "$shim_before" && $direct_after == "$direct_before" && -z $next_after ]] || changed=1
    if ((changed)); then
        fail 'shim-install --no-nvram changed native GRUB firmware aliases, BootOrder, or BootNext'
        leap16_r73_restore_no_nvram_baseline "$order_before" "$shim_before" "$direct_before" \
            || { fail 'Could not restore exact firmware intent after the --no-nvram contract violation'; return 1; }
        return 1
    fi
    if ((install_rc != 0)); then
        fail "Native shim-install --no-nvram failed during post-policy EFI reconstruction (exit $install_rc)"
        return 1
    fi
    leap16_r73_validate_native_efi_payload || return 1
    validate_grub_boot_chain current || { fail 'Strict deep GRUB validation failed after native EFI reconstruction'; return 1; }
    ok 'shim-install refreshed native EFI payload without changing NVRAM intent'
}

leap16_r73_reconstruct_filesystem() {
    local policy candidate policy_hash
    policy="$R73_REPAIR_SNAPSHOT/default-grub.candidate"
    candidate="$R73_REPAIR_SNAPSHOT/grub.cfg.candidate"
    r28_render_grub_default "$policy" || return 1
    policy_hash=$(sha256sum -- "$policy" | awk '{print $1}')
    [[ $policy_hash =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
    sudo install -o root -g root -m 0644 -- "$policy" /etc/default/grub || return 1
    [[ $(leap16_hash_file_privileged /etc/default/grub) == "$policy_hash" ]] || { fail 'Installed native GRUB policy differs from generated bytes'; return 1; }
    sudo rm -rf -- "$R21_GRUB_THEME_DIR" || return 1
    sudo mkdir -p -- "$(dirname -- "$R21_GRUB_THEME_DIR")" || return 1
    sudo cp -a -- "$R28_THEME_SOURCE" "$R21_GRUB_THEME_DIR" || return 1
    sudo grub2-mkconfig -o "$candidate" >/dev/null \
        || { fail 'grub2-mkconfig failed while building the repair candidate'; return 1; }
    leap16_r73_validate_candidate_cfg "$candidate" || return 1
    sudo install -o root -g root -m 0600 -- "$candidate" /boot/grub2/grub.cfg || return 1
    validate_grub_boot_chain current || { fail 'Strict deep GRUB validation rejected the reconstructed filesystem state'; return 1; }
    ok 'Reconstructed native GRUB policy/theme/config passed the unchanged deep validator while current EFI bytes remained untouched'
    leap16_r73_refresh_native_efi || return 1
    R73_FILESYSTEM_PROVEN=1
    ok 'Complete package-generated native GRUB filesystem/EFI state passed deep validation before NVRAM normalization'
}

leap16_r73_choose_keep_id() {
    local path=$1 id current=${BOOT_CURRENT^^}
    while IFS= read -r id; do
        [[ ${id^^} == "$current" ]] && { printf '%s\n' "$current"; return 0; }
    done < <(leap16_r73_ids_for_native_path "$path")
    leap16_r73_ids_for_native_path "$path" | awk 'NF{print toupper($0); exit}'
}

leap16_r73_delete_duplicate_ids() {
    local path=$1 keep=${2^^} role=$3 id
    while IFS= read -r id; do
        id=${id^^}; [[ $id =~ ^[0-9A-F]{4}$ ]] || continue
        [[ $id == "$keep" ]] && continue
        leap16_nvram_entry_matches_current_esp "$id" && nvram_id_matches_path "$id" "$path" \
            || { fail "Refusing to delete unproven $role alias Boot$id"; return 1; }
        [[ $id != ${BOOT_CURRENT^^} ]] || { fail "Refusing to delete current Boot$id"; return 1; }
        sudo efibootmgr -b "$id" -B >/dev/null || { fail "Could not delete duplicate $role Boot$id"; return 1; }
        ok "Removed ownership-proven duplicate $role Boot$id"
    done < <(leap16_r73_ids_for_native_path "$path")
}

leap16_r73_normalize_nvram() {
    local shim direct old id new_order tail=''
    local -a shim_ids=() direct_ids=() _r73_order_ids=()
    ((R73_FILESYSTEM_PROVEN == 1)) || { fail 'NVRAM normalization is forbidden before repaired filesystem deep proof'; return 1; }
    mapfile -t shim_ids < <(leap16_r73_ids_for_native_path "$R28_GRUB_SHIM_PATH")
    if ((${#shim_ids[@]} == 0)); then
        r28_create_alias_create_only "$R28_GRUB_SHIM_LABEL" "$R28_GRUB_SHIM_PATH" || return 1
    fi
    mapfile -t direct_ids < <(leap16_r73_ids_for_native_path "$R28_GRUB_DIRECT_PATH")
    ((${#direct_ids[@]} > 0)) || { fail 'No native direct-GRUB alias exists after filesystem repair'; return 1; }
    shim=$(leap16_r73_choose_keep_id "$R28_GRUB_SHIM_PATH")
    direct=$(leap16_r73_choose_keep_id "$R28_GRUB_DIRECT_PATH")
    [[ $shim =~ ^[0-9A-F]{4}$ && $direct =~ ^[0-9A-F]{4}$ && $shim != "$direct" ]] \
        || { fail 'Could not select distinct native shim/direct aliases'; return 1; }

    leap16_r73_delete_duplicate_ids "$R28_GRUB_SHIM_PATH" "$shim" 'shim' || return 1
    leap16_r73_delete_duplicate_ids "$R28_GRUB_DIRECT_PATH" "$direct" 'direct-GRUB' || return 1

    old=$(leap16_current_boot_order) || return 1
    IFS=',' read -ra _r73_order_ids <<<"$old"
    for id in "${_r73_order_ids[@]}"; do
        id=${id^^}; [[ $id =~ ^[0-9A-F]{4}$ ]] || continue
        [[ $id == "$shim" || $id == "$direct" ]] && continue
        leap16_nvram_entry_matches_current_esp "$id" \
            && { nvram_id_matches_path "$id" "$R28_GRUB_SHIM_PATH" || nvram_id_matches_path "$id" "$R28_GRUB_DIRECT_PATH"; } \
            && continue
        [[ -n $tail ]] && tail+=','
        tail+=$id
    done
    new_order="$shim,$direct"; [[ -n $tail ]] && new_order+=",$tail"
    sudo efibootmgr -o "$new_order" >/dev/null || { fail 'Could not install canonical shim/direct GRUB BootOrder'; return 1; }
    [[ $(leap16_current_boot_order) == "$new_order" ]] || { fail 'Firmware did not retain canonical shim/direct GRUB BootOrder'; return 1; }
    [[ -z $(pending_bootnext_id 2>/dev/null || true) ]] || { fail 'BootNext appeared during same-backend GRUB repair'; return 1; }
    [[ $(leap16_r73_ids_for_native_path "$R28_GRUB_SHIM_PATH" | awk 'NF{n++} END{print n+0}') == 1 ]] \
        || { fail 'Final native shim alias count is not exactly one'; return 1; }
    [[ $(leap16_r73_ids_for_native_path "$R28_GRUB_DIRECT_PATH" | awk 'NF{n++} END{print n+0}') == 1 ]] \
        || { fail 'Final direct-GRUB alias count is not exactly one'; return 1; }
    validate_grub_boot_chain current || { fail 'Final deep GRUB validation failed after NVRAM normalization'; return 1; }
    ok "Canonical native GRUB NVRAM topology installed: shim Boot$shim first, direct GRUB Boot$direct second"
}

leap16_r73_execute_repair() {
    local rc=0
    R73_FILESYSTEM_PROVEN=0 R73_REPAIR_SNAPSHOT=''
    leap16_r73_snapshot_filesystem || { fail 'Could not create the required pre-repair snapshot'; return 1; }
    if ! leap16_r73_reconstruct_filesystem; then
        leap16_stage_diagnostic r73-grub-repair-filesystem-failed >/dev/null 2>&1 || true
        leap16_r73_restore_filesystem_snapshot \
            || { fail "Automatic filesystem rollback failed; evidence remains at $R73_REPAIR_SNAPSHOT"; return 1; }
        rm -rf -- "$R73_REPAIR_SNAPSHOT" 2>/dev/null || true
        R73_REPAIR_SNAPSHOT=''
        return 1
    fi
    if ! leap16_r73_normalize_nvram; then
        leap16_stage_diagnostic r73-grub-repair-nvram-incomplete >/dev/null 2>&1 || true
        fail 'Filesystem repair is deeply valid, but NVRAM normalization was not proven complete.'
        fail 'The repaired bootable files were retained; no unproven EFI executable was deleted. Inspect diagnostics before rebooting.'
        return 1
    fi
    rm -rf -- "$R73_REPAIR_SNAPSHOT" 2>/dev/null || true
    R73_REPAIR_SNAPSHOT=''
    printf '\nLeap-native GRUB2 repair completed successfully.\n'
    printf 'The strict policy/theme validator passes, package-generated shim/direct/fallback EFI is complete, shim is first, direct GRUB is second, and BootNext is empty.\n'
}

# Final dispatch layer: intercept only current GRUB -> GRUB.  This guarantees
# Leap never falls through to execute_grub_repair from the inherited Arch stack.
if declare -F run_live_operation >/dev/null 2>&1; then
    eval "$(declare -f run_live_operation | sed '1s/run_live_operation/run_live_operation_pre_leap16_r73/')"
fi
run_live_operation() {
    local target=${1:-} current
    detect_bootloader; current=$BOOTLOADER
    if [[ $current:$target != grub:grub ]]; then
        run_live_operation_pre_leap16_r73 "$@"
        return $?
    fi
    leap16_r44_with_transaction_transcript "$current" "$target" repair leap16_r73_run_repair_inner
}

leap16_r73_run_repair_inner() {
    leap16_r73_repair_preflight || return 1
    leap16_r73_repair_plan
    printf '\nA user GRUB backup is intentionally not offered for this operation because the contaminated source cannot pass the unchanged backup policy gate.\n'
    printf 'The repair creates its own mandatory exact rollback snapshot immediately before the first filesystem write.\n'
    confirm_operation grub grub || { printf '\nOperation cancelled. No boot state was modified.\n'; return 0; }
    printf '\nRe-running the complete Leap-native repair preflight at the write boundary...\n'
    leap16_r73_repair_preflight || { printf '\nWrite-boundary revalidation failed. Nothing was modified.\n'; return 1; }
    leap16_r73_execute_repair
}
