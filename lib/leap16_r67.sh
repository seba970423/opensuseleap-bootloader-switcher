#!/usr/bin/env bash

# leap16-r67
# Leap-native rEFInd kernel/initrd validation and openSUSE symlink policy.
#
# The first r66 hardware stage proved that upstream rEFInd 0.14.2, its ext4
# driver, controlled ESP staging, and create-only NVRAM choreography all work
# on the real Leap host.  The stage then failed safely because the r64
# validator reused grub_initramfs_matches_kernel_version(), a CachyOS/Arch
# mkinitcpio helper that requires lsinitcpio and mkinitcpio's module layout.
# Leap 16 uses dracut initrds.  r67 validates those with lsinitrd instead and
# enables rEFInd's upstream follow_symlinks option, added specifically for
# openSUSE-style kernel links.

LEAP16_R67_INITRD_REASON=''

leap16_r67_initrd_matches_kernel_release() {
    local image=$1 ver=$2 listing releases other
    LEAP16_R67_INITRD_REASON=''

    have lsinitrd || {
        LEAP16_R67_INITRD_REASON='lsinitrd is unavailable; Leap rEFInd direct-kernel validation requires dracut tooling'
        return 1
    }
    [[ -f $image ]] || {
        LEAP16_R67_INITRD_REASON="initrd is missing: $image"
        return 1
    }

    if [[ -r $image ]]; then
        listing=$(lsinitrd "$image" 2>/dev/null) || {
            LEAP16_R67_INITRD_REASON='lsinitrd could not parse the image'
            return 1
        }
    else
        listing=$(sudo -n lsinitrd "$image" 2>/dev/null) || {
            LEAP16_R67_INITRD_REASON='lsinitrd could not parse the protected image'
            return 1
        }
    fi

    # A normal dracut image contains kernel-module paths.  When they are
    # present, bind the image to the exact release and reject mixed-release
    # module trees.  Some valid host-only images can contain no loadable kernel
    # modules at all; in that case, require dracut's own -k resolver to accept
    # the exact installed release rather than inventing a mkinitcpio invariant.
    releases=$(grep -oE '(usr/)?lib/modules/[^/[:space:]]+' <<<"$listing" 2>/dev/null \
        | sed -E 's#^(usr/)?lib/modules/##' | sort -u || true)
    if [[ -n $releases ]]; then
        grep -Fxq -- "$ver" <<<"$releases" || {
            LEAP16_R67_INITRD_REASON="dracut image has module trees, but none for exact kernel release $ver"
            return 1
        }
        other=$(grep -Fvx -- "$ver" <<<"$releases" || true)
        [[ -z $other ]] || {
            LEAP16_R67_INITRD_REASON="dracut image mixes unexpected kernel module release(s): $(tr '\n' ',' <<<"$other" | sed 's/,$//')"
            return 1
        }
    else
        lsinitrd -k "$ver" >/dev/null 2>&1 || {
            LEAP16_R67_INITRD_REASON="dracut could not resolve an initrd for exact kernel release $ver"
            return 1
        }
    fi
    return 0
}

