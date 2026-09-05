#!/usr/bin/env bash

ROOT_SOURCE=""
ROOT_FSTYPE=""
ROOT_UUID=""
ESP_SOURCE=""
ESP_MOUNT=""
ESP_FSTYPE=""
ESP_UUID=""
ESP_PARTTYPE=""

resolve_uuid() {
    local dev=$1 value=""
    [[ -n $dev ]] || return 0

    # lsblk is normally usable by an unprivileged user and handles ordinary
    # block devices without requiring direct reads of the device node.
    if have lsblk; then
        value=$(lsblk -dnro UUID -- "$dev" 2>/dev/null | head -n1 || true)
        [[ -n $value ]] && { printf '%s\n' "$value"; return 0; }
    fi

    if have blkid; then
        value=$(blkid -s UUID -o value -- "$dev" 2>/dev/null || true)
        [[ -n $value ]] && { printf '%s\n' "$value"; return 0; }
    fi

    # Last read-only fallback: resolve the UUID symlink that points at dev.
    if [[ -d /dev/disk/by-uuid ]]; then
        local link target canonical
        canonical=$(readlink -f -- "$dev" 2>/dev/null || true)
        for link in /dev/disk/by-uuid/*; do
            [[ -e $link ]] || continue
            target=$(readlink -f -- "$link" 2>/dev/null || true)
            if [[ -n $canonical && $target == "$canonical" ]]; then
                basename -- "$link"
                return 0
            fi
        done
    fi
}

find_esp_from_mounts() {
    local mp src fstype parttype
    for mp in /boot /boot/efi /efi; do
        if findmnt -rn -M "$mp" >/dev/null 2>&1; then
            src=$(findmnt -rn -M "$mp" -o SOURCE 2>/dev/null || true)
            fstype=$(findmnt -rn -M "$mp" -o FSTYPE 2>/dev/null || true)
            parttype=""
            if [[ -n $src ]] && have lsblk; then
                parttype=$(lsblk -dnro PARTTYPE -- "$src" 2>/dev/null | head -n1 || true)
            fi
            if [[ ${parttype,,} == c12a7328-f81f-11d2-ba4b-00a0c93ec93b || ${fstype,,} =~ ^(vfat|fat|fat32)$ ]]; then
                ESP_SOURCE=$src
                ESP_MOUNT=$mp
                ESP_FSTYPE=$fstype
                ESP_PARTTYPE=$parttype
                ESP_UUID=$(resolve_uuid "$src")
                return 0
            fi
        fi
    done
    return 1
}

collect_storage_info() {
    ROOT_SOURCE=$(findmnt -rn -M / -o SOURCE 2>/dev/null || true)
    ROOT_FSTYPE=$(findmnt -rn -M / -o FSTYPE 2>/dev/null || true)
    ROOT_UUID=$(resolve_uuid "$ROOT_SOURCE")

    ESP_SOURCE="" ESP_MOUNT="" ESP_FSTYPE="" ESP_UUID="" ESP_PARTTYPE=""
    find_esp_from_mounts || true
}
