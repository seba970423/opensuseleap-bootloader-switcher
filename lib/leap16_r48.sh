#!/usr/bin/env bash
# leap16-r48: open the first direct non-GRUB systemd matrix edge:
# finalized Limine -> native openSUSE systemd-boot.
#
# This layer deliberately does NOT enable systemd-boot -> Limine yet.  The
# source and target topologies are both understood, but the Limine target still
# deserves its normal two-step primary+generic-fallback hardware proof.  r48
# first proves the simpler Limine-source retirement edge without touching the
# already hardware-proven GRUB2 <-> Limine or GRUB2 <-> systemd-boot paths.
#
# Candidate topology:
#   Limine primary Boot#### stays first
#   Limine fallback Boot#### stays second and EFI/BOOT stays byte-identical Limine
#   parked systemd-boot Boot#### is appended and receives BootNext exactly once
#
# Final topology after exact systemd-boot runtime proof:
#   systemd-boot Boot#### first
#   EFI/BOOT transferred to byte-identical systemd-boot
#   both ownership-proven Limine firmware aliases removed only after leaving BootOrder
#   exact Limine EFI/config/splash/kernel payload retired
#   LOADER_TYPE=systemd-boot

LEAP16_R48_META='r48-limine-to-systemd.tsv'
LEAP16_R48_SYSTEMD_CHILD='opensuse-bootloader-switcher'
LEAP16_R48_FIRMWARE_BASELINE='source-firmware-baseline.txt'
LEAP16_R48_FALLBACK_CHURN='r48-fallback-churn.tsv'

leap16_r48_pending() {
    [[ ${PENDING_FORMAT:-} == ${R26_PENDING_FORMAT:-5} \
       && ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == limine:systemd-boot ]]
}

leap16_r48_meta_path() {
    local snap=${PENDING_TRANSACTION_SNAPSHOT_DIR:-${TRANSACTION_SNAPSHOT_DIR:-}}
    [[ -n $snap ]] || return 1
    printf '%s/%s\n' "$snap" "$LEAP16_R48_META"
}

leap16_r48_meta_value() {
    local key=$1 p
    p=$(leap16_r48_meta_path) || return 1
    awk -F'\t' -v k="$key" '$1==k{print $2;exit}' "$p" 2>/dev/null
}

leap16_r48_write_meta() {
    local fallback_id=${1^^} p
    [[ $fallback_id =~ ^[0-9A-F]{4}$ ]] || return 1
    p=$(leap16_r48_meta_path) || return 1
    {
        printf 'direction\tlimine:systemd-boot\n'
        printf 'source_fallback_boot_id\t%s\n' "$fallback_id"
        printf 'source_fallback_path\t%s\n' "$LEAP16_R21_FALLBACK_EFI_PATH"
    } >"$p" || return 1
    chmod 600 -- "$p" 2>/dev/null || true
}

leap16_r48_validate_meta() {
    local p fallback
    p=$(leap16_r48_meta_path) || { PENDING_REASON='r48 Limine/systemd metadata path is unavailable'; return 1; }
    [[ -s $p ]] || { PENDING_REASON='r48 Limine/systemd metadata is missing'; return 1; }
    pending_path_under "$p" "$PENDING_TRANSACTION_SNAPSHOT_DIR" || { PENDING_REASON='r48 metadata escaped the transaction snapshot'; return 1; }
    [[ $(leap16_r48_meta_value direction) == limine:systemd-boot ]] || { PENDING_REASON='r48 direction marker is wrong'; return 1; }
    fallback=$(leap16_r48_meta_value source_fallback_boot_id); fallback=${fallback^^}
    [[ $fallback =~ ^[0-9A-F]{4}$ ]] || { PENDING_REASON='r48 source fallback Boot#### is malformed'; return 1; }
    [[ $(leap16_r48_meta_value source_fallback_path) == "$LEAP16_R21_FALLBACK_EFI_PATH" ]] || { PENDING_REASON='r48 source fallback path is wrong'; return 1; }
    return 0
}

leap16_r48_fallback_id() {
    local id
    id=$(leap16_r48_meta_value source_fallback_boot_id 2>/dev/null || true)
    [[ ${id^^} =~ ^[0-9A-F]{4}$ ]] || return 1
    printf '%s\n' "${id^^}"
}

# Format-v5 originally whitelisted only hub edges.  Admit this one new edge
# without relaxing any of the remaining identity/manifest checks.
eval "$(declare -f load_pending_state | sed '1s/load_pending_state/load_pending_state_pre_leap16_r48/')"
load_pending_state() {
    if load_pending_state_pre_leap16_r48 "$@"; then
        return 0
    fi
    [[ $(r26_state_format 2>/dev/null || true) == "$R26_PENDING_FORMAT" \
       && ${PENDING_REASON:-} == 'unsupported r26 adapter migration direction' \
       && ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == limine:systemd-boot ]] || return 1

    [[ $PENDING_PHASE == candidate-ready || $PENDING_PHASE == boot-armed || $PENDING_PHASE == runtime-validated ]] || { PENDING_REASON='unsupported pending-state phase'; return 1; }
    [[ $PENDING_FORMAT == "$R26_PENDING_FORMAT" ]] || { PENDING_REASON='wrong r26 state format'; return 1; }
    [[ $PENDING_ADAPTER_REVISION == "$R26_ADAPTER_REVISION" ]] || { PENDING_REASON='unsupported adapter-state revision'; return 1; }
    [[ -n $PENDING_MACHINE_ID && -n $PENDING_OLD_BOOT_ID && -n $PENDING_TARGET_BOOT_ID ]] || { PENDING_REASON='missing transaction identity'; return 1; }
    [[ -n $PENDING_SOURCE_CMDLINE ]] || { PENDING_REASON='missing source kernel command line'; return 1; }
    [[ -n $PENDING_SOURCE_MANIFEST && -n $PENDING_TARGET_MANIFEST ]] || { PENDING_REASON='missing adapter ownership manifests'; return 1; }
    PENDING_REASON='valid'
    return 0
}