# rEFInd >= 0.14.0 gained follow_symlinks specifically to support openSUSE
# layouts where a scanned kernel name can be a symlink to a file outside the
# directories rEFInd normally scans.  r66 already fixes the payload to 0.14.2,
# so enable the feature explicitly rather than relying on the upstream default
# (false).
leap16_r66_patch_refind_config() {
    local conf="${ESP_MOUNT%/}/EFI/refind/refind.conf" tmp out
    (sudo -n test -f "$conf" 2>/dev/null || [[ -f $conf ]]) || { fail 'Manually staged rEFInd refind.conf is missing'; return 1; }
    tmp=$(mktemp) || return 1; out=$(mktemp) || { rm -f -- "$tmp"; return 1; }
    leap16_r64_refind_read "$conf" >"$tmp" || { rm -f -- "$tmp" "$out"; return 1; }
    awk '
        BEGIN{IGNORECASE=1}
        /^[[:space:]]*#?[[:space:]]*(timeout|use_nvram|scanfor|scan_all_linux_kernels|dont_scan_dirs|extra_kernel_version_strings|follow_symlinks)[[:space:]]+/ {next}
        {print}
    ' "$tmp" >"$out" || { rm -f -- "$tmp" "$out"; return 1; }
    {
        printf '\n%s\n' "$LEAP16_R64_REFIND_MARKER"
        printf 'timeout 5\n'
        printf 'use_nvram false\n'
        printf 'scanfor internal,manual\n'
        printf 'scan_all_linux_kernels true\n'
        printf 'follow_symlinks true\n'
        printf 'dont_scan_dirs EFI/BOOT,EFI/OPENSUSE,EFI/LIMINE,EFI/systemd,EFI/opensuse-bootloader-switcher\n'
    } >>"$out"
    sudo install -o root -g root -m 0644 -- "$out" "$conf" || { rm -f -- "$tmp" "$out"; return 1; }
    rm -f -- "$tmp" "$out"
    ok 'Applied Leap-native rEFInd direct-kernel scanner policy with openSUSE symlink following enabled'
}

# Preserve r64's non-Leap validator, but replace only Leap's kernel/initrd
# structural logic.  Do not alter the generic mkinitcpio helper used by the
# already hardware-proven CachyOS/GRUB paths.
if declare -F validate_refind_boot_chain >/dev/null 2>&1; then
    eval "$(declare -f validate_refind_boot_chain | sed '1s/validate_refind_boot_chain/validate_refind_boot_chain_pre_leap16_r67/')"
