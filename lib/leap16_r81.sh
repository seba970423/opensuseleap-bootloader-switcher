#!/usr/bin/env bash
# leap16-r81: repair the hardware-observed Limine/rEFInd recovery contract
# and preserve rEFInd-edge diagnostics through final transaction cleanup.
# Live and restore still use the same r64 staging and independent boot proofs.

leap16_r81_recovery_block() {
    case "$1" in
        refind)
            printf '/openSUSE rEFInd recovery\n### Temporary direct recovery path retained until Limine fallback proof completes\ncomment: Native openSUSE rEFInd recovery path\nprotocol: efi\npath: boot():/EFI/refind/refind_x64.efi\n'
            ;;
        fallback)
            printf '/EFI fallback\n### Standard UEFI fallback executable; byte-identical to canonical Limine\ncomment: Standard UEFI fallback loader (Limine)\nprotocol: efi\npath: boot():/EFI/BOOT/BOOTX64.EFI\n'
            ;;
        *) return 1 ;;
    esac
}

# Check one complete stanza, not unrelated title/path matches from different
# entries. No extra EFI chainloader may masquerade as this recovery contract.
leap16_r81_recovery_block_present() {
    local conf=$1 kind=$2 block
    block=$(leap16_r81_recovery_block "$kind") || return 1
    awk -v block="$block" '
        BEGIN { n=split(block,wanted,"\n") }
        $0==wanted[1] {
            count++
            for(i=2;i<=n;i++) if(getline<=0 || $0!=wanted[i]) bad=1
            next
        }
        /^[[:space:]]*protocol:[[:space:]]*efi([[:space:]]|$)/ {bad=1}
        /^\/EFI fallback$/ || /^\/openSUSE .* recovery$/ {bad=1}
        END {exit !(count==1 && !bad)}
    ' "$conf"
}

