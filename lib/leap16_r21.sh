#!/usr/bin/env bash

# leap16-r21 forward completion layer
# -----------------------------------
# r20 hardware-proved the primary GRUB2 -> Limine one-shot transaction but
# deliberately retained native openSUSE GRUB2 and kept EFI/BOOT/BOOTX64.EFI as
# the openSUSE shim.  r21 completes that forward transaction in a second,
# independently runtime-proven phase:
#
#   1. prove the canonical Limine Boot#### exactly as r20 did;
#   2. promote canonical Limine while GRUB2 is still intact;
#   3. replace the generic fallback with byte-identical Limine, create/adopt one
#      exact \EFI\BOOT\BOOTX64.EFI firmware alias, and test it with BootNext;
#   4. only after BootCurrent proves that exact fallback alias, retire the exact
#      pre-staged native openSUSE GRUB2 NVRAM/EFI/config ownership.
#
# No package removal is mixed into the boot-state transaction.  The reverse
# Limine -> GRUB2 adapter remains fail-closed when the retained native GRUB2
# target no longer exists; rebuilding GRUB2 is a separate adapter problem.

LEAP16_R21_FALLBACK_EFI_PATH='\EFI\BOOT\BOOTX64.EFI'
LEAP16_R21_FALLBACK_LABEL='UEFI OS'
LEAP16_R21_META_BASENAME='r21-limine-fallback.tsv'
LEAP16_R21_PRECONF_BASENAME='r21-primary-proven-limine.conf'
LEAP16_R21_FINALCONF_BASENAME='r21-final-limine.conf'

r21_forward_pending() {
    [[ ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == grub:limine ]]
}

r21_fallback_meta_path() {
    [[ -n ${PENDING_TRANSACTION_SNAPSHOT_DIR:-} ]] || return 1
    printf '%s/%s\n' "$PENDING_TRANSACTION_SNAPSHOT_DIR" "$LEAP16_R21_META_BASENAME"
}

r21_preconf_path() {
    [[ -n ${PENDING_TRANSACTION_SNAPSHOT_DIR:-} ]] || return 1
    printf '%s/%s\n' "$PENDING_TRANSACTION_SNAPSHOT_DIR" "$LEAP16_R21_PRECONF_BASENAME"
}

r21_fallback_meta_exists() {
    local p
    p=$(r21_fallback_meta_path 2>/dev/null || true)
    [[ -n $p && -s $p ]]
}

r21_meta_value() {
    local key=$1 p
    p=$(r21_fallback_meta_path) || return 1
    awk -F'\t' -v k="$key" '$1==k {print $2; exit}' "$p" 2>/dev/null
}

r21_hash_privileged() {
    local path=$1
    sudo -n sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || true
}

r21_atomic_replace() {
    local src=$1 dst=$2 expected_hash=$3 tmp dir actual
    [[ -r $src ]] || { fail "Replacement source is unreadable: $src"; return 1; }
    dir=$(dirname -- "$dst")
    tmp="$dir/.r21.$(basename -- "$dst").$$"
    sudo mkdir -p -- "$dir" || return 1
    sudo rm -f -- "$tmp" 2>/dev/null || true
    sudo cp -- "$src" "$tmp" || { sudo rm -f -- "$tmp" 2>/dev/null || true; return 1; }
    actual=$(r21_hash_privileged "$tmp")
    [[ $actual == "$expected_hash" ]] || {
        sudo rm -f -- "$tmp" 2>/dev/null || true
        fail "Replacement payload hash mismatch for $dst"
        return 1
    }
    sudo chmod 0644 -- "$tmp" 2>/dev/null || true
    sudo mv -f -- "$tmp" "$dst" || { sudo rm -f -- "$tmp" 2>/dev/null || true; return 1; }
    actual=$(r21_hash_privileged "$dst")
    [[ $actual == "$expected_hash" ]] || { fail "Installed payload hash mismatch for $dst"; return 1; }
    sudo sync -f "$dst" 2>/dev/null || sudo sync 2>/dev/null || true
    return 0
}

# Generated r20 configs have one exact final recovery block.  Rewrite it only
# after the canonical Limine runtime proof so replacing EFI/BOOT cannot turn
# Limine's own recovery menu entry into a recursive Limine chain.
r21_rewrite_recovery_to_direct_grub() {
    local conf=$PENDING_LIMINE_CONF_PATH preconf tmp out current expected found=0 line a b c d new_hash
    preconf=$(r21_preconf_path) || return 1
    current=$(r21_hash_privileged "$conf")
    expected=$PENDING_LIMINE_CONF_HASH
    [[ $current == "$expected" ]] || { fail 'limine.conf changed before fallback ownership transfer'; return 1; }

    sudo -n cat -- "$conf" >"$preconf" 2>/dev/null || cat -- "$conf" >"$preconf" 2>/dev/null || return 1
    [[ $(sha256sum -- "$preconf" | awk '{print $1}') == "$expected" ]] || { fail 'Could not snapshot the primary-proven limine.conf exactly'; return 1; }
    chmod 600 -- "$preconf" 2>/dev/null || true

    tmp=$(mktemp) || return 1
    out=$(mktemp) || { rm -f -- "$tmp"; return 1; }
    if sudo -n cat -- "$conf" >"$tmp" 2>/dev/null; then :; else cat -- "$conf" >"$tmp" || { rm -f -- "$tmp" "$out"; return 1; }; fi

    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == '/EFI fallback' ]]; then
            IFS= read -r a || { rm -f -- "$tmp" "$out"; fail 'Truncated EFI fallback block in limine.conf'; return 1; }
            IFS= read -r b || { rm -f -- "$tmp" "$out"; fail 'Truncated EFI fallback block in limine.conf'; return 1; }
            IFS= read -r c || { rm -f -- "$tmp" "$out"; fail 'Truncated EFI fallback block in limine.conf'; return 1; }
            IFS= read -r d || { rm -f -- "$tmp" "$out"; fail 'Truncated EFI fallback block in limine.conf'; return 1; }
            [[ $c == 'protocol: efi' && $d == 'path: boot():/EFI/BOOT/BOOTX64.EFI' ]] || {
                rm -f -- "$tmp" "$out"
                fail 'The generated EFI fallback block no longer matches the r20 transaction contract'
                return 1
            }
            {
                printf '/openSUSE GRUB2 recovery\n'
                printf '### Temporary direct recovery path retained until Limine fallback proof completes\n'
                printf 'comment: Native openSUSE shim/GRUB2 recovery path\n'
                printf 'protocol: efi\n'
                printf 'path: boot():/EFI/OPENSUSE/SHIM.EFI\n'
            } >>"$out"
            found=$((found + 1))
        else
            printf '%s\n' "$line" >>"$out"
        fi
    done <"$tmp"
    rm -f -- "$tmp"
    [[ $found == 1 ]] || { rm -f -- "$out"; fail "Expected exactly one generated EFI fallback block, found $found"; return 1; }
    new_hash=$(sha256sum -- "$out" | awk '{print $1}')
    r21_atomic_replace "$out" "$conf" "$new_hash" || { rm -f -- "$out"; return 1; }
    rm -f -- "$out"
    printf '%s\n' "$new_hash"
}

