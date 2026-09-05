#!/usr/bin/env bash
# leap16-r32: first openSUSE-native systemd-boot live-switch backend.
#
# Scope is intentionally narrow:
#   * GRUB2 -> systemd-boot live switch only.
#   * Reuse the inherited format-v5 source-first/BootNext/runtime-proof engine.
#   * Do not alter the hardware-proven GRUB2 <-> Limine implementation.
#   * Do not expose systemd-boot user backup/restore yet.
#   * Limine <-> systemd-boot and systemd-boot -> GRUB2 remain locked until
#     the first hardware proof establishes the exact Leap systemd-boot topology.
#
# Unlike CachyOS r26, Leap normally mounts the ESP at /boot/efi.  Therefore we
# stage Type #1 BLS entries ourselves and copy exact kernel/initrd payloads into
# a transaction-owned machine-id tree on the ESP.  systemd-boot itself comes
# from the native openSUSE systemd-boot RPM; NVRAM remains under explicit
# efibootmgr --create-only control so the source stays first until runtime proof.

LEAP16_R32_SDBOOT_LABEL='openSUSE systemd-boot'
LEAP16_R32_SDBOOT_EFI='\EFI\systemd\systemd-bootx64.efi'
LEAP16_R32_SDBOOT_LOADER_DEFAULT='opensuse-current.conf'
LEAP16_R32_SDBOOT_MANAGED_MARKER='# Managed by openSUSE Bootloader Switcher leap16-r32'

# Preserve r31 behavior for every route except the new GRUB2 -> systemd-boot edge.
eval "$(declare -f r26_adapter_paths | sed '1s/r26_adapter_paths/r26_adapter_paths_pre_leap16_r32/')"
eval "$(declare -f r26_adapter_validate | sed '1s/r26_adapter_validate/r26_adapter_validate_pre_leap16_r32/')"
eval "$(declare -f r26_stage_systemd_boot_target | sed '1s/r26_stage_systemd_boot_target/r26_stage_systemd_boot_target_pre_leap16_r32/')"
eval "$(declare -f r26_target_namespace_clean | sed '1s/r26_target_namespace_clean/r26_target_namespace_clean_pre_leap16_r32/')"
eval "$(declare -f r26_retire_source_adapter | sed '1s/r26_retire_source_adapter/r26_retire_source_adapter_pre_leap16_r32/')"
eval "$(declare -f r26_finalize_target_fallback | sed '1s/r26_finalize_target_fallback/r26_finalize_target_fallback_pre_leap16_r32/')"
eval "$(declare -f operation_supported | sed '1s/operation_supported/operation_supported_pre_leap16_r32/')"
eval "$(declare -f show_operation_plan | sed '1s/show_operation_plan/show_operation_plan_pre_leap16_r32/')"
eval "$(declare -f run_live_operation | sed '1s/run_live_operation/run_live_operation_pre_leap16_r32/')"

leap16_r32_machine_id() { cat /etc/machine-id 2>/dev/null || true; }

leap16_r32_sdboot_payload_root() {
    local mid
    mid=$(leap16_r32_machine_id)
    [[ -n $mid ]] || return 1
    printf '%s/%s/opensuse-bootloader-switcher\n' "${ESP_MOUNT%/}" "$mid"
}

leap16_r32_sdboot_entry_path() {
    local ver=$1
    printf '%s/loader/entries/opensuse-%s.conf\n' "${ESP_MOUNT%/}" "$ver"
}

leap16_r32_systemd_owned_paths() {
    local ver root
    root=$(leap16_r32_sdboot_payload_root) || return 1
    printf '%s\n' "${ESP_MOUNT%/}/EFI/systemd" "${ESP_MOUNT%/}/loader/loader.conf" "$root"
    collect_kernels
    for ver in "${KERNEL_VERSIONS[@]}"; do
        leap16_r32_sdboot_entry_path "$ver"
    done
}

# Leap source ownership differs from CachyOS (/boot/grub2 + EFI/OPENSUSE).
r26_adapter_paths() {
    local bl=$1
    if [[ $bl == grub ]]; then
        printf '%s\n' /boot/grub2 "${ESP_MOUNT%/}/EFI/OPENSUSE" /etc/default/grub
        return 0
    fi
    if [[ $bl == systemd-boot ]]; then
        leap16_r32_systemd_owned_paths
        return $?
    fi
    r26_adapter_paths_pre_leap16_r32 "$@"
}

leap16_r32_sdboot_read() {
    local p=$1
    if [[ -r $p ]]; then cat -- "$p"; else sudo -n cat -- "$p" 2>/dev/null; fi
}

