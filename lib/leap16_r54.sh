#!/usr/bin/env bash
# leap16-r54: repair the r51-r53 systemd-boot -> Limine promotion ordering
# bug and make post-second-proof systemd retirement resumable/idempotent.
#
# r51 used adapter_target_promote(), whose generic helper intentionally drops
# the source Boot#### from BootOrder.  That is correct for single-proof hub
# migrations but contradicts this two-proof reverse edge, where canonical
# systemd-boot must remain second until the Limine EFI fallback earns its own
# independent runtime proof.  r54 uses the dedicated primary+source recovery
# ordering helper and can heal the exact r53 stranded topology before any
# fallback ownership transfer.
#
# r54 also closes the known cleanup retry gap: after the second Limine proof,
# an exact retirement authorization sidecar is persisted before any source
# deletion.  Once authorized, each cleanup step is idempotent and accepts only
# missing-or-still-exact source-owned state.  This allows a later retry after a
# partially completed retirement without ever treating unproven deletion as
# authorized.

LEAP16_R54_RETIRE_AUTH='r54-systemd-retirement-authorized.tsv'

leap16_r54_retire_auth_path() {
    local d
    d=$(leap16_r51_snapshot_dir) || return 1
    printf '%s/%s\n' "$d" "$LEAP16_R54_RETIRE_AUTH"
}

leap16_r54_auth_value() {
    local key=$1 p
    p=$(leap16_r54_retire_auth_path) || return 1
    awk -F'\t' -v k="$key" '$1==k{print $2;exit}' "$p" 2>/dev/null
}

leap16_r54_render_final_limine_conf() {
    local out=$1 conf="${PENDING_ESP_MOUNT%/}/limine.conf" expected tmp line a b c d found=0
    expected=$(leap16_r51_meta_value transferred_conf_hash)
    [[ $expected =~ ^[0-9A-Fa-f]{64}$ ]] || { fail 'Transferred Limine config identity is unavailable'; return 1; }
    [[ $(r21_hash_privileged "$conf") == "$expected" ]] || { fail 'Transferred limine.conf changed before retirement authorization'; return 1; }
    tmp=$(mktemp) || return 1
    if [[ -r $conf ]]; then cat -- "$conf" >"$tmp"; else sudo -n cat -- "$conf" >"$tmp" 2>/dev/null; fi \
        || { rm -f -- "$tmp"; return 1; }
    : >"$out" || { rm -f -- "$tmp"; return 1; }
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == '/openSUSE systemd-boot recovery' ]]; then
            IFS= read -r a || { rm -f -- "$tmp" "$out"; return 1; }
            IFS= read -r b || { rm -f -- "$tmp" "$out"; return 1; }
            IFS= read -r c || { rm -f -- "$tmp" "$out"; return 1; }
            IFS= read -r d || { rm -f -- "$tmp" "$out"; return 1; }
            [[ $c == 'protocol: efi' && $d == 'path: boot():/EFI/systemd/systemd-bootx64.efi' ]] \
                || { rm -f -- "$tmp" "$out"; fail 'Temporary systemd-boot recovery block changed before retirement authorization'; return 1; }
            found=$((found + 1))
        else
            printf '%s\n' "$line" >>"$out" || { rm -f -- "$tmp" "$out"; return 1; }
        fi
    done <"$tmp"
    rm -f -- "$tmp"
    [[ $found == 1 ]] || { rm -f -- "$out"; fail "Expected exactly one temporary systemd-boot recovery block before authorization, found $found"; return 1; }
}

