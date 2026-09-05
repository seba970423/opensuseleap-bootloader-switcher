#!/usr/bin/env bash
# leap16-r60: diagnostic lifecycle repair for every staged systemd edge.
#
# This overlay changes diagnostics only. It does not alter candidate staging,
# BootNext, runtime proof, promotion, fallback transfer, ownership gates,
# cleanup, backup contents, or restore execution.

LEAP16_R60_BASELINE_CACHE='.r60-firmware-baseline-v.txt'
LEAP16_R60_CONTEXT_CACHE='.r60-direct-edge-context.tsv'

leap16_r60_valid_efibootmgr_dump() {
    local file=$1
    [[ -s $file && ! -L $file ]] || return 1
    grep -Eq '^BootCurrent:[[:space:]]+[0-9A-Fa-f]{4}[[:space:]]*$' "$file" || return 1
    grep -Eq '^BootOrder:[[:space:]]+[0-9A-Fa-f]{4}(,[0-9A-Fa-f]{4})*[[:space:]]*$' "$file" || return 1
    grep -Eq '^Boot[0-9A-Fa-f]{4}\*?[[:space:]]' "$file"
}

# Never let the post-reboot tail of the interactive process truncate the valid
# staged firmware capture written while the transaction snapshot was bound.
leap16_r44_diag_bind_pending() {
    [[ -n ${LEAP16_R44_TRANSACTION_DIAG_DIR:-} && -d $LEAP16_R44_TRANSACTION_DIAG_DIR ]] || return 0
    local snap=${PENDING_TRANSACTION_SNAPSHOT_DIR:-${TRANSACTION_SNAPSHOT_DIR:-}} tmp=''
    [[ -n $snap && -d $snap ]] || return 0
    printf '%s\n' "$LEAP16_R44_TRANSACTION_DIAG_DIR" >"$snap/$LEAP16_R44_DIAG_POINTER" 2>/dev/null || true
    chmod 600 -- "$snap/$LEAP16_R44_DIAG_POINTER" 2>/dev/null || true
    tmp=$(mktemp -- "$LEAP16_R44_TRANSACTION_DIAG_DIR/.staged-efibootmgr-v.XXXXXX") || tmp=''
    if [[ -n $tmp ]]; then
        if efibootmgr -v >"$tmp" 2>&1 && leap16_r60_valid_efibootmgr_dump "$tmp"; then
            chmod 600 -- "$tmp" 2>/dev/null || true
            mv -f -- "$tmp" "$LEAP16_R44_TRANSACTION_DIAG_DIR/staged-efibootmgr-v.txt" || rm -f -- "$tmp"
        else
            rm -f -- "$tmp"
        fi
    fi
    [[ -n ${PENDING_STATE_FILE:-} && -r ${PENDING_STATE_FILE:-} ]] \
        && cp -- "$PENDING_STATE_FILE" "$LEAP16_R44_TRANSACTION_DIAG_DIR/pending-migration.tsv" 2>/dev/null || true
}

eval "$(declare -f leap16_pending_firmware_baseline_path | sed '1s/leap16_pending_firmware_baseline_path/leap16_pending_firmware_baseline_path_pre_leap16_r60/')"

leap16_r60_cached_baseline_path() {
    [[ -n ${LEAP16_DIAGNOSTIC_ROOT:-} ]] || return 1
    printf '%s/%s\n' "${LEAP16_DIAGNOSTIC_ROOT%/}" "$LEAP16_R60_BASELINE_CACHE"
}

