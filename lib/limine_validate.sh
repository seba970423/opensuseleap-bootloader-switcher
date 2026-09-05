#!/usr/bin/env bash

LIMINE_DEEP_FAILURES=0
LIMINE_DEEP_WARNINGS=0
LIMINE_DIAGNOSTIC_DIR=""

ld_ok()   { ok "$*"; }
ld_warn() { warn "$*"; ((LIMINE_DEEP_WARNINGS++)); }
ld_fail() { fail "$*"; ((LIMINE_DEEP_FAILURES++)); }
ld_info() { info "$*"; }

kernel_pkgbase_for_version() {
    local ver=$1 f
    f="/usr/lib/modules/$ver/pkgbase"
    if [[ -r $f ]]; then
        head -n1 -- "$f"
        return 0
    fi
    return 1
}

normalize_cmdline_for_compare() {
    local input=$1 tok
    # GRUB may expose BOOT_IMAGE= (and some loaders may expose initrd=) in
    # /proc/cmdline even though neither is required in Limine's cmdline field.
    # Everything else is preserved and compared as a token set.
    for tok in $input; do
        case "$tok" in
            BOOT_IMAGE=*|boot_image=*|initrd=*) continue ;;
        esac
        printf '%s\n' "$tok"
    done | LC_ALL=C sort -u
}

cmdline_contains_reference_tokens() {
    local reference=$1 candidate=$2 tok
    local -A have_tokens=()
    while IFS= read -r tok; do
        [[ -n $tok ]] && have_tokens["$tok"]=1
    done < <(normalize_cmdline_for_compare "$candidate")

    while IFS= read -r tok; do
        [[ -n $tok ]] || continue
        [[ -n ${have_tokens[$tok]+x} ]] || {
            LIMINE_MISSING_CMDLINE_TOKEN=$tok
            return 1
        }
    done < <(normalize_cmdline_for_compare "$reference")
    LIMINE_MISSING_CMDLINE_TOKEN=""
    return 0
}

limine_conf_field_for_kernel() {
    local kernel_id=$1 field=$2 conf=${3:-${ESP_MOUNT:-/boot}/limine.conf}
    awk -v kid="$kernel_id" -v field="$field" '
        /^[[:space:]]*comment:[[:space:]]*kernel-id=/ {
            line=$0
            sub(/^[[:space:]]*comment:[[:space:]]*kernel-id=/, "", line)
            gsub(/[[:space:]]+$/, "", line)
            active=(line == kid)
            next
        }
        active {
            # Another kernel entry starts before the requested field.
            if ($0 ~ /^[[:space:]]*comment:[[:space:]]*kernel-id=/) exit
            key=$0
            sub(/^[[:space:]]*/, "", key)
            if (key ~ ("^" field ":[[:space:]]*")) {
                sub(("^" field ":[[:space:]]*"), "", key)
                print key
                exit
            }
        }
    ' "$conf"
}

limine_conf_kernel_id_count() {
    local kernel_id=$1 conf=${2:-${ESP_MOUNT:-/boot}/limine.conf}
    awk -v kid="$kernel_id" '
        /^[[:space:]]*comment:[[:space:]]*kernel-id=/ {
            line=$0
            sub(/^[[:space:]]*comment:[[:space:]]*kernel-id=/, "", line)
            gsub(/[[:space:]]+$/, "", line)
            if (line == kid) count++
        }
        END { print count+0 }
    ' "$conf"
}

