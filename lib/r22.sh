#!/usr/bin/env bash

# r22 automation layer
# --------------------
# r21 proved the transaction model, but required the user to babysit every
# state transition. r22 keeps the same validation/finalization gates and moves
# the post-reboot continuation into a temporary root-owned one-shot systemd
# service.
#
# Safety properties:
#   * the normal user still authorizes the migration before any writes;
#   * the source stays first in persistent BootOrder until runtime proof;
#   * BootNext is used only once for the test boot;
#   * the resume service executes a root-owned copy of this tool and a
#     root-owned copy of the transaction state (never user-writable code/state);
#   * runtime validation must pass before unattended FINALIZE is permitted;
#   * if firmware falls back to the source, the transaction returns to
#     candidate-ready and no source cleanup is attempted;
#   * the temporary service removes/disables itself after success or a safe
#     failure. The user's original transaction state is synchronized so manual
#     recovery remains possible when automation cannot complete.

R22_SYSTEM_ROOT=/var/lib/cachyos-bootloader-switcher/r22
R22_SERVICE_NAME=cachyos-bootloader-switcher-resume.service
R22_SERVICE_PATH=/etc/systemd/system/$R22_SERVICE_NAME
R22_RESULT_FILE_NAME=last-auto-result.txt
R22_BUNDLE_MARKER=.r22-root-owned-resume-bundle

r22_realpath_m() {
    realpath -m -- "$1" 2>/dev/null || printf '%s\n' "$1"
}

r22_default_user_state_dir() {
    printf '%s/.local/state/cachyos-bootloader-switcher\n' "$HOME"
}

r22_user_state_is_safe_for_automation() {
    local state expected home_real state_real
    state=${PENDING_STATE_DIR:-}
    expected=$(r22_default_user_state_dir)
    home_real=$(r22_realpath_m "$HOME")
    state_real=$(r22_realpath_m "$state")
    [[ -n $state && $state_real == $(r22_realpath_m "$expected") ]] || return 1
    [[ $state_real == "$home_real/"* ]] || return 1
    return 0
}

r22_safe_bundle_path() {
    local p=${1:-} root_real p_real
    [[ -n $p ]] || return 1
    root_real=$(r22_realpath_m "$R22_SYSTEM_ROOT")
    p_real=$(r22_realpath_m "$p")
    [[ $p_real == "$root_real/"* && $p_real != "$root_real" ]]
}

r22_state_value() {
    local file=$1 key=$2
    awk -F'\t' -v k="$key" '$1==k {print $2; exit}' "$file" 2>/dev/null
}

r22_write_external_phase() {
    local file=$1 phase=$2 tmp found=0 key value owner group
    [[ -f $file ]] || return 1
    tmp=$(mktemp) || return 1
    while IFS=$'\t' read -r key value; do
        if [[ $key == phase ]]; then
            printf 'phase\t%s\n' "$phase" >>"$tmp" || { rm -f -- "$tmp"; return 1; }
            found=1
        else
            printf '%s\t%s\n' "$key" "$value" >>"$tmp" || { rm -f -- "$tmp"; return 1; }
        fi
    done <"$file"
    ((found)) || { rm -f -- "$tmp"; return 1; }
    owner=$(stat -c '%u' -- "$file" 2>/dev/null || true)
    group=$(stat -c '%g' -- "$file" 2>/dev/null || true)
    install -m 0600 -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
    [[ $owner =~ ^[0-9]+$ && $group =~ ^[0-9]+$ ]] && chown "$owner:$group" -- "$file" 2>/dev/null || true
}

r22_rebase_state_snapshot_paths() {
    local in=$1 out=$2 old=$3 new=$4 key value
    : >"$out" || return 1
    while IFS=$'\t' read -r key value; do
        if [[ $value == "$old" || $value == "$old/"* ]]; then
            value="$new${value#"$old"}"
        fi
        printf '%s\t%s\n' "$key" "$value" >>"$out" || return 1
    done <"$in"
}

