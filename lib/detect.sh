#!/usr/bin/env bash

BOOT_CURRENT=""
BOOT_ORDER=""
BOOT_NEXT=""
BOOT_LABEL=""
BOOT_EFI_PATH=""
BOOTLOADER="unknown"
DETECTION_EVIDENCE=()

efi_path_from_efibootmgr_line() {
    local line=$1
    # efibootmgr may append optional binary data directly after the textual
    # EFI filename (for example \EFI\BOOT\BOOTX64.EFI0000424f). Match only
    # through the first .efi suffix so firmware optional data never becomes
    # part of the path used for identity/ownership checks.
    if [[ $line =~ (\\EFI\\[^[:space:]]*\.[Ee][Ff][Ii]) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

parse_efibootmgr() {
    BOOT_CURRENT="" BOOT_ORDER="" BOOT_NEXT="" BOOT_LABEL="" BOOT_EFI_PATH=""
    have efibootmgr || return 1
    local out current line
    out=$(efibootmgr -v 2>/dev/null) || return 1
    BOOT_CURRENT=$(awk -F': ' '/^BootCurrent:/ {print $2; exit}' <<<"$out")
    BOOT_ORDER=$(awk -F': ' '/^BootOrder:/ {print $2; exit}' <<<"$out")
    BOOT_NEXT=$(awk -F': ' '/^BootNext:/ {print $2; exit}' <<<"$out")
    current=${BOOT_CURRENT^^}
    [[ -n $current ]] || return 0
    line=$(awk -v id="$current" 'BEGIN{IGNORECASE=1} $0 ~ "^Boot" id {print; exit}' <<<"$out")
    [[ -n $line ]] || return 0
    BOOT_LABEL=$(sed -E 's/^Boot[0-9A-Fa-f]{4}\*?[[:space:]]*//' <<<"$line" | sed -E 's/[[:space:]]+HD\(.*$//' | sed -E 's/[[:space:]]+VenHw\(.*$//' | sed -E 's/[[:space:]]+File\(.*$//' | sed -E 's/[[:space:]]+$//')
    BOOT_EFI_PATH=$(efi_path_from_efibootmgr_line "$line" 2>/dev/null || true)
}

normalize_efi_path() {
    local efi=$1
    efi=${efi//\\//}
    efi=${efi#/}
    printf '%s\n' "$efi"
}

bootcurrent_is_generic_fallback() {
    local p
    p=$(normalize_efi_path "${BOOT_EFI_PATH:-}")
    [[ ${p,,} == efi/boot/bootx64.efi ]]
}

# Resolve a firmware EFI path against the detected ESP without privilege.
# This is safe for normal startup/reporting and must never trigger sudo.
resolve_efi_path_on_esp() {
    local efi=$1 rel candidate match
    [[ -n $ESP_MOUNT && -n $efi ]] || return 1

    rel=$(normalize_efi_path "$efi")
    [[ -n $rel ]] || return 1
    candidate="$ESP_MOUNT/$rel"

    if [[ -f $candidate ]]; then
        printf '%s\n' "$candidate"
        return 0
    fi

    match=$(find "$ESP_MOUNT" -xdev -type f -ipath "$candidate" -print -quit 2>/dev/null || true)
    if [[ -n $match ]]; then
        printf '%s\n' "$match"
        return 0
    fi

    return 1
}

# Privileged verification is a separate, explicit preflight operation.
# It is used only immediately before an action that already requires protected
# ESP reads (currently backup creation). It never runs during normal startup.
resolve_efi_path_on_esp_privileged() {
    local efi=$1 rel candidate match

    if resolve_efi_path_on_esp "$efi"; then
        return 0
    fi

    [[ -n $ESP_MOUNT && -n $efi ]] || return 1
    rel=$(normalize_efi_path "$efi")
    [[ -n $rel ]] || return 1
    candidate="$ESP_MOUNT/$rel"
    have sudo || return 1

    if sudo -n test -f "$candidate" 2>/dev/null; then
        printf '%s\n' "$candidate"
        return 0
    fi

    # Authentication is permitted only here, in explicit privileged preflight.
    if [[ -t 0 ]] && sudo test -f "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
    fi

    match=$(sudo -n find "$ESP_MOUNT" -xdev -type f -ipath "$candidate" -print -quit 2>/dev/null || true)
    if [[ -n $match ]]; then
        printf '%s\n' "$match"
        return 0
    fi

    if [[ -t 0 ]]; then
        match=$(sudo find "$ESP_MOUNT" -xdev -type f -ipath "$candidate" -print -quit 2>/dev/null || true)
        if [[ -n $match ]]; then
            printf '%s\n' "$match"
            return 0
        fi
    fi

    return 1
}

path_exists_on_esp() {
    resolve_efi_path_on_esp "$1" >/dev/null
}

path_exists_on_esp_privileged() {
    resolve_efi_path_on_esp_privileged "$1" >/dev/null
}

detect_generic_fallback_owner_unprivileged() {
    local fallback expected candidate hash candidate_hash owner="" matches=0 bl
    fallback=$(resolve_efi_path_on_esp '\EFI\BOOT\BOOTX64.EFI' 2>/dev/null || true)
    [[ -n $fallback && -r $fallback ]] || return 1
    hash=$(sha256sum -- "$fallback" 2>/dev/null | awk '{print $1}' || true)
    [[ $hash =~ ^[0-9A-Fa-f]{64}$ ]] || return 1

    for bl in grub limine systemd-boot refind; do
        case "$bl" in
            grub) expected='\EFI\CACHYOS\GRUBX64.EFI' ;;
            limine) expected='\EFI\LIMINE\LIMINE_X64.EFI' ;;
            systemd-boot) expected='\EFI\systemd\systemd-bootx64.efi' ;;
            refind) expected='\EFI\refind\refind_x64.efi' ;;
        esac
        candidate=$(resolve_efi_path_on_esp "$expected" 2>/dev/null || true)
        [[ -n $candidate && -r $candidate ]] || continue
        candidate_hash=$(sha256sum -- "$candidate" 2>/dev/null | awk '{print $1}' || true)
        [[ -n $candidate_hash && $candidate_hash == "$hash" ]] || continue
        owner=$bl
        ((matches++))
    done
    ((matches == 1)) || return 1
    printf '%s\n' "$owner"
}

detect_bootloader() {
    collect_storage_info
    parse_efibootmgr || true
    BOOTLOADER="unknown"
    DETECTION_EVIDENCE=()

    local p
    p=$(normalize_efi_path "$BOOT_EFI_PATH")
    p=${p,,}
    if [[ $p == */grubx64.efi ]]; then
        BOOTLOADER="grub"; DETECTION_EVIDENCE+=("BootCurrent EFI path points to GRUB")
    elif [[ $p == *limine* && $p == *.efi ]]; then
        BOOTLOADER="limine"; DETECTION_EVIDENCE+=("BootCurrent EFI path points to Limine")
    elif [[ $p == *refind* && $p == *.efi ]]; then
        BOOTLOADER="refind"; DETECTION_EVIDENCE+=("BootCurrent EFI path points to rEFInd")
    elif [[ $p == */systemd/systemd-bootx64.efi || $p == */boot/bootx64.efi && ${BOOT_LABEL,,} == *systemd* ]]; then
        BOOTLOADER="systemd-boot"; DETECTION_EVIDENCE+=("BootCurrent EFI path points to systemd-boot")
    fi

    case "$BOOTLOADER" in
        unknown)
            # A generic UEFI fallback path is intentionally not identified by
            # label alone. If it is readable, accept it only when its bytes are
            # an unambiguous match for one canonical bootloader EFI binary on
            # this same ESP.
            if [[ $p == efi/boot/bootx64.efi ]]; then
                local fallback_owner
                fallback_owner=$(detect_generic_fallback_owner_unprivileged 2>/dev/null || true)
                if [[ -n $fallback_owner ]]; then
                    BOOTLOADER=$fallback_owner
                    DETECTION_EVIDENCE+=("Generic UEFI fallback is byte-identical to the canonical $fallback_owner EFI binary")
                fi
            fi
            if [[ $BOOTLOADER == unknown ]] && have bootctl && bootctl status 2>/dev/null | grep -qi 'systemd-boot'; then
                BOOTLOADER="systemd-boot"; DETECTION_EVIDENCE+=("bootctl reports systemd-boot")
            fi
            ;;
    esac

    if [[ $BOOTLOADER == unknown && -n $BOOT_LABEL ]]; then
        case "${BOOT_LABEL,,}" in
            *limine*) BOOTLOADER="limine"; DETECTION_EVIDENCE+=("UEFI label suggests Limine; path was inconclusive") ;;
            *refind*) BOOTLOADER="refind"; DETECTION_EVIDENCE+=("UEFI label suggests rEFInd; path was inconclusive") ;;
        esac
    fi
}

