#!/usr/bin/env bash

# r32: tolerate refind-install leaving multiple identical mount layers on the
# already-mounted ESP, while refusing any genuinely ambiguous stacked ESP.
# Also re-prove the original ESP topology immediately after refind-install.

ESP_MOUNT_STACK_DEPTH=${ESP_MOUNT_STACK_DEPTH:-0}
ESP_DETECTION_REASON=${ESP_DETECTION_REASON:-}

r32_fstype_is_esp_compatible() {
    case "${1,,}" in
        vfat|fat|fat32) return 0 ;;
        *) return 1 ;;
    esac
}

r32_sources_equivalent() {
    local a=$1 b=$2 ca cb
    [[ -n $a && -n $b ]] || return 1
    [[ $a == "$b" ]] && return 0
    ca=$(readlink -f -- "$a" 2>/dev/null || true)
    cb=$(readlink -f -- "$b" 2>/dev/null || true)
    [[ -n $ca && -n $cb && $ca == "$cb" ]]
}

# Override the original storage helper. findmnt may legitimately report the
# same source mounted repeatedly at one target when an installer stacks an
# identical mount. We collapse only byte-for-byte-equivalent SOURCE/FSTYPE
# tuples. Distinct qualifying ESP tuples at the same mountpoint are ambiguous
# and are refused instead of picking one arbitrarily.
find_esp_from_mounts() {
    local mp line src fstype parttype raw_count
    local -a raw_rows=() unique_rows=() qualifying_rows=()

    ESP_MOUNT_STACK_DEPTH=0
    ESP_DETECTION_REASON=""

    for mp in /boot /boot/efi /efi; do
        raw_rows=()
        unique_rows=()
        qualifying_rows=()

        mapfile -t raw_rows < <(findmnt -ern -M "$mp" -o SOURCE,FSTYPE 2>/dev/null || true)
        ((${#raw_rows[@]})) || continue
        raw_count=${#raw_rows[@]}

        # Keep SOURCE/FSTYPE pairing intact while deduplicating identical rows.
        mapfile -t unique_rows < <(printf '%s\n' "${raw_rows[@]}" | awk 'NF >= 2 {print $1 "\t" $2}' | LC_ALL=C sort -u)

        for line in "${unique_rows[@]}"; do
            IFS=$'\t' read -r src fstype <<<"$line"
            [[ -n $src && -n $fstype ]] || continue
            parttype=""
            if have lsblk; then
                parttype=$(lsblk -dnro PARTTYPE -- "$src" 2>/dev/null | head -n1 || true)
            fi
            if [[ ${parttype,,} == c12a7328-f81f-11d2-ba4b-00a0c93ec93b ]] || r32_fstype_is_esp_compatible "$fstype"; then
                qualifying_rows+=("$src"$'\t'"$fstype"$'\t'"$parttype")
            fi
        done

        ((${#qualifying_rows[@]})) || continue
        # Only repeated *identical* mount rows are safe to collapse. If the
        # same target contains any distinct stacked mount identity (even a
        # non-ESP filesystem under/over the ESP), the live topology is
        # ambiguous and the switcher must not guess which layer owns /boot.
        if ((${#unique_rows[@]} > 1)); then
            ESP_DETECTION_REASON="multiple distinct mount identities are stacked at $mp"
            return 1
        fi

        IFS=$'\t' read -r src fstype parttype <<<"${qualifying_rows[0]}"
        ESP_SOURCE=$src
        ESP_MOUNT=$mp
        ESP_FSTYPE=$fstype
        ESP_PARTTYPE=$parttype
        ESP_UUID=$(resolve_uuid "$src")
        ESP_MOUNT_STACK_DEPTH=$raw_count
        return 0
    done

    ESP_DETECTION_REASON=${ESP_DETECTION_REASON:-'no mounted FAT/EFI System Partition candidate was found'}
    return 1
}

# Preserve the current release's storage reset semantics while resetting the
# new diagnostic fields as well.
collect_storage_info() {
    ROOT_SOURCE=$(findmnt -rn -M / -o SOURCE 2>/dev/null | head -n1 || true)
    ROOT_FSTYPE=$(findmnt -rn -M / -o FSTYPE 2>/dev/null | head -n1 || true)
    ROOT_UUID=$(resolve_uuid "$ROOT_SOURCE")

    ESP_SOURCE="" ESP_MOUNT="" ESP_FSTYPE="" ESP_UUID="" ESP_PARTTYPE=""
    ESP_MOUNT_STACK_DEPTH=0 ESP_DETECTION_REASON=""
    find_esp_from_mounts || true
}

r32_verify_refind_post_install_esp() {
    local expected_source=$1 expected_mount=$2 expected_fstype=$3 expected_uuid=$4

    collect_storage_info
    [[ -n ${ESP_SOURCE:-} && -n ${ESP_MOUNT:-} ]] || {
        fail "rEFInd installer post-check could not resolve the ESP${ESP_DETECTION_REASON:+: $ESP_DETECTION_REASON}"
        return 1
    }
    r32_sources_equivalent "$ESP_SOURCE" "$expected_source" || {
        fail "rEFInd installer changed the resolved ESP source ($expected_source -> $ESP_SOURCE); refusing to continue"
        return 1
    }
    [[ $ESP_MOUNT == "$expected_mount" ]] || {
        fail "rEFInd installer changed the ESP mountpoint ($expected_mount -> $ESP_MOUNT); refusing to continue"
        return 1
    }
    [[ ${ESP_FSTYPE,,} == "${expected_fstype,,}" ]] || {
        fail "rEFInd installer changed the ESP filesystem identity ($expected_fstype -> $ESP_FSTYPE); refusing to continue"
        return 1
    }
    [[ -n $ESP_UUID && $ESP_UUID == "$expected_uuid" ]] || {
        fail "rEFInd installer changed or obscured the ESP UUID ($expected_uuid -> ${ESP_UUID:-unresolved}); refusing to continue"
        return 1
    }

    if ((ESP_MOUNT_STACK_DEPTH > 1)); then
        info "rEFInd installer left $ESP_MOUNT_STACK_DEPTH identical mount layers at $ESP_MOUNT; source/filesystem/UUID identity is unchanged, so they are treated as one logical ESP."
    fi
    ok "rEFInd installer preserved the validated ESP topology ($ESP_SOURCE, $ESP_UUID at $ESP_MOUNT)"
}

# Override only rEFInd target staging. The r26 transaction choreography remains
# untouched; this adds a topology proof directly after the external installer.
r26_stage_refind_target() {
    local source_id=$1 original_order=$2 reference=$3 target_id
    local expected_source=$ESP_SOURCE expected_mount=$ESP_MOUNT expected_fstype=$ESP_FSTYPE expected_uuid=$ESP_UUID

    [[ -n $expected_source && -n $expected_mount && -n $expected_fstype && -n $expected_uuid ]] || {
        fail 'rEFInd staging requires a fully resolved ESP identity before refind-install'
        return 1
    }

    install_target_packages refind || return 1
    have refind-install || { fail 'refind-install is unavailable after package installation'; return 1; }
    sudo refind-install || return 1
    r32_verify_refind_post_install_esp "$expected_source" "$expected_mount" "$expected_fstype" "$expected_uuid" || return 1
    [[ -f "$ESP_MOUNT/EFI/refind/refind.conf" ]] || sudo -n test -f "$ESP_MOUNT/EFI/refind/refind.conf" 2>/dev/null || { fail 'refind-install did not create the expected refind.conf on the detected ESP'; return 1; }
    r26_patch_refind_config || return 1
    r26_write_refind_linux_conf "$reference" || return 1
    find_nvram_entry_for_target refind || { fail 'Could not find the canonical rEFInd NVRAM entry'; return 1; }
    target_id=$TARGET_NVRAM_ID
    set_source_first_boot_order "$source_id" "$target_id" "$original_order" || return 1
    r26_restore_source_fallback_after_target_stage || return 1
    adapter_target_validate refind || return 1
    r26_record_target_adapter refind || return 1
    R26_STAGED_TARGET_ID=${target_id^^}
    ok "Staged canonical rEFInd NVRAM target as Boot$R26_STAGED_TARGET_ID"
}