leap16_r32_sdboot_field() {
    local p=$1 key=$2
    leap16_r32_sdboot_read "$p" | awk -v k="$key" 'BEGIN{IGNORECASE=1} $1==k {$1=""; sub(/^[[:space:]]+/,""); print; exit}'
}

leap16_r32_validate_systemd_boot_chain() {
    local mode=${1:-current} failures=0 reference rootarg mountmode token
    local ver entry linux initrd options payload_root default
    printf '\nDeep openSUSE systemd-boot boot-chain validation (%s):\n' "$mode"

    [[ -n ${ESP_MOUNT:-} ]] || { fail 'ESP mountpoint is unavailable'; return 1; }
    reference=${PENDING_SOURCE_CMDLINE:-$(cat /proc/cmdline 2>/dev/null || true)}
    [[ -n $reference ]] || { fail 'Could not capture reference kernel command line'; return 1; }

    local canonical
    canonical=$(resolve_efi_path_on_esp_privileged "$LEAP16_R32_SDBOOT_EFI" 2>/dev/null || true)
    [[ -n $canonical ]] && ok "Canonical systemd-boot EFI exists: $canonical" || { fail 'Canonical systemd-boot EFI is missing'; ((failures++)); }

    local loader="${ESP_MOUNT%/}/loader/loader.conf"
    if sudo -n test -f "$loader" 2>/dev/null || [[ -f $loader ]]; then
        default=$(leap16_r32_sdboot_read "$loader" | awk '$1=="default"{print $2;exit}')
        [[ $default == "$LEAP16_R32_SDBOOT_LOADER_DEFAULT" ]] \
            && ok 'loader.conf selects the deterministic openSUSE current entry' \
            || { fail "Unexpected systemd-boot default entry: ${default:-unset}"; ((failures++)); }
    else
        fail 'systemd-boot loader.conf is missing'; ((failures++))
    fi

    rootarg=''; mountmode=''
    for token in $reference; do
        [[ $token == root=* && -z $rootarg ]] && rootarg=$token
        [[ ( $token == rw || $token == ro ) && -z $mountmode ]] && mountmode=$token
    done
    [[ -n $rootarg ]] || { fail 'Reference cmdline has no root= token'; ((failures++)); }
    [[ -n $mountmode ]] || { fail 'Reference cmdline has no rw/ro token'; ((failures++)); }

    payload_root=$(leap16_r32_sdboot_payload_root) || { fail 'Machine ID is unavailable'; return 1; }
    collect_kernels
    ((${#KERNEL_VERSIONS[@]} > 0)) || { fail 'No installed kernels were discovered'; return 1; }
    for ver in "${KERNEL_VERSIONS[@]}"; do
        entry=$(leap16_r32_sdboot_entry_path "$ver")
        if ! sudo -n test -f "$entry" 2>/dev/null && [[ ! -f $entry ]]; then
            fail "Missing BLS entry for kernel $ver"; ((failures++)); continue
        fi
        linux=$(leap16_r32_sdboot_field "$entry" linux 2>/dev/null || true)
        initrd=$(leap16_r32_sdboot_field "$entry" initrd 2>/dev/null || true)
        options=$(leap16_r32_sdboot_field "$entry" options 2>/dev/null || true)
        [[ $linux == "/${payload_root#${ESP_MOUNT%/}/}/$ver/linux" ]] \
            && (sudo -n test -f "${ESP_MOUNT%/}/${linux#/}" 2>/dev/null || [[ -f ${ESP_MOUNT%/}/${linux#/} ]]) \
            && ok "$ver kernel payload is exact and present" \
            || { fail "$ver kernel payload path is missing/incorrect (${linux:-unset})"; ((failures++)); }
        [[ $initrd == "/${payload_root#${ESP_MOUNT%/}/}/$ver/initrd" ]] \
            && (sudo -n test -f "${ESP_MOUNT%/}/${initrd#/}" 2>/dev/null || [[ -f ${ESP_MOUNT%/}/${initrd#/} ]]) \
            && ok "$ver initrd payload is exact and present" \
            || { fail "$ver initrd payload path is missing/incorrect (${initrd:-unset})"; ((failures++)); }
        [[ -n $rootarg && " $options " == *" $rootarg "* ]] || { fail "$ver options do not preserve $rootarg"; ((failures++)); }
        [[ -n $mountmode && " $options " == *" $mountmode "* ]] || { fail "$ver options do not preserve $mountmode"; ((failures++)); }
        for token in $reference; do
            case "$token" in BOOT_IMAGE=*|boot_image=*|initrd=*|root=*|rw|ro) continue ;; esac
            [[ " $options " == *" $token "* ]] || { fail "$ver options are missing reference token: $token"; ((failures++)); }
        done
    done

    if have bootctl; then
        bootctl --esp-path="$ESP_MOUNT" status >/dev/null 2>&1 || sudo -n bootctl --esp-path="$ESP_MOUNT" status >/dev/null 2>&1 \
            || { warn 'bootctl could not inspect the staged ESP from this session'; }
    fi
    printf '  Summary: %d failure(s)\n' "$failures"
    ((failures == 0))
}

r26_adapter_validate() {
    local bl=$1 mode=${2:-migration}
    case "$bl" in
        grub) validate_grub_boot_chain "$mode" ;;
        systemd-boot) leap16_r32_validate_systemd_boot_chain "$mode" ;;
        *) r26_adapter_validate_pre_leap16_r32 "$@" ;;
    esac
}

leap16_r32_secure_boot_disabled() {
    local out
    have mokutil || return 1
    out=$(mokutil --sb-state 2>/dev/null || true)
    grep -qi 'SecureBoot disabled\|Secure Boot disabled' <<<"$out"
}

leap16_r32_find_systemd_boot_binary() {
    local p
    for p in /usr/lib/systemd/boot/efi/systemd-bootx64.efi /usr/lib/systemd-boot/systemd-bootx64.efi; do
        [[ -f $p ]] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

leap16_r32_install_systemd_boot_package() {
    have zypper || { fail 'zypper is required'; return 1; }
    if leap16_r32_find_systemd_boot_binary >/dev/null 2>&1; then return 0; fi
    printf 'Installing native openSUSE systemd-boot package...\n'
    sudo zypper --non-interactive install systemd-boot || return 1
    leap16_r32_find_systemd_boot_binary >/dev/null 2>&1 || { fail 'systemd-boot RPM installed but no x86_64 EFI binary was found'; return 1; }
}

leap16_r32_portable_cmdline() {
    local token out=''
    for token in $1; do
        case "$token" in BOOT_IMAGE=*|boot_image=*|initrd=*) continue ;; esac
        [[ -n $out ]] && out+=' '
        out+=$token
    done
    printf '%s\n' "$out"
}

leap16_r32_write_systemd_boot_candidate() {
    local reference=$1 binary root ver src_kernel src_initrd entry tmp options relroot first=1
    binary=$(leap16_r32_find_systemd_boot_binary) || return 1
    root=$(leap16_r32_sdboot_payload_root) || return 1
    relroot="/${root#${ESP_MOUNT%/}/}"
    options=$(leap16_r32_portable_cmdline "$reference")
    [[ -n $options ]] || { fail 'Could not derive a portable systemd-boot kernel command line'; return 1; }

    sudo install -d -m 0755 -- "${ESP_MOUNT%/}/EFI/systemd" "${ESP_MOUNT%/}/loader/entries" "$root" || return 1
    sudo install -m 0644 -- "$binary" "${ESP_MOUNT%/}/EFI/systemd/systemd-bootx64.efi" || return 1

    collect_kernels
    for ver in "${KERNEL_VERSIONS[@]}"; do
        src_kernel="/boot/vmlinuz-$ver"; src_initrd="/boot/initrd-$ver"
        [[ -f $src_kernel && -f $src_initrd ]] || { fail "Missing complete /boot kernel/initrd pair for $ver"; return 1; }
        sudo install -d -m 0755 -- "$root/$ver" || return 1
        sudo install -m 0644 -- "$src_kernel" "$root/$ver/linux" || return 1
        sudo install -m 0644 -- "$src_initrd" "$root/$ver/initrd" || return 1
        entry=$(leap16_r32_sdboot_entry_path "$ver")
        tmp=$(mktemp) || return 1
        cat >"$tmp" <<ENTRY
$LEAP16_R32_SDBOOT_MANAGED_MARKER
title openSUSE Leap 16 ($ver)
version $ver
linux $relroot/$ver/linux
initrd $relroot/$ver/initrd
options $options
ENTRY
        sudo install -m 0644 -- "$tmp" "$entry" || { rm -f -- "$tmp"; return 1; }
        rm -f -- "$tmp"
        if ((first)); then
            sudo cp -- "$entry" "${ESP_MOUNT%/}/loader/entries/$LEAP16_R32_SDBOOT_LOADER_DEFAULT" || return 1
            first=0
        fi
    done

    tmp=$(mktemp) || return 1
    cat >"$tmp" <<LOADER
$LEAP16_R32_SDBOOT_MANAGED_MARKER
default $LEAP16_R32_SDBOOT_LOADER_DEFAULT
timeout 5
console-mode keep
editor no
LOADER
    sudo install -m 0644 -- "$tmp" "${ESP_MOUNT%/}/loader/loader.conf" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
}

# Include the deterministic alias entry in ownership, in addition to per-version entries.
eval "$(declare -f leap16_r32_systemd_owned_paths | sed '1s/leap16_r32_systemd_owned_paths/leap16_r32_systemd_owned_paths_base/')"
leap16_r32_systemd_owned_paths() {
    leap16_r32_systemd_owned_paths_base
    printf '%s/loader/entries/%s\n' "${ESP_MOUNT%/}" "$LEAP16_R32_SDBOOT_LOADER_DEFAULT"
}

r26_target_namespace_clean() {
    local target=$1
    if [[ ${BOOTLOADER:-} == grub && $target == systemd-boot ]]; then
        [[ $(count_nvram_entries_for_target systemd-boot) == 0 ]] || { fail 'Pre-existing systemd-boot NVRAM state is ambiguous'; return 1; }
        local p
        while IFS= read -r p; do
            [[ -n $p ]] || continue
            if sudo -n test -e "$p" 2>/dev/null || sudo -n test -L "$p" 2>/dev/null || [[ -e $p || -L $p ]]; then
                fail "systemd-boot target namespace already exists: $p"
                return 1
            fi
        done < <(leap16_r32_systemd_owned_paths)
        return 0
    fi
    r26_target_namespace_clean_pre_leap16_r32 "$@"
}

r26_stage_systemd_boot_target() {
    local source_id=$1 original_order=$2 reference=$3 target_id binary
    [[ ${BOOTLOADER:-} == grub ]] || { r26_stage_systemd_boot_target_pre_leap16_r32 "$@"; return $?; }
    leap16_r32_secure_boot_disabled || { fail "${SWITCHER_RELEASE:-leap16-r34} systemd-boot staging requires Secure Boot disabled; signed shim chaining is not enabled yet"; return 1; }
    leap16_r32_install_systemd_boot_package || return 1
    leap16_r32_write_systemd_boot_candidate "$reference" || return 1

    # Register only the canonical target and never let firmware reorder it.
    r28_create_alias_create_only "$LEAP16_R32_SDBOOT_LABEL" "$LEAP16_R32_SDBOOT_EFI" || return 1
    target_id=$R28_CREATED_ALIAS_ID
    set_source_first_boot_order "$source_id" "$target_id" "$original_order" || return 1
    r26_restore_source_fallback_after_target_stage || return 1
    adapter_target_validate systemd-boot || return 1
    r26_record_target_adapter systemd-boot || return 1
    R26_STAGED_TARGET_ID=${target_id^^}
    ok "Staged native openSUSE systemd-boot target as parked Boot$R26_STAGED_TARGET_ID"
}

# After runtime proof, retire only the exact native GRUB ownership recorded by
# format-v5.  /etc/sysconfig/bootloader is deliberately not in that manifest;
# flip its policy only after source retirement is authorized.
r26_retire_source_adapter() {
    if [[ ${PENDING_FORMAT:-} == "$R26_PENDING_FORMAT" && ${PENDING_SOURCE:-} == grub && ${PENDING_TARGET:-} == systemd-boot ]]; then
        r26_retire_source_adapter_pre_leap16_r32 || return 1
        if [[ -f /etc/sysconfig/bootloader ]]; then
            local tmp
            tmp=$(mktemp) || return 1
            awk '
                BEGIN{done=0}
                /^[[:space:]]*LOADER_TYPE=/ {print "LOADER_TYPE=systemd-boot"; done=1; next}
                {print}
                END{if(!done) print "LOADER_TYPE=systemd-boot"}
            ' /etc/sysconfig/bootloader >"$tmp" || { rm -f -- "$tmp"; return 1; }
            sudo install -m 0644 -- "$tmp" /etc/sysconfig/bootloader || { rm -f -- "$tmp"; return 1; }
            rm -f -- "$tmp"
            ok 'Updated openSUSE bootloader policy to LOADER_TYPE=systemd-boot after runtime proof'
        fi
        return 0
    fi
    r26_retire_source_adapter_pre_leap16_r32 "$@"
}

r26_finalize_target_fallback() {
    if [[ ${PENDING_FORMAT:-} == "$R26_PENDING_FORMAT" && ${PENDING_SOURCE:-} == grub && ${PENDING_TARGET:-} == systemd-boot ]]; then
        # Preserve r26's ownership rule, but do not silently replace an unrelated
        # shared fallback.  When GRUB owned it, the target may take it only now.
        r26_finalize_target_fallback_pre_leap16_r32 "$@"
        return $?
    fi
    r26_finalize_target_fallback_pre_leap16_r32 "$@"
}

operation_supported() {
    local current=$1 target=$2
    [[ $current:$target == grub:systemd-boot ]] && return 0
    operation_supported_pre_leap16_r32 "$@"
}

show_operation_plan() {
    local current=$1 target=$2
    if [[ $current:$target != grub:systemd-boot ]]; then
        show_operation_plan_pre_leap16_r32 "$@"
        return $?
    fi
    printf '\nExact openSUSE GRUB2 -> systemd-boot candidate plan:\n'
    printf '  1. Re-prove native openSUSE GRUB2/shim, current ESP/root/kernel state, empty BootNext and source-first persistent BootOrder.\n'
    printf '  2. Require Secure Boot disabled and a completely clean transaction-owned systemd-boot namespace.\n'
    printf '  3. Install only the native openSUSE systemd-boot RPM if needed; copy its canonical EFI binary to EFI/systemd.\n'
    printf '  4. Copy exact installed kernel/initrd pairs into a machine-id-owned ESP tree and generate deterministic Type #1 BLS entries without changing /etc/fstab.\n'
    printf '  5. Create exactly one parked systemd-boot Boot#### with efibootmgr --create-only; restore GRUB2 first in persistent BootOrder and restore the exact pre-stage EFI/BOOT fallback.\n'
    printf '  6. Deep-validate source + candidate, commit exact ownership manifests, then arm only the candidate with BootNext.\n'
    printf '  7. After real systemd-boot userspace arrival, prove exact BootCurrent/kernel/root/cmdline/ownership.\n'
    printf '  8. Only after proof: promote systemd-boot, retire ownership-proven native GRUB2 state, update LOADER_TYPE, then materialize the target fallback only when the old fallback ownership allows it.\n'
    printf '  If target proof fails, native GRUB2 is not retired.\n'
}

leap16_r32_systemd_preflight() {
    local target=$1
    [[ ${BOOTLOADER:-} == grub && $target == systemd-boot ]] || return 1
    printf '\n%s systemd-boot switch preflight:\n' "${SWITCHER_RELEASE:-leap16-r34}"
    run_validation preflight || { fail 'Base preflight failed; no boot state was modified'; return 1; }
    is_leap16 || { fail 'This backend is restricted to openSUSE Leap 16'; return 1; }
    leap16_require_sudo_session || return 1
    if bootcurrent_is_generic_fallback; then
        fail 'Current session was booted through generic EFI fallback; canonical source BootCurrent is required.'
        return 1
    fi
    pending_exists && { fail 'A bootloader transaction is already pending'; return 1; }
    [[ -z ${BOOT_NEXT:-} ]] || { fail "BootNext is already set to Boot${BOOT_NEXT^^}"; return 1; }
    leap16_r32_secure_boot_disabled || { fail 'Secure Boot must be disabled for the first systemd-boot hardware proof'; return 1; }
    adapter_source_validate grub || { fail 'Native GRUB2 source failed deep validation'; return 1; }
    r26_target_namespace_clean systemd-boot || return 1
    collect_kernels
    ((${#KERNEL_VERSIONS[@]} > 0)) || { fail 'No complete installed kernels were discovered'; return 1; }
    local ver
    for ver in "${KERNEL_VERSIONS[@]}"; do
        [[ -f /boot/vmlinuz-$ver && -f /boot/initrd-$ver ]] || { fail "Missing /boot/vmlinuz-$ver or /boot/initrd-$ver"; return 1; }
    done
    ok 'GRUB2 -> systemd-boot preflight passed without touching the proven GRUB2 <-> Limine paths'
}

run_live_operation() {
    local target=${1:-} current
    detect_bootloader
    current=$BOOTLOADER
    if [[ $current:$target != grub:systemd-boot ]]; then
        run_live_operation_pre_leap16_r32 "$@"
        return $?
    fi

    leap16_r32_systemd_preflight "$target" || return 1
    show_operation_plan "$current" "$target"
    printf '\nNo systemd-boot user backup/restore integration is enabled in %s; only the mandatory private transaction snapshot is created.\n' "${SWITCHER_RELEASE:-leap16-r34}"
    confirm_operation "$current" "$target" || { printf '\nOperation cancelled. No boot state was modified.\n'; return 0; }
    printf '\nRe-running the complete systemd-boot preflight at the write boundary...\n'
    leap16_r32_systemd_preflight "$target" || { printf '\nWrite-boundary revalidation failed. Nothing was modified.\n'; return 1; }
    r26_execute_adapter_switch systemd-boot
}
