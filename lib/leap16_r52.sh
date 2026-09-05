#!/usr/bin/env bash
# leap16-r52: transcript child dispatch + locale-safe PTY transcript sanitizer.
#
# r51 added a new systemd-boot -> Limine transaction entry point, but r46's
# deliberately strict PTY child allowlist still knew only the original r44
# systemd-edge functions.  As a result the PTY child failed closed before the
# r51 preflight could even start.  Keep the strict allowlist, but include the
# exact r51 transaction entry point.
#
# r51 also exposed a locale-sensitive sed range in r46's post-PTY sanitizer.
# Force bytewise C collation for the control-sequence regex so a user's UTF-8
# locale cannot turn the ASCII ranges into "Invalid range end".

leap16_r46_sanitize_typescript() {
    local raw=$1 out=$2
    LC_ALL=C tr '\r' '\n' <"$raw" \
        | LC_ALL=C sed -u -E $'s#\x1B\\[[0-?]*[ -/]*[@-~]##g' \
        | LC_ALL=C sed -E '/^Script started on .*\[COMMAND=/d; /^Script done on .*\[COMMAND_EXIT_CODE=/d' \
        >"$out"
}

leap16_r46_transcript_child() {
    local diag=${1:-} expected_current=${2:-} target=${3:-} kind=${4:-} command=${5:-}
    shift 5 || true

    [[ -n $diag && -d $diag && ! -L $diag ]] || { printf '[FAIL] Invalid r46 transaction diagnostics directory\n' >&2; return 2; }
    case "$command" in
        leap16_r44_run_systemd_edge_inner|\
        leap16_r44_restore_grub_backup_from_systemd|\
        leap16_r44_restore_systemd_backup|\
        leap16_r51_run_systemd_to_limine_inner) ;;
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
