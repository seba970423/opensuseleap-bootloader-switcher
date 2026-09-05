#!/usr/bin/env bash
# openSUSE Leap 16 r28
#
# Complete the round trip from a fully-finalized Limine-only installation back
# to native openSUSE GRUB2.  r15 can adopt retained GRUB state, but r23+ can
# legitimately retire that state completely.  r28 therefore adds a second
# reverse backend which reconstructs native openSUSE GRUB2 from the installed
# RPM payloads without giving it persistent authority until an exact one-shot
# runtime proof succeeds.
#
# Finalized Limine source topology required by this path:
#   Boot#### openSUSE Limine -> \EFI\LIMINE\LIMINE_X64.EFI
#   Boot#### UEFI OS         -> \EFI\BOOT\BOOTX64.EFI (byte-identical Limine)
#   no EFI/OPENSUSE, /boot/grub2, /etc/default/grub, or native GRUB aliases
#
# Candidate GRUB topology before runtime proof:
#   Limine primary remains first
#   Limine fallback remains second / unchanged
#   direct-GRUB Boot#### exists but is deliberately parked outside BootOrder
#   openSUSE shim Boot#### is appended last and receives BootNext once
#
# Only exact shim/GRUB runtime proof permits promotion.  After promotion r28
# transfers EFI/BOOT back to the proven shim, removes both Limine firmware
# aliases + owned Limine files, and exposes native openSUSE shim first with the
# direct-GRUB alias second.

R28_GRUB_SHIM_PATH='\EFI\OPENSUSE\SHIM.EFI'
R28_GRUB_DIRECT_PATH='\EFI\OPENSUSE\GRUBX64.EFI'
R28_GRUB_SHIM_LABEL='opensuse-secureboot'
R28_GRUB_DIRECT_LABEL='opensuse'
R28_REBUILD_META_BASENAME='r28-rebuilt-grub.tsv'
R28_THEME_SOURCE='/usr/share/grub2/themes/openSUSE'

R28_PRIMARY_ID=''
R28_SOURCE_FALLBACK_ID=''
R28_DIRECT_ID=''
R28_TARGET_ID=''
R28_CREATED_ALIAS_ID=''
R28_REBUILD_STAGING=0

# A finalized r27 Limine menu legitimately exposes /EFI fallback while
# EFI/BOOT is byte-identical Limine. During r28 reverse staging EFI/OPENSUSE
# is reconstructed alongside that still-authoritative Limine source. Admit
# this otherwise forward-invalid combination only for the explicit reverse
# reconstruction phase.
eval "$(declare -f leap16_validate_limine_recovery_contract | sed '1s/leap16_validate_limine_recovery_contract/leap16_validate_limine_recovery_contract_pre_r28/')"
leap16_validate_limine_recovery_contract() {
    local conf=$1 fallback="$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI" primary="$ESP_MOUNT/EFI/LIMINE/LIMINE_X64.EFI" fh ph
    if [[ ${R28_REBUILD_STAGING:-0} == 1 ]] || r28_rebuilt_reverse_pending 2>/dev/null; then
        if r24_final_fallback_block_present "$conf"; then
            fh=$(r21_hash_privileged "$fallback")
            ph=$(r21_hash_privileged "$primary")
            if [[ $fh =~ ^[0-9A-Fa-f]{64}$ && $fh == "$ph" ]]; then
                LEAP16_LIMINE_RECOVERY_DETAIL='Limine still owns EFI/BOOT; reconstructed native GRUB2 is staged separately and has no persistent authority'
                return 0
            fi
        fi
    fi
    leap16_validate_limine_recovery_contract_pre_r28 "$@"
}


r28_rebuilt_reverse_pending() {
    [[ ${PENDING_FORMAT:-} == 4 \
       && ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == limine:grub \
       && ${PENDING_GRUB_DEFAULT_CREATED:-} == 1 ]]
}

# r15 originally treated format-4 marker=0 as the only Leap reverse mode.
# Keep that retained-target path, and additionally admit r28's marker=1
# reconstructed target so the proven resume machinery can be reused safely.
eval "$(declare -f leap16_reverse_pending | sed '1s/leap16_reverse_pending/leap16_reverse_pending_pre_r28/')"
leap16_reverse_pending() {
    [[ ${PENDING_FORMAT:-} == 4 \
       && ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == limine:grub \
       && ( ${PENDING_GRUB_DEFAULT_CREATED:-} == 0 || ${PENDING_GRUB_DEFAULT_CREATED:-} == 1 ) ]]
}

r28_meta_path() {
    local snap=${PENDING_TRANSACTION_SNAPSHOT_DIR:-${TRANSACTION_SNAPSHOT_DIR:-}}
    [[ -n $snap ]] || return 1
    printf '%s/%s\n' "$snap" "$R28_REBUILD_META_BASENAME"
}

r28_meta_value() {
    local key=$1 p
    p=$(r28_meta_path) || return 1
    awk -F'\t' -v k="$key" '$1==k{print $2; exit}' "$p" 2>/dev/null
}

r28_write_meta() {
    local source_fallback_id=${1^^} direct_id=${2^^} target_id=${3^^} p
    p=$(r28_meta_path) || return 1
    {
        printf 'rebuild_marker\t1\n'
        printf 'source_fallback_boot_id\t%s\n' "$source_fallback_id"
        printf 'direct_grub_boot_id\t%s\n' "$direct_id"
        printf 'target_shim_boot_id\t%s\n' "$target_id"
        printf 'source_fallback_path\t%s\n' "$LEAP16_R21_FALLBACK_EFI_PATH"
        printf 'direct_grub_path\t%s\n' "$R28_GRUB_DIRECT_PATH"
        printf 'target_shim_path\t%s\n' "$R28_GRUB_SHIM_PATH"
    } >"$p" || return 1
    chmod 600 -- "$p" 2>/dev/null || true
}