# All format-5 adapter baselines have the same complete efibootmgr -v shape.
# Older generic diagnostics knew only the original filename.
leap16_pending_firmware_baseline_path() {
    local snap candidate old=''
    for snap in \
        "${PENDING_TRANSACTION_SNAPSHOT_DIR:-}" \
        "${TRANSACTION_SNAPSHOT_DIR:-}" \
        "$(leap16_diag_pending_value transaction_snapshot_dir 2>/dev/null || true)"; do
        [[ -n $snap ]] || continue
        for candidate in "$snap/source-firmware-baseline.txt" "$snap/prestage-efibootmgr-v.txt"; do
            if leap16_r60_valid_efibootmgr_dump "$candidate"; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done
    done
    old=$(leap16_pending_firmware_baseline_path_pre_leap16_r60 2>/dev/null || true)
    if [[ -n $old ]] && leap16_r60_valid_efibootmgr_dump "$old"; then
        printf '%s\n' "$old"
        return 0
    fi
    candidate=$(leap16_r60_cached_baseline_path 2>/dev/null || true)
    [[ -n $candidate ]] && leap16_r60_valid_efibootmgr_dump "$candidate" || return 1
    printf '%s\n' "$candidate"
}

leap16_r60_cache_firmware_baseline() {
    local source cache tmp
    source=$(leap16_pending_firmware_baseline_path 2>/dev/null || true)
    [[ -n $source ]] && leap16_r60_valid_efibootmgr_dump "$source" || return 0
    cache=$(leap16_r60_cached_baseline_path 2>/dev/null || true)
    [[ -n $cache && -d ${LEAP16_DIAGNOSTIC_ROOT:-/nonexistent} ]] || return 0
    if leap16_r60_valid_efibootmgr_dump "$cache"; then return 0; fi
    tmp=$(mktemp -- "${LEAP16_DIAGNOSTIC_ROOT%/}/.r60-firmware-baseline.XXXXXX") || return 0
    if cp -- "$source" "$tmp" && leap16_r60_valid_efibootmgr_dump "$tmp"; then
        chmod 600 -- "$tmp" 2>/dev/null || true
        mv -f -- "$tmp" "$cache" || rm -f -- "$tmp"
    else
        rm -f -- "$tmp"
    fi
}

leap16_r60_context_path() {
    [[ -n ${LEAP16_DIAGNOSTIC_ROOT:-} ]] || return 1
    printf '%s/%s\n' "${LEAP16_DIAGNOSTIC_ROOT%/}" "$LEAP16_R60_CONTEXT_CACHE"
}

leap16_r60_discover_fallback_id() {
    local id='' ids=''
    case "${PENDING_SOURCE:-}:${PENDING_TARGET:-}" in
        limine:systemd-boot) id=$(leap16_r48_fallback_id 2>/dev/null || true) ;;
        systemd-boot:limine)
            id=$(leap16_r51_fallback_id 2>/dev/null || true)
            if [[ ! ${id^^} =~ ^[0-9A-F]{4}$ ]]; then
                ids=$(r21_fallback_ids_now 2>/dev/null | awk '/^[0-9A-Fa-f]{4}$/{print toupper($0)}' | LC_ALL=C sort -u | paste -sd, -)
                [[ -n $ids && $ids != *,* ]] && id=$ids
            fi
            ;;
    esac
    id=${id^^}
    [[ $id =~ ^[0-9A-F]{4}$ ]] || return 1
    printf '%s\n' "$id"
}

leap16_r60_context_value() {
    local key=$1 file
    file=$(leap16_r60_context_path 2>/dev/null || true)
    [[ -n $file && -r $file ]] || return 1
    awk -F'\t' -v key="$key" '$1==key {print $2; exit}' "$file" 2>/dev/null
}

leap16_r60_cache_direct_edge_context() {
    local direction="${PENDING_SOURCE:-}:${PENDING_TARGET:-}" fallback='' file tmp
    case "$direction" in limine:systemd-boot|systemd-boot:limine) ;; *) return 0 ;; esac
    fallback=$(leap16_r60_discover_fallback_id 2>/dev/null || leap16_r60_context_value fallback_boot_id 2>/dev/null || true)
    file=$(leap16_r60_context_path 2>/dev/null || true)
    [[ -n $file && -d ${LEAP16_DIAGNOSTIC_ROOT:-/nonexistent} ]] || return 0
    tmp=$(mktemp -- "${LEAP16_DIAGNOSTIC_ROOT%/}/.r60-direct-edge-context.XXXXXX") || return 0
    {
        printf 'direction\t%s\n' "$direction"
        printf 'source_boot_id\t%s\n' "${PENDING_OLD_BOOT_ID^^}"
        printf 'target_boot_id\t%s\n' "${PENDING_TARGET_BOOT_ID^^}"
        printf 'fallback_boot_id\t%s\n' "$fallback"
        printf 'original_boot_order\t%s\n' "${PENDING_ORIGINAL_BOOT_ORDER^^}"
    } >"$tmp" || { rm -f -- "$tmp"; return 0; }
    chmod 600 -- "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$file" || rm -f -- "$tmp"
}

