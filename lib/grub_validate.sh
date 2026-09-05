#!/usr/bin/env bash

GRUB_DIAGNOSTIC_DIR=""
GRUB_MISSING_CMDLINE_TOKEN=""

GRUB_INITRAMFS_REASON=""

# Validate an existing conventional mkinitcpio image independently of the
# Limine-managed copy.  A clean Limine installation can legitimately retain
# /boot/initramfs-<pkgbase>.img whose bytes differ from the managed
# $ESP/<machine-id>/<kernel>/initramfs copy.  For GRUB candidate purposes the
# important invariants are that the image is parseable and contains modules for
# the exact installed kernel release.  Real boot proof is still required before
# cross-family cleanup is ever unlocked.
grub_initramfs_matches_kernel_version() {
    local image=$1 ver=$2 listing
    GRUB_INITRAMFS_REASON=""
    have lsinitcpio || { GRUB_INITRAMFS_REASON='lsinitcpio is unavailable'; return 1; }

    if [[ -r $image ]]; then
        listing=$(lsinitcpio -l "$image" 2>/dev/null) || { GRUB_INITRAMFS_REASON='lsinitcpio could not parse the image'; return 1; }
    else
        listing=$(sudo -n lsinitcpio -l "$image" 2>/dev/null) || { GRUB_INITRAMFS_REASON='lsinitcpio could not parse the protected image'; return 1; }
    fi

    if ! grep -Fq "usr/lib/modules/$ver/" <<<"$listing"; then
        GRUB_INITRAMFS_REASON="image does not contain modules for exact kernel release $ver"
        return 1
    fi

    return 0
}

GRUB_PROBE_VALUE=""
GRUB_PROBE_RC=0
GRUB_PROBE_STDERR=""
GRUB_PROBE_DIAGNOSTICS=""
GRUB_PROBE_PATH_FAILURES=0
GRUB_PROBE_PATH_WARNINGS=0

# GRUB uses module-oriented filesystem names in a few cases (for example
# "fat" for a Linux "vfat" mount, and "ext2" for ext2/3/4).  Normalize only
# known aliases; everything else is compared literally.
grub_normalize_fs_name() {
    case "${1,,}" in
        vfat|fat|fat16|fat32) printf 'fat\n' ;;
        ext2|ext3|ext4) printf 'ext\n' ;;
        *) printf '%s\n' "${1,,}" ;;
    esac
}