leap16_r54_sync_retire_auth_to_user_shadow() {
    local auth=$1 conf user_snapshot uid gid
    [[ ${EUID:-$(id -u)} -eq 0 ]] || return 0
    [[ -n ${R22_RESUME_BUNDLE:-} && -f ${R22_RESUME_BUNDLE%/}/resume.conf ]] || return 0
    conf="${R22_RESUME_BUNDLE%/}/resume.conf"
    r22_user_shadow_matches_conf "$conf" || { fail 'Could not validate user shadow before persisting retirement authorization'; return 1; }
    user_snapshot=$(r22_conf_value "$conf" user_snapshot_dir)
    uid=$(r22_conf_value "$conf" user_uid); gid=$(r22_conf_value "$conf" user_gid)
    [[ -d $user_snapshot && $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ ]] || { fail 'User shadow metadata is incomplete for retirement authorization'; return 1; }
    cp -f -- "$auth" "$user_snapshot/$LEAP16_R54_RETIRE_AUTH" || return 1
    chown "$uid:$gid" -- "$user_snapshot/$LEAP16_R54_RETIRE_AUTH" 2>/dev/null || true
    chmod 600 -- "$user_snapshot/$LEAP16_R54_RETIRE_AUTH" 2>/dev/null || true
    ok 'Mirrored retirement authorization into the user-owned pending snapshot'
}

