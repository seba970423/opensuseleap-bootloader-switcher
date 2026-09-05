#!/usr/bin/env bash
# leap16-r51: enable the complete live Limine <-> systemd-boot matrix.
#
# r48-r50 hardware-proved Limine -> systemd-boot and its cleanup/recovery
# checkpoints.  r51 opens the reverse live edge, systemd-boot -> Limine, while
# deliberately leaving the Limine <-> systemd-boot backup/restore execution
# matrix locked until both live directions are hardware-proven.
#
# Reverse transaction contract:
#   1. finalized systemd-boot stays persistent first and owns EFI/BOOT;
#   2. one canonical Limine Boot#### is staged last and receives BootNext;
#   3. after exact canonical Limine runtime proof, Limine is promoted but the
#      exact systemd-boot source remains intact;
#   4. Limine takes EFI/BOOT, one exact fallback Boot#### is created/adopted and
#      receives a second independent BootNext proof;
#   5. only after BootCurrent proves that exact fallback are systemd-boot NVRAM
#      and exact source-owned files retired.
#
# No package removal is mixed into this transaction.  rEFInd writes and the
# new cross-backend backup/restore execution routes remain locked.

LEAP16_R51_META='r51-systemd-to-limine.tsv'
LEAP16_R51_PRECONF='r51-primary-proven-limine.conf'
LEAP16_R51_PRIMARY_TARGET_MANIFEST='r51-target-primary-owned.tsv'
LEAP16_R51_STAGING=0

leap16_r51_pending() {
    [[ ${PENDING_FORMAT:-} == ${R26_PENDING_FORMAT:-5} \
       && ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == systemd-boot:limine ]]
}

leap16_r51_snapshot_dir() {
    local d=${PENDING_TRANSACTION_SNAPSHOT_DIR:-${TRANSACTION_SNAPSHOT_DIR:-}}
    [[ -n $d ]] || return 1
    printf '%s\n' "$d"
}

leap16_r51_meta_path() {
    local d
    d=$(leap16_r51_snapshot_dir) || return 1
    printf '%s/%s\n' "$d" "$LEAP16_R51_META"
}

leap16_r51_preconf_path() {
    local d
    d=$(leap16_r51_snapshot_dir) || return 1
    printf '%s/%s\n' "$d" "$LEAP16_R51_PRECONF"
}

leap16_r51_primary_manifest_path() {
    local d
    d=$(leap16_r51_snapshot_dir) || return 1
    printf '%s/%s\n' "$d" "$LEAP16_R51_PRIMARY_TARGET_MANIFEST"
}

leap16_r51_meta_value() {
    local key=$1 p
    p=$(leap16_r51_meta_path) || return 1
    awk -F'\t' -v k="$key" '$1==k{print $2;exit}' "$p" 2>/dev/null
}

