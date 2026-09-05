#!/usr/bin/env bash

VALIDATION_FAILURES=0
VALIDATION_WARNINGS=0

v_ok() { ok "$*"; }
v_warn() { warn "$*"; ((VALIDATION_WARNINGS++)); }
v_fail() { fail "$*"; ((VALIDATION_FAILURES++)); }
v_info() { info "$*"; }

# Modes:
#   passive    never authenticates or invokes privileged checks
#   preflight  may authenticate for narrowly scoped protected-ESP verification
run_validation() {
    local mode=${1:-passive}
    VALIDATION_FAILURES=0
    VALIDATION_WARNINGS=0
    detect_bootloader
    collect_kernels

    [[ -d /sys/firmware/efi ]] && v_ok 'System is booted in UEFI mode' || v_fail 'System is not booted in UEFI mode'
    have efibootmgr && v_ok 'efibootmgr is available' || v_fail 'efibootmgr is missing'
    [[ -n $BOOT_CURRENT ]] && v_ok "BootCurrent is available ($BOOT_CURRENT)" || v_fail 'Unable to resolve BootCurrent'
    [[ $BOOTLOADER != unknown ]] && v_ok "Currently booted bootloader identified as $BOOTLOADER" || v_fail 'Currently booted bootloader could not be identified safely'

    if [[ -n $ESP_MOUNT && -n $ESP_SOURCE ]]; then
        v_ok "ESP is mounted at $ESP_MOUNT from $ESP_SOURCE"
    else
        v_fail 'Unable to resolve a mounted EFI System Partition'
    fi

    if [[ ${ESP_FSTYPE,,} =~ ^(vfat|fat|fat32)$ ]]; then
        v_ok "ESP filesystem is $ESP_FSTYPE"
    else
        v_fail "ESP filesystem is not FAT (${ESP_FSTYPE:-unknown})"
    fi

    if [[ -n $BOOT_EFI_PATH ]]; then
        if path_exists_on_esp "$BOOT_EFI_PATH"; then
            v_ok 'BootCurrent EFI executable exists on the mounted ESP'
        elif [[ $mode == preflight ]]; then
            if path_exists_on_esp_privileged "$BOOT_EFI_PATH"; then
                v_ok 'BootCurrent EFI executable exists on the mounted ESP'
            else
                v_warn 'Could not confirm BootCurrent EFI executable at the resolved ESP mount'
            fi
        else
            # Do not surprise the user with authentication during startup/reporting.
            # A protected ESP will be verified later during explicit preflight.
            v_info 'BootCurrent EFI executable requires privileged verification before protected-ESP operations'
        fi
    else
        v_warn 'BootCurrent EFI path is unavailable'
    fi

    [[ -n $ROOT_SOURCE ]] && v_ok "Root filesystem resolved to $ROOT_SOURCE" || v_fail 'Root filesystem source unresolved'
    [[ -n $ROOT_UUID ]] && v_ok "Root filesystem UUID resolved ($ROOT_UUID)" || v_warn 'Root UUID could not be resolved (valid on some stacked/device-mapper layouts)'

    if ((${#KERNEL_IMAGES[@]})); then
        v_ok "Found ${#KERNEL_IMAGES[@]} kernel image(s) in /usr/lib/modules"
    else
        v_fail 'No /usr/lib/modules/*/vmlinuz kernel images found'
    fi

    if have findmnt && findmnt --verify --tab-file /etc/fstab >/dev/null 2>&1; then
        v_ok '/etc/fstab passes findmnt verification'
    else
        v_warn '/etc/fstab did not pass findmnt verification or findmnt lacks --verify support'
    fi

    printf '  Summary: %d failure(s), %d warning(s)\n' "$VALIDATION_FAILURES" "$VALIDATION_WARNINGS"
    ((VALIDATION_FAILURES == 0))
}
