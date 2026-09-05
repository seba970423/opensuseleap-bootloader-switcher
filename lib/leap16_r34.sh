#!/usr/bin/env bash
# leap16-r34: first hardware-failure follow-up for the Leap systemd-boot edge.
#
# r33 proved the one-shot systemd-boot EFI/kernel path on real hardware, but its
# root-owned resume dispatcher fell through to the older GRUB2 -> Limine resume
# function.  The target was correctly detected as systemd-boot/Boot0000, then
# the Limine-only runtime validator rejected it before any promotion or cleanup.
#
# r34 fixes that dispatch without changing the hardware-proven GRUB2 <-> Limine
# paths.  It also fixes the systemd-boot menu UX (no duplicate "current" BLS
# alias and no kernel version embedded twice in the title) and strengthens the
# future GRUB2 retirement boundary by recording a full pre-stage firmware
# baseline.  A pre-r34 adapter transaction is intentionally NOT eligible for
# GRUB retirement because it lacks that baseline; return to GRUB2, roll it back,
# and restage with r34.

LEAP16_R34_SDBOOT_MARKER='# Managed by openSUSE Bootloader Switcher leap16-r34'
LEAP16_R32_SDBOOT_MANAGED_MARKER="$LEAP16_R34_SDBOOT_MARKER"
LEAP16_R34_FIRMWARE_BASELINE='source-firmware-baseline.txt'

leap16_r34_sdboot_pending() {
    [[ ${PENDING_FORMAT:-} == ${R26_PENDING_FORMAT:-5} \
       && ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == grub:systemd-boot ]]
}

leap16_r34_baseline_path() {
    [[ -n ${PENDING_TRANSACTION_SNAPSHOT_DIR:-${TRANSACTION_SNAPSHOT_DIR:-}} ]] || return 1
    printf '%s/%s\n' "${PENDING_TRANSACTION_SNAPSHOT_DIR:-$TRANSACTION_SNAPSHOT_DIR}" "$LEAP16_R34_FIRMWARE_BASELINE"
}

# Accept old r32/r33 markers for exact stale-candidate cleanup and for reading a
# currently staged r33 transaction, while writing only the r34 marker.
leap16_r33_switcher_entry_marker() {
    local path=$1 first
    first=$(leap16_r32_sdboot_read "$path" 2>/dev/null | head -n1 || true)
    [[ $first == "$LEAP16_R33_R32_MARKER" \
       || $first == "$LEAP16_R33_R33_MARKER" \
       || $first == "$LEAP16_R34_SDBOOT_MARKER" ]]
}