resolve_limine_boot_uri() {
    local value=$1 rel
    value=${value%%#*}
    case "$value" in
        'boot():'*) rel=${value#boot\(\):} ;;
        *) return 1 ;;
    esac
    rel=${rel#/}
    [[ -n $ESP_MOUNT && -n $rel ]] || return 1
    printf '%s/%s\n' "$ESP_MOUNT" "$rel"
}

verify_limine_uri_hash() {
    local value=$1 path expected actual
    [[ $value == *#* ]] || return 2
    expected=${value##*#}
    [[ $expected =~ ^[0-9A-Fa-f]{128}$ ]] || return 2
    path=$(resolve_limine_boot_uri "$value") || return 1
    if sudo -n test -f "$path" 2>/dev/null || [[ -f $path ]]; then
        if [[ -r $path ]]; then
            actual=$(b2sum -- "$path" 2>/dev/null | awk '{print $1}' || true)
        else
            actual=$(sudo -n b2sum -- "$path" 2>/dev/null | awk '{print $1}' || true)
        fi
        [[ -n $actual && ${actual,,} == ${expected,,} ]]
        return
    fi
    return 1
}

validate_limine_boot_chain() {
    local mode=${1:-current} reference_cmdline conf="${ESP_MOUNT:-/boot}/limine.conf"
    local ver kid effective conf_cmdline path_value initrd_value resolved
    local kernel_count=0

    LIMINE_DEEP_FAILURES=0
    LIMINE_DEEP_WARNINGS=0
    detect_bootloader
    collect_kernels

    printf '\nDeep Limine boot-chain validation:\n'

    have limine-entry-tool || ld_fail 'limine-entry-tool is not installed/available'
    have b2sum || ld_fail 'b2sum (coreutils) is not installed/available for Limine BLAKE2b verification'
    [[ -r /proc/cmdline ]] || ld_fail '/proc/cmdline is unreadable'
    reference_cmdline=$(cat /proc/cmdline 2>/dev/null || true)
    [[ -n $reference_cmdline ]] && ld_ok "Reference running cmdline captured from /proc/cmdline" || ld_fail 'Running kernel command line is empty'
    local running_root_token
    running_root_token=$(tr ' ' '\n' </proc/cmdline | grep -E '^root=' | head -n1 || true)

    if [[ -r /etc/default/limine ]]; then
        ld_ok '/etc/default/limine exists and is readable'
        if grep -Eq '^[[:space:]]*KERNEL_CMDLINE\[' /etc/default/limine; then
            ld_ok '/etc/default/limine contains explicit KERNEL_CMDLINE configuration'
        else
            ld_warn '/etc/default/limine has no explicit KERNEL_CMDLINE assignment; fallback behavior will be relied upon'
        fi
        local configured_esp
        configured_esp=$(awk -F= '/^[[:space:]]*ESP_PATH=/{print $2; exit}' /etc/default/limine | sed 's/^[[:space:]"]*//; s/[[:space:]"]*$//' || true)
        if [[ -n $configured_esp ]]; then
            if [[ $configured_esp == "$ESP_MOUNT" ]]; then
                ld_ok "/etc/default/limine ESP_PATH matches the detected ESP mount ($ESP_MOUNT)"
            else
                ld_fail "/etc/default/limine ESP_PATH ($configured_esp) does not match detected ESP mount ($ESP_MOUNT)"
            fi
        else
            ld_warn '/etc/default/limine does not declare ESP_PATH explicitly'
        fi
    else
        ld_warn '/etc/default/limine is missing/unreadable; limine-entry-tool fallback behavior will be relied upon'
    fi

    if sudo -n test -r "$conf" 2>/dev/null; then
        :
    elif [[ -r $conf ]]; then
        :
    else
        ld_fail "$conf is missing or unreadable"
    fi

    # Work with a temporary unprivileged copy so parsing never runs as root.
    local tmp_conf
    tmp_conf=$(mktemp)
    if [[ -r $conf ]]; then
        cat -- "$conf" >"$tmp_conf"
    elif sudo -n cat -- "$conf" >"$tmp_conf" 2>/dev/null; then
        :
    elif [[ -t 0 ]] && sudo cat -- "$conf" >"$tmp_conf"; then
        :
    else
        rm -f -- "$tmp_conf"
        ld_fail "Could not read $conf for deep validation"
        printf '  Summary: %d failure(s), %d warning(s)\n' "$LIMINE_DEEP_FAILURES" "$LIMINE_DEEP_WARNINGS"
        return 1
    fi

    for ver in "${KERNEL_VERSIONS[@]}"; do
        kid=$(kernel_pkgbase_for_version "$ver" 2>/dev/null || true)
        if [[ -z $kid ]]; then
            ld_fail "Could not resolve kernel package id for $ver (/usr/lib/modules/$ver/pkgbase missing)"
            continue
        fi
        ((kernel_count++))
        printf '  Kernel: %s (%s)\n' "$kid" "$ver"

        local entry_count
        entry_count=$(limine_conf_kernel_id_count "$kid" "$tmp_conf" 2>/dev/null || printf '0')
        if [[ $entry_count == 1 ]]; then
            ld_ok "$kid appears exactly once in limine.conf"
        else
            ld_fail "$kid appears $entry_count time(s) in limine.conf; expected exactly one generated entry"
        fi

        effective=$(limine-entry-tool --get-cmdline "$kid" 2>/dev/null || true)
        if [[ -n $effective ]]; then
            ld_ok "$kid effective cmdline resolved"
        else
            ld_fail "$kid effective cmdline is empty/unresolvable"
            continue
        fi

        if cmdline_contains_reference_tokens "$reference_cmdline" "$effective"; then
            ld_ok "$kid preserves the running system cmdline tokens"
        else
            ld_fail "$kid is missing cmdline token required by the running system: ${LIMINE_MISSING_CMDLINE_TOKEN:-unknown}"
        fi

        if [[ -n $running_root_token ]]; then
            if tr ' ' '\n' <<<"$effective" | grep -Fxq -- "$running_root_token"; then
                ld_ok "$kid preserves the running root argument ($running_root_token)"
            else
                ld_fail "$kid does not preserve the running root argument ($running_root_token)"
            fi
        fi

        conf_cmdline=$(limine_conf_field_for_kernel "$kid" cmdline "$tmp_conf" || true)
        if [[ -z $conf_cmdline ]]; then
            ld_fail "$kid has no cmdline entry in $conf"
        elif [[ $conf_cmdline == "$effective" ]]; then
            ld_ok "$kid limine.conf cmdline matches limine-entry-tool effective cmdline"
        elif cmdline_contains_reference_tokens "$effective" "$conf_cmdline" && cmdline_contains_reference_tokens "$conf_cmdline" "$effective"; then
            ld_ok "$kid limine.conf cmdline is token-equivalent to the effective cmdline"
        else
            ld_fail "$kid limine.conf cmdline differs from limine-entry-tool effective cmdline"
        fi

        path_value=$(limine_conf_field_for_kernel "$kid" path "$tmp_conf" || true)
        if [[ -n $path_value ]] && resolved=$(resolve_limine_boot_uri "$path_value" 2>/dev/null); then
            if sudo -n test -f "$resolved" 2>/dev/null || [[ -f $resolved ]]; then
                ld_ok "$kid staged kernel exists: ${resolved#$ESP_MOUNT/}"
                if [[ $path_value == *#* ]]; then
                    if verify_limine_uri_hash "$path_value"; then ld_ok "$kid staged kernel hash matches limine.conf"; else ld_fail "$kid staged kernel hash does not match limine.conf"; fi
                fi
            else
                ld_fail "$kid staged kernel is missing: $resolved"
            fi
        else
            ld_fail "$kid has no valid Limine kernel path"
        fi

        initrd_value=$(limine_conf_field_for_kernel "$kid" module_path "$tmp_conf" || true)
        if [[ -n $initrd_value ]] && resolved=$(resolve_limine_boot_uri "$initrd_value" 2>/dev/null); then
            if sudo -n test -f "$resolved" 2>/dev/null || [[ -f $resolved ]]; then
                ld_ok "$kid staged initramfs exists: ${resolved#$ESP_MOUNT/}"
                if [[ $initrd_value == *#* ]]; then
                    if verify_limine_uri_hash "$initrd_value"; then ld_ok "$kid staged initramfs hash matches limine.conf"; else ld_fail "$kid staged initramfs hash does not match limine.conf"; fi
                fi
            else
                ld_fail "$kid staged initramfs is missing: $resolved"
            fi
        else
            ld_fail "$kid has no valid Limine initramfs module_path"
        fi
    done

    rm -f -- "$tmp_conf"

    ((kernel_count > 0)) || ld_fail 'No installed kernels could be mapped to Limine kernel IDs'
    ((kernel_count == ${#KERNEL_VERSIONS[@]})) || ld_fail "Only $kernel_count of ${#KERNEL_VERSIONS[@]} installed kernels could be mapped to Limine entries"

    # Cross-check the running root identity against the independently resolved
    # root filesystem when the system uses the common root=UUID= form.
    if [[ -n $running_root_token ]]; then
        ld_ok "Running root argument is $running_root_token"
        if [[ $running_root_token == root=UUID=* && -n $ROOT_UUID ]]; then
            if [[ $running_root_token == "root=UUID=$ROOT_UUID" ]]; then
                ld_ok 'Running root=UUID identity matches the mounted root filesystem UUID'
            else
                ld_fail "Running root argument ($running_root_token) does not match mounted root UUID ($ROOT_UUID)"
            fi
        fi
    else
        ld_warn 'No root= token is present in /proc/cmdline; relying on full token-preservation checks for this storage topology'
    fi

    printf '  Summary: %d failure(s), %d warning(s)\n' "$LIMINE_DEEP_FAILURES" "$LIMINE_DEEP_WARNINGS"
    ((LIMINE_DEEP_FAILURES == 0))
}

capture_limine_diagnostics() {
    local phase=${1:-snapshot} ts dir
    ts=$(date '+%Y%m%d-%H%M%S')
    dir="$HOME/cachyos-bootloader-diagnostics/${ts}-${phase}"
    mkdir -p -- "$dir" || return 1
    chmod 700 -- "$dir" 2>/dev/null || true

    cat /proc/cmdline >"$dir/proc-cmdline.txt" 2>/dev/null || true
    cp -a -- /etc/default/limine "$dir/etc-default-limine" 2>/dev/null || true
    cp -a -- /etc/fstab "$dir/fstab" 2>/dev/null || true
    efibootmgr -v >"$dir/efibootmgr-v.txt" 2>&1 || true
    lsblk -f >"$dir/lsblk-f.txt" 2>&1 || true
    findmnt --verify --verbose >"$dir/findmnt-verify.txt" 2>&1 || true
    pacman -Q >"$dir/pacman-Q.txt" 2>&1 || true

    local conf_path="${ESP_MOUNT:-/boot}/limine.conf"
    if [[ -r $conf_path ]]; then
        cat "$conf_path" >"$dir/limine.conf" 2>/dev/null || true
    else
        sudo -n cat "$conf_path" >"$dir/limine.conf" 2>/dev/null || true
    fi

    collect_kernels
    local ver kid
    : >"$dir/effective-cmdlines.txt"
    for ver in "${KERNEL_VERSIONS[@]}"; do
        kid=$(kernel_pkgbase_for_version "$ver" 2>/dev/null || true)
        [[ -n $kid ]] || continue
        printf '%s (%s): ' "$kid" "$ver" >>"$dir/effective-cmdlines.txt"
        limine-entry-tool --get-cmdline "$kid" >>"$dir/effective-cmdlines.txt" 2>&1 || true
    done

    LIMINE_DIAGNOSTIC_DIR=$dir
    printf '%s\n' "$dir"
}
