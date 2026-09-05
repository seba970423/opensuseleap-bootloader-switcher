#!/usr/bin/env bash
# leap16-r63: fix systemd-boot -> restored Limine managed-payload staging.
#
# Limine and the Leap systemd-boot adapter intentionally share ESP/<machine-id>
# as a parent.  Finalized systemd-boot owns only the exact
# <machine-id>/opensuse-bootloader-switcher child, while Limine owns one sibling
# child per installed kernel.  r61 reused the older GRUB restore hook, which
# correctly required the whole parent to be absent for GRUB sources but is
# wrong for this direct edge: a healthy systemd-boot source must already have
# that parent.
#
# r63 keeps the r51 two-proof transaction untouched.  It only makes the r31
# Limine backup substitution direct-edge aware:
#   * the selected backup machine-id tree must contain exactly the expected
#     Limine kernel children and no foreign/systemd child;
#   * the live shared parent must still contain exactly the proven systemd-boot
#     child before the merge;
#   * only the expected Limine sibling children are copied from the validated
#     backup; the shared parent and systemd-boot source child are never replaced.
# Existing r51 rollback already removes only those exact Limine children.

leap16_r63_validate_limine_backup_children_for_systemd_merge() {
    local dir=$1 esp_rel mid src_parent expected path base entry found
    local -a expected_bases=() actual_bases=()

    load_backup_metadata "$dir" || return 1
    esp_rel=${esp_mount#/}; mid=${machine_id:-}
    [[ -n $esp_rel && $esp_rel != *'..'* && -n $mid && $mid != */* && $mid != *'..'* ]] \
        || { fail 'Limine backup has invalid ESP/machine-id metadata for shared-parent restore'; return 1; }
    src_parent="$dir/files/$esp_rel/$mid"
    [[ -d $src_parent && ! -L $src_parent ]] \
        || { fail 'Limine backup managed payload parent is missing or unsafe'; return 1; }

    while IFS= read -r path; do
        [[ -n $path ]] || continue
        base=${path##*/}
        [[ -n $base && $base != "$LEAP16_R48_SYSTEMD_CHILD" ]] \
            || { fail 'Limine backup unexpectedly contains the reserved systemd-boot managed child'; return 1; }
        expected_bases+=("$base")
    done < <(leap16_r48_expected_limine_child_paths)
    ((${#expected_bases[@]} > 0)) || { fail 'Could not derive expected Limine kernel children for restore'; return 1; }

    while IFS=$'\t' read -r entry base; do
        [[ -n $base ]] || continue
        [[ $entry == d ]] || { fail "Unexpected non-directory object in Limine backup managed parent: $base"; return 1; }
        actual_bases+=("$base")
    done < <(find "$src_parent" -mindepth 1 -maxdepth 1 -printf '%y\t%f\n' 2>/dev/null | LC_ALL=C sort)

    ((${#actual_bases[@]} == ${#expected_bases[@]})) \
        || { fail 'Limine backup managed parent does not contain exactly the current expected kernel children'; return 1; }

    for expected in "${expected_bases[@]}"; do
        found=0
        for base in "${actual_bases[@]}"; do
            [[ $base == "$expected" ]] && { found=1; break; }
        done
        ((found)) || { fail "Limine backup is missing expected managed kernel child: $expected"; return 1; }
        [[ -d $src_parent/$expected && ! -L $src_parent/$expected ]] \
            || { fail "Limine backup kernel child is not a safe directory: $expected"; return 1; }
    done
    ! find "$src_parent" -type l -print -quit 2>/dev/null | grep -q . \
        || { fail 'Limine backup managed payload contains a symlink'; return 1; }
    return 0
}

# Strengthen only the systemd-source Limine restore validator.  The inherited
# r61 checks still prove manifest integrity, kernel set, EFI/splash shape and
# portable cmdline equivalence before this exact-child shape check runs.
if declare -F leap16_r61_validate_limine_backup_payload_for_systemd_source >/dev/null 2>&1; then
    eval "$(declare -f leap16_r61_validate_limine_backup_payload_for_systemd_source | sed '1s/leap16_r61_validate_limine_backup_payload_for_systemd_source/leap16_r61_validate_limine_backup_payload_for_systemd_source_pre_leap16_r63/')"
fi
leap16_r61_validate_limine_backup_payload_for_systemd_source() {
    declare -F leap16_r61_validate_limine_backup_payload_for_systemd_source_pre_leap16_r63 >/dev/null 2>&1 || return 1
    leap16_r61_validate_limine_backup_payload_for_systemd_source_pre_leap16_r63 "$@" || return 1
    leap16_r63_validate_limine_backup_children_for_systemd_merge "$1" || return 1
    return 0
}

# Replace only the r31 backup-substitution staging case when the proven source
# is systemd-boot.  Live systemd -> Limine staging and GRUB -> restored Limine
# continue through the existing implementation unchanged.
if declare -F stage_limine_kernel_entries_from_existing_artifacts >/dev/null 2>&1; then
    eval "$(declare -f stage_limine_kernel_entries_from_existing_artifacts | sed '1s/stage_limine_kernel_entries_from_existing_artifacts/stage_limine_kernel_entries_from_existing_artifacts_pre_leap16_r63/')"
fi
stage_limine_kernel_entries_from_existing_artifacts() {
    local dir=${LEAP16_R31_RESTORE_DIR:-} esp_rel mid src_parent dst_parent path base src dst child child_base
    local -a expected_paths=()

    if [[ -z $dir || ${BOOTLOADER:-} != systemd-boot ]]; then
        declare -F stage_limine_kernel_entries_from_existing_artifacts_pre_leap16_r63 >/dev/null 2>&1 || return 1
        stage_limine_kernel_entries_from_existing_artifacts_pre_leap16_r63 "$@"
        return $?
    fi

    leap16_r63_validate_limine_backup_children_for_systemd_merge "$dir" || return 1
    load_backup_metadata "$dir" || return 1
    esp_rel=${esp_mount#/}; mid=${machine_id:-}
    src_parent="$dir/files/$esp_rel/$mid"
    dst_parent="${ESP_MOUNT%/}/$mid"

    (sudo -n test -d "$dst_parent" 2>/dev/null || [[ -d $dst_parent ]]) \
        || { fail "Finalized systemd-boot shared payload parent disappeared before Limine restore staging: $dst_parent"; return 1; }
    (sudo -n test ! -L "$dst_parent" 2>/dev/null || [[ ! -L $dst_parent ]]) \
        || { fail 'Shared machine-id payload parent became a symlink before Limine restore staging'; return 1; }

    # Re-prove the shared parent at the write point.  Before adding Limine
    # siblings it must still contain only the exact systemd-boot source child.
    while IFS= read -r child; do
        [[ -n $child ]] || continue
        child_base=${child##*/}
        [[ $child_base == "$LEAP16_R48_SYSTEMD_CHILD" ]] \
            || { fail "Unexpected/foreign machine-id child appeared before Limine restore merge: $child"; return 1; }
    done < <(sudo -n find "$dst_parent" -mindepth 1 -maxdepth 1 -print 2>/dev/null | LC_ALL=C sort || true)
    (sudo -n test -d "$dst_parent/$LEAP16_R48_SYSTEMD_CHILD" 2>/dev/null || [[ -d $dst_parent/$LEAP16_R48_SYSTEMD_CHILD ]]) \
        || { fail 'Proven systemd-boot managed source child disappeared before Limine restore merge'; return 1; }
    (sudo -n test ! -L "$dst_parent/$LEAP16_R48_SYSTEMD_CHILD" 2>/dev/null || [[ ! -L $dst_parent/$LEAP16_R48_SYSTEMD_CHILD ]]) \
        || { fail 'Proven systemd-boot managed source child became a symlink before Limine restore merge'; return 1; }

    mapfile -t expected_paths < <(leap16_r48_expected_limine_child_paths) || return 1
    ((${#expected_paths[@]} > 0)) || { fail 'No expected Limine kernel child paths were derived at restore staging'; return 1; }
    for path in "${expected_paths[@]}"; do
        base=${path##*/}
        src="$src_parent/$base"
        dst="$dst_parent/$base"
        [[ -d $src && ! -L $src ]] || { fail "Validated Limine backup child disappeared before copy: $base"; return 1; }
        if sudo -n test -e "$dst" 2>/dev/null || sudo -n test -L "$dst" 2>/dev/null || [[ -e $dst || -L $dst ]]; then
            fail "Limine kernel child appeared after restore preflight: $dst"
            return 1
        fi
        sudo cp -a --no-preserve=all -- "$src" "$dst_parent/" || return 1
        ok "Restored self-contained Limine managed kernel/initrd child beside preserved systemd-boot source: $base"
    done
    ok 'Merged validated Limine managed payload into the shared machine-id parent without replacing systemd-boot ownership'
}
