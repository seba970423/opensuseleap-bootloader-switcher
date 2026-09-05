#!/usr/bin/env bash
# leap16-r33: harden the first GRUB2 -> systemd-boot hardware-proof edge.
#
# r32 hardware staging exposed three implementation bugs without ever arming
# BootNext:
#   * Leap's proven cmdline legitimately omits an explicit rw/ro token, while
#     the r32 candidate validator incorrectly required one.
#   * zypper's default weak-dependency expansion pulled in sdbootutil and PCR/TPM
#     helpers even though the candidate backend only needs the systemd-boot EFI
#     binary during the proof phase.
#   * inherited CachyOS uncommitted cleanup did not know about r32's Leap-only
#     machine-id payload tree / opensuse-*.conf BLS entries.
#
# Keep the hardware-proven r31 GRUB2 <-> Limine implementation untouched.  This
# layer changes only the GRUB2 -> systemd-boot candidate edge introduced by r32.

LEAP16_R33_R32_MARKER='# Managed by openSUSE Bootloader Switcher leap16-r32'
LEAP16_R33_R33_MARKER='# Managed by openSUSE Bootloader Switcher leap16-r33'
LEAP16_R32_SDBOOT_MANAGED_MARKER="$LEAP16_R33_R33_MARKER"
LEAP16_R33_SDBOOT_PACKAGE_INSTALLED_BY_STAGE=0
LEAP16_R33_RECOVERABLE_RESIDUE=0

# Preserve r32/r30 behavior outside this one Leap edge.
eval "$(declare -f r26_adapter_validate | sed '1s/r26_adapter_validate/r26_adapter_validate_pre_leap16_r33/')"
eval "$(declare -f r26_target_namespace_clean | sed '1s/r26_target_namespace_clean/r26_target_namespace_clean_pre_leap16_r33/')"
eval "$(declare -f r26_stage_systemd_boot_target | sed '1s/r26_stage_systemd_boot_target/r26_stage_systemd_boot_target_pre_leap16_r33/')"
eval "$(declare -f r26_remove_uncommitted_target_namespaces | sed '1s/r26_remove_uncommitted_target_namespaces/r26_remove_uncommitted_target_namespaces_pre_leap16_r33/')"

leap16_r33_switcher_entry_marker() {
    local path=$1 first
    first=$(leap16_r32_sdboot_read "$path" 2>/dev/null | head -n1 || true)
    [[ $first == "$LEAP16_R33_R32_MARKER" || $first == "$LEAP16_R33_R33_MARKER" ]]
}

leap16_r33_systemd_dir_is_switcher_shape() {
    local dir="${ESP_MOUNT%/}/EFI/systemd" binary staged_hash binary_hash listing
    if ! sudo -n test -d "$dir" 2>/dev/null && [[ ! -d $dir ]]; then
        return 1
    fi
    listing=$(sudo -n find "$dir" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | LC_ALL=C sort || true)
    [[ $listing == systemd-bootx64.efi ]] || return 1
    binary=$(leap16_r32_find_systemd_boot_binary 2>/dev/null || true)
    [[ -n $binary ]] || return 1
    staged_hash=$(sudo -n sha256sum -- "$dir/systemd-bootx64.efi" 2>/dev/null | awk '{print $1}' || true)
    binary_hash=$(sha256sum -- "$binary" 2>/dev/null | awk '{print $1}' || true)
    [[ -n $staged_hash && $staged_hash == "$binary_hash" ]]
}

leap16_r33_payload_root_is_reserved_shape() {
    local root obj base child childbase
    root=$(leap16_r32_sdboot_payload_root 2>/dev/null || true)
    [[ -n $root ]] || return 1
    if ! sudo -n test -d "$root" 2>/dev/null && [[ ! -d $root ]]; then
        return 1
    fi

    # The root name is switcher-specific, but still reject unexpected object
    # shapes so a stale-candidate cleanup never eats unrelated user content.
    while IFS= read -r obj; do
        [[ -n $obj ]] || continue
        if ! sudo -n test -d "$obj" 2>/dev/null; then
            return 1
        fi
        base=${obj##*/}
        [[ -n $base && $base != . && $base != .. ]] || return 1
        local have_linux=0 have_initrd=0
        while IFS= read -r child; do
            [[ -n $child ]] || continue
            childbase=${child##*/}
            case "$childbase" in
                linux) sudo -n test -f "$child" 2>/dev/null || return 1; have_linux=1 ;;
                initrd) sudo -n test -f "$child" 2>/dev/null || return 1; have_initrd=1 ;;
                *) return 1 ;;
            esac
        done < <(sudo -n find "$obj" -mindepth 1 -maxdepth 1 -print 2>/dev/null | LC_ALL=C sort)
        ((have_linux == 1 && have_initrd == 1)) || return 1
    done < <(sudo -n find "$root" -mindepth 1 -maxdepth 1 -print 2>/dev/null | LC_ALL=C sort)
    return 0
}