# Route systemd-boot through the same Leap checkpoint collector as GRUB/Limine.
# Cache report-only context first so the post-finalization report remains valid
# after the private transaction snapshot is intentionally deleted.
pending_capture_runtime_diagnostics() {
    local phase=${1:-runtime} dir target_diag=''
    leap16_r60_cache_firmware_baseline
    leap16_r60_cache_direct_edge_context
    case "$PENDING_TARGET" in
        grub) target_diag=$(capture_grub_diagnostics "$phase" 2>/dev/null | tail -n1 || true) ;;
        limine) target_diag=$(capture_limine_diagnostics "$phase" 2>/dev/null | tail -n1 || true) ;;
        systemd-boot) target_diag=$(leap16_capture_diagnostics "$phase" 2>/dev/null | tail -n1 || true) ;;
    esac
    if [[ -n $target_diag && -d $target_diag ]]; then
        dir=$target_diag
    else
        dir="$HOME/cachyos-bootloader-diagnostics/$(date +%Y%m%d-%H%M%S)-$phase"
        mkdir -p -- "$dir" || return 1
        chmod 700 -- "$dir" 2>/dev/null || true
    fi
    printf '%s\n' "$PENDING_SOURCE_CMDLINE" >"$dir/recorded-source-cmdline.txt" 2>/dev/null || true
    cat /proc/cmdline >"$dir/runtime-target-cmdline.txt" 2>/dev/null || true
    uname -a >"$dir/uname-a.txt" 2>&1 || true
    efibootmgr -v >"$dir/efibootmgr-runtime-v.txt" 2>&1 || true
    printf '%s\n' "$dir"
}

leap16_r60_csv_append_unique() {
    local csv=$1 value=$2 item
    [[ -n $value ]] || { printf '%s\n' "$csv"; return 0; }
    IFS=',' read -ra _r60_csv_items <<<"$csv"
    for item in "${_r60_csv_items[@]}"; do [[ $item == "$value" ]] && { printf '%s\n' "$csv"; return 0; }; done
    leap16_csv_append "$csv" "$value"
}

leap16_r60_line_path_matches() {
    local dump=$1 id=${2^^} expected=$3 line path
    line=$(leap16_line_for_id_in_dump "$dump" "$id")
    [[ -n $line ]] || return 1
    path=$(efi_path_from_efibootmgr_line "$line" 2>/dev/null || true)
    [[ -n $path && $(normalize_efi_path "$path" | tr '[:upper:]' '[:lower:]') == $(normalize_efi_path "$expected" | tr '[:upper:]' '[:lower:]') ]]
}

leap16_r60_direct_edge_fallback_id() {
    local id
    id=$(leap16_r60_discover_fallback_id 2>/dev/null || true)
    if [[ ! ${id^^} =~ ^[0-9A-F]{4}$ ]]; then id=$(leap16_r60_context_value fallback_boot_id 2>/dev/null || true); fi
    id=${id^^}
    [[ $id =~ ^[0-9A-F]{4}$ ]] || return 1
    printf '%s\n' "$id"
}

