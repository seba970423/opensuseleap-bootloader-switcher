#!/usr/bin/env bash
# leap16-r62: extend the strict r46/r52 PTY transcript child allowlist for the
# two r61 Limine <-> systemd-boot backup-restore executors.
#
# r61 correctly routed both new restore operations through the existing r46 PTY
# transcript wrapper, but the child process still failed closed because r52's
# strict command allowlist predates those r61 executor names.  This overlay does
# not change restore validation or firmware behavior; it only admits the exact
# two r61 transaction entry points while preserving the fail-closed allowlist.

leap16_r46_transcript_child() {
    local diag=${1:-} expected_current=${2:-} target=${3:-} kind=${4:-} command=${5:-}
    shift 5 || true

    [[ -n $diag && -d $diag && ! -L $diag ]] || { printf '[FAIL] Invalid r46 transaction diagnostics directory\n' >&2; return 2; }
    case "$command" in
        leap16_r44_run_systemd_edge_inner|\
        leap16_r44_restore_grub_backup_from_systemd|\
        leap16_r44_restore_systemd_backup|\
        leap16_r51_run_systemd_to_limine_inner|\
        leap16_r61_restore_systemd_backup_from_limine|\
        leap16_r61_restore_limine_backup_from_systemd) ;;
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
