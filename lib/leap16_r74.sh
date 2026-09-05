#!/usr/bin/env bash
# leap16-r74: admit the r73 same-GRUB repair executor through the strict r46
# PTY transcript child boundary.
#
# The first hardware run proved the parent dispatch and transcript wrapper were
# reached, but the fresh child process rejected leap16_r73_run_repair_inner
# before repair preflight. This mirrors the r61/r62 restore-dispatch failure.
# Keep the allowlist closed and add only this exact no-argument executor.

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
        leap16_r61_restore_limine_backup_from_systemd|\
        leap16_r64_run_refind_edge_inner|\
        leap16_r64_restore_refind_backup|\
        leap16_r64_restore_grub_backup_from_refind|\
        leap16_r64_restore_limine_backup_from_refind|\
        leap16_r64_restore_systemd_backup_from_refind|\
        leap16_r73_run_repair_inner) ;;
        *) printf '[FAIL] Refusing unknown r46 transcript child command: %s\n' "$command" >&2; return 2 ;;
    esac
    declare -F "$command" >/dev/null 2>&1 || { printf '[FAIL] r46 transcript child command is unavailable: %s\n' "$command" >&2; return 2; }

    # The r73 repair is deliberately a same-backend operation and takes no
    # executor arguments. Refuse any attempt to smuggle arguments through its
    # newly admitted child action.
    if [[ $command == leap16_r73_run_repair_inner ]]; then
        [[ $expected_current == grub && $target == grub && $kind == repair && $# == 0 ]] \
            || { printf '[FAIL] Invalid r73 repair transcript-child contract\n' >&2; return 2; }
    fi

    LEAP16_R44_TRANSACTION_DIAG_DIR=$diag
    detect_bootloader
    if [[ $BOOTLOADER != "$expected_current" ]]; then
        printf '[FAIL] Bootloader changed before transcript child start: expected %s, detected %s\n' "$expected_current" "$BOOTLOADER" >&2
        return 1
    fi

    "$command" "$@"
}
