#!/usr/bin/env bash
# r33: rEFInd runtime-state-aware ownership and direct-kernel runtime proof.
#
# Real hardware proved that a fresh rEFInd installation legitimately mutates
# EFI/refind/vars/PreviousBoot after launching an entry when use_nvram=false.
# The immutable ownership contract therefore excludes only the rEFInd-owned
# vars namespace while continuing to hash/prove every other installed object.
# Runtime certification additionally proves PreviousBoot names the running
# CachyOS vmlinuz entry so a rEFInd -> GRUB chainload cannot masquerade as a
# successful direct rEFInd Linux boot merely because BootCurrent is rEFInd.

eval "$(declare -f r26_record_owned_path | sed '1s/r26_record_owned_path/r26_record_owned_path_pre_r33/')"
eval "$(declare -f r26_verify_owned_manifest | sed '1s/r26_verify_owned_manifest/r26_verify_owned_manifest_pre_r33/')"
eval "$(declare -f verify_pending_candidate_ownership_unchanged | sed '1s/verify_pending_candidate_ownership_unchanged/verify_pending_candidate_ownership_unchanged_pre_r33/')"

r33_is_refind_root() {
    local path=${1%/}
    [[ ${path,,} == */efi/refind ]]
}

r33_refind_path_is_runtime_mutable() {
    local root=${1%/} path=$2
    [[ $path == "$root/vars" || $path == "$root/vars/"* ]]
}

r33_write_refind_immutable_tree_manifest() {
    local root=${1%/} out=$2 path type identity target count=0
    : >"$out" || return 1
    while IFS= read -r -d '' path; do
        r33_refind_path_is_runtime_mutable "$root" "$path" && continue
        [[ $path != *$'\n'* && $path != *$'\r'* && $path != *$'\t'* ]] || return 1
        if sudo -n test -L "$path" 2>/dev/null; then
            type=l
            target=$(sudo -n readlink -- "$path" 2>/dev/null || true)
            [[ $target != *$'\n'* && $target != *$'\r'* && $target != *$'\t'* ]] || return 1
            identity=$(printf '%s' "$target" | sha256sum | awk '{print $1}')
        elif sudo -n test -f "$path" 2>/dev/null; then
            type=f
            identity=$(sudo -n sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || true)
        elif sudo -n test -d "$path" 2>/dev/null; then
            type=d
            identity='-'
        else
            return 1
        fi
        [[ -n $identity ]] || return 1
        printf '%s\t%s\t%s\n' "$type" "$identity" "$path" >>"$out" || return 1
        ((count++))
    done < <(sudo -n find "$root" -mindepth 1 -print0 2>/dev/null | LC_ALL=C sort -z)
    ((count > 0))
}

r33_verify_refind_immutable_tree_manifest() {
    local root=${1%/} manifest=$2 expected current type identity path
    [[ -s $manifest ]] || return 1
    expected=$(mktemp) || return 1
    current=$(mktemp) || { rm -f -- "$expected"; return 1; }

    : >"$expected"
    while IFS=$'\t' read -r type identity path; do
        [[ -n $type && -n $identity && -n $path ]] || { rm -f -- "$expected" "$current"; return 1; }
        # Backward compatibility for already-staged r26/r32 manifests: old
        # manifests may contain vars and PreviousBoot. Filter those records
        # from the immutable comparison rather than rewriting transaction
        # history after the target has booted.
        r33_refind_path_is_runtime_mutable "$root" "$path" && continue
        printf '%s\t%s\t%s\n' "$type" "$identity" "$path" >>"$expected" || { rm -f -- "$expected" "$current"; return 1; }
    done <"$manifest"
    [[ -s $expected ]] || { rm -f -- "$expected" "$current"; return 1; }

    if ! r33_write_refind_immutable_tree_manifest "$root" "$current"; then
        rm -f -- "$expected" "$current"
        return 1
    fi
    LC_ALL=C sort -o "$expected" "$expected"
    LC_ALL=C sort -o "$current" "$current"
    if cmp -s "$expected" "$current"; then
        rm -f -- "$expected" "$current"
        return 0
    fi
    rm -f -- "$expected" "$current"
    return 1
}

# New rEFInd ownership snapshots never claim the mutable vars namespace as
# immutable. Other bootloader ownership semantics remain byte-for-byte r26.
r26_record_owned_path() {
    local record=$1 path=$2 token mf
    if r33_is_refind_root "$path" && (sudo -n test -d "$path" 2>/dev/null || [[ -d $path ]]); then
        token=$(r26_manifest_token "$path")
        mf="$TRANSACTION_SNAPSHOT_DIR/tree-$token.tsv"
        r33_write_refind_immutable_tree_manifest "$path" "$mf" || { fail "Could not snapshot immutable rEFInd ownership tree: $path"; return 1; }
        printf 'tree\t%s\t%s\n' "$path" "$(basename -- "$mf")" >>"$record" || return 1
        return 0
    fi
    r26_record_owned_path_pre_r33 "$@"
}