r22_write_resume_conf() {
    local out=$1 bundle=$2 user_state=$3 user_snapshot=$4 uid=$5 gid=$6 user_home=$7
    {
        printf 'bundle\t%s\n' "$bundle"
        printf 'user_state_file\t%s\n' "$user_state"
        printf 'user_snapshot_dir\t%s\n' "$user_snapshot"
        printf 'user_uid\t%s\n' "$uid"
        printf 'user_gid\t%s\n' "$gid"
        printf 'user_home\t%s\n' "$user_home"
        printf 'created\t%s\n' "$PENDING_CREATED"
        printf 'machine_id\t%s\n' "$PENDING_MACHINE_ID"
        printf 'source\t%s\n' "$PENDING_SOURCE"
        printf 'target\t%s\n' "$PENDING_TARGET"
        printf 'old_boot_id\t%s\n' "$PENDING_OLD_BOOT_ID"
        printf 'target_boot_id\t%s\n' "$PENDING_TARGET_BOOT_ID"
    } >"$out"
}

r22_conf_value() {
    local file=$1 key=$2
    awk -F'\t' -v k="$key" '$1==k {print $2; exit}' "$file" 2>/dev/null
}

r22_write_systemd_unit() {
    local out=$1 bundle=$2 state_dir=$3
    cat >"$out" <<EOF_UNIT
[Unit]
Description=CachyOS Bootloader Switcher transaction resume
After=local-fs.target
ConditionPathExists=$state_dir/pending-migration.tsv

[Service]
Type=oneshot
Environment=BOOTLOADER_SWITCHER_STATE_DIR=$state_dir
Environment=R22_RESUME_BUNDLE=$bundle
Environment=HOME=$bundle/runtime-home
Environment=R22_AUTO_FINALIZE=1
ExecStart=/usr/bin/bash $bundle/tool/bootloader-switcher.sh --resume-transaction-root
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF_UNIT
}

r22_remove_resume_service_files() {
    # Root-only helper. Do not fail the already-completed boot transaction just
    # because service housekeeping has a problem.
    systemctl disable "$R22_SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f -- "$R22_SERVICE_PATH" >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
}