# Report direct Limine/systemd states according to their actual proof
# choreography. This is read-only evidence generation; transaction gates keep
# using their existing, hardware-proven validators.
leap16_r60_assess_direct_edge_order() {
    local phase=$1 direction="${PENDING_SOURCE:-}:${PENDING_TARGET:-}"
    local source=${PENDING_OLD_BOOT_ID^^} target=${PENDING_TARGET_BOOT_ID^^} original=${PENDING_ORIGINAL_BOOT_ORDER^^}
    local fallback='' baseline_path baseline current current_order expected='' id line base_path current_path
    local orig_bbs='' cur_bbs='' missing='' added='' current_stable='' final=0
    local -a original_ids=() current_ids=()

    LEAP16_ORDER_REASON=''
    LEAP16_ORDER_CURRENT_FULL=''
    LEAP16_ORDER_EXPECTED_STABLE=''
    LEAP16_ORDER_CURRENT_STABLE=''
    LEAP16_ORDER_BBS_ORIGINAL=''
    LEAP16_ORDER_BBS_CURRENT=''
    LEAP16_ORDER_BBS_MISSING=''
    LEAP16_ORDER_BBS_ADDED=''

    [[ $source =~ ^[0-9A-F]{4}$ && $target =~ ^[0-9A-F]{4}$ && -n $original ]] \
        || { LEAP16_ORDER_REASON='direct-edge transaction identity is incomplete'; return 1; }
    baseline_path=$(leap16_pending_firmware_baseline_path 2>/dev/null || true)
    [[ -n $baseline_path ]] && leap16_r60_valid_efibootmgr_dump "$baseline_path" \
        || { LEAP16_ORDER_REASON='direct-edge firmware baseline is unavailable'; return 1; }
    baseline=$(cat -- "$baseline_path" 2>/dev/null || true)
    current=$(efibootmgr -v 2>/dev/null || true)
    current_order=$(awk -F': ' '/^BootOrder:/ {print toupper($2); exit}' <<<"$current")
    [[ -n $current_order ]] || { LEAP16_ORDER_REASON='current BootOrder is unreadable'; return 1; }
    LEAP16_ORDER_CURRENT_FULL=$current_order
    fallback=$(leap16_r60_direct_edge_fallback_id 2>/dev/null || true)

    case "$direction:$phase" in
        limine:systemd-boot:runtime-pass-systemd-from-limine)
            [[ $fallback =~ ^[0-9A-F]{4}$ ]] || { LEAP16_ORDER_REASON='Limine source fallback identity is unavailable'; return 1; }
            expected="$source,$fallback,$target"
            ;;
        limine:systemd-boot:finalized-systemd-from-limine|limine:systemd-boot:auto-resume-pass)
            expected=$target; final=1
            ;;
        systemd-boot:limine:runtime-pass-limine-from-systemd)
            expected="$source,$target"
            [[ $fallback =~ ^[0-9A-F]{4}$ ]] && expected="$expected,$fallback"
            ;;
        systemd-boot:limine:fallback-armed-limine-from-systemd|systemd-boot:limine:fallback-runtime-pass-limine-from-systemd)
            [[ $fallback =~ ^[0-9A-F]{4}$ ]] || { LEAP16_ORDER_REASON='Limine fallback identity is unavailable'; return 1; }
            expected="$target,$fallback,$source"
            ;;
        systemd-boot:limine:finalized-limine-from-systemd|systemd-boot:limine:auto-resume-pass)
            [[ $fallback =~ ^[0-9A-F]{4}$ ]] || { LEAP16_ORDER_REASON='Final Limine fallback identity is unavailable'; return 1; }
            expected="$target,$fallback"; final=1
            ;;
        *) LEAP16_ORDER_REASON='not a direct Limine/systemd diagnostic phase'; return 2 ;;
    esac

    IFS=',' read -ra original_ids <<<"$original"
    for id in "${original_ids[@]}"; do
        id=${id^^}; [[ -n $id ]] || continue
        line=$(leap16_line_for_id_in_dump "$baseline" "$id")
        [[ -n $line ]] || { LEAP16_ORDER_REASON="original Boot$id is missing from the direct-edge baseline"; return 1; }
        if leap16_line_is_bbs "$line"; then
            orig_bbs=$(leap16_r60_csv_append_unique "$orig_bbs" "$id")
            continue
        fi
        if [[ $final == 1 && ( $id == "$source" || $id == "$fallback" ) ]]; then continue; fi
        case ",$expected," in *",$id,"*) continue ;; esac
        current_path=$(efi_path_from_efibootmgr_line "$(leap16_line_for_id_in_dump "$current" "$id")" 2>/dev/null || true)
        base_path=$(efi_path_from_efibootmgr_line "$line" 2>/dev/null || true)
        [[ -n $current_path && -n $base_path \
           && $(normalize_efi_path "$current_path" | tr '[:upper:]' '[:lower:]') == $(normalize_efi_path "$base_path" | tr '[:upper:]' '[:lower:]') ]] \
            || { LEAP16_ORDER_REASON="original EFI-file Boot$id changed or disappeared"; return 1; }
        expected=$(leap16_r60_csv_append_unique "$expected" "$id")
    done

    leap16_r60_line_path_matches "$current" "$target" "$PENDING_TARGET_EFI_PATH" \
        || { LEAP16_ORDER_REASON="target Boot$target changed EFI path"; return 1; }
    if [[ $expected == "$source"* || $expected == *",$source"* ]]; then
        leap16_r60_line_path_matches "$current" "$source" "$PENDING_OLD_BOOT_EFI_PATH" \
            || { LEAP16_ORDER_REASON="source recovery Boot$source changed EFI path"; return 1; }
    elif [[ $final == 1 ]] && boot_id_exists "$source"; then
        LEAP16_ORDER_REASON="retired source Boot$source still exists"
        return 1
    fi
    if [[ $fallback =~ ^[0-9A-F]{4}$ ]]; then
        if [[ $expected == "$fallback"* || $expected == *",$fallback"* ]]; then
            leap16_r60_line_path_matches "$current" "$fallback" "$LEAP16_R21_FALLBACK_EFI_PATH" \
                || { LEAP16_ORDER_REASON="fallback Boot$fallback changed EFI path"; return 1; }
        elif [[ $final == 1 && $direction == limine:systemd-boot ]] && boot_id_exists "$fallback"; then
            LEAP16_ORDER_REASON="retired Limine fallback Boot$fallback still exists"
            return 1
        fi
    fi

    IFS=',' read -ra current_ids <<<"$current_order"
    for id in "${current_ids[@]}"; do
        id=${id^^}; [[ -n $id ]] || continue
        line=$(leap16_line_for_id_in_dump "$current" "$id")
        [[ -n $line ]] || { LEAP16_ORDER_REASON="BootOrder references missing Boot$id"; return 1; }
        if leap16_line_is_bbs "$line"; then
            cur_bbs=$(leap16_r60_csv_append_unique "$cur_bbs" "$id")
        else
            current_stable=$(leap16_r60_csv_append_unique "$current_stable" "$id")
        fi
    done
    IFS=',' read -ra _r60_csv_items <<<"$orig_bbs"
    for id in "${_r60_csv_items[@]}"; do [[ -n $id ]] && ! leap16_order_has_id "$cur_bbs" "$id" && missing=$(leap16_r60_csv_append_unique "$missing" "$id"); done
    IFS=',' read -ra _r60_csv_items <<<"$cur_bbs"
    for id in "${_r60_csv_items[@]}"; do [[ -n $id ]] && ! leap16_order_has_id "$orig_bbs" "$id" && added=$(leap16_r60_csv_append_unique "$added" "$id"); done

    LEAP16_ORDER_EXPECTED_STABLE=$expected
    LEAP16_ORDER_CURRENT_STABLE=$current_stable
    LEAP16_ORDER_BBS_ORIGINAL=$orig_bbs
    LEAP16_ORDER_BBS_CURRENT=$cur_bbs
    LEAP16_ORDER_BBS_MISSING=$missing
    LEAP16_ORDER_BBS_ADDED=$added
    [[ $current_stable == "$expected" ]] \
        || { LEAP16_ORDER_REASON="direct-edge stable EFI-file BootOrder drifted (expected $expected, got ${current_stable:-empty})"; return 1; }
    LEAP16_ORDER_REASON="$direction $phase stable EFI-file topology matches; BBS entries are firmware-owned churn only"
    return 0
}