fi
validate_refind_boot_chain() {
    local mode=${1:-current} esp=${ESP_MOUNT:-/boot/efi} root conf linuxconf driver options expected id ids order
    local failures=0 ver kernel initrd resolved
    if ! is_leap16; then
        validate_refind_boot_chain_pre_leap16_r67 "$@"
        return $?
    fi
    esp=${esp%/}; root="$esp/EFI/refind"; conf="$root/refind.conf"; linuxconf=/boot/refind_linux.conf
    driver=$(leap16_r64_refind_driver_path)
    printf '\nDeep openSUSE rEFInd boot-chain validation (%s):\n' "$mode"

    if sudo -n test -f "$root/refind_x64.efi" 2>/dev/null || [[ -f $root/refind_x64.efi ]]; then
        [[ $(leap16_r32_sdboot_read "$root/refind_x64.efi" 2>/dev/null | od -An -tx1 -N2 | tr -d '[:space:]') == 4d5a ]] \
            && { ok 'Canonical rEFInd EFI executable has an MZ header'; } \
            || { fail 'Canonical rEFInd EFI executable is malformed'; ((failures+=1)); }
        if have file && ! leap16_is_x86_64_efi_application "$root/refind_x64.efi"; then fail 'Canonical rEFInd EFI is not an x86-64 EFI application'; ((failures+=1)); fi
    else
        fail "Canonical rEFInd EFI is missing: $root/refind_x64.efi"; ((failures+=1))
    fi

    (sudo -n test -f "$conf" 2>/dev/null || [[ -f $conf ]]) || { fail 'rEFInd refind.conf is missing'; ((failures+=1)); }
    (sudo -n test -f "$linuxconf" 2>/dev/null || [[ -f $linuxconf ]]) || { fail '/boot/refind_linux.conf is missing'; ((failures+=1)); }
    if [[ ${ROOT_FSTYPE:-$(findmnt -rn -M / -o FSTYPE 2>/dev/null)} == ext4 ]]; then
        if sudo -n test -f "$driver" 2>/dev/null || [[ -f $driver ]]; then
            ok 'rEFInd ext4 filesystem driver exists for direct access to the Leap /boot kernel tree'
        else
            fail "rEFInd ext4 driver is missing: $driver"; ((failures+=1))
        fi
    fi

    if ((failures == 0)) || (sudo -n test -f "$conf" 2>/dev/null || [[ -f $conf ]]); then
        expected=$(leap16_r64_refind_config_value "$conf" scan_all_linux_kernels 2>/dev/null || true)
        [[ ${expected,,} == true ]] && ok 'scan_all_linux_kernels=true' || { fail 'rEFInd does not enable scan_all_linux_kernels=true'; ((failures+=1)); }
        expected=$(leap16_r64_refind_config_value "$conf" follow_symlinks 2>/dev/null || true)
        [[ ${expected,,} == true ]] && ok 'follow_symlinks=true enables upstream openSUSE kernel-link traversal' || { fail 'rEFInd does not enable follow_symlinks=true for openSUSE kernel links'; ((failures+=1)); }
        expected=$(leap16_r64_refind_config_value "$conf" use_nvram 2>/dev/null || true)
        [[ ${expected,,} == false ]] && ok 'use_nvram=false keeps rEFInd PreviousBoot state disk-backed when possible' || { fail 'rEFInd use_nvram is not false'; ((failures+=1)); }
        expected=$(leap16_r64_refind_config_value "$conf" scanfor 2>/dev/null || true)
        [[ ${expected// /} == *internal* ]] && ok 'rEFInd scans internal direct-boot targets' || { fail 'rEFInd scanfor does not include internal'; ((failures+=1)); }
        expected=$(leap16_r64_refind_config_value "$conf" dont_scan_dirs 2>/dev/null || true)
        local low=${expected,,}
        for id in efi/boot efi/opensuse efi/limine efi/systemd efi/opensuse-bootloader-switcher; do
            [[ $low == *"$id"* ]] || { fail "rEFInd dont_scan_dirs is missing $id"; ((failures+=1)); }
        done
        ((failures == 0)) && ok 'rEFInd scanner excludes source/fallback/reference EFI namespaces that must never masquerade as direct kernel boots'
    fi

    if sudo -n test -f "$linuxconf" 2>/dev/null || [[ -f $linuxconf ]]; then
        options=$(refind_standard_options "$linuxconf" 2>/dev/null || true)
        [[ -n $options ]] || { fail 'rEFInd standard kernel options are missing'; ((failures+=1)); }
        if [[ -n $options ]]; then
            local reference=${PENDING_SOURCE_CMDLINE:-$(cat /proc/cmdline 2>/dev/null || true)}
            pending_cmdline_equivalent "$options" "$reference" \
                && ok 'rEFInd standard kernel options are token-equivalent to the proven source/running cmdline' \
                || { fail 'rEFInd standard options are not token-equivalent to the proven source/running cmdline'; ((failures+=1)); }
        fi
        grep -Eq '^"Boot to single-user mode"[[:space:]]+".+[[:space:]]single"$' "$linuxconf" 2>/dev/null \
            && ok 'rEFInd single-user options line is present' \
            || { fail 'rEFInd single-user options line is missing'; ((failures+=1)); }
    fi

    collect_kernels
    ((${#KERNEL_VERSIONS[@]} > 0)) || { fail 'No complete Leap kernel/initrd pairs were found'; ((failures+=1)); }
    for ver in "${KERNEL_VERSIONS[@]}"; do
        kernel="/boot/vmlinuz-$ver"; initrd="/boot/initrd-$ver"
        [[ -f $kernel ]] && ok "$ver kernel exists at /boot/vmlinuz-$ver" || { fail "$ver kernel is missing"; ((failures+=1)); }
        if [[ -L $kernel ]]; then
            resolved=$(readlink -f -- "$kernel" 2>/dev/null || true)
            [[ -n $resolved && -f $resolved ]] \
                && ok "$ver kernel symlink resolves to a real file for rEFInd follow_symlinks" \
                || { fail "$ver kernel symlink target is missing"; ((failures+=1)); }
        fi
        [[ -f $initrd ]] && ok "$ver initrd exists at /boot/initrd-$ver" || { fail "$ver initrd is missing"; ((failures+=1)); }
        if [[ -L $initrd ]]; then
            resolved=$(readlink -f -- "$initrd" 2>/dev/null || true)
            [[ -n $resolved && -f $resolved ]] \
                && ok "$ver initrd symlink resolves to a real file" \
                || { fail "$ver initrd symlink target is missing"; ((failures+=1)); }
        fi
        if [[ -f $initrd ]]; then
            leap16_r67_initrd_matches_kernel_release "$initrd" "$ver" \
                && ok "$ver dracut initrd is parseable and bound to the kernel release" \
                || { fail "$ver dracut initrd failed structural validation: ${LEAP16_R67_INITRD_REASON:-unknown}"; ((failures+=1)); }
        fi
    done

    ids=$(leap16_r48_ids_for_current_esp_path "$LEAP16_R64_REFIND_EFI" | paste -sd, -)
    case "$mode" in
        current|source|final|runtime)
            if [[ ${BOOTLOADER:-} == refind ]]; then
                [[ -n $ids && $ids != *,* ]] && ok "Exactly one canonical rEFInd same-ESP NVRAM alias exists: Boot${ids^^}" \
                    || { fail "Canonical rEFInd NVRAM alias set is ambiguous (${ids:-none})"; ((failures+=1)); }
            fi
            ;;
    esac
    if [[ ${BOOTLOADER:-} == refind ]]; then
        order=$(leap16_current_boot_order 2>/dev/null || true)
        [[ -n $order ]] || { fail 'BootOrder is unavailable while validating active rEFInd'; ((failures+=1)); }
    fi
    printf '  rEFInd deep summary: %d failure(s)\n' "$failures"
    ((failures == 0))
}


# Fail read-only preflight before target mutation if Leap's dracut inspector is
# unavailable.  The fixed rEFInd payload itself is acquired only at the write
# boundary, but validation capability should be known before staging begins.
if declare -F leap16_r64_preflight >/dev/null 2>&1; then
    eval "$(declare -f leap16_r64_preflight | sed '1s/leap16_r64_preflight/leap16_r64_preflight_pre_leap16_r67/')"
fi
leap16_r64_preflight() {
    local target=$1
    leap16_r64_preflight_pre_leap16_r67 "$@" || return $?
    if [[ $target == refind ]]; then
        have lsinitrd || { fail 'lsinitrd is required to validate Leap dracut initrds before rEFInd candidate staging'; return 1; }
        ok 'r67 Leap dracut initrd inspection is available through lsinitrd'
    fi
}

# r67 backups must retain the openSUSE symlink policy that the live validator
# now requires.  Keep every r66 integrity/identity check, then add this single
# release-specific policy invariant.
if declare -F leap16_r64_refind_backup_payload_valid >/dev/null 2>&1; then
    eval "$(declare -f leap16_r64_refind_backup_payload_valid | sed '1s/leap16_r64_refind_backup_payload_valid/leap16_r64_refind_backup_payload_valid_pre_leap16_r67/')"
fi
leap16_r64_refind_backup_payload_valid() {
    local dir=$1 root conf value
    leap16_r64_refind_backup_payload_valid_pre_leap16_r67 "$@" || return $?
    root=$(leap16_r64_refind_backup_root "$dir") || { BACKUP_VALIDATION_REASON='invalid rEFInd backup ESP mount metadata'; return 1; }
    conf="$root/refind.conf"
    value=$(awk 'BEGIN{IGNORECASE=1} /^[[:space:]]*#/ {next} $1=="follow_symlinks"{print $2;exit}' "$conf")
    [[ ${value,,} == true ]] || { BACKUP_VALIDATION_REASON='backed-up rEFInd does not enable follow_symlinks=true required by the Leap direct-kernel policy'; return 1; }
    return 0
}

# Keep the r66 acquisition plan but make the new openSUSE link/dracut contract
# visible before the write boundary.
if declare -F leap16_r64_plan >/dev/null 2>&1; then
    eval "$(declare -f leap16_r64_plan | sed '1s/leap16_r64_plan/leap16_r64_plan_pre_leap16_r67/')"
fi
leap16_r64_plan() {
    leap16_r64_plan_pre_leap16_r67 "$@" || return $?
    if [[ ${2:-} == refind ]]; then
        printf '  r67 gate: validate Leap dracut initrds with lsinitrd and enable upstream follow_symlinks=true before any BootNext proof.\n'
    fi
}

# Release-accurate matrix: r66 reached real target staging but safe-failed at
# the stale mkinitcpio structural gate before BootNext/candidate commit.
leap16_r64_print_matrix() {
    cat <<'MATRIX'
openSUSE Leap 16 bootloader matrix — leap16-r67

Legend:
  HW-PROVEN       completed on real hardware before r64
  HW-PENDING      implemented + regression-covered; requires a successful real rEFInd boot transaction
  —               same-backend; not a cross-loader edge

LIVE SWITCH MATRIX (source rows -> target columns)
                 GRUB2        Limine       systemd-boot  rEFInd
  GRUB2          —            HW-PROVEN    HW-PROVEN     HW-PENDING
  Limine         HW-PROVEN    —            HW-PROVEN     HW-PENDING
  systemd-boot   HW-PROVEN    HW-PROVEN    —             HW-PENDING
  rEFInd         HW-PENDING   HW-PENDING    HW-PENDING    —

CROSS-LOADER RESTORE MATRIX (active source -> restored backup target)
                 GRUB2        Limine       systemd-boot  rEFInd
  GRUB2          —            HW-PROVEN    HW-PROVEN     HW-PENDING
  Limine         HW-PROVEN    —            HW-PROVEN     HW-PENDING
  systemd-boot   HW-PROVEN    HW-PROVEN    —             HW-PENDING
  rEFInd         HW-PENDING   HW-PENDING    HW-PENDING    —

BACKUP BACKENDS
  GRUB2          HW-PROVEN
  Limine         HW-PROVEN
  systemd-boot   HW-PROVEN
  rEFInd         HW-PENDING (immutable EFI/refind + refind_linux.conf; vars excluded)

TARGET PROOF CONTRACTS
  GRUB2          canonical shim runtime proof -> native shim EFI/BOOT ownership -> direct-GRUB recovery second in BootOrder
  Limine         canonical Limine runtime proof -> independent Limine EFI/BOOT BootCurrent proof -> source retirement
  systemd-boot   canonical systemd-boot runtime proof -> exact byte-identical EFI/BOOT transfer -> source retirement
  rEFInd         canonical rEFInd runtime proof + PreviousBoot direct-kernel proof -> source retirement; rEFInd intentionally does NOT claim EFI/BOOT

rEFInd LEAP DIRECT-KERNEL CONTRACT
  fixed upstream rEFInd 0.14.2 binary ZIP + ext4_x64.efi
  scan_all_linux_kernels=true + follow_symlinks=true for upstream openSUSE kernel-link support
  Leap initrds are validated with dracut lsinitrd, never the inherited CachyOS/Arch lsinitcpio helper
  scanner excludes EFI source/fallback/reference namespaces

HARDWARE ATTEMPTS INVOLVING rEFInd
  GRUB2 -> rEFInd  r64: SAFE-FAIL before candidate commit (zypper option-scope bug); not a boot proof
  GRUB2 -> rEFInd  r65: SAFE-FAIL before candidate commit (Leap repos have no refind provider); not a boot proof
  GRUB2 -> rEFInd  r66: SAFE-FAIL before candidate commit after successful upstream staging/create-only; stale mkinitcpio validator rejected Leap dracut initrds
MATRIX
}