leap16_r34_default_entry_name() {
    collect_kernels
    ((${#KERNEL_VERSIONS[@]} > 0)) || return 1
    printf 'opensuse-%s.conf\n' "${KERNEL_VERSIONS[0]}"
}

# New r34 ownership has only real per-kernel BLS entries.  The old
# opensuse-current.conf alias remains understood by the legacy validator below
# so an r33 transaction can be inspected/rolled back exactly, but r34 never
# creates or claims a new alias.
leap16_r32_systemd_owned_paths() {
    local ver root
    root=$(leap16_r32_sdboot_payload_root) || return 1
    printf '%s\n' "${ESP_MOUNT%/}/EFI/systemd" "${ESP_MOUNT%/}/loader/loader.conf" "$root"
    collect_kernels
    for ver in "${KERNEL_VERSIONS[@]}"; do
        leap16_r32_sdboot_entry_path "$ver"
    done
}

# Preserve the exact boot-critical fields from r33, but let systemd-boot do the
# intended title/version rendering itself.  This removes both the duplicate
# version text and the duplicate newest-kernel menu item.
leap16_r32_write_systemd_boot_candidate() {
    local reference=$1 binary root ver src_kernel src_initrd entry tmp options relroot default
    binary=$(leap16_r32_find_systemd_boot_binary) || return 1
    root=$(leap16_r32_sdboot_payload_root) || return 1
    relroot="/${root#${ESP_MOUNT%/}/}"
    options=$(leap16_r32_portable_cmdline "$reference")
    [[ -n $options ]] || { fail 'Could not derive a portable systemd-boot kernel command line'; return 1; }

    sudo install -d -m 0755 -- "${ESP_MOUNT%/}/EFI/systemd" "${ESP_MOUNT%/}/loader/entries" "$root" || return 1
    sudo install -m 0644 -- "$binary" "${ESP_MOUNT%/}/EFI/systemd/systemd-bootx64.efi" || return 1

    collect_kernels
    ((${#KERNEL_VERSIONS[@]} > 0)) || { fail 'No installed kernels were discovered while writing systemd-boot entries'; return 1; }
    default="opensuse-${KERNEL_VERSIONS[0]}.conf"
    for ver in "${KERNEL_VERSIONS[@]}"; do
        src_kernel="/boot/vmlinuz-$ver"; src_initrd="/boot/initrd-$ver"
        [[ -f $src_kernel && -f $src_initrd ]] || { fail "Missing complete /boot kernel/initrd pair for $ver"; return 1; }
        sudo install -d -m 0755 -- "$root/$ver" || return 1
        sudo install -m 0644 -- "$src_kernel" "$root/$ver/linux" || return 1
        sudo install -m 0644 -- "$src_initrd" "$root/$ver/initrd" || return 1
        entry=$(leap16_r32_sdboot_entry_path "$ver")
        tmp=$(mktemp) || return 1
        cat >"$tmp" <<ENTRY
$LEAP16_R34_SDBOOT_MARKER
title openSUSE Leap 16
version $ver
sort-key opensuse
linux $relroot/$ver/linux
initrd $relroot/$ver/initrd
options $options
ENTRY
        sudo install -m 0644 -- "$tmp" "$entry" || { rm -f -- "$tmp"; return 1; }
        rm -f -- "$tmp"
    done

    # Defensive cleanup is allowed here only because target-namespace preflight
    # has already proven any same-name legacy alias is switcher-owned residue.
    sudo rm -f -- "${ESP_MOUNT%/}/loader/entries/opensuse-current.conf" 2>/dev/null || true

    tmp=$(mktemp) || return 1
    cat >"$tmp" <<LOADER
$LEAP16_R34_SDBOOT_MARKER
default $default
timeout 5
console-mode keep
editor no
LOADER
    sudo install -m 0644 -- "$tmp" "${ESP_MOUNT%/}/loader/loader.conf" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
}

leap16_r34_validate_systemd_boot_chain() {
    local mode=${1:-current} failures=0 reference rootarg mountmode token
    local ver entry linux initrd options payload_root default expected_default marker title version sortkey opt_mode
    local legacy_alias="${ESP_MOUNT%/}/loader/entries/opensuse-current.conf" legacy=0 first_entry
    printf '\nDeep openSUSE systemd-boot boot-chain validation (%s):\n' "$mode"

    [[ -n ${ESP_MOUNT:-} ]] || { fail 'ESP mountpoint is unavailable'; return 1; }
    reference=${PENDING_SOURCE_CMDLINE:-$(cat /proc/cmdline 2>/dev/null || true)}
    [[ -n $reference ]] || { fail 'Could not capture reference kernel command line'; return 1; }

    local canonical loader
    canonical=$(resolve_efi_path_on_esp_privileged "$LEAP16_R32_SDBOOT_EFI" 2>/dev/null || true)
    [[ -n $canonical ]] && ok "Canonical systemd-boot EFI exists: $canonical" || { fail 'Canonical systemd-boot EFI is missing'; ((failures++)); }

    collect_kernels
    ((${#KERNEL_VERSIONS[@]} > 0)) || { fail 'No installed kernels were discovered'; return 1; }
    expected_default="opensuse-${KERNEL_VERSIONS[0]}.conf"
    loader="${ESP_MOUNT%/}/loader/loader.conf"
    if sudo -n test -f "$loader" 2>/dev/null || [[ -f $loader ]]; then
        default=$(leap16_r32_sdboot_read "$loader" | awk '$1=="default"{print $2;exit}')
        marker=$(leap16_r32_sdboot_read "$loader" | head -n1 || true)
        if [[ $default == opensuse-current.conf ]]; then
            legacy=1
            [[ $marker == "$LEAP16_R33_R32_MARKER" || $marker == "$LEAP16_R33_R33_MARKER" ]] \
                && ok 'loader.conf is the exact legacy r32/r33 layout (accepted only for inspection/rollback)' \
                || { fail 'Legacy current-alias loader.conf has no r32/r33 ownership marker'; ((failures++)); }
        elif [[ $default == "$expected_default" ]]; then
            [[ $marker == "$LEAP16_R34_SDBOOT_MARKER" ]] \
                && ok "loader.conf selects the real newest kernel entry directly: $expected_default" \
                || { fail 'r34 loader.conf default is correct but its ownership marker is not'; ((failures++)); }
        else
            fail "Unexpected systemd-boot default entry: ${default:-unset} (expected $expected_default)"; ((failures++))
        fi
    else
        fail 'systemd-boot loader.conf is missing'; ((failures++))
    fi

    rootarg=''; mountmode=''
    for token in $reference; do
        [[ $token == root=* && -z $rootarg ]] && rootarg=$token
        [[ ( $token == rw || $token == ro ) && -z $mountmode ]] && mountmode=$token
    done
    [[ -n $rootarg ]] || { fail 'Reference cmdline has no root= token'; ((failures++)); }
    if [[ -n $mountmode ]]; then
        ok "Reference cmdline explicitly carries $mountmode; candidate entries must preserve it"
    else
        ok 'Reference cmdline has no explicit rw/ro token; candidate entries must preserve that omission'
    fi

    payload_root=$(leap16_r32_sdboot_payload_root) || { fail 'Machine ID is unavailable'; return 1; }
    for ver in "${KERNEL_VERSIONS[@]}"; do
        entry=$(leap16_r32_sdboot_entry_path "$ver")
        if ! sudo -n test -f "$entry" 2>/dev/null && [[ ! -f $entry ]]; then
            fail "Missing BLS entry for kernel $ver"; ((failures++)); continue
        fi
        marker=$(leap16_r32_sdboot_read "$entry" | head -n1 || true)
        title=$(leap16_r32_sdboot_field "$entry" title 2>/dev/null || true)
        version=$(leap16_r32_sdboot_field "$entry" version 2>/dev/null || true)
        sortkey=$(leap16_r32_sdboot_field "$entry" sort-key 2>/dev/null || true)
        linux=$(leap16_r32_sdboot_field "$entry" linux 2>/dev/null || true)
        initrd=$(leap16_r32_sdboot_field "$entry" initrd 2>/dev/null || true)
        options=$(leap16_r32_sdboot_field "$entry" options 2>/dev/null || true)

        if [[ $marker == "$LEAP16_R34_SDBOOT_MARKER" ]]; then
            [[ $title == 'openSUSE Leap 16' ]] && ok "$ver title delegates version rendering to systemd-boot" || { fail "$ver has unexpected r34 title: ${title:-unset}"; ((failures++)); }
            [[ $version == "$ver" ]] || { fail "$ver BLS version field is wrong: ${version:-unset}"; ((failures++)); }
            [[ $sortkey == opensuse ]] || { fail "$ver BLS sort-key is wrong: ${sortkey:-unset}"; ((failures++)); }
        elif [[ $marker == "$LEAP16_R33_R32_MARKER" || $marker == "$LEAP16_R33_R33_MARKER" ]]; then
            [[ $title == "openSUSE Leap 16 ($ver)" && $version == "$ver" ]] || { fail "$ver legacy BLS identity is not the exact r32/r33 shape"; ((failures++)); }
        else
            fail "$ver BLS entry is outside switcher ownership"; ((failures++))
        fi

        [[ $linux == "/${payload_root#${ESP_MOUNT%/}/}/$ver/linux" ]] \
            && (sudo -n test -f "${ESP_MOUNT%/}/${linux#/}" 2>/dev/null || [[ -f ${ESP_MOUNT%/}/${linux#/} ]]) \
            && ok "$ver kernel payload is exact and present" \
            || { fail "$ver kernel payload path is missing/incorrect (${linux:-unset})"; ((failures++)); }
        [[ $initrd == "/${payload_root#${ESP_MOUNT%/}/}/$ver/initrd" ]] \
            && (sudo -n test -f "${ESP_MOUNT%/}/${initrd#/}" 2>/dev/null || [[ -f ${ESP_MOUNT%/}/${initrd#/} ]]) \
            && ok "$ver initrd payload is exact and present" \
            || { fail "$ver initrd payload path is missing/incorrect (${initrd:-unset})"; ((failures++)); }
        [[ -n $options ]] || { fail "$ver loader entry has no options line"; ((failures++)); continue; }
        if pending_cmdline_equivalent "$reference" "$options"; then
            ok "$ver options are token-equivalent to the proven source cmdline"
        else
            fail "$ver options are not token-equivalent to the proven source cmdline"
            printf '       reference: %s\n' "$reference"
            printf '       candidate: %s\n' "$options"
            ((failures++))
        fi
        if [[ -z $mountmode ]]; then
            opt_mode=''
            for token in $options; do [[ ( $token == rw || $token == ro ) && -z $opt_mode ]] && opt_mode=$token; done
            [[ -z $opt_mode ]] || { fail "$ver candidate invented mount-mode token $opt_mode absent from the source"; ((failures++)); }
        fi
    done

    first_entry=$(leap16_r32_sdboot_entry_path "${KERNEL_VERSIONS[0]}")
    if ((legacy)); then
        if sudo -n test -f "$legacy_alias" 2>/dev/null || [[ -f $legacy_alias ]]; then
            cmp -s <(leap16_r32_sdboot_read "$legacy_alias") <(leap16_r32_sdboot_read "$first_entry") \
                && ok 'Legacy opensuse-current.conf is byte-identical to the newest real kernel entry' \
                || { fail 'Legacy opensuse-current.conf is not byte-identical to the newest real kernel entry'; ((failures++)); }
        else
            fail 'Legacy loader.conf selects opensuse-current.conf but that alias is missing'; ((failures++))
        fi
    else
        if sudo -n test -e "$legacy_alias" 2>/dev/null || [[ -e $legacy_alias ]]; then
            fail 'r34 layout must not contain the duplicate opensuse-current.conf alias'; ((failures++))
        else
            ok 'No duplicate opensuse-current.conf BLS alias exists'
        fi
    fi

    if have bootctl; then
        bootctl --esp-path="$ESP_MOUNT" status >/dev/null 2>&1 || sudo -n bootctl --esp-path="$ESP_MOUNT" status >/dev/null 2>&1 || warn 'bootctl could not inspect the staged ESP from this session'
    fi
    printf '  Summary: %d failure(s)\n' "$failures"
    ((failures == 0))
}

# r33 already overrides the adapter validator. Replace only the systemd-boot
# implementation beneath that contract.
leap16_r33_validate_systemd_boot_chain() { leap16_r34_validate_systemd_boot_chain "$@"; }

# Every new r34 GRUB2 -> systemd-boot transaction records the complete firmware
# table before target staging.  This is deliberately outside pending.tsv so old
# format-5 parsers remain strict and compatible.
eval "$(declare -f adapter_source_snapshot | sed '1s/adapter_source_snapshot/adapter_source_snapshot_pre_leap16_r34/')"
adapter_source_snapshot() {
    local source=$1 baseline
    adapter_source_snapshot_pre_leap16_r34 "$@" || return $?
    [[ $source == grub ]] || return 0
    baseline="$TRANSACTION_SNAPSHOT_DIR/$LEAP16_R34_FIRMWARE_BASELINE"
    efibootmgr -v >"$baseline" || { fail 'Could not record the pre-stage firmware baseline for GRUB2 retirement ownership'; return 1; }
    chmod 600 -- "$baseline" 2>/dev/null || true
    grep -Eq '^BootCurrent:[[:space:]]+' "$baseline" || { fail 'Pre-stage firmware baseline is incomplete'; return 1; }
    ok 'Recorded the complete pre-stage firmware table for future ownership-gated GRUB2 alias retirement'
}

leap16_r34_source_grub_ids_from_baseline() {
    local baseline line id path norm partuuid lower saw_source=0 count=0
    baseline=$(leap16_r34_baseline_path) || return 1
    [[ -s $baseline ]] || { fail 'r34 source firmware baseline is missing; this older candidate is not eligible for GRUB2 retirement'; return 1; }
    partuuid=$(lsblk -no PARTUUID -- "$PENDING_ESP_SOURCE" 2>/dev/null | awk 'NF{print tolower($1); exit}')
    while IFS= read -r line; do
        [[ $line =~ ^Boot([0-9A-Fa-f]{4})\*? ]] || continue
        id=${BASH_REMATCH[1]^^}
        path=$(efi_path_from_efibootmgr_line "$line" 2>/dev/null || true)
        [[ -n $path ]] || continue
        norm=$(normalize_efi_path "$path" | tr '[:upper:]' '[:lower:]')
        case "$norm" in efi/opensuse/shim.efi|efi/opensuse/grubx64.efi|efi/opensuse/grub.efi) ;; *) continue ;; esac
        lower=${line,,}
        [[ -z $partuuid || $lower == *"$partuuid"* ]] || continue
        [[ $id == ${PENDING_OLD_BOOT_ID^^} ]] && saw_source=1
        printf '%s\n' "$id"
        count=$((count + 1))
    done <"$baseline"
    ((count > 0 && saw_source == 1)) || { fail 'Could not derive an exact GRUB2 NVRAM ownership set from the r34 firmware baseline'; return 1; }
}

leap16_r34_verify_source_grub_ids() {
    local id path baseline_ids current_ids
    local raw
    raw=$(leap16_r34_source_grub_ids_from_baseline) || return 1
    baseline_ids=$(awk '/^[0-9A-F]{4}$/{print}' <<<"$raw" | LC_ALL=C sort -u | paste -sd, -)
    [[ -n $baseline_ids ]] || return 1
    IFS=',' read -ra _r34_ids <<<"$baseline_ids"
    for id in "${_r34_ids[@]}"; do
        boot_id_exists "$id" || { fail "Ownership-proven GRUB2 Boot$id disappeared before retirement"; return 1; }
        leap16_nvram_entry_matches_current_esp "$id" || { fail "Ownership-proven GRUB2 Boot$id is no longer bound to the transaction ESP"; return 1; }
        path=$(leap16_boot_entry_line_for_id "$id" | { read -r line; efi_path_from_efibootmgr_line "$line" 2>/dev/null || true; })
        case "$(normalize_efi_path "$path" | tr '[:upper:]' '[:lower:]')" in efi/opensuse/shim.efi|efi/opensuse/grubx64.efi|efi/opensuse/grub.efi) ;; *) fail "Ownership-proven GRUB2 Boot$id changed EFI path"; return 1 ;; esac
    done
    ok "r34 firmware baseline still owns native GRUB2 alias(es): Boot${baseline_ids//,/ Boot}"
}

leap16_r34_target_first_keep_recovery() {
    local target=${PENDING_TARGET_BOOT_ID^^} order id joined
    local -a out=("$target") ids=()
    order=$(leap16_current_boot_order 2>/dev/null || true)
    [[ -n $order ]] || return 1
    IFS=',' read -ra ids <<<"$order"
    for id in "${ids[@]}"; do
        id=${id^^}; [[ -n $id && $id != "$target" ]] || continue
        boot_id_exists "$id" && out+=("$id")
    done
    joined=$(IFS=,; printf '%s' "${out[*]}")
    sudo efibootmgr -o "$joined" >/dev/null || return 1
    [[ $(pending_bootorder_first) == "$target" ]]
}

leap16_r34_transfer_systemd_fallback() {
    local fallback="$PENDING_ESP_MOUNT/EFI/BOOT/BOOTX64.EFI" hash
    if [[ $PENDING_OLD_FALLBACK_EXISTED == 1 && $PENDING_SOURCE_FALLBACK_OWNED != 1 ]]; then
        hash=$(sudo -n sha256sum -- "$fallback" 2>/dev/null | awk '{print $1}' || true)
        [[ $hash == "$PENDING_OLD_FALLBACK_HASH" ]] || { fail 'Unrelated generic EFI fallback changed before systemd-boot finalization'; return 1; }
        info 'Preserving unrelated pre-existing EFI/BOOT/BOOTX64.EFI; canonical systemd-boot NVRAM remains authoritative.'
        return 0
    fi
    sudo mkdir -p -- "$(dirname -- "$fallback")" || return 1
    sudo install -m 0644 -- "$PENDING_TARGET_EFI_RESOLVED" "$fallback" || return 1
    hash=$(sudo -n sha256sum -- "$fallback" 2>/dev/null | awk '{print $1}' || true)
    [[ $hash == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'Could not materialize byte-identical systemd-boot generic fallback'; return 1; }
    ok 'Transferred the generic EFI fallback to byte-identical systemd-boot only after runtime proof and persistent promotion'
}

leap16_r34_remove_grub_source_files_efi_first() {
    local record=$PENDING_SOURCE_MANIFEST kind path identity have_grub=0 have_efi=0 have_default=0
    r26_verify_owned_manifest "$record" || return 1
    while IFS=$'\t' read -r kind path identity; do
        case "$path" in
            /boot/grub2) have_grub=1 ;;
            "$PENDING_ESP_MOUNT/EFI/OPENSUSE") have_efi=1 ;;
            /etc/default/grub) have_default=1 ;;
            *) fail "Unexpected GRUB2 source ownership path in adapter manifest: $path"; return 1 ;;
        esac
    done <"$record"
    ((have_grub == 1 && have_efi == 1 && have_default == 1)) || { fail 'GRUB2 source ownership manifest is incomplete for r34 retirement'; return 1; }

    sudo rm -rf -- "$PENDING_ESP_MOUNT/EFI/OPENSUSE" || return 1
    ok 'Removed ownership-proven EFI/OPENSUSE before the final GRUB NVRAM alias sweep'
    sudo rm -rf -- /boot/grub2 || return 1
    ok 'Removed ownership-proven /boot/grub2 tree'
    sudo rm -f -- /etc/default/grub || return 1
    ok 'Removed ownership-proven /etc/default/grub'
}

leap16_r34_sweep_native_grub_aliases() {
    local pass csv id
    for pass in 1 2 3; do
        csv=$(r21_current_native_grub_ids | awk 'NF{print toupper($0)}' | LC_ALL=C sort -u | paste -sd, -)
        [[ -n $csv ]] || { ok 'Final same-ESP native GRUB2 NVRAM alias sweep is empty'; return 0; }
        IFS=',' read -ra _r34_ids <<<"$csv"
        for id in "${_r34_ids[@]}"; do
            leap16_nvram_entry_matches_current_esp "$id" || { fail "Refusing to remove Boot$id because its ESP ownership changed"; return 1; }
            sudo efibootmgr -b "$id" -B >/dev/null || { fail "Could not remove native GRUB2 alias Boot$id"; return 1; }
            ok "Removed path/ESP-owned native GRUB2 alias Boot$id"
        done
    done
    csv=$(r21_current_native_grub_ids | awk 'NF{print toupper($0)}' | LC_ALL=C sort -u | paste -sd, -)
    [[ -z $csv ]] || { fail "Native GRUB2 aliases remain after repeated final sweep: Boot${csv//,/ Boot}"; return 1; }
}

leap16_r34_set_loader_policy_systemd() {
    local tmp
    [[ -f /etc/sysconfig/bootloader ]] || return 0
    tmp=$(mktemp) || return 1
    awk 'BEGIN{done=0} /^[[:space:]]*LOADER_TYPE=/ {print "LOADER_TYPE=systemd-boot"; done=1; next} {print} END{if(!done) print "LOADER_TYPE=systemd-boot"}' /etc/sysconfig/bootloader >"$tmp" || { rm -f -- "$tmp"; return 1; }
    sudo install -m 0644 -- "$tmp" /etc/sysconfig/bootloader || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
    ok 'Updated openSUSE bootloader policy to LOADER_TYPE=systemd-boot after exact runtime proof'
}

leap16_r34_validate_systemd_runtime() {
    validate_pending_compatibility || { fail "Pending migration is not compatible: $PENDING_REASON"; return 1; }
    leap16_r34_sdboot_pending || { fail 'r34 systemd runtime proof requires GRUB2 -> systemd-boot format-5 state'; return 1; }
    [[ $PENDING_PHASE == boot-armed || $PENDING_PHASE == runtime-validated ]] || { fail "Runtime validation requires boot-armed/runtime-validated state (phase is $PENDING_PHASE)"; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == systemd-boot ]] || { fail "Current bootloader is $(bootloader_display_name "$BOOTLOADER"), not systemd-boot"; return 1; }
    [[ ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail "Runtime proof requires BootCurrent=Boot$PENDING_TARGET_BOOT_ID (found Boot${BOOT_CURRENT:-unknown})"; return 1; }
    nvram_id_matches_path "$PENDING_TARGET_BOOT_ID" "$PENDING_TARGET_EFI_PATH" || { fail 'BootCurrent systemd-boot NVRAM path changed'; return 1; }
    leap16_nvram_entry_matches_current_esp "$PENDING_TARGET_BOOT_ID" || { fail 'BootCurrent systemd-boot entry is no longer bound to the transaction ESP'; return 1; }
    leap16_require_sudo_session || return 1

    local next first diag
    run_validation preflight || return 1
    next=$(pending_bootnext_id)
    if [[ -n $next && ${next^^} != ${PENDING_TARGET_BOOT_ID^^} ]]; then
        fail "BootNext belongs to unrelated Boot$next; refusing runtime certification"; return 1
    elif [[ ${next^^} == ${PENDING_TARGET_BOOT_ID^^} ]]; then
        warn "Firmware still reports consumed transaction BootNext=Boot$next; clearing it"
        sudo efibootmgr -N >/dev/null || return 1
        [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext remained set after explicit clear'; return 1; }
    else
        ok 'BootNext was consumed/cleared by firmware after the one-time systemd-boot boot'
    fi
    first=$(pending_bootorder_first)
    [[ ${first^^} == ${PENDING_OLD_BOOT_ID^^} ]] || { fail "Persistent BootOrder drifted; expected GRUB2 source Boot$PENDING_OLD_BOOT_ID first, found Boot${first:-unknown}"; return 1; }
    ok "Persistent BootOrder still keeps GRUB2 source Boot$PENDING_OLD_BOOT_ID first"

    pending_validate_running_kernel || return 1
    pending_validate_runtime_cmdline_against_source || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1
    verify_pending_source_recovery_unchanged || return 1

    pending_set_phase runtime-validated || { fail 'Runtime checks passed but runtime-validated phase could not be persisted'; return 1; }
    PENDING_PHASE=runtime-validated
    diag=$(pending_capture_runtime_diagnostics runtime-pass | tail -n1 || true)
    [[ -n $diag ]] && printf 'Runtime diagnostic snapshot: %s\n' "$diag"
    printf '\nRUNTIME-VALIDATED GRUB2 -> systemd-boot one-shot boot succeeded.\n'
    printf '  BootCurrent: Boot%s -> %s\n' "$PENDING_TARGET_BOOT_ID" "$PENDING_TARGET_EFI_PATH"
    printf '  BootNext: clear\n'
    printf '  Persistent BootOrder: GRUB2 remains first until finalization\n'
}

eval "$(declare -f validate_pending_target_runtime | sed '1s/validate_pending_target_runtime/validate_pending_target_runtime_pre_leap16_r34/')"
validate_pending_target_runtime() {
    if leap16_r34_sdboot_pending; then
        leap16_r34_validate_systemd_runtime
    else
        validate_pending_target_runtime_pre_leap16_r34 "$@"
    fi
}

leap16_r34_finalize_grub_to_systemd() {
    validate_pending_compatibility || { fail "Pending migration is not compatible: $PENDING_REASON"; return 1; }
    leap16_r34_sdboot_pending || { fail 'r34 finalizer is restricted to GRUB2 -> systemd-boot'; return 1; }
    [[ $PENDING_PHASE == runtime-validated ]] || { fail 'Finalization requires runtime-validated systemd-boot state'; return 1; }
    [[ -s $(leap16_r34_baseline_path 2>/dev/null || printf /nonexistent) ]] || {
        fail 'This candidate predates r34 and has no complete pre-stage firmware baseline.'
        fail 'GRUB2 retirement is intentionally locked. Reboot normally to GRUB2, roll back this candidate, then restage with r34.'
        return 1
    }
    detect_bootloader
    [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail 'Finalization must run from the exact runtime-proven systemd-boot target session'; return 1; }
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext must be clear before persistent finalization'; return 1; }
    run_validation preflight || return 1
    pending_validate_running_kernel || return 1
    pending_validate_runtime_cmdline_against_source || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    leap16_r34_validate_systemd_boot_chain runtime || return 1
    verify_pending_source_recovery_unchanged || return 1
    leap16_r34_verify_source_grub_ids || return 1

    printf '\nFINALIZE hardware-proven GRUB2 -> systemd-boot:\n'
    printf '  - promote Boot%s first while retaining every GRUB2 recovery alias during the promotion gate\n' "$PENDING_TARGET_BOOT_ID"
    printf '  - transfer generic EFI fallback only after promotion and exact runtime proof\n'
    printf '  - remove ownership-proven EFI/OPENSUSE first, then sweep same-ESP GRUB aliases\n'
    printf '  - remove /boot/grub2 and /etc/default/grub only from their recorded source manifest\n'

    leap16_r34_target_first_keep_recovery || { fail 'Could not promote systemd-boot while retaining source recovery aliases'; return 1; }
    verify_pending_candidate_ownership_unchanged || { fail 'Target changed after promotion; no GRUB cleanup was attempted'; return 1; }
    leap16_r34_validate_systemd_boot_chain target || { fail 'Target validation failed after promotion; no GRUB cleanup was attempted'; return 1; }
    verify_pending_source_recovery_unchanged || { fail 'GRUB2 recovery changed after promotion; no cleanup was attempted'; return 1; }
    leap16_r34_verify_source_grub_ids || return 1

    leap16_r34_transfer_systemd_fallback || return 1
    # Verify the manifest one final time before deleting any source-owned bytes.
    r26_verify_owned_manifest "$PENDING_SOURCE_MANIFEST" || return 1
    leap16_r34_remove_grub_source_files_efi_first || return 1
    leap16_r34_sweep_native_grub_aliases || return 1
    leap16_r34_set_loader_policy_systemd || return 1

    detect_bootloader
    [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail 'Target identity changed during finalization'; return 1; }
    [[ $(pending_bootorder_first) == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail 'systemd-boot is not first in persistent BootOrder after GRUB2 retirement'; return 1; }
    [[ -z $(r21_current_native_grub_ids | awk 'NF') ]] || { fail 'A same-ESP native GRUB2 NVRAM alias remains after retirement'; return 1; }
    [[ ! -e /boot/grub2 && ! -e /etc/default/grub ]] || { fail 'Native GRUB2 filesystem state remains after retirement'; return 1; }
    sudo -n test ! -e "$PENDING_ESP_MOUNT/EFI/OPENSUSE" 2>/dev/null || { fail 'EFI/OPENSUSE remains after retirement'; return 1; }
    [[ $(sudo -n sha256sum -- "$PENDING_ESP_MOUNT/EFI/BOOT/BOOTX64.EFI" 2>/dev/null | awk '{print $1}') == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'Final generic EFI fallback is not byte-identical to the proven systemd-boot EFI'; return 1; }
    validate_target_state systemd-boot || return 1
    leap16_r34_validate_systemd_boot_chain final || return 1

    pending_capture_runtime_diagnostics finalized-systemd-boot >/dev/null 2>&1 || true
    remove_pending_transaction_snapshot || warn 'Could not remove private transaction snapshot after successful finalization'
    rm -f -- "$PENDING_STATE_FILE"
    printf '\nFINALIZED GRUB2 -> systemd-boot successfully.\n'
    printf 'systemd-boot Boot%s is persistent first; native GRUB2 aliases/files are retired and EFI/BOOT is systemd-boot-owned.\n' "$PENDING_TARGET_BOOT_ID"
    return 0
}

# Do not let the generic r26 finalizer retire only BootCurrent while leaving the
# direct openSUSE GRUB alias orphaned.  Every other adapter direction delegates.
eval "$(declare -f r26_finalize_adapter_transaction | sed '1s/r26_finalize_adapter_transaction/r26_finalize_adapter_transaction_pre_leap16_r34/')"
r26_finalize_adapter_transaction() {
    if leap16_r34_sdboot_pending; then
        leap16_r34_finalize_grub_to_systemd
    else
        r26_finalize_adapter_transaction_pre_leap16_r34 "$@"
    fi
}

# Automatic root continuation for format-5 GRUB2 -> systemd-boot.  r33 fell
# through to the older forward Limine resume here, producing the exact observed
# "Current bootloader is systemd-boot, not Limine" failure.
leap16_r34_resume_systemd_root() {
    r22_root_bundle_preflight || return 1
    local bundle=$R22_RESUME_BUNDLE conf="$R22_RESUME_BUNDLE/resume.conf" detail
    mkdir -p -- "$bundle/diagnostics" || return 1
    LEAP16_DIAGNOSTIC_ROOT="$bundle/diagnostics" LEAP16_AUTO_RESUME=1
    export LEAP16_DIAGNOSTIC_ROOT LEAP16_AUTO_RESUME
    exec > >(tee -a "$bundle/automatic-resume.log") 2>&1
    printf 'openSUSE Bootloader Switcher %s automatic GRUB2 -> systemd-boot resume\nBundle: %s\n' "${SWITCHER_RELEASE:-leap16-r34}" "$bundle"

    load_pending_state || { r22_write_user_result "$conf" failed "Invalid root-owned systemd-boot pending state: $PENDING_REASON" || true; r22_remove_resume_service_files; return 1; }
    validate_pending_compatibility || { r22_write_user_result "$conf" failed "systemd-boot resume transaction is incompatible: $PENDING_REASON" || true; r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true; r22_remove_resume_service_files; return 1; }
    detect_bootloader
    if [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == ${PENDING_OLD_BOOT_ID^^} ]]; then
        printf 'Automatic systemd-boot resume: firmware returned to the recorded GRUB2 source; no target proof/finalization allowed.\n'
        r22_resume_source_fallback "$conf" || return 1
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" safe-fallback || true
        return 0
    fi
    [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || {
        leap16_capture_diagnostics auto-resume-unexpected-bootcurrent >/dev/null 2>&1 || true
        r22_write_user_result "$conf" failed 'systemd-boot automatic resume saw an unexpected BootCurrent/loader identity; no promotion/retirement occurred.' || true
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
        r22_remove_resume_service_files
        return 1
    }

    case "$PENDING_PHASE" in
        boot-armed)
            leap16_r34_validate_systemd_runtime || {
                r22_write_user_result "$conf" failed 'systemd-boot booted, but exact runtime proof failed; persistent promotion/GRUB2 retirement were NOT attempted.' || true
                leap16_capture_diagnostics auto-resume-runtime-failed >/dev/null 2>&1 || true
                r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
                r22_remove_resume_service_files
                return 1
            }
            PENDING_PHASE=runtime-validated
            r22_sync_user_phase_from_root "$conf" runtime-validated || true
            ;;
        runtime-validated) printf 'Automatic systemd-boot resume: runtime proof already persisted; continuing finalization.\n' ;;
        *) r22_write_user_result "$conf" failed "Unexpected systemd-boot automatic-resume phase: $PENDING_PHASE" || true; r22_remove_resume_service_files; return 1 ;;
    esac

    if ! leap16_r34_finalize_grub_to_systemd; then
        r22_write_user_result "$conf" failed 'systemd-boot runtime proof passed, but ownership-gated GRUB2 retirement/finalization failed. No unproven cleanup is permitted.' || true
        leap16_capture_diagnostics auto-resume-finalization-failed >/dev/null 2>&1 || true
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
        r22_remove_resume_service_files
        return 1
    fi

    leap16_capture_diagnostics auto-resume-pass >/dev/null 2>&1 || true
    r13_sync_root_diagnostics_to_user "$conf" "$bundle" success || true
    detail="GRUB2 -> systemd-boot automated runtime proof and finalization succeeded. systemd-boot Boot$PENDING_TARGET_BOOT_ID is first; ownership-proven native GRUB2 aliases/files were retired and EFI/BOOT was transferred to systemd-boot."
    r22_cleanup_user_shadow_after_success "$conf"
    r22_write_user_result "$conf" success "$detail" || true
    r22_remove_resume_service_files
    rm -rf -- "$bundle" 2>/dev/null || true
    return 0
}

eval "$(declare -f r22_resume_transaction_root | sed '1s/r22_resume_transaction_root/r22_resume_transaction_root_pre_leap16_r34/')"
r22_resume_transaction_root() {
    local src='' tgt=''
    if [[ -f ${PENDING_STATE_FILE:-/nonexistent} ]]; then
        src=$(awk -F'\t' '$1=="source"{print $2;exit}' "$PENDING_STATE_FILE" 2>/dev/null || true)
        tgt=$(awk -F'\t' '$1=="target"{print $2;exit}' "$PENDING_STATE_FILE" 2>/dev/null || true)
    fi
    if [[ $src:$tgt == grub:systemd-boot ]]; then
        leap16_r34_resume_systemd_root
    else
        r22_resume_transaction_root_pre_leap16_r34 "$@"
    fi
}

# Direction-correct pending UX for the new adapter edge.  The current r33
# hardware candidate can therefore be rolled back cleanly after returning to
# GRUB2, instead of being forced through Limine-specific wording/actions.
eval "$(declare -f pending_banner | sed '1s/pending_banner/pending_banner_pre_leap16_r34/')"
pending_banner() {
    if pending_exists && validate_pending_compatibility >/dev/null 2>&1 && leap16_r34_sdboot_pending; then
        detect_bootloader
        printf 'Pending/staged migration: GRUB2 -> systemd-boot  [%s]' "$PENDING_PHASE"
        case "$PENDING_PHASE:$BOOTLOADER" in
            candidate-ready:grub) printf '  [PARKED]\n' ;;
            boot-armed:grub) [[ -n ${BOOT_NEXT:-} ]] && printf '  [BootNext ARMED]\n' || printf '  [ONE-SHOT CONSUMED; SOURCE ACTIVE]\n' ;;
            boot-armed:systemd-boot) printf '  [SYSTEMD-BOOT ACTIVE; RUNTIME PROOF AVAILABLE]\n' ;;
            runtime-validated:systemd-boot) printf '  [SYSTEMD-BOOT RUNTIME PROVEN; FINALIZATION ELIGIBLE]\n' ;;
            *) printf '  [CURRENT: %s]\n' "$(bootloader_display_name "$BOOTLOADER")" ;;
        esac
        return 0
    fi
    pending_banner_pre_leap16_r34 "$@"
}

eval "$(declare -f manage_pending_migration | sed '1s/manage_pending_migration/manage_pending_migration_pre_leap16_r34/')"
manage_pending_migration() {
    pending_exists || { printf '\nNo pending/staged migration exists.\n'; return 0; }
    validate_pending_compatibility || { printf '\nPending migration state is invalid/incompatible: %s\n' "$PENDING_REASON"; return 1; }
    if ! leap16_r34_sdboot_pending; then
        manage_pending_migration_pre_leap16_r34 "$@"
        return $?
    fi
    detect_bootloader
    show_pending_details
    local choice next baseline
    baseline=$(leap16_r34_baseline_path 2>/dev/null || true)

    if [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == ${PENDING_OLD_BOOT_ID^^} ]]; then
        case "$PENDING_PHASE" in
            candidate-ready)
                printf '\nGRUB2 source is active and the systemd-boot candidate is parked.\n[1] Revalidate source + candidate\n[2] Arm systemd-boot + automatic resume\n[3] Roll back this exact candidate\n[4] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep ;;
                    2) [[ -s $baseline ]] || { fail 'This pre-r34 candidate lacks the firmware ownership baseline; roll it back and restage with r34.'; return 1; }; r23_arm_candidate_automatically && r22_prepare_resume_bundle && r23_prompt_reboot ;;
                    3) rollback_pending_candidate ;;
                    4|'') return 0 ;;
                    *) return 1 ;;
                esac
                ;;
            boot-armed)
                next=$(pending_bootnext_id)
                if [[ -z $next ]]; then
                    printf '\nThe one-shot was consumed and this GRUB2 source session is authoritative again.\n'
                    if [[ ! -s $baseline ]]; then printf 'This is the pre-r34 hardware candidate; it must be rolled back before the clean-menu r34 restage.\n'; fi
                    printf '[1] Return transaction to candidate-ready\n[2] Roll back this exact candidate\n[3] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in 1) pending_set_phase candidate-ready ;; 2) rollback_pending_candidate ;; 3|'') return 0 ;; *) return 1 ;; esac
                elif [[ ${next^^} == ${PENDING_TARGET_BOOT_ID^^} ]]; then
                    printf '\nOne-time systemd-boot BootNext is armed.\n[1] Revalidate ownership\n[2] Cancel BootNext back to candidate-ready\n[3] Roll back candidate\n[4] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in 1) verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep ;; 2) sudo efibootmgr -N >/dev/null && pending_set_phase candidate-ready && r22_disarm_user_resume_bundle ;; 3) rollback_pending_candidate ;; 4|'') return 0 ;; *) return 1 ;; esac
                else
                    fail "Unrelated BootNext=Boot$next exists"; return 1
                fi
                ;;
            runtime-validated)
                printf '\nRuntime proof is recorded but GRUB2 is active again. Re-arm only if this is an r34-baselined candidate.\n[1] Re-arm target\n[2] Roll back candidate\n[3] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in 1) [[ -s $baseline ]] || { fail 'Pre-r34 candidate cannot be re-armed for finalization; roll back/restage.'; return 1; }; pending_set_phase candidate-ready && load_pending_state && r23_arm_candidate_automatically && r22_prepare_resume_bundle && r23_prompt_reboot ;; 2) rollback_pending_candidate ;; 3|'') return 0 ;; *) return 1 ;; esac
                ;;
        esac
    elif [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]]; then
        case "$PENDING_PHASE" in
            boot-armed)
                printf '\nThe exact systemd-boot one-shot target is running.\n'
                if [[ ! -s $baseline ]]; then
                    printf 'This r33 candidate predates the r34 firmware ownership baseline. Runtime bootability is proven, but GRUB2 retirement is LOCKED.\n'
                    printf 'Reboot normally to GRUB2, then use this menu to roll back and restage with r34.\n'
                    printf '[1] Run read-only/exact runtime validation for evidence\n[2] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in 1) leap16_r34_validate_systemd_runtime ;; 2|'') return 0 ;; *) return 1 ;; esac
                else
                    printf '[1] Run exact runtime validation now\n[2] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in 1) leap16_r34_validate_systemd_runtime ;; 2|'') return 0 ;; *) return 1 ;; esac
                fi
                ;;
            runtime-validated)
                if [[ ! -s $baseline ]]; then
                    printf '\nThe pre-r34 target has runtime proof, but retirement is locked because its firmware ownership baseline is incomplete. Reboot to GRUB2 and roll back/restage.\n'
                    return 1
                fi
                printf '\nThis exact systemd-boot session has runtime proof and an r34 firmware baseline.\n[1] Re-run runtime validation\n[2] Finalize systemd-boot and retire exact GRUB2 source\n[3] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in 1) leap16_r34_validate_systemd_runtime ;; 2) leap16_r34_finalize_grub_to_systemd ;; 3|'') return 0 ;; *) return 1 ;; esac
                ;;
        esac
    else
        fail 'Current bootloader is neither the exact GRUB2 source nor exact systemd-boot target for this transaction'
        return 1
    fi
}