eval "$(declare -f leap16_write_firmware_order_report | sed '1s/leap16_write_firmware_order_report/leap16_write_firmware_order_report_pre_leap16_r60/')"

leap16_write_firmware_order_report() {
    local out=$1 phase=${2:-snapshot} rc=0
    case "${PENDING_SOURCE:-}:${PENDING_TARGET:-}:$phase" in
        limine:systemd-boot:runtime-pass-systemd-from-limine|\
        limine:systemd-boot:finalized-systemd-from-limine|\
        limine:systemd-boot:auto-resume-pass|\
        systemd-boot:limine:runtime-pass-limine-from-systemd|\
        systemd-boot:limine:fallback-armed-limine-from-systemd|\
        systemd-boot:limine:fallback-runtime-pass-limine-from-systemd|\
        systemd-boot:limine:finalized-limine-from-systemd|\
        systemd-boot:limine:auto-resume-pass)
            leap16_r60_assess_direct_edge_order "$phase" || rc=$?
            [[ $rc == 2 ]] && { leap16_write_firmware_order_report_pre_leap16_r60 "$@"; return $?; }
            leap16_emit_firmware_order_report "$out" "$([[ $rc == 0 ]] && printf 0 || printf 1)"
            return 0
            ;;
    esac
    leap16_write_firmware_order_report_pre_leap16_r60 "$@"
}

