#!/usr/bin/env bash
# r47: reconstruct the effective Limine default cmdline from every backed-up
# KERNEL_CMDLINE[default] assignment before cross-backend restore comparison.
#
# Real hardware exposed a valid CachyOS Limine backup whose /etc/default/limine
# contained more than one append assignment:
#
#   KERNEL_CMDLINE[default]+="quiet ... mitigations=off"
#   KERNEL_CMDLINE[default]+=" intel_pstate=passive"
#
# The historical restore extractor used only the first matching line.  That
# silently dropped the later append and made a GRUB runtime carrying the exact
# same effective policy look incompatible.  Direct GRUB -> Limine migration was
# unaffected because it derives target policy from the proven runtime cmdline.
#
# This layer fixes only backup-policy reconstruction.  It never sources or evals
# backup configuration.  It parses the supported default assignment forms,
# honors '=' as replacement and '+=' as append, then leaves semantic comparison
# to the existing pending_cmdline_equivalent() gate (which already filters
# BOOT_IMAGE=/boot_image=/initrd= loader-only artifacts and sorts unique tokens).

# Preserve the previous implementation for archaeology/debugging.
eval "$(declare -f r23_backup_limine_cmdline | sed '1s/r23_backup_limine_cmdline/r23_backup_limine_cmdline_pre_r47/')"

r47_limine_assignment_value() {
    local raw=$1

    # Trim only syntax-adjacent whitespace. Whitespace intentionally stored
    # inside quotes (for example an appended " intel_pstate=passive") remains
    # part of the value and is harmless to the token comparator.
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"

    if [[ $raw == \"*\" && $raw == *\" && ${#raw} -ge 2 ]]; then
        raw=${raw:1:${#raw}-2}
    elif [[ $raw == \'*\' && $raw == *\' && ${#raw} -ge 2 ]]; then
        raw=${raw:1:${#raw}-2}
    fi

    printf '%s\n' "$raw"
}

r23_backup_limine_cmdline() {
    local dir=$1 file line op raw value effective='' seen=0
    file="$dir/files/etc/default/limine"
    [[ -f $file && ! -L $file ]] || return 1

    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line =~ ^[[:space:]]*KERNEL_CMDLINE\[default\]([+]?)=[[:space:]]*(.*)$ ]]; then
            op=${BASH_REMATCH[1]}
            raw=${BASH_REMATCH[2]}
            value=$(r47_limine_assignment_value "$raw") || return 1

            if [[ $op == + ]]; then
                if [[ -n $effective && -n $value ]]; then
                    effective+=" $value"
                elif [[ -n $value ]]; then
                    effective=$value
                fi
            else
                # A plain '=' assignment replaces all earlier default policy,
                # matching limine-entry-tool's documented configuration model.
                effective=$value
            fi
            seen=1
        fi
    done <"$file"

    ((seen)) && [[ -n $effective ]] || return 1
    printf '%s\n' "$effective"
}
