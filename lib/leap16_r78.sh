#!/usr/bin/env bash
# leap16-r78: admit the r77 finalized-GRUB duplicate-cleanup executor through
# the strict r46 PTY transcript child boundary.
#
# The first r77 hardware cleanup attempt reached the transcript wrapper but the
# fresh child process still inherited r75's closed allowlist, which knew the
# older r73 repair and r75 residue-cleanup executors but not the new r77
# same-GRUB NVRAM-only cleanup action.  Keep the boundary fail-closed: intercept
# exactly that one zero-argument grub -> grub cleanup contract and delegate all
# pre-existing child commands unchanged to the inherited r75 dispatcher.

if declare -F leap16_r46_transcript_child >/dev/null 2>&1; then
    eval "$(declare -f leap16_r46_transcript_child | sed '1s/leap16_r46_transcript_child/leap16_r46_transcript_child_pre_leap16_r78/')"
fi

leap16_r46_transcript_child() {
    local diag=${1:-} expected_current=${2:-} target=${3:-} kind=${4:-} command=${5:-}

    if [[ $command != leap16_r77_cleanup_finalized_grub_duplicates_inner ]]; then
        leap16_r46_transcript_child_pre_leap16_r78 "$@"
        return $?
    fi

    shift 5 || true
    [[ -n $diag && -d $diag && ! -L $diag ]] \
        || { printf '[FAIL] Invalid r46 transaction diagnostics directory\n' >&2; return 2; }
    [[ $expected_current == grub && $target == grub && $kind == cleanup && $# == 0 ]] \
        || { printf '[FAIL] Invalid r77 finalized-GRUB cleanup transcript-child contract\n' >&2; return 2; }
    declare -F "$command" >/dev/null 2>&1 \
        || { printf '[FAIL] r46 transcript child command is unavailable: %s\n' "$command" >&2; return 2; }

    LEAP16_R44_TRANSACTION_DIAG_DIR=$diag
    detect_bootloader
    [[ $BOOTLOADER == grub ]] || {
        printf '[FAIL] Bootloader changed before transcript child start: expected grub, detected %s\n' "$BOOTLOADER" >&2
        return 1
    }
    "$command"
}