leap16_r81_render_recovery() {
    local conf=$1 title=$2 path=$3 kind=$4 out=$5 block
    block=$(leap16_r81_recovery_block "$kind") || return 1
    awk -v title="$title" -v path="$path" -v block="$block" '
        $0==title {
            count++
            if(getline<=0 || $0 !~ /^### /) bad=1
            if(getline<=0 || $0 !~ /^comment: /) bad=1
            if(getline<=0 || $0!="protocol: efi") bad=1
            if(getline<=0 || $0!=path) bad=1
            print block
            next
        }
        {print}
        END {exit !(count==1 && !bad)}
    ' "$conf" >"$out" || return 1
    leap16_r81_recovery_block_present "$out" "$kind"
}

# Both freshly generated and validated restored Limine configs initially have
# /EFI fallback. Finalized rEFInd intentionally does not own EFI/BOOT; point
# recovery at its complete canonical tree before the first deep target gate.
leap16_r64_patch_limine_pretransfer_comment() {
    local conf="${ESP_MOUNT%/}/limine.conf" input out hash
    [[ ${BOOTLOADER:-} == refind && ${LEAP16_R64_STAGING:-0} == 1 ]] || return 1
    input=$(mktemp) || return 1
    out=$(mktemp) || { rm -f -- "$input"; return 1; }
    if ! leap16_r64_refind_read "$conf" >"$input" \
        || ! leap16_r81_render_recovery "$input" '/EFI fallback' \
            'path: boot():/EFI/BOOT/BOOTX64.EFI' refind "$out"; then
        rm -f -- "$input" "$out"
        fail 'Expected exactly one intact Limine fallback stanza before direct rEFInd recovery conversion'
        return 1
    fi
    hash=$(sha256sum -- "$out" | awk '{print $1}')
    r21_atomic_replace "$out" "$conf" "$hash" || { rm -f -- "$input" "$out"; return 1; }
    rm -f -- "$input" "$out"
    ok 'Limine candidate recovery points directly to canonical rEFInd; EFI/BOOT retains its pre-stage state'
}

eval "$(declare -f leap16_validate_limine_recovery_contract | sed '1s/leap16_validate_limine_recovery_contract/leap16_validate_limine_recovery_contract_pre_leap16_r81/')"
leap16_validate_limine_recovery_contract() {
    local conf=$1 esp=${ESP_MOUNT%/} fh ph rh expected existed old_hash fallback=''
    if [[ ${LEAP16_R64_STAGING:-0} != 1 || ${BOOTLOADER:-} != refind ]] \
        && ! leap16_r64_pending_refind_limine; then
        leap16_validate_limine_recovery_contract_pre_leap16_r81 "$@"
        return $?
    fi
    LEAP16_LIMINE_RECOVERY_DETAIL=''
    ph=$(r21_hash_privileged "$esp/EFI/LIMINE/LIMINE_X64.EFI") || return 1
    [[ $ph =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
    if [[ ${LEAP16_R64_STAGING:-0} == 1 ]]; then
        expected=${R26_SOURCE_EFI_HASH:-}
        existed=${OLD_FALLBACK_EXISTED:-}; old_hash=${OLD_FALLBACK_HASH:-}
    else
        expected=${PENDING_SOURCE_EFI_HASH:-}
        existed=${PENDING_OLD_FALLBACK_EXISTED:-}; old_hash=${PENDING_OLD_FALLBACK_HASH:-}
        [[ $ph == "$PENDING_TARGET_EFI_HASH" ]] || return 1
        fallback=$(leap16_r64_limine_fallback_id 2>/dev/null || true)
    fi

    if leap16_r81_recovery_block_present "$conf" refind; then
        rh=$(r21_hash_privileged "$esp/EFI/refind/refind_x64.efi") || return 1
        [[ $expected =~ ^[0-9A-Fa-f]{64}$ && $rh == "$expected" && $rh != "$ph" ]] || return 1
        if [[ -n $fallback ]]; then
            fh=$(r21_hash_privileged "$esp/EFI/BOOT/BOOTX64.EFI") || return 1
            [[ $fh == "$ph" && $fh == "$(leap16_r64_meta_value limine_fallback_hash)" ]] || return 1
            LEAP16_LIMINE_RECOVERY_DETAIL='Limine owns byte-identical EFI/BOOT; exact canonical rEFInd remains direct recovery until proof #2'
        elif [[ $existed == 1 ]]; then
            fh=$(r21_hash_privileged "$esp/EFI/BOOT/BOOTX64.EFI") || return 1
            [[ $old_hash =~ ^[0-9A-Fa-f]{64}$ && $fh == "$old_hash" ]] || return 1
            LEAP16_LIMINE_RECOVERY_DETAIL='Direct canonical rEFInd recovery is intact; existing generic fallback bytes remain unchanged'
        elif [[ $existed == 0 ]]; then
            [[ ! -e $esp/EFI/BOOT/BOOTX64.EFI && ! -L $esp/EFI/BOOT/BOOTX64.EFI ]] || return 1
            LEAP16_LIMINE_RECOVERY_DETAIL='Direct canonical rEFInd recovery is intact; generic fallback remains absent before transfer'
        else
            return 1
        fi
        return 0
    fi

    # This branch is reachable only inside the unchanged two-proof finalizer.
    # A final-looking config or a runtime-validated primary alone earns nothing.
    [[ ${LEAP16_R81_FINAL_MENU_AUTHORIZED:-0} == 1 \
       && ${PENDING_PHASE:-} == runtime-validated && -n $fallback \
       && ${BOOT_CURRENT^^} == "${fallback^^}" ]] || return 1
    leap16_r81_recovery_block_present "$conf" fallback || return 1
    fh=$(r21_hash_privileged "$esp/EFI/BOOT/BOOTX64.EFI") || return 1
    [[ $fh == "$ph" && $fh == "$(leap16_r64_meta_value limine_fallback_hash)" ]] || return 1
    LEAP16_LIMINE_RECOVERY_DETAIL='After two Limine boot proofs, the final menu exposes the byte-identical standard EFI fallback'
}

# Recovery already uses canonical rEFInd. Freeze an exact rollback copy at the
# same r64 transfer boundary; no premature EFI/BOOT recovery entry is needed.
leap16_r64_rewrite_limine_recovery_to_refind() {
    local conf="${PENDING_ESP_MOUNT%/}/limine.conf" pre expected
    pre=$(leap16_r64_limine_preconf_path) || return 1
    expected=$(leap16_r64_meta_value limine_primary_conf_hash) || return 1
    [[ $expected =~ ^[0-9A-Fa-f]{64}$ && $(r21_hash_privileged "$conf") == "$expected" ]] \
        || { fail 'Primary limine.conf changed before fallback transfer' >&2; return 1; }
    leap16_r64_refind_read "$conf" >"$pre" || return 1
    chmod 600 -- "$pre" || return 1
    [[ $(sha256sum -- "$pre" | awk '{print $1}') == "$expected" ]] || return 1
    leap16_r81_recovery_block_present "$pre" refind \
        || { fail 'Primary Limine config lacks exact direct rEFInd recovery' >&2; return 1; }
    printf '%s\n' "$expected"
}

# Preserve the established visible fallback menu, as GRUB/systemd -> Limine do.
leap16_r64_remove_limine_refind_recovery_block() {
    local conf="${PENDING_ESP_MOUNT%/}/limine.conf" expected input out hash
    [[ ${LEAP16_R81_FINAL_MENU_AUTHORIZED:-0} == 1 ]] || return 1
    expected=$(leap16_r64_meta_value limine_transferred_conf_hash) || return 1
    [[ $expected =~ ^[0-9A-Fa-f]{64}$ && $(r21_hash_privileged "$conf") == "$expected" ]] \
        || { fail 'Transferred limine.conf changed before final fallback-menu conversion' >&2; return 1; }
    input=$(mktemp) || return 1
    out=$(mktemp) || { rm -f -- "$input"; return 1; }
    if ! leap16_r64_refind_read "$conf" >"$input" \
        || ! leap16_r81_render_recovery "$input" '/openSUSE rEFInd recovery' \
            'path: boot():/EFI/refind/refind_x64.efi' fallback "$out"; then
        rm -f -- "$input" "$out"; return 1
    fi
    hash=$(sha256sum -- "$out" | awk '{print $1}')
    r21_atomic_replace "$out" "$conf" "$hash" || { rm -f -- "$input" "$out"; return 1; }
    rm -f -- "$input" "$out"
    printf '%s\n' "$hash"
}

eval "$(declare -f leap16_r64_retire_refind_after_limine_fallback_proof | sed '1s/leap16_r64_retire_refind_after_limine_fallback_proof/leap16_r64_retire_refind_after_limine_fallback_proof_pre_leap16_r81/')"
leap16_r64_retire_refind_after_limine_fallback_proof() {
    # The inherited function's very first gate is the complete fresh fallback
    # runtime proof. This dynamically scoped flag admits only its final menu.
    local LEAP16_R81_FINAL_MENU_AUTHORIZED=1
    leap16_r64_retire_refind_after_limine_fallback_proof_pre_leap16_r81 "$@"
}

# Two passes tolerate one re-synthesis wave. Enumeration, baseline collisions,
# changed identities and failed deletions are fatal on either pass. These are
# the same r80 ownership gates, rechecked after the BootOrder write as well.
leap16_r80_normalize_limine_aliases_after_fallback_proof() {
    [[ ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == refind:limine \
       && ${PENDING_PHASE:-} == runtime-validated ]] || return 1
    leap16_r64_limine_fallback_staged || return 1
    local target=${PENDING_TARGET_BOOT_ID^^} fallback pass raw primary_raw fallback_raw id path csv
    local -a removals=()
    fallback=$(leap16_r64_limine_fallback_id) || return 1; fallback=${fallback^^}
    for pass in 1 2; do
        leap16_r80_validate_limine_keep_aliases || return 1
        primary_raw=$(leap16_r80_collect_poststage_duplicates "$LEAP16_R80_LIMINE_PRIMARY_PATH" "$target") || return 1
        fallback_raw=$(leap16_r80_collect_poststage_duplicates "$LEAP16_R21_FALLBACK_EFI_PATH" "$fallback") || return 1
        removals=()
        raw=$primary_raw
        [[ -z $fallback_raw ]] || raw="${raw}${raw:+$'\n'}${fallback_raw}"
        [[ -z $raw ]] || mapfile -t removals <<<"$raw"
        if ((${#removals[@]})); then
            csv=$(IFS=,; printf '%s' "${removals[*]}")
            leap16_r77_rewrite_order_without_ids "$csv" >/dev/null || return 1
            for id in "${removals[@]}"; do
                [[ -n $id ]] || continue
                path=$LEAP16_R21_FALLBACK_EFI_PATH
                [[ $'\n'$primary_raw$'\n' != *$'\n'"$id"$'\n'* ]] || path=$LEAP16_R80_LIMINE_PRIMARY_PATH
                if leap16_r80_id_existed_in_baseline "$id" \
                    || ! leap16_nvram_entry_matches_current_esp "$id" \
                    || ! nvram_id_matches_path "$id" "$path"; then
                    fail "Duplicate Boot$id changed ownership before deletion"; return 1
                fi
                leap16_order_has_id "$(leap16_current_boot_order)" "$id" \
                    && { fail "Duplicate Boot$id remains in BootOrder before deletion"; return 1; }
                sudo efibootmgr -b "$id" -B >/dev/null \
                    || { fail "Could not delete bounded Limine/fallback duplicate Boot$id"; return 1; }
                if boot_id_exists "$id"; then
                    leap16_nvram_entry_matches_current_esp "$id" && nvram_id_matches_path "$id" "$path" \
                        || { fail "Boot$id changed identity after deletion; refusing further cleanup"; return 1; }
                    # Same-path re-synthesis is re-enumerated below; it gets
                    # at most the one remaining pass and cannot earn success.
                fi
                ok "Deleted bounded Limine/fallback duplicate Boot$id (normalization pass $pass/2)"
            done
        fi
        leap16_r80_validate_limine_keep_aliases || return 1
        primary_raw=$(leap16_r80_current_limine_primary_ids) || return 1
        fallback_raw=$(leap16_r80_current_limine_fallback_ids) || return 1
        if [[ $primary_raw == "$target" && $fallback_raw == "$fallback" ]]; then
            ok "Limine NVRAM aliases are unique: primary Boot$target, fallback Boot$fallback"
            return 0
        fi
    done
    fail 'Limine alias topology did not converge after two bounded normalization passes; success is refused'
    return 1
}

leap16_r81_diagnostic_pair() {
    case "${PENDING_SOURCE:-}:${PENDING_TARGET:-}" in limine:refind|refind:limine) return 0;; *) return 1;; esac
}

leap16_r81_report_cache_dir() {
    [[ -n ${LEAP16_DIAGNOSTIC_ROOT:-} ]] || return 1
    printf '%s/.r81-refind-report\n' "${LEAP16_DIAGNOSTIC_ROOT%/}"
}

# Report-only context. It is never supplied to ownership, rollback or runtime
# proof gates. The unique snapshot path binds the cache to this transaction.
leap16_r81_cache_report_context() {
    leap16_r81_diagnostic_pair || return 0
    local baseline cache tmp fallback='' pu
    baseline=$(leap16_r64_baseline_path) || return 1
    leap16_r60_valid_efibootmgr_dump "$baseline" || return 1
    cache=$(leap16_r81_report_cache_dir) || return 1
    [[ ! -L $cache ]] || return 1
    mkdir -p -- "$cache" || return 1
    chmod 700 -- "$cache" || return 1
    pu=$(leap16_r80_transaction_partuuid) || return 1
    [[ -n $pu ]] || return 1
    fallback=$(leap16_r64_limine_fallback_id 2>/dev/null || true)
    cp -- "$baseline" "$cache/baseline.txt" || return 1
    tmp=$(mktemp -- "$cache/context.XXXXXX") || return 1
    {
        printf 'snapshot\t%s\n' "$PENDING_TRANSACTION_SNAPSHOT_DIR"
        printf 'direction\t%s:%s\n' "$PENDING_SOURCE" "$PENDING_TARGET"
        printf 'target\t%s\n' "${PENDING_TARGET_BOOT_ID^^}"
        printf 'source\t%s\n' "${PENDING_OLD_BOOT_ID^^}"
        printf 'partuuid\t%s\n' "$pu"
        printf 'fallback\t%s\n' "$fallback"
    } >"$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$cache/context.tsv"
}

leap16_r81_report_value() {
    local cache
    cache=$(leap16_r81_report_cache_dir) || return 1
    awk -F'\t' -v key="$1" '$1==key {print $2; exit}' "$cache/context.tsv"
}

leap16_r81_report_cache_matches() {
    [[ $(leap16_r81_report_value snapshot) == "${PENDING_TRANSACTION_SNAPSHOT_DIR:-}" \
       && $(leap16_r81_report_value direction) == "${PENDING_SOURCE:-}:${PENDING_TARGET:-}" \
       && $(leap16_r81_report_value target) == "${PENDING_TARGET_BOOT_ID^^}" \
       && $(leap16_r81_report_value source) == "${PENDING_OLD_BOOT_ID^^}" ]]
}

leap16_r81_report_line_matches() {
    local line=$1 expected=$2 pu=$3 path
    [[ ${line,,} == *",gpt,${pu,,},"* ]] || return 1
    path=$(efi_path_from_efibootmgr_line "$line") || return 1
    [[ $(normalize_efi_path "${path,,}") == "$(normalize_efi_path "${expected,,}")" ]]
}

# Classify complete Boot#### tables, including parked aliases. Final source
# absence is the expected state after retirement, never a missing-recovery
# error. Intermediate stages retain the source and independently track proof #2.
leap16_r81_assess_pair_order() {
    local phase=$1 cache baseline current order next boot_current pu target source fallback='' final=0
    local target_path source_path id line old path kind expected='' expected_foreign='' stable='' first
    local target_count=0 fallback_count=0 source_count=0 has_primary_source=0 has_fallback_source=0
    local -A roles=() base_lines=() current_lines=()
    local -a original_ids=() ids=()
    LEAP16_ORDER_REASON=''; LEAP16_ORDER_CURRENT_FULL=''; LEAP16_ORDER_EXPECTED_STABLE=''; LEAP16_ORDER_CURRENT_STABLE=''
    LEAP16_ORDER_BBS_ORIGINAL=''; LEAP16_ORDER_BBS_CURRENT=''; LEAP16_ORDER_BBS_MISSING=''; LEAP16_ORDER_BBS_ADDED=''
    leap16_r81_report_cache_matches || { LEAP16_ORDER_REASON='rEFInd-edge report context is missing or belongs to another transaction'; return 1; }
    cache=$(leap16_r81_report_cache_dir) || return 1
    leap16_r60_valid_efibootmgr_dump "$cache/baseline.txt" \
        || { LEAP16_ORDER_REASON='complete cached firmware baseline is unavailable'; return 1; }
    baseline=$(cat -- "$cache/baseline.txt") || return 1
    current=$(efibootmgr -v) || { LEAP16_ORDER_REASON='current firmware enumeration failed'; return 1; }
    order=$(awk -F': ' '/^BootOrder:/{print toupper($2);exit}' <<<"$current")
    next=$(awk -F': ' '/^BootNext:/{print toupper($2);exit}' <<<"$current")
    boot_current=$(awk -F': ' '/^BootCurrent:/{print toupper($2);exit}' <<<"$current")
    [[ $order =~ ^[0-9A-F]{4}(,[0-9A-F]{4})*$ ]] || { LEAP16_ORDER_REASON='current BootOrder is unreadable'; return 1; }
    LEAP16_ORDER_CURRENT_FULL=$order
    pu=$(leap16_r81_report_value partuuid); target=${PENDING_TARGET_BOOT_ID^^}; source=${PENDING_OLD_BOOT_ID^^}
    case "$phase" in finalized-refind-from-limine|finalized-limine-from-refind|auto-resume-pass) final=1;; esac
    if [[ $PENDING_TARGET == refind ]]; then
        target_path=$LEAP16_R64_REFIND_EFI; source_path=$LEAP16_R80_LIMINE_PRIMARY_PATH
    else
        target_path=$LEAP16_R80_LIMINE_PRIMARY_PATH; source_path=$LEAP16_R64_REFIND_EFI
        fallback=$(leap16_r81_report_value fallback)
    fi
    while IFS= read -r line; do
        [[ $line =~ ^Boot([0-9A-Fa-f]{4})\*?[[:space:]] ]] || continue
        id=${BASH_REMATCH[1]^^}; base_lines[$id]=$line
    done <<<"$baseline"
    [[ $(awk -F': ' '/^BootOrder:/{print toupper($2);exit}' <<<"$baseline") == "${PENDING_ORIGINAL_BOOT_ORDER^^}" ]] \
        || { LEAP16_ORDER_REASON='cached baseline does not match the original BootOrder'; return 1; }
    IFS=',' read -ra original_ids <<<"${PENDING_ORIGINAL_BOOT_ORDER^^}"
    for id in "${original_ids[@]}"; do
        [[ -n ${base_lines[$id]:-} ]] || { LEAP16_ORDER_REASON="baseline is missing original Boot$id"; return 1; }
    done
    while IFS= read -r line; do
        [[ $line =~ ^Boot([0-9A-Fa-f]{4})\*?[[:space:]] ]] || continue
        id=${BASH_REMATCH[1]^^}; current_lines[$id]=$line; kind=foreign
        if leap16_line_is_bbs "$line"; then roles[$id]=bbs; continue; fi
        if leap16_r81_report_line_matches "$line" "$target_path" "$pu"; then
            [[ $id == "$target" && $line == "Boot$id*"* ]] || { LEAP16_ORDER_REASON='canonical target alias is duplicated, inactive or changed'; return 1; }
            target_count=$((target_count+1)); kind=target
        elif leap16_r81_report_line_matches "$line" "$source_path" "$pu" \
            || { [[ $PENDING_SOURCE == limine ]] && leap16_r81_report_line_matches "$line" "$LEAP16_R21_FALLBACK_EFI_PATH" "$pu"; }; then
            (( ! final )) || { LEAP16_ORDER_REASON="retired source alias Boot$id remains"; return 1; }
            old=${base_lines[$id]:-}
            if [[ -n $old ]]; then
                path=$(efi_path_from_efibootmgr_line "$line") || return 1
                leap16_r81_report_line_matches "$old" "$path" "$pu" || { LEAP16_ORDER_REASON="source alias Boot$id reused an unrelated baseline ID"; return 1; }
            fi
            source_count=$((source_count+1)); kind=source
            if leap16_r81_report_line_matches "$line" "$source_path" "$pu"; then has_primary_source=1; else has_fallback_source=1; fi
        elif [[ -n $fallback ]] && leap16_r81_report_line_matches "$line" "$LEAP16_R21_FALLBACK_EFI_PATH" "$pu"; then
            [[ $id == "$fallback" && $line == "Boot$id*"* ]] || { LEAP16_ORDER_REASON='Limine fallback alias is duplicated, inactive or changed'; return 1; }
            fallback_count=$((fallback_count+1)); kind=fallback
        else
            [[ ${base_lines[$id]:-} == "$line" ]] || { LEAP16_ORDER_REASON="unrelated EFI entry Boot$id appeared or changed"; return 1; }
        fi
        roles[$id]=$kind
    done <<<"$current"
    ((target_count==1)) || { LEAP16_ORDER_REASON='exact canonical target alias is missing'; return 1; }
    if (( ! final )); then
        ((has_primary_source)) || { LEAP16_ORDER_REASON='canonical source recovery is missing before retirement'; return 1; }
        [[ $PENDING_SOURCE != limine || $has_fallback_source == 1 ]] || { LEAP16_ORDER_REASON='Limine source fallback is missing before retirement'; return 1; }
    fi
    [[ -z $fallback || $fallback_count == 1 ]] || { LEAP16_ORDER_REASON='recorded Limine fallback is missing'; return 1; }
    [[ $PENDING_TARGET != limine || $final == 0 || -n $fallback ]] || { LEAP16_ORDER_REASON='final Limine fallback identity is unavailable'; return 1; }

    # Preserve every unrelated baseline entry, even those outside BootOrder.
    for id in "${!base_lines[@]}"; do
        line=${base_lines[$id]}
        leap16_line_is_bbs "$line" && continue
        leap16_r81_report_line_matches "$line" "$source_path" "$pu" && continue
        if [[ $PENDING_SOURCE == limine ]] && leap16_r81_report_line_matches "$line" "$LEAP16_R21_FALLBACK_EFI_PATH" "$pu"; then continue; fi
        [[ -z $fallback || $id != "$fallback" ]] || continue
        [[ ${current_lines[$id]:-} == "$line" ]] || { LEAP16_ORDER_REASON="unrelated baseline Boot$id disappeared or changed"; return 1; }
    done
    IFS=',' read -ra original_ids <<<"${PENDING_ORIGINAL_BOOT_ORDER^^}"
    for id in "${original_ids[@]}"; do
        [[ ${roles[$id]:-} != foreign ]] || expected_foreign=$(leap16_r60_csv_append_unique "$expected_foreign" "$id")
        if leap16_line_is_bbs "${base_lines[$id]:-}"; then LEAP16_ORDER_BBS_ORIGINAL=$(leap16_r60_csv_append_unique "$LEAP16_ORDER_BBS_ORIGINAL" "$id"); fi
    done
    IFS=',' read -ra ids <<<"$order"
    local foreign='' core='' kind_current
    for id in "${ids[@]}"; do
        kind_current=${roles[$id]:-}
        [[ -n $kind_current ]] || { LEAP16_ORDER_REASON="BootOrder references missing Boot$id"; return 1; }
        if [[ $kind_current == bbs ]]; then
            LEAP16_ORDER_BBS_CURRENT=$(leap16_r60_csv_append_unique "$LEAP16_ORDER_BBS_CURRENT" "$id"); continue
        fi
        leap16_order_has_id "$stable" "$id" && { LEAP16_ORDER_REASON="BootOrder repeats Boot$id"; return 1; }
        stable=$(leap16_r60_csv_append_unique "$stable" "$id")
        if [[ $kind_current == foreign ]]; then foreign=$(leap16_r60_csv_append_unique "$foreign" "$id"); else core=$(leap16_r60_csv_append_unique "$core" "$id"); fi
    done
    [[ $foreign == "$expected_foreign" ]] || { LEAP16_ORDER_REASON='unrelated persistent EFI order changed'; return 1; }
    LEAP16_ORDER_CURRENT_STABLE=$stable
    if ((final)); then
        expected=$target; [[ -z $fallback ]] || expected="$target,$fallback"
        [[ -z $expected_foreign ]] || expected="$expected,$expected_foreign"
        [[ $stable == "$expected" && -z $next ]] || { LEAP16_ORDER_REASON='final persistent topology or BootNext is not exact'; return 1; }
        [[ $boot_current == "${fallback:-$target}" ]] || { LEAP16_ORDER_REASON='final BootCurrent does not match the required proof identity'; return 1; }
        LEAP16_ORDER_REASON='runtime-proven target topology is exact; owned source aliases are retired; unrelated EFI entries are preserved'
    else
        first=${stable%%,*}
        if [[ -n $fallback ]]; then
            [[ $stable == "$target,$fallback" || $stable == "$target,$fallback,"* ]] || { LEAP16_ORDER_REASON='Limine primary/fallback do not lead the transferred topology'; return 1; }
        else
            [[ $first == "$source" || ( $first == "$target" && ${PENDING_PHASE:-} == runtime-validated ) ]] \
                || { LEAP16_ORDER_REASON='source-first or runtime-proven promotion order is not satisfied'; return 1; }
        fi
        leap16_order_has_id "$core" "$source" && leap16_order_has_id "$core" "$target" \
            || { LEAP16_ORDER_REASON='source/target recovery identities are not both in BootOrder'; return 1; }
        [[ -z $next || $next == "${fallback:-$target}" ]] || { LEAP16_ORDER_REASON='unrelated BootNext appeared'; return 1; }
        # This stage permits bounded source alias churn; report its independently
        # checked constraints without presenting observed order as an oracle.
        expected=''
        LEAP16_ORDER_REASON='target and source recovery identities match this pre-retirement proof stage; unrelated EFI entries are preserved'
    fi
    LEAP16_ORDER_EXPECTED_STABLE=$expected
    for id in ${LEAP16_ORDER_BBS_ORIGINAL//,/ }; do leap16_order_has_id "$LEAP16_ORDER_BBS_CURRENT" "$id" || LEAP16_ORDER_BBS_MISSING=$(leap16_r60_csv_append_unique "$LEAP16_ORDER_BBS_MISSING" "$id"); done
    for id in ${LEAP16_ORDER_BBS_CURRENT//,/ }; do leap16_order_has_id "$LEAP16_ORDER_BBS_ORIGINAL" "$id" || LEAP16_ORDER_BBS_ADDED=$(leap16_r60_csv_append_unique "$LEAP16_ORDER_BBS_ADDED" "$id"); done
    return 0
}

eval "$(declare -f leap16_write_firmware_order_report | sed '1s/leap16_write_firmware_order_report/leap16_write_firmware_order_report_pre_leap16_r81/')"
leap16_write_firmware_order_report() {
    if ! leap16_r81_diagnostic_pair; then leap16_write_firmware_order_report_pre_leap16_r81 "$@"; return $?; fi
    local rc=0
    leap16_r81_assess_pair_order "${2:-snapshot}" || rc=$?
    leap16_emit_firmware_order_report "$1" "$rc"
}

eval "$(declare -f leap16_capture_diagnostics | sed '1s/leap16_capture_diagnostics/leap16_capture_diagnostics_pre_leap16_r81/')"
leap16_capture_diagnostics() {
    if ! leap16_r81_diagnostic_pair; then leap16_capture_diagnostics_pre_leap16_r81 "$@"; return $?; fi
    local dir cache snap file
    leap16_r81_cache_report_context >/dev/null 2>&1 || true
    dir=$(leap16_capture_diagnostics_pre_leap16_r81 "$@") || return 1
    [[ -d $dir ]] || return 1
    leap16_diag_read_file "${ESP_MOUNT%/}/EFI/refind/refind.conf" "$dir/refind.conf"
    leap16_diag_read_file /boot/refind_linux.conf "$dir/refind_linux.conf"
    r33_refind_previous_boot_text >"$dir/refind-PreviousBoot.txt" 2>&1 || true
    for file in refind_x64.efi drivers_x64/ext4_x64.efi; do
        printf '%s  %s\n' "$(r21_hash_privileged "${ESP_MOUNT%/}/EFI/refind/$file" 2>/dev/null || printf MISSING)" "${ESP_MOUNT%/}/EFI/refind/$file"
    done >"$dir/refind-artifact-sha256.txt"
    cache=$(leap16_r81_report_cache_dir) || return 1
    if leap16_r81_report_cache_matches; then
        cp -- "$cache/baseline.txt" "$dir/r64-firmware-baseline.txt" || return 1
        cp -- "$cache/context.tsv" "$dir/r81-report-context.tsv" || return 1
    fi
    snap=${PENDING_TRANSACTION_SNAPSHOT_DIR:-}
    for file in "$LEAP16_R64_META" source-owned.tsv target-owned.tsv; do
        [[ ! -f $snap/$file ]] || cp -- "$snap/$file" "$dir/$file" || return 1
    done
    printf '%s\n' "$dir"
}

eval "$(declare -f pending_capture_runtime_diagnostics | sed '1s/pending_capture_runtime_diagnostics/pending_capture_runtime_diagnostics_pre_leap16_r81/')"
pending_capture_runtime_diagnostics() {
    if ! leap16_r81_diagnostic_pair; then pending_capture_runtime_diagnostics_pre_leap16_r81 "$@"; return $?; fi
    local dir
    dir=$(leap16_capture_diagnostics "${1:-runtime}") || return 1
    printf '%s\n' "$PENDING_SOURCE_CMDLINE" >"$dir/recorded-source-cmdline.txt" || return 1
    cat /proc/cmdline >"$dir/runtime-target-cmdline.txt" || return 1
    efibootmgr -v >"$dir/efibootmgr-runtime-v.txt" 2>&1 || true
    printf '%s\n' "$dir"
}

leap16_r64_print_matrix() {
    cat <<'MATRIX'
openSUSE Leap 16 bootloader matrix — leap16-r81

Legend:
  HW-PROVEN       completed automatically on real hardware with exact final topology
  HW-PENDING      implemented; complete hardware evidence still required
  —               same-backend; not a cross-loader edge

LIVE SWITCH MATRIX (source rows -> target columns)
                 GRUB2        Limine       systemd-boot  rEFInd
  GRUB2          —            HW-PROVEN    HW-PROVEN     HW-PROVEN
  Limine         HW-PROVEN    —            HW-PROVEN     HW-PROVEN
  systemd-boot   HW-PROVEN    HW-PROVEN    —             HW-PENDING
  rEFInd         HW-PROVEN    HW-PENDING   HW-PENDING    —

CROSS-LOADER RESTORE MATRIX (active source -> restored backup target)
                 GRUB2        Limine       systemd-boot  rEFInd
  GRUB2          —            HW-PROVEN    HW-PROVEN     HW-PROVEN
  Limine         HW-PROVEN    —            HW-PROVEN     HW-PENDING
  systemd-boot   HW-PROVEN    HW-PROVEN    —             HW-PENDING
  rEFInd         HW-PROVEN    HW-PENDING   HW-PENDING    —

BACKUP BACKENDS
  GRUB2          HW-PROVEN
  Limine         HW-PROVEN
  systemd-boot   HW-PROVEN
  rEFInd         HW-PROVEN

r81 evidence scope:
  - The Sep 5 r80 bundle proves Limine -> rEFInd live through direct-kernel proof,
    automatic source retirement and final BootCurrent/BootOrder 0001.
  - Its rEFInd -> Limine attempt failed before candidate commit and rolled back.
  - Neither Limine/rEFInd restore direction has a completion trace in that bundle.
  - r81 repairs the reverse recovery contract and the pair's diagnostic export;
    local tests never promote an unproven hardware or restore edge.
  - GRUB2 <-> rEFInd live and both restores remain HW-PROVEN per the handoff.
MATRIX
}