leap16_r54_write_retire_auth() {
    local p tmp source target fallback source_manifest_hash final_tmp final_hash
    source=${PENDING_OLD_BOOT_ID^^}; target=${PENDING_TARGET_BOOT_ID^^}
    fallback=$(leap16_r51_fallback_id) || return 1
    [[ -s $PENDING_SOURCE_MANIFEST ]] || { fail 'Source ownership manifest is unavailable at retirement authorization boundary'; return 1; }
    source_manifest_hash=$(sha256sum -- "$PENDING_SOURCE_MANIFEST" 2>/dev/null | awk '{print $1}' || true)
    [[ $source_manifest_hash =~ ^[0-9A-Fa-f]{64}$ ]] || { fail 'Could not bind retirement authorization to the source ownership manifest'; return 1; }
    final_tmp=$(mktemp) || return 1
    leap16_r54_render_final_limine_conf "$final_tmp" || { rm -f -- "$final_tmp"; return 1; }
    final_hash=$(sha256sum -- "$final_tmp" | awk '{print $1}')
    rm -f -- "$final_tmp"
    [[ $final_hash =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
    p=$(leap16_r54_retire_auth_path) || return 1
    tmp="$p.tmp.$$"
    {
        printf 'format\t1\n'
        printf 'direction\tsystemd-boot:limine\n'
        printf 'source_boot_id\t%s\n' "$source"
        printf 'target_boot_id\t%s\n' "$target"
        printf 'fallback_boot_id\t%s\n' "$fallback"
        printf 'source_efi_hash\t%s\n' "$PENDING_SOURCE_EFI_HASH"
        printf 'target_efi_hash\t%s\n' "$PENDING_TARGET_EFI_HASH"
        printf 'source_manifest_hash\t%s\n' "$source_manifest_hash"
        printf 'transferred_conf_hash\t%s\n' "$(leap16_r51_meta_value transferred_conf_hash)"
        printf 'final_conf_hash\t%s\n' "$final_hash"
        printf 'created\t%s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
    } >"$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 600 -- "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$p" || { rm -f -- "$tmp"; return 1; }
    leap16_r54_sync_retire_auth_to_user_shadow "$p" || return 1
    ok 'Persisted RETIREMENT-AUTHORIZED checkpoint after both independent Limine runtime proofs'
}

leap16_r54_validate_retire_auth() {
    local p source target fallback mh
    p=$(leap16_r54_retire_auth_path) || return 1
    [[ -s $p ]] || return 1
    pending_path_under "$p" "$PENDING_TRANSACTION_SNAPSHOT_DIR" || { fail 'Retirement authorization escaped the transaction snapshot'; return 1; }
    [[ $(leap16_r54_auth_value format) == 1 && $(leap16_r54_auth_value direction) == systemd-boot:limine ]] \
        || { fail 'Retirement authorization format/direction is invalid'; return 1; }
    source=${PENDING_OLD_BOOT_ID^^}; target=${PENDING_TARGET_BOOT_ID^^}; fallback=$(leap16_r51_fallback_id) || return 1
    [[ $(leap16_r54_auth_value source_boot_id) == "$source" \
       && $(leap16_r54_auth_value target_boot_id) == "$target" \
       && $(leap16_r54_auth_value fallback_boot_id) == "$fallback" ]] \
        || { fail 'Retirement authorization Boot#### identities do not match pending state'; return 1; }
    [[ $(leap16_r54_auth_value source_efi_hash) == "$PENDING_SOURCE_EFI_HASH" \
       && $(leap16_r54_auth_value target_efi_hash) == "$PENDING_TARGET_EFI_HASH" ]] \
        || { fail 'Retirement authorization EFI identities do not match pending state'; return 1; }
    mh=$(sha256sum -- "$PENDING_SOURCE_MANIFEST" 2>/dev/null | awk '{print $1}' || true)
    [[ -n $mh && $mh == $(leap16_r54_auth_value source_manifest_hash) ]] \
        || { fail 'Source ownership manifest changed after retirement authorization'; return 1; }
    [[ $(leap16_r54_auth_value transferred_conf_hash) == $(leap16_r51_meta_value transferred_conf_hash) ]] \
        || { fail 'Retirement authorization no longer matches the transferred Limine configuration'; return 1; }
    [[ $(leap16_r54_auth_value final_conf_hash) =~ ^[0-9A-Fa-f]{64}$ ]] \
        || { fail 'Retirement authorization final Limine config hash is malformed'; return 1; }
    return 0
}

leap16_r54_retirement_authorized() {
    leap16_r54_validate_retire_auth >/dev/null 2>&1
}

# Verify that a partially removed tree contains only unchanged objects from the
# frozen ownership manifest.  Missing original objects are allowed only after
# retirement authorization; added/changed objects still fail closed.
leap16_r54_tree_remaining_is_owned_subset() {
    local root=$1 manifest=$2 probe current line
    [[ -s $manifest ]] || { fail "Tree ownership manifest is unavailable: $manifest"; return 1; }
    if ! sudo -n test -e "$root" 2>/dev/null && ! sudo -n test -L "$root" 2>/dev/null && [[ ! -e $root && ! -L $root ]]; then
        return 0
    fi
    (sudo -n test -d "$root" 2>/dev/null || [[ -d $root ]]) || { fail "Authorized source tree changed object type: $root"; return 1; }
    (sudo -n test ! -L "$root" 2>/dev/null || [[ ! -L $root ]]) || { fail "Authorized source tree became a symlink: $root"; return 1; }
    probe=$(mktemp) || return 1
    if ! sudo -n find "$root" -mindepth 1 -print -quit >"$probe" 2>/dev/null; then
        rm -f -- "$probe"
        fail "Could not enumerate remaining authorized source tree: $root"
        return 1
    fi
    if [[ ! -s $probe ]]; then rm -f -- "$probe"; return 0; fi
    rm -f -- "$probe"
    current=$(mktemp) || return 1
    if ! write_privileged_tree_manifest "$root" "$current"; then
        rm -f -- "$current"
        fail "Could not manifest remaining authorized source tree: $root"
        return 1
    fi
    while IFS= read -r line; do
        grep -Fxq -- "$line" "$manifest" || {
            rm -f -- "$current"
            fail "Remaining source tree contains changed/foreign state after retirement authorization: $root"
            return 1
        }
    done <"$current"
    rm -f -- "$current"
    return 0
}

leap16_r54_source_remaining_is_owned_subset() {
    local record=$PENDING_SOURCE_MANIFEST kind path identity actual mf
    [[ -s $record ]] || { fail 'Source ownership record is missing after retirement authorization'; return 1; }
    while IFS=$'\t' read -r kind path identity; do
        [[ -n $kind && -n $path && -n $identity ]] || return 1
        case "$kind" in
            file)
                if ! sudo -n test -e "$path" 2>/dev/null && ! sudo -n test -L "$path" 2>/dev/null && [[ ! -e $path && ! -L $path ]]; then
                    continue
                fi
                actual=$(sudo -n sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || true)
                [[ -n $actual && $actual == "$identity" ]] || { fail "Remaining authorized source file changed: $path"; return 1; }
                ;;
            tree)
                mf="$(dirname -- "$record")/$identity"
                leap16_r54_tree_remaining_is_owned_subset "$path" "$mf" || return 1
                ;;
            *) fail "Unknown source ownership record type after retirement authorization: $kind"; return 1 ;;
        esac
    done <"$record"
}