grub_normalize_device() {
    local dev=${1%%\[*}
    [[ -n $dev ]] || return 0
    if [[ $dev == /dev/* ]]; then
        readlink -f -- "$dev" 2>/dev/null || printf '%s\n' "$dev"
    else
        printf '%s\n' "$dev"
    fi
}

grub_append_probe_diagnostic() {
    local label=$1 target=$2 path=$3 rc=$4 value=$5 stderr=$6
    GRUB_PROBE_DIAGNOSTICS+="label=$label target=$target path=$path rc=$rc"$'\n'
    GRUB_PROBE_DIAGNOSTICS+="stdout=$value"$'\n'
    if [[ -n $stderr ]]; then
        GRUB_PROBE_DIAGNOSTICS+="stderr:"$'\n'"$stderr"$'\n'
    else
        GRUB_PROBE_DIAGNOSTICS+="stderr=<empty>"$'\n'
    fi
    GRUB_PROBE_DIAGNOSTICS+=$'---\n'
}

# Run grub-probe with the already-established privileged preflight context.
# Never discard stderr: a failed probe must explain exactly why it failed.
grub_probe_capture() {
    local label=$1 target=$2 path=$3 err out rc=0 stderr=""
    GRUB_PROBE_VALUE=""
    GRUB_PROBE_RC=0
    GRUB_PROBE_STDERR=""

    err=$(mktemp) || {
        GRUB_PROBE_RC=125
        GRUB_PROBE_STDERR='could not create temporary stderr capture file'
        grub_append_probe_diagnostic "$label" "$target" "$path" "$GRUB_PROBE_RC" '' "$GRUB_PROBE_STDERR"
        return 1
    }

    if out=$(sudo -n grub-probe --target="$target" "$path" 2>"$err"); then
        rc=0
    else
        rc=$?
    fi
    stderr=$(cat -- "$err" 2>/dev/null || true)
    rm -f -- "$err"

    GRUB_PROBE_VALUE=$(trim "$out")
    GRUB_PROBE_RC=$rc
    GRUB_PROBE_STDERR=$stderr
    grub_append_probe_diagnostic "$label" "$target" "$path" "$rc" "$GRUB_PROBE_VALUE" "$stderr"

    ((rc == 0)) && [[ -n $GRUB_PROBE_VALUE ]]
}

grub_print_probe_failure() {
    local target=$1 path=$2 line
    fail "grub-probe --target=$target $path exited with status $GRUB_PROBE_RC"
    if [[ -n $GRUB_PROBE_STDERR ]]; then
        while IFS= read -r line; do
            printf '         stderr: %s\n' "$line"
        done <<<"$GRUB_PROBE_STDERR"
    elif ((GRUB_PROBE_RC == 0)); then
        printf '         stderr: <empty>; command returned no probe value\n'
    else
        printf '         stderr: <empty>\n'
    fi
}

# Compare GRUB's privileged view of a path with independently detected Linux
# topology.  This is intentionally topology-aware rather than filesystem-name
# specific: / may be f2fs/ext4/btrfs/etc., /boot may be separate or live on /,
# and the ESP may or may not itself be /boot.
grub_validate_probe_path() {
    local label=$1 path=$2 expected_source=$3 expected_fs=$4 expected_uuid=$5
    local got expected got_norm expected_norm
    local failures=0 warnings=0

    if grub_probe_capture "$label" device "$path"; then
        got=$(grub_normalize_device "$GRUB_PROBE_VALUE")
        expected=$(grub_normalize_device "$expected_source")
        if [[ -n $expected && $got == "$expected" ]]; then
            ok "$label grub-probe device matches detected topology ($GRUB_PROBE_VALUE)"
        elif [[ -n $expected ]]; then
            fail "$label grub-probe device mismatch: probe=$GRUB_PROBE_VALUE detected=$expected_source"; ((failures++))
        else
            warn "$label detected device is unavailable; grub-probe returned $GRUB_PROBE_VALUE"; ((warnings++))
        fi
    else
        grub_print_probe_failure device "$path"; ((failures++))
    fi

    if grub_probe_capture "$label" fs "$path"; then
        got_norm=$(grub_normalize_fs_name "$GRUB_PROBE_VALUE")
        expected_norm=$(grub_normalize_fs_name "$expected_fs")
        if [[ -n $expected_norm && $got_norm == "$expected_norm" ]]; then
            ok "$label grub-probe filesystem matches detected topology ($GRUB_PROBE_VALUE)"
        elif [[ -n $expected_norm ]]; then
            fail "$label grub-probe filesystem mismatch: probe=$GRUB_PROBE_VALUE detected=$expected_fs"; ((failures++))
        else
            warn "$label detected filesystem type is unavailable; grub-probe returned $GRUB_PROBE_VALUE"; ((warnings++))
        fi
    else
        grub_print_probe_failure fs "$path"; ((failures++))
    fi

    if grub_probe_capture "$label" fs_uuid "$path"; then
        got=${GRUB_PROBE_VALUE,,}
        expected=${expected_uuid,,}
        if [[ -n $expected && $got == "$expected" ]]; then
            ok "$label grub-probe filesystem UUID matches detected topology ($GRUB_PROBE_VALUE)"
        elif [[ -n $expected ]]; then
            fail "$label grub-probe filesystem UUID mismatch: probe=$GRUB_PROBE_VALUE detected=$expected_uuid"; ((failures++))
        else
            warn "$label detected filesystem UUID is unavailable; grub-probe returned $GRUB_PROBE_VALUE"; ((warnings++))
        fi
    else
        grub_print_probe_failure fs_uuid "$path"; ((failures++))
    fi

    GRUB_PROBE_PATH_FAILURES=$failures
    GRUB_PROBE_PATH_WARNINGS=$warnings
    ((failures == 0))
}

grub_detect_path_topology() {
    local path=$1 source fs uuid source_dev
    source=$(findmnt -rn -T "$path" -o SOURCE 2>/dev/null | head -n1 || true)
    fs=$(findmnt -rn -T "$path" -o FSTYPE 2>/dev/null | head -n1 || true)
    source_dev=${source%%\[*}
    uuid=$(resolve_uuid "$source_dev")
    printf '%s\t%s\t%s\n' "$source" "$fs" "$uuid"
}

# Compare a generated GRUB linux command line against the known-good running
# command line. Loader-specific tokens, root= and rw/ro are validated
# separately because grub-mkconfig materializes those itself.
grub_reference_tokens() {
    local token
    for token in $1; do
        case "$token" in
            BOOT_IMAGE=*|boot_image=*|initrd=*|root=*|rw|ro) continue ;;
        esac
        printf '%s\n' "$token"
    done
}

grub_line_has_reference_tokens() {
    local reference=$1 line=$2 token
    GRUB_MISSING_CMDLINE_TOKEN=""
    while IFS= read -r token; do
        [[ -n $token ]] || continue
        if [[ " $line " != *" $token "* ]]; then
            GRUB_MISSING_CMDLINE_TOKEN=$token
            return 1
        fi
    done < <(grub_reference_tokens "$reference")
    return 0
}

grub_linux_line_for_kernel() {
    local conf=$1 kid=$2
    awk -v expected="vmlinuz-$kid" '
        /^[[:space:]]*(linux|linuxefi)[[:space:]]/ {
            path=$2
            sub(/^.*\//, "", path)
            if (path == expected) {print; exit}
        }
    ' "$conf"
}

grub_initrd_line_for_kernel() {
    local conf=$1 kid=$2
    awk -v expected="initramfs-$kid.img" '
        /^[[:space:]]*(initrd|initrdefi)[[:space:]]/ {
            for (i=2; i<=NF; i++) {
                path=$i
                sub(/^.*\//, "", path)
                if (path == expected) {print; exit}
            }
        }
    ' "$conf"
}

grub_kernel_first_line_number() {
    local conf=$1 kid=$2
    awk -v expected="vmlinuz-$kid" '
        /^[[:space:]]*(linux|linuxefi)[[:space:]]/ {
            path=$2
            sub(/^.*\//, "", path)
            if (path == expected) {print NR; exit}
        }
    ' "$conf"
}

grub_default_value() {
    local key=$1 file=${2:-/etc/default/grub} value
    [[ -r $file ]] || return 1
    value=$(awk -F= -v key="$key" '
        $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            sub(/^[^=]*=/, "", $0)
            print
            exit
        }
    ' "$file")
    value=${value#\"}; value=${value%\"}
    value=${value#\'}; value=${value%\'}
    printf '%s\n' "$value"
}

validate_grub_boot_chain() {
    local mode=${1:-current}
    local conf=/boot/grub/grub.cfg tmp="" failures=0 warnings=0
    local reference root_token mode_token ver kid linux_line initrd_line line_no
    local regular_line="" lts_line="" preferred="" configured_top=""
    local kernel_file initrd_file

    printf '\nDeep GRUB boot-chain validation:\n'
    reference=$(cat /proc/cmdline 2>/dev/null || true)
    if [[ -n $reference ]]; then
        ok 'Reference running cmdline captured from /proc/cmdline'
    else
        fail 'Could not capture the running kernel command line'; ((failures++))
    fi
    root_token=$(tr ' ' '\n' <<<"$reference" | awk '/^root=/{print; exit}')
    mode_token=$(tr ' ' '\n' <<<"$reference" | awk '$0=="rw" || $0=="ro" {print; exit}')
    [[ -n $root_token ]] && ok "Running root argument is $root_token" || { fail 'Running cmdline has no root= argument'; ((failures++)); }
    [[ -n $mode_token ]] && ok "Running root mount-mode token is $mode_token" || { fail 'Running cmdline has neither rw nor ro'; ((failures++)); }

    if [[ $root_token == root=UUID=* && -n ${ROOT_UUID:-} ]]; then
        if [[ ${root_token#root=UUID=} == "$ROOT_UUID" ]]; then
            ok 'Running root=UUID identity matches the mounted root filesystem UUID'
        else
            fail "Running root UUID (${root_token#root=UUID=}) does not match mounted root UUID $ROOT_UUID"; ((failures++))
        fi
    fi

    GRUB_PROBE_DIAGNOSTICS=""
    if have grub-probe; then
        local boot_source="" boot_fs="" boot_uuid="" esp_path=""
        if grub_validate_probe_path 'Root' / "${ROOT_SOURCE:-}" "${ROOT_FSTYPE:-}" "${ROOT_UUID:-}"; then
            :
        fi
        ((failures += GRUB_PROBE_PATH_FAILURES))
        ((warnings += GRUB_PROBE_PATH_WARNINGS))

        IFS=$'\t' read -r boot_source boot_fs boot_uuid < <(grub_detect_path_topology /boot)
        if grub_validate_probe_path 'Boot payload' /boot "$boot_source" "$boot_fs" "$boot_uuid"; then
            :
        fi
        ((failures += GRUB_PROBE_PATH_FAILURES))
        ((warnings += GRUB_PROBE_PATH_WARNINGS))

        # On layouts such as /boot/efi, the GRUB payload filesystem and the ESP
        # are distinct.  Probe the ESP as a third topology object instead of
        # pretending /boot is always the ESP.
        if [[ -n ${ESP_MOUNT:-} && ${ESP_MOUNT%/} != /boot ]]; then
            esp_path=${ESP_MOUNT%/}
            if grub_validate_probe_path 'ESP' "$esp_path" "${ESP_SOURCE:-}" "${ESP_FSTYPE:-}" "${ESP_UUID:-}"; then
                :
            fi
            ((failures += GRUB_PROBE_PATH_FAILURES))
            ((warnings += GRUB_PROBE_PATH_WARNINGS))
        fi
    else
        fail 'grub-probe is unavailable'; ((failures++))
    fi

    collect_kernels
    preferred=${KERNEL_PKGBASES[0]:-}
    if [[ -n $preferred ]]; then
        configured_top=$(grub_default_value GRUB_TOP_LEVEL /etc/default/grub 2>/dev/null || true)
        if [[ $configured_top == "/boot/vmlinuz-$preferred" ]]; then
            ok "GRUB_TOP_LEVEL explicitly prefers $preferred"
        elif [[ $mode == migration ]]; then
            fail "GRUB_TOP_LEVEL does not prefer $preferred (found: ${configured_top:-unset})"; ((failures++))
        else
            warn "GRUB_TOP_LEVEL is not explicitly pinned to $preferred"; ((warnings++))
        fi
        local configured_default
        configured_default=$(grub_default_value GRUB_DEFAULT /etc/default/grub 2>/dev/null || true)
        if [[ $configured_default == 0 ]]; then
            ok 'GRUB_DEFAULT is deterministic (0)'
        elif [[ $mode == migration ]]; then
            fail "GRUB_DEFAULT is not 0 (found: ${configured_default:-unset})"; ((failures++))
        else
            warn "GRUB_DEFAULT is not explicitly 0 (found: ${configured_default:-unset})"; ((warnings++))
        fi
    else
        fail 'Could not determine the preferred installed kernel'; ((failures++))
    fi

    if [[ -r $conf ]]; then
        :
    elif sudo -n test -r "$conf" 2>/dev/null; then
        tmp=$(mktemp) || return 1
        sudo -n cat -- "$conf" >"$tmp" || { rm -f -- "$tmp"; return 1; }
        conf=$tmp
    else
        fail '/boot/grub/grub.cfg is missing or unreadable'; ((failures++))
    fi

    if [[ -r $conf ]]; then
        if have grub-script-check; then
            if grub-script-check "$conf" >/dev/null 2>&1; then
                ok 'grub.cfg passes grub-script-check'
            else
                fail 'grub.cfg fails grub-script-check'; ((failures++))
            fi
        else
            fail 'grub-script-check is unavailable'; ((failures++))
        fi

        for ver in "${KERNEL_VERSIONS[@]}"; do
            kid=$(kernel_pkgbase_for_version "$ver" 2>/dev/null || true)
            printf '  Kernel: %s (%s)\n' "${kid:-unknown}" "$ver"
            if [[ -z $kid ]]; then
                fail "Could not resolve pkgbase for installed kernel $ver"; ((failures++)); continue
            fi

            kernel_file="/boot/vmlinuz-$kid"
            initrd_file="/boot/initramfs-$kid.img"
            if sudo -n test -f "$kernel_file" 2>/dev/null || [[ -f $kernel_file ]]; then
                ok "$kid conventional kernel artifact exists: $kernel_file"
            else
                fail "$kid conventional kernel artifact is missing: $kernel_file"; ((failures++))
            fi
            if sudo -n test -f "$initrd_file" 2>/dev/null || [[ -f $initrd_file ]]; then
                ok "$kid conventional initramfs artifact exists: $initrd_file"
                if grub_initramfs_matches_kernel_version "$initrd_file" "$ver"; then
                    ok "$kid conventional initramfs is parseable and contains modules for $ver"
                else
                    fail "$kid conventional initramfs failed structural kernel-version validation: ${GRUB_INITRAMFS_REASON:-unknown}"; ((failures++))
                fi
            else
                fail "$kid conventional initramfs artifact is missing: $initrd_file"; ((failures++))
            fi

            linux_line=$(grub_linux_line_for_kernel "$conf" "$kid")
            initrd_line=$(grub_initrd_line_for_kernel "$conf" "$kid")
            if [[ -n $linux_line ]]; then
                ok "$kid has a GRUB linux entry"
            else
                fail "$kid has no GRUB linux entry in grub.cfg"; ((failures++)); continue
            fi
            if [[ -n $initrd_line ]]; then
                ok "$kid has a matching initramfs entry"
            else
                fail "$kid has no matching initramfs entry in grub.cfg"; ((failures++))
            fi
            if [[ -n $root_token && " $linux_line " == *" $root_token "* ]]; then
                ok "$kid GRUB linux line preserves the running root argument"
            else
                fail "$kid GRUB linux line does not preserve $root_token"; ((failures++))
            fi
            if [[ -n $mode_token && " $linux_line " == *" $mode_token "* ]]; then
                ok "$kid GRUB linux line preserves the running $mode_token mount-mode token"
            else
                fail "$kid GRUB linux line does not preserve running mount mode ${mode_token:-unknown}"; ((failures++))
            fi
            if grub_line_has_reference_tokens "$reference" "$linux_line"; then
                ok "$kid GRUB linux line preserves the running non-loader cmdline tokens"
            else
                fail "$kid GRUB linux line lost running token: ${GRUB_MISSING_CMDLINE_TOKEN:-unknown}"; ((failures++))
            fi
            line_no=$(grub_kernel_first_line_number "$conf" "$kid")
            case "$kid" in
                linux-cachyos|linux) regular_line=$line_no ;;
                *-lts|linux-lts) [[ -z $lts_line ]] && lts_line=$line_no ;;
            esac
        done

        if [[ -n $regular_line && -n $lts_line ]]; then
            if ((regular_line < lts_line)); then
                ok 'Default/regular kernel appears before LTS in generated GRUB kernel entries'
            else
                fail 'LTS appears before the default/regular kernel in generated GRUB kernel entries'; ((failures++))
            fi
        fi
    fi

    [[ -n $tmp ]] && rm -f -- "$tmp"
    printf '  Summary: %d failure(s), %d warning(s)\n' "$failures" "$warnings"
    ((failures == 0))
}

capture_grub_diagnostics() {
    local phase=${1:-snapshot} stamp out limine_conf="${ESP_MOUNT:-/boot}/limine.conf"
    stamp=$(date +%Y%m%d-%H%M%S)
    out="$HOME/cachyos-bootloader-diagnostics/${stamp}-${phase}"
    mkdir -p -- "$out" || return 1
    chmod 700 -- "$out" 2>/dev/null || true
    cat /proc/cmdline >"$out/proc-cmdline.txt" 2>/dev/null || true
    cat /etc/fstab >"$out/fstab.txt" 2>/dev/null || true
    [[ -r /etc/default/grub ]] && cat /etc/default/grub >"$out/default-grub.txt" 2>/dev/null || true
    [[ -r /etc/default/limine ]] && cat /etc/default/limine >"$out/default-limine.txt" 2>/dev/null || true
    efibootmgr -v >"$out/efibootmgr-v.txt" 2>&1 || true
    lsblk -f >"$out/lsblk-f.txt" 2>&1 || true
    findmnt --verify --verbose >"$out/findmnt-verify.txt" 2>&1 || true
    pacman -Q >"$out/pacman-Q.txt" 2>&1 || true
    if [[ -n ${GRUB_PROBE_DIAGNOSTICS:-} ]]; then
        printf '%s' "$GRUB_PROBE_DIAGNOSTICS" >"$out/grub-probe-validation.txt" 2>/dev/null || true
    fi
    if have grub-probe && sudo -n true 2>/dev/null; then
        {
            printf '## root (/)\n'
            for target in device fs fs_uuid; do
                printf '$ grub-probe --target=%s /\n' "$target"
                sudo -n grub-probe --target="$target" / 2>&1 || printf '[exit=%d]\n' "$?"
            done
            printf '\n## boot payload (/boot)\n'
            for target in device fs fs_uuid; do
                printf '$ grub-probe --target=%s /boot\n' "$target"
                sudo -n grub-probe --target="$target" /boot 2>&1 || printf '[exit=%d]\n' "$?"
            done
            if [[ -n ${ESP_MOUNT:-} && ${ESP_MOUNT%/} != /boot ]]; then
                printf '\n## ESP (%s)\n' "$ESP_MOUNT"
                for target in device fs fs_uuid; do
                    printf '$ grub-probe --target=%s %s\n' "$target" "$ESP_MOUNT"
                    sudo -n grub-probe --target="$target" "$ESP_MOUNT" 2>&1 || printf '[exit=%d]\n' "$?"
                done
            fi
        } >"$out/grub-probe-live.txt" 2>&1 || true
    fi
    if [[ -r /boot/grub/grub.cfg ]]; then
        cat /boot/grub/grub.cfg >"$out/grub.cfg"
    elif sudo -n test -r /boot/grub/grub.cfg 2>/dev/null; then
        sudo -n cat /boot/grub/grub.cfg >"$out/grub.cfg" 2>/dev/null || true
    fi
    if [[ -r $limine_conf ]]; then
        cat -- "$limine_conf" >"$out/limine.conf" 2>/dev/null || true
    elif sudo -n test -r "$limine_conf" 2>/dev/null; then
        sudo -n cat -- "$limine_conf" >"$out/limine.conf" 2>/dev/null || true
    fi
    GRUB_DIAGNOSTIC_DIR=$out
    printf '%s\n' "$out"
}

# CachyOS Calamares parity gate for GRUB presentation. The captured clean
# installer/reference state installs cachyos-grub-theme and configures the
# exact theme path below. This is separate from generic GRUB validation so an
# older/source GRUB installation is not rejected merely for presentation.
validate_cachyos_grub_theme() {
    local theme=/usr/share/grub/themes/cachyos/theme.txt configured conf=/boot/grub/grub.cfg failures=0
    printf '\nCachyOS GRUB theme validation:\n'

    if pacman -Q cachyos-grub-theme >/dev/null 2>&1; then
        ok 'cachyos-grub-theme package is installed'
    else
        fail 'cachyos-grub-theme package is not installed'; ((failures++))
    fi

    if [[ -f $theme && -r $theme ]]; then
        ok "CachyOS GRUB theme asset exists: $theme"
    else
        fail "CachyOS GRUB theme asset is missing/unreadable: $theme"; ((failures++))
    fi

    configured=$(grub_default_value GRUB_THEME /etc/default/grub 2>/dev/null || true)
    if [[ $configured == "$theme" ]]; then
        ok 'GRUB_THEME matches the CachyOS Calamares reference path'
    else
        fail "GRUB_THEME mismatch: expected=$theme configured=${configured:-missing}"; ((failures++))
    fi

    if [[ -r $conf ]] || sudo -n test -r "$conf" 2>/dev/null; then
        if grep -Fq 'themes/cachyos/theme.txt' "$conf" 2>/dev/null || sudo -n grep -Fq 'themes/cachyos/theme.txt' "$conf" 2>/dev/null; then
            ok 'Generated grub.cfg contains the CachyOS theme reference'
        else
            fail 'Generated grub.cfg does not contain the CachyOS theme reference'; ((failures++))
        fi
    else
        fail 'Generated grub.cfg is unavailable for theme validation'; ((failures++))
    fi

    printf '  Theme summary: %d failure(s)\n' "$failures"
    ((failures == 0))
}
