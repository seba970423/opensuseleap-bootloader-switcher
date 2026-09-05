#!/usr/bin/env bash

REFIND_VALIDATION_FAILURES=0
REFIND_VALIDATION_WARNINGS=0
REFIND_MISSING_CMDLINE_TOKEN=""
REFIND_CACHYOS_KERNEL_LIST='linux-cachyos-bore,linux-cachyos-lts,linux-cachyos-bmq,linux-cachyos,linux'

refind_read_file() {
    local path=$1
    if [[ -r $path ]]; then cat -- "$path"; else sudo -n cat -- "$path" 2>/dev/null; fi
}

refind_reference_cmdline() {
    if [[ -n ${PENDING_SOURCE_CMDLINE:-} ]]; then printf '%s\n' "$PENDING_SOURCE_CMDLINE"; else cat /proc/cmdline 2>/dev/null || true; fi
}

refind_reference_tokens() {
    local token
    for token in $1; do
        case "$token" in BOOT_IMAGE=*|boot_image=*|initrd=*|root=*|rw|ro) continue ;; esac
        printf '%s\n' "$token"
    done
}

refind_options_have_reference_tokens() {
    local reference=$1 options=$2 token
    REFIND_MISSING_CMDLINE_TOKEN=""
    while IFS= read -r token; do
        [[ -n $token ]] || continue
        if [[ " $options " != *" $token "* ]]; then REFIND_MISSING_CMDLINE_TOKEN=$token; return 1; fi
    done < <(refind_reference_tokens "$reference")
    return 0
}

refind_standard_options() {
    local file=${1:-/boot/refind_linux.conf}
    refind_read_file "$file" 2>/dev/null | awk -F'"' '
        /^"Boot (with standard|using default) options"/ {print $4; exit}
    '
}

refind_kernel_list_value() {
    local file=$1
    refind_read_file "$file" 2>/dev/null | awk '
        /^[[:space:]]*extra_kernel_version_strings[[:space:]]+/ {
            sub(/^[[:space:]]*extra_kernel_version_strings[[:space:]]+/, ""); gsub(/[[:space:]]/, ""); print; exit
        }
    '
}

validate_refind_boot_chain() {
    local mode=${1:-current} failures=0 warnings=0
    local bootroot conf linuxconf
    local reference options rootarg mountmode token list ver kid
    bootroot=${REFIND_BOOT_ROOT:-/boot}
    conf="${ESP_MOUNT%/}/EFI/refind/refind.conf"
    linuxconf=${REFIND_LINUX_CONF_PATH:-$bootroot/refind_linux.conf}

    printf '\nDeep rEFInd boot-chain validation:\n'
    reference=$(refind_reference_cmdline)
    [[ -n $reference ]] && ok 'Reference known-good cmdline captured' || { fail 'Could not capture a reference kernel cmdline'; ((failures++)); }

    if [[ -f $conf ]] || sudo -n test -f "$conf" 2>/dev/null; then ok "rEFInd configuration exists: $conf"; else fail "Missing rEFInd configuration: $conf"; ((failures++)); fi
    if [[ -f $linuxconf ]] || sudo -n test -f "$linuxconf" 2>/dev/null; then ok "rEFInd Linux options file exists: $linuxconf"; else fail "Missing rEFInd Linux options file: $linuxconf"; ((failures++)); fi

    if [[ -f $conf ]] || sudo -n test -f "$conf" 2>/dev/null; then
        list=$(refind_kernel_list_value "$conf" 2>/dev/null || true)
        if [[ $list == "$REFIND_CACHYOS_KERNEL_LIST" ]]; then
            ok 'extra_kernel_version_strings matches the CachyOS installer reference order'
        else
            fail "extra_kernel_version_strings does not match CachyOS reference (${list:-unset})"; ((failures++))
        fi
    fi

    options=$(refind_standard_options "$linuxconf" 2>/dev/null || true)
    if [[ -n $options ]]; then
        ok 'rEFInd standard boot options are present'
        rootarg=""; mountmode=""
        for token in $reference; do
            [[ $token == root=* && -z $rootarg ]] && rootarg=$token
            [[ ( $token == rw || $token == ro ) && -z $mountmode ]] && mountmode=$token
        done
        if [[ -n $rootarg && " $options " == *" $rootarg "* ]]; then ok 'rEFInd standard options preserve the reference root argument'; else fail "rEFInd standard options do not preserve ${rootarg:-root=...}"; ((failures++)); fi
        if [[ -n $mountmode && " $options " == *" $mountmode "* ]]; then ok "rEFInd standard options preserve the reference $mountmode mount-mode token"; else fail 'rEFInd standard options do not preserve the reference rw/ro mode'; ((failures++)); fi
        if refind_options_have_reference_tokens "$reference" "$options"; then ok 'rEFInd standard options preserve the reference non-loader cmdline tokens'; else fail "rEFInd standard options are missing reference token: $REFIND_MISSING_CMDLINE_TOKEN"; ((failures++)); fi
    else
        fail 'Could not resolve the standard rEFInd boot options line'; ((failures++))
    fi

    collect_kernels
    for ver in "${KERNEL_VERSIONS[@]}"; do
        kid=$(kernel_pkgbase_for_version "$ver" 2>/dev/null || true)
        [[ -n $kid ]] || { fail "Could not resolve pkgbase for installed kernel $ver"; ((failures++)); continue; }
        if [[ -f "$bootroot/vmlinuz-$kid" ]] || sudo -n test -f "$bootroot/vmlinuz-$kid" 2>/dev/null; then ok "$kid kernel image exists for rEFInd autodetection"; else fail "$kid kernel image is missing from /boot"; ((failures++)); fi
        if [[ -f "$bootroot/initramfs-$kid.img" ]] || sudo -n test -f "$bootroot/initramfs-$kid.img" 2>/dev/null; then
            if grub_initramfs_matches_kernel_version "$bootroot/initramfs-$kid.img" "$ver"; then ok "$kid initramfs is parseable and binds to $ver"; else fail "$kid initramfs failed structural validation: ${GRUB_INITRAMFS_REASON:-unknown}"; ((failures++)); fi
        else
            fail "$kid initramfs is missing from /boot"; ((failures++))
        fi
    done

    REFIND_VALIDATION_FAILURES=$failures
    REFIND_VALIDATION_WARNINGS=$warnings
    printf '  Summary: %d failure(s), %d warning(s)\n' "$failures" "$warnings"
    ((failures == 0))
}