bootloader_package_state() {
    local pkgs=(grub grub-hook limine limine-mkinitcpio-hook limine-entry-tool refind systemd-boot-manager)
    local p owner found=0 state
    have pacman || { printf 'unavailable'; return 0; }
    for p in "${pkgs[@]}"; do
        pacman -Q "$p" >/dev/null 2>&1 || continue
        owner=unknown
        case "$p" in
            grub|grub-hook) owner=grub ;;
            limine|limine-mkinitcpio-hook|limine-entry-tool) owner=limine ;;
            refind) owner=refind ;;
            systemd-boot-manager) owner=systemd-boot ;;
        esac
        if [[ $owner == "$BOOTLOADER" ]]; then state=CURRENT; else state=INACTIVE; fi
        ((found)) && printf ' '
        printf '%s[%s]' "$p" "$state"
        found=1
    done
    ((found)) || printf 'none-detected'
}

print_system_report() {
    detect_bootloader
    collect_kernels
    printf 'Detected system:\n'
    printf '  Firmware:       %s\n' "$([[ -d /sys/firmware/efi ]] && printf UEFI || printf 'Legacy/unknown')"
    printf '  Bootloader:     %s\n' "$BOOTLOADER"
    printf '  BootCurrent:    %s\n' "${BOOT_CURRENT:-unavailable}"
    printf '  BootNext:       %s\n' "${BOOT_NEXT:-none}"
    printf '  UEFI label:     %s\n' "${BOOT_LABEL:-unavailable}"
    printf '  EFI executable: %s\n' "${BOOT_EFI_PATH:-unavailable}"
    printf '  ESP device:     %s\n' "${ESP_SOURCE:-unresolved}"
    printf '  ESP mountpoint: %s\n' "${ESP_MOUNT:-unresolved}"
    printf '  ESP filesystem: %s\n' "${ESP_FSTYPE:-unresolved}"
    printf '  ESP UUID:       %s\n' "${ESP_UUID:-unresolved}"
    printf '  Root device:    %s\n' "${ROOT_SOURCE:-unresolved}"
    printf '  Root filesystem:%s%s\n' "$([[ -n $ROOT_FSTYPE ]] && printf ' ' || printf '')" "${ROOT_FSTYPE:-unresolved}"
    printf '  Root UUID:      %s\n' "${ROOT_UUID:-unresolved}"
    printf '  Packages:       %s\n' "$(bootloader_package_state)"
    printf '  Kernels:        %s\n' "${KERNEL_SUMMARY:-none-detected}"
    printf '\nValidation:\n'
    run_validation passive
}