r21_remove_direct_grub_recovery_block() {
    local conf=$PENDING_LIMINE_CONF_PATH tmp out current expected found=0 line a b c d new_hash final_snap
    expected=$(r21_meta_value transferred_limine_conf_hash)
    current=$(r21_hash_privileged "$conf")
    [[ -n $expected && $current == "$expected" ]] || { fail 'Transferred limine.conf changed before GRUB2 retirement'; return 1; }
    tmp=$(mktemp) || return 1
    out=$(mktemp) || { rm -f -- "$tmp"; return 1; }
    sudo -n cat -- "$conf" >"$tmp" 2>/dev/null || cat -- "$conf" >"$tmp" || { rm -f -- "$tmp" "$out"; return 1; }
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == '/openSUSE GRUB2 recovery' ]]; then
            IFS= read -r a || { rm -f -- "$tmp" "$out"; return 1; }
            IFS= read -r b || { rm -f -- "$tmp" "$out"; return 1; }
            IFS= read -r c || { rm -f -- "$tmp" "$out"; return 1; }
            IFS= read -r d || { rm -f -- "$tmp" "$out"; return 1; }
            [[ $c == 'protocol: efi' && $d == 'path: boot():/EFI/OPENSUSE/SHIM.EFI' ]] || {
                rm -f -- "$tmp" "$out"; fail 'Direct GRUB2 recovery block changed before retirement'; return 1;
            }
            found=$((found + 1))
            # Drop this temporary block entirely in the finalized Limine config.
        else
            printf '%s\n' "$line" >>"$out"
        fi
    done <"$tmp"
    rm -f -- "$tmp"
    [[ $found == 1 ]] || { rm -f -- "$out"; fail "Expected exactly one direct GRUB2 recovery block, found $found"; return 1; }
    new_hash=$(sha256sum -- "$out" | awk '{print $1}')
    r21_atomic_replace "$out" "$conf" "$new_hash" || { rm -f -- "$out"; return 1; }
    final_snap="$PENDING_TRANSACTION_SNAPSHOT_DIR/$LEAP16_R21_FINALCONF_BASENAME"
    cp -- "$out" "$final_snap" 2>/dev/null || true
    chmod 600 -- "$final_snap" 2>/dev/null || true
    rm -f -- "$out"
    printf '%s\n' "$new_hash"
}

r21_baseline_line_for_id() {
    local id=${1^^} baseline
    baseline=$(leap16_pending_firmware_baseline_path 2>/dev/null || true)
    [[ -n $baseline && -r $baseline ]] || return 1
    awk -v id="$id" 'BEGIN{IGNORECASE=1} $0 ~ "^Boot" id "\\*?([[:space:]]|$)" {print; exit}' "$baseline"
}

r21_source_grub_ids_from_baseline() {
    local baseline line id path norm partuuid lower
    baseline=$(leap16_pending_firmware_baseline_path 2>/dev/null || true)
    [[ -n $baseline && -r $baseline ]] || { fail 'Pre-stage firmware baseline is unavailable for GRUB2 retirement ownership'; return 1; }
    partuuid=$(lsblk -no PARTUUID -- "$PENDING_ESP_SOURCE" 2>/dev/null | awk 'NF{print tolower($1); exit}')
    while IFS= read -r line; do
        [[ $line =~ ^Boot([0-9A-Fa-f]{4})\*? ]] || continue
        id=${BASH_REMATCH[1]^^}
        path=$(efi_path_from_efibootmgr_line "$line" 2>/dev/null || true)
        [[ -n $path ]] || continue
        norm=$(normalize_efi_path "$path" | tr '[:upper:]' '[:lower:]')
        case "$norm" in
            efi/opensuse/shim.efi|efi/opensuse/grubx64.efi|efi/opensuse/grub.efi) ;;
            *) continue ;;
        esac
        lower=${line,,}
        [[ -z $partuuid || $lower == *"$partuuid"* ]] || continue
        printf '%s\n' "$id"
    done <"$baseline"
}

r21_current_native_grub_ids() {
    local line id path norm partuuid lower
    partuuid=$(lsblk -no PARTUUID -- "$PENDING_ESP_SOURCE" 2>/dev/null | awk 'NF{print tolower($1); exit}')
    while IFS= read -r line; do
        [[ $line =~ ^Boot([0-9A-Fa-f]{4})\*? ]] || continue
        id=${BASH_REMATCH[1]^^}
        path=$(efi_path_from_efibootmgr_line "$line" 2>/dev/null || true)
        [[ -n $path ]] || continue
        norm=$(normalize_efi_path "$path" | tr '[:upper:]' '[:lower:]')
        case "$norm" in
            efi/opensuse/shim.efi|efi/opensuse/grubx64.efi|efi/opensuse/grub.efi) ;;
            *) continue ;;
        esac
        lower=${line,,}
        [[ -z $partuuid || $lower == *"$partuuid"* ]] || continue
        printf '%s\n' "$id"
    done < <(efibootmgr -v 2>/dev/null)
}

r21_ids_csv_sorted() {
    tr ',' '\n' <<<"${1:-}" | awk 'NF{print toupper($0)}' | LC_ALL=C sort -u | paste -sd, -
}

r21_source_grub_ids_csv() {
    local id csv="" count=0 saw_source=0
    while IFS= read -r id; do
        [[ $id =~ ^[0-9A-F]{4}$ ]] || continue
        [[ $id == ${PENDING_OLD_BOOT_ID^^} ]] && saw_source=1
        [[ ,$csv, == *,$id,* ]] && continue
        if [[ -n $csv ]]; then csv+=",$id"; else csv=$id; fi
        count=$((count + 1))
    done < <(r21_source_grub_ids_from_baseline)
    ((count > 0 && saw_source == 1)) || { fail 'Could not derive the exact native openSUSE GRUB2 NVRAM ownership set'; return 1; }
    printf '%s\n' "$csv"
}