leap16_r51_write_initial_meta() {
    local source=${1^^} primary_conf_hash=$2 p tmp
    [[ $source =~ ^[0-9A-F]{4}$ ]] || return 1
    [[ $primary_conf_hash =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
    p=$(leap16_r51_meta_path) || return 1
    tmp="$p.tmp.$$"
    {
        printf 'format\t1\n'
        printf 'direction\tsystemd-boot:limine\n'
        printf 'source_boot_id\t%s\n' "$source"
        printf 'source_efi_path\t%s\n' "$LEAP16_R32_SDBOOT_EFI"
        printf 'primary_conf_hash\t%s\n' "$primary_conf_hash"
        printf 'fallback_boot_id\t\n'
        printf 'fallback_hash\t\n'
        printf 'transferred_conf_hash\t\n'
        printf 'created\t%s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
    } >"$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 600 -- "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$p"
}

leap16_r51_write_fallback_meta() {
    local fallback=${1^^} fallback_hash=$2 transferred_hash=$3 source primary p tmp
    [[ $fallback =~ ^[0-9A-F]{4}$ ]] || return 1
    [[ $fallback_hash =~ ^[0-9A-Fa-f]{64}$ && $transferred_hash =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
    source=$(leap16_r51_meta_value source_boot_id); source=${source^^}
    primary=$(leap16_r51_meta_value primary_conf_hash)
    [[ $source =~ ^[0-9A-F]{4}$ && $primary =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
    p=$(leap16_r51_meta_path) || return 1
    tmp="$p.tmp.$$"
    {
        printf 'format\t1\n'
        printf 'direction\tsystemd-boot:limine\n'
        printf 'source_boot_id\t%s\n' "$source"
        printf 'source_efi_path\t%s\n' "$LEAP16_R32_SDBOOT_EFI"
        printf 'primary_conf_hash\t%s\n' "$primary"
        printf 'fallback_boot_id\t%s\n' "$fallback"
        printf 'fallback_hash\t%s\n' "$fallback_hash"
        printf 'transferred_conf_hash\t%s\n' "$transferred_hash"
        printf 'created\t%s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
    } >"$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 600 -- "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$p"
}

leap16_r51_fallback_id() {
    local id
    id=$(leap16_r51_meta_value fallback_boot_id 2>/dev/null || true); id=${id^^}
    [[ $id =~ ^[0-9A-F]{4}$ ]] || return 1
    printf '%s\n' "$id"
}

leap16_r51_fallback_staged() {
    leap16_r51_fallback_id >/dev/null 2>&1
}

leap16_r51_validate_meta() {
    local p source primary fallback fh ch
    p=$(leap16_r51_meta_path) || { PENDING_REASON='r51 systemd/Limine metadata path is unavailable'; return 1; }
    [[ -s $p ]] || { PENDING_REASON='r51 systemd/Limine metadata is missing'; return 1; }
    [[ -z ${PENDING_TRANSACTION_SNAPSHOT_DIR:-} ]] || pending_path_under "$p" "$PENDING_TRANSACTION_SNAPSHOT_DIR" \
        || { PENDING_REASON='r51 metadata escaped the transaction snapshot'; return 1; }
    [[ $(leap16_r51_meta_value format) == 1 ]] || { PENDING_REASON='r51 metadata format is unsupported'; return 1; }
    [[ $(leap16_r51_meta_value direction) == systemd-boot:limine ]] || { PENDING_REASON='r51 direction marker is wrong'; return 1; }
    source=$(leap16_r51_meta_value source_boot_id); source=${source^^}
    [[ $source =~ ^[0-9A-F]{4}$ ]] || { PENDING_REASON='r51 source Boot#### is malformed'; return 1; }
    [[ -z ${PENDING_OLD_BOOT_ID:-} || $source == ${PENDING_OLD_BOOT_ID^^} ]] || { PENDING_REASON='r51 source Boot#### disagrees with pending state'; return 1; }
    [[ $(leap16_r51_meta_value source_efi_path) == "$LEAP16_R32_SDBOOT_EFI" ]] || { PENDING_REASON='r51 source EFI path is wrong'; return 1; }
    primary=$(leap16_r51_meta_value primary_conf_hash)
    [[ $primary =~ ^[0-9A-Fa-f]{64}$ ]] || { PENDING_REASON='r51 primary Limine config hash is invalid'; return 1; }
    fallback=$(leap16_r51_meta_value fallback_boot_id); fallback=${fallback^^}
    fh=$(leap16_r51_meta_value fallback_hash); ch=$(leap16_r51_meta_value transferred_conf_hash)
    if [[ -n $fallback || -n $fh || -n $ch ]]; then
        [[ $fallback =~ ^[0-9A-F]{4}$ ]] || { PENDING_REASON='r51 fallback Boot#### is malformed'; return 1; }
        [[ $fh =~ ^[0-9A-Fa-f]{64}$ && $ch =~ ^[0-9A-Fa-f]{64}$ ]] || { PENDING_REASON='r51 fallback transfer hashes are invalid'; return 1; }
        [[ -z ${PENDING_TARGET_EFI_HASH:-} || $fh == "$PENDING_TARGET_EFI_HASH" ]] || { PENDING_REASON='r51 fallback hash is not bound to the Limine primary EFI'; return 1; }
    fi
    return 0
}

# Format-v5 originally admits only hub edges plus r48's forward direct edge.
# Admit the reverse direct edge without weakening any format-v5 identity checks.
eval "$(declare -f load_pending_state | sed '1s/load_pending_state/load_pending_state_pre_leap16_r51/')"
load_pending_state() {
    if load_pending_state_pre_leap16_r51 "$@"; then
        return 0
    fi
    [[ $(r26_state_format 2>/dev/null || true) == "$R26_PENDING_FORMAT" \
       && ${PENDING_REASON:-} == 'unsupported r26 adapter migration direction' \
       && ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == systemd-boot:limine ]] || return 1
    [[ $PENDING_PHASE == candidate-ready || $PENDING_PHASE == boot-armed || $PENDING_PHASE == runtime-validated ]] || { PENDING_REASON='unsupported pending-state phase'; return 1; }
    [[ $PENDING_FORMAT == "$R26_PENDING_FORMAT" ]] || { PENDING_REASON='wrong r26 state format'; return 1; }
    [[ $PENDING_ADAPTER_REVISION == "$R26_ADAPTER_REVISION" ]] || { PENDING_REASON='unsupported adapter-state revision'; return 1; }
    [[ -n $PENDING_MACHINE_ID && -n $PENDING_OLD_BOOT_ID && -n $PENDING_TARGET_BOOT_ID ]] || { PENDING_REASON='missing transaction identity'; return 1; }
    [[ -n $PENDING_SOURCE_CMDLINE ]] || { PENDING_REASON='missing source kernel command line'; return 1; }
    [[ -n $PENDING_SOURCE_MANIFEST && -n $PENDING_TARGET_MANIFEST ]] || { PENDING_REASON='missing adapter ownership manifests'; return 1; }
    PENDING_REASON='valid'
    return 0
}

eval "$(declare -f validate_pending_compatibility | sed '1s/validate_pending_compatibility/validate_pending_compatibility_pre_leap16_r51/')"
validate_pending_compatibility() {
    validate_pending_compatibility_pre_leap16_r51 "$@" || return $?
    leap16_r51_pending || return 0
    leap16_r51_validate_meta || return 1
    [[ -s "$PENDING_TRANSACTION_SNAPSHOT_DIR/$LEAP16_R34_FIRMWARE_BASELINE" ]] \
        || { PENDING_REASON='r51 pre-stage firmware baseline is missing'; return 1; }
    PENDING_REASON='compatible'
    return 0
}

leap16_r51_systemd_source_gate() {
    local ids order fallback_count
    leap16_r34_validate_systemd_boot_chain source || return 1
    grep -Eq '^[[:space:]]*LOADER_TYPE=.*systemd-boot' /etc/sysconfig/bootloader 2>/dev/null \
        || { fail 'openSUSE LOADER_TYPE is not systemd-boot'; return 1; }
    ids=$(leap16_r38_current_systemd_ids | paste -sd, -)
    [[ -n $ids && $ids != *,* && ${ids^^} == ${BOOT_CURRENT^^} ]] \
        || { fail "Expected exactly one canonical systemd-boot NVRAM alias matching BootCurrent; found ${ids:-none}"; return 1; }
    order=$(leap16_current_boot_order)
    [[ ${order%%,*} == ${BOOT_CURRENT^^} ]] || { fail "Persistent BootOrder is not source systemd-boot Boot${BOOT_CURRENT^^} first ($order)"; return 1; }
    leap16_r38_source_fallback_exact || return 1
    fallback_count=$(r21_fallback_ids_now | awk 'NF{n++} END{print n+0}')
    [[ $fallback_count == 0 ]] || { fail "Pre-stage generic-fallback NVRAM alias set is not clean ($fallback_count exact same-ESP alias(es))"; return 1; }
    ok 'Finalized systemd-boot source is canonical, source-first, and owns EFI/BOOT with no generic-fallback NVRAM alias'
}

leap16_r51_limine_namespace_clean() {
    local mid parent child base expected
    local -a expected_limine=()
    [[ $(count_nvram_entries_for_target limine) == 0 ]] || { fail 'Pre-existing Limine NVRAM state is ambiguous'; return 1; }
    for child in "${ESP_MOUNT%/}/EFI/LIMINE" "${ESP_MOUNT%/}/limine.conf" "${ESP_MOUNT%/}/$R23_LIMINE_SPLASH_NAME" /etc/default/limine; do
        if sudo -n test -e "$child" 2>/dev/null || sudo -n test -L "$child" 2>/dev/null || [[ -e $child || -L $child ]]; then
            fail "Limine target namespace already exists: $child"
            return 1
        fi
    done
    mid=$(cat /etc/machine-id 2>/dev/null || true)
    [[ -n $mid ]] || { fail 'Machine ID is unavailable'; return 1; }
    parent="${ESP_MOUNT%/}/$mid"
    (sudo -n test -d "$parent" 2>/dev/null || [[ -d $parent ]]) || { fail "Finalized systemd-boot payload parent is missing: $parent"; return 1; }
    (sudo -n test ! -L "$parent" 2>/dev/null || [[ ! -L $parent ]]) || { fail 'Machine-id payload parent is a symlink'; return 1; }
    while IFS= read -r child; do
        [[ -n $child ]] || continue
        base=${child##*/}
        [[ $base == "$LEAP16_R48_SYSTEMD_CHILD" ]] || { fail "Unexpected/foreign machine-id child blocks Limine staging: $child"; return 1; }
    done < <(sudo -n find "$parent" -mindepth 1 -maxdepth 1 -print 2>/dev/null | LC_ALL=C sort || true)
    [[ -d "$parent/$LEAP16_R48_SYSTEMD_CHILD" ]] || sudo -n test -d "$parent/$LEAP16_R48_SYSTEMD_CHILD" 2>/dev/null \
        || { fail 'Expected systemd-boot managed payload child is missing from the shared machine-id parent'; return 1; }
    mapfile -t expected_limine < <(leap16_r48_expected_limine_child_paths) || return 1
    for expected in "${expected_limine[@]}"; do
        if sudo -n test -e "$expected" 2>/dev/null || [[ -e $expected ]]; then
            fail "Limine kernel child namespace already exists: $expected"
            return 1
        fi
    done
    ok 'Shared machine-id parent contains only the exact systemd-boot source child; Limine child namespaces are clean'
}

leap16_r51_preflight() {
    local target=$1
    [[ ${BOOTLOADER:-} == systemd-boot && $target == limine ]] || return 1
    printf '\n%s systemd-boot -> Limine switch preflight:\n' "${SWITCHER_RELEASE:-leap16-r51}"
    run_validation preflight || { fail 'Base preflight failed; nothing was modified'; return 1; }
    is_leap16 || { fail 'This backend is restricted to openSUSE Leap 16'; return 1; }
    leap16_require_sudo_session || return 1
    bootcurrent_is_generic_fallback && { fail 'Canonical systemd-boot BootCurrent is required; current session came through generic fallback'; return 1; }
    [[ $(normalize_efi_path "${BOOT_EFI_PATH:-}" | tr '[:upper:]' '[:lower:]') == efi/systemd/systemd-bootx64.efi ]] \
        || { fail 'BootCurrent is not canonical systemd-boot'; return 1; }
    pending_exists && { fail 'A bootloader transaction is already pending'; return 1; }
    [[ -z ${BOOT_NEXT:-} ]] || { fail "BootNext is already set to Boot${BOOT_NEXT^^}"; return 1; }
    leap16_r51_systemd_source_gate || return 1
    leap16_r51_limine_namespace_clean || return 1
    for _cmd in efibootmgr lsblk findmnt sha256sum b2sum tar od cmp stat df; do have "$_cmd" || { fail "Required command is missing: $_cmd"; return 1; }; done
    (have curl || have wget || [[ -n ${BOOTLOADER_SWITCHER_LIMINE_ARCHIVE:-} ]]) || { fail 'curl or wget is required unless BOOTLOADER_SWITCHER_LIMINE_ARCHIVE points to the pinned archive'; return 1; }
    efibootmgr --help 2>&1 | grep -q -- '--create-only' || { fail 'Installed efibootmgr does not support --create-only'; return 1; }
    collect_kernels
    ((${#KERNEL_VERSIONS[@]} > 0)) || { fail 'No complete Leap kernel/initrd pairs are available for Limine'; return 1; }
    leap16_verify_esp_capacity || return 1
    ok 'systemd-boot -> Limine preflight passed; systemd-boot remains authoritative through the first canonical Limine proof'
}

leap16_r51_plan() {
    printf '\nExact openSUSE systemd-boot -> Limine two-proof plan:\n'
    printf '  1. Re-prove finalized canonical systemd-boot, byte-identical EFI/BOOT, source-first BootOrder and empty BootNext.\n'
    printf '  2. Require a clean Limine NVRAM/EFI/config/kernel-child target while allowing only the exact systemd-boot child under the shared machine-id parent.\n'
    printf '  3. Snapshot exact systemd-boot-owned BLS/payload/EFI state, EFI/BOOT and the complete pre-stage firmware table.\n'
    printf '  4. Stage the pinned Limine EFI + CachyOS r47 theme + exact Leap kernel/initrd copies without touching EFI/BOOT.\n'
    printf '  5. Create one parked canonical Limine Boot####, keep systemd-boot persistent first, and arm only Limine with BootNext.\n'
    printf '  6. After real canonical Limine userspace arrival, prove BootCurrent/kernel/root/cmdline/target ownership while systemd-boot remains exact.\n'
    printf '  7. Promote proven canonical Limine, redirect its temporary recovery entry directly to canonical systemd-boot, transfer EFI/BOOT to byte-identical Limine, and arm one explicit fallback Boot####.\n'
    printf '  8. Require a second real boot whose BootCurrent is that exact EFI/BOOT fallback.\n'
    printf '  9. Only after the second proof: remove systemd-boot from BootOrder/NVRAM, retire exact systemd-owned files, remove the temporary recovery entry, and leave Limine primary + genuine fallback first/second.\n'
    printf '  If either proof fails, ownership-proven systemd-boot recovery remains available.\n'
}

# During this direct edge the generic Limine fallback menu represents systemd,
# not GRUB.  Recognize that exact temporary topology without changing the
# hardware-proven GRUB -> Limine contract.
eval "$(declare -f leap16_validate_limine_recovery_contract | sed '1s/leap16_validate_limine_recovery_contract/leap16_validate_limine_recovery_contract_pre_leap16_r51/')"
leap16_validate_limine_recovery_contract() {
    local conf=$1 fallback="${ESP_MOUNT%/}/EFI/BOOT/BOOTX64.EFI" primary="${ESP_MOUNT%/}/EFI/LIMINE/LIMINE_X64.EFI" systemd="${ESP_MOUNT%/}/EFI/systemd/systemd-bootx64.efi" fh ph sh
    if [[ ${LEAP16_R51_STAGING:-0} != 1 ]] && ! leap16_r51_pending; then
        leap16_validate_limine_recovery_contract_pre_leap16_r51 "$@"
        return $?
    fi
    LEAP16_LIMINE_RECOVERY_DETAIL=''
    if grep -Fqx '/EFI fallback' "$conf" && grep -Fqx 'path: boot():/EFI/BOOT/BOOTX64.EFI' "$conf"; then
        fh=$(r21_hash_privileged "$fallback"); ph=$(r21_hash_privileged "$primary"); sh=$(r21_hash_privileged "$systemd")
        [[ -n $fh && -n $ph && -n $sh && $fh == "$sh" && $fh != "$ph" ]] || return 1
        LEAP16_LIMINE_RECOVERY_DETAIL='Limine candidate keeps the byte-identical systemd-boot EFI fallback as pre-transfer recovery'
        return 0
    fi
    if grep -Fqx '/openSUSE systemd-boot recovery' "$conf" && grep -Fqx 'path: boot():/EFI/systemd/systemd-bootx64.efi' "$conf"; then
        fh=$(r21_hash_privileged "$fallback"); ph=$(r21_hash_privileged "$primary"); sh=$(r21_hash_privileged "$systemd")
        [[ -n $fh && -n $ph && -n $sh && $fh == "$ph" ]] || return 1
        LEAP16_LIMINE_RECOVERY_DETAIL='Limine owns EFI/BOOT; temporary recovery is redirected directly to canonical systemd-boot'
        return 0
    fi
    if ! grep -Fq '/EFI fallback' "$conf" && ! grep -Fq '/openSUSE systemd-boot recovery' "$conf"; then
        fh=$(r21_hash_privileged "$fallback"); ph=$(r21_hash_privileged "$primary")
        [[ -n $fh && $fh == "$ph" ]] || return 1
        if sudo -n test -e "${ESP_MOUNT%/}/EFI/systemd" 2>/dev/null || [[ -e ${ESP_MOUNT%/}/EFI/systemd ]]; then return 1; fi
        LEAP16_LIMINE_RECOVERY_DETAIL='Finalized Limine has a byte-identical EFI/BOOT fallback and no obsolete systemd-boot recovery entry'
        return 0
    fi
    return 1
}

leap16_r51_patch_pretransfer_comment() {
    local conf="${ESP_MOUNT%/}/limine.conf" tmp
    (sudo -n test -f "$conf" 2>/dev/null || [[ -f $conf ]]) || return 1
    tmp=$(mktemp) || return 1
    if [[ -r $conf ]]; then cat -- "$conf" >"$tmp"; else sudo -n cat -- "$conf" >"$tmp" 2>/dev/null; fi || { rm -f -- "$tmp"; return 1; }
    sed -i 's|^comment: Preserved openSUSE generic fallback / GRUB2 recovery path$|comment: Preserved openSUSE generic fallback / systemd-boot recovery path|' "$tmp" || { rm -f -- "$tmp"; return 1; }
    sudo install -o root -g root -m 0644 -- "$tmp" "$conf" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
}

leap16_r51_stage_limine_target() {
    local source_id=${1^^} original_order=$2 reference=$3 target_id conf_hash
    [[ ${BOOTLOADER:-} == systemd-boot ]] || return 1
    LEAP16_R51_STAGING=1
    leap16_prepare_limine_assets || { LEAP16_R51_STAGING=0; return 1; }
    write_limine_candidate_policy || { LEAP16_R51_STAGING=0; return 1; }
    stage_limine_kernel_entries_from_existing_artifacts || { LEAP16_R51_STAGING=0; return 1; }
    leap16_r51_patch_pretransfer_comment || { LEAP16_R51_STAGING=0; return 1; }
    leap16_install_limine_efi_payload || { LEAP16_R51_STAGING=0; return 1; }
    r26_restore_source_fallback_after_target_stage || { LEAP16_R51_STAGING=0; return 1; }
    validate_limine_boot_chain migration || { LEAP16_R51_STAGING=0; return 1; }

    LEAP16_CREATED_TARGET_ID=''
    leap16_create_limine_nvram_candidate "$original_order" || { LEAP16_R51_STAGING=0; return 1; }
    target_id=${LEAP16_CREATED_TARGET_ID^^}
    [[ $target_id =~ ^[0-9A-F]{4}$ ]] || { LEAP16_R51_STAGING=0; fail 'Limine staging did not publish a valid Boot####'; return 1; }
    [[ $(leap16_current_boot_order) == "${LEAP16_CANDIDATE_BOOT_ORDER^^}" ]] || { LEAP16_R51_STAGING=0; fail 'Limine candidate BootOrder changed after create-only staging'; return 1; }
    [[ ${BOOT_CURRENT^^} == "$source_id" ]] || { LEAP16_R51_STAGING=0; fail 'Source systemd-boot BootCurrent changed during Limine staging'; return 1; }
    r26_restore_source_fallback_after_target_stage || { LEAP16_R51_STAGING=0; return 1; }
    adapter_target_validate limine || { LEAP16_R51_STAGING=0; return 1; }
    r26_record_target_adapter limine || { LEAP16_R51_STAGING=0; return 1; }
    conf_hash=$(r21_hash_privileged "${ESP_MOUNT%/}/limine.conf")
    [[ $conf_hash =~ ^[0-9A-Fa-f]{64}$ ]] || { LEAP16_R51_STAGING=0; fail 'Could not freeze primary Limine config hash'; return 1; }
    leap16_r51_write_initial_meta "$source_id" "$conf_hash" || { LEAP16_R51_STAGING=0; fail 'Could not persist r51 direct-edge ownership metadata'; return 1; }
    LEAP16_R51_STAGING=0
    R26_STAGED_TARGET_ID=$target_id
    ok "Staged canonical Limine target as parked Boot$target_id while systemd-boot remains persistent first"
}

eval "$(declare -f adapter_target_stage | sed '1s/adapter_target_stage/adapter_target_stage_pre_leap16_r51/')"
adapter_target_stage() {
    local target=$1
    if [[ ${BOOTLOADER:-} == systemd-boot && $target == limine ]]; then
        leap16_r51_stage_limine_target "$2" "$3" "$4"
    else
        adapter_target_stage_pre_leap16_r51 "$@"
    fi
}

# Failed staging must never delete the shared machine-id parent: only exact
# Limine children created by this attempt are removed.  The systemd source child
# remains untouched.
eval "$(declare -f r26_remove_uncommitted_target_namespaces | sed '1s/r26_remove_uncommitted_target_namespaces/r26_remove_uncommitted_target_namespaces_pre_leap16_r51/')"
r26_remove_uncommitted_target_namespaces() {
    local target=$1 id path
    if [[ ${BOOTLOADER:-} != systemd-boot || $target != limine ]]; then
        r26_remove_uncommitted_target_namespaces_pre_leap16_r51 "$@"
        return $?
    fi
    while IFS= read -r id; do
        [[ $id =~ ^[0-9A-Fa-f]{4}$ ]] || continue
        leap16_nvram_entry_matches_current_esp "$id" || continue
        sudo efibootmgr -b "${id^^}" -B >/dev/null 2>&1 || return 1
        ok "Removed uncommitted Limine NVRAM entry Boot${id^^}"
    done < <(r21_nvram_ids_for_esp_path "$(target_expected_efi_path limine)")
    for path in /etc/default/limine "${ESP_MOUNT%/}/limine.conf" "${ESP_MOUNT%/}/$R23_LIMINE_SPLASH_NAME" "${ESP_MOUNT%/}/EFI/LIMINE"; do
        if sudo -n test -e "$path" 2>/dev/null || sudo -n test -L "$path" 2>/dev/null || [[ -e $path || -L $path ]]; then
            sudo rm -rf -- "$path" || return 1
            ok "Removed uncommitted Limine target namespace: $path"
        fi
    done
    while IFS= read -r path; do
        [[ -n $path ]] || continue
        if sudo -n test -e "$path" 2>/dev/null || [[ -e $path ]]; then
            sudo rm -rf -- "$path" || return 1
            ok "Removed uncommitted Limine kernel child: $path"
        fi
    done < <(leap16_r48_expected_limine_child_paths)
    local mid
    mid=$(cat /etc/machine-id 2>/dev/null || true)
    [[ -z $mid ]] || sudo rmdir -- "${ESP_MOUNT%/}/$mid" 2>/dev/null || true
    return 0
}

leap16_r51_verify_pretransfer_source() {
    local order first second
    verify_pending_source_recovery_unchanged || return 1
    leap16_r38_source_fallback_exact || return 1
    order=$(leap16_current_boot_order) || return 1
    first=${order%%,*}
    if [[ $PENDING_PHASE == candidate-ready || $PENDING_PHASE == boot-armed ]]; then
        [[ ${first^^} == ${PENDING_OLD_BOOT_ID^^} ]] || { fail "systemd-boot source is not first before primary Limine proof ($order)"; return 1; }
    elif [[ $PENDING_PHASE == runtime-validated ]] && ! leap16_r51_fallback_staged; then
        if [[ ${first^^} == ${PENDING_OLD_BOOT_ID^^} ]]; then
            :
        elif [[ ${first^^} == ${PENDING_TARGET_BOOT_ID^^} ]]; then
            second=${order#*,}; second=${second%%,*}
            [[ ${second^^} == ${PENDING_OLD_BOOT_ID^^} ]] || { fail "Promoted Limine topology does not retain systemd-boot second ($order)"; return 1; }
        else
            fail "Unexpected persistent topology before fallback transfer ($order)"
            return 1
        fi
    fi
    return 0
}

leap16_r51_validate_primary_runtime() {
    local order first diag
    validate_pending_compatibility || { fail "Pending direct transaction is incompatible: $PENDING_REASON"; return 1; }
    leap16_r51_pending || { fail 'r51 primary validator received the wrong transaction direction'; return 1; }
    leap16_r51_fallback_staged && { fail 'Primary validator is not valid after the fallback proof has been staged'; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail "Primary runtime proof requires canonical Limine Boot${PENDING_TARGET_BOOT_ID^^}"; return 1; }
    leap16_require_sudo_session || return 1
    run_validation preflight || return 1
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext was not consumed/cleared by firmware'; return 1; }
    order=$(leap16_current_boot_order); first=${order%%,*}
    if [[ ${first^^} != ${PENDING_OLD_BOOT_ID^^} && ${first^^} != ${PENDING_TARGET_BOOT_ID^^} ]]; then
        fail "Persistent BootOrder drifted before primary proof ($order)"
        return 1
    fi
    if [[ ${first^^} == ${PENDING_TARGET_BOOT_ID^^} ]]; then
        local second=${order#*,}; second=${second%%,*}
        [[ ${second^^} == ${PENDING_OLD_BOOT_ID^^} ]] || { fail "Promoted Limine topology lost systemd-boot recovery ($order)"; return 1; }
    fi
    pending_validate_running_kernel || return 1
    pending_validate_runtime_cmdline_against_source || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1
    leap16_r51_verify_pretransfer_source || return 1
    if [[ $PENDING_PHASE == boot-armed ]]; then
        pending_set_phase runtime-validated || { fail 'Primary runtime checks passed but phase could not be persisted'; return 1; }
        PENDING_PHASE=runtime-validated
    elif [[ $PENDING_PHASE != runtime-validated ]]; then
        fail "Primary runtime validation is not authorized from phase $PENDING_PHASE"
        return 1
    fi
    diag=$(pending_capture_runtime_diagnostics runtime-pass-limine-from-systemd | tail -n1 || true)
    [[ -n $diag ]] && printf 'Runtime diagnostic snapshot: %s\n' "$diag"
    printf '\nPRIMARY-RUNTIME-VALIDATED systemd-boot -> Limine one-shot boot succeeded.\n'
    printf 'systemd-boot remains intact until the genuine Limine EFI fallback earns its second independent runtime proof.\n'
}

eval "$(declare -f validate_pending_target_runtime | sed '1s/validate_pending_target_runtime/validate_pending_target_runtime_pre_leap16_r51/')"
validate_pending_target_runtime() {
    if leap16_r51_pending; then
        leap16_r51_validate_primary_runtime
    else
        validate_pending_target_runtime_pre_leap16_r51 "$@"
    fi
}

leap16_r51_rewrite_recovery_to_direct_systemd() {
    local conf="${PENDING_ESP_MOUNT%/}/limine.conf" pre tmp out current expected found=0 line a b c d new_hash
    pre=$(leap16_r51_preconf_path) || return 1
    expected=$(leap16_r51_meta_value primary_conf_hash)
    current=$(r21_hash_privileged "$conf")
    [[ -n $expected && $current == "$expected" ]] || { fail 'limine.conf changed before systemd-boot fallback ownership transfer'; return 1; }
    if [[ -r $conf ]]; then cat -- "$conf" >"$pre"; else sudo -n cat -- "$conf" >"$pre" 2>/dev/null; fi || return 1
    [[ $(sha256sum -- "$pre" | awk '{print $1}') == "$expected" ]] || { fail 'Could not snapshot primary-proven limine.conf exactly'; return 1; }
    chmod 600 -- "$pre" 2>/dev/null || true
    tmp=$(mktemp) || return 1; out=$(mktemp) || { rm -f -- "$tmp"; return 1; }
    cat -- "$pre" >"$tmp" || { rm -f -- "$tmp" "$out"; return 1; }
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == '/EFI fallback' ]]; then
            IFS= read -r a || { rm -f -- "$tmp" "$out"; return 1; }
            IFS= read -r b || { rm -f -- "$tmp" "$out"; return 1; }
            IFS= read -r c || { rm -f -- "$tmp" "$out"; return 1; }
            IFS= read -r d || { rm -f -- "$tmp" "$out"; return 1; }
            [[ $c == 'protocol: efi' && $d == 'path: boot():/EFI/BOOT/BOOTX64.EFI' ]] || { rm -f -- "$tmp" "$out"; fail 'Generated Limine EFI fallback block changed before transfer'; return 1; }
            {
                printf '/openSUSE systemd-boot recovery\n'
                printf '### Temporary direct recovery path retained until Limine fallback proof completes\n'
                printf 'comment: Native openSUSE systemd-boot recovery path\n'
                printf 'protocol: efi\n'
                printf 'path: boot():/EFI/systemd/systemd-bootx64.efi\n'
            } >>"$out"
            found=$((found + 1))
        else
            printf '%s\n' "$line" >>"$out"
        fi
    done <"$tmp"
    rm -f -- "$tmp"
    [[ $found == 1 ]] || { rm -f -- "$out"; fail "Expected exactly one Limine EFI fallback block, found $found"; return 1; }
    new_hash=$(sha256sum -- "$out" | awk '{print $1}')
    r21_atomic_replace "$out" "$conf" "$new_hash" || { rm -f -- "$out"; return 1; }
    rm -f -- "$out"
    printf '%s\n' "$new_hash"
}

leap16_r51_remove_systemd_recovery_block() {
    local conf="${PENDING_ESP_MOUNT%/}/limine.conf" expected tmp out line a b c d found=0 new_hash
    expected=$(leap16_r51_meta_value transferred_conf_hash)
    [[ -n $expected && $(r21_hash_privileged "$conf") == "$expected" ]] || { fail 'Transferred limine.conf changed before systemd-boot retirement'; return 1; }
    tmp=$(mktemp) || return 1; out=$(mktemp) || { rm -f -- "$tmp"; return 1; }
    if [[ -r $conf ]]; then cat -- "$conf" >"$tmp"; else sudo -n cat -- "$conf" >"$tmp" 2>/dev/null; fi || { rm -f -- "$tmp" "$out"; return 1; }
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == '/openSUSE systemd-boot recovery' ]]; then
            IFS= read -r a || { rm -f -- "$tmp" "$out"; return 1; }
            IFS= read -r b || { rm -f -- "$tmp" "$out"; return 1; }
            IFS= read -r c || { rm -f -- "$tmp" "$out"; return 1; }
            IFS= read -r d || { rm -f -- "$tmp" "$out"; return 1; }
            [[ $c == 'protocol: efi' && $d == 'path: boot():/EFI/systemd/systemd-bootx64.efi' ]] || { rm -f -- "$tmp" "$out"; fail 'Temporary systemd-boot recovery block changed before retirement'; return 1; }
            found=$((found + 1))
        else
            printf '%s\n' "$line" >>"$out"
        fi
    done <"$tmp"
    rm -f -- "$tmp"
    [[ $found == 1 ]] || { rm -f -- "$out"; fail "Expected exactly one temporary systemd-boot recovery block, found $found"; return 1; }
    new_hash=$(sha256sum -- "$out" | awk '{print $1}')
    r21_atomic_replace "$out" "$conf" "$new_hash" || { rm -f -- "$out"; return 1; }
    rm -f -- "$out"
    printf '%s\n' "$new_hash"
}

leap16_r51_refresh_target_manifest() {
    local record=${PENDING_TARGET_MANIFEST:-} tmp path saved
    [[ -n $record ]] || return 1
    pending_path_under "$record" "$PENDING_TRANSACTION_SNAPSHOT_DIR" || return 1
    saved=${TRANSACTION_SNAPSHOT_DIR:-}
    TRANSACTION_SNAPSHOT_DIR=$PENDING_TRANSACTION_SNAPSHOT_DIR
    tmp="$record.tmp.$$"
    : >"$tmp" || { TRANSACTION_SNAPSHOT_DIR=$saved; return 1; }
    while IFS= read -r path; do
        [[ -n $path ]] || continue
        r26_record_owned_path "$tmp" "$path" || { rm -f -- "$tmp"; TRANSACTION_SNAPSHOT_DIR=$saved; return 1; }
    done < <(r26_adapter_paths limine)
    [[ -s $tmp ]] || { rm -f -- "$tmp"; TRANSACTION_SNAPSHOT_DIR=$saved; fail 'Refreshed Limine ownership manifest is empty'; return 1; }
    mv -f -- "$tmp" "$record" || { rm -f -- "$tmp"; TRANSACTION_SNAPSHOT_DIR=$saved; return 1; }
    chmod 600 -- "$record" 2>/dev/null || true
    TRANSACTION_SNAPSHOT_DIR=$saved
}

leap16_r51_verify_systemd_source_after_transfer() {
    local source=${PENDING_OLD_BOOT_ID^^} hash ids
    nvram_id_matches_path "$source" "$PENDING_OLD_BOOT_EFI_PATH" || { fail 'Source systemd-boot NVRAM entry/path changed after fallback transfer'; return 1; }
    leap16_nvram_entry_matches_current_esp "$source" || { fail 'Source systemd-boot NVRAM entry changed ESP binding'; return 1; }
    hash=$(r21_hash_privileged "$PENDING_SOURCE_EFI_RESOLVED")
    [[ -n $hash && $hash == "$PENDING_SOURCE_EFI_HASH" ]] || { fail 'Source systemd-boot EFI executable changed'; return 1; }
    r26_verify_owned_manifest "$PENDING_SOURCE_MANIFEST" || return 1
    ids=$(leap16_r38_current_systemd_ids | paste -sd, -)
    [[ -n $ids && $ids != *,* && ${ids^^} == "$source" ]] || { fail "Canonical systemd-boot source alias set changed (found ${ids:-none})"; return 1; }
    leap16_r34_validate_systemd_boot_chain recovery || return 1
    grep -Eq '^[[:space:]]*LOADER_TYPE=.*systemd-boot' /etc/sysconfig/bootloader 2>/dev/null \
        || { fail 'LOADER_TYPE changed before systemd-boot retirement'; return 1; }
    ok "Canonical systemd-boot Boot$source remains exact passive recovery after EFI/BOOT transfer"
}

leap16_r51_verify_transferred_limine() {
    local fallback hash conf_hash order
    leap16_r51_validate_meta || { fail "$PENDING_REASON"; return 1; }
    fallback=$(leap16_r51_fallback_id) || return 1
    hash=$(r21_hash_privileged "$PENDING_TARGET_EFI_RESOLVED")
    [[ $hash == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'Canonical Limine EFI changed after fallback transfer'; return 1; }
    hash=$(r21_hash_privileged "$PENDING_OLD_FALLBACK_PATH")
    [[ $hash == "$PENDING_TARGET_EFI_HASH" && $hash == $(leap16_r51_meta_value fallback_hash) ]] || { fail 'EFI/BOOT is no longer byte-identical to canonical Limine'; return 1; }
    conf_hash=$(leap16_r51_meta_value transferred_conf_hash)
    [[ $(r21_hash_privileged "${PENDING_ESP_MOUNT%/}/limine.conf") == "$conf_hash" ]] || { fail 'Transferred limine.conf changed'; return 1; }
    boot_id_exists "$fallback" || { fail "Limine fallback Boot$fallback disappeared"; return 1; }
    nvram_id_matches_path "$fallback" "$LEAP16_R21_FALLBACK_EFI_PATH" || { fail "Limine fallback Boot$fallback changed EFI path"; return 1; }
    leap16_nvram_entry_matches_current_esp "$fallback" || { fail "Limine fallback Boot$fallback changed ESP binding"; return 1; }
    verify_pending_candidate_ownership_unchanged || return 1
    validate_target_state limine || return 1
    validate_limine_boot_chain migration || return 1
    leap16_r51_verify_systemd_source_after_transfer || return 1
    order=$(leap16_current_boot_order)
    [[ $order == "${PENDING_TARGET_BOOT_ID^^},$fallback"* ]] || { fail "Limine primary/fallback are not the leading persistent paths ($order)"; return 1; }
    ok 'Canonical Limine + explicit byte-identical fallback + passive systemd-boot recovery remain exact'
}

leap16_r51_restore_pre_fallback_state() {
    local fallback next pre primary_manifest primary_hash source=${PENDING_OLD_BOOT_ID^^} target=${PENDING_TARGET_BOOT_ID^^}
    fallback=$(leap16_r51_fallback_id 2>/dev/null || true)
    next=$(pending_bootnext_id 2>/dev/null || true)
    if [[ -n $fallback && ${next^^} == "$fallback" ]]; then sudo efibootmgr -N >/dev/null 2>&1 || true; fi
    r21_remove_staging_fallback_aliases || return 1
    [[ ${PENDING_OLD_FALLBACK_EXISTED:-0} == 1 && -f ${PENDING_OLD_FALLBACK_SNAPSHOT:-/nonexistent} ]] || { fail 'Original systemd-boot EFI fallback snapshot is unavailable'; return 1; }
    r21_atomic_replace "$PENDING_OLD_FALLBACK_SNAPSHOT" "$PENDING_OLD_FALLBACK_PATH" "$PENDING_OLD_FALLBACK_HASH" || return 1
    pre=$(leap16_r51_preconf_path) || return 1
    primary_hash=$(leap16_r51_meta_value primary_conf_hash)
    [[ -f $pre && $primary_hash =~ ^[0-9A-Fa-f]{64}$ ]] || { fail 'Primary Limine config rollback snapshot is unavailable'; return 1; }
    r21_atomic_replace "$pre" "${PENDING_ESP_MOUNT%/}/limine.conf" "$primary_hash" || return 1
    primary_manifest=$(leap16_r51_primary_manifest_path) || return 1
    if [[ -s $primary_manifest ]]; then
        cp -f -- "$primary_manifest" "$PENDING_TARGET_MANIFEST" || return 1
        chmod 600 -- "$PENDING_TARGET_MANIFEST" 2>/dev/null || true
    else
        leap16_r51_refresh_target_manifest || return 1
    fi
    r21_order_primary_then_source_recovery || return 1
    leap16_r51_write_initial_meta "$source" "$primary_hash" || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    verify_pending_source_recovery_unchanged || return 1
    [[ $(leap16_current_boot_order | cut -d, -f1,2) == "$target,$source" ]] || { fail 'Could not restore primary-Limine + systemd-boot recovery ordering'; return 1; }
    ok 'Restored safe primary-Limine + canonical systemd-boot recovery topology; the second proof remains unearned'
}

leap16_r51_promote_and_stage_fallback() {
    local source=${PENDING_OLD_BOOT_ID^^} target=${PENDING_TARGET_BOOT_ID^^} order conf_hash fallback_hash fallback_id before next primary_manifest
    validate_pending_compatibility || { fail "Pending transaction is incompatible: $PENDING_REASON"; return 1; }
    leap16_r51_pending || return 1
    [[ $PENDING_PHASE == runtime-validated ]] || { fail 'Fallback staging requires primary Limine runtime proof'; return 1; }
    leap16_r51_fallback_staged && { fail 'The Limine fallback proof is already staged'; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == "$target" ]] || { fail 'Fallback staging must run from the canonical runtime-proven Limine session'; return 1; }
    leap16_r51_validate_primary_runtime || return 1
    order=$(leap16_current_boot_order)
    if [[ ${order%%,*} == "$source" ]]; then
        adapter_target_promote "$target" "$source" || { fail 'Could not promote runtime-proven canonical Limine while retaining systemd-boot recovery'; return 1; }
    fi
    [[ $(leap16_current_boot_order | cut -d, -f1,2) == "$target,$source" ]] || { fail 'Canonical Limine/systemd-boot promoted recovery topology is not exact'; return 1; }
    verify_pending_candidate_ownership_unchanged || return 1
    verify_pending_source_recovery_unchanged || return 1
    [[ $(r21_fallback_ids_now | awk 'NF{n++} END{print n+0}') == 0 ]] || { fail 'A generic-fallback NVRAM alias appeared before fallback transfer; refusing ambiguous ownership'; return 1; }

    primary_manifest=$(leap16_r51_primary_manifest_path) || return 1
    cp -f -- "$PENDING_TARGET_MANIFEST" "$primary_manifest" || return 1
    chmod 600 -- "$primary_manifest" 2>/dev/null || true
    conf_hash=$(leap16_r51_rewrite_recovery_to_direct_systemd) || { fail 'Could not redirect Limine recovery directly to canonical systemd-boot before EFI/BOOT transfer'; return 1; }
    if ! r21_atomic_replace "$PENDING_TARGET_EFI_RESOLVED" "$PENDING_OLD_FALLBACK_PATH" "$PENDING_TARGET_EFI_HASH"; then
        leap16_r51_restore_pre_fallback_state || true
        return 1
    fi
    fallback_hash=$(r21_hash_privileged "$PENDING_OLD_FALLBACK_PATH")
    [[ $fallback_hash == "$PENDING_TARGET_EFI_HASH" ]] || { leap16_r51_restore_pre_fallback_state || true; fail 'Limine fallback hash verification failed after transfer'; return 1; }
    fallback_id=$(r21_create_or_adopt_fallback_alias) || { leap16_r51_restore_pre_fallback_state || true; return 1; }
    fallback_id=${fallback_id^^}
    leap16_r51_refresh_target_manifest || { leap16_r51_restore_pre_fallback_state || true; return 1; }
    leap16_r51_write_fallback_meta "$fallback_id" "$fallback_hash" "$conf_hash" || { leap16_r51_restore_pre_fallback_state || true; return 1; }
    order=$(r21_order_primary_fallback_then_existing "$fallback_id") || { leap16_r51_restore_pre_fallback_state || true; return 1; }
    leap16_r51_verify_transferred_limine || { leap16_r51_restore_pre_fallback_state || true; return 1; }
    before=$(leap16_current_boot_order)
    sudo efibootmgr -n "$fallback_id" >/dev/null || { leap16_r51_restore_pre_fallback_state || true; return 1; }
    next=$(pending_bootnext_id)
    if [[ ${next^^} != "$fallback_id" || $(leap16_current_boot_order) != "$before" ]]; then
        [[ ${next^^} == "$fallback_id" ]] && sudo efibootmgr -N >/dev/null 2>&1 || true
        leap16_r51_restore_pre_fallback_state || true
        fail 'Limine fallback BootNext arming changed persistent BootOrder or failed exact verification'
        return 1
    fi
    pending_capture_runtime_diagnostics fallback-armed-limine-from-systemd >/dev/null 2>&1 || true
    printf '\nPRIMARY PROOF COMPLETE. Genuine Limine EFI fallback is now staged for the second proof.\n'
    printf '  Persistent BootOrder: %s\n' "$order"
    printf '  BootNext:             Boot%s -> %s\n' "$fallback_id" "$LEAP16_R21_FALLBACK_EFI_PATH"
    printf '  systemd-boot Boot%s remains intact behind the two Limine paths until that exact fallback BootCurrent is proven.\n' "$source"
}

leap16_r51_validate_fallback_runtime() {
    local fallback next order actual
    validate_pending_compatibility || { fail "Pending transaction is incompatible: $PENDING_REASON"; return 1; }
    leap16_r51_pending && leap16_r51_fallback_staged || { fail 'No r51 fallback proof is staged'; return 1; }
    fallback=$(leap16_r51_fallback_id) || return 1
    detect_bootloader
    [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == "$fallback" ]] || { fail "Fallback runtime proof requires BootCurrent=Boot$fallback"; return 1; }
    nvram_id_matches_path "$fallback" "$LEAP16_R21_FALLBACK_EFI_PATH" || { fail 'Fallback BootCurrent no longer points to EFI/BOOT/BOOTX64.EFI'; return 1; }
    leap16_nvram_entry_matches_current_esp "$fallback" || { fail 'Fallback BootCurrent is not bound to the transaction ESP'; return 1; }
    run_validation preflight || return 1
    next=$(pending_bootnext_id)
    if [[ -n $next && ${next^^} == "$fallback" ]]; then
        sudo efibootmgr -N >/dev/null || return 1
        ok 'Cleared lingering transaction-owned fallback BootNext after successful arrival'
    elif [[ -n $next ]]; then
        fail "Unrelated BootNext=Boot$next exists during fallback proof"
        return 1
    else
        ok 'Fallback BootNext was consumed/cleared by firmware'
    fi
    pending_validate_running_kernel || return 1
    pending_validate_runtime_cmdline_against_source || return 1
    actual=$(r21_hash_privileged "$PENDING_OLD_FALLBACK_PATH")
    [[ $actual == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'Actually booted fallback bytes no longer match canonical Limine'; return 1; }
    leap16_r51_verify_transferred_limine || return 1
    order=$(leap16_current_boot_order)
    [[ $order == "${PENDING_TARGET_BOOT_ID^^},$fallback"* ]] || { fail "Persistent primary/fallback topology changed before second proof ($order)"; return 1; }
    pending_capture_runtime_diagnostics fallback-runtime-pass-limine-from-systemd >/dev/null 2>&1 || true
    printf '\nFALLBACK-RUNTIME-VALIDATED. Two independent Limine runtime proofs are complete.\n'
}

leap16_r51_extra_fallback_ids() {
    local keep id baseline="$PENDING_TRANSACTION_SNAPSHOT_DIR/$LEAP16_R34_FIRMWARE_BASELINE"
    keep=$(leap16_r51_fallback_id 2>/dev/null || true)
    while IFS= read -r id; do
        id=${id^^}
        [[ $id =~ ^[0-9A-F]{4}$ && $id != "$keep" ]] || continue
        leap16_nvram_entry_matches_current_esp "$id" || continue
        nvram_id_matches_path "$id" "$LEAP16_R21_FALLBACK_EFI_PATH" || continue
        grep -Eq "^Boot${id}\\*?[[:space:]]" "$baseline" 2>/dev/null && { fail "Fallback alias Boot$id existed before staging and is not transaction-owned" >&2; return 1; }
        printf '%s\n' "$id"
    done < <(r21_fallback_ids_now)
}

leap16_r51_final_order_without_systemd() {
    local target=${PENDING_TARGET_BOOT_ID^^} source=${PENDING_OLD_BOOT_ID^^} fallback order id joined owned
    local -a current=() out=() extras=()
    fallback=$(leap16_r51_fallback_id) || return 1
    mapfile -t extras < <(leap16_r51_extra_fallback_ids) || return 1
    out=("$target" "$fallback")
    order=$(leap16_current_boot_order) || return 1
    IFS=',' read -ra current <<<"$order"
    for id in "${current[@]}"; do
        id=${id^^}; [[ -n $id ]] || continue
        [[ $id != "$target" && $id != "$fallback" && $id != "$source" ]] || continue
        owned=0
        local x
        for x in "${extras[@]}"; do [[ $id == "$x" ]] && { owned=1; break; }; done
        ((owned)) && continue
        boot_id_exists "$id" && out+=("$id")
    done
    joined=$(IFS=,; printf '%s' "${out[*]}")
    sudo efibootmgr -o "$joined" >/dev/null || return 1
    order=$(leap16_current_boot_order)
    [[ $order == "$target,$fallback"* ]] || { fail "Final Limine order does not begin primary/fallback ($order)"; return 1; }
    ! leap16_order_has_id "$order" "$source" || { fail "Source systemd-boot Boot$source remains in BootOrder"; return 1; }
    for id in "${extras[@]}"; do
        leap16_order_has_id "$order" "$id" && { fail "Transaction-created fallback alias Boot$id remains in BootOrder"; return 1; }
    done
    printf '%s\n' "$order"
}

leap16_r51_set_final_limine_policy() {
    local file=/etc/sysconfig/bootloader tmp
    [[ -f $file ]] || return 0
    tmp=$(mktemp) || return 1
    awk '
        BEGIN{done=0}
        /^[[:space:]]*LOADER_TYPE=/ {print "LOADER_TYPE=grub2-efi"; done=1; next}
        {print}
        END{if(!done) print "LOADER_TYPE=grub2-efi"}
    ' "$file" >"$tmp" || { rm -f -- "$tmp"; return 1; }
    sudo install -m 0644 -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
    ok 'Returned openSUSE LOADER_TYPE to the same grub2-efi compatibility value used by the hardware-proven finalized Limine baseline'
}

leap16_r51_retire_systemd_after_fallback_proof() {
    local source=${PENDING_OLD_BOOT_ID^^} target=${PENDING_TARGET_BOOT_ID^^} fallback order final_hash id
    local -a extras=()
    leap16_r51_validate_fallback_runtime || return 1
    fallback=$(leap16_r51_fallback_id) || return 1
    mapfile -t extras < <(leap16_r51_extra_fallback_ids) || return 1
    printf '\nRETIRING systemd-boot only after exact canonical + fallback Limine proofs:\n'
    printf '  - keep primary Limine Boot%s first and proven fallback Boot%s second\n' "$target" "$fallback"
    printf '  - remove source systemd-boot Boot%s from BootOrder before deleting its variable\n' "$source"
    printf '  - retire only the exact source systemd-boot ownership manifest\n'
    printf '  - remove the temporary direct systemd-boot recovery entry from limine.conf\n'
    order=$(leap16_r51_final_order_without_systemd) || return 1
    nvram_id_matches_path "$source" "$PENDING_OLD_BOOT_EFI_PATH" || { fail 'Source systemd-boot path changed before NVRAM retirement'; return 1; }
    leap16_nvram_entry_matches_current_esp "$source" || { fail 'Source systemd-boot ESP binding changed before NVRAM retirement'; return 1; }
    for id in "${extras[@]}"; do
        boot_id_exists "$id" || continue
        sudo efibootmgr -b "$id" -B >/dev/null || { fail "Could not delete transaction-created fallback churn Boot$id"; return 1; }
        ok "Deleted transaction-created same-ESP fallback alias Boot$id"
    done
    sudo efibootmgr -b "$source" -B >/dev/null || { fail "Could not delete source systemd-boot Boot$source"; return 1; }
    boot_id_exists "$source" && { fail "Source systemd-boot Boot$source still exists after deletion"; return 1; }
    r26_remove_owned_manifest_paths "$PENDING_SOURCE_MANIFEST" || return 1
    sudo rmdir -- "${PENDING_ESP_MOUNT%/}/loader/entries" 2>/dev/null || true
    sudo rmdir -- "${PENDING_ESP_MOUNT%/}/loader" 2>/dev/null || true
    sudo rmdir -- "${PENDING_ESP_MOUNT%/}/${PENDING_MACHINE_ID}" 2>/dev/null || true
    leap16_r51_set_final_limine_policy || return 1
    final_hash=$(leap16_r51_remove_systemd_recovery_block) || return 1
    leap16_r51_refresh_target_manifest || return 1

    detect_bootloader
    [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == "$fallback" ]] || { fail 'Final Limine fallback identity changed during source retirement'; return 1; }
    [[ $(leap16_current_boot_order) == "$target,$fallback"* ]] || { fail 'Final Limine primary/fallback order changed during source retirement'; return 1; }
    [[ -z $(leap16_r38_current_systemd_ids | awk 'NF') ]] || { fail 'A canonical systemd-boot NVRAM alias remains after retirement'; return 1; }
    [[ -z $(leap16_r51_extra_fallback_ids | awk 'NF') ]] || { fail 'An extra same-ESP generic-fallback alias remains after finalization'; return 1; }
    [[ $(r21_hash_privileged "$PENDING_OLD_FALLBACK_PATH") == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'Final Limine fallback bytes changed during systemd-boot retirement'; return 1; }
    validate_target_state limine || return 1
    validate_limine_boot_chain migration || return 1
    [[ $(r21_hash_privileged "${PENDING_ESP_MOUNT%/}/limine.conf") == "$final_hash" ]] || { fail 'Final Limine config hash changed after systemd-boot retirement'; return 1; }

    pending_capture_runtime_diagnostics finalized-limine-from-systemd >/dev/null 2>&1 || true
    remove_pending_transaction_snapshot || warn 'Could not remove private transaction snapshot after successful finalization'
    rm -f -- "$PENDING_STATE_FILE"
    printf '\nFINALIZED systemd-boot -> Limine successfully.\n'
    printf 'Primary Limine Boot%s is persistent first; genuine Limine fallback Boot%s is second; exact systemd-boot source state is retired.\n' "$target" "$fallback"
}

# This direction intentionally replaces the generic single-proof finalizer with
# the two-proof Limine completion state machine.
eval "$(declare -f r26_finalize_adapter_transaction | sed '1s/r26_finalize_adapter_transaction/r26_finalize_adapter_transaction_pre_leap16_r51/')"
r26_finalize_adapter_transaction() {
    if ! leap16_r51_pending; then
        r26_finalize_adapter_transaction_pre_leap16_r51 "$@"
        return $?
    fi
    if leap16_r51_fallback_staged; then
        leap16_r51_retire_systemd_after_fallback_proof
    else
        leap16_r51_promote_and_stage_fallback
    fi
}

leap16_r51_rollback_candidate() {
    local source=${PENDING_OLD_BOOT_ID^^} target=${PENDING_TARGET_BOOT_ID^^} next order id joined answer
    local -a ids=() out=()
    validate_pending_compatibility || { fail "Pending transaction is incompatible: $PENDING_REASON"; return 1; }
    leap16_r51_pending || return 1
    leap16_r51_fallback_staged && { fail 'Whole-candidate rollback is not offered after fallback ownership transfer; use the fallback-transfer rollback instead'; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == "$source" ]] || { fail 'Whole-candidate rollback must run from the recorded systemd-boot source'; return 1; }
    [[ $PENDING_PHASE == candidate-ready || $PENDING_PHASE == boot-armed ]] || { fail 'Whole-candidate rollback is allowed only before primary Limine runtime proof'; return 1; }
    read -r -p 'Type ROLLBACK to remove this exact unproven Limine candidate: ' answer
    [[ $answer == ROLLBACK ]] || { printf 'Rollback cancelled.\n'; return 0; }
    next=$(pending_bootnext_id 2>/dev/null || true)
    if [[ ${next^^} == "$target" ]]; then sudo efibootmgr -N >/dev/null || return 1; elif [[ -n $next ]]; then fail "Unrelated BootNext=Boot$next exists"; return 1; fi
    verify_pending_candidate_ownership_unchanged || return 1
    verify_pending_source_recovery_unchanged || return 1
    order=$(leap16_current_boot_order); IFS=',' read -ra ids <<<"$order"
    for id in "${ids[@]}"; do id=${id^^}; [[ -n $id && $id != "$target" ]] || continue; boot_id_exists "$id" && out+=("$id"); done
    joined=$(IFS=,; printf '%s' "${out[*]}")
    [[ -n $joined ]] || return 1
    sudo efibootmgr -o "$joined" >/dev/null || return 1
    [[ $(pending_bootorder_first) == "$source" ]] || { fail 'systemd-boot source is not first after candidate removal from BootOrder'; return 1; }
    nvram_id_matches_path "$target" "$PENDING_TARGET_EFI_PATH" || return 1
    sudo efibootmgr -b "$target" -B >/dev/null || return 1
    r26_remove_owned_manifest_paths "$PENDING_TARGET_MANIFEST" || return 1
    r26_restore_fallback_on_rollback || return 1
    verify_pending_source_recovery_unchanged || return 1
    remove_pending_transaction_snapshot || true
    rm -f -- "$PENDING_STATE_FILE"
    ok 'ROLLBACK-COMPLETE. systemd-boot remains authoritative; the unproven Limine candidate is removed.'
}

eval "$(declare -f rollback_pending_candidate | sed '1s/rollback_pending_candidate/rollback_pending_candidate_pre_leap16_r51/')"
rollback_pending_candidate() {
    if leap16_r51_pending; then
        leap16_r51_rollback_candidate
    else
        rollback_pending_candidate_pre_leap16_r51 "$@"
    fi
}

leap16_r51_rearm_primary() {
    local next
    leap16_r51_pending || return 1
    leap16_r51_fallback_staged && { fail 'Primary re-arm is not valid while the fallback proof is staged'; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == ${PENDING_OLD_BOOT_ID^^} ]] || { fail 'Primary re-arm requires the recorded systemd-boot source session'; return 1; }
    leap16_require_sudo_session || return 1
    verify_pending_source_recovery_unchanged || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1
    next=$(pending_bootnext_id)
    [[ -z $next ]] || { fail "BootNext is already set to Boot$next"; return 1; }
    pending_set_phase candidate-ready || return 1
    PENDING_PHASE=candidate-ready
    r23_arm_candidate_automatically || return 1
    r22_prepare_resume_bundle || { r22_rollback_automation_arm; return 1; }
    r23_prompt_reboot
}

leap16_r51_sync_fallback_state_to_user() {
    local conf=$1 user_snapshot uid gid src base
    r22_user_shadow_matches_conf "$conf" || return 1
    user_snapshot=$(r22_conf_value "$conf" user_snapshot_dir)
    uid=$(r22_conf_value "$conf" user_uid); gid=$(r22_conf_value "$conf" user_gid)
    [[ -d $user_snapshot && $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ ]] || return 1
    for src in "$(leap16_r51_meta_path)" "$(leap16_r51_preconf_path)" "$(leap16_r51_primary_manifest_path)" "$PENDING_TARGET_MANIFEST"; do
        [[ -f $src ]] || continue
        base=${src##*/}
        cp -f -- "$src" "$user_snapshot/$base" || return 1
        chown "$uid:$gid" -- "$user_snapshot/$base" 2>/dev/null || true
        chmod 600 -- "$user_snapshot/$base" 2>/dev/null || true
    done
}

leap16_r51_resume_root() {
    r22_root_bundle_preflight || return 1
    local bundle=$R22_RESUME_BUNDLE conf="$R22_RESUME_BUNDLE/resume.conf" detail fallback
    mkdir -p -- "$bundle/diagnostics" || return 1
    LEAP16_DIAGNOSTIC_ROOT="$bundle/diagnostics" LEAP16_AUTO_RESUME=1
    export LEAP16_DIAGNOSTIC_ROOT LEAP16_AUTO_RESUME
    exec > >(tee -a "$bundle/automatic-resume.log") 2>&1
    printf 'openSUSE Bootloader Switcher %s automatic systemd-boot -> Limine resume\nBundle: %s\n' "${SWITCHER_RELEASE:-leap16-r51}" "$bundle"
    load_pending_state || { r22_write_user_result "$conf" failed "Invalid r51 pending state: $PENDING_REASON" || true; r22_remove_resume_service_files; return 1; }
    validate_pending_compatibility || { r22_write_user_result "$conf" failed "Incompatible r51 pending state: $PENDING_REASON" || true; r22_remove_resume_service_files; return 1; }
    detect_bootloader

    if leap16_r51_fallback_staged; then
        fallback=$(leap16_r51_fallback_id)
        if [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == "$fallback" ]]; then
            if ! leap16_r51_retire_systemd_after_fallback_proof; then
                r22_write_user_result "$conf" failed 'Exact Limine fallback arrived, but second-proof finalization failed before safe completion. No unproven source cleanup was attempted beyond already completed ownership-gated steps.' || true
                r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
                r22_remove_resume_service_files
                return 1
            fi
            leap16_capture_diagnostics auto-resume-pass >/dev/null 2>&1 || true
            r13_sync_root_diagnostics_to_user "$conf" "$bundle" success || true
            detail="systemd-boot -> Limine completed with two independent runtime proofs. Primary Limine Boot$PENDING_TARGET_BOOT_ID is first; genuine Limine fallback Boot$fallback is second and byte-identical; exact source systemd-boot NVRAM/BLS/payload/EFI state was retired."
            r22_cleanup_user_shadow_after_success "$conf"
            r22_write_user_result "$conf" success "$detail" || true
            r22_remove_resume_service_files
            rm -rf -- "$bundle" 2>/dev/null || true
            return 0
        fi
        printf 'Automatic resume: the armed Limine fallback did not become the exact BootCurrent; systemd-boot retirement is forbidden.\n' >&2
        if leap16_r51_restore_pre_fallback_state; then
            leap16_r51_sync_fallback_state_to_user "$conf" || true
            r13_sync_root_diagnostics_to_user "$conf" "$bundle" safe-fallback || true
            r22_write_user_result "$conf" safe-fallback 'The second Limine fallback proof was not obtained. Primary Limine remains proven; canonical systemd-boot and its original EFI/BOOT fallback were restored as recovery.' || true
            r22_remove_resume_service_files
            return 0
        fi
        r22_write_user_result "$conf" failed 'The second Limine fallback proof was not obtained and safe fallback-transfer rollback also failed. systemd-boot retirement was not attempted.' || true
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
        r22_remove_resume_service_files
        return 1
    fi

    if [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == ${PENDING_OLD_BOOT_ID^^} ]]; then
        printf 'Automatic resume: firmware returned to the recorded systemd-boot source; no Limine proof/promotion is allowed.\n'
        if r22_resume_source_fallback "$conf"; then
            r13_sync_root_diagnostics_to_user "$conf" "$bundle" safe-fallback || true
            return 0
        fi
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
        return 1
    fi
    [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || {
        r22_write_user_result "$conf" failed 'systemd-boot -> Limine resume saw an unexpected BootCurrent; no source cleanup was attempted.' || true
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
        r22_remove_resume_service_files
        return 1
    }
    case "$PENDING_PHASE" in
        boot-armed)
            leap16_r51_validate_primary_runtime || {
                r22_write_user_result "$conf" failed 'Canonical Limine booted but primary runtime proof failed; systemd-boot remains intact and no fallback transfer occurred.' || true
                r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
                r22_remove_resume_service_files
                return 1
            }
            r22_sync_user_phase_from_root "$conf" runtime-validated || true
            ;;
        runtime-validated) printf 'Primary Limine runtime proof is already persisted; continuing to explicit fallback staging.\n' ;;
        *) r22_write_user_result "$conf" failed "Unexpected r51 automatic-resume phase: $PENDING_PHASE" || true; r22_remove_resume_service_files; return 1 ;;
    esac
    if ! leap16_r51_promote_and_stage_fallback; then
        r22_write_user_result "$conf" failed 'Primary Limine proof passed, but fallback staging failed. systemd-boot retirement was NOT attempted.' || true
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
        r22_remove_resume_service_files
        return 1
    fi
    leap16_r51_sync_fallback_state_to_user "$conf" || warn 'Could not mirror r51 fallback sidecars into the user transaction snapshot; root-owned automatic continuation remains authoritative'
    r13_sync_root_diagnostics_to_user "$conf" "$bundle" fallback-armed || true
    fallback=$(leap16_r51_fallback_id)
    r22_write_user_result "$conf" pending "Primary Limine is proven. Genuine Limine EFI fallback Boot$fallback is installed and armed for one exact BootNext proof; systemd-boot remains intact until that second proof succeeds." || true
    printf '\nr51 phase 1 complete. Rebooting exactly once into explicit Limine fallback Boot%s.\n' "$fallback"
    if ! systemctl reboot; then
        printf 'Automatic reboot request failed. BootNext remains armed; reboot normally to continue the fallback proof.\n' >&2
        return 1
    fi
    return 0
}

eval "$(declare -f r22_resume_transaction_root | sed '1s/r22_resume_transaction_root/r22_resume_transaction_root_pre_leap16_r51/')"
r22_resume_transaction_root() {
    local src='' tgt=''
    if [[ -f ${PENDING_STATE_FILE:-/nonexistent} ]]; then
        src=$(awk -F'\t' '$1=="source"{print $2;exit}' "$PENDING_STATE_FILE" 2>/dev/null || true)
        tgt=$(awk -F'\t' '$1=="target"{print $2;exit}' "$PENDING_STATE_FILE" 2>/dev/null || true)
    fi
    if [[ $src:$tgt == systemd-boot:limine ]]; then
        leap16_r51_resume_root
    else
        r22_resume_transaction_root_pre_leap16_r51 "$@"
    fi
}

leap16_r51_pending_menu() {
    local source=${PENDING_OLD_BOOT_ID^^} target=${PENDING_TARGET_BOOT_ID^^} fallback choice next order first
    detect_bootloader
    show_pending_details
    fallback=$(leap16_r51_fallback_id 2>/dev/null || true)

    if [[ -n $fallback && $BOOTLOADER == limine && ${BOOT_CURRENT^^} == "$fallback" ]]; then
        printf '\nThe exact Limine EFI fallback Boot%s is running. Both independent Limine proofs can now be completed.\n' "$fallback"
        printf '[1] Finish migration and retire exact systemd-boot source state\n[2] Re-check fallback + source recovery (read-only)\n[3] Back\n\n'
        read -r -p 'Select an option: ' choice
        case "$choice" in
            1) leap16_require_sudo_session && leap16_r51_retire_systemd_after_fallback_proof ;;
            2) leap16_require_sudo_session && leap16_r51_validate_fallback_runtime ;;
            3|'') return 0 ;;
            *) return 1 ;;
        esac
        return $?
    fi

    if [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == "$target" ]]; then
        case "$PENDING_PHASE" in
            boot-armed)
                printf '\nCanonical Limine is the one-shot target; systemd-boot is still persistent recovery.\n'
                printf '[1] Validate this primary Limine boot now\n[2] Back\n\n'
                read -r -p 'Select an option: ' choice
                [[ $choice == 1 ]] && leap16_r51_validate_primary_runtime
                return $?
                ;;
            runtime-validated)
                if leap16_r51_fallback_staged; then
                    next=$(pending_bootnext_id)
                    printf '\nPrimary Limine is proven. Genuine Limine fallback Boot%s is staged; systemd-boot remains intact.\n' "$fallback"
                    if [[ ${next^^} == "$fallback" ]]; then
                        printf '[1] Re-check staged fallback + systemd-boot recovery\n[2] Reboot into the armed fallback proof\n[3] Roll back only the fallback transfer\n[4] Back\n\n'
                        read -r -p 'Select an option: ' choice
                        case "$choice" in
                            1) leap16_r51_verify_transferred_limine ;;
                            2) leap16_r51_verify_transferred_limine && r13_prompt_reboot ;;
                            3) leap16_r51_restore_pre_fallback_state ;;
                            4|'') return 0 ;;
                            *) return 1 ;;
                        esac
                    else
                        printf '[1] Re-check staged fallback + systemd-boot recovery\n[2] Roll back only the fallback transfer\n[3] Back\n\n'
                        read -r -p 'Select an option: ' choice
                        case "$choice" in
                            1) leap16_r51_verify_transferred_limine ;;
                            2) leap16_r51_restore_pre_fallback_state ;;
                            3|'') return 0 ;;
                            *) return 1 ;;
                        esac
                    fi
                else
                    order=$(leap16_current_boot_order); first=${order%%,*}
                    printf '\nCanonical Limine has passed its first runtime proof. systemd-boot is still intact.\n'
                    printf '[1] Continue: promote Limine and stage the genuine EFI fallback proof\n[2] Re-check primary Limine + systemd-boot recovery\n[3] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in
                        1) leap16_require_sudo_session && leap16_r51_promote_and_stage_fallback ;;
                        2) leap16_require_sudo_session && leap16_r51_validate_primary_runtime ;;
                        3|'') return 0 ;;
                        *) return 1 ;;
                    esac
                fi
                ;;
            *) fail "Unsupported r51 target-session phase: $PENDING_PHASE"; return 1 ;;
        esac
        return $?
    fi

    if [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == "$source" ]]; then
        case "$PENDING_PHASE" in
            candidate-ready)
                printf '\nsystemd-boot source is active and the Limine candidate is parked.\n'
                printf '[1] Revalidate source + Limine candidate\n[2] Arm one-time primary Limine test + automatic resume\n[3] Roll back this unproven Limine candidate\n[4] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) leap16_require_sudo_session && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep ;;
                    2) leap16_require_sudo_session && r23_arm_candidate_automatically && r22_prepare_resume_bundle && r23_prompt_reboot ;;
                    3) leap16_r51_rollback_candidate ;;
                    4|'') return 0 ;;
                    *) return 1 ;;
                esac
                ;;
            boot-armed)
                next=$(pending_bootnext_id)
                printf '\nPrimary Limine one-shot state: BootNext=%s. systemd-boot remains persistent first.\n' "${next:-none}"
                printf '[1] Re-check source + candidate\n[2] Back\n\n'
                read -r -p 'Select an option: ' choice
                [[ $choice == 1 ]] && leap16_r51_verify_pretransfer_source && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep
                return $?
                ;;
            runtime-validated)
                leap16_r51_fallback_staged && { fail 'Fallback transfer is staged but the systemd-boot source is running; use the automatic recovery result or boot canonical Limine before changing transaction state'; return 1; }
                printf '\nPrimary Limine proof exists, but systemd-boot is active again. Finalization is forbidden from the source session.\n'
                printf '[1] Re-arm canonical Limine for continuation\n[2] Re-check source + target ownership\n[3] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) leap16_r51_rearm_primary ;;
                    2) verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep ;;
                    3|'') return 0 ;;
                    *) return 1 ;;
                esac
                ;;
        esac
        return $?
    fi
    fail "Active session matches neither recorded systemd-boot source Boot$source nor Limine primary/fallback target state"
    return 1
}