leap16_r33_classify_systemd_namespace() {
    local p ver root entries canonical_dir loader found=0
    LEAP16_R33_RECOVERABLE_RESIDUE=0

    [[ $(count_nvram_entries_for_target systemd-boot) == 0 ]] || {
        fail 'Pre-existing systemd-boot NVRAM state is ambiguous; refusing automatic residue recovery.'
        return 1
    }

    root=$(leap16_r32_sdboot_payload_root 2>/dev/null || true)
    entries="${ESP_MOUNT%/}/loader/entries"
    loader="${ESP_MOUNT%/}/loader/loader.conf"
    canonical_dir="${ESP_MOUNT%/}/EFI/systemd"

    if [[ -n $root ]] && { sudo -n test -e "$root" 2>/dev/null || [[ -e $root ]]; }; then
        leap16_r33_payload_root_is_reserved_shape || {
            fail "Switcher-reserved systemd-boot payload tree has an unexpected shape: $root"
            return 1
        }
        found=1
    fi

    if sudo -n test -e "$loader" 2>/dev/null || [[ -e $loader ]]; then
        leap16_r33_switcher_entry_marker "$loader" || {
            fail "Pre-existing foreign systemd-boot loader.conf is outside switcher ownership: $loader"
            return 1
        }
        found=1
    fi

    if sudo -n test -e "$canonical_dir" 2>/dev/null || [[ -e $canonical_dir ]]; then
        leap16_r33_systemd_dir_is_switcher_shape || {
            fail "Pre-existing EFI/systemd tree is not the exact r32/r33 staged shape: $canonical_dir"
            return 1
        }
        found=1
    fi

    # Exact names reserved for the currently installed kernels may not be
    # foreign. Old r32/r33 entries are recoverable only when their marker proves
    # switcher ownership.
    collect_kernels
    for ver in "${KERNEL_VERSIONS[@]}"; do
        p=$(leap16_r32_sdboot_entry_path "$ver")
        if sudo -n test -e "$p" 2>/dev/null || [[ -e $p ]]; then
            leap16_r33_switcher_entry_marker "$p" || {
                fail "Reserved openSUSE BLS entry already exists without switcher ownership: $p"
                return 1
            }
            found=1
        fi
    done
    p="${ESP_MOUNT%/}/loader/entries/$LEAP16_R32_SDBOOT_LOADER_DEFAULT"
    if sudo -n test -e "$p" 2>/dev/null || [[ -e $p ]]; then
        leap16_r33_switcher_entry_marker "$p" || {
            fail "Reserved openSUSE current BLS entry already exists without switcher ownership: $p"
            return 1
        }
        found=1
    fi

    if sudo -n test -d "$entries" 2>/dev/null || [[ -d $entries ]]; then
        while IFS= read -r p; do
            [[ -n $p ]] || continue
            if leap16_r33_switcher_entry_marker "$p"; then
                found=1
            fi
        done < <(sudo -n find "$entries" -maxdepth 1 -type f -name 'opensuse-*.conf' -print 2>/dev/null | LC_ALL=C sort)
    fi

    if ((found)); then
        LEAP16_R33_RECOVERABLE_RESIDUE=1
        warn 'Detected exact uncommitted r32/r33 systemd-boot residue with no surviving target NVRAM entry.'
        warn 'It will be removed only after the STAGE write boundary, then the target namespace will be re-proven clean.'
    fi
    return 0
}

r26_target_namespace_clean() {
    local target=$1
    if [[ ${BOOTLOADER:-} == grub && $target == systemd-boot ]]; then
        leap16_r33_classify_systemd_namespace
        return $?
    fi
    r26_target_namespace_clean_pre_leap16_r33 "$@"
}