# Every persisted direct edge also carries sidecar ownership evidence for the
# second Limine firmware alias plus the complete pre-stage firmware table.  Do
# not let a format-5 state become write-eligible if either sidecar disappeared.
eval "$(declare -f validate_pending_compatibility | sed '1s/validate_pending_compatibility/validate_pending_compatibility_pre_leap16_r48/')"
validate_pending_compatibility() {
    validate_pending_compatibility_pre_leap16_r48 "$@" || return $?
    leap16_r48_pending || return 0
    leap16_r48_validate_meta || return 1
    local baseline
    baseline=$(leap16_r48_baseline_path 2>/dev/null || true)
    [[ -n $baseline && -s $baseline ]] || { PENDING_REASON='r48 pre-stage firmware baseline is missing'; return 1; }
    grep -Eq '^BootCurrent:[[:space:]]+' "$baseline" || { PENDING_REASON='r48 firmware baseline has no BootCurrent'; return 1; }
    grep -Eq '^BootOrder:[[:space:]]+' "$baseline" || { PENDING_REASON='r48 firmware baseline has no BootOrder'; return 1; }
    PENDING_REASON='compatible'
    return 0
}

leap16_r48_baseline_path() {
    local snap=${PENDING_TRANSACTION_SNAPSHOT_DIR:-${TRANSACTION_SNAPSHOT_DIR:-}}
    [[ -n $snap ]] || return 1
    printf '%s/%s\n' "$snap" "$LEAP16_R48_FIRMWARE_BASELINE"
}

leap16_r48_baseline_has_id() {
    local id=${1^^} baseline
    baseline=$(leap16_r48_baseline_path 2>/dev/null || true)
    [[ -n $baseline && -s $baseline ]] || return 1
    grep -Eq "^Boot${id}\\*?[[:space:]]" "$baseline"
}

leap16_r48_fallback_churn_path() {
    local snap=${PENDING_TRANSACTION_SNAPSHOT_DIR:-${TRANSACTION_SNAPSHOT_DIR:-}}
    [[ -n $snap ]] || return 1
    printf '%s/%s\n' "$snap" "$LEAP16_R48_FALLBACK_CHURN"
}

# Limine and the Leap systemd adapter share ESP/<machine-id> as a parent.  Never
# claim the shared parent, and never claim arbitrary foreign children.  Freeze
# only the exact installed-kernel child directories that the proven Limine
# config is expected to own.
leap16_r48_expected_limine_child_paths() {
    local mid parent ver kid
    mid=$(cat /etc/machine-id 2>/dev/null || true)
    [[ -n $mid ]] || return 1
    parent="${ESP_MOUNT%/}/$mid"
    collect_kernels
    for ver in "${KERNEL_VERSIONS[@]}"; do
        kid=$(kernel_pkgbase_for_version "$ver" 2>/dev/null || true)
        [[ -n $kid ]] || { fail "Could not resolve Limine kernel ownership id for $ver"; return 1; }
        printf '%s/%s\n' "$parent" "$kid"
    done | LC_ALL=C sort -u
}

