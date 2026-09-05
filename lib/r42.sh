#!/usr/bin/env bash
# r42: remove source-loader-only cmdline artifacts before Limine entry staging.
#
# Real-hardware rEFInd -> Limine and systemd-boot -> Limine staging exposed the
# same misleading limine-entry-tool diagnostic:
#
#   Invalid 'initrd=\\initramfs-linux-cachyos.img' path:
#   /boot/\\initramfs-linux-cachyos.img not found
#
# The source bootloader may expose an initrd= (or BOOT_IMAGE=) token in
# /proc/cmdline. Those tokens describe how the *source loader* reached the
# running kernel; they are not portable kernel parameters. limine-entry-tool
# deliberately interprets initrd= tokens in KERNEL_CMDLINE as additional Limine
# modules, so copying such a token verbatim makes it try to resolve the source
# loader's EFI-style path as a Linux path under the ESP.
#
# r42 makes the Limine policy consistent with the transaction/runtime validators
# and the existing rEFInd target policy: BOOT_IMAGE=/boot_image=/initrd= are
# excluded while root=, rw/ro, and every real kernel parameter stay untouched.
# It also refuses to print [OK] if limine-entry-tool ever reports an invalid-path
# diagnostic despite returning exit status 0.

r42_portable_limine_cmdline() {
    local input=$1 token
    for token in $input; do
        case "$token" in
            BOOT_IMAGE=*|boot_image=*|initrd=*) continue ;;
        esac
        printf '%s ' "$token"
    done | sed 's/[[:space:]]*$//'
}

# Preserve the inherited implementation for archaeology/debugging, but replace
# only the policy serialization step. The CachyOS theme/palette and ownership
# behavior remain the r23 implementation byte-for-byte apart from cmdline input.
eval "$(declare -f write_limine_candidate_policy | sed '1s/write_limine_candidate_policy/write_limine_candidate_policy_pre_r42/')"
write_limine_candidate_policy() {
    local raw_cmdline cmdline tmp conf_tmp
    [[ ! -e /etc/default/limine ]] || { fail '/etc/default/limine appeared after preflight; refusing to overwrite it'; return 1; }
    [[ ! -e "$ESP_MOUNT/limine.conf" ]] || { fail 'limine.conf appeared after preflight; refusing to overwrite it'; return 1; }
    raw_cmdline=$(cat /proc/cmdline 2>/dev/null || true)
    [[ -n $raw_cmdline ]] || { fail 'Running kernel cmdline is empty; cannot materialize Limine policy'; return 1; }
    [[ $raw_cmdline != *$'\n'* && $raw_cmdline != *$'\r'* ]] || { fail 'Running kernel cmdline contains a line break; refusing unsafe policy serialization'; return 1; }
    cmdline=$(r42_portable_limine_cmdline "$raw_cmdline")
    [[ -n $cmdline ]] || { fail 'Portable Limine kernel cmdline is empty after removing source-loader-only tokens'; return 1; }
    [[ -n $ESP_MOUNT ]] || { fail 'ESP mountpoint is unresolved'; return 1; }
    [[ -r $R23_LIMINE_SPLASH_SOURCE ]] || { fail "CachyOS Limine splash asset is unavailable: $R23_LIMINE_SPLASH_SOURCE"; return 1; }

    if [[ $cmdline != "$raw_cmdline" ]]; then
        info 'Excluded source-loader-only BOOT_IMAGE/initrd tokens from the Limine target policy'
    fi

    tmp=$(mktemp) || return 1
    conf_tmp=$(mktemp) || { rm -f -- "$tmp"; return 1; }
    chmod 600 -- "$tmp" "$conf_tmp" 2>/dev/null || true
    printf 'ESP_PATH="%s"\n' "$ESP_MOUNT" >"$tmp"
    printf 'KERNEL_CMDLINE[default]+=%s\n' "$cmdline" >>"$tmp"
    printf 'BOOT_ORDER="*, *lts, *fallback, Snapshots"\n' >>"$tmp"
    r23_write_cachyos_limine_theme_base "$conf_tmp" "$R23_LIMINE_SPLASH_SOURCE" || { rm -f -- "$tmp" "$conf_tmp"; return 1; }

    sudo install -o root -g root -m 0644 -- "$tmp" /etc/default/limine || { rm -f -- "$tmp" "$conf_tmp"; return 1; }
    sudo install -o root -g root -m 0644 -- "$conf_tmp" "$ESP_MOUNT/limine.conf" || { rm -f -- "$tmp" "$conf_tmp"; return 1; }
    rm -f -- "$tmp" "$conf_tmp"
    r23_install_cachyos_limine_splash || return 1
    LIMINE_DEFAULT_CREATED=1
    LIMINE_DEFAULT_HASH=$(sha256sum /etc/default/limine 2>/dev/null | awk '{print $1}' || sudo -n sha256sum /etc/default/limine 2>/dev/null | awk '{print $1}' || true)
    [[ -n $LIMINE_DEFAULT_HASH ]] || { fail 'Could not hash generated /etc/default/limine'; return 1; }
    ok 'Created transaction-owned CachyOS-themed Limine base + portable policy from the proven running cmdline and detected ESP'
}

# A successful exit status must not override an explicit invalid-path diagnostic.
# This closes the confusing "Invalid ... path" immediately followed by "[OK]"
# presentation that exposed the r42 cmdline portability bug.
eval "$(declare -f stage_limine_kernel_entries_from_existing_artifacts | sed '1s/stage_limine_kernel_entries_from_existing_artifacts/stage_limine_kernel_entries_from_existing_artifacts_pre_r42/')"
stage_limine_kernel_entries_from_existing_artifacts() {
    have limine-entry-tool || { fail 'limine-entry-tool is unavailable after package installation'; return 1; }
    collect_kernels
    local ver kid kernel_path initrd_path effective tool_output tool_rc
    for ver in "${KERNEL_VERSIONS[@]}"; do
        kid=$(kernel_pkgbase_for_version "$ver" 2>/dev/null || true)
        [[ -n $kid ]] || { fail "Could not resolve pkgbase for installed kernel $ver"; return 1; }
        kernel_path="/boot/vmlinuz-$kid"
        initrd_path="/boot/initramfs-$kid.img"
        (sudo -n test -f "$kernel_path" 2>/dev/null || [[ -f $kernel_path ]]) || { fail "Kernel source disappeared before Limine staging: $kernel_path"; return 1; }
        (sudo -n test -f "$initrd_path" 2>/dev/null || [[ -f $initrd_path ]]) || { fail "Initramfs source disappeared before Limine staging: $initrd_path"; return 1; }

        tool_rc=0
        tool_output=$(sudo limine-entry-tool --add-kernel "$kid" "$initrd_path" "$kernel_path" "" --comment "kernel-version=$ver" --quiet 2>&1) || tool_rc=$?
        [[ -z $tool_output ]] || printf '%s\n' "$tool_output" >&2
        if ((tool_rc != 0)); then
            fail "limine-entry-tool failed while staging $kid ($ver) with status $tool_rc"
            return 1
        fi
        if grep -Eq "(^|[[:space:]])Invalid '[^']+' path:" <<<"$tool_output"; then
            fail "limine-entry-tool reported an invalid path while staging $kid ($ver); refusing to treat the entry as successful"
            return 1
        fi

        effective=$(limine-entry-tool --get-cmdline "$kid" 2>/dev/null || true)
        [[ -n $effective ]] || { fail "Effective Limine cmdline is empty after staging $kid"; return 1; }
        ok "Staged Limine kernel entry from existing artifacts: $kid ($ver)"
    done
}