# Verify old and new rEFInd manifests with the same narrow mutable-state rule.
# Every non-vars file/dir/symlink remains exact-hash/shape protected.
r26_verify_owned_manifest() {
    local record=$1 kind path identity actual mf
    [[ -s $record ]] || { fail "Ownership record is missing/empty: $record"; return 1; }
    while IFS=$'\t' read -r kind path identity; do
        [[ -n $kind && -n $path && -n $identity ]] || return 1
        case "$kind" in
            file)
                actual=$(sudo -n sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || true)
                [[ -n $actual && $actual == "$identity" ]] || { fail "Ownership-proven file changed/missing: $path"; return 1; }
                ;;
            tree)
                mf="$(dirname -- "$record")/$identity"
                if r33_is_refind_root "$path"; then
                    r33_verify_refind_immutable_tree_manifest "$path" "$mf" || { fail "Ownership-proven immutable rEFInd tree changed/missing: $path"; return 1; }
                else
                    pending_verify_tree_manifest "$path" "$mf" || { fail "Ownership-proven tree changed/missing: $path"; return 1; }
                fi
                ;;
            *) fail "Unknown ownership manifest record type: $kind"; return 1 ;;
        esac
    done <"$record"
    return 0
}

r33_read_privileged_file() {
    local path=$1
    if [[ -r $path ]]; then cat -- "$path"; else sudo -n cat -- "$path" 2>/dev/null; fi
}

r33_refind_previous_boot_text() {
    local refdir file efivar_dir efivar
    if [[ -n ${REFIND_PREVIOUS_BOOT_FILE:-} ]]; then
        file=$REFIND_PREVIOUS_BOOT_FILE
        [[ -f $file ]] || return 1
        r33_read_privileged_file "$file" | tr -d '\000\r'
        return ${PIPESTATUS[0]}
    fi

    refdir="${PENDING_ESP_MOUNT:-${ESP_MOUNT:-/boot}}/EFI/refind"
    file="$refdir/vars/PreviousBoot"
    if sudo -n test -f "$file" 2>/dev/null || [[ -f $file ]]; then
        r33_read_privileged_file "$file" | tr -d '\000\r'
        return ${PIPESTATUS[0]}
    fi

    # If rEFInd could not use disk-backed vars (or use_nvram=true), fall back
    # to the standard rEFInd PreviousBoot EFI variable. efivarfs prepends a
    # four-byte attribute field before the UTF-16 payload.
    efivar_dir=${REFIND_EFIVAR_DIR:-/sys/firmware/efi/efivars}
    efivar=$(find "$efivar_dir" -maxdepth 1 -type f -name 'PreviousBoot-*' -print -quit 2>/dev/null || true)
    [[ -n $efivar ]] || return 1
    if [[ -r $efivar ]]; then
        dd if="$efivar" bs=1 skip=4 status=none 2>/dev/null | tr -d '\000\r'
    else
        sudo -n dd if="$efivar" bs=1 skip=4 status=none 2>/dev/null | tr -d '\000\r'
    fi
}

r33_verify_refind_direct_kernel_launch() {
    [[ ${PENDING_TARGET:-} == refind ]] || return 0
    local running kid expected previous lower_previous source_efi_base
    running=${R33_RUNNING_KERNEL_RELEASE:-$(uname -r)}
    kid=$(kernel_pkgbase_for_version "$running" 2>/dev/null || true)
    [[ -n $kid ]] || { fail "rEFInd runtime proof could not resolve pkgbase for running kernel $running"; return 1; }
    expected="vmlinuz-$kid"
    previous=$(r33_refind_previous_boot_text 2>/dev/null || true)
    [[ -n $previous ]] || {
        fail 'rEFInd runtime proof could not read PreviousBoot from disk-backed vars or EFI NVRAM'
        return 1
    }
    lower_previous=${previous,,}
    source_efi_base=${PENDING_OLD_BOOT_EFI_PATH##*\\}
    source_efi_base=${source_efi_base##*/}
    if [[ -n $source_efi_base && $lower_previous == *"${source_efi_base,,}"* ]]; then
        fail "rEFInd PreviousBoot shows the protected source EFI loader was chainloaded ($source_efi_base); direct-kernel runtime proof is refused"
        return 1
    fi
    [[ $lower_previous == *"${expected,,}"* ]] || {
        fail "rEFInd PreviousBoot does not prove the running CachyOS kernel was launched directly (expected $expected; recorded: $previous)"
        return 1
    }
    ok "rEFInd PreviousBoot proves direct launch of the running CachyOS kernel ($expected)"
}

# Keep r26's NVRAM/EFI/hash checks, but use the r33 immutable rEFInd tree
# verifier above and, only from an actually booted rEFInd target session,
# require direct-kernel PreviousBoot proof before runtime certification can
# progress to phase=runtime-validated.
verify_pending_candidate_ownership_unchanged() {
    verify_pending_candidate_ownership_unchanged_pre_r33 "$@" || return 1
    if [[ ${PENDING_FORMAT:-} == "$R26_PENDING_FORMAT" && ${PENDING_TARGET:-} == refind && ${BOOTLOADER:-} == refind ]]; then
        case "${PENDING_PHASE:-}" in
            boot-armed|runtime-validated) r33_verify_refind_direct_kernel_launch || return 1 ;;
        esac
    fi
    return 0
}
