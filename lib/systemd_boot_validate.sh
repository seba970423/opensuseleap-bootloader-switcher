#!/usr/bin/env bash

SDBOOT_VALIDATION_FAILURES=0
SDBOOT_VALIDATION_WARNINGS=0
SDBOOT_MISSING_CMDLINE_TOKEN=""

sdboot_read_file() {
    local path=$1
    if [[ -r $path ]]; then
        cat -- "$path"
    else
        sudo -n cat -- "$path" 2>/dev/null
    fi
}


sdboot_path_exists() {
    local path=$1
    [[ -f $path ]] || sudo -n test -f "$path" 2>/dev/null
}

sdboot_entry_field() {
    local file=$1 key=$2
    sdboot_read_file "$file" 2>/dev/null | awk -v k="$key" '
        BEGIN{IGNORECASE=1}
        $1==k { $1=""; sub(/^[[:space:]]+/, ""); print; exit }
    '
}

sdboot_reference_tokens() {
    local token
    for token in $1; do
        case "$token" in
            BOOT_IMAGE=*|boot_image=*|initrd=*|root=*|rw|ro) continue ;;
        esac
        printf '%s\n' "$token"
    done
}

sdboot_options_have_reference_tokens() {
    local reference=$1 options=$2 token
    SDBOOT_MISSING_CMDLINE_TOKEN=""
    while IFS= read -r token; do
        [[ -n $token ]] || continue
        if [[ " $options " != *" $token "* ]]; then
            SDBOOT_MISSING_CMDLINE_TOKEN=$token
            return 1
        fi
    done < <(sdboot_reference_tokens "$reference")
    return 0
}

sdboot_reference_cmdline() {
    if [[ -n ${PENDING_SOURCE_CMDLINE:-} ]]; then
        printf '%s\n' "$PENDING_SOURCE_CMDLINE"
    else
        cat /proc/cmdline 2>/dev/null || true
    fi
}