leap16_r48_verify_limine_machine_children_exact() {
    local mid parent child expected_csv base
    local -a expected=()
    mid=$(cat /etc/machine-id 2>/dev/null || true)
    [[ -n $mid ]] || { fail 'Machine ID is unavailable while proving Limine payload ownership'; return 1; }
    parent="${ESP_MOUNT%/}/$mid"
    mapfile -t expected < <(leap16_r48_expected_limine_child_paths) || return 1
    ((${#expected[@]} > 0)) || { fail 'No expected Limine kernel child namespaces were derived'; return 1; }
    while IFS= read -r child; do
        [[ -n $child ]] || continue
        base=${child##*/}
        [[ $base != "$LEAP16_R48_SYSTEMD_CHILD" ]] || { fail 'systemd-boot payload child already exists inside the finalized Limine source namespace'; return 1; }
        local match=0 e
        for e in "${expected[@]}"; do [[ $child == "$e" ]] && { match=1; break; }; done
        ((match)) || { fail "Unexpected/foreign machine-id child is not claimable as Limine ownership: $child"; return 1; }
    done < <(sudo -n find "$parent" -mindepth 1 -maxdepth 1 -print 2>/dev/null | LC_ALL=C sort || true)
    local e
    for e in "${expected[@]}"; do
        (sudo -n test -d "$e" 2>/dev/null || [[ -d $e ]]) || { fail "Expected Limine managed kernel child is missing: $e"; return 1; }
    done
    ok 'Limine machine-id namespace contains only the exact installed-kernel child directories'
}

eval "$(declare -f r26_adapter_paths | sed '1s/r26_adapter_paths/r26_adapter_paths_pre_leap16_r48/')"
r26_adapter_paths() {
    local bl=$1 path
    if [[ $bl != limine ]]; then
        r26_adapter_paths_pre_leap16_r48 "$@"
        return $?
    fi
    printf '%s\n' "${ESP_MOUNT%/}/EFI/LIMINE" "${ESP_MOUNT%/}/limine.conf" "${ESP_MOUNT%/}/limine-splash.png" /etc/default/limine
    while IFS= read -r path; do
        [[ -n $path ]] && printf '%s\n' "$path"
    done < <(leap16_r48_expected_limine_child_paths)
}

leap16_r48_ids_for_current_esp_path() {
    local expected=$1 id
    while IFS= read -r id; do
        id=${id^^}
        [[ $id =~ ^[0-9A-F]{4}$ ]] || continue
        leap16_nvram_entry_matches_current_esp "$id" || continue
        nvram_id_matches_path "$id" "$expected" || continue
        printf '%s\n' "$id"
    done < <(efibootmgr -v 2>/dev/null | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\)\*.*/\1/p' | tr '[:lower:]' '[:upper:]' | LC_ALL=C sort -u)
}

leap16_r48_current_fallback_ids() {
    leap16_r48_ids_for_current_esp_path "$LEAP16_R21_FALLBACK_EFI_PATH"
}

leap16_r48_source_topology_gate() {
    local primary=${BOOT_CURRENT^^} order fallback ids ph fh
    ids=$(leap16_r48_current_fallback_ids | paste -sd, -)
    [[ -n $ids && $ids != *,* ]] || { fail "Expected exactly one Limine generic-fallback NVRAM alias; found ${ids:-none}"; return 1; }
    fallback=${ids^^}
    [[ $fallback != "$primary" ]] || { fail 'Limine primary and fallback unexpectedly use the same Boot####'; return 1; }
    leap16_nvram_entry_matches_current_esp "$fallback" || { fail "Limine fallback Boot$fallback is not bound to the current ESP"; return 1; }
    nvram_id_matches_path "$fallback" "$LEAP16_R21_FALLBACK_EFI_PATH" || { fail "Limine fallback Boot$fallback changed EFI path"; return 1; }
    order=$(leap16_current_boot_order)
    [[ ${order%%,*} == "$primary" ]] || { fail "Persistent BootOrder is not Limine primary Boot$primary first ($order)"; return 1; }
    [[ ${order#*,} != "$order" && ${order#*,} == "$fallback"* ]] || { fail "Limine fallback Boot$fallback is not second in persistent BootOrder ($order)"; return 1; }
    ph=$(r21_hash_privileged "${ESP_MOUNT%/}/EFI/LIMINE/LIMINE_X64.EFI")
    fh=$(r21_hash_privileged "${ESP_MOUNT%/}/EFI/BOOT/BOOTX64.EFI")
    [[ $ph =~ ^[0-9A-Fa-f]{64}$ && $ph == "$fh" ]] || { fail 'Finalized Limine generic fallback is not byte-identical to the canonical Limine EFI'; return 1; }
    LEAP16_R48_DISCOVERED_FALLBACK_ID=$fallback
    ok "Finalized Limine primary/fallback topology is exact: Boot$primary, Boot$fallback"
}

leap16_r48_systemd_namespace_clean() {
    local p
    [[ $(count_nvram_entries_for_target systemd-boot) == 0 ]] || { fail 'Pre-existing systemd-boot NVRAM state is ambiguous'; return 1; }
    while IFS= read -r p; do
        [[ -n $p ]] || continue
        if sudo -n test -e "$p" 2>/dev/null || sudo -n test -L "$p" 2>/dev/null || [[ -e $p || -L $p ]]; then
            fail "systemd-boot target namespace already exists: $p"
            return 1
        fi
    done < <(leap16_r32_systemd_owned_paths)
    return 0
}

leap16_r48_preflight() {
    local target=$1
    [[ ${BOOTLOADER:-} == limine && $target == systemd-boot ]] || return 1
    printf '\n%s Limine -> systemd-boot switch preflight:\n' "${SWITCHER_RELEASE:-leap16-r48}"
    run_validation preflight || { fail 'Base preflight failed; nothing was modified'; return 1; }
    is_leap16 || { fail 'This backend is restricted to openSUSE Leap 16'; return 1; }
    leap16_require_sudo_session || return 1
    bootcurrent_is_generic_fallback && { fail 'Canonical Limine BootCurrent is required; reboot through the primary Limine Boot#### first'; return 1; }
    [[ $(normalize_efi_path "${BOOT_EFI_PATH:-}" | tr '[:upper:]' '[:lower:]') == efi/limine/limine_x64.efi ]] || { fail 'BootCurrent is not canonical Limine'; return 1; }
    pending_exists && { fail 'A bootloader transaction is already pending'; return 1; }
    [[ -z ${BOOT_NEXT:-} ]] || { fail "BootNext is already set to Boot${BOOT_NEXT^^}"; return 1; }
    validate_limine_boot_chain current || { fail 'Finalized Limine source failed deep validation'; return 1; }
    leap16_r48_source_topology_gate || return 1
    leap16_r48_verify_limine_machine_children_exact || return 1
    leap16_r32_secure_boot_disabled || { fail 'Secure Boot must be disabled for this systemd-boot path'; return 1; }
    leap16_r48_systemd_namespace_clean || return 1
    collect_kernels
    ((${#KERNEL_VERSIONS[@]} > 0)) || { fail 'No complete installed kernel/initrd pairs were found'; return 1; }
    ok 'Limine -> systemd-boot preflight passed; primary+fallback Limine remain authoritative until exact systemd-boot runtime proof'
}

leap16_r48_plan() {
    printf '\nExact openSUSE Limine -> systemd-boot candidate plan:\n'
    printf '  1. Re-prove finalized Limine primary + explicit generic-fallback Boot#### and byte-identical fallback payload.\n'
    printf '  2. Snapshot only Limine-owned EFI/config/kernel child namespaces; never claim the shared machine-id parent.\n'
    printf '  3. Stage native openSUSE systemd-boot + exact BLS/kernel/initrd payload as one parked Boot####.\n'
    printf '  4. Keep Limine primary first, Limine fallback second, restore EFI/BOOT to Limine, and arm only systemd-boot with BootNext.\n'
    printf '  5. After real systemd-boot userspace arrival, prove BootCurrent/kernel/root/cmdline/target ownership while both Limine firmware paths remain exact.\n'
    printf '  6. Only after proof: promote systemd-boot, transfer EFI/BOOT to systemd-boot, remove both Limine aliases from BootOrder while their EFI paths still exist, then retire exact Limine-owned files.\n'
    printf '  7. Set LOADER_TYPE=systemd-boot and require final canonical+fallback systemd-boot validation.\n'
    printf '  If target proof fails, Limine primary/fallback recovery remains intact.\n'
}

# Snapshot the fallback Boot#### identity in addition to the disjoint Limine file
# manifest created by the adapter source snapshot.
eval "$(declare -f adapter_source_snapshot | sed '1s/adapter_source_snapshot/adapter_source_snapshot_pre_leap16_r48/')"
adapter_source_snapshot() {
    local source=$1 fallback baseline
    adapter_source_snapshot_pre_leap16_r48 "$@" || return $?
    [[ $source == limine ]] || return 0
    fallback=${LEAP16_R48_DISCOVERED_FALLBACK_ID:-}
    if [[ ! $fallback =~ ^[0-9A-F]{4}$ ]]; then
        local ids
        ids=$(leap16_r48_current_fallback_ids | paste -sd, -)
        [[ -n $ids && $ids != *,* ]] || { fail 'Could not freeze exact Limine fallback Boot#### identity'; return 1; }
        fallback=${ids^^}
    fi
    leap16_r48_write_meta "$fallback" || { fail 'Could not persist Limine fallback ownership metadata'; return 1; }

    # Fallback ownership transfer can make some firmware synthesize a fresh
    # `UEFI OS` alias for EFI/BOOT.  Capture the full table before staging so a
    # later alias can be distinguished from user/pre-existing firmware state.
    baseline=$(leap16_r48_baseline_path) || return 1
    sudo -n efibootmgr -v >"$baseline" || { fail 'Could not record the privileged pre-stage firmware table for Limine retirement ownership'; return 1; }
    chmod 600 -- "$baseline" 2>/dev/null || true
    grep -Eq '^BootCurrent:[[:space:]]+' "$baseline" || { fail 'Pre-stage firmware baseline is incomplete'; return 1; }
    grep -Eq '^BootOrder:[[:space:]]+' "$baseline" || { fail 'Pre-stage firmware baseline has no BootOrder'; return 1; }
    grep -Eq "^Boot${fallback}\\*?[[:space:]]" "$baseline" || { fail "Pre-stage firmware baseline does not contain Limine fallback Boot$fallback"; return 1; }
    ok "Recorded Limine fallback Boot$fallback plus the complete pre-stage firmware table as source recovery ownership"
}

# Extend the source recovery proof with the second Limine firmware path.
eval "$(declare -f verify_pending_source_recovery_unchanged | sed '1s/verify_pending_source_recovery_unchanged/verify_pending_source_recovery_unchanged_pre_leap16_r48/')"
verify_pending_source_recovery_unchanged() {
    local fallback ids order
    verify_pending_source_recovery_unchanged_pre_leap16_r48 "$@" || return $?
    leap16_r48_pending || return 0
    leap16_r48_validate_meta || { fail "$PENDING_REASON"; return 1; }
    fallback=$(leap16_r48_fallback_id) || return 1
    boot_id_exists "$fallback" || { fail "Ownership-proven Limine fallback Boot$fallback disappeared"; return 1; }
    leap16_nvram_entry_matches_current_esp "$fallback" || { fail "Limine fallback Boot$fallback changed ESP ownership"; return 1; }
    nvram_id_matches_path "$fallback" "$LEAP16_R21_FALLBACK_EFI_PATH" || { fail "Limine fallback Boot$fallback changed EFI path"; return 1; }
    ids=$(leap16_r48_current_fallback_ids | paste -sd, -)
    [[ ${ids^^} == "$fallback" ]] || { fail "Limine fallback alias set changed (expected Boot$fallback, found ${ids:-none})"; return 1; }
    order=$(leap16_current_boot_order)
    [[ ${order%%,*} == ${PENDING_OLD_BOOT_ID^^} ]] || { fail 'Limine source is no longer first in persistent BootOrder'; return 1; }
    [[ ${order#*,} != "$order" && ${order#*,} == "$fallback"* ]] || { fail "Limine fallback Boot$fallback is no longer second in persistent BootOrder ($order)"; return 1; }
    ok "Exact Limine source primary/fallback ordering remains unchanged: Boot${PENDING_OLD_BOOT_ID^^}, Boot$fallback"
}

# Failed/uncommitted staging must remove the actual Leap systemd namespace,
# not the inherited CachyOS sdboot-manage layout.  r33 already does this for a
# GRUB source; mirror that exact ownership boundary for a Limine source.
eval "$(declare -f r26_remove_uncommitted_target_namespaces | sed '1s/r26_remove_uncommitted_target_namespaces/r26_remove_uncommitted_target_namespaces_pre_leap16_r48/')"
r26_remove_uncommitted_target_namespaces() {
    local target=$1 path id rc=0
    if [[ ${BOOTLOADER:-} != limine || $target != systemd-boot ]]; then
        r26_remove_uncommitted_target_namespaces_pre_leap16_r48 "$@"
        return $?
    fi

    while IFS= read -r id; do
        [[ -n $id ]] || continue
        sudo efibootmgr -b "$id" -B >/dev/null 2>&1 || { rc=1; continue; }
        ok "Removed uncommitted systemd-boot NVRAM entry Boot$id"
    done < <(leap16_r48_ids_for_current_esp_path "$LEAP16_R32_SDBOOT_EFI")

    while IFS= read -r path; do
        [[ -n $path ]] || continue
        if sudo -n test -e "$path" 2>/dev/null || sudo -n test -L "$path" 2>/dev/null || [[ -e $path || -L $path ]]; then
            sudo rm -rf -- "$path" || { rc=1; continue; }
            ok "Removed uncommitted systemd-boot target namespace: $path"
        fi
    done < <(leap16_r32_systemd_owned_paths)
    sudo rmdir -- "${ESP_MOUNT%/}/loader/entries" 2>/dev/null || true
    sudo rmdir -- "${ESP_MOUNT%/}/loader" 2>/dev/null || true
    leap16_r47_cleanup_empty_machine_id_parent || true

    if (( ${LEAP16_R33_SDBOOT_PACKAGE_INSTALLED_BY_STAGE:-0} == 1 )); then
        if sudo zypper --non-interactive remove systemd-boot >/dev/null; then
            LEAP16_R33_SDBOOT_PACKAGE_INSTALLED_BY_STAGE=0
            ok 'Removed systemd-boot RPM installed only by the failed uncommitted Limine -> systemd-boot staging attempt'
        else
            fail 'Could not restore the pre-stage systemd-boot package state after failed Limine -> systemd-boot staging'
            rc=1
        fi
    fi
    return "$rc"
}

# Use the already hardware-proven Leap systemd staging backend for Limine too.
eval "$(declare -f r26_stage_systemd_boot_target | sed '1s/r26_stage_systemd_boot_target/r26_stage_systemd_boot_target_pre_leap16_r48/')"
r26_stage_systemd_boot_target() {
    local source_id=$1 original_order=$2 reference=$3 target_id
    if [[ ${BOOTLOADER:-} != limine ]]; then
        r26_stage_systemd_boot_target_pre_leap16_r48 "$@"
        return $?
    fi
    leap16_r32_secure_boot_disabled || { fail 'systemd-boot staging requires Secure Boot disabled'; return 1; }
    leap16_r32_install_systemd_boot_package || return 1
    leap16_r32_write_systemd_boot_candidate "$reference" || return 1
    r28_create_alias_create_only "$LEAP16_R32_SDBOOT_LABEL" "$LEAP16_R32_SDBOOT_EFI" || return 1
    target_id=$R28_CREATED_ALIAS_ID
    set_source_first_boot_order "$source_id" "$target_id" "$original_order" || return 1
    r26_restore_source_fallback_after_target_stage || return 1
    adapter_target_validate systemd-boot || return 1
    r26_record_target_adapter systemd-boot || return 1
    R26_STAGED_TARGET_ID=${target_id^^}
    ok "Staged native openSUSE systemd-boot target as parked Boot$R26_STAGED_TARGET_ID without disturbing Limine fallback"
}

# The original r32 namespace-clean hook is GRUB-source-only.  Route this edge to
# the same exact Leap target namespace gate.
eval "$(declare -f r26_target_namespace_clean | sed '1s/r26_target_namespace_clean/r26_target_namespace_clean_pre_leap16_r48/')"
r26_target_namespace_clean() {
    local target=$1
    if [[ ${BOOTLOADER:-} == limine && $target == systemd-boot ]]; then
        leap16_r48_systemd_namespace_clean
    else
        r26_target_namespace_clean_pre_leap16_r48 "$@"
    fi
}

leap16_r48_validate_systemd_runtime() {
    local diag next order
    validate_pending_compatibility || { fail "Pending migration is incompatible: $PENDING_REASON"; return 1; }
    leap16_r48_pending || return 1
    [[ $PENDING_PHASE == boot-armed || $PENDING_PHASE == runtime-validated ]] || { fail "Runtime validation requires boot-armed/runtime-validated state (phase $PENDING_PHASE)"; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail "Runtime proof requires exact systemd-boot Boot$PENDING_TARGET_BOOT_ID"; return 1; }
    leap16_require_sudo_session || return 1
    next=$(pending_bootnext_id)
    [[ -z $next ]] || { fail "BootNext is still set to Boot$next after the one-shot boot"; return 1; }
    order=$(leap16_current_boot_order)
    [[ ${order%%,*} == ${PENDING_OLD_BOOT_ID^^} ]] || { fail "Persistent BootOrder no longer keeps Limine source first ($order)"; return 1; }
    pending_validate_running_kernel || return 1
    pending_validate_runtime_cmdline_against_source || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    leap16_r34_validate_systemd_boot_chain runtime || return 1
    verify_pending_source_recovery_unchanged || return 1
    pending_set_phase runtime-validated || { fail 'Runtime proof passed but runtime-validated phase could not be persisted'; return 1; }
    PENDING_PHASE=runtime-validated
    diag=$(pending_capture_runtime_diagnostics runtime-pass-systemd-from-limine | tail -n1 || true)
    [[ -n $diag ]] && printf 'Runtime diagnostic snapshot: %s\n' "$diag"
    printf '\nRUNTIME-VALIDATED Limine -> systemd-boot one-shot boot succeeded.\n'
    printf '  BootCurrent: Boot%s -> %s\n' "$PENDING_TARGET_BOOT_ID" "$PENDING_TARGET_EFI_PATH"
    printf '  Persistent BootOrder: Limine primary/fallback recovery remains ahead until finalization\n'
}

eval "$(declare -f validate_pending_target_runtime | sed '1s/validate_pending_target_runtime/validate_pending_target_runtime_pre_leap16_r48/')"
validate_pending_target_runtime() {
    if leap16_r48_pending; then
        leap16_r48_validate_systemd_runtime
    else
        validate_pending_target_runtime_pre_leap16_r48 "$@"
    fi
}

# After EFI/BOOT ownership transfer, some firmware may synthesize an extra
# same-ESP `UEFI OS` alias.  The complete pre-stage firmware table lets us
# distinguish such an alias from user/pre-existing state.  Record the exact
# post-baseline fallback IDs once, then make partial-finalization retries
# idempotent without ever broadening ownership.
leap16_r48_collect_fallback_churn() {
    local source=${PENDING_OLD_BOOT_ID^^} target=${PENDING_TARGET_BOOT_ID^^} fallback id
    fallback=$(leap16_r48_fallback_id) || return 1
    while IFS= read -r id; do
        id=${id^^}
        [[ $id =~ ^[0-9A-F]{4}$ ]] || continue
        [[ $id != "$source" && $id != "$target" && $id != "$fallback" ]] || continue
        if leap16_r48_baseline_has_id "$id"; then
            # Preflight required exactly one same-ESP fallback alias (the
            # explicit Limine fallback), so another baseline fallback ID is an
            # ownership contradiction rather than something we may normalize.
            fail "Unexpected pre-stage generic-fallback Boot$id is not the recorded Limine fallback"
            return 1
        fi
        leap16_nvram_entry_matches_current_esp "$id" || { fail "Post-stage fallback Boot$id is not on the transaction ESP"; return 1; }
        nvram_id_matches_path "$id" "$LEAP16_R21_FALLBACK_EFI_PATH" || { fail "Post-stage fallback Boot$id changed EFI path"; return 1; }
        printf '%s\n' "$id"
    done < <(leap16_r48_current_fallback_ids)
}

leap16_r48_record_fallback_churn() {
    local record tmp id raw current_csv recorded_csv
    record=$(leap16_r48_fallback_churn_path) || return 1
    if [[ ! -s $record ]]; then
        tmp=$(mktemp) || return 1
        printf 'version\t1\n' >"$tmp" || { rm -f -- "$tmp"; return 1; }
        raw=$(leap16_r48_collect_fallback_churn) || { rm -f -- "$tmp"; return 1; }
        if [[ -n $raw ]]; then
            while IFS= read -r id; do
                [[ $id =~ ^[0-9A-F]{4}$ ]] || continue
                printf 'entry\t%s\n' "$id" >>"$tmp" || { rm -f -- "$tmp"; return 1; }
            done <<<"$raw"
        fi
        mv -f -- "$tmp" "$record" || { rm -f -- "$tmp"; return 1; }
        chmod 600 -- "$record" 2>/dev/null || true
    fi

    current_csv=$(leap16_r48_collect_fallback_churn | LC_ALL=C sort -u | paste -sd, -) || return 1
    recorded_csv=$(awk -F'\t' '$1=="entry" && $2 ~ /^[0-9A-F]{4}$/{print $2}' "$record" | LC_ALL=C sort -u | paste -sd, -)
    # Missing recorded IDs are acceptable on an interrupted retry; an
    # unrecorded newly appearing ID is not.
    if [[ -n $current_csv ]]; then
        local cur
        IFS=',' read -ra _r48_cur <<<"$current_csv"
        for cur in "${_r48_cur[@]}"; do
            case ",$recorded_csv," in *,$cur,*) ;; *) fail "Unrecorded post-stage generic-fallback Boot$cur appeared after ownership was frozen"; return 1 ;; esac
        done
    fi
    if [[ -n $recorded_csv ]]; then
        ok "Ownership-recorded post-baseline generic-fallback churn: Boot${recorded_csv//,/ Boot}"
    else
        ok 'No post-baseline generic-fallback firmware churn was observed'
    fi
}

leap16_r48_recorded_fallback_churn_ids() {
    local record
    record=$(leap16_r48_fallback_churn_path) || return 1
    [[ -s $record ]] || return 0
    awk -F'\t' '$1=="entry" && $2 ~ /^[0-9A-F]{4}$/{print $2}' "$record" | LC_ALL=C sort -u
}

leap16_r48_verify_recorded_fallback_churn() {
    local id
    while IFS= read -r id; do
        [[ -n $id ]] || continue
        # Missing is safe on a partial-finalization retry because the exact ID
        # was frozen before any deletion.  A surviving ID must remain exact.
        boot_id_exists "$id" || continue
        leap16_nvram_entry_matches_current_esp "$id" || { fail "Ownership-recorded fallback-churn Boot$id changed ESP binding"; return 1; }
        nvram_id_matches_path "$id" "$LEAP16_R21_FALLBACK_EFI_PATH" || { fail "Ownership-recorded fallback-churn Boot$id changed EFI path"; return 1; }
    done < <(leap16_r48_recorded_fallback_churn_ids)
}

leap16_r48_final_order_without_limine() {
    local target=${PENDING_TARGET_BOOT_ID^^} source=${PENDING_OLD_BOOT_ID^^} fallback order id joined c owned
    local -a ids=() out=("$target") churn=()
    fallback=$(leap16_r48_fallback_id) || return 1
    leap16_r48_record_fallback_churn || return 1
    leap16_r48_verify_recorded_fallback_churn || return 1
    mapfile -t churn < <(leap16_r48_recorded_fallback_churn_ids)
    order=$(leap16_current_boot_order) || return 1
    IFS=',' read -ra ids <<<"$order"
    for id in "${ids[@]}"; do
        id=${id^^}; owned=0
        [[ -n $id && $id != "$target" && $id != "$source" && $id != "$fallback" ]] || continue
        for c in "${churn[@]}"; do [[ $id == "$c" ]] && { owned=1; break; }; done
        ((owned)) && continue
        boot_id_exists "$id" && out+=("$id")
    done
    joined=$(IFS=,; printf '%s' "${out[*]}")
    sudo efibootmgr -o "$joined" >/dev/null || return 1
    order=$(leap16_current_boot_order)
    [[ ${order%%,*} == "$target" ]] || { fail "Final BootOrder is not systemd-boot first ($order)"; return 1; }
    ! leap16_order_has_id "$order" "$source" || { fail "Limine primary Boot$source remains in BootOrder"; return 1; }
    ! leap16_order_has_id "$order" "$fallback" || { fail "Limine fallback Boot$fallback remains in BootOrder"; return 1; }
    for c in "${churn[@]}"; do
        [[ -n $c ]] || continue
        ! leap16_order_has_id "$order" "$c" || { fail "Ownership-recorded generic-fallback churn Boot$c remains in BootOrder"; return 1; }
    done
    ok 'Removed Limine primary/fallback plus ownership-recorded post-baseline fallback churn from BootOrder while every referenced EFI path still exists'
}

leap16_r48_delete_limine_aliases() {
    local source=${PENDING_OLD_BOOT_ID^^} fallback id
    fallback=$(leap16_r48_fallback_id) || return 1
    leap16_r48_verify_recorded_fallback_churn || return 1
    while IFS= read -r id; do
        [[ -n $id ]] || continue
        if boot_id_exists "$id"; then
            leap16_nvram_entry_matches_current_esp "$id" || { fail "Fallback-churn Boot$id changed ESP binding before deletion"; return 1; }
            nvram_id_matches_path "$id" "$LEAP16_R21_FALLBACK_EFI_PATH" || { fail "Fallback-churn Boot$id changed path before deletion"; return 1; }
            sudo efibootmgr -b "$id" -B >/dev/null || return 1
            ok "Deleted ownership-recorded post-baseline generic-fallback Boot$id after removing it from BootOrder"
        fi
    done < <(leap16_r48_recorded_fallback_churn_ids)
    if boot_id_exists "$fallback"; then
        leap16_nvram_entry_matches_current_esp "$fallback" || { fail "Limine fallback Boot$fallback changed ESP binding before deletion"; return 1; }
        nvram_id_matches_path "$fallback" "$LEAP16_R21_FALLBACK_EFI_PATH" || { fail "Limine fallback Boot$fallback changed path before deletion"; return 1; }
        sudo efibootmgr -b "$fallback" -B >/dev/null || return 1
        ok "Deleted ownership-proven Limine fallback Boot$fallback after removing it from BootOrder"
    fi
    if boot_id_exists "$source"; then
        leap16_nvram_entry_matches_current_esp "$source" || { fail "Limine primary Boot$source changed ESP binding before deletion"; return 1; }
        nvram_id_matches_path "$source" "$PENDING_OLD_BOOT_EFI_PATH" || { fail "Limine primary Boot$source changed path before deletion"; return 1; }
        sudo efibootmgr -b "$source" -B >/dev/null || return 1
        ok "Deleted ownership-proven Limine primary Boot$source after removing it from BootOrder"
    fi
    [[ -z $(leap16_r48_current_fallback_ids | awk 'NF') ]] || { fail 'A same-ESP generic-fallback NVRAM alias remains after Limine retirement'; return 1; }
    [[ $(count_nvram_entries_for_target limine) == 0 ]] || { fail 'A canonical Limine NVRAM alias remains after retirement'; return 1; }
}

leap16_r48_finalize() {
    local fallback
    validate_pending_compatibility || { fail "Pending migration is incompatible: $PENDING_REASON"; return 1; }
    leap16_r48_pending || return 1
    [[ $PENDING_PHASE == runtime-validated ]] || { fail 'Finalization requires runtime-validated systemd-boot state'; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail 'Finalization must run from the exact runtime-proven systemd-boot target'; return 1; }
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext must be clear before finalization'; return 1; }
    run_validation preflight || return 1
    pending_validate_running_kernel || return 1
    pending_validate_runtime_cmdline_against_source || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    leap16_r34_validate_systemd_boot_chain runtime || return 1
    verify_pending_source_recovery_unchanged || return 1
    fallback=$(leap16_r48_fallback_id) || return 1

    printf '\nFINALIZE hardware-proven Limine -> systemd-boot:\n'
    printf '  - promote systemd-boot Boot%s while Limine primary Boot%s + fallback Boot%s still exist\n' "$PENDING_TARGET_BOOT_ID" "$PENDING_OLD_BOOT_ID" "$fallback"
    printf '  - transfer EFI/BOOT to byte-identical runtime-proven systemd-boot\n'
    printf '  - remove both Limine aliases from BootOrder before deleting either variable\n'
    printf '  - retire only the exact Limine source manifest, then set LOADER_TYPE=systemd-boot\n'

    leap16_r34_target_first_keep_recovery || { fail 'Could not promote systemd-boot while retaining Limine recovery aliases'; return 1; }
    verify_pending_candidate_ownership_unchanged || return 1
    leap16_r34_validate_systemd_boot_chain target || return 1
    verify_pending_source_recovery_unchanged || return 1

    leap16_r34_transfer_systemd_fallback || return 1
    # From here the shared fallback intentionally belongs to systemd-boot, so
    # do not call the source verifier that requires the old Limine fallback hash.
    r26_verify_owned_manifest "$PENDING_SOURCE_MANIFEST" || return 1
    leap16_r48_final_order_without_limine || return 1
    leap16_r48_delete_limine_aliases || return 1
    r26_remove_owned_manifest_paths "$PENDING_SOURCE_MANIFEST" || return 1
    leap16_r34_set_loader_policy_systemd || return 1

    detect_bootloader
    [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail 'systemd-boot identity changed during finalization'; return 1; }
    [[ $(pending_bootorder_first) == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail 'systemd-boot is not first after Limine retirement'; return 1; }
    [[ $(r21_hash_privileged "$PENDING_ESP_MOUNT/EFI/BOOT/BOOTX64.EFI") == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'Final generic EFI fallback is not byte-identical to systemd-boot'; return 1; }
    validate_target_state systemd-boot || return 1
    leap16_r34_validate_systemd_boot_chain final || return 1

    pending_capture_runtime_diagnostics finalized-systemd-from-limine >/dev/null 2>&1 || true
    remove_pending_transaction_snapshot || warn 'Could not remove private transaction snapshot after successful finalization'
    rm -f -- "$PENDING_STATE_FILE"
    printf '\nFINALIZED Limine -> systemd-boot successfully.\n'
    printf 'systemd-boot Boot%s is persistent first; both Limine firmware aliases and exact Limine-owned files are retired.\n' "$PENDING_TARGET_BOOT_ID"
}

eval "$(declare -f r26_finalize_adapter_transaction | sed '1s/r26_finalize_adapter_transaction/r26_finalize_adapter_transaction_pre_leap16_r48/')"
r26_finalize_adapter_transaction() {
    if leap16_r48_pending; then
        leap16_r48_finalize
    else
        r26_finalize_adapter_transaction_pre_leap16_r48 "$@"
    fi
}

# Add only the first direct edge to the operation matrix.
eval "$(declare -f operation_supported | sed '1s/operation_supported/operation_supported_pre_leap16_r48/')"
operation_supported() {
    [[ $1:$2 == limine:systemd-boot ]] && return 0
    operation_supported_pre_leap16_r48 "$@"
}

# Reuse r44/r46 full-stage transcript + user-backup prompt by extending the
# already allow-listed inner command instead of inventing a second PTY entry.
eval "$(declare -f leap16_r44_run_systemd_edge_inner | sed '1s/leap16_r44_run_systemd_edge_inner/leap16_r44_run_systemd_edge_inner_pre_leap16_r48/')"
leap16_r44_run_systemd_edge_inner() {
    local target=$1 current=$BOOTLOADER rc=0
    if [[ $current:$target != limine:systemd-boot ]]; then
        leap16_r44_run_systemd_edge_inner_pre_leap16_r48 "$@"
        return $?
    fi
    leap16_r48_preflight "$target" || return 1
    offer_operation_backup || return 1
    leap16_r48_plan
    confirm_operation "$current" "$target" || { printf '\nOperation cancelled. No boot state was modified.\n'; return 0; }
    printf '\nRe-running the complete Limine -> systemd-boot preflight at the write boundary...\n'
    leap16_r48_preflight "$target" || { printf '\nWrite-boundary revalidation failed. Nothing was modified.\n'; return 1; }
    r26_execute_adapter_switch systemd-boot || rc=$?
    leap16_r44_diag_bind_pending
    return "$rc"
}

eval "$(declare -f run_live_operation | sed '1s/run_live_operation/run_live_operation_pre_leap16_r48/')"
run_live_operation() {
    local target=${1:-} current
    detect_bootloader; current=$BOOTLOADER
    if [[ $current:$target == limine:systemd-boot ]]; then
        leap16_r44_with_transaction_transcript "$current" "$target" switch leap16_r44_run_systemd_edge_inner "$target"
        return $?
    fi
    run_live_operation_pre_leap16_r48 "$@"
}

# Root automatic continuation with the same diagnostics sync as the already
# proven GRUB/systemd directions.
leap16_r48_resume_systemd_root() {
    r22_root_bundle_preflight || return 1
    local bundle=$R22_RESUME_BUNDLE conf="$R22_RESUME_BUNDLE/resume.conf" detail
    mkdir -p -- "$bundle/diagnostics" || return 1
    LEAP16_DIAGNOSTIC_ROOT="$bundle/diagnostics" LEAP16_AUTO_RESUME=1
    export LEAP16_DIAGNOSTIC_ROOT LEAP16_AUTO_RESUME
    exec > >(tee -a "$bundle/automatic-resume.log") 2>&1
    printf 'openSUSE Bootloader Switcher %s automatic Limine -> systemd-boot resume\nBundle: %s\n' "${SWITCHER_RELEASE:-leap16-r48}" "$bundle"
    load_pending_state || { r22_write_user_result "$conf" failed "Invalid r48 pending state: $PENDING_REASON" || true; r22_remove_resume_service_files; return 1; }
    validate_pending_compatibility || { r22_write_user_result "$conf" failed "Incompatible r48 pending state: $PENDING_REASON" || true; r22_remove_resume_service_files; return 1; }
    detect_bootloader
    if [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == ${PENDING_OLD_BOOT_ID^^} ]]; then
        printf 'Automatic resume: firmware returned to Limine source; no systemd-boot proof/finalization allowed.\n'
        r22_resume_source_fallback "$conf" || return 1
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" safe-fallback || true
        return 0
    fi
    [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || {
        r22_write_user_result "$conf" failed 'Limine -> systemd-boot resume saw an unexpected BootCurrent; no source cleanup was attempted.' || true
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
        r22_remove_resume_service_files
        return 1
    }
    case "$PENDING_PHASE" in
        boot-armed)
            validate_pending_target_runtime || {
                r22_write_user_result "$conf" failed 'systemd-boot booted but Limine -> systemd-boot runtime proof failed; Limine retirement was NOT attempted.' || true
                r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
                r22_remove_resume_service_files
                return 1
            }
            PENDING_PHASE=runtime-validated
            r22_sync_user_phase_from_root "$conf" runtime-validated || true
            ;;
        runtime-validated) printf 'Runtime proof already persisted; continuing Limine -> systemd-boot finalization.\n' ;;
        *) r22_write_user_result "$conf" failed "Unexpected r48 automatic-resume phase: $PENDING_PHASE" || true; r22_remove_resume_service_files; return 1 ;;
    esac
    if ! r26_finalize_adapter_transaction; then
        r22_write_user_result "$conf" failed 'systemd-boot runtime proof passed but ownership-gated Limine retirement/finalization failed.' || true
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
        r22_remove_resume_service_files
        return 1
    fi
    leap16_capture_diagnostics auto-resume-pass >/dev/null 2>&1 || true
    r13_sync_root_diagnostics_to_user "$conf" "$bundle" success || true
    detail="Limine -> systemd-boot automated runtime proof/finalization succeeded. systemd-boot Boot$PENDING_TARGET_BOOT_ID is first; Limine primary/fallback aliases and exact source-owned files were retired."
    r22_cleanup_user_shadow_after_success "$conf"
    r22_write_user_result "$conf" success "$detail" || true
    r22_remove_resume_service_files
    rm -rf -- "$bundle" 2>/dev/null || true
}

eval "$(declare -f r22_resume_transaction_root | sed '1s/r22_resume_transaction_root/r22_resume_transaction_root_pre_leap16_r48/')"
r22_resume_transaction_root() {
    local src='' tgt=''
    if [[ -f ${PENDING_STATE_FILE:-/nonexistent} ]]; then
        src=$(awk -F'\t' '$1=="source"{print $2;exit}' "$PENDING_STATE_FILE" 2>/dev/null || true)
        tgt=$(awk -F'\t' '$1=="target"{print $2;exit}' "$PENDING_STATE_FILE" 2>/dev/null || true)
    fi
    if [[ $src:$tgt == limine:systemd-boot ]]; then
        leap16_r48_resume_systemd_root
    else
        r22_resume_transaction_root_pre_leap16_r48 "$@"
    fi
}