r22_prepare_resume_bundle() {
    r22_user_state_is_safe_for_automation || {
        fail 'Automatic post-reboot resume is available only with the default per-user state directory'
        return 1
    }
    have systemctl || { fail 'systemctl is unavailable; cannot install the temporary resume service'; return 1; }
    [[ -n ${SCRIPT_DIR:-} && -d $SCRIPT_DIR ]] || { fail 'Tool source directory is unavailable for the root-owned resume bundle'; return 1; }
    [[ -f $PENDING_STATE_FILE && -d $PENDING_TRANSACTION_SNAPSHOT_DIR ]] || { fail 'Pending transaction state/snapshot is incomplete'; return 1; }

    # Never trample a previous root resume transaction. A stale unit/bundle is
    # something the user should see and inspect, not something we silently
    # replace with root privileges.
    if sudo -n test -e "$R22_SERVICE_PATH" 2>/dev/null; then
        fail "A previous temporary resume service still exists: $R22_SERVICE_PATH"
        return 1
    fi

    local stamp bundle tmp state_tmp snap_base root_snap uid gid user_state user_snapshot unit_tmp
    stamp=$(date +%Y%m%d-%H%M%S)
    bundle="$R22_SYSTEM_ROOT/${PENDING_MACHINE_ID}-${stamp}-Boot${PENDING_TARGET_BOOT_ID}"
    r22_safe_bundle_path "$bundle" || { fail 'Generated resume bundle path failed safety validation'; return 1; }
    tmp=$(mktemp -d) || return 1
    mkdir -p "$tmp/tool" "$tmp/state" "$tmp/runtime-home" || return 1
    cp -a -- "$SCRIPT_DIR/." "$tmp/tool/" || return 1

    snap_base=$(basename -- "$PENDING_TRANSACTION_SNAPSHOT_DIR")
    [[ $snap_base == .prestage.* ]] || { fail 'Transaction snapshot basename is not recognized'; return 1; }
    cp -a -- "$PENDING_TRANSACTION_SNAPSHOT_DIR" "$tmp/state/$snap_base" || return 1
    root_snap="$bundle/state/$snap_base"
    r22_rebase_state_snapshot_paths "$PENDING_STATE_FILE" "$tmp/state/pending-migration.tsv" "$PENDING_TRANSACTION_SNAPSHOT_DIR" "$root_snap" || return 1

    uid=$(id -u)
    gid=$(id -g)
    user_state=$PENDING_STATE_FILE
    user_snapshot=$PENDING_TRANSACTION_SNAPSHOT_DIR
    r22_write_resume_conf "$tmp/resume.conf" "$bundle" "$user_state" "$user_snapshot" "$uid" "$gid" "$HOME" || return 1
    printf 'r22\n' >"$tmp/$R22_BUNDLE_MARKER" || return 1
    unit_tmp="$tmp/$R22_SERVICE_NAME"
    r22_write_systemd_unit "$unit_tmp" "$bundle" "$bundle/state" || return 1

    sudo install -d -o root -g root -m 0700 -- "$R22_SYSTEM_ROOT" "$bundle" || return 1
    sudo cp -a -- "$tmp/tool" "$tmp/state" "$tmp/runtime-home" "$tmp/resume.conf" "$tmp/$R22_BUNDLE_MARKER" "$bundle/" || return 1
    sudo chown -R root:root -- "$bundle" || return 1
    sudo chmod 0700 -- "$bundle" "$bundle/tool" "$bundle/state" "$bundle/runtime-home" || return 1
    sudo find "$bundle" -type d -exec chmod go-w {} + || return 1
    sudo find "$bundle" -type f -exec chmod go-w {} + || return 1
    sudo chmod 0755 -- "$bundle/tool/bootloader-switcher.sh" || return 1
    sudo install -o root -g root -m 0644 -- "$unit_tmp" "$R22_SERVICE_PATH" || return 1
    sudo systemctl daemon-reload || return 1
    sudo systemctl enable "$R22_SERVICE_NAME" >/dev/null || return 1

    # A small user-owned pointer is informational only; the root service never
    # trusts it. It helps the interactive tool explain what is armed.
    printf '%s\n' "$bundle" >"$PENDING_STATE_DIR/r22-resume-bundle.path" || true
    chmod 600 -- "$PENDING_STATE_DIR/r22-resume-bundle.path" 2>/dev/null || true
    rm -rf -- "$tmp" 2>/dev/null || true
    ok 'Installed temporary root-owned resume service for the next boot'
    return 0
}

r22_rollback_automation_arm() {
    local next
    next=$(pending_bootnext_id)
    if [[ $next == "$PENDING_TARGET_BOOT_ID" ]]; then
        sudo efibootmgr -N >/dev/null 2>&1 || true
    fi
    pending_set_phase candidate-ready >/dev/null 2>&1 || true
    sudo systemctl disable "$R22_SERVICE_NAME" >/dev/null 2>&1 || true
    sudo rm -f -- "$R22_SERVICE_PATH" >/dev/null 2>&1 || true
    sudo systemctl daemon-reload >/dev/null 2>&1 || true
}


r22_disarm_user_resume_bundle() {
    local pointer="$PENDING_STATE_DIR/r22-resume-bundle.path" bundle
    [[ -f $pointer ]] || return 0
    bundle=$(head -n1 -- "$pointer" 2>/dev/null || true)
    if r22_safe_bundle_path "$bundle"; then
        sudo systemctl disable "$R22_SERVICE_NAME" >/dev/null 2>&1 || true
        sudo rm -f -- "$R22_SERVICE_PATH" >/dev/null 2>&1 || true
        sudo systemctl daemon-reload >/dev/null 2>&1 || true
        sudo rm -rf -- "$bundle" >/dev/null 2>&1 || true
    fi
    rm -f -- "$pointer" 2>/dev/null || true
}

# Keep r21's manual cancellation/rollback behavior, but make sure a deferred
# r22 automatic-resume service cannot survive after the user cancels it.
eval "$(declare -f cancel_pending_one_time_boot | sed '1s/cancel_pending_one_time_boot/cancel_pending_one_time_boot_r21/')"
cancel_pending_one_time_boot() {
    cancel_pending_one_time_boot_r21 "$@" || return $?
    r22_disarm_user_resume_bundle
}