r28_validate_meta() {
    local p fallback direct target
    p=$(r28_meta_path) || { PENDING_REASON='r28 reconstructed-GRUB metadata path is unavailable'; return 1; }
    [[ -s $p ]] || { PENDING_REASON='r28 reconstructed-GRUB metadata is missing'; return 1; }
    pending_path_under "$p" "$PENDING_TRANSACTION_SNAPSHOT_DIR" || { PENDING_REASON='r28 reconstructed-GRUB metadata is outside the transaction snapshot'; return 1; }
    [[ $(r28_meta_value rebuild_marker) == 1 ]] || { PENDING_REASON='r28 reconstructed-GRUB marker is missing'; return 1; }
    fallback=$(r28_meta_value source_fallback_boot_id); direct=$(r28_meta_value direct_grub_boot_id); target=$(r28_meta_value target_shim_boot_id)
    [[ $fallback =~ ^[0-9A-Fa-f]{4}$ && $direct =~ ^[0-9A-Fa-f]{4}$ && $target =~ ^[0-9A-Fa-f]{4}$ ]] || { PENDING_REASON='r28 reconstructed-GRUB firmware IDs are malformed'; return 1; }
    [[ ${target^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { PENDING_REASON='r28 target shim ID disagrees with pending target identity'; return 1; }
    [[ $(r28_meta_value source_fallback_path) == "$LEAP16_R21_FALLBACK_EFI_PATH" ]] || { PENDING_REASON='r28 source fallback path metadata is unexpected'; return 1; }
    [[ $(r28_meta_value direct_grub_path) == "$R28_GRUB_DIRECT_PATH" ]] || { PENDING_REASON='r28 direct GRUB path metadata is unexpected'; return 1; }
    [[ $(r28_meta_value target_shim_path) == "$R28_GRUB_SHIM_PATH" ]] || { PENDING_REASON='r28 shim path metadata is unexpected'; return 1; }
    [[ -s $PENDING_TRANSACTION_SNAPSHOT_DIR/r28-efi-boot-aux-before.tsv ]] || { PENDING_REASON='r28 pre-stage EFI/BOOT auxiliary ownership record is missing'; return 1; }
    [[ -s $PENDING_TRANSACTION_SNAPSHOT_DIR/r28-efi-boot-aux-generated.tsv ]] || { PENDING_REASON='r28 generated EFI/BOOT auxiliary ownership record is missing'; return 1; }
    return 0
}

r28_ids_for_path() {
    # This helper is safe before pending state exists: bind discovery to the
    # currently detected ESP and compare the parsed EFI path exactly after
    # normalization, rather than relying on a substring match alone.
    local expected=$1 line id path expected_norm partuuid lower
    expected_norm=$(normalize_efi_path "$expected" | tr '[:upper:]' '[:lower:]')
    partuuid=$(lsblk -no PARTUUID -- "${ESP_SOURCE:-}" 2>/dev/null | awk 'NF{print tolower($1); exit}')
    [[ -n $expected_norm && -n $partuuid ]] || return 1
    while IFS= read -r line; do
        [[ $line =~ ^Boot([0-9A-Fa-f]{4})\*? ]] || continue
        id=${BASH_REMATCH[1]^^}
        path=$(efi_path_from_efibootmgr_line "$line" 2>/dev/null || true)
        [[ -n $path ]] || continue
        [[ $(normalize_efi_path "$path" | tr '[:upper:]' '[:lower:]') == "$expected_norm" ]] || continue
        lower=${line,,}
        [[ $lower == *"$partuuid"* ]] || continue
        printf '%s\n' "$id"
    done < <(efibootmgr -v 2>/dev/null)
}

r28_current_native_grub_ids_csv() {
    local path id csv=''
    local -a paths=("$R28_GRUB_SHIM_PATH" "$R28_GRUB_DIRECT_PATH" '\EFI\OPENSUSE\GRUB.EFI')
    for path in "${paths[@]}"; do
        while IFS= read -r id; do
            [[ $id =~ ^[0-9A-F]{4}$ ]] || continue
            id=${id^^}
            [[ ,$csv, == *,$id,* ]] && continue
            if [[ -n $csv ]]; then csv+=",$id"; else csv=$id; fi
        done < <(r28_ids_for_path "$path")
    done
    [[ -z $csv ]] || tr ',' '\n' <<<"$csv" | LC_ALL=C sort -u | paste -sd, -
}

r28_exact_one_id_for_path() {
    local path=$1 id
    local -a ids=()
    mapfile -t ids < <(r28_ids_for_path "$path")
    ((${#ids[@]} == 1)) || return 1
    id=${ids[0]^^}
    leap16_boot_entry_is_active "$id" || return 1
    leap16_nvram_entry_matches_current_esp "$id" || return 1
    printf '%s\n' "$id"
}

r28_validate_finalized_limine_source() {
    local ids primary fallback ph fh order grub_ids
    R28_PRIMARY_ID=''; R28_SOURCE_FALLBACK_ID=''

    pending_exists && { fail 'A staged migration is already pending; r28 will not stack transactions'; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == limine ]] || { fail 'Native GRUB2 reconstruction requires Limine as the current source'; return 1; }
    run_validation preflight || return 1
    [[ -z ${BOOT_NEXT:-} ]] || { fail "BootNext is already set to Boot${BOOT_NEXT^^}"; return 1; }
    leap16_require_sudo_session || return 1

    primary=$(r28_exact_one_id_for_path '\EFI\LIMINE\LIMINE_X64.EFI') || { fail 'Expected exactly one canonical Limine NVRAM alias on the current ESP'; return 1; }
    fallback=$(r28_exact_one_id_for_path "$LEAP16_R21_FALLBACK_EFI_PATH") || { fail 'Expected exactly one generic Limine fallback NVRAM alias on the current ESP'; return 1; }
    [[ ${BOOT_CURRENT^^} == ${primary^^} ]] || { fail "Finalized reverse staging must start from primary Limine Boot$primary (BootCurrent=${BOOT_CURRENT^^})"; return 1; }
    order=$(leap16_current_boot_order)
    [[ $order == "$primary,$fallback"* ]] || { fail "Persistent BootOrder is not primary-Limine/fallback first ($order)"; return 1; }

    ph=$(r21_hash_privileged "$ESP_MOUNT/EFI/LIMINE/LIMINE_X64.EFI")
    fh=$(r21_hash_privileged "$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI")
    [[ $ph =~ ^[0-9A-Fa-f]{64}$ && $ph == "$fh" ]] || { fail 'Finalized Limine primary/fallback bytes are not identical'; return 1; }

    grub_ids=$(r28_current_native_grub_ids_csv)
    [[ -z $grub_ids ]] || { fail "Native GRUB2 firmware aliases still exist: Boot${grub_ids//,/ Boot}"; return 1; }
    (sudo -n test ! -e "$ESP_MOUNT/EFI/OPENSUSE" 2>/dev/null || [[ ! -e $ESP_MOUNT/EFI/OPENSUSE ]]) || { fail 'EFI/OPENSUSE already exists; refusing reconstructed-target staging'; return 1; }
    [[ ! -e /boot/grub2 ]] || { fail '/boot/grub2 already exists; refusing reconstructed-target staging'; return 1; }
    [[ ! -e /etc/default/grub ]] || { fail '/etc/default/grub already exists; refusing reconstructed-target staging'; return 1; }

    local p
    for p in grub2-mkconfig grub2-script-check grub2-install grub2-probe grub2-mkrelpath shim-install efibootmgr rpm iconv; do
        have "$p" || { fail "$p is required for native openSUSE GRUB2 reconstruction"; return 1; }
    done
    rpm -q grub2-common grub2-x86_64-efi shim >/dev/null 2>&1 || { fail 'Installed openSUSE GRUB2/shim RPM set is incomplete'; return 1; }
    shim-install --help 2>&1 | grep -q -- '--no-nvram' || { fail 'Installed shim-install lacks --no-nvram'; return 1; }
    shim-install --help 2>&1 | grep -q -- '--efi-directory' || { fail 'Installed shim-install lacks --efi-directory'; return 1; }
    shim-install --help 2>&1 | grep -q -- '--config-file' || { fail 'Installed shim-install lacks --config-file'; return 1; }
    efibootmgr --help 2>&1 | grep -q -- '--create-only' || { fail 'Installed efibootmgr lacks --create-only'; return 1; }
    [[ -f $R28_THEME_SOURCE/theme.txt ]] || { fail "Packaged native openSUSE GRUB theme is missing: $R28_THEME_SOURCE/theme.txt"; return 1; }
    grep -Eq '^[[:space:]]*LOADER_TYPE=.*grub2-efi' /etc/sysconfig/bootloader 2>/dev/null || { fail 'openSUSE LOADER_TYPE is not grub2-efi'; return 1; }

    validate_limine_boot_chain current || return 1
    validate_cachyos_limine_theme || return 1
    R28_PRIMARY_ID=${primary^^}
    R28_SOURCE_FALLBACK_ID=${fallback^^}
    ok "r28 preflight passed: finalized Limine Boot$R28_PRIMARY_ID + fallback Boot$R28_SOURCE_FALLBACK_ID; native GRUB2 state is absent and reconstructable"
}

r28_running_grub_default_cmdline() {
    local token out=''
    for token in $(cat /proc/cmdline 2>/dev/null || true); do
        case "$token" in BOOT_IMAGE=*|boot_image=*|initrd=*|root=*) continue ;; esac
        [[ -n $out ]] && out+=' '
        out+=$token
    done
    printf '%s\n' "$out"
}

r28_render_grub_default() {
    local out=$1 cmd
    cmd=$(r28_running_grub_default_cmdline)
    {
        printf '# Managed by openSUSE Bootloader Switcher\n'
        printf 'GRUB_DISTRIBUTOR=\n'
        printf 'GRUB_DEFAULT=saved\n'
        printf 'GRUB_HIDDEN_TIMEOUT=0\n'
        printf 'GRUB_HIDDEN_TIMEOUT_QUIET=true\n'
        printf 'GRUB_TIMEOUT=8\n'
        printf 'GRUB_CMDLINE_LINUX_DEFAULT=%q\n' "$cmd"
        printf 'GRUB_CMDLINE_LINUX=""\n'
        printf 'GRUB_TERMINAL="gfxterm"\n'
        printf 'GRUB_GFXMODE="auto"\n'
        printf 'GRUB_BACKGROUND=\n'
        printf 'GRUB_THEME=/boot/grub2/themes/openSUSE/theme.txt\n'
        printf 'SUSE_BTRFS_SNAPSHOT_BOOTING="true"\n'
        printf 'GRUB_USE_LINUXEFI="true"\n'
        printf 'GRUB_DISABLE_OS_PROBER="false"\n'
        printf 'GRUB_ENABLE_CRYPTODISK="n"\n'
    } >"$out"
}

r28_create_alias_create_only() {
    local label=$1 path=$2 topology disk part before after order_before order_after id
    local -a ids=()
    R28_CREATED_ALIAS_ID=''
    mapfile -t ids < <(r28_ids_for_path "$path")
    ((${#ids[@]} == 0)) || { fail "Refusing create-only: $path already has ${#ids[@]} NVRAM alias(es)"; return 1; }
    topology=$(leap16_esp_disk_part) || { fail 'Could not derive ESP disk/partition for NVRAM creation'; return 1; }
    disk=${topology%%$'\t'*}; part=${topology#*$'\t'}
    order_before=$(leap16_current_boot_order)
    before=$(efibootmgr -v 2>/dev/null | grep -Ei '^Boot[0-9A-Fa-f]{4}\*?[[:space:]]' | LC_ALL=C sort || true)
    sudo efibootmgr --create-only --disk "$disk" --part "$part" --label "$label" --loader "$path" >/dev/null || { fail "Could not create $label -> $path"; return 1; }
    mapfile -t ids < <(r28_ids_for_path "$path")
    ((${#ids[@]} == 1)) || { fail "Create-only did not leave exactly one alias for $path"; return 1; }
    id=${ids[0]^^}
    leap16_boot_entry_is_active "$id" || { fail "New Boot$id is not active"; return 1; }
    leap16_nvram_entry_matches_current_esp "$id" || { fail "New Boot$id is not bound to the current ESP"; return 1; }
    after=$(efibootmgr -v 2>/dev/null | awk -v tid="$id" 'BEGIN{IGNORECASE=1} /^Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/ {x=substr($1,5,4); gsub(/\*/,"",x); if (toupper(x)!=toupper(tid)) print}' | LC_ALL=C sort)
    order_after=$(leap16_current_boot_order)
    [[ $after == "$before" ]] || { fail "A pre-existing Boot#### changed while creating Boot$id"; return 1; }
    [[ ${order_after^^} == ${order_before^^} ]] || { fail 'efibootmgr --create-only unexpectedly changed BootOrder'; return 1; }
    [[ -z $(pending_bootnext_id 2>/dev/null || true) ]] || { fail 'BootNext appeared during create-only'; return 1; }
    R28_CREATED_ALIAS_ID=$id
    ok "Created parked Boot$id $label -> $path without changing BootOrder/BootNext"
}

r28_validate_grub_files() {
    local failures=0 ver line shim direct fh ph
    printf '\nReconstructed native openSUSE GRUB2 filesystem validation:\n'
    shim=$(resolve_efi_path_on_esp_privileged "$R28_GRUB_SHIM_PATH" 2>/dev/null || true)
    direct=$(resolve_efi_path_on_esp_privileged "$R28_GRUB_DIRECT_PATH" 2>/dev/null || true)
    [[ -n $shim ]] && ok "Native shim exists: $shim" || { fail 'Native openSUSE shim is missing'; ((failures++)); }
    [[ -n $direct ]] && ok "Native direct GRUB EFI exists: $direct" || { fail 'Native openSUSE GRUBX64.EFI is missing'; ((failures++)); }
    local bootcsv="$ESP_MOUNT/EFI/OPENSUSE/boot.csv" bootcsv_text=''
    if sudo -n test -f "$bootcsv" 2>/dev/null || [[ -f $bootcsv ]]; then
        if [[ -r $bootcsv ]]; then
            bootcsv_text=$(iconv -f UTF-16 -t UTF-8 "$bootcsv" 2>/dev/null | tr -d '\r\n' || true)
        else
            bootcsv_text=$(sudo -n iconv -f UTF-16 -t UTF-8 "$bootcsv" 2>/dev/null | tr -d '\r\n' || true)
        fi
        [[ ${bootcsv_text,,} == 'shim.efi,opensuse-secureboot' ]] \
            && ok 'Native openSUSE boot.csv restores shim.efi,opensuse-secureboot recovery identity' \
            || { fail "Native openSUSE boot.csv has unexpected content: ${bootcsv_text:-unreadable}"; ((failures++)); }
    else
        fail 'Native openSUSE boot.csv is missing'
        ((failures++))
    fi
    [[ -f /boot/grub2/grub.cfg ]] && ok '/boot/grub2/grub.cfg exists' || { fail '/boot/grub2/grub.cfg is missing'; ((failures++)); }
    [[ -f /etc/default/grub ]] && ok '/etc/default/grub exists' || { fail '/etc/default/grub is missing'; ((failures++)); }
    leap16_grub_cfg_script_check >/dev/null 2>&1 && ok 'grub2-script-check accepts reconstructed grub.cfg' || { fail 'grub2-script-check rejected reconstructed grub.cfg'; ((failures++)); }
    collect_kernels
    for ver in "${KERNEL_VERSIONS[@]}"; do
        line=$(leap16_grub_cfg_grep -F -- "/boot/vmlinuz-$ver" 2>/dev/null | head -n1 || true)
        [[ -n $line ]] && ok "grub.cfg contains kernel $ver" || { fail "grub.cfg has no entry for kernel $ver"; ((failures++)); }
    done
    [[ -n ${ROOT_UUID:-} ]] && leap16_grub_cfg_grep -Fq -- "root=UUID=$ROOT_UUID" >/dev/null 2>&1 \
        && ok 'reconstructed grub.cfg carries the detected root UUID' \
        || { fail 'reconstructed grub.cfg does not carry the detected root UUID'; ((failures++)); }
    validate_cachyos_grub_theme || ((failures++))
    ph=$(r21_hash_privileged "$ESP_MOUNT/EFI/LIMINE/LIMINE_X64.EFI")
    fh=$(r21_hash_privileged "$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI")
    [[ -n $ph && $ph == "$fh" ]] && ok 'Limine-owned EFI/BOOT fallback remains byte-identical to canonical Limine during GRUB staging' \
        || { fail 'Limine-owned EFI/BOOT fallback changed during GRUB staging'; ((failures++)); }
    ((failures == 0))
}

r28_validate_rebuilt_grub_target() {
    local target_id=${1^^} direct_id fallback_id order
    printf '\nReconstructed native openSUSE GRUB2 candidate validation:\n'
    leap16_boot_entry_is_active "$target_id" || { fail "Reconstructed shim Boot$target_id is not active"; return 1; }
    nvram_id_matches_path "$target_id" "$R28_GRUB_SHIM_PATH" || { fail "Boot$target_id does not point to $R28_GRUB_SHIM_PATH"; return 1; }
    leap16_nvram_entry_matches_current_esp "$target_id" || { fail "Boot$target_id is not bound to the current ESP"; return 1; }
    direct_id=$(r28_exact_one_id_for_path "$R28_GRUB_DIRECT_PATH") || { fail 'Expected exactly one parked direct-GRUB NVRAM alias'; return 1; }
    fallback_id=$(r28_exact_one_id_for_path "$LEAP16_R21_FALLBACK_EFI_PATH") || { fail 'Expected exactly one Limine EFI fallback alias during reconstructed-GRUB staging'; return 1; }
    if r28_rebuilt_reverse_pending; then
        [[ ${direct_id^^} == $(r28_meta_value direct_grub_boot_id | tr '[:lower:]' '[:upper:]') ]] || { fail 'Direct-GRUB Boot#### differs from r28 transaction metadata'; return 1; }
        [[ ${fallback_id^^} == $(r28_meta_value source_fallback_boot_id | tr '[:lower:]' '[:upper:]') ]] || { fail 'Source fallback Boot#### differs from r28 transaction metadata'; return 1; }
    fi
    order=$(leap16_current_boot_order)
    leap16_order_has_id "$order" "$direct_id" && { fail "Parked direct-GRUB Boot$direct_id unexpectedly entered BootOrder before finalization"; return 1; }
    r28_validate_grub_files || return 1
    ok "Reconstructed GRUB2 candidate is exact: shim Boot$target_id; parked direct Boot$direct_id; Limine fallback Boot$fallback_id still owns EFI/BOOT"
}

r28_snapshot_rebuilt_grub_target() {
    local target_id=${1^^} ver p h fallback theme_manifest
    [[ -n ${TRANSACTION_SNAPSHOT_DIR:-} && -d $TRANSACTION_SNAPSHOT_DIR ]] || { fail 'Transaction snapshot directory is unavailable'; return 1; }
    TARGET_EFI_RESOLVED=$(resolve_efi_path_on_esp_privileged "$R28_GRUB_SHIM_PATH" 2>/dev/null || true)
    [[ -n $TARGET_EFI_RESOLVED ]] || { fail 'Could not resolve reconstructed openSUSE shim'; return 1; }
    TARGET_EFI_HASH=$(r21_hash_privileged "$TARGET_EFI_RESOLVED")
    [[ $TARGET_EFI_HASH =~ ^[0-9A-Fa-f]{64}$ ]] || { fail 'Could not hash reconstructed openSUSE shim'; return 1; }
    TARGET_GRUB_DIR=/boot/grub2
    TARGET_GRUB_CFG_PATH=/boot/grub2/grub.cfg
    TARGET_GRUB_CFG_HASH=$(r21_hash_privileged "$TARGET_GRUB_CFG_PATH")
    [[ $TARGET_GRUB_CFG_HASH =~ ^[0-9A-Fa-f]{64}$ ]] || { fail 'Could not hash reconstructed grub.cfg'; return 1; }
    GRUB_DEFAULT_CREATED=1
    GRUB_DEFAULT_HASH=$(r21_hash_privileged /etc/default/grub)
    [[ $GRUB_DEFAULT_HASH =~ ^[0-9A-Fa-f]{64}$ ]] || { fail 'Could not hash transaction-created /etc/default/grub'; return 1; }

    GRUB_ARTIFACT_MANIFEST="$TRANSACTION_SNAPSHOT_DIR/grub-artifacts.tsv"
    : >"$GRUB_ARTIFACT_MANIFEST" || return 1
    collect_kernels
    for ver in "${KERNEL_VERSIONS[@]}"; do
        for p in "/boot/vmlinuz-$ver" "/boot/initrd-$ver"; do
            h=$(r21_hash_privileged "$p")
            [[ $h =~ ^[0-9A-Fa-f]{64}$ ]] || { fail "Could not hash source-shared GRUB boot artifact: $p"; return 1; }
            printf 'shared\t%s\t%s\n' "$h" "$p" >>"$GRUB_ARTIFACT_MANIFEST" || return 1
        done
    done
    [[ -s $GRUB_ARTIFACT_MANIFEST ]] || return 1
    GRUB_DIR_MANIFEST="$TRANSACTION_SNAPSHOT_DIR/grub-dir.tsv"
    write_privileged_tree_manifest "$TARGET_GRUB_DIR" "$GRUB_DIR_MANIFEST" || { fail 'Could not snapshot reconstructed /boot/grub2 tree'; return 1; }
    TARGET_GRUB_EFI_DIR=$(dirname -- "$TARGET_EFI_RESOLVED")
    GRUB_EFI_DIR_MANIFEST="$TRANSACTION_SNAPSHOT_DIR/grub-efi-dir.tsv"
    write_privileged_tree_manifest "$TARGET_GRUB_EFI_DIR" "$GRUB_EFI_DIR_MANIFEST" || { fail 'Could not snapshot reconstructed EFI/OPENSUSE tree'; return 1; }
    theme_manifest="$TRANSACTION_SNAPSHOT_DIR/grub-theme-dir.tsv"
    write_privileged_tree_manifest "$R21_GRUB_THEME_DIR" "$theme_manifest" || { fail 'Could not snapshot reconstructed openSUSE GRUB theme'; return 1; }
    printf 'required\n' >"$TRANSACTION_SNAPSHOT_DIR/grub-theme-required" || return 1
    chmod 600 -- "$GRUB_ARTIFACT_MANIFEST" "$GRUB_DIR_MANIFEST" "$GRUB_EFI_DIR_MANIFEST" "$theme_manifest" "$TRANSACTION_SNAPSHOT_DIR/grub-theme-required" 2>/dev/null || true

    fallback="$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"
    POST_STAGE_FALLBACK_HASH=$(r21_hash_privileged "$fallback")
    [[ $POST_STAGE_FALLBACK_HASH == "$OLD_FALLBACK_HASH" ]] || { fail 'Limine fallback changed before reconstructed GRUB candidate commit'; return 1; }
    ok "Recorded exact transaction-created native GRUB2 ownership for Boot$target_id"
}

# r15's path validator is openSUSE-aware but marker=0-only.  Admit the same
# native paths/manifests with marker=1 for r28's transaction-created target.
eval "$(declare -f validate_pending_owned_paths | sed '1s/validate_pending_owned_paths/validate_pending_owned_paths_pre_r28/')"
validate_pending_owned_paths() {
    if ! r28_rebuilt_reverse_pending; then
        validate_pending_owned_paths_pre_r28 "$@"
        return $?
    fi
    local machine_id expected_target expected_old actual_target actual_old manifest
    machine_id=$(cat /etc/machine-id 2>/dev/null || true)
    expected_target=$(safe_realpath "$ESP_MOUNT/$(normalize_efi_path "$R28_GRUB_SHIM_PATH")")
    expected_old=$(safe_realpath "$ESP_MOUNT/$(normalize_efi_path "$PENDING_OLD_BOOT_EFI_PATH")")
    actual_target=$(safe_realpath "$PENDING_TARGET_EFI_RESOLVED")
    actual_old=$(safe_realpath "$PENDING_SOURCE_LIMINE_EFI_RESOLVED")
    [[ ${actual_target,,} == ${expected_target,,} ]] || { PENDING_REASON='pending reconstructed GRUB2 shim path is unexpected'; return 1; }
    [[ ${actual_old,,} == ${expected_old,,} ]] || { PENDING_REASON='pending source Limine EFI path is unexpected'; return 1; }
    pending_hash_is_sha256 "$PENDING_TARGET_EFI_HASH" || { PENDING_REASON='invalid reconstructed shim hash'; return 1; }
    pending_hash_is_sha256 "$PENDING_SOURCE_LIMINE_EFI_HASH" || { PENDING_REASON='invalid source Limine EFI hash'; return 1; }
    pending_validate_snapshot_dir || return 1
    pending_validate_fallback_metadata || return 1
    [[ $(safe_realpath "$PENDING_SOURCE_LIMINE_CONF_PATH") == $(safe_realpath "$ESP_MOUNT/limine.conf") ]] || { PENDING_REASON='pending source limine.conf path is unexpected'; return 1; }
    [[ $(safe_realpath "$PENDING_SOURCE_LIMINE_MANAGED_DIR") == $(safe_realpath "$ESP_MOUNT/$machine_id") ]] || { PENDING_REASON='pending source Limine managed directory is unexpected'; return 1; }
    pending_hash_is_sha256 "$PENDING_SOURCE_LIMINE_CONF_HASH" || { PENDING_REASON='invalid source limine.conf hash'; return 1; }
    pending_hash_is_sha256 "$PENDING_SOURCE_LIMINE_DEFAULT_HASH" || { PENDING_REASON='invalid source /etc/default/limine hash'; return 1; }
    pending_hash_is_sha256 "$PENDING_SOURCE_LIMINE_MANAGED_HASH" || { PENDING_REASON='invalid source Limine managed-tree hash'; return 1; }
    [[ $(safe_realpath "$PENDING_GRUB_CFG_PATH") == $(safe_realpath /boot/grub2/grub.cfg) ]] || { PENDING_REASON='pending reconstructed grub.cfg path is unexpected'; return 1; }
    [[ $(safe_realpath "$PENDING_GRUB_DIR") == $(safe_realpath /boot/grub2) ]] || { PENDING_REASON='pending reconstructed /boot/grub2 path is unexpected'; return 1; }
    [[ $(safe_realpath "$PENDING_GRUB_EFI_DIR" | tr '[:upper:]' '[:lower:]') == $(safe_realpath "$ESP_MOUNT/EFI/OPENSUSE" | tr '[:upper:]' '[:lower:]') ]] || { PENDING_REASON='pending reconstructed EFI/OPENSUSE path is unexpected'; return 1; }
    pending_hash_is_sha256 "$PENDING_GRUB_CFG_HASH" || { PENDING_REASON='invalid reconstructed grub.cfg hash'; return 1; }
    pending_hash_is_sha256 "$PENDING_GRUB_DEFAULT_HASH" || { PENDING_REASON='invalid reconstructed /etc/default/grub hash'; return 1; }
    [[ $PENDING_GRUB_DEFAULT_CREATED == 1 ]] || { PENDING_REASON='reconstructed GRUB default is not marked transaction-created'; return 1; }
    for manifest in "$PENDING_GRUB_ARTIFACT_MANIFEST" "$PENDING_GRUB_DIR_MANIFEST" "$PENDING_GRUB_EFI_DIR_MANIFEST"; do
        [[ -n $manifest ]] || { PENDING_REASON='reconstructed GRUB ownership manifest metadata is missing'; return 1; }
        pending_path_under "$manifest" "$PENDING_TRANSACTION_SNAPSHOT_DIR" || { PENDING_REASON='reconstructed GRUB manifest is outside transaction snapshot'; return 1; }
        [[ -s $manifest ]] || { PENDING_REASON='reconstructed GRUB manifest is missing/empty'; return 1; }
    done
    [[ -s $PENDING_TRANSACTION_SNAPSHOT_DIR/source-limine-efi-dir.tsv ]] || { PENDING_REASON='source Limine EFI retirement manifest is missing'; return 1; }
    [[ -s $PENDING_TRANSACTION_SNAPSHOT_DIR/source-limine-managed-dir.tsv ]] || { PENDING_REASON='source Limine managed retirement manifest is missing'; return 1; }
    r28_validate_meta || return 1
    return 0
}

# Deep candidate validation differs from retained-r15 only in one critical
# invariant: before runtime proof EFI/BOOT must remain Limine, not shim.
eval "$(declare -f validate_pending_target_deep | sed '1s/validate_pending_target_deep/validate_pending_target_deep_pre_r28/')"
validate_pending_target_deep() {
    if ! r28_rebuilt_reverse_pending; then
        validate_pending_target_deep_pre_r28 "$@"
        return $?
    fi
    validate_target_state grub || return 1
    if [[ ${BOOTLOADER:-} == grub && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]]; then
        validate_grub_boot_chain current || return 1
    else
        r28_validate_rebuilt_grub_target "$PENDING_TARGET_BOOT_ID" || return 1
    fi
    verify_pending_candidate_ownership_unchanged || return 1
    validate_cachyos_grub_theme
}

r28_cleanup_alias_path() {
    local path=$1 id
    while IFS= read -r id; do
        [[ $id =~ ^[0-9A-F]{4}$ ]] || continue
        leap16_nvram_entry_matches_current_esp "$id" || continue
        sudo efibootmgr -b "$id" -B >/dev/null 2>&1 || true
    done < <(r28_ids_for_path "$path")
}

r28_cleanup_uncommitted_rebuild() {
    local original_order=$1 phase=${2:-r28-rebuild-stage-failed}
    R28_REBUILD_STAGING=0
    leap16_stage_diagnostic "$phase" >/dev/null 2>&1 || true
    local next
    next=$(pending_bootnext_id 2>/dev/null || true)
    [[ -n $next ]] && sudo efibootmgr -N >/dev/null 2>&1 || true
    r22_disarm_user_resume_bundle >/dev/null 2>&1 || true
    restore_source_fallback_after_grub_install >/dev/null 2>&1 || true
    r28_restore_source_boot_aux >/dev/null 2>&1 || true
    r28_cleanup_alias_path "$R28_GRUB_SHIM_PATH"
    r28_cleanup_alias_path "$R28_GRUB_DIRECT_PATH"
    r15_restore_existing_original_order "$original_order" >/dev/null 2>&1 || true
    sudo rm -rf -- "$ESP_MOUNT/EFI/OPENSUSE" /boot/grub2 >/dev/null 2>&1 || true
    sudo rm -f -- /etc/default/grub >/dev/null 2>&1 || true
    rm -f -- "$PENDING_STATE_FILE" 2>/dev/null || true
    [[ -n ${TRANSACTION_SNAPSHOT_DIR:-} && -d $TRANSACTION_SNAPSHOT_DIR ]] && rm -rf -- "$TRANSACTION_SNAPSHOT_DIR" 2>/dev/null || true
    pending_reset 2>/dev/null || true
}

r28_aux_record_path() {
    local kind=$1 snap=${PENDING_TRANSACTION_SNAPSHOT_DIR:-${TRANSACTION_SNAPSHOT_DIR:-}}
    [[ -n $snap ]] || return 1
    printf '%s/r28-efi-boot-aux-%s.tsv\n' "$snap" "$kind"
}

r28_snapshot_source_boot_aux() {
    local record name path h snap=${TRANSACTION_SNAPSHOT_DIR:-}
    [[ -n $snap && -d $snap ]] || { fail 'Transaction snapshot is unavailable for EFI/BOOT auxiliary ownership'; return 1; }
    record=$(r28_aux_record_path before) || return 1
    : >"$record" || return 1
    for name in fallback.efi MokManager.efi; do
        path="$ESP_MOUNT/EFI/BOOT/$name"
        if sudo -n test -f "$path" 2>/dev/null || [[ -f $path ]]; then
            h=$(r21_hash_privileged "$path")
            [[ $h =~ ^[0-9A-Fa-f]{64}$ ]] || { fail "Could not hash source EFI/BOOT/$name"; return 1; }
            if [[ -r $path ]]; then cat -- "$path" >"$snap/r28-$name.before"; else sudo -n cat -- "$path" >"$snap/r28-$name.before"; fi || return 1
            [[ $(sha256sum -- "$snap/r28-$name.before" | awk '{print $1}') == "$h" ]] || { fail "Internal snapshot mismatch for EFI/BOOT/$name"; return 1; }
            printf '%s\t1\t%s\n' "$name" "$h" >>"$record" || return 1
        else
            printf '%s\t0\t-\n' "$name" >>"$record" || return 1
        fi
    done
    chmod 600 -- "$record" "$snap"/r28-*.before 2>/dev/null || true
    ok 'Snapshotted source EFI/BOOT fallback.efi/MokManager.efi ownership before native GRUB reconstruction'
}

r28_capture_generated_boot_aux() {
    local record name path h snap=${TRANSACTION_SNAPSHOT_DIR:-}
    [[ -n $snap && -d $snap ]] || return 1
    record=$(r28_aux_record_path generated) || return 1
    : >"$record" || return 1
    for name in fallback.efi MokManager.efi; do
        path="$ESP_MOUNT/EFI/BOOT/$name"
        (sudo -n test -f "$path" 2>/dev/null || [[ -f $path ]]) || { fail "shim-install did not produce EFI/BOOT/$name"; return 1; }
        h=$(r21_hash_privileged "$path")
        [[ $h =~ ^[0-9A-Fa-f]{64}$ ]] || { fail "Could not hash shim-install generated EFI/BOOT/$name"; return 1; }
        if [[ -r $path ]]; then cat -- "$path" >"$snap/r28-$name.grub"; else sudo -n cat -- "$path" >"$snap/r28-$name.grub"; fi || return 1
        [[ $(sha256sum -- "$snap/r28-$name.grub" | awk '{print $1}') == "$h" ]] || { fail "Generated snapshot mismatch for EFI/BOOT/$name"; return 1; }
        printf '%s\t%s\n' "$name" "$h" >>"$record" || return 1
    done
    chmod 600 -- "$record" "$snap"/r28-*.grub 2>/dev/null || true
    ok 'Captured shim-install generated EFI/BOOT auxiliary payloads for post-proof GRUB ownership transfer'
}

r28_restore_source_boot_aux() {
    local record name existed expected path snap=${PENDING_TRANSACTION_SNAPSHOT_DIR:-${TRANSACTION_SNAPSHOT_DIR:-}}
    [[ -n $snap ]] || return 0
    record="$snap/r28-efi-boot-aux-before.tsv"
    [[ -s $record ]] || return 0
    while IFS=$'\t' read -r name existed expected; do
        [[ $name == fallback.efi || $name == MokManager.efi ]] || return 1
        path="$ESP_MOUNT/EFI/BOOT/$name"
        if [[ $existed == 1 ]]; then
            [[ -f $snap/r28-$name.before ]] || return 1
            sudo install -m 0644 -- "$snap/r28-$name.before" "$path" || return 1
            [[ $(r21_hash_privileged "$path") == "$expected" ]] || return 1
        elif [[ $existed == 0 ]]; then
            sudo rm -f -- "$path" || return 1
        else
            return 1
        fi
    done <"$record"
    return 0
}

r28_install_generated_boot_aux() {
    local record name expected path snap=${PENDING_TRANSACTION_SNAPSHOT_DIR:-}
    [[ -n $snap ]] || return 1
    record="$snap/r28-efi-boot-aux-generated.tsv"
    [[ -s $record ]] || { fail 'Generated EFI/BOOT auxiliary ownership record is missing'; return 1; }
    while IFS=$'\t' read -r name expected; do
        [[ $name == fallback.efi || $name == MokManager.efi ]] || return 1
        [[ $expected =~ ^[0-9A-Fa-f]{64}$ && -f $snap/r28-$name.grub ]] || return 1
        [[ $(sha256sum -- "$snap/r28-$name.grub" | awk '{print $1}') == "$expected" ]] || return 1
        path="$ESP_MOUNT/EFI/BOOT/$name"
        sudo install -m 0644 -- "$snap/r28-$name.grub" "$path" || return 1
        [[ $(r21_hash_privileged "$path") == "$expected" ]] || { fail "Final EFI/BOOT/$name does not match runtime-staged native GRUB payload"; return 1; }
    done <"$record"
    ok 'Transferred shim-install generated fallback.efi/MokManager.efi only after GRUB runtime proof'
}

r28_install_native_grub_files() {
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
    leap16_grub_cfg_script_check >/dev/null 2>&1 || { fail 'Generated openSUSE grub.cfg failed grub2-script-check before EFI installation'; return 1; }

    # shim-install is the native openSUSE UEFI installer.  --no-nvram keeps
    # firmware transaction state under our explicit efibootmgr control.
    sudo shim-install --no-nvram --efi-directory="$ESP_MOUNT" --config-file=/boot/grub2/grub.cfg >/dev/null || {
        fail 'shim-install --no-nvram failed while reconstructing native openSUSE EFI state'
        return 1
    }
    r28_capture_generated_boot_aux || return 1
    restore_source_fallback_after_grub_install || return 1
    r28_restore_source_boot_aux || { fail 'Could not restore source EFI/BOOT auxiliary files after shim-install'; return 1; }
    # Re-run config after shim/grub installation so the snapshot represents the
    # exact final reconstructed /boot/grub2 state.
    sudo grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null || return 1
    restore_source_fallback_after_grub_install || return 1
    r28_restore_source_boot_aux || return 1

    local -a shim_ids=() direct_ids=()
    mapfile -t shim_ids < <(r28_ids_for_path "$R28_GRUB_SHIM_PATH")
    mapfile -t direct_ids < <(r28_ids_for_path "$R28_GRUB_DIRECT_PATH")
    ((${#shim_ids[@]} == 0)) || { fail 'shim-install --no-nvram unexpectedly created one or more shim NVRAM aliases'; return 1; }
    ((${#direct_ids[@]} == 0)) || { fail 'shim-install --no-nvram unexpectedly created one or more direct-GRUB NVRAM aliases'; return 1; }
    r28_validate_grub_files
}

r28_rebuild_plan() {
    printf '\nExact native openSUSE Limine -> GRUB2 reconstruction plan:\n'
    printf '  1. Re-prove finalized primary Limine + byte-identical firmware fallback and require GRUB files/NVRAM to be absent.\n'
    printf '  2. Snapshot exact Limine source ownership and the pre-stage firmware/fallback state.\n'
    printf '  3. Recreate /etc/default/grub, native openSUSE theme, /boot/grub2 and EFI/OPENSUSE using grub2-mkconfig + shim-install --no-nvram.\n'
    printf '  4. If the installer touches EFI/BOOT, restore the proven Limine fallback before any reboot.\n'
    printf '  5. Create native direct-GRUB + shim Boot#### aliases with --create-only; keep direct GRUB parked outside BootOrder.\n'
    printf '  6. Keep Limine primary/fallback first and append only the shim target last; arm BootNext to that exact shim target once.\n'
    printf '  7. Reboot into native GRUB2 and prove exact BootCurrent, kernel/root/cmdline, GRUB files/theme and unchanged Limine recovery.\n'
    printf '  8. Promote runtime-proven shim GRUB2 first. Only then transfer EFI/BOOT from Limine back to byte-identical shim.\n'
    printf '  9. Retire both Limine firmware aliases and ownership-proven EFI/LIMINE/config/splash/managed-kernel state.\n'
    printf ' 10. Put native shim first and direct GRUB second; final deep GRUB2 validation must pass before transaction state is cleared.\n'
}

r28_execute_limine_to_rebuilt_grub() {
    local old_id original_order source_fallback_id direct_id target_id candidate_order
    old_id=${BOOT_CURRENT^^}
    original_order=$(leap16_current_boot_order) || return 1
    source_fallback_id=$R28_SOURCE_FALLBACK_ID

    printf '\nExecuting native openSUSE Limine -> GRUB2 reconstruction transaction...\n'
    snapshot_limine_source_ownership || return 1
    R28_REBUILD_STAGING=1
    leap16_snapshot_firmware_baseline || { r28_cleanup_uncommitted_rebuild "$original_order" firmware-baseline-snapshot-failed; return 1; }
    leap16_snapshot_source_limine_retirement_ownership || { r28_cleanup_uncommitted_rebuild "$original_order" source-ownership-snapshot-failed; return 1; }
    r28_snapshot_source_boot_aux || { r28_cleanup_uncommitted_rebuild "$original_order" source-efi-boot-aux-snapshot-failed; return 1; }

    r28_install_native_grub_files || { r28_cleanup_uncommitted_rebuild "$original_order" native-grub-rebuild-failed; return 1; }
    verify_source_limine_recovery_state "$old_id" || { r28_cleanup_uncommitted_rebuild "$original_order" source-recovery-changed-after-grub-rebuild; return 1; }

    r28_create_alias_create_only "$R28_GRUB_DIRECT_LABEL" "$R28_GRUB_DIRECT_PATH" || { r28_cleanup_uncommitted_rebuild "$original_order" direct-grub-alias-create-failed; return 1; }
    direct_id=$R28_CREATED_ALIAS_ID
    r28_create_alias_create_only "$R28_GRUB_SHIM_LABEL" "$R28_GRUB_SHIM_PATH" || { r28_cleanup_uncommitted_rebuild "$original_order" shim-alias-create-failed; return 1; }
    target_id=$R28_CREATED_ALIAS_ID
    R28_DIRECT_ID=$direct_id R28_TARGET_ID=$target_id

    # Keep the direct alias registered but parked outside BootOrder.  This both
    # mirrors native openSUSE ownership and prevents firmware from needing to
    # synthesize a replacement alias while candidate order remains simple.
    set_source_first_boot_order "$old_id" "$target_id" "$original_order" || { r28_cleanup_uncommitted_rebuild "$original_order" candidate-order-failed; return 1; }
    candidate_order=$(leap16_current_boot_order)
    [[ $candidate_order == "$old_id,$source_fallback_id,$target_id"* ]] || { fail "Unexpected reconstructed candidate BootOrder: $candidate_order"; r28_cleanup_uncommitted_rebuild "$original_order" candidate-order-verify-failed; return 1; }
    ! leap16_order_has_id "$candidate_order" "$direct_id" || { fail 'Direct GRUB alias entered candidate BootOrder unexpectedly'; r28_cleanup_uncommitted_rebuild "$original_order" direct-alias-not-parked; return 1; }
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext appeared during GRUB reconstruction'; r28_cleanup_uncommitted_rebuild "$original_order" candidate-bootnext-appeared; return 1; }

    r28_validate_rebuilt_grub_target "$target_id" || { r28_cleanup_uncommitted_rebuild "$original_order" rebuilt-grub-validation-failed; return 1; }
    r28_snapshot_rebuilt_grub_target "$target_id" || { r28_cleanup_uncommitted_rebuild "$original_order" rebuilt-grub-snapshot-failed; return 1; }
    r28_write_meta "$source_fallback_id" "$direct_id" "$target_id" || { r28_cleanup_uncommitted_rebuild "$original_order" r28-meta-write-failed; return 1; }

    GRUB_DIAGNOSTIC_DIR=''
    if ! write_pending_limine_to_grub "$old_id" "$original_order" "$target_id" candidate-ready; then
        fail 'Could not persist reconstructed Limine -> GRUB2 candidate metadata'
        r28_cleanup_uncommitted_rebuild "$original_order" pending-state-write-failed
        return 1
    fi
    load_pending_state || { r28_cleanup_uncommitted_rebuild "$original_order" pending-state-reload-failed; return 1; }
    R28_REBUILD_STAGING=0
    validate_pending_compatibility || { fail "Fresh reconstructed reverse state is incompatible: $PENDING_REASON"; r28_cleanup_uncommitted_rebuild "$original_order" pending-compatibility-failed; return 1; }
    leap16_validate_pending_firmware_order 'Reconstructed reverse candidate' || { r28_cleanup_uncommitted_rebuild "$original_order" candidate-firmware-order-failed; return 1; }
    verify_pending_source_recovery_unchanged || { r28_cleanup_uncommitted_rebuild "$original_order" candidate-source-proof-failed; return 1; }
    verify_pending_candidate_ownership_unchanged || { r28_cleanup_uncommitted_rebuild "$original_order" candidate-target-ownership-failed; return 1; }
    validate_pending_target_deep || { r28_cleanup_uncommitted_rebuild "$original_order" candidate-target-deep-failed; return 1; }
    leap16_stage_diagnostic candidate-pass
    if [[ -n ${LIMINE_DIAGNOSTIC_DIR:-} ]]; then
        GRUB_DIAGNOSTIC_DIR=$LIMINE_DIAGNOSTIC_DIR
        r21_pending_set_key diagnostic_path "$GRUB_DIAGNOSTIC_DIR" >/dev/null 2>&1 || true
        PENDING_DIAGNOSTIC_PATH=$GRUB_DIAGNOSTIC_DIR
        printf 'Diagnostic snapshot: %s\n' "$GRUB_DIAGNOSTIC_DIR"
    fi
    printf '\nCANDIDATE-READY native openSUSE GRUB2 reconstruction completed.\n'
    printf '  Source:         Limine Boot%s (persistent first)\n' "$old_id"
    printf '  Source fallback: Boot%s -> EFI/BOOT/BOOTX64.EFI (still Limine)\n' "$source_fallback_id"
    printf '  Target shim:    Boot%s -> EFI/OPENSUSE/SHIM.EFI (parked last)\n' "$target_id"
    printf '  Direct GRUB:    Boot%s -> EFI/OPENSUSE/GRUBX64.EFI (registered, outside BootOrder until finalization)\n' "$direct_id"
    printf '  BootOrder:      %s\n' "$(leap16_current_boot_order)"
    printf '  BootNext:       unset\n'
    r15_arm_reverse_automatically
}

# Use the reconstructed path only when the complete r27-style Limine-only
# topology is present.  Retained-GRUB systems continue through the proven r15
# adapter without behavioral changes.
eval "$(declare -f run_live_operation | sed '1s/run_live_operation/run_live_operation_pre_r28/')"
run_live_operation() {
    local target=${1:-} current
    detect_bootloader
    current=$BOOTLOADER
    if [[ $current:$target == limine:grub ]]; then
        # If a native shim target still exists, retain the old adoption path.
        if [[ $(count_nvram_entries_for_target grub) == 1 ]] && path_exists_on_esp_privileged "$R28_GRUB_SHIM_PATH"; then
            run_live_operation_pre_r28 "$@"
            return $?
        fi
        r28_validate_finalized_limine_source || return 1
        r28_rebuild_plan
        printf '\nNo existing GRUB state is being adopted: r28 reconstructs the native openSUSE GRUB2/shim chain from installed packages under transaction ownership.\n'
        if ! confirm_operation "$current" "$target"; then
            printf '\nOperation cancelled. No boot state was modified.\n'
            return 0
        fi
        printf '\nRe-running the complete finalized-Limine reconstruction preflight at the write boundary...\n'
        r28_validate_finalized_limine_source || { printf '\nWrite-boundary revalidation failed. Nothing was modified.\n'; return 1; }
        r28_execute_limine_to_rebuilt_grub
    else
        run_live_operation_pre_r28 "$@"
    fi
}

# Version-neutral reverse reboot text for both retained and reconstructed paths.
r15_prompt_reboot_reverse() {
    local answer detail
    if r28_rebuilt_reverse_pending; then
        detail='If runtime proof passes, native GRUB2 will be promoted, EFI/BOOT will transfer back to shim, and only then will exact Limine source/fallback ownership be retired.'
    else
        detail='If runtime proof passes, native GRUB2 will be promoted and only the exact retained-source Limine state will be retired.'
    fi
    printf '\nThe one-time native GRUB2 test is armed and the root-owned resume service is fully verified.\n'
    printf '%s\n' "$detail"
    read -r -p 'Reboot now? [y/N]: ' answer
    case "$answer" in
        y|Y|yes|YES) printf 'Rebooting now; no firmware-menu selection is required.\n'; sudo systemctl reboot ;;
        *) printf 'Reboot deferred. BootNext and the verified temporary resume service remain armed for the next normal reboot.\n' ;;
    esac
}

r28_transfer_marker_path() {
    [[ -n ${PENDING_TRANSACTION_SNAPSHOT_DIR:-} ]] || return 1
    printf '%s/r28-fallback-transfer-complete\n' "$PENDING_TRANSACTION_SNAPSHOT_DIR"
}

r28_transfer_complete() {
    local p
    p=$(r28_transfer_marker_path 2>/dev/null || true)
    [[ -n $p && -f $p ]] || return 1
    [[ $(cat -- "$p" 2>/dev/null) == "$PENDING_TARGET_EFI_HASH" ]]
}

r28_mark_transfer_complete() {
    local p tmp
    p=$(r28_transfer_marker_path) || return 1
    tmp="$p.tmp.$$"
    printf '%s\n' "$PENDING_TARGET_EFI_HASH" >"$tmp" || return 1
    chmod 600 -- "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$p" || return 1
    r28_transfer_complete
}

r28_restore_pending_source_fallback_bytes() {
    [[ ${PENDING_OLD_FALLBACK_EXISTED:-0} == 1 ]] || return 1
    [[ -f ${PENDING_OLD_FALLBACK_SNAPSHOT:-} ]] || return 1
    [[ $(sha256sum -- "$PENDING_OLD_FALLBACK_SNAPSHOT" 2>/dev/null | awk '{print $1}') == "$PENDING_OLD_FALLBACK_HASH" ]] || return 1
    sudo install -m 0644 -- "$PENDING_OLD_FALLBACK_SNAPSHOT" "$PENDING_OLD_FALLBACK_PATH" || return 1
    [[ $(r21_hash_privileged "$PENDING_OLD_FALLBACK_PATH") == "$PENDING_OLD_FALLBACK_HASH" ]]
}

r28_remove_aliases_for_path() {
    local path=$1 required_id=${2:-} id saw=0
    required_id=${required_id^^}
    while IFS= read -r id; do
        [[ $id =~ ^[0-9A-F]{4}$ ]] || continue
        id=${id^^}
        [[ -n $required_id && $id == "$required_id" ]] && saw=1
        leap16_nvram_entry_matches_current_esp "$id" || { fail "Refusing to remove Boot$id for $path: ESP ownership changed"; return 1; }
    done < <(r28_ids_for_path "$path")
    if [[ -n $required_id && $saw != 1 && -n $(r28_ids_for_path "$path") ]]; then
        fail "Recorded Boot$required_id no longer owns $path while another alias does"
        return 1
    fi
    while IFS= read -r id; do
        [[ $id =~ ^[0-9A-F]{4}$ ]] || continue
        id=${id^^}
        sudo efibootmgr -b "$id" -B >/dev/null || { fail "Could not remove Boot$id -> $path"; return 1; }
        ok "Removed Limine NVRAM alias Boot$id -> $path"
    done < <(r28_ids_for_path "$path")
    [[ -z $(r28_ids_for_path "$path") ]] || { fail "An NVRAM alias remains at $path after removal"; return 1; }
    return 0
}

r28_remove_source_limine_files_after_fallback_transfer() {
    local h efi_dir splash expected
    efi_dir=$(dirname -- "$PENDING_SOURCE_LIMINE_EFI_RESOLVED")
    if sudo -n test -d "$efi_dir" 2>/dev/null || [[ -d $efi_dir ]]; then
        pending_verify_tree_manifest "$efi_dir" "$PENDING_TRANSACTION_SNAPSHOT_DIR/source-limine-efi-dir.tsv" || { fail 'EFI/LIMINE changed at retirement boundary'; return 1; }
        sudo rm -rf -- "$efi_dir" || return 1
        ok 'Removed ownership-proven source EFI/LIMINE namespace'
    else
        ok 'Source EFI/LIMINE namespace is already retired'
    fi

    if sudo -n test -f "$PENDING_SOURCE_LIMINE_CONF_PATH" 2>/dev/null || [[ -f $PENDING_SOURCE_LIMINE_CONF_PATH ]]; then
        h=$(r21_hash_privileged "$PENDING_SOURCE_LIMINE_CONF_PATH")
        [[ $h == "$PENDING_SOURCE_LIMINE_CONF_HASH" ]] || { fail 'limine.conf changed at retirement boundary'; return 1; }
        sudo rm -f -- "$PENDING_SOURCE_LIMINE_CONF_PATH" || return 1
        ok 'Removed ownership-proven source limine.conf'
    else
        ok 'Source limine.conf is already retired'
    fi

    splash="$ESP_MOUNT/limine-splash.png"
    if [[ -s $PENDING_TRANSACTION_SNAPSHOT_DIR/source-limine-splash.sha256 ]]; then
        expected=$(cat "$PENDING_TRANSACTION_SNAPSHOT_DIR/source-limine-splash.sha256")
        if sudo -n test -f "$splash" 2>/dev/null || [[ -f $splash ]]; then
            h=$(r21_hash_privileged "$splash")
            [[ $h == "$expected" ]] || { fail 'Limine splash changed at retirement boundary'; return 1; }
            sudo rm -f -- "$splash" || return 1
            ok 'Removed ownership-proven Limine splash'
        else
            ok 'Limine splash is already retired'
        fi
    fi

    if [[ -f /etc/default/limine ]]; then
        h=$(r21_hash_privileged /etc/default/limine)
        [[ $h == "$PENDING_SOURCE_LIMINE_DEFAULT_HASH" ]] || { fail '/etc/default/limine changed at retirement boundary'; return 1; }
        sudo rm -f -- /etc/default/limine || return 1
        ok 'Removed ownership-proven /etc/default/limine'
    else
        ok 'Source /etc/default/limine is already retired'
    fi

    if sudo -n test -d "$PENDING_SOURCE_LIMINE_MANAGED_DIR" 2>/dev/null || [[ -d $PENDING_SOURCE_LIMINE_MANAGED_DIR ]]; then
        pending_verify_tree_manifest "$PENDING_SOURCE_LIMINE_MANAGED_DIR" "$PENDING_TRANSACTION_SNAPSHOT_DIR/source-limine-managed-dir.tsv" || { fail 'Limine managed tree changed at retirement boundary'; return 1; }
        sudo rm -rf -- "$PENDING_SOURCE_LIMINE_MANAGED_DIR" || return 1
        ok 'Removed ownership-proven Limine managed kernel directory'
    else
        ok 'Source Limine managed kernel directory is already retired'
    fi
}

r28_final_grub_order() {
    local target=${PENDING_TARGET_BOOT_ID^^} direct=$1 source=${PENDING_OLD_BOOT_ID^^} fallback=$2 order id joined seen
    direct=${direct^^}; fallback=${fallback^^}
    local -a current=() out=("$target" "$direct")
    order=$(leap16_current_boot_order) || return 1
    IFS=',' read -ra current <<<"$order"
    for id in "${current[@]}"; do
        id=${id^^}
        [[ -n $id && $id != "$target" && $id != "$direct" && $id != "$source" && $id != "$fallback" ]] || continue
        boot_id_exists "$id" || continue
        seen=0; local x
        for x in "${out[@]}"; do [[ $x == "$id" ]] && { seen=1; break; }; done
        ((seen)) || out+=("$id")
    done
    joined=$(IFS=,; printf '%s' "${out[*]}")
    sudo efibootmgr -o "$joined" >/dev/null || return 1
    order=$(leap16_current_boot_order)
    [[ $order == "$target,$direct"* ]] || { fail "Final GRUB BootOrder does not begin shim/direct ($order)"; return 1; }
    printf '%s\n' "$order"
}

r28_retire_limine_after_grub_proof() {
    local source=${PENDING_OLD_BOOT_ID^^} source_fallback direct target=${PENDING_TARGET_BOOT_ID^^} fallback_hash order live_direct transferred=0
    source_fallback=$(r28_meta_value source_fallback_boot_id); source_fallback=${source_fallback^^}
    direct=$(r28_meta_value direct_grub_boot_id); direct=${direct^^}
    [[ $source_fallback =~ ^[0-9A-F]{4}$ && $direct =~ ^[0-9A-F]{4}$ ]] || { fail 'r28 finalization metadata is incomplete'; return 1; }

    if r28_transfer_complete; then
        transferred=1
        [[ $(r21_hash_privileged "$PENDING_OLD_FALLBACK_PATH") == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'Recorded post-proof fallback transfer marker exists but EFI/BOOT is not the proven shim'; return 1; }
        verify_pending_candidate_ownership_unchanged || return 1
        validate_grub_boot_chain current || return 1
        ok 'Recovered previously completed GRUB fallback-transfer checkpoint; continuing idempotent Limine retirement'
    else
        leap16_verify_source_limine_after_promotion || return 1
        verify_pending_candidate_ownership_unchanged || return 1
        validate_grub_boot_chain current || return 1
        live_direct=$(r28_exact_one_id_for_path "$R28_GRUB_DIRECT_PATH") || { fail 'Parked direct-GRUB alias is missing or ambiguous before the fallback-transfer boundary'; return 1; }
        [[ ${live_direct^^} == ${direct^^} ]] || { fail "Parked direct-GRUB identity changed before fallback transfer (expected Boot$direct, got Boot$live_direct)"; return 1; }

        printf '\nTRANSFERRING generic EFI fallback back to runtime-proven native openSUSE shim:\n'
        r21_atomic_replace "$PENDING_TARGET_EFI_RESOLVED" "$PENDING_OLD_FALLBACK_PATH" "$PENDING_TARGET_EFI_HASH" || return 1
        fallback_hash=$(r21_hash_privileged "$PENDING_OLD_FALLBACK_PATH")
        [[ $fallback_hash == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'EFI/BOOT did not become byte-identical to the proven openSUSE shim'; r28_restore_pending_source_fallback_bytes || true; return 1; }
        if ! r28_install_generated_boot_aux; then
            fail 'Could not complete native EFI/BOOT auxiliary transfer; restoring the proven Limine fallback checkpoint'
            r28_restore_pending_source_fallback_bytes || warn 'Could not restore source BOOTX64.EFI after auxiliary-transfer failure'
            r28_restore_source_boot_aux || warn 'Could not restore source EFI/BOOT auxiliary files after transfer failure'
            return 1
        fi
        if ! r28_mark_transfer_complete; then
            fail 'Could not persist the post-proof fallback-transfer checkpoint; restoring Limine EFI/BOOT bytes before aborting'
            r28_restore_pending_source_fallback_bytes || warn 'Could not restore source BOOTX64.EFI after checkpoint-write failure'
            r28_restore_source_boot_aux || warn 'Could not restore source EFI/BOOT auxiliary files after checkpoint-write failure'
            return 1
        fi
        transferred=1
        ok 'EFI/BOOT ownership transfer to runtime-proven native openSUSE shim is transaction-persisted'
    fi

    # The old UEFI OS alias now points to shim. Retire both Limine firmware
    # identities by current ESP/path ownership.  After the persisted transfer
    # checkpoint these operations are deliberately idempotent for manual retry.
    r28_remove_aliases_for_path "$LEAP16_R21_FALLBACK_EFI_PATH" || return 1
    r28_remove_aliases_for_path '\EFI\LIMINE\LIMINE_X64.EFI' || return 1
    r28_remove_source_limine_files_after_fallback_transfer || return 1

    direct=$(r28_exact_one_id_for_path "$R28_GRUB_DIRECT_PATH") || { fail 'Final direct-GRUB alias is missing or ambiguous'; return 1; }
    nvram_id_matches_path "$target" "$R28_GRUB_SHIM_PATH" || { fail 'Proven shim target path changed during Limine retirement'; return 1; }
    leap16_nvram_entry_matches_current_esp "$target" || { fail 'Proven shim target ESP binding changed during Limine retirement'; return 1; }
    order=$(r28_final_grub_order "$direct" "$source_fallback") || return 1

    [[ -z $(r28_ids_for_path '\EFI\LIMINE\LIMINE_X64.EFI') ]] || { fail 'Canonical Limine NVRAM alias remains after retirement'; return 1; }
    [[ -z $(r28_ids_for_path "$LEAP16_R21_FALLBACK_EFI_PATH") ]] || { fail 'Limine UEFI fallback alias remains after retirement'; return 1; }
    (sudo -n test ! -e "$ESP_MOUNT/EFI/LIMINE" 2>/dev/null || [[ ! -e $ESP_MOUNT/EFI/LIMINE ]]) || { fail 'EFI/LIMINE remains after retirement'; return 1; }
    [[ ! -e "$ESP_MOUNT/limine.conf" && ! -e /etc/default/limine && ! -e "$PENDING_SOURCE_LIMINE_MANAGED_DIR" ]] || { fail 'One or more ownership-proven Limine source files remain after retirement'; return 1; }
    [[ $(r21_hash_privileged "$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI") == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'Final generic EFI fallback is not the proven shim'; return 1; }
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext unexpectedly exists after reconstructed GRUB finalization'; return 1; }
    ok "Final native openSUSE firmware topology: shim Boot$target first, direct GRUB Boot$direct second ($order)"
}

# Branch the proven r15 promotion machinery only at the retirement semantics.
# Retained-target transactions keep their original behavior unchanged.
eval "$(declare -f r15_promote_and_finalize_grub | sed '1s/r15_promote_and_finalize_grub/r15_promote_and_finalize_grub_pre_r28/')"
r15_promote_and_finalize_grub() {
    if ! r28_rebuilt_reverse_pending; then
        r15_promote_and_finalize_grub_pre_r28 "$@"
        return $?
    fi
    validate_pending_compatibility || { fail "Pending reconstructed reverse migration is incompatible: $PENDING_REASON"; return 1; }
    [[ $PENDING_PHASE == runtime-validated ]] || { fail 'GRUB2 promotion requires runtime-validated state'; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail 'GRUB2 promotion is allowed only from the exact runtime-proven shim target session'; return 1; }
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext is set; refusing persistent promotion'; return 1; }

    local current_first
    current_first=$(pending_bootorder_first 2>/dev/null || true)
    if [[ ${current_first^^} == ${PENDING_TARGET_BOOT_ID^^} ]]; then
        verify_pending_candidate_ownership_unchanged || return 1
        validate_grub_boot_chain current || return 1
        if ! r28_transfer_complete; then
            leap16_validate_promoted_firmware_order 'Recovered reconstructed GRUB2 promotion' || return 1
            leap16_verify_source_limine_after_promotion || return 1
        else
            ok 'Reconstructed GRUB2 is already persistent first and the post-proof fallback-transfer checkpoint is present'
        fi
        r28_retire_limine_after_grub_proof || return 1
        detect_bootloader
        [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail 'Final GRUB2 identity changed after resumed Limine retirement'; return 1; }
        validate_grub_boot_chain current || return 1
        validate_cachyos_grub_theme || return 1
        validate_target_state grub || return 1
        [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext unexpectedly exists after resumed finalization'; return 1; }
        leap16_stage_diagnostic finalization-pass
        printf '
FINALIZED Limine -> native openSUSE GRUB2 successfully.
'
        printf '  Runtime-proven shim Boot%s is persistent first.
' "$PENDING_TARGET_BOOT_ID"
        printf '  Direct native GRUB2 is persistent second.
'
        printf '  EFI/BOOT/BOOTX64.EFI is byte-identical to the proven shim.
'
        printf '  Primary + fallback Limine aliases and ownership-proven Limine files are retired.
'
        return 0
    fi

    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1
    verify_pending_source_recovery_unchanged || return 1
    leap16_validate_pending_firmware_order 'Pre-promotion reconstructed reverse' || return 1

    local promoted
    promoted=$(r13_promoted_order_from_current) || return 1
    sudo efibootmgr -o "$promoted" >/dev/null || return 1
    if ! leap16_validate_promoted_firmware_order 'Reconstructed GRUB2 promotion'; then
        fail 'Post-promotion firmware gate failed; attempting to restore Limine source first'
        r15_recover_source_first_after_failed_reverse_promotion || warn 'Could not automatically restore source-first order'
        return 1
    fi
    detect_bootloader
    [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail 'BootCurrent identity changed after reconstructed GRUB2 promotion'; return 1; }
    validate_grub_boot_chain current || { r15_recover_source_first_after_failed_reverse_promotion || true; return 1; }
    verify_pending_candidate_ownership_unchanged || { r15_recover_source_first_after_failed_reverse_promotion || true; return 1; }
    leap16_verify_source_limine_after_promotion || { r15_recover_source_first_after_failed_reverse_promotion || true; return 1; }
    leap16_stage_diagnostic promotion-pass

    r28_retire_limine_after_grub_proof || return 1
    detect_bootloader
    [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail 'Final GRUB2 identity changed after Limine retirement'; return 1; }
    validate_grub_boot_chain current || return 1
    validate_cachyos_grub_theme || return 1
    validate_target_state grub || return 1
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext unexpectedly exists after finalization'; return 1; }
    leap16_stage_diagnostic finalization-pass
    printf '\nFINALIZED Limine -> native openSUSE GRUB2 successfully.\n'
    printf '  Runtime-proven shim Boot%s is persistent first.\n' "$PENDING_TARGET_BOOT_ID"
    printf '  Direct native GRUB2 is persistent second.\n'
    printf '  EFI/BOOT/BOOTX64.EFI is byte-identical to the proven shim.\n'
    printf '  Primary + fallback Limine aliases and ownership-proven Limine files are retired.\n'
    return 0
}

r28_rollback_rebuilt_grub_candidate() {
    validate_pending_compatibility || return 1
    r28_rebuilt_reverse_pending || return 1
    detect_bootloader
    [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == ${PENDING_OLD_BOOT_ID^^} ]] || { fail 'Reconstructed-GRUB rollback is allowed only from the recorded Limine source session'; return 1; }
    leap16_require_sudo_session || return 1
    verify_pending_source_recovery_unchanged || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1
    local next answer h direct fallback
    next=$(pending_bootnext_id)
    [[ -z $next || ${next^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail "Unrelated BootNext=Boot$next exists; refusing rollback"; return 1; }
    printf '\nRollback removes only the transaction-reconstructed native GRUB2 state and leaves finalized Limine unchanged.\n'
    read -r -p 'Type ROLLBACK to abandon the reconstructed GRUB2 candidate: ' answer
    [[ $answer == ROLLBACK ]] || { printf 'Rollback cancelled.\n'; return 0; }
    leap16_stage_diagnostic rollback-before-cleanup
    [[ -n $next ]] && sudo efibootmgr -N >/dev/null 2>&1 || true
    r22_disarm_user_resume_bundle || true

    direct=$(r28_meta_value direct_grub_boot_id); fallback=$(r28_meta_value source_fallback_boot_id)
    r28_cleanup_alias_path "$R28_GRUB_SHIM_PATH"
    r28_cleanup_alias_path "$R28_GRUB_DIRECT_PATH"
    r15_restore_existing_original_order "$PENDING_ORIGINAL_BOOT_ORDER" || return 1
    rollback_pending_fallback_state || return 1
    r28_restore_source_boot_aux || { fail 'Could not restore pre-stage EFI/BOOT auxiliary files during rollback'; return 1; }
    pending_verify_tree_manifest "$PENDING_GRUB_EFI_DIR" "$PENDING_GRUB_EFI_DIR_MANIFEST" || return 1
    pending_verify_tree_manifest "$PENDING_GRUB_DIR" "$PENDING_GRUB_DIR_MANIFEST" || return 1
    h=$(r21_hash_privileged /etc/default/grub)
    [[ $h == "$PENDING_GRUB_DEFAULT_HASH" ]] || { fail '/etc/default/grub changed before rollback'; return 1; }
    sudo rm -rf -- "$PENDING_GRUB_EFI_DIR" "$PENDING_GRUB_DIR" || return 1
    sudo rm -f -- /etc/default/grub || return 1
    [[ -z $(r28_ids_for_path "$R28_GRUB_SHIM_PATH") && -z $(r28_ids_for_path "$R28_GRUB_DIRECT_PATH") ]] || { fail 'A reconstructed GRUB NVRAM alias remains after rollback'; return 1; }
    [[ $(r21_hash_privileged "$PENDING_OLD_FALLBACK_PATH") == "$PENDING_OLD_FALLBACK_HASH" ]] || { fail 'Limine fallback differs after rollback'; return 1; }
    rm -f -- "$PENDING_STATE_FILE"
    leap16_stage_diagnostic rollback-pass
    remove_pending_transaction_snapshot || warn 'Could not remove transaction snapshot'
    pending_reset
    ok "ROLLBACK-COMPLETE. Limine primary/fallback remain authoritative; reconstructed GRUB2 state was removed."
}

eval "$(declare -f rollback_pending_candidate | sed '1s/rollback_pending_candidate/rollback_pending_candidate_pre_r28/')"
rollback_pending_candidate() {
    if r28_rebuilt_reverse_pending; then
        r28_rollback_rebuilt_grub_candidate
    else
        rollback_pending_candidate_pre_r28 "$@"
    fi
}

# r15 directly calls its own rollback helper from its manager.  Route that
# symbol too when the pending target is transaction-created.
eval "$(declare -f r15_rollback_reverse_candidate | sed '1s/r15_rollback_reverse_candidate/r15_rollback_reverse_candidate_pre_r28/')"
r15_rollback_reverse_candidate() {
    if r28_rebuilt_reverse_pending; then
        r28_rollback_rebuilt_grub_candidate
    else
        r15_rollback_reverse_candidate_pre_r28 "$@"
    fi
}

# Reconstructed candidate banner/manager.  Retained-r15 and forward r21+ states
# continue through their previous handlers.
eval "$(declare -f pending_banner | sed '1s/pending_banner/pending_banner_pre_r28/')"
pending_banner() {
    if pending_exists && validate_pending_compatibility >/dev/null 2>&1 && r28_rebuilt_reverse_pending; then
        detect_bootloader
        printf 'Pending/staged migration: Limine -> native openSUSE GRUB2  [%s]' "$PENDING_PHASE"
        case "$PENDING_PHASE:$BOOTLOADER" in
            candidate-ready:limine) printf '  [RECONSTRUCTED GRUB2 TARGET PARKED]\n' ;;
            boot-armed:limine) printf '  [GRUB2 BootNext + AUTO-RESUME ARMED]\n' ;;
            boot-armed:grub) printf '  [GRUB2 ACTIVE; AUTO-RESUME SHOULD VALIDATE]\n' ;;
            runtime-validated:grub) printf '  [GRUB2 RUNTIME PROVEN; FINALIZATION ELIGIBLE]\n' ;;
            *) printf '  [CURRENT: %s]\n' "$(bootloader_display_name "$BOOTLOADER")" ;;
        esac
        return 0
    fi
    pending_banner_pre_r28 "$@"
}

eval "$(declare -f manage_pending_migration | sed '1s/manage_pending_migration/manage_pending_migration_pre_r28/')"
manage_pending_migration() {
    pending_exists || { printf '\nNo pending/staged migration exists.\n'; return 0; }
    validate_pending_compatibility || { printf '\nPending migration state is invalid/incompatible: %s\n' "$PENDING_REASON"; return 1; }
    if ! r28_rebuilt_reverse_pending; then
        manage_pending_migration_pre_r28 "$@"
        return $?
    fi
    detect_bootloader
    show_pending_details
    local choice next
    if [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == ${PENDING_OLD_BOOT_ID^^} ]]; then
        case "$PENDING_PHASE" in
            candidate-ready)
                printf '\nLimine source is active; reconstructed native GRUB2 is parked.\n[1] Revalidate source + reconstructed target\n[2] Arm GRUB2 + install automatic resume\n[3] Roll back reconstructed target\n[4] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in 1) verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep ;; 2) r15_arm_reverse_automatically ;; 3) r28_rollback_rebuilt_grub_candidate ;; 4|'') return 0 ;; *) return 1 ;; esac
                ;;
            boot-armed)
                next=$(pending_bootnext_id)
                if [[ ${next^^} == ${PENDING_TARGET_BOOT_ID^^} ]]; then
                    printf '\nOne-time reconstructed GRUB2 BootNext is armed.\n[1] Re-check integrity\n[2] Re-verify automatic resume and reboot prompt\n[3] Cancel BootNext back to candidate-ready\n[4] Roll back reconstructed target\n[5] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in
                        1) verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep ;;
                        2) r15_strict_resume_bundle_ready && r15_prompt_reboot_reverse ;;
                        3) sudo efibootmgr -N >/dev/null && pending_set_phase candidate-ready && r22_disarm_user_resume_bundle ;;
                        4) r28_rollback_rebuilt_grub_candidate ;;
                        5|'') return 0 ;;
                        *) return 1 ;;
                    esac
                elif [[ -z $next ]]; then
                    printf '\nBootNext was consumed/cleared without accepted GRUB2 runtime proof.\n[1] Return to candidate-ready\n[2] Roll back reconstructed target\n[3] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in 1) pending_set_phase candidate-ready; r22_disarm_user_resume_bundle ;; 2) r28_rollback_rebuilt_grub_candidate ;; 3|'') return 0 ;; *) return 1 ;; esac
                else
                    fail "Unrelated BootNext=Boot$next exists"; return 1
                fi
                ;;
            runtime-validated)
                printf '\nGRUB2 runtime proof exists, but Limine is active again.\n[1] Re-arm GRUB2 + automatic resume\n[2] Re-check ownership\n[3] Roll back reconstructed target\n[4] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in 1) pending_set_phase candidate-ready && load_pending_state && r15_arm_reverse_automatically ;; 2) verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged ;; 3) r28_rollback_rebuilt_grub_candidate ;; 4|'') return 0 ;; *) return 1 ;; esac
                ;;
        esac
    elif [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]]; then
        case "$PENDING_PHASE" in
            boot-armed)
                printf '\nThe one-time reconstructed native GRUB2 target is running.\n[1] Run exact runtime validation now\n[2] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in 1) r15_validate_grub_target_runtime ;; 2|'') return 0 ;; *) return 1 ;; esac
                ;;
            runtime-validated)
                printf '\nThis exact reconstructed GRUB2 session has runtime proof.\n[1] Re-run runtime validation\n[2] Promote GRUB2, transfer shim fallback, and retire exact Limine source now\n[3] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in 1) r15_validate_grub_target_runtime ;; 2) r15_manual_finalize_grub ;; 3|'') return 0 ;; *) return 1 ;; esac
                ;;
        esac
    else
        fail 'Current bootloader is neither the exact recorded Limine source nor reconstructed GRUB2 target'
        return 1
    fi
}

# Root automatic resume: version-neutral text and success detail.  The actual
# proof/finalization calls are the same audited r15 machinery, with r28's
# promotion override selected by marker=1.
r15_resume_reverse_root() {
    r22_root_bundle_preflight || return 1
    local bundle=$R22_RESUME_BUNDLE conf="$R22_RESUME_BUNDLE/resume.conf" detail mode='retained'
    mkdir -p -- "$bundle/diagnostics" || return 1
    LEAP16_DIAGNOSTIC_ROOT="$bundle/diagnostics"; LEAP16_AUTO_RESUME=1
    export LEAP16_DIAGNOSTIC_ROOT LEAP16_AUTO_RESUME
    exec > >(tee -a "$bundle/automatic-resume.log") 2>&1
    printf 'openSUSE Bootloader Switcher automatic Limine -> GRUB2 resume\nBundle: %s\n' "$bundle"
    load_pending_state || { r22_write_user_result "$conf" failed "Invalid root-owned reverse pending state: $PENDING_REASON" || true; r22_remove_resume_service_files; return 1; }
    validate_pending_compatibility || { r22_write_user_result "$conf" failed "Reverse resume transaction is incompatible: $PENDING_REASON" || true; r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true; r22_remove_resume_service_files; return 1; }
    r28_rebuilt_reverse_pending && mode='reconstructed'
    detect_bootloader
    if [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == ${PENDING_OLD_BOOT_ID^^} ]]; then
        printf 'Automatic reverse resume: firmware returned to Limine source; no target proof/finalization allowed.\n'
        r22_resume_source_fallback "$conf" || return 1
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" safe-fallback || true
        return 0
    fi
    [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || {
        leap16_capture_diagnostics auto-resume-unexpected-bootcurrent >/dev/null 2>&1 || true
        r22_write_user_result "$conf" failed 'Reverse automatic resume saw an unexpected BootCurrent; no promotion/retirement occurred.' || true
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
        r22_remove_resume_service_files
        return 1
    }
    case "$PENDING_PHASE" in
        boot-armed)
            r15_validate_grub_target_runtime || {
                r22_write_user_result "$conf" failed 'Native GRUB2 booted but reverse automatic runtime proof failed; no persistent promotion/retirement occurred.' || true
                leap16_capture_diagnostics auto-resume-runtime-failed >/dev/null 2>&1 || true
                r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
                r22_remove_resume_service_files
                return 1
            }
            PENDING_PHASE=runtime-validated
            r22_sync_user_phase_from_root "$conf" runtime-validated || true
            ;;
        runtime-validated) printf 'Automatic reverse resume: runtime proof already persisted; continuing to finalization.\n' ;;
        *) r22_write_user_result "$conf" failed "Unexpected reverse automatic-resume phase: $PENDING_PHASE" || true; r22_remove_resume_service_files; return 1 ;;
    esac
    if ! r15_promote_and_finalize_grub; then
        r22_write_user_result "$conf" failed 'GRUB2 runtime proof passed, but safe reverse promotion/finalization failed. Ownership gates prevented unproven source cleanup.' || true
        leap16_capture_diagnostics auto-resume-finalization-failed >/dev/null 2>&1 || true
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
        r22_remove_resume_service_files
        return 1
    fi
    leap16_capture_diagnostics auto-resume-pass >/dev/null 2>&1 || true
    r13_sync_root_diagnostics_to_user "$conf" "$bundle" success || true
    if [[ $mode == reconstructed ]]; then
        detail="Limine -> native openSUSE GRUB2 reconstruction succeeded after exact runtime proof. Shim Boot$PENDING_TARGET_BOOT_ID is first, direct GRUB is second, EFI/BOOT is shim-owned, and exact primary/fallback Limine state was retired."
    else
        detail="Limine -> GRUB2 automated runtime proof and finalization succeeded. Native openSUSE GRUB2 Boot$PENDING_TARGET_BOOT_ID is first; exact source Limine state was retired."
    fi
    remove_pending_transaction_snapshot || true
    rm -f -- "$PENDING_STATE_FILE"
    r22_cleanup_user_shadow_after_success "$conf"
    r22_write_user_result "$conf" success "$detail" || true
    r22_remove_resume_service_files
    rm -rf -- "$bundle" 2>/dev/null || true
    return 0
}
