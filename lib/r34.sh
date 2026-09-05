#!/usr/bin/env bash
# r34: nounset-safe local-initialization hardening.
#
# The first real rEFInd runtime-proof attempt in r33 exposed an old helper bug:
#
#   local ver=$1 f="/usr/lib/modules/$ver/pkgbase"
#
# Under `set -u`, Bash expands the whole local command before the new `ver`
# assignment is reliably available to the `f=...` expansion.  Many historical
# callers accidentally masked this through Bash dynamic scoping by already
# having a local named `ver`; r33's direct-runtime proof used `running` instead
# and finally exposed the latent bug.
#
# The two shared kernel-pkgbase helpers are fixed in their foundational modules.
# r34 also overrides the remaining active r25 functions that had the same
# dependent-local pattern, while leaving the historical r25 implementation
# untouched.  r28's identical backup_mount bug remains historical because r29
# already overrides that helper with the proven split-assignment fix.

# Preserve the active r25 behavior and change only local initialization order.
r25_probe_failed_grub_restore_residue() {
    local dir=$1 backup_default backup_tree
    local cur rel backed listing rc=0
    backup_default="$dir/files/etc/default/grub"
    backup_tree="$dir/files/boot/grub"
    R25_GRUB_RESIDUE_DEFAULT=0
    R25_GRUB_RESIDUE_TREE=0

    if [[ -e /etc/default/grub || -L /etc/default/grub ]]; then
        [[ -f $backup_default && ! -L $backup_default ]] || {
            fail 'A pre-existing /etc/default/grub exists, but the selected backup cannot prove its identity.'
            return 1
        }
        sudo cmp -s -- /etc/default/grub "$backup_default" || {
            fail 'Pre-existing /etc/default/grub does not byte-match the selected validated GRUB backup.'
            fail 'Refusing to classify it as failed-restore residue.'
            return 1
        }
        R25_GRUB_RESIDUE_DEFAULT=1
        info 'Detected ownership-proven /etc/default/grub residue from the selected GRUB backup.'
    fi

    if sudo test -e /boot/grub 2>/dev/null || sudo test -L /boot/grub 2>/dev/null; then
        sudo test -d /boot/grub 2>/dev/null || { fail 'Pre-existing /boot/grub is not a directory; ownership is ambiguous.'; return 1; }
        [[ -d $backup_tree ]] || { fail 'Selected GRUB backup has no /boot/grub tree to prove the pre-existing target residue.'; return 1; }

        listing=$(mktemp) || { fail 'Could not allocate a temporary ownership-scan file.'; return 1; }
        if ! sudo find -P /boot/grub -mindepth 1 -print0 >"$listing"; then
            rm -f -- "$listing"
            fail 'Could not enumerate the pre-existing /boot/grub tree for ownership proof.'
            return 1
        fi

        while IFS= read -r -d '' cur; do
            rel=${cur#/boot/grub/}
            backed="$backup_tree/$rel"
            if sudo test -L "$cur" 2>/dev/null; then
                fail "Pre-existing /boot/grub residue contains a symlink and cannot be proven safe: $cur"
                rc=1; break
            elif sudo test -d "$cur" 2>/dev/null; then
                [[ -d $backed && ! -L $backed ]] || {
                    fail "Pre-existing GRUB directory is not present in the selected backup: $cur"
                    rc=1; break
                }
            elif sudo test -f "$cur" 2>/dev/null; then
                [[ -f $backed && ! -L $backed ]] || {
                    fail "Pre-existing GRUB file is not present in the selected backup: $cur"
                    rc=1; break
                }
                sudo cmp -s -- "$cur" "$backed" || {
                    fail "Pre-existing GRUB file differs from the selected validated backup: $cur"
                    rc=1; break
                }
            else
                fail "Unsupported object exists in pre-existing /boot/grub residue: $cur"
                rc=1; break
            fi
        done <"$listing"
        rm -f -- "$listing"
        ((rc == 0)) || return 1

        R25_GRUB_RESIDUE_TREE=1
        info 'Detected ownership-proven /boot/grub residue whose existing files are a byte-identical subset of the selected backup.'
    fi
    return 0
}

r25_validate_grub_backup_policy() {
    local dir=$1 src
    src="$dir/files/etc/default/grub"
    [[ -f $src ]] || { fail 'GRUB backup is missing /etc/default/grub'; return 1; }
    grep -Fqx 'GRUB_THEME="/usr/share/grub/themes/cachyos/theme.txt"' "$src" || {
        fail 'GRUB backup policy does not reference the captured CachyOS theme path.'
        return 1
    }
    grep -Eq '^GRUB_DEFAULT=0$' "$src" || {
        fail 'GRUB backup policy is missing deterministic GRUB_DEFAULT=0.'
        return 1
    }
    return 0
}

r25_install_grub_policy_from_backup() {
    local dir=$1 src
    src="$dir/files/etc/default/grub"
    [[ -f $src ]] || { fail 'GRUB backup policy disappeared before staging'; return 1; }
    # Preflight proved there was no source-owned /etc/default/grub. Installing
    # the grub package may create its packaged default; replacing only that
    # policy file with the integrity-validated backup is ownership-safe.
    sudo install -o root -g root -m 0644 -- "$src" /etc/default/grub || return 1
    GRUB_DEFAULT_CREATED=1
    GRUB_DEFAULT_HASH=$(sha256sum /etc/default/grub 2>/dev/null | awk '{print $1}' || sudo -n sha256sum /etc/default/grub 2>/dev/null | awk '{print $1}' || true)
    [[ $GRUB_DEFAULT_HASH =~ ^[0-9A-Fa-f]{64}$ ]] || { fail 'Could not hash restored /etc/default/grub'; return 1; }
    ok 'Restored the integrity-validated GRUB policy from backup'
    info 'Generated /boot/grub modules/config are rebuilt from the current CachyOS GRUB packages instead of copying stale generated payload bytes.'
}