eval "$(declare -f rollback_pending_candidate | sed '1s/rollback_pending_candidate/rollback_pending_candidate_r21/')"
rollback_pending_candidate() {
    rollback_pending_candidate_r21 "$@" || return $?
    r22_disarm_user_resume_bundle
}

r22_arm_candidate_automatically() {
    validate_pending_compatibility || { fail "Pending migration is not compatible: $PENDING_REASON"; return 1; }
    [[ $PENDING_SOURCE == limine && $PENDING_TARGET == grub && $PENDING_PHASE == candidate-ready ]] || {
        fail 'Automatic arming currently supports only candidate-ready Limine -> GRUB transactions'
        return 1
    }
    detect_bootloader
    [[ $BOOTLOADER == "$PENDING_SOURCE" && $BOOT_CURRENT == "$PENDING_OLD_BOOT_ID" ]] || {
        fail 'Automatic arming requires the recorded source Limine session to be active'
        return 1
    }
    run_validation preflight || return 1
    verify_pending_source_recovery_unchanged || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext is already owned by another request'; return 1; }
    [[ $(pending_bootorder_first) == "$PENDING_OLD_BOOT_ID" ]] || { fail 'Persistent BootOrder is no longer source-first'; return 1; }
    nvram_id_matches_path "$PENDING_TARGET_BOOT_ID" "$PENDING_TARGET_EFI_PATH" || { fail 'Target NVRAM path changed before automatic arming'; return 1; }

    sudo efibootmgr -n "$PENDING_TARGET_BOOT_ID" >/dev/null || return 1
    [[ $(pending_bootnext_id) == "$PENDING_TARGET_BOOT_ID" ]] || {
        sudo efibootmgr -N >/dev/null 2>&1 || true
        fail 'BootNext verification failed during automatic arming'
        return 1
    }
    if ! pending_set_phase boot-armed; then
        sudo efibootmgr -N >/dev/null 2>&1 || true
        fail 'Could not persist boot-armed phase; BootNext was cleared'
        return 1
    fi
    PENDING_PHASE=boot-armed
    ok "Armed one-time GRUB test as BootNext=Boot$PENDING_TARGET_BOOT_ID"
    ok "Persistent BootOrder remains source Limine Boot$PENDING_OLD_BOOT_ID first until runtime proof"
}

r22_prompt_reboot() {
    local answer
    printf '\nThe one-time GRUB test is armed and the switcher will resume automatically after reboot.\n'
    printf 'If runtime validation passes, the switcher will finalize GRUB automatically and retire only ownership-proven Limine state.\n'
    read -r -p 'Reboot now? [y/N]: ' answer
    case "$answer" in
        y|Y|yes|YES)
            printf 'Rebooting now. No firmware-menu selection is required.\n'
            sudo systemctl reboot
            ;;
        *)
            printf 'Reboot deferred. BootNext and the temporary resume service remain armed for your next normal reboot.\n'
            ;;
    esac
}

r22_after_fresh_limine_to_grub_candidate() {
    # execute_limine_to_grub has just persisted candidate-ready while Limine is
    # still the active source. Record the already-present CachyOS theme as part
    # of the transaction, then arm and hand off post-reboot work automatically.
    load_pending_state || { fail "Could not reload the newly staged transaction: $PENDING_REASON"; return 1; }
    validate_pending_compatibility || return 1
    if ! r21_theme_required; then
        r21_refresh_grub_theme_candidate_metadata || return 1
        load_pending_state || return 1
        PENDING_PHASE=candidate-ready
    fi
    verify_pending_candidate_ownership_unchanged || return 1

    r22_arm_candidate_automatically || return 1
    if ! r22_prepare_resume_bundle; then
        fail 'Could not prepare automatic post-reboot continuation. Clearing the one-time boot for safety.'
        r22_rollback_automation_arm
        return 1
    fi
    r22_prompt_reboot
}