sdboot_entry_for_pkgbase() {
    local kid=$1 dir="${ESP_MOUNT%/}/loader/entries" candidate
    candidate="$dir/$kid.conf"
    if [[ -f $candidate ]] || sudo -n test -f "$candidate" 2>/dev/null; then
        printf '%s\n' "$candidate"
        return 0
    fi
    # sdboot-manage normally names entries after vmlinuz-<pkgbase>, but accept
    # a foreign/current package naming scheme only when the linux line resolves
    # to the exact installed kernel basename.
    local f linux
    while IFS= read -r f; do
        [[ -n $f ]] || continue
        linux=$(sdboot_entry_field "$f" linux 2>/dev/null || true)
        [[ ${linux##*/} == "vmlinuz-$kid" ]] || continue
        printf '%s\n' "$f"
        return 0
    done < <(find "$dir" -maxdepth 1 -type f -name '*.conf' -print 2>/dev/null | LC_ALL=C sort)
    return 1
}

validate_systemd_boot_chain() {
    local mode=${1:-current} failures=0 warnings=0
    local esp loader entries
    local reference rootarg mountmode ver kid entry linux options initrd line default
    esp="${ESP_MOUNT%/}"
    loader="$esp/loader/loader.conf"
    entries="$esp/loader/entries"

    printf '\nDeep systemd-boot boot-chain validation:\n'
    reference=$(sdboot_reference_cmdline)
    [[ -n $reference ]] && { ok 'Reference known-good cmdline captured'; } || { fail 'Could not capture a reference kernel cmdline'; ((failures++)); }

    if [[ -f $loader ]] || sudo -n test -f "$loader" 2>/dev/null; then
        ok "loader.conf exists: $loader"
        default=$(sdboot_read_file "$loader" 2>/dev/null | awk '$1=="default"{print $2; exit}')
        if [[ $default == linux-cachyos.conf || $default == linux-cachyos ]]; then
            ok 'loader.conf deterministically prefers the regular CachyOS kernel'
        else
            fail "loader.conf default is not the regular CachyOS kernel (${default:-unset})"; ((failures++))
        fi
        if sdboot_read_file "$loader" 2>/dev/null | grep -Eq '^[[:space:]]*timeout[[:space:]]+5([[:space:]]*)$'; then
            ok 'loader.conf timeout matches CachyOS installer reference (5)'
        else
            fail 'loader.conf timeout is not 5'; ((failures++))
        fi
        if sdboot_read_file "$loader" 2>/dev/null | grep -Eq '^[[:space:]]*console-mode[[:space:]]+keep([[:space:]]*)$'; then
            ok 'loader.conf console-mode matches CachyOS installer reference (keep)'
        else
            fail 'loader.conf console-mode keep is missing'; ((failures++))
        fi
    else
        fail "Missing systemd-boot loader configuration: $loader"; ((failures++))
    fi

    if [[ -d $entries ]] || sudo -n test -d "$entries" 2>/dev/null; then
        ok "loader entry directory exists: $entries"
    else
        fail "Missing loader entry directory: $entries"; ((failures++))
    fi

    rootarg=""
    mountmode=""
    for line in $reference; do
        [[ $line == root=* && -z $rootarg ]] && rootarg=$line
        [[ ( $line == rw || $line == ro ) && -z $mountmode ]] && mountmode=$line
    done
    [[ -n $rootarg ]] || { fail 'Reference cmdline has no root= argument'; ((failures++)); }
    [[ -n $mountmode ]] || { fail 'Reference cmdline has no rw/ro mount-mode token'; ((failures++)); }

    collect_kernels
    for ver in "${KERNEL_VERSIONS[@]}"; do
        kid=$(kernel_pkgbase_for_version "$ver" 2>/dev/null || true)
        [[ -n $kid ]] || { fail "Could not resolve pkgbase for installed kernel $ver"; ((failures++)); continue; }
        printf '  Kernel: %s (%s)\n' "$kid" "$ver"
        entry=$(sdboot_entry_for_pkgbase "$kid" 2>/dev/null || true)
        if [[ -z $entry ]]; then
            fail "$kid has no systemd-boot loader entry"; ((failures++)); continue
        fi
        ok "$kid loader entry exists: $entry"
        linux=$(sdboot_entry_field "$entry" linux 2>/dev/null || true)
        if [[ ${linux##*/} == "vmlinuz-$kid" ]] && sdboot_path_exists "$esp/${linux#/}"; then
            ok "$kid linux entry resolves to an existing kernel payload"
        else
            fail "$kid linux entry is missing/incorrect (${linux:-unset})"; ((failures++))
        fi
        initrd=$(sdboot_read_file "$entry" 2>/dev/null | awk '$1=="initrd"{print $2}' | tail -n1)
        if [[ ${initrd##*/} == "initramfs-$kid.img" ]] && sdboot_path_exists "$esp/${initrd#/}"; then
            ok "$kid initrd entry resolves to the matching initramfs"
        else
            fail "$kid matching initramfs entry is missing/incorrect (${initrd:-unset})"; ((failures++))
        fi
        options=$(sdboot_entry_field "$entry" options 2>/dev/null || true)
        [[ -n $options ]] || { fail "$kid loader entry has no options line"; ((failures++)); continue; }
        if [[ -n $rootarg && " $options " == *" $rootarg "* ]]; then ok "$kid options preserve the reference root argument"; else fail "$kid options do not preserve $rootarg"; ((failures++)); fi
        if [[ -n $mountmode && " $options " == *" $mountmode "* ]]; then ok "$kid options preserve the reference $mountmode mount-mode token"; else fail "$kid options do not preserve mount mode $mountmode"; ((failures++)); fi
        if sdboot_options_have_reference_tokens "$reference" "$options"; then
            ok "$kid options preserve the reference non-loader cmdline tokens"
        else
            fail "$kid options are missing reference token: $SDBOOT_MISSING_CMDLINE_TOKEN"; ((failures++))
        fi
    done

    if have bootctl; then
        if bootctl --esp-path="$esp" status >/dev/null 2>&1 || sudo -n bootctl --esp-path="$esp" status >/dev/null 2>&1; then
            ok 'bootctl can inspect the detected ESP'
        else
            warn 'bootctl status could not inspect the staged ESP from this session'; ((warnings++))
        fi
    else
        fail 'bootctl is unavailable'; ((failures++))
    fi

    SDBOOT_VALIDATION_FAILURES=$failures
    SDBOOT_VALIDATION_WARNINGS=$warnings
    printf '  Summary: %d failure(s), %d warning(s)\n' "$failures" "$warnings"
    ((failures == 0))
}
