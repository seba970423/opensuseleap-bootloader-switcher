#!/usr/bin/env bash
# r39: reconcile Limine menu entries against ownership-proven source retirement.
#
# Real hardware exposed a post-finalization defect in r37: rEFInd -> Limine
# correctly retired /EFI/refind and the rEFInd NVRAM entry, but the Limine
# candidate had discovered rEFInd while the source was intentionally still
# present and kept a stale EFI chainload stanza in limine.conf. Selecting that
# zombie entry later panicked because the source path had (correctly) been
# removed.
#
# r39 closes that gap without weakening candidate ownership. Immediately before
# source retirement, while the source is still intact and recoverable, it:
#   1. re-proves the original target ownership manifest;
#   2. removes only Limine menu stanza(s) whose path resolves exactly to the
#      recorded source EFI executable;
#   3. proves no such path remains and deep-validates Limine again;
#   4. re-records the target ownership manifest to cover the reconciled config;
#   5. only then allows ownership-gated source retirement.
#
# Final Limine validation also asserts that no menu path points at the retired
# source EFI executable. The generic EFI fallback entry is deliberately not
# touched: EFI/BOOT/BOOTX64.EFI is target fallback state, not source residue.

r39_normalize_efi_path() {
    local value=${1:-}
    value=${value%%#*}
    case "$value" in
        boot\(\):*) value=${value#boot\(\):} ;;
    esac
    value=${value//\\//}
    value=/${value#/}
    printf '%s\n' "${value,,}"
}

r39_limine_source_reference_count() {
    local conf=$1 source_path=$2 want
    want=$(r39_normalize_efi_path "$source_path")
    awk -v want="$want" '
        function norm(v) {
            sub(/^[[:space:]]*path:[[:space:]]*/, "", v)
            sub(/#.*/, "", v)
            gsub(/\\/, "/", v)
            sub(/^boot\(\):/, "", v)
            if (substr(v,1,1) != "/") v="/" v
            return tolower(v)
        }
        /^[[:space:]]*path:[[:space:]]*/ {
            if (norm($0) == want) count++
        }
        END { print count+0 }
    ' "$conf"
}

# Rewrite limine.conf by removing only complete menu chunks whose path: field
# resolves exactly to the recorded source EFI path. A chunk begins at any
# Limine menu heading (/entry, //child, /+group, ...), so unrelated kernel,
# fallback, and foreign EFI entries are preserved byte-for-byte.
r39_strip_limine_source_entries() {
    local conf=$1 source_path=$2 out=$3 count_file=$4 want
    want=$(r39_normalize_efi_path "$source_path")
    awk -v want="$want" -v count_file="$count_file" '
        function norm_path(v) {
            sub(/^[[:space:]]*path:[[:space:]]*/, "", v)
            sub(/#.*/, "", v)
            gsub(/\\/, "/", v)
            sub(/^boot\(\):/, "", v)
            if (substr(v,1,1) != "/") v="/" v
            return tolower(v)
        }
        function is_heading(v) {
            return v ~ /^[[:space:]]*\/+[^\/[:space:]]/
        }
        function flush(    i,drop) {
            if (n == 0) return
            drop=0
            for (i=1; i<=n; i++) {
                if (buf[i] ~ /^[[:space:]]*path:[[:space:]]*/ && norm_path(buf[i]) == want) {
                    drop=1
                }
            }
            if (drop) {
                removed++
            } else {
                for (i=1; i<=n; i++) print buf[i]
            }
            delete buf
            n=0
        }
        {
            if (is_heading($0)) flush()
            buf[++n]=$0
        }
        END {
            flush()
            print removed+0 > count_file
        }
    ' "$conf" >"$out"
}

r39_verify_limine_no_source_reference() {
    local conf=${PENDING_ESP_MOUNT:-${ESP_MOUNT:-/boot}}/limine.conf source_path=${PENDING_OLD_BOOT_EFI_PATH:-} count
    [[ -n $source_path ]] || { fail 'Cannot verify Limine source-retirement references: recorded source EFI path is missing'; return 1; }
    if sudo -n test -r "$conf" 2>/dev/null; then
        count=$(sudo -n cat -- "$conf" 2>/dev/null | awk -v want="$(r39_normalize_efi_path "$source_path")" '
            function norm(v) { sub(/^[[:space:]]*path:[[:space:]]*/, "", v); sub(/#.*/, "", v); gsub(/\\/, "/", v); sub(/^boot\(\):/, "", v); if (substr(v,1,1)!="/") v="/" v; return tolower(v) }
            /^[[:space:]]*path:[[:space:]]*/ { if (norm($0)==want) c++ }
            END { print c+0 }
        ')
    elif [[ -r $conf ]]; then
        count=$(r39_limine_source_reference_count "$conf" "$source_path")
    else
        fail "Cannot verify Limine source-retirement references: $conf is unreadable"
        return 1
    fi
    [[ $count == 0 ]] || { fail "Limine still contains $count menu path reference(s) to retired source EFI $source_path"; return 1; }
    ok "Limine has no menu path referencing the retired source EFI executable ($source_path)"
}

r39_refresh_pending_limine_manifest() {
    local target=${PENDING_TARGET:-} record path had_snapshot=0 old_snapshot=''
    [[ $target == limine ]] || return 0
    [[ -n ${PENDING_TARGET_MANIFEST:-} && -n ${PENDING_TRANSACTION_SNAPSHOT_DIR:-} ]] || {
        fail 'Cannot refresh reconciled Limine ownership: pending manifest/snapshot metadata is incomplete'
        return 1
    }
    pending_path_under "$PENDING_TARGET_MANIFEST" "$PENDING_TRANSACTION_SNAPSHOT_DIR" || {
        fail 'Cannot refresh reconciled Limine ownership: target manifest escaped transaction snapshot'
        return 1
    }

    record="$PENDING_TRANSACTION_SNAPSHOT_DIR/.target-owned.r39.$$"
    : >"$record" || return 1
    chmod 600 -- "$record" 2>/dev/null || true
    if [[ ${TRANSACTION_SNAPSHOT_DIR+x} ]]; then had_snapshot=1; old_snapshot=$TRANSACTION_SNAPSHOT_DIR; fi
    TRANSACTION_SNAPSHOT_DIR=$PENDING_TRANSACTION_SNAPSHOT_DIR
    while IFS= read -r path; do
        [[ -n $path ]] || continue
        if ! r26_record_owned_path "$record" "$path"; then
            rm -f -- "$record"
            if ((had_snapshot)); then TRANSACTION_SNAPSHOT_DIR=$old_snapshot; else unset TRANSACTION_SNAPSHOT_DIR; fi
            return 1
        fi
    done < <(r26_adapter_paths limine)
    if ((had_snapshot)); then TRANSACTION_SNAPSHOT_DIR=$old_snapshot; else unset TRANSACTION_SNAPSHOT_DIR; fi
    [[ -s $record ]] || { rm -f -- "$record"; fail 'Reconciled Limine ownership manifest would be empty'; return 1; }
    mv -f -- "$record" "$PENDING_TARGET_MANIFEST" || return 1
    ok 'Re-recorded exact Limine target ownership after source-chainloader reconciliation'
}

r39_restore_pre_reconcile_state() {
    local conf=$1 conf_snapshot=$2 manifest_snapshot=$3
    local rc=0
    if [[ -f $conf_snapshot ]]; then
        sudo install -o root -g root -m 0644 -- "$conf_snapshot" "$conf" || rc=1
    else
        rc=1
    fi
    if [[ -f $manifest_snapshot ]]; then
        cp -f -- "$manifest_snapshot" "$PENDING_TARGET_MANIFEST" || rc=1
    else
        rc=1
    fi
    if ((rc == 0)); then
        warn 'Reverted the pre-retirement Limine reconciliation because a post-edit safety gate failed; source retirement was not attempted.'
    else
        fail 'Could not fully revert the pre-retirement Limine reconciliation. Do not reboot until target/source state is inspected.'
    fi
    return "$rc"
}

r39_reconcile_limine_before_source_retirement() {
    local conf=${PENDING_ESP_MOUNT:-${ESP_MOUNT:-/boot}}/limine.conf source_path=${PENDING_OLD_BOOT_EFI_PATH:-}
    local before tmp count_file removed after snapshot manifest_snapshot hash

    [[ ${PENDING_TARGET:-} == limine ]] || return 0
    [[ -n $source_path ]] || { fail 'Limine reconciliation requires the recorded source EFI path'; return 1; }

    # Anchor against the exact candidate that earned runtime proof before making
    # the one narrowly-authorized configuration change.
    verify_pending_candidate_ownership_unchanged || {
        fail 'Limine candidate ownership changed before source-chainloader reconciliation; source retirement is refused'
        return 1
    }

    tmp=$(mktemp) || return 1
    count_file=$(mktemp) || { rm -f -- "$tmp"; return 1; }
    if [[ -r $conf ]]; then
        before=$(r39_limine_source_reference_count "$conf" "$source_path")
        r39_strip_limine_source_entries "$conf" "$source_path" "$tmp" "$count_file" || { rm -f -- "$tmp" "$count_file"; return 1; }
    elif sudo -n test -r "$conf" 2>/dev/null; then
        local readable
        readable=$(mktemp) || { rm -f -- "$tmp" "$count_file"; return 1; }
        sudo -n cat -- "$conf" >"$readable" 2>/dev/null || { rm -f -- "$tmp" "$count_file" "$readable"; return 1; }
        before=$(r39_limine_source_reference_count "$readable" "$source_path")
        r39_strip_limine_source_entries "$readable" "$source_path" "$tmp" "$count_file" || { rm -f -- "$tmp" "$count_file" "$readable"; return 1; }
        rm -f -- "$readable"
    else
        rm -f -- "$tmp" "$count_file"
        fail "Cannot reconcile Limine source references because $conf is unreadable"
        return 1
    fi

    removed=$(cat -- "$count_file" 2>/dev/null || printf '0')
    rm -f -- "$count_file"
    [[ $removed =~ ^[0-9]+$ && $before =~ ^[0-9]+$ && $removed == "$before" ]] || {
        rm -f -- "$tmp"
        fail "Limine reconciliation accounting mismatch (found=$before removed=$removed)"
        return 1
    }

    if ((before == 0)); then
        rm -f -- "$tmp"
        ok 'Limine candidate has no source-EFI chainloader entry to reconcile before retirement'
        return 0
    fi

    snapshot="$PENDING_TRANSACTION_SNAPSHOT_DIR/limine.conf.pre-source-retirement"
    manifest_snapshot="$PENDING_TRANSACTION_SNAPSHOT_DIR/target-owned.pre-r39.tsv"
    if [[ -r $conf ]]; then cat -- "$conf" >"$snapshot"; else sudo -n cat -- "$conf" >"$snapshot"; fi || { rm -f -- "$tmp"; return 1; }
    cp -f -- "$PENDING_TARGET_MANIFEST" "$manifest_snapshot" || { rm -f -- "$tmp"; return 1; }
    chmod 600 -- "$snapshot" "$manifest_snapshot" 2>/dev/null || true
    hash=$(sha256sum -- "$snapshot" 2>/dev/null | awk '{print $1}' || true)
    [[ $hash =~ ^[0-9A-Fa-f]{64}$ ]] || { rm -f -- "$tmp"; fail 'Could not snapshot pre-retirement Limine config'; return 1; }

    sudo install -o root -g root -m 0644 -- "$tmp" "$conf" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
    after=$(sudo -n cat -- "$conf" 2>/dev/null | awk -v want="$(r39_normalize_efi_path "$source_path")" '
        function norm(v) { sub(/^[[:space:]]*path:[[:space:]]*/, "", v); sub(/#.*/, "", v); gsub(/\\/, "/", v); sub(/^boot\(\):/, "", v); if (substr(v,1,1)!="/") v="/" v; return tolower(v) }
        /^[[:space:]]*path:[[:space:]]*/ { if (norm($0)==want) c++ }
        END { print c+0 }
    ')
    if [[ $after != 0 ]]; then
        fail 'Limine source-chainloader reconciliation did not remove every exact source EFI reference'
        r39_restore_pre_reconcile_state "$conf" "$snapshot" "$manifest_snapshot" || true
        return 1
    fi
    ok "Removed $before stale Limine source-chainloader menu entr$([[ $before == 1 ]] && printf 'y' || printf 'ies') before source retirement"

    # The candidate manifest intentionally covered the pre-reconciliation config.
    # Re-baseline only after the exact authorized edit and another deep target
    # validation, while the source recovery path still exists. Any failure in
    # this mini-transaction restores both the old config and the old manifest so
    # normal pending rollback/retry remains available.
    if ! adapter_target_validate limine; then
        fail 'Reconciled Limine config failed deep validation; source retirement is refused'
        r39_restore_pre_reconcile_state "$conf" "$snapshot" "$manifest_snapshot" || true
        return 1
    fi
    if ! r39_refresh_pending_limine_manifest; then
        r39_restore_pre_reconcile_state "$conf" "$snapshot" "$manifest_snapshot" || true
        return 1
    fi
    if ! verify_pending_candidate_ownership_unchanged; then
        fail 'Reconciled Limine ownership could not be re-proven; source retirement is refused'
        r39_restore_pre_reconcile_state "$conf" "$snapshot" "$manifest_snapshot" || true
        return 1
    fi
    if ! r39_verify_limine_no_source_reference; then
        r39_restore_pre_reconcile_state "$conf" "$snapshot" "$manifest_snapshot" || true
        return 1
    fi
    return 0
}

# Interpose immediately before ownership-gated source retirement. If anything
# about reconciliation fails, the source remains intact and authoritative.
eval "$(declare -f adapter_source_retire | sed '1s/adapter_source_retire/adapter_source_retire_pre_r39/')"
adapter_source_retire() {
    if [[ ${PENDING_FORMAT:-} == "$R26_PENDING_FORMAT" && ${PENDING_TARGET:-} == limine ]]; then
        r39_reconcile_limine_before_source_retirement || return 1
    fi
    adapter_source_retire_pre_r39 "$@"
}

# Add the missing post-retirement invariant to final Limine validation.
eval "$(declare -f adapter_target_final_validate | sed '1s/adapter_target_final_validate/adapter_target_final_validate_pre_r39/')"
adapter_target_final_validate() {
    local target=$1
    adapter_target_final_validate_pre_r39 "$@" || return 1
    if [[ ${PENDING_FORMAT:-} == "$R26_PENDING_FORMAT" && $target == limine && -n ${PENDING_OLD_BOOT_EFI_PATH:-} ]]; then
        r39_verify_limine_no_source_reference || return 1
    fi
    return 0
}
