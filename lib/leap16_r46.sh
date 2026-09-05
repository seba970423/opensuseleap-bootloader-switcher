#!/usr/bin/env bash
# leap16-r46: record interactive transaction output through a real PTY instead
# of asynchronously replaying a pipe into the user's terminal.
#
# r44/r45 used stdout/stderr -> process substitution -> tee.  That captures a
# good stage.log, but sudo/system helpers may still write directly to /dev/tty.
# Those direct TTY writes can race the asynchronous tee replay and leave Konsole
# at a surprising cursor column even when the logged stream itself is clean.
# r46 keeps the live transaction terminal-native by running the exact operation
# under util-linux script(1).  script owns one PTY stream, so stdout/stderr and
# /dev/tty writers are serialized by the PTY just as they are without logging.
# The raw typescript is sanitized only after the operation finishes; stage.log
# is diagnostics, never part of boot-state decisions.

leap16_r46_sanitize_typescript() {
    local raw=$1 out=$2
    # Turn PTY CRLF/progress returns into line-oriented text, strip common ANSI
    # CSI controls, and remove script(1)'s own header/trailer metadata.
    tr '\r' '\n' <"$raw" \
        | sed -u -E $'s#\x1B\\[[0-?]*[ -/]*[@-~]##g' \
        | sed -E '/^Script started on .*\[COMMAND=/d; /^Script done on .*\[COMMAND_EXIT_CODE=/d' \
        >"$out"
}

leap16_r46_build_shell_command() {
    local __outvar=$1; shift
    local q='' arg
    for arg in "$@"; do
        printf -v arg '%q' "$arg"
        q+="${q:+ }$arg"
    done
    printf -v "$__outvar" '%s' "$q"
}

# Internal child action.  It is intentionally restricted to the three r44
# systemd-edge operation entry points used by the transcript wrapper.
leap16_r46_transcript_child() {
    local diag=${1:-} expected_current=${2:-} target=${3:-} kind=${4:-} command=${5:-}
    shift 5 || true

    [[ -n $diag && -d $diag && ! -L $diag ]] || { printf '[FAIL] Invalid r46 transaction diagnostics directory\n' >&2; return 2; }
    case "$command" in
        leap16_r44_run_systemd_edge_inner|leap16_r44_restore_grub_backup_from_systemd|leap16_r44_restore_systemd_backup) ;;
        *) printf '[FAIL] Refusing unknown r46 transcript child command: %s\n' "$command" >&2; return 2 ;;
    esac
    declare -F "$command" >/dev/null 2>&1 || { printf '[FAIL] r46 transcript child command is unavailable: %s\n' "$command" >&2; return 2; }

    LEAP16_R44_TRANSACTION_DIAG_DIR=$diag
    detect_bootloader
    if [[ $BOOTLOADER != "$expected_current" ]]; then
        printf '[FAIL] Bootloader changed before transcript child start: expected %s, detected %s\n' "$expected_current" "$BOOTLOADER" >&2
        return 1
    fi

    "$command" "$@"
}

# Replace r45's asynchronous tee wrapper.  The operation itself runs in a child
# instance of this same release under script(1)'s pseudo-terminal.  This keeps
# helpers that use /dev/tty in the same ordered PTY stream as normal stdout and
# stderr, while still producing one complete transaction transcript.
leap16_r44_with_transaction_transcript() {
    local current=$1 target=$2 kind=$3 command=$4 rc=0 log raw child_cmd
    shift 4
    leap16_r44_diag_begin "$current" "$target" "$kind" || {
        warn 'Could not create the full transaction transcript directory; normal checkpoint diagnostics remain available'
        "$command" "$@"
        return $?
    }

    log="$LEAP16_R44_TRANSACTION_DIAG_DIR/stage.log"
    raw="$LEAP16_R44_TRANSACTION_DIAG_DIR/.stage.typescript.raw"

    if ! command -v script >/dev/null 2>&1; then
        warn 'util-linux script(1) is unavailable; running with native terminal output and reduced stage transcript rather than risking tee-induced terminal corruption'
        "$command" "$@" || rc=$?
        printf '[r46] Full PTY stage transcript unavailable: script(1) not installed.\n' >"$log"
    else
        leap16_r46_build_shell_command child_cmd \
            "$SCRIPT_DIR/bootloader-switcher.sh" \
            --r46-transcript-child \
            "$LEAP16_R44_TRANSACTION_DIAG_DIR" "$current" "$target" "$kind" "$command" "$@"
        # -q: no start/stop chatter on the live terminal
        # -e: return the exact child command status
        # -f: flush the typescript continuously for crash diagnostics
        # -c: execute the exact quoted child command under a PTY
        script -qefc "$child_cmd" "$raw" || rc=$?
        if [[ -f $raw ]]; then
            leap16_r46_sanitize_typescript "$raw" "$log" || cp -- "$raw" "$log" 2>/dev/null || true
            rm -f -- "$raw" 2>/dev/null || true
        fi
    fi

    printf 'stage_exit=%s\nstage_finished_at=%s\n' "$rc" "$(date --iso-8601=seconds 2>/dev/null || date)" >>"$LEAP16_R44_TRANSACTION_DIAG_DIR/transaction.conf" 2>/dev/null || true
    printf 'Transaction transcript: %s\n' "$LEAP16_R44_TRANSACTION_DIAG_DIR"
    return "$rc"
}