eval "$(declare -f r13_sync_root_diagnostics_to_user | sed '1s/r13_sync_root_diagnostics_to_user/r13_sync_root_diagnostics_to_user_pre_leap16_r60/')"

# A reboot terminates the PTY parent before r46 can sanitize its typescript.
# Complete that report-only housekeeping from the root resume sync instead.
r13_sync_root_diagnostics_to_user() {
    local conf=$1 bundle=$2 status=${3:-resume} rc=0 diag dest uid gid real_dest real_diag raw log tmp now
    r13_sync_root_diagnostics_to_user_pre_leap16_r60 "$@" || rc=$?
    [[ -f $bundle/$LEAP16_R44_DIAG_POINTER ]] || return "$rc"
    diag=$(head -n1 -- "$bundle/$LEAP16_R44_DIAG_POINTER" 2>/dev/null || true)
    dest=$(r22_conf_value "$conf" user_diagnostic_root)
    uid=$(r22_conf_value "$conf" user_uid); gid=$(r22_conf_value "$conf" user_gid)
    [[ -n $diag && -n $dest && $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ ]] || return "$rc"
    real_dest=$(r22_realpath_m "$dest"); real_diag=$(r22_realpath_m "$diag")
    [[ $real_diag == "$real_dest/"* && $real_diag != "$real_dest" && -d $diag && ! -L $diag ]] || return "$rc"

    raw="$diag/.stage.typescript.raw"; log="$diag/stage.log"
    if [[ -s $raw && ! -L $raw ]]; then
        tmp=$(mktemp -- "$diag/.stage.log.XXXXXX") || tmp=''
        if [[ -n $tmp ]] && leap16_r46_sanitize_typescript "$raw" "$tmp"; then
            chmod 600 -- "$tmp" 2>/dev/null || true
            chown "$uid:$gid" "$tmp" 2>/dev/null || true
            mv -f -- "$tmp" "$log" && rm -f -- "$raw"
        else
            [[ -n $tmp ]] && rm -f -- "$tmp"
        fi
    fi
    if [[ -f $diag/transaction.conf ]] && ! grep -Eq '^stage_(exit|completion)=' "$diag/transaction.conf"; then
        now=$(date --iso-8601=seconds 2>/dev/null || date)
        printf 'stage_completion=automatic-reboot-handoff\nstage_finished_at=%s\n' "$now" >>"$diag/transaction.conf" 2>/dev/null || true
        chown "$uid:$gid" "$diag/transaction.conf" 2>/dev/null || true
        chmod 600 -- "$diag/transaction.conf" 2>/dev/null || true
    fi
    return "$rc"
}