leap16_r33_remove_recoverable_systemd_residue() {
    local root entries loader canonical_dir p
    leap16_r33_classify_systemd_namespace || return 1
    ((LEAP16_R33_RECOVERABLE_RESIDUE == 1)) || return 0

    root=$(leap16_r32_sdboot_payload_root) || return 1
    entries="${ESP_MOUNT%/}/loader/entries"
    loader="${ESP_MOUNT%/}/loader/loader.conf"
    canonical_dir="${ESP_MOUNT%/}/EFI/systemd"

    if sudo -n test -e "$loader" 2>/dev/null || [[ -e $loader ]]; then
        leap16_r33_switcher_entry_marker "$loader" || return 1
        sudo rm -f -- "$loader" || return 1
        ok "Removed stale switcher-owned systemd-boot loader.conf: $loader"
    fi

    if sudo -n test -d "$entries" 2>/dev/null || [[ -d $entries ]]; then
        while IFS= read -r p; do
            [[ -n $p ]] || continue
            leap16_r33_switcher_entry_marker "$p" || continue
            sudo rm -f -- "$p" || return 1
            ok "Removed stale switcher-owned BLS entry: $p"
        done < <(sudo -n find "$entries" -maxdepth 1 -type f -name 'opensuse-*.conf' -print 2>/dev/null | LC_ALL=C sort)
    fi

    if sudo -n test -e "$root" 2>/dev/null || [[ -e $root ]]; then
        leap16_r33_payload_root_is_reserved_shape || return 1
        sudo rm -rf -- "$root" || return 1
        ok "Removed stale switcher-owned kernel/initrd payload tree: $root"
    fi

    if sudo -n test -e "$canonical_dir" 2>/dev/null || [[ -e $canonical_dir ]]; then
        leap16_r33_systemd_dir_is_switcher_shape || return 1
        sudo rm -rf -- "$canonical_dir" || return 1
        ok "Removed stale switcher-owned EFI/systemd candidate tree: $canonical_dir"
    fi

    sudo rmdir -- "$entries" 2>/dev/null || true
    sudo rmdir -- "${ESP_MOUNT%/}/loader" 2>/dev/null || true

    # Bypass r33's permissive residue classifier here: after cleanup the exact
    # strict r32 namespace gate must pass before any new target bytes are staged.
    r26_target_namespace_clean_pre_leap16_r33 systemd-boot || {
        fail 'Could not prove a completely clean systemd-boot namespace after stale-candidate cleanup.'
        return 1
    }
    ok 'Re-proved a completely clean systemd-boot target namespace after stale-candidate cleanup'
}

# The first proof needs only the EFI binary. Disable weak dependencies so the
# systemd-boot+shim Supplements relationship does not pull sdbootutil/PCR/TPM
# tooling into a GRUB-authoritative candidate transaction.
leap16_r32_install_systemd_boot_package() {
    have zypper || { fail 'zypper is required'; return 1; }
    LEAP16_R33_SDBOOT_PACKAGE_INSTALLED_BY_STAGE=0
    if leap16_r32_find_systemd_boot_binary >/dev/null 2>&1; then
        return 0
    fi
    printf 'Installing native openSUSE systemd-boot package with weak dependencies disabled...\n'
    sudo zypper --non-interactive --no-recommends install systemd-boot || return 1
    leap16_r32_find_systemd_boot_binary >/dev/null 2>&1 || {
        fail 'systemd-boot RPM installed but no x86_64 EFI binary was found'
        return 1
    }
    LEAP16_R33_SDBOOT_PACKAGE_INSTALLED_BY_STAGE=1
    ok 'Installed the systemd-boot RPM without optional sdbootutil/PCR/TPM weak-dependency expansion'
}

# Reuse the already-proven pending_cmdline_equivalent() normalizer.  Leap's
# known-good GRUB cmdline has no explicit rw/ro token, and that omission itself
# must be preserved rather than invented by the target validator.
leap16_r33_validate_systemd_boot_chain() {
    local mode=${1:-current} failures=0 reference rootarg mountmode token
    local ver entry linux initrd options payload_root default opt_mode
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
    if [[ -n $mountmode ]]; then
        ok "Reference cmdline explicitly carries $mountmode; candidate entries must preserve it"
    else
        ok 'Reference cmdline has no explicit rw/ro token; candidate entries must preserve that omission'
    fi

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
        [[ -n $options ]] || { fail "$ver loader entry has no options line"; ((failures++)); continue; }
        if pending_cmdline_equivalent "$reference" "$options"; then
            ok "$ver options are token-equivalent to the proven source cmdline"
        else
            fail "$ver options are not token-equivalent to the proven source cmdline"
            printf '       reference: %s\n' "$reference"
            printf '       candidate: %s\n' "$options"
            ((failures++))
        fi
        if [[ -z $mountmode ]]; then
            opt_mode=''
            for token in $options; do
                [[ ( $token == rw || $token == ro ) && -z $opt_mode ]] && opt_mode=$token
            done
            [[ -z $opt_mode ]] || { fail "$ver candidate invented mount-mode token $opt_mode absent from the source"; ((failures++)); }
        fi
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
    if [[ $bl == systemd-boot ]]; then
        leap16_r33_validate_systemd_boot_chain "$mode"
        return $?
    fi
    r26_adapter_validate_pre_leap16_r33 "$@"
}