r22_user_shadow_matches_conf() {
    local conf=$1 state expected
    state=$(r22_conf_value "$conf" user_state_file)
    [[ -f $state ]] || return 1
    for expected in created machine_id source target old_boot_id target_boot_id; do
        [[ $(r22_state_value "$state" "$expected") == $(r22_conf_value "$conf" "$expected") ]] || return 1
    done
    return 0
}

r22_write_user_result() {
    local conf=$1 status=$2 detail=$3 state_file state_dir uid gid out tmp
    state_file=$(r22_conf_value "$conf" user_state_file)
    state_dir=$(dirname -- "$state_file")
    uid=$(r22_conf_value "$conf" user_uid)
    gid=$(r22_conf_value "$conf" user_gid)
    mkdir -p -- "$state_dir" || return 1
    out="$state_dir/$R22_RESULT_FILE_NAME"
    tmp=$(mktemp) || return 1
    {
        printf 'status=%s\n' "$status"
        printf 'time=%s\n' "$(date -Is)"
        printf 'detail=%s\n' "$detail"
    } >"$tmp"
    install -m 0600 -- "$tmp" "$out" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
    [[ $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ ]] && chown "$uid:$gid" -- "$out" 2>/dev/null || true
}

r22_sync_user_phase_from_root() {
    local conf=$1 phase=$2 state
    state=$(r22_conf_value "$conf" user_state_file)
    r22_user_shadow_matches_conf "$conf" || return 1
    r22_write_external_phase "$state" "$phase"
}

r22_cleanup_user_shadow_after_success() {
    local conf=$1 state snapshot state_dir uid gid
    state=$(r22_conf_value "$conf" user_state_file)
    snapshot=$(r22_conf_value "$conf" user_snapshot_dir)
    state_dir=$(dirname -- "$state")
    uid=$(r22_conf_value "$conf" user_uid)
    gid=$(r22_conf_value "$conf" user_gid)

    if r22_user_shadow_matches_conf "$conf"; then
        [[ $(r22_realpath_m "$snapshot") == $(r22_realpath_m "$state_dir")/.prestage.* ]] && rm -rf -- "$snapshot" 2>/dev/null || true
        rm -f -- "$state" "$state_dir/r22-resume-bundle.path" 2>/dev/null || true
    fi
    mkdir -p -- "$state_dir" 2>/dev/null || true
    [[ $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ ]] && chown "$uid:$gid" -- "$state_dir" 2>/dev/null || true
}

r22_root_bundle_preflight() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'Internal automatic resume requires root.\n' >&2; return 1; }
    local bundle=${R22_RESUME_BUNDLE:-} marker conf owner
    r22_safe_bundle_path "$bundle" || { printf 'Invalid automatic-resume bundle path.\n' >&2; return 1; }
    marker="$bundle/$R22_BUNDLE_MARKER"
    conf="$bundle/resume.conf"
    [[ -f $marker && -f $conf && -f $bundle/state/pending-migration.tsv ]] || { printf 'Incomplete automatic-resume bundle.\n' >&2; return 1; }
    owner=$(stat -c '%u' -- "$bundle" 2>/dev/null || true)
    [[ $owner == 0 ]] || { printf 'Automatic-resume bundle is not root-owned.\n' >&2; return 1; }
    [[ $(r22_conf_value "$conf" bundle) == "$bundle" ]] || { printf 'Automatic-resume bundle identity mismatch.\n' >&2; return 1; }
    return 0
}

r22_resume_source_fallback() {
    local conf=$1 next
    printf 'Automatic resume: source bootloader is active after the one-time test request; target runtime proof was not obtained.\n'
    next=$(pending_bootnext_id)
    if [[ $next == "$PENDING_TARGET_BOOT_ID" ]]; then
        printf 'Automatic resume: firmware left the transaction BootNext behind; clearing only Boot%s.\n' "$next"
        efibootmgr -N >/dev/null || return 1
    elif [[ -n $next ]]; then
        printf 'Automatic resume: unrelated BootNext=Boot%s exists; leaving it untouched and refusing state reset.\n' "$next" >&2
        return 1
    fi
    reset_consumed_test_to_candidate_ready || return 1
    r22_sync_user_phase_from_root "$conf" candidate-ready || true
    r22_write_user_result "$conf" safe-fallback "The one-time $(bootloader_display_name "$PENDING_TARGET") target did not obtain runtime proof; $(bootloader_display_name "$PENDING_SOURCE") remained the source and the candidate was returned to candidate-ready." || true
    r22_remove_resume_service_files
    return 0
}

