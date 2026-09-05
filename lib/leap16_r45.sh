#!/usr/bin/env bash
# leap16-r45: keep r44 full transaction transcripts without letting CR/ANSI
# progress output corrupt the live terminal.  Transaction semantics are unchanged.

# Convert terminal-control-oriented output into a stable line stream before it
# reaches both Konsole and stage.log.  The transaction command still sees a pipe
# exactly as in r44; this only normalizes the mirror side of that pipe.
leap16_r45_stage_log_filter() {
    # 1) carriage-return progress updates become normal lines instead of moving
    #    the terminal cursor back over already-printed transaction text.
    # 2) strip common ANSI CSI control sequences from captured command output.
    #    Our own switcher status lines do not rely on those sequences.
    tr '\r' '\n' | sed -u -E $'s/\x1B\\[[0-?]*[ -\\/]*[@-~]//g'
}

# Override only r44's transcript wrapper.  Keep stdout/stderr merged into one
# ordered stream, but normalize it before tee writes to the live terminal/log.
# Wait for the mirror process after restoring the original descriptors so no
# buffered tail can race with the next menu/prompt.
leap16_r44_with_transaction_transcript() {
    local current=$1 target=$2 kind=$3 command=$4 rc=0 log mirror_pid=0
    shift 4
    leap16_r44_diag_begin "$current" "$target" "$kind" || {
        warn 'Could not create the full transaction transcript directory; normal checkpoint diagnostics remain available'
        "$command" "$@"
        return $?
    }
    log="$LEAP16_R44_TRANSACTION_DIAG_DIR/stage.log"
    exec 8>&1 9>&2
    exec > >(leap16_r45_stage_log_filter | tee -a "$log") 2>&1
    mirror_pid=$!
    "$command" "$@" || rc=$?
    exec 1>&8 2>&9
    exec 8>&- 9>&-
    if [[ $mirror_pid =~ ^[0-9]+$ && $mirror_pid -gt 0 ]]; then
        wait "$mirror_pid" 2>/dev/null || true
    fi
    printf 'stage_exit=%s\nstage_finished_at=%s\n' "$rc" "$(date --iso-8601=seconds 2>/dev/null || date)" >>"$LEAP16_R44_TRANSACTION_DIAG_DIR/transaction.conf" 2>/dev/null || true
    printf 'Transaction transcript: %s\n' "$LEAP16_R44_TRANSACTION_DIAG_DIR"
    return "$rc"
}