leap16_r54_remove_source_manifest_idempotent() {
    local record=$PENDING_SOURCE_MANIFEST kind path identity
    leap16_r54_source_remaining_is_owned_subset || return 1
    while IFS=$'\t' read -r kind path identity; do
        case "$kind" in
            file)
                if sudo -n test -e "$path" 2>/dev/null || sudo -n test -L "$path" 2>/dev/null || [[ -e $path || -L $path ]]; then
                    sudo rm -f -- "$path" || return 1
                    ok "Retired ownership-authorized source path: $path"
                else
                    info "Ownership-authorized source path is already retired: $path"
                fi
                ;;
            tree)
                if sudo -n test -e "$path" 2>/dev/null || sudo -n test -L "$path" 2>/dev/null || [[ -e $path || -L $path ]]; then
                    sudo rm -rf -- "$path" || return 1
                    ok "Retired ownership-authorized source path: $path"
                else
                    info "Ownership-authorized source path is already retired: $path"
                fi
                ;;
        esac
    done <"$record"
}

leap16_r54_validate_authorized_limine_state() {
    local target=${PENDING_TARGET_BOOT_ID^^} fallback next order current_hash
    leap16_r54_validate_retire_auth || return 1
    fallback=$(leap16_r51_fallback_id) || return 1
    detect_bootloader
    [[ $BOOTLOADER == limine && ( ${BOOT_CURRENT^^} == "$target" || ${BOOT_CURRENT^^} == "$fallback" ) ]] \
        || { fail 'Authorized retirement retry must run from proven Limine primary or proven Limine fallback'; return 1; }
    next=$(pending_bootnext_id)
    [[ -z $next ]] || { fail "Refusing authorized retirement while BootNext=Boot$next exists"; return 1; }
    boot_id_exists "$target" || { fail "Proven Limine primary Boot$target disappeared after retirement authorization"; return 1; }
    nvram_id_matches_path "$target" "$PENDING_TARGET_EFI_PATH" || { fail 'Proven Limine primary EFI path changed after retirement authorization'; return 1; }
    leap16_nvram_entry_matches_current_esp "$target" || { fail 'Proven Limine primary ESP binding changed after retirement authorization'; return 1; }
    boot_id_exists "$fallback" || { fail "Proven Limine fallback Boot$fallback disappeared after retirement authorization"; return 1; }
    nvram_id_matches_path "$fallback" "$LEAP16_R21_FALLBACK_EFI_PATH" || { fail 'Proven Limine fallback EFI path changed after retirement authorization'; return 1; }
    leap16_nvram_entry_matches_current_esp "$fallback" || { fail 'Proven Limine fallback ESP binding changed after retirement authorization'; return 1; }
    current_hash=$(r21_hash_privileged "$PENDING_TARGET_EFI_RESOLVED")
    [[ $current_hash == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'Canonical Limine EFI changed after retirement authorization'; return 1; }
    [[ $(r21_hash_privileged "$PENDING_OLD_FALLBACK_PATH") == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'Proven Limine fallback bytes changed after retirement authorization'; return 1; }
    order=$(leap16_current_boot_order)
    [[ $order == "$target,$fallback"* ]] || { fail "Proven Limine primary/fallback order changed after retirement authorization ($order)"; return 1; }
    leap16_r54_source_remaining_is_owned_subset || return 1
    return 0
}

leap16_r54_finalize_limine_conf_idempotent() {
    local conf="${PENDING_ESP_MOUNT%/}/limine.conf" transferred final current tmp new_hash
    transferred=$(leap16_r54_auth_value transferred_conf_hash)
    final=$(leap16_r54_auth_value final_conf_hash)
    current=$(r21_hash_privileged "$conf")
    if [[ $current == "$final" ]]; then
        ok 'Temporary systemd-boot recovery block was already retired from limine.conf'
        printf '%s\n' "$final"
        return 0
    fi
    [[ $current == "$transferred" ]] || { fail 'limine.conf is neither the authorized pre-retirement nor final configuration'; return 1; }
    tmp=$(mktemp) || return 1
    leap16_r54_render_final_limine_conf "$tmp" || { rm -f -- "$tmp"; return 1; }
    new_hash=$(sha256sum -- "$tmp" | awk '{print $1}')
    [[ $new_hash == "$final" ]] || { rm -f -- "$tmp"; fail 'Deterministic final Limine config no longer matches retirement authorization'; return 1; }
    r21_atomic_replace "$tmp" "$conf" "$final" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
    printf '%s\n' "$final"
}

# Repair only the exact r51-r53 stranded checkpoint: primary Limine already
# runtime-proven and first, systemd source still byte/manifest exact but was
# accidentally dropped from BootOrder by the generic promotion helper.
leap16_r54_repair_promoted_recovery_order_if_needed() {
    local source target order first second hash
    leap16_r51_pending || return 0
    [[ ${PENDING_PHASE:-} == runtime-validated ]] || return 0
    leap16_r51_fallback_staged && return 0
    detect_bootloader
    source=${PENDING_OLD_BOOT_ID^^}; target=${PENDING_TARGET_BOOT_ID^^}
    [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == "$target" ]] || return 0
    order=$(leap16_current_boot_order) || return 1
    first=${order%%,*}; second=${order#*,}; second=${second%%,*}
    [[ ${first^^} == "$target" ]] || return 0
    [[ ${second^^} == "$source" ]] && return 0

    # No ownership transfer has happened yet.  Require the complete source to
    # remain exact before restoring it to second position.
    boot_id_exists "$source" || { fail "r51-r53 recovery repair cannot find source systemd-boot Boot$source"; return 1; }
    nvram_id_matches_path "$source" "$PENDING_OLD_BOOT_EFI_PATH" || { fail 'r51-r53 recovery repair found a changed systemd-boot NVRAM path'; return 1; }
    leap16_nvram_entry_matches_current_esp "$source" || { fail 'r51-r53 recovery repair found a changed systemd-boot ESP binding'; return 1; }
    hash=$(r21_hash_privileged "$PENDING_SOURCE_EFI_RESOLVED")
    [[ -n $hash && $hash == "$PENDING_SOURCE_EFI_HASH" ]] || { fail 'r51-r53 recovery repair found changed systemd-boot EFI bytes'; return 1; }
    r26_verify_owned_manifest "$PENDING_SOURCE_MANIFEST" || return 1
    leap16_r34_validate_systemd_boot_chain recovery || return 1
    grep -Eq '^[[:space:]]*LOADER_TYPE=.*systemd-boot' /etc/sysconfig/bootloader 2>/dev/null \
        || { fail 'r51-r53 recovery repair found LOADER_TYPE changed before fallback proof'; return 1; }
    leap16_r53_verify_pretransfer_fallback_alias_set || return 1
    r21_order_primary_then_source_recovery || { fail 'Could not restore canonical Limine + systemd-boot recovery ordering'; return 1; }
    [[ $(leap16_current_boot_order | cut -d, -f1,2) == "$target,$source" ]] \
        || { fail 'Recovered BootOrder does not begin canonical Limine + systemd-boot'; return 1; }
    ok "Repaired r51-r53 stranded topology: Limine Boot$target first, systemd-boot Boot$source second; firmware fallback aliases preserved behind them"
}

# Make the existing primary validator self-heal the one known r53 checkpoint so
# the already-proven transaction can continue without restaging.
eval "$(declare -f leap16_r51_validate_primary_runtime | sed '1s/leap16_r51_validate_primary_runtime/leap16_r51_validate_primary_runtime_pre_leap16_r54/')"
leap16_r51_validate_primary_runtime() {
    leap16_r54_repair_promoted_recovery_order_if_needed || return 1
    leap16_r51_validate_primary_runtime_pre_leap16_r54 "$@"
}

# r53's function is reproduced with one semantic change: promotion uses the
# dedicated primary+source recovery ordering helper.  It NEVER calls the generic
# adapter_target_promote() helper that drops the source from BootOrder.
leap16_r51_promote_and_stage_fallback() {
    local source=${PENDING_OLD_BOOT_ID^^} target=${PENDING_TARGET_BOOT_ID^^} order conf_hash fallback_hash fallback_id before next primary_manifest
    validate_pending_compatibility || { fail "Pending transaction is incompatible: $PENDING_REASON"; return 1; }
    leap16_r51_pending || return 1
    [[ $PENDING_PHASE == runtime-validated ]] || { fail 'Fallback staging requires primary Limine runtime proof'; return 1; }
    leap16_r51_fallback_staged && { fail 'The Limine fallback proof is already staged'; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == "$target" ]] || { fail 'Fallback staging must run from the canonical runtime-proven Limine session'; return 1; }
    leap16_r51_validate_primary_runtime || return 1

    r21_order_primary_then_source_recovery || { fail 'Could not establish canonical Limine + systemd-boot recovery ordering before fallback transfer'; return 1; }
    [[ $(leap16_current_boot_order | cut -d, -f1,2) == "$target,$source" ]] || { fail 'Canonical Limine/systemd-boot promoted recovery topology is not exact'; return 1; }
    verify_pending_candidate_ownership_unchanged || return 1
    verify_pending_source_recovery_unchanged || return 1
    leap16_r53_verify_pretransfer_fallback_alias_set || return 1

    primary_manifest=$(leap16_r51_primary_manifest_path) || return 1
    cp -f -- "$PENDING_TARGET_MANIFEST" "$primary_manifest" || return 1
    chmod 600 -- "$primary_manifest" 2>/dev/null || true
    conf_hash=$(leap16_r51_rewrite_recovery_to_direct_systemd) || { fail 'Could not redirect Limine recovery directly to canonical systemd-boot before EFI/BOOT transfer'; return 1; }
    if ! r21_atomic_replace "$PENDING_TARGET_EFI_RESOLVED" "$PENDING_OLD_FALLBACK_PATH" "$PENDING_TARGET_EFI_HASH"; then
        leap16_r51_restore_pre_fallback_state || true
        return 1
    fi
    fallback_hash=$(r21_hash_privileged "$PENDING_OLD_FALLBACK_PATH")
    [[ $fallback_hash == "$PENDING_TARGET_EFI_HASH" ]] || { leap16_r51_restore_pre_fallback_state || true; fail 'Limine fallback hash verification failed after transfer'; return 1; }
    fallback_id=$(r21_create_or_adopt_fallback_alias) || { leap16_r51_restore_pre_fallback_state || true; return 1; }
    fallback_id=${fallback_id^^}
    leap16_r51_refresh_target_manifest || { leap16_r51_restore_pre_fallback_state || true; return 1; }
    leap16_r51_write_fallback_meta "$fallback_id" "$fallback_hash" "$conf_hash" || { leap16_r51_restore_pre_fallback_state || true; return 1; }
    order=$(r21_order_primary_fallback_then_existing "$fallback_id") || { leap16_r51_restore_pre_fallback_state || true; return 1; }
    leap16_r51_verify_transferred_limine || { leap16_r51_restore_pre_fallback_state || true; return 1; }
    before=$(leap16_current_boot_order)
    sudo efibootmgr -n "$fallback_id" >/dev/null || { leap16_r51_restore_pre_fallback_state || true; return 1; }
    next=$(pending_bootnext_id)
    if [[ ${next^^} != "$fallback_id" || $(leap16_current_boot_order) != "$before" ]]; then
        [[ ${next^^} == "$fallback_id" ]] && sudo efibootmgr -N >/dev/null 2>&1 || true
        leap16_r51_restore_pre_fallback_state || true
        fail 'Limine fallback BootNext arming changed persistent BootOrder or failed exact verification'
        return 1
    fi
    pending_capture_runtime_diagnostics fallback-armed-limine-from-systemd >/dev/null 2>&1 || true
    printf '\nPRIMARY PROOF COMPLETE. Genuine Limine EFI fallback is now staged for the second proof.\n'
    printf '  Persistent BootOrder: %s\n' "$order"
    printf '  BootNext:             Boot%s -> %s\n' "$fallback_id" "$LEAP16_R21_FALLBACK_EFI_PATH"
    printf '  systemd-boot Boot%s remains intact behind the two Limine paths until that exact fallback BootCurrent is proven.\n' "$source"
}

# Replace r51's one-shot cleanup with an authorization boundary plus idempotent
# retirement.  Before authorization, the full systemd source must still pass the
# original second-proof validator.  After authorization, missing source-owned
# objects are accepted only as already-completed retirement steps; anything
# remaining must still be an exact subset of the frozen source manifest.
leap16_r51_retire_systemd_after_fallback_proof() {
    local source=${PENDING_OLD_BOOT_ID^^} target=${PENDING_TARGET_BOOT_ID^^} fallback order final_hash id
    local -a extras=()
    validate_pending_compatibility || { fail "Pending transaction is incompatible: $PENDING_REASON"; return 1; }
    leap16_r51_pending && leap16_r51_fallback_staged || { fail 'No systemd-boot -> Limine fallback retirement is pending'; return 1; }

    local auth_path
    auth_path=$(leap16_r54_retire_auth_path) || return 1
    if [[ -e $auth_path || -L $auth_path ]]; then
        leap16_r54_validate_retire_auth || return 1
        leap16_r54_validate_authorized_limine_state || return 1
        ok 'Resuming previously authorized systemd-boot retirement; already-completed exact cleanup steps are accepted'
    else
        leap16_r51_validate_fallback_runtime || return 1
        leap16_r54_write_retire_auth || return 1
        leap16_r54_validate_authorized_limine_state || return 1
    fi

    fallback=$(leap16_r51_fallback_id) || return 1
    mapfile -t extras < <(leap16_r51_extra_fallback_ids) || return 1
    printf '\nRETIRING systemd-boot only after exact canonical + fallback Limine proofs:\n'
    printf '  - keep primary Limine Boot%s first and proven fallback Boot%s second\n' "$target" "$fallback"
    printf '  - remove source systemd-boot Boot%s from BootOrder before deleting its variable\n' "$source"
    printf '  - retire only missing-or-still-exact paths from the frozen source ownership manifest\n'
    printf '  - remove the temporary direct systemd-boot recovery entry from limine.conf\n'

    order=$(leap16_r51_final_order_without_systemd) || return 1
    for id in "${extras[@]}"; do
        boot_id_exists "$id" || continue
        leap16_nvram_entry_matches_current_esp "$id" || { fail "Transaction-created fallback Boot$id changed ESP binding before retirement"; return 1; }
        nvram_id_matches_path "$id" "$LEAP16_R21_FALLBACK_EFI_PATH" || { fail "Transaction-created fallback Boot$id changed EFI path before retirement"; return 1; }
        sudo efibootmgr -b "$id" -B >/dev/null || { fail "Could not delete transaction-created fallback churn Boot$id"; return 1; }
        ok "Deleted transaction-created same-ESP fallback alias Boot$id"
    done

    if boot_id_exists "$source"; then
        nvram_id_matches_path "$source" "$PENDING_OLD_BOOT_EFI_PATH" || { fail 'Source systemd-boot path changed before NVRAM retirement'; return 1; }
        leap16_nvram_entry_matches_current_esp "$source" || { fail 'Source systemd-boot ESP binding changed before NVRAM retirement'; return 1; }
        sudo efibootmgr -b "$source" -B >/dev/null || { fail "Could not delete source systemd-boot Boot$source"; return 1; }
        boot_id_exists "$source" && { fail "Source systemd-boot Boot$source still exists after deletion"; return 1; }
        ok "Deleted ownership-authorized source systemd-boot Boot$source"
    else
        info "Ownership-authorized source systemd-boot Boot$source is already retired"
    fi

    leap16_r54_remove_source_manifest_idempotent || return 1
    sudo rmdir -- "${PENDING_ESP_MOUNT%/}/loader/entries" 2>/dev/null || true
    sudo rmdir -- "${PENDING_ESP_MOUNT%/}/loader" 2>/dev/null || true
    leap16_r47_cleanup_empty_machine_id_parent || true
    leap16_r51_set_final_limine_policy || return 1
    final_hash=$(leap16_r54_finalize_limine_conf_idempotent) || return 1
    leap16_r51_refresh_target_manifest || return 1

    detect_bootloader
    [[ $BOOTLOADER == limine && ( ${BOOT_CURRENT^^} == "$fallback" || ${BOOT_CURRENT^^} == "$target" ) ]] || { fail 'Final Limine runtime identity changed during source retirement'; return 1; }
    [[ $(leap16_current_boot_order) == "$target,$fallback"* ]] || { fail 'Final Limine primary/fallback order changed during source retirement'; return 1; }
    [[ -z $(leap16_r38_current_systemd_ids | awk 'NF') ]] || { fail 'A canonical systemd-boot NVRAM alias remains after retirement'; return 1; }
    [[ -z $(leap16_r51_extra_fallback_ids | awk 'NF') ]] || { fail 'An extra same-ESP generic-fallback alias remains after finalization'; return 1; }
    [[ $(r21_hash_privileged "$PENDING_OLD_FALLBACK_PATH") == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'Final Limine fallback bytes changed during systemd-boot retirement'; return 1; }
    validate_target_state limine || return 1
    validate_limine_boot_chain migration || return 1
    [[ $(r21_hash_privileged "${PENDING_ESP_MOUNT%/}/limine.conf") == "$final_hash" ]] || { fail 'Final Limine config hash changed after systemd-boot retirement'; return 1; }

    pending_capture_runtime_diagnostics finalized-limine-from-systemd >/dev/null 2>&1 || true
    remove_pending_transaction_snapshot || warn 'Could not remove private transaction snapshot after successful finalization'
    rm -f -- "$PENDING_STATE_FILE"
    printf '\nFINALIZED systemd-boot -> Limine successfully.\n'
    printf 'Primary Limine Boot%s is persistent first; genuine Limine fallback Boot%s is second; exact systemd-boot source state is retired.\n' "$target" "$fallback"
}

# r47 used `find ... || true` for an empty shared machine-id namespace probe.
# Treat enumeration failure as unsafe instead of silently interpreting it as
# empty.  Cleanup remains rmdir-only.
leap16_r47_machine_id_parent_is_empty_dir() {
    local parent=$1 probe
    (sudo -n test -d "$parent" 2>/dev/null || [[ -d $parent ]]) || return 1
    (sudo -n test ! -L "$parent" 2>/dev/null || [[ ! -L $parent ]]) || return 1
    probe=$(mktemp) || return 1
    if ! sudo -n find "$parent" -mindepth 1 -maxdepth 1 -print -quit >"$probe" 2>/dev/null; then
        rm -f -- "$probe"
        return 1
    fi
    [[ ! -s $probe ]]
    local rc=$?
    rm -f -- "$probe"
    return "$rc"
}

leap16_r47_limine_machine_namespace_conflicts() {
    local parent=$1 probe
    if ! sudo -n test -e "$parent" 2>/dev/null && [[ ! -e $parent ]]; then return 1; fi
    if sudo -n test -L "$parent" 2>/dev/null || [[ -L $parent ]] || \
       ! (sudo -n test -d "$parent" 2>/dev/null || [[ -d $parent ]]); then
        return 0
    fi
    probe=$(mktemp) || return 0
    if ! sudo -n find "$parent" -mindepth 1 -maxdepth 1 -print -quit >"$probe" 2>/dev/null; then
        rm -f -- "$probe"
        return 0
    fi
    if [[ -s $probe ]]; then rm -f -- "$probe"; return 0; fi
    rm -f -- "$probe"
    return 1
}

# Keep the plan honest about the new retry boundary.
eval "$(declare -f leap16_r51_plan | sed '1s/leap16_r51_plan/leap16_r51_plan_pre_leap16_r54/')"
leap16_r51_plan() {
    leap16_r51_plan_pre_leap16_r54 "$@"
    printf '  r54 note: after the exact fallback proof, persist a retirement authorization checkpoint before any systemd-boot deletion; cleanup is then idempotently resumable.\n'
}