r22_resume_transaction_root() {
    r22_root_bundle_preflight || return 1
    local bundle=$R22_RESUME_BUNDLE conf="$R22_RESUME_BUNDLE/resume.conf" rc=0
    printf 'CachyOS Bootloader Switcher automatic transaction resume\n'
    printf 'Bundle: %s\n' "$bundle"

    load_pending_state || { printf 'Automatic resume: root-owned pending state is invalid: %s\n' "$PENDING_REASON" >&2; rc=1; }
    ((rc == 0)) && validate_pending_compatibility || rc=1
    if ((rc != 0)); then
        r22_write_user_result "$conf" failed 'The root-owned resume transaction failed compatibility validation; no source cleanup was attempted.' || true
        r22_remove_resume_service_files
        return 1
    fi

    detect_bootloader
    if [[ $BOOTLOADER == "$PENDING_SOURCE" && $BOOT_CURRENT == "$PENDING_OLD_BOOT_ID" ]]; then
        r22_resume_source_fallback "$conf"
        return $?
    fi

    if [[ $BOOTLOADER != "$PENDING_TARGET" || $BOOT_CURRENT != "$PENDING_TARGET_BOOT_ID" ]]; then
        printf 'Automatic resume: neither recorded source nor target is the current EFI boot. Refusing automation.\n' >&2
        r22_write_user_result "$conf" failed 'Automatic resume saw an unexpected BootCurrent/bootloader identity and refused to modify source state.' || true
        r22_remove_resume_service_files
        return 1
    fi

    case "$PENDING_PHASE" in
        boot-armed)
            if ! validate_pending_target_runtime; then
                r22_write_user_result "$conf" failed 'The automatically booted GRUB target failed runtime validation; FINALIZE was not attempted.' || true
                r22_remove_resume_service_files
                return 1
            fi
            PENDING_PHASE=runtime-validated
            r22_sync_user_phase_from_root "$conf" runtime-validated || true
            ;;
        runtime-validated)
            printf 'Automatic resume: runtime proof was already persisted in the root-owned transaction; continuing to finalization.\n'
            ;;
        *)
            printf 'Automatic resume: unexpected target phase %s; refusing unattended finalization.\n' "$PENDING_PHASE" >&2
            r22_write_user_result "$conf" failed "Unexpected automatic-resume phase: $PENDING_PHASE" || true
            r22_remove_resume_service_files
            return 1
            ;;
    esac

    # r21's finalizer still performs every ownership/runtime/deep validation
    # again. R22_AUTO_FINALIZE only skips the redundant interactive word prompt
    # because the user already approved this resumable transaction pre-reboot.
    if ! R22_AUTO_FINALIZE=1 r21_finalize_limine_to_grub; then
        r22_write_user_result "$conf" failed 'Runtime proof passed, but ownership-gated automatic finalization failed. Inspect diagnostics; the resume service was disabled to prevent repeated writes.' || true
        r22_remove_resume_service_files
        return 1
    fi

    r22_cleanup_user_shadow_after_success "$conf"
    r22_write_user_result "$conf" success "Limine -> GRUB finalized automatically. GRUB Boot$PENDING_TARGET_BOOT_ID is first in persistent BootOrder and ownership-proven Limine firmware/config state was retired." || true
    r22_remove_resume_service_files
    rm -rf -- "$bundle" 2>/dev/null || true
    return 0
}

r22_show_last_auto_result() {
    local f="$PENDING_STATE_DIR/$R22_RESULT_FILE_NAME"
    [[ -f $f ]] || return 0
    printf 'Last automated transaction result:\n'
    sed 's/^/  /' "$f" 2>/dev/null || true
    printf '\n'
}