# Cleanup must mirror r32's actual Leap target ownership, not the inherited
# CachyOS sdboot-manage namespace.  This fixes the stale payload/BLS residue seen
# after the first failed hardware staging attempt.
r26_remove_uncommitted_target_namespaces() {
    local target=$1 path id rc=0
    if [[ ${BOOTLOADER:-} != grub || $target != systemd-boot ]]; then
        r26_remove_uncommitted_target_namespaces_pre_leap16_r33 "$@"
        return $?
    fi

    while IFS= read -r id; do
        [[ -n $id ]] || continue
        sudo efibootmgr -b "$id" -B >/dev/null 2>&1 || { rc=1; continue; }
        ok "Removed uncommitted systemd-boot NVRAM entry Boot$id"
    done < <(r21_nvram_ids_for_esp_path "$LEAP16_R32_SDBOOT_EFI")

    # Paths are exactly those recorded as target ownership by the Leap adapter.
    # Parent trees may appear before individual entries; existence checks make
    # repeated/partial cleanup idempotent.
    while IFS= read -r path; do
        [[ -n $path ]] || continue
        if sudo -n test -e "$path" 2>/dev/null || sudo -n test -L "$path" 2>/dev/null || [[ -e $path || -L $path ]]; then
            sudo rm -rf -- "$path" || { rc=1; continue; }
            ok "Removed uncommitted systemd-boot target namespace: $path"
        fi
    done < <(leap16_r32_systemd_owned_paths)
    sudo rmdir -- "${ESP_MOUNT%/}/loader/entries" 2>/dev/null || true
    sudo rmdir -- "${ESP_MOUNT%/}/loader" 2>/dev/null || true

    if ((LEAP16_R33_SDBOOT_PACKAGE_INSTALLED_BY_STAGE == 1)); then
        if sudo zypper --non-interactive remove systemd-boot >/dev/null; then
            LEAP16_R33_SDBOOT_PACKAGE_INSTALLED_BY_STAGE=0
            ok 'Removed systemd-boot RPM that was installed only by the failed uncommitted staging attempt'
        else
            fail 'Could not restore the pre-stage systemd-boot package state after staging failure'
            rc=1
        fi
    fi
    return "$rc"
}

# r32 residue cleanup is a write and therefore happens only inside the already
# confirmed staging path. Once it is gone, re-prove strict target cleanliness
# before delegating to the otherwise unchanged r32 candidate writer.
r26_stage_systemd_boot_target() {
    if [[ ${BOOTLOADER:-} == grub ]]; then
        leap16_r33_remove_recoverable_systemd_residue || return 1
    fi
    r26_stage_systemd_boot_target_pre_leap16_r33 "$@"
}

# Add one explicit warning for the exact package residue produced by r32. It is
# not invoked while GRUB remains authoritative; r33 simply avoids adding more
# weak dependencies on clean systems.
eval "$(declare -f leap16_r32_systemd_preflight | sed '1s/leap16_r32_systemd_preflight/leap16_r32_systemd_preflight_pre_leap16_r33/')"
leap16_r32_systemd_preflight() {
    leap16_r32_systemd_preflight_pre_leap16_r33 "$@" || return 1
    if rpm -q sdbootutil >/dev/null 2>&1; then
        warn 'sdbootutil is already installed (the first r32 attempt pulled it through weak dependencies).'
        warn "${SWITCHER_RELEASE:-leap16-r34} does not invoke sdbootutil while GRUB2 remains authoritative; LOADER_TYPE stays grub2-efi until runtime proof."
    fi
    ok "${SWITCHER_RELEASE:-leap16-r34} systemd-boot hardening gates are active: optional rw/ro semantics, exact stale-target recovery, and weak-dependency suppression"
}