eval "$(declare -f manage_pending_migration | sed '1s/manage_pending_migration/manage_pending_migration_pre_leap16_r51/')"
manage_pending_migration() {
    pending_exists || { printf '\nNo pending/staged migration exists.\n'; return 0; }
    validate_pending_compatibility || { printf '\nPending migration state is invalid/incompatible: %s\n' "$PENDING_REASON"; return 1; }
    if leap16_r51_pending; then
        leap16_r51_pending_menu
    else
        manage_pending_migration_pre_leap16_r51 "$@"
    fi
}

# Open the complete live direct matrix.  Backup/restore execution is deliberately
# not expanded here; only the existing backup offer for the current source runs.
eval "$(declare -f operation_supported | sed '1s/operation_supported/operation_supported_pre_leap16_r51/')"
operation_supported() {
    [[ $1:$2 == systemd-boot:limine ]] && return 0
    operation_supported_pre_leap16_r51 "$@"
}

leap16_r51_run_systemd_to_limine_inner() {
    local target=$1 current=$BOOTLOADER rc=0
    leap16_r51_preflight "$target" || return 1
    offer_operation_backup || return 1
    leap16_r51_plan
    confirm_operation "$current" "$target" || { printf '\nOperation cancelled. No boot state was modified.\n'; return 0; }
    printf '\nRe-running the complete systemd-boot -> Limine preflight at the write boundary...\n'
    leap16_r51_preflight "$target" || { printf '\nWrite-boundary revalidation failed. Nothing was modified.\n'; return 1; }
    r26_execute_adapter_switch limine || rc=$?
    leap16_r44_diag_bind_pending
    return "$rc"
}

eval "$(declare -f run_live_operation | sed '1s/run_live_operation/run_live_operation_pre_leap16_r51/')"
run_live_operation() {
    local target=${1:-} current
    detect_bootloader; current=$BOOTLOADER
    if [[ $current:$target == systemd-boot:limine ]]; then
        leap16_r44_with_transaction_transcript "$current" "$target" switch leap16_r51_run_systemd_to_limine_inner "$target"
        return $?
    fi
    run_live_operation_pre_leap16_r51 "$@"
}