r21_verify_source_grub_nvram_ids() {
    local csv=$1 id baseline_line current_line baseline_path current_path
    local -a ids=()
    IFS=',' read -ra ids <<<"$csv"
    ((${#ids[@]} > 0)) || return 1
    for id in "${ids[@]}"; do
        id=${id^^}
        boot_id_exists "$id" || { fail "Ownership-proven native GRUB2 Boot$id disappeared before retirement"; return 1; }
        baseline_line=$(r21_baseline_line_for_id "$id") || { fail "No firmware baseline exists for source Boot$id"; return 1; }
        current_line=$(leap16_boot_entry_line_for_id "$id")
        [[ -n $current_line ]] || { fail "Current source Boot$id could not be read"; return 1; }
        baseline_path=$(efi_path_from_efibootmgr_line "$baseline_line" 2>/dev/null || true)
        current_path=$(efi_path_from_efibootmgr_line "$current_line" 2>/dev/null || true)
        [[ -n $baseline_path && -n $current_path && $(normalize_efi_path "$baseline_path" | tr '[:upper:]' '[:lower:]') == $(normalize_efi_path "$current_path" | tr '[:upper:]' '[:lower:]') ]] || {
            fail "Source Boot$id EFI path changed since the pre-stage baseline"
            return 1
        }
        leap16_nvram_entry_matches_current_esp "$id" || { fail "Source Boot$id is no longer bound to the transaction ESP"; return 1; }
    done
    local current_csv current_sorted expected_sorted
    current_csv=$(r21_current_native_grub_ids | paste -sd, -)
    current_sorted=$(r21_ids_csv_sorted "$current_csv")
    expected_sorted=$(r21_ids_csv_sorted "$csv")
    [[ $current_sorted == "$expected_sorted" ]] || {
        fail "Native openSUSE GRUB2 alias set changed since staging (expected ${expected_sorted:-none}, current ${current_sorted:-none})"
        return 1
    }
    ok "Native openSUSE GRUB2 NVRAM ownership set is unchanged: Boot${csv//,/ Boot}"
}

r21_verify_grub_cleanup_ownership() {
    local dm em rec efi_dir present expected actual
    dm=$(r23_source_grub_dir_manifest_path)
    em=$(r23_source_grub_efi_dir_manifest_path)
    rec=$(r23_source_grub_default_record_path)
    [[ -s $dm && -s $em && -f $rec ]] || { fail 'Native openSUSE GRUB2 retirement manifests are missing'; return 1; }
    pending_verify_tree_manifest /boot/grub2 "$dm" || { fail 'Source /boot/grub2 changed since staging'; return 1; }
    efi_dir=$(dirname -- "$PENDING_OLD_GRUB_EFI_RESOLVED")
    pending_verify_tree_manifest "$efi_dir" "$em" || { fail 'Source EFI/OPENSUSE namespace changed since staging'; return 1; }
    present=$(awk -F'\t' '$1=="present"{print $2; exit}' "$rec")
    expected=$(awk -F'\t' '$1=="hash"{print $2; exit}' "$rec")
    if [[ $present == 1 ]]; then
        actual=$(r21_hash_privileged /etc/default/grub)
        [[ -n $actual && $actual == "$expected" ]] || { fail 'Source /etc/default/grub changed since staging'; return 1; }
    else
        [[ ! -e /etc/default/grub ]] || { fail '/etc/default/grub appeared after the source ownership snapshot'; return 1; }
    fi
    ok 'Native openSUSE GRUB2 filesystem/config ownership remains exact for retirement'
}

r21_fallback_ids_now() {
    r21_nvram_ids_for_esp_path "$LEAP16_R21_FALLBACK_EFI_PATH"
}

# Fallback staging begins only after proving that there are zero firmware
# aliases for the generic path. Every exact matching alias that appears before
# metadata is committed therefore belongs to this staging attempt (explicitly
# created by us or synthesized by firmware after the payload changed). This
# lets rollback clean up even if alias creation fails before returning one ID.
r21_remove_staging_fallback_aliases() {
    local id failures=0
    while IFS= read -r id; do
        [[ $id =~ ^[0-9A-Fa-f]{4}$ ]] || continue
        id=${id^^}
        leap16_nvram_entry_matches_current_esp "$id" || {
            fail "Refusing to remove fallback-path Boot$id because it is not bound to the transaction ESP"
            failures=$((failures + 1))
            continue
        }
        if sudo efibootmgr -b "$id" -B >/dev/null 2>&1; then
            ok "Removed transaction-staged fallback alias Boot$id during rollback"
        else
            fail "Could not remove transaction-staged fallback alias Boot$id during rollback"
            failures=$((failures + 1))
        fi
    done < <(r21_fallback_ids_now)
    ((failures == 0))
}

r21_create_or_adopt_fallback_alias() {
    local topology disk part id count before after
    local -a ids=()
    mapfile -t ids < <(r21_fallback_ids_now)
    count=${#ids[@]}
    if ((count == 1)); then
        id=${ids[0]^^}
        leap16_boot_entry_is_active "$id" || { fail "Firmware-synthesized fallback Boot$id is not active"; return 1; }
        leap16_nvram_entry_matches_current_esp "$id" || { fail "Existing fallback Boot$id is not bound to this ESP"; return 1; }
        ok "Firmware synthesized an exact fallback alias after Limine fallback installation; adopting Boot$id" >&2
        printf '%s\n' "$id"
        return 0
    elif ((count > 1)); then
        fail "Fallback NVRAM path is ambiguous after payload installation (${count} aliases)"
        return 1
    fi

    efibootmgr --help 2>&1 | grep -q -- '--create-only' || { fail 'Installed efibootmgr lacks --create-only for explicit fallback alias creation'; return 1; }
    topology=$(leap16_esp_disk_part) || { fail 'Could not derive ESP disk/partition for fallback alias creation'; return 1; }
    disk=${topology%%$'\t'*}; part=${topology#*$'\t'}
    before=$(efibootmgr -v 2>/dev/null | grep -Ei '^Boot[0-9A-Fa-f]{4}\*?[[:space:]]' | LC_ALL=C sort || true)
    sudo efibootmgr --create-only --disk "$disk" --part "$part" --label "$LEAP16_R21_FALLBACK_LABEL" --loader "$LEAP16_R21_FALLBACK_EFI_PATH" >/dev/null || {
        fail 'Could not explicitly create the Limine EFI fallback Boot#### alias'
        return 1
    }
    mapfile -t ids < <(r21_fallback_ids_now)
    ((${#ids[@]} == 1)) || { fail 'Explicit fallback alias creation did not result in exactly one matching Boot####'; return 1; }
    id=${ids[0]^^}
    leap16_boot_entry_is_active "$id" || { fail "New fallback Boot$id is not active"; return 1; }
    leap16_nvram_entry_matches_current_esp "$id" || { fail "New fallback Boot$id is not bound to this ESP"; return 1; }
    after=$(efibootmgr -v 2>/dev/null | awk -v tid="$id" 'BEGIN{IGNORECASE=1} /^Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/ {x=substr($1,5,4); gsub(/\*/,"",x); if (toupper(x) != toupper(tid)) print}' | LC_ALL=C sort)
    [[ $after == "$before" ]] || { fail 'A pre-existing Boot#### changed during explicit fallback --create-only'; return 1; }
    ok "Explicitly created Limine fallback alias Boot$id -> $LEAP16_R21_FALLBACK_EFI_PATH" >&2
    printf '%s\n' "$id"
}

r21_order_primary_fallback_then_existing() {
    local fallback_id=${1^^} order id joined
    local -a current=() out=("${PENDING_TARGET_BOOT_ID^^}" "$fallback_id")
    order=$(leap16_current_boot_order) || return 1
    IFS=',' read -ra current <<<"$order"
    for id in "${current[@]}"; do
        id=${id^^}
        [[ -n $id && $id != ${PENDING_TARGET_BOOT_ID^^} && $id != "$fallback_id" ]] || continue
        boot_id_exists "$id" && out+=("$id")
    done
    joined=$(IFS=,; printf '%s' "${out[*]}")
    sudo efibootmgr -o "$joined" >/dev/null || return 1
    order=$(leap16_current_boot_order)
    [[ ${order%%,*} == ${PENDING_TARGET_BOOT_ID^^} && ${order#*,} != "$order" && ${order#*,} == "$fallback_id"* ]] || {
        fail "Could not establish Limine primary/fallback-first topology (current $order)"
        return 1
    }
    printf '%s\n' "$order"
}

r21_order_primary_then_source_recovery() {
    local order id joined source=${PENDING_OLD_BOOT_ID^^} target=${PENDING_TARGET_BOOT_ID^^}
    local -a current=() out=("$target" "$source")
    order=$(leap16_current_boot_order 2>/dev/null || true)
    IFS=',' read -ra current <<<"$order"
    for id in "${current[@]}"; do
        id=${id^^}
        [[ -n $id && $id != "$target" && $id != "$source" ]] || continue
        boot_id_exists "$id" && out+=("$id")
    done
    joined=$(IFS=,; printf '%s' "${out[*]}")
    sudo efibootmgr -o "$joined" >/dev/null || return 1
    [[ $(leap16_current_boot_order | cut -d, -f1,2) == "$target,$source" ]]
}

r21_order_final_primary_fallback() {
    local fallback_id=${1^^} order id joined
    local -a current=() out=("${PENDING_TARGET_BOOT_ID^^}" "$fallback_id")
    order=$(leap16_current_boot_order 2>/dev/null || true)
    IFS=',' read -ra current <<<"$order"
    for id in "${current[@]}"; do
        id=${id^^}
        [[ -n $id && $id != ${PENDING_TARGET_BOOT_ID^^} && $id != "$fallback_id" ]] || continue
        boot_id_exists "$id" && out+=("$id")
    done
    joined=$(IFS=,; printf '%s' "${out[*]}")
    sudo efibootmgr -o "$joined" >/dev/null || return 1
    order=$(leap16_current_boot_order)
    [[ $order == "${PENDING_TARGET_BOOT_ID^^},$fallback_id"* ]] || { fail "Final Limine primary/fallback ordering failed ($order)"; return 1; }
    printf '%s\n' "$order"
}

r21_write_fallback_meta() {
    local fallback_id=${1^^} conf_hash=$2 source_ids=$3 fallback_hash=$4 p tmp
    p=$(r21_fallback_meta_path) || return 1
    tmp="$p.tmp.$$"
    {
        printf 'format\t1\n'
        printf 'fallback_boot_id\t%s\n' "$fallback_id"
        printf 'fallback_efi_path\t%s\n' "$LEAP16_R21_FALLBACK_EFI_PATH"
        printf 'fallback_label\t%s\n' "$LEAP16_R21_FALLBACK_LABEL"
        printf 'fallback_hash\t%s\n' "$fallback_hash"
        printf 'primary_hash\t%s\n' "$PENDING_TARGET_EFI_HASH"
        printf 'transferred_limine_conf_hash\t%s\n' "$conf_hash"
        printf 'source_grub_ids\t%s\n' "$source_ids"
        printf 'created\t%s\n' "$(date -Is)"
    } >"$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 600 -- "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$p"
}

r21_validate_fallback_meta() {
    local id path hash primary conf_hash source_ids
    r21_fallback_meta_exists || { fail 'Limine fallback transaction metadata is missing'; return 1; }
    id=$(r21_meta_value fallback_boot_id)
    path=$(r21_meta_value fallback_efi_path)
    hash=$(r21_meta_value fallback_hash)
    primary=$(r21_meta_value primary_hash)
    conf_hash=$(r21_meta_value transferred_limine_conf_hash)
    source_ids=$(r21_meta_value source_grub_ids)
    [[ $id =~ ^[0-9A-Fa-f]{4}$ ]] || { fail 'Recorded fallback Boot#### is invalid'; return 1; }
    [[ $path == "$LEAP16_R21_FALLBACK_EFI_PATH" ]] || { fail 'Recorded fallback EFI path is invalid'; return 1; }
    pending_hash_is_sha256 "$hash" && pending_hash_is_sha256 "$primary" && pending_hash_is_sha256 "$conf_hash" || { fail 'Fallback transaction hash metadata is invalid'; return 1; }
    [[ $hash == "$primary" && $primary == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'Fallback metadata is not byte-bound to the recorded primary Limine EFI'; return 1; }
    [[ $source_ids =~ ^[0-9A-Fa-f]{4}(,[0-9A-Fa-f]{4})*$ ]] || { fail 'Recorded GRUB2 NVRAM retirement set is invalid/empty'; return 1; }
    return 0
}

r21_sync_fallback_sidecars_to_user() {
    local conf=$1 user_snapshot uid gid p pre
    r22_user_shadow_matches_conf "$conf" || return 1
    user_snapshot=$(r22_conf_value "$conf" user_snapshot_dir)
    uid=$(r22_conf_value "$conf" user_uid); gid=$(r22_conf_value "$conf" user_gid)
    [[ $(r22_realpath_m "$user_snapshot") == $(r22_realpath_m "$(dirname -- "$(r22_conf_value "$conf" user_state_file)")")/.prestage.* ]] || return 1
    mkdir -p -- "$user_snapshot" || return 1
    p=$(r21_fallback_meta_path) || return 1
    pre=$(r21_preconf_path) || return 1
    [[ -f $p && -f $pre ]] || return 1
    cp -f -- "$p" "$user_snapshot/$LEAP16_R21_META_BASENAME" || return 1
    cp -f -- "$pre" "$user_snapshot/$LEAP16_R21_PRECONF_BASENAME" || return 1
    [[ $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ ]] && chown "$uid:$gid" -- "$user_snapshot/$LEAP16_R21_META_BASENAME" "$user_snapshot/$LEAP16_R21_PRECONF_BASENAME" 2>/dev/null || true
    chmod 600 -- "$user_snapshot/$LEAP16_R21_META_BASENAME" "$user_snapshot/$LEAP16_R21_PRECONF_BASENAME" 2>/dev/null || true
}

r21_remove_user_fallback_sidecars() {
    local conf=$1 user_snapshot
    r22_user_shadow_matches_conf "$conf" || return 0
    user_snapshot=$(r22_conf_value "$conf" user_snapshot_dir)
    rm -f -- "$user_snapshot/$LEAP16_R21_META_BASENAME" "$user_snapshot/$LEAP16_R21_PRECONF_BASENAME" 2>/dev/null || true
}

r21_verify_transferred_limine_state() {
    local fallback="$PENDING_ESP_MOUNT/EFI/BOOT/BOOTX64.EFI" expected conf_expected actual id
    r21_validate_fallback_meta || return 1
    expected=$(r21_meta_value fallback_hash)
    conf_expected=$(r21_meta_value transferred_limine_conf_hash)
    id=$(r21_meta_value fallback_boot_id); id=${id^^}
    actual=$(r21_hash_privileged "$PENDING_TARGET_EFI_RESOLVED")
    [[ $actual == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'Primary Limine EFI changed after fallback ownership transfer'; return 1; }
    actual=$(r21_hash_privileged "$fallback")
    [[ $actual == "$expected" && $actual == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'EFI/BOOT fallback is no longer byte-identical to canonical Limine'; return 1; }
    actual=$(r21_hash_privileged "$PENDING_LIMINE_CONF_PATH")
    [[ $actual == "$conf_expected" ]] || { fail 'Transferred limine.conf changed before fallback proof'; return 1; }
    boot_id_exists "$id" || { fail "Fallback Boot$id disappeared"; return 1; }
    nvram_id_matches_path "$id" "$LEAP16_R21_FALLBACK_EFI_PATH" || { fail "Fallback Boot$id changed EFI path"; return 1; }
    leap16_nvram_entry_matches_current_esp "$id" || { fail "Fallback Boot$id is no longer bound to the transaction ESP"; return 1; }
    validate_target_state limine || return 1
    validate_limine_boot_chain migration || return 1
    r23_verify_limine_theme_manifest || return 1
    ok 'Primary Limine + explicit byte-identical fallback topology remains exact'
}

r21_restore_pre_fallback_state() {
    local fallback_id=${1:-$(r21_meta_value fallback_boot_id 2>/dev/null || true)} next preconf old_hash actual
    fallback_id=${fallback_id^^}
    next=$(pending_bootnext_id 2>/dev/null || true)
    if [[ -n $fallback_id && ${next^^} == "$fallback_id" ]]; then sudo efibootmgr -N >/dev/null 2>&1 || true; fi

    # The stage precondition proved zero exact fallback aliases. Remove every
    # matching transaction-ESP alias that appeared during this staging attempt,
    # including a firmware-synthesized alias created before one ID was recorded.
    r21_remove_staging_fallback_aliases || return 1

    if [[ ${PENDING_OLD_FALLBACK_EXISTED:-0} == 1 && -f ${PENDING_OLD_FALLBACK_SNAPSHOT:-/nonexistent} ]]; then
        old_hash=$PENDING_OLD_FALLBACK_HASH
        r21_atomic_replace "$PENDING_OLD_FALLBACK_SNAPSHOT" "$PENDING_OLD_FALLBACK_PATH" "$old_hash" || return 1
    fi

    preconf=$(r21_preconf_path 2>/dev/null || true)
    if [[ -n $preconf && -f $preconf ]]; then
        r21_atomic_replace "$preconf" "$PENDING_LIMINE_CONF_PATH" "$PENDING_LIMINE_CONF_HASH" || return 1
    fi

    r21_order_primary_then_source_recovery || return 1
    rm -f -- "$(r21_fallback_meta_path 2>/dev/null || printf /nonexistent)" 2>/dev/null || true
    actual=$(r21_hash_privileged "$PENDING_OLD_FALLBACK_PATH")
    [[ $actual == "$PENDING_OLD_FALLBACK_HASH" ]] || { fail 'Fallback rollback did not restore the original openSUSE shim bytes'; return 1; }
    actual=$(r21_hash_privileged "$PENDING_LIMINE_CONF_PATH")
    [[ $actual == "$PENDING_LIMINE_CONF_HASH" ]] || { fail 'Fallback rollback did not restore the primary-proven limine.conf'; return 1; }
    ok 'Returned to the r20-safe topology: primary Limine first, native GRUB2 retained, shim fallback restored'
}

r21_stage_fallback_test() {
    local conf_hash fallback="$PENDING_ESP_MOUNT/EFI/BOOT/BOOTX64.EFI" fallback_hash fallback_id source_ids order next before_order existing_count
    validate_pending_compatibility || { fail "Pending migration is incompatible: $PENDING_REASON"; return 1; }
    r21_forward_pending || { fail 'Fallback staging is valid only for GRUB2 -> Limine'; return 1; }
    [[ $PENDING_PHASE == runtime-validated ]] || { fail 'Fallback ownership transfer requires primary Limine runtime proof'; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail 'Fallback staging must run from the exact primary Limine Boot#### session'; return 1; }
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext must be clear before the fallback test is staged'; return 1; }
    [[ ${PENDING_OLD_FALLBACK_EXISTED:-0} == 1 ]] || { fail 'r21 requires the snapshotted native openSUSE fallback before transferring fallback ownership'; return 1; }
    fallback_hash=$(r21_hash_privileged "$fallback")
    [[ $fallback_hash == "$PENDING_OLD_FALLBACK_HASH" ]] || { fail 'The original openSUSE fallback changed before ownership transfer'; return 1; }
    existing_count=$(r21_fallback_ids_now | awk 'NF{n++} END{print n+0}')
    ((existing_count == 0)) || { fail "A pre-existing firmware alias already points to EFI/BOOT/BOOTX64.EFI ($existing_count match(es)); refusing ambiguous ownership transfer"; return 1; }

    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1
    verify_pending_source_recovery_unchanged || return 1
    r21_verify_grub_cleanup_ownership || return 1
    source_ids=$(r21_source_grub_ids_csv) || return 1
    r21_verify_source_grub_nvram_ids "$source_ids" || return 1

    conf_hash=$(r21_rewrite_recovery_to_direct_grub) || { fail 'Could not redirect Limine recovery away from EFI/BOOT before fallback transfer'; return 1; }
    if ! r21_atomic_replace "$PENDING_TARGET_EFI_RESOLVED" "$fallback" "$PENDING_TARGET_EFI_HASH"; then
        r21_restore_pre_fallback_state "" || true
        return 1
    fi
    fallback_hash=$(r21_hash_privileged "$fallback")
    [[ $fallback_hash == "$PENDING_TARGET_EFI_HASH" ]] || { r21_restore_pre_fallback_state "" || true; fail 'Limine fallback hash verification failed after install'; return 1; }

    fallback_id=$(r21_create_or_adopt_fallback_alias) || {
        r21_restore_pre_fallback_state "" || true
        return 1
    }
    fallback_id=${fallback_id^^}
    r21_write_fallback_meta "$fallback_id" "$conf_hash" "$source_ids" "$fallback_hash" || {
        r21_restore_pre_fallback_state "$fallback_id" || true
        return 1
    }

    order=$(r21_order_primary_fallback_then_existing "$fallback_id") || {
        r21_restore_pre_fallback_state "$fallback_id" || true
        return 1
    }
    r21_verify_transferred_limine_state || {
        r21_restore_pre_fallback_state "$fallback_id" || true
        return 1
    }
    r21_verify_source_grub_nvram_ids "$source_ids" || {
        r21_restore_pre_fallback_state "$fallback_id" || true
        return 1
    }
    r21_verify_grub_cleanup_ownership || {
        r21_restore_pre_fallback_state "$fallback_id" || true
        return 1
    }

    leap16_stage_diagnostic fallback-staged
    before_order=$(leap16_current_boot_order)
    sudo efibootmgr -n "$fallback_id" >/dev/null || { r21_restore_pre_fallback_state "$fallback_id" || true; return 1; }
    next=$(pending_bootnext_id)
    if [[ ${next^^} != "$fallback_id" || $(leap16_current_boot_order) != "$before_order" ]]; then
        [[ ${next^^} == "$fallback_id" ]] && sudo efibootmgr -N >/dev/null 2>&1 || true
        r21_restore_pre_fallback_state "$fallback_id" || true
        fail 'Fallback BootNext arming changed persistent BootOrder or failed exact verification'
        return 1
    fi
    leap16_stage_diagnostic fallback-bootnext-armed
    ok "Limine fallback proof armed: BootNext=Boot$fallback_id -> $LEAP16_R21_FALLBACK_EFI_PATH"
    ok "Persistent topology is now $order (primary Limine, fallback Limine, then intact native GRUB2 recovery)"
    return 0
}

r21_validate_fallback_runtime() {
    local fallback_id next order fallback_hash actual
    r21_validate_fallback_meta || return 1
    fallback_id=$(r21_meta_value fallback_boot_id); fallback_id=${fallback_id^^}
    fallback_hash=$(r21_meta_value fallback_hash)
    detect_bootloader
    [[ $BOOTLOADER == limine ]] || { fail 'Fallback BootCurrent bytes are not identified as canonical Limine'; return 1; }
    [[ ${BOOT_CURRENT^^} == "$fallback_id" ]] || { fail "Fallback runtime proof requires BootCurrent=Boot$fallback_id (found Boot${BOOT_CURRENT:-unknown})"; return 1; }
    nvram_id_matches_path "$fallback_id" "$LEAP16_R21_FALLBACK_EFI_PATH" || { fail 'Fallback BootCurrent no longer points to EFI/BOOT/BOOTX64.EFI'; return 1; }
    leap16_nvram_entry_matches_current_esp "$fallback_id" || { fail 'Fallback BootCurrent is not bound to the transaction ESP'; return 1; }
    leap16_stage_diagnostic fallback-runtime-arrival
    run_validation preflight || return 1
    next=$(pending_bootnext_id)
    if [[ -n $next && ${next^^} == "$fallback_id" ]]; then
        sudo efibootmgr -N >/dev/null || return 1
        ok 'Cleared lingering transaction-owned fallback BootNext after successful arrival'
    elif [[ -n $next ]]; then
        fail "Unrelated BootNext=Boot$next exists during fallback proof"
        return 1
    else
        ok 'Fallback BootNext was consumed/cleared by firmware'
    fi
    pending_validate_running_kernel || return 1
    pending_validate_runtime_cmdline_against_source || return 1
    actual=$(r21_hash_privileged "$PENDING_ESP_MOUNT/EFI/BOOT/BOOTX64.EFI")
    [[ $actual == "$fallback_hash" && $actual == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'Actually booted fallback bytes no longer match canonical Limine'; return 1; }
    r21_verify_transferred_limine_state || return 1
    r21_verify_source_grub_nvram_ids "$(r21_meta_value source_grub_ids)" || return 1
    r21_verify_grub_cleanup_ownership || return 1
    order=$(leap16_current_boot_order)
    [[ $order == "${PENDING_TARGET_BOOT_ID^^},$fallback_id"* ]] || { fail "Persistent topology changed before fallback proof ($order)"; return 1; }
    leap16_stage_diagnostic fallback-runtime-pass
    printf '\nFALLBACK-RUNTIME-VALIDATED.\n'
    printf '  BootCurrent proof: Boot%s -> %s\n' "$fallback_id" "$LEAP16_R21_FALLBACK_EFI_PATH"
    printf '  Bytes:             identical to canonical Limine Boot%s\n' "$PENDING_TARGET_BOOT_ID"
    printf '  Kernel/root/cmdline: exact transaction proof passed\n'
    printf '  Native GRUB2:      still intact; retirement is authorized only now\n'
}

r21_remove_source_grub_nvram_ids() {
    local csv=$1 id
    local -a ids=()
    r21_verify_source_grub_nvram_ids "$csv" || return 1
    IFS=',' read -ra ids <<<"$csv"
    for id in "${ids[@]}"; do
        id=${id^^}
        sudo efibootmgr -b "$id" -B >/dev/null || return 1
        ok "Removed ownership-proven native GRUB2 NVRAM entry Boot$id"
    done
    for id in "${ids[@]}"; do boot_id_exists "$id" && { fail "Native GRUB2 Boot$id still exists after retirement"; return 1; }; done
}

r21_remove_source_grub_files() {
    local dm em rec efi_dir present expected actual
    r21_verify_grub_cleanup_ownership || return 1
    dm=$(r23_source_grub_dir_manifest_path); em=$(r23_source_grub_efi_dir_manifest_path); rec=$(r23_source_grub_default_record_path)
    pending_verify_tree_manifest /boot/grub2 "$dm" || return 1
    sudo rm -rf -- /boot/grub2 || return 1
    ok 'Removed ownership-proven native /boot/grub2 tree'
    efi_dir=$(dirname -- "$PENDING_OLD_GRUB_EFI_RESOLVED")
    pending_verify_tree_manifest "$efi_dir" "$em" || return 1
    sudo rm -rf -- "$efi_dir" || return 1
    ok "Removed ownership-proven native openSUSE EFI namespace: $efi_dir"
    present=$(awk -F'\t' '$1=="present"{print $2; exit}' "$rec")
    expected=$(awk -F'\t' '$1=="hash"{print $2; exit}' "$rec")
    if [[ $present == 1 && -e /etc/default/grub ]]; then
        actual=$(r21_hash_privileged /etc/default/grub)
        [[ $actual == "$expected" ]] || { fail 'Refusing to remove changed /etc/default/grub'; return 1; }
        sudo rm -f -- /etc/default/grub || return 1
        ok 'Removed ownership-proven native /etc/default/grub'
    fi
}

r21_retire_grub_after_fallback_proof() {
    local fallback_id source_ids final_hash order
    r21_validate_fallback_runtime || return 1
    fallback_id=$(r21_meta_value fallback_boot_id); fallback_id=${fallback_id^^}
    source_ids=$(r21_meta_value source_grub_ids)

    printf '\nRETIRING native GRUB2 only after exact Limine fallback proof:\n'
    printf '  - keep primary Limine Boot%s first\n' "$PENDING_TARGET_BOOT_ID"
    printf '  - keep proven Limine fallback Boot%s second\n' "$fallback_id"
    printf '  - retire exact pre-stage openSUSE GRUB2 Boot#### aliases: Boot%s\n' "${source_ids//,/ Boot}"
    printf '  - retire only ownership-proven /boot/grub2, EFI/OPENSUSE and /etc/default/grub\n'
    printf '  - remove the now-obsolete temporary GRUB2 recovery entry from limine.conf\n'

    r21_remove_source_grub_nvram_ids "$source_ids" || return 1
    r21_remove_source_grub_files || return 1
    final_hash=$(r21_remove_direct_grub_recovery_block) || return 1
    order=$(r21_order_final_primary_fallback "$fallback_id") || return 1

    [[ ! -e /boot/grub2 ]] || { fail '/boot/grub2 still exists after retirement'; return 1; }
    sudo -n test ! -e "$(dirname -- "$PENDING_OLD_GRUB_EFI_RESOLVED")" 2>/dev/null || { fail 'EFI/OPENSUSE still exists after retirement'; return 1; }
    [[ $(r21_hash_privileged "$PENDING_ESP_MOUNT/EFI/BOOT/BOOTX64.EFI") == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'Proven Limine fallback changed during GRUB2 retirement'; return 1; }
    boot_id_exists "$PENDING_TARGET_BOOT_ID" || { fail 'Primary Limine NVRAM entry disappeared during GRUB2 retirement'; return 1; }
    boot_id_exists "$fallback_id" || { fail 'Proven Limine fallback NVRAM entry disappeared during GRUB2 retirement'; return 1; }
    validate_target_state limine || return 1
    validate_limine_boot_chain migration || return 1
    validate_cachyos_limine_theme || return 1
    r23_verify_limine_theme_manifest || return 1
    [[ $(r21_hash_privileged "$PENDING_LIMINE_CONF_PATH") == "$final_hash" ]] || { fail 'Final Limine configuration hash changed after retirement'; return 1; }
    leap16_stage_diagnostic grub-retirement-pass
    printf '\nGRUB2-RETIREMENT-VALIDATED. Final persistent BootOrder: %s\n' "$order"
    printf 'Primary Limine + genuine Limine EFI fallback are the two leading firmware paths.\n'
}

# Recovery-entry validator used by the Leap Limine deep validator.  It accepts
# exactly the three legitimate r21 states: pre-transfer shim fallback, temporary
# direct GRUB recovery while EFI/BOOT is Limine, or finalized Limine with no
# dead GRUB recovery entry.
leap16_validate_limine_recovery_contract() {
    local conf=$1 fallback="$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI" primary="$ESP_MOUNT/EFI/LIMINE/LIMINE_X64.EFI" fh ph
    LEAP16_LIMINE_RECOVERY_DETAIL=''
    if grep -Fqx '/EFI fallback' "$conf" && grep -Fqx 'path: boot():/EFI/BOOT/BOOTX64.EFI' "$conf"; then
        fh=$(r21_hash_privileged "$fallback"); ph=$(r21_hash_privileged "$primary")
        [[ -n $fh && -n $ph && $fh != "$ph" ]] || return 1
        LEAP16_LIMINE_RECOVERY_DETAIL='Limine config keeps the pre-transfer openSUSE EFI fallback as GRUB2 recovery'
        return 0
    fi
    if grep -Fqx '/openSUSE GRUB2 recovery' "$conf" && grep -Fqx 'path: boot():/EFI/OPENSUSE/SHIM.EFI' "$conf"; then
        sudo -n test -f "$ESP_MOUNT/EFI/OPENSUSE/SHIM.EFI" 2>/dev/null || [[ -f $ESP_MOUNT/EFI/OPENSUSE/SHIM.EFI ]] || return 1
        fh=$(r21_hash_privileged "$fallback"); ph=$(r21_hash_privileged "$primary")
        [[ -n $fh && $fh == "$ph" ]] || return 1
        LEAP16_LIMINE_RECOVERY_DETAIL='Limine fallback owns EFI/BOOT; temporary recovery is redirected directly to openSUSE shim'
        return 0
    fi
    if ! grep -Fq '/EFI fallback' "$conf" && ! grep -Fq '/openSUSE GRUB2 recovery' "$conf"; then
        fh=$(r21_hash_privileged "$fallback"); ph=$(r21_hash_privileged "$primary")
        [[ -n $fh && $fh == "$ph" ]] || return 1
        if sudo -n test -e "$ESP_MOUNT/EFI/OPENSUSE" 2>/dev/null || [[ -e $ESP_MOUNT/EFI/OPENSUSE ]]; then return 1; fi
        LEAP16_LIMINE_RECOVERY_DETAIL='Finalized Limine has a byte-identical EFI/BOOT fallback and no obsolete GRUB2 recovery entry'
        return 0
    fi
    return 1
}

# r20's validator body is patched to call the helper above.  Keep a wrapper
# here as a guard for old copied bundles that somehow load r21 without the patch.
if declare -F validate_limine_boot_chain >/dev/null; then
    :
fi

# Diagnostics: teach the firmware-order report about the two new forward
# topologies so fallback-staged/proven/finalized snapshots are not mislabeled as
# r20 promotion drift.
eval "$(declare -f leap16_write_firmware_order_report | sed '1s/leap16_write_firmware_order_report/leap16_write_firmware_order_report_pre_r21/')"
leap16_write_firmware_order_report() {
    local out=$1 phase=${2:-snapshot} fallback_id source_ids order expected assessment=pass reason
    case "$phase" in
        fallback-staged|fallback-bootnext-armed|fallback-runtime-arrival|fallback-runtime-pass)
            fallback_id=$(r21_meta_value fallback_boot_id 2>/dev/null || true); fallback_id=${fallback_id^^}
            order=$(leap16_current_boot_order 2>/dev/null || true)
            expected="${PENDING_TARGET_BOOT_ID^^},$fallback_id"
            if [[ -z $fallback_id || $order != "$expected"* ]]; then assessment=fail; reason="expected primary/fallback leading order $expected, got ${order:-unreadable}"; else reason='primary Limine and explicit Limine fallback lead persistent BootOrder; native GRUB2 recovery remains behind them'; fi
            {
                printf 'assessment=%s\n' "$assessment"
                printf 'reason=%s\n' "$reason"
                printf 'full_current_boot_order=%s\n' "$order"
                printf 'stable_expected_prefix=%s\n' "$expected"
                printf 'fallback_boot_id=%s\n' "$fallback_id"
                printf 'source_grub_ids=%s\n' "$(r21_meta_value source_grub_ids 2>/dev/null || true)"
            } >"$out"
            return 0
            ;;
        grub-retirement-pass|auto-resume-success)
            if r21_fallback_meta_exists; then
                fallback_id=$(r21_meta_value fallback_boot_id); fallback_id=${fallback_id^^}
                source_ids=$(r21_meta_value source_grub_ids)
                order=$(leap16_current_boot_order 2>/dev/null || true)
                expected="${PENDING_TARGET_BOOT_ID^^},$fallback_id"
                if [[ $order != "$expected"* ]]; then assessment=fail; reason="expected finalized primary/fallback leading order $expected, got ${order:-unreadable}"; else reason='finalized Limine primary + genuine EFI fallback lead BootOrder; ownership-proven native GRUB2 entries are retired'; fi
                {
                    printf 'assessment=%s\n' "$assessment"
                    printf 'reason=%s\n' "$reason"
                    printf 'full_current_boot_order=%s\n' "$order"
                    printf 'stable_expected_prefix=%s\n' "$expected"
                    printf 'fallback_boot_id=%s\n' "$fallback_id"
                    printf 'retired_source_grub_ids=%s\n' "$source_ids"
                } >"$out"
                return 0
            fi
            ;;
    esac
    leap16_write_firmware_order_report_pre_r21 "$@"
}

# Manual runtime-proven forward continuation now performs the fallback test
# instead of clearing the transaction at r20's primary-promotion boundary.
eval "$(declare -f leap16_finish_manual_promotion | sed '1s/leap16_finish_manual_promotion/leap16_finish_manual_promotion_pre_r21/')"
leap16_finish_manual_promotion() {
    validate_pending_compatibility || { fail "Pending migration is incompatible: $PENDING_REASON"; return 1; }
    r21_forward_pending || { leap16_finish_manual_promotion_pre_r21 "$@"; return $?; }
    [[ $PENDING_PHASE == runtime-validated ]] || { fail 'Manual r21 continuation requires runtime-validated primary Limine'; return 1; }
    leap16_promote_runtime_proven_limine_core || return 1
    r21_stage_fallback_test || return 1
    if ! r22_prepare_resume_bundle; then
        fail 'Could not prepare the second-boot root resume bundle; rolling fallback test staging back to the r20-safe topology'
        r21_restore_pre_fallback_state "$(r21_meta_value fallback_boot_id 2>/dev/null || true)" || true
        return 1
    fi
    printf '\nThe canonical Limine boot is proven. A second one-shot boot now targets the genuine Limine EFI fallback.\n'
    printf 'GRUB2 will remain intact until that exact fallback BootCurrent proof succeeds.\n'
    r13_prompt_reboot
}

r23_finalize_grub_to_limine() { leap16_finish_manual_promotion; }

r21_finish_forward_success() {
    local conf=$1 bundle=$2 detail fallback_id
    fallback_id=$(r21_meta_value fallback_boot_id); fallback_id=${fallback_id^^}
    leap16_stage_diagnostic auto-resume-success
    r13_sync_root_diagnostics_to_user "$conf" "$bundle" success || true
    detail="GRUB2 -> Limine completed with two independent runtime proofs. Primary Limine Boot$PENDING_TARGET_BOOT_ID is first; genuine Limine fallback Boot$fallback_id -> $LEAP16_R21_FALLBACK_EFI_PATH is second and byte-identical; ownership-proven native openSUSE GRUB2 NVRAM/EFI/config state was retired."
    remove_pending_transaction_snapshot || true
    rm -f -- "$PENDING_STATE_FILE"
    r22_cleanup_user_shadow_after_success "$conf"
    r22_write_user_result "$conf" success "$detail" || true
    r22_remove_resume_service_files
    rm -rf -- "$bundle" 2>/dev/null || true
    return 0
}

r21_resume_forward_root() {
    r22_root_bundle_preflight || return 1
    local bundle=$R22_RESUME_BUNDLE conf="$R22_RESUME_BUNDLE/resume.conf" fallback_id detail
    mkdir -p -- "$bundle/diagnostics" || return 1
    LEAP16_DIAGNOSTIC_ROOT="$bundle/diagnostics"
    LEAP16_AUTO_RESUME=1
    export LEAP16_DIAGNOSTIC_ROOT LEAP16_AUTO_RESUME
    exec > >(tee -a "$bundle/automatic-resume.log") 2>&1

    printf 'openSUSE Bootloader Switcher leap16-r21 forward automatic transaction resume\n'
    printf 'Bundle: %s\n' "$bundle"
    load_pending_state || {
        printf 'Automatic resume: root-owned pending state is invalid: %s\n' "$PENDING_REASON" >&2
        r22_write_user_result "$conf" failed 'Root-owned r21 pending state failed validation; no source retirement was attempted.' || true
        r22_remove_resume_service_files
        return 1
    }
    validate_pending_compatibility || {
        r22_write_user_result "$conf" failed "r21 automatic resume transaction is incompatible: $PENDING_REASON" || true
        r22_remove_resume_service_files
        return 1
    }
    r21_forward_pending || { r22_write_user_result "$conf" failed 'r21 forward resume received the wrong transaction direction.' || true; r22_remove_resume_service_files; return 1; }
    detect_bootloader

    if r21_fallback_meta_exists; then
        fallback_id=$(r21_meta_value fallback_boot_id); fallback_id=${fallback_id^^}
        if [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == "$fallback_id" ]]; then
            if ! r21_retire_grub_after_fallback_proof; then
                r22_write_user_result "$conf" failed 'The exact Limine fallback boot arrived, but proof/finalization failed before safe completion. No unproven cleanup is attempted beyond any already completed ownership-gated retirement step.' || true
                leap16_stage_diagnostic auto-resume-fallback-finalization-failed
                r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
                r22_remove_resume_service_files
                return 1
            fi
            r21_finish_forward_success "$conf" "$bundle"
            return $?
        fi

        printf 'Automatic resume: the armed Limine fallback did not become the exact BootCurrent; GRUB2 retirement is forbidden.\n' >&2
        if r21_restore_pre_fallback_state "$fallback_id"; then
            r21_remove_user_fallback_sidecars "$conf" || true
            r13_sync_root_diagnostics_to_user "$conf" "$bundle" safe-fallback || true
            r22_write_user_result "$conf" safe-fallback 'The second-boot Limine fallback proof was not obtained. Native GRUB2 was retained; EFI/BOOT and limine.conf were restored to the r20-safe primary-Limine + shim-recovery topology.' || true
            r22_remove_resume_service_files
            return 0
        fi
        r22_write_user_result "$conf" failed 'The Limine fallback proof was not obtained and automatic rollback of the fallback-transfer staging also failed. Native GRUB2 retirement was not attempted.' || true
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
        r22_remove_resume_service_files
        return 1
    fi

    # First post-reboot phase: exact canonical Limine proof, unchanged from r20.
    if [[ $BOOTLOADER == "$PENDING_SOURCE" && ${BOOT_CURRENT^^} == ${PENDING_OLD_BOOT_ID^^} ]]; then
        printf 'Automatic resume: firmware returned to the recorded GRUB2 source; no Limine proof and no promotion are allowed.\n'
        if r22_resume_source_fallback "$conf"; then
            leap16_capture_diagnostics auto-resume-source-fallback >/dev/null 2>&1 || true
            r13_sync_root_diagnostics_to_user "$conf" "$bundle" safe-fallback || true
            return 0
        fi
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
        return 1
    fi
    [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || {
        leap16_stage_diagnostic auto-resume-unexpected-primary-bootcurrent
        r22_write_user_result "$conf" failed 'Primary Limine automatic resume saw an unexpected BootCurrent; no fallback transfer or GRUB2 retirement occurred.' || true
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
        r22_remove_resume_service_files
        return 1
    }

    case "$PENDING_PHASE" in
        boot-armed)
            validate_pending_target_runtime || {
                r22_write_user_result "$conf" failed 'Canonical Limine booted but primary runtime proof failed; no fallback transfer or GRUB2 retirement occurred.' || true
                r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
                r22_remove_resume_service_files
                return 1
            }
            PENDING_PHASE=runtime-validated
            r22_sync_user_phase_from_root "$conf" runtime-validated || true
            ;;
        runtime-validated)
            printf 'Automatic resume: canonical Limine runtime proof was already persisted; continuing to r21 fallback staging.\n'
            ;;
        *)
            r22_write_user_result "$conf" failed "Unexpected primary automatic-resume phase: $PENDING_PHASE" || true
            r22_remove_resume_service_files
            return 1
            ;;
    esac

    # Keep r20's proven primary promotion as an intermediate safe state.  Do
    # not clear the transaction: r21 still owes the fallback runtime proof.
    if ! leap16_promote_runtime_proven_limine_core; then
        r22_write_user_result "$conf" failed 'Primary Limine runtime proof passed, but the r20-safe persistent promotion failed. Native GRUB2 and shim fallback were retained.' || true
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
        r22_remove_resume_service_files
        return 1
    fi
    if ! r21_stage_fallback_test; then
        r22_write_user_result "$conf" failed 'Primary Limine was proven/promoted, but genuine Limine fallback staging failed. The tool attempted to retain/restore the r20-safe native GRUB2 + shim recovery topology.' || true
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
        r22_remove_resume_service_files
        return 1
    fi
    r21_sync_fallback_sidecars_to_user "$conf" || warn 'Could not mirror r21 fallback sidecars into the user transaction snapshot; root-owned automatic continuation remains authoritative'
    r13_sync_root_diagnostics_to_user "$conf" "$bundle" fallback-armed || true
    r22_write_user_result "$conf" pending 'Primary Limine is proven. Genuine Limine EFI fallback is installed and armed for one exact BootNext proof; native GRUB2 remains intact until that second proof succeeds.' || true

    printf '\nr21 phase 1 complete. Rebooting exactly once into the explicit Limine fallback Boot%s.\n' "$(r21_meta_value fallback_boot_id)"
    printf 'Native GRUB2 is still present and will not be retired unless the fallback BootCurrent proof passes.\n'
    if ! systemctl reboot; then
        printf 'Automatic reboot request failed. BootNext remains armed; reboot normally to continue the fallback proof.\n' >&2
        r22_write_user_result "$conf" pending 'Fallback proof is staged and BootNext remains armed, but the automatic reboot request failed. Reboot normally to continue; GRUB2 is still intact.' || true
        return 1
    fi
    return 0
}

# Preserve r15 reverse dispatch; override only the forward root transaction.
eval "$(declare -f r22_resume_transaction_root | sed '1s/r22_resume_transaction_root/r22_resume_transaction_root_pre_r21/')"
r22_resume_transaction_root() {
    local src="" tgt=""
    if [[ -f ${PENDING_STATE_FILE:-/nonexistent} ]]; then
        src=$(awk -F'\t' '$1=="source"{print $2;exit}' "$PENDING_STATE_FILE" 2>/dev/null || true)
        tgt=$(awk -F'\t' '$1=="target"{print $2;exit}' "$PENDING_STATE_FILE" 2>/dev/null || true)
    fi
    if [[ $src:$tgt == grub:limine ]]; then
        r21_resume_forward_root
    else
        r22_resume_transaction_root_pre_r21 "$@"
    fi
}

r21_finish_forward_success_manual() {
    leap16_stage_diagnostic manual-forward-success
    r22_disarm_user_resume_bundle
    remove_pending_transaction_snapshot || warn 'Could not remove the private r21 transaction snapshot after manual completion'
    rm -f -- "$PENDING_STATE_FILE"
    pending_reset
    ok 'FINALIZED GRUB2 -> Limine: canonical Limine + genuine EFI fallback are proven; native openSUSE GRUB2 state is retired.'
}

# If the temporary root service did not complete the second-boot handoff, the
# interactive manager must understand the r21 fallback sidecar instead of
# falling back to the older r13 "promote primary" menu.
eval "$(declare -f manage_pending_migration | sed '1s/manage_pending_migration/manage_pending_migration_pre_r21/')"
manage_pending_migration() {
    pending_exists || { printf '\nNo pending/staged migration exists.\n'; return 0; }
    validate_pending_compatibility || { printf '\nPending migration state is invalid/incompatible: %s\n' "$PENDING_REASON"; return 1; }
    if ! r21_forward_pending || ! r21_fallback_meta_exists; then
        manage_pending_migration_pre_r21 "$@"
        return $?
    fi

    detect_bootloader
    local fallback_id next choice
    fallback_id=$(r21_meta_value fallback_boot_id); fallback_id=${fallback_id^^}
    next=$(pending_bootnext_id 2>/dev/null || true)
    show_pending_details

    if [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == "$fallback_id" ]]; then
        printf '\nThe exact r21 Limine fallback Boot%s is running. GRUB2 is still intact.\n' "$fallback_id"
        printf '[1] Prove this fallback and retire ownership-proven native GRUB2 now\n[2] Capture diagnostics\n[3] Back\n\n'
        read -r -p 'Select an option: ' choice
        case "$choice" in
            1) r21_retire_grub_after_fallback_proof && r21_finish_forward_success_manual ;;
            2) leap16_stage_diagnostic manual-fallback-session ;;
            3|'') return 0 ;;
            *) return 1 ;;
        esac
        return $?
    fi

    if [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]]; then
        if [[ ${next^^} == "$fallback_id" ]]; then
            printf '\nPrimary Limine is active and the exact fallback BootNext is still armed. GRUB2 remains intact.\n'
            printf '[1] Re-check transferred fallback + GRUB2 ownership\n[2] Reboot into the armed fallback proof\n[3] Roll back fallback transfer to the r20-safe shim topology\n[4] Back\n\n'
            read -r -p 'Select an option: ' choice
            case "$choice" in
                1) r21_verify_transferred_limine_state && r21_verify_source_grub_nvram_ids "$(r21_meta_value source_grub_ids)" && r21_verify_grub_cleanup_ownership ;;
                2) r21_verify_transferred_limine_state && r13_prompt_reboot ;;
                3) r21_restore_pre_fallback_state "$fallback_id" && r22_disarm_user_resume_bundle ;;
                4|'') return 0 ;;
                *) return 1 ;;
            esac
            return $?
        fi
        if [[ -z $next ]]; then
            printf '\nFallback BootNext was consumed/cleared but this session is canonical Limine, not the fallback Boot%s.\n' "$fallback_id"
            printf 'GRUB2 retirement is forbidden.\n[1] Restore shim fallback + primary-proven config\n[2] Capture diagnostics\n[3] Back\n\n'
            read -r -p 'Select an option: ' choice
            case "$choice" in
                1) r21_restore_pre_fallback_state "$fallback_id" && r22_disarm_user_resume_bundle ;;
                2) leap16_stage_diagnostic manual-fallback-not-proven ;;
                3|'') return 0 ;;
                *) return 1 ;;
            esac
            return $?
        fi
        fail "Unrelated BootNext=Boot$next exists during the r21 fallback transaction"
        return 1
    fi

    if [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == ${PENDING_OLD_BOOT_ID^^} ]]; then
        printf '\nFirmware returned to the recorded GRUB2 source while the fallback proof was pending. GRUB2 retirement is forbidden.\n'
        printf '[1] Restore pre-fallback shim topology and disarm automation\n[2] Back\n\n'
        read -r -p 'Select an option: ' choice
        case "$choice" in
            1) r21_restore_pre_fallback_state "$fallback_id" && r22_disarm_user_resume_bundle ;;
            2|'') return 0 ;;
            *) return 1 ;;
        esac
        return $?
    fi

    fail 'Current session is neither the exact primary Limine, exact fallback Limine, nor recorded GRUB2 recovery session for this r21 transaction'
    return 1
}

# Forward pending banner exposes the second proof boundary instead of claiming
# completion after primary promotion.
eval "$(declare -f pending_banner | sed '1s/pending_banner/pending_banner_pre_r21/')"
pending_banner() {
    if pending_exists && validate_pending_compatibility >/dev/null 2>&1 && r21_forward_pending; then
        detect_bootloader
        if r21_fallback_meta_exists; then
            local fid
            fid=$(r21_meta_value fallback_boot_id); fid=${fid^^}
            printf 'Pending/staged migration: GRUB2 -> Limine  [fallback-proof-armed]'
            if [[ ${BOOT_CURRENT^^} == "$fid" ]]; then printf '  [LIMINE FALLBACK ACTIVE; FINALIZATION ELIGIBLE]\n'; else printf '  [BootNext fallback Boot%s awaiting proof]\n' "$fid"; fi
            return 0
        fi
    fi
    pending_banner_pre_r21 "$@"
}

