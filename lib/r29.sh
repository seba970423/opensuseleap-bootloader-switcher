#!/usr/bin/env bash
# r29: nounset-safe systemd-boot v4 restore path hotfix.
#
# The first real-hardware r28 restore attempt reached the write boundary, proved
# the GRUB source and selected systemd-boot v4 backup, then failed before
# bootctl/staging because r28_systemd_backup_esp_path declared backup_mount and
# expanded it for rel in the same `local` command:
#
#   local dir=$1 backup_mount=$2 rel=${backup_mount#/}
#
# Under the switcher's `set -u`, Bash expands the right-hand side before the
# new local backup_mount assignment becomes visible.  r28's validator happened
# to mask this because its caller already had a dynamically-scoped local named
# backup_mount.  The live staging caller did not, exposing the bug.
#
# Keep r28 intact as the historical implementation and override only the helper
# with a split declaration/assignment.  All r28 transactional restore behavior
# remains unchanged.

r28_systemd_backup_esp_path() {
    local dir=$1 backup_mount=$2 rel
    rel=${backup_mount#/}
    [[ -n $rel && $rel != *'..'* ]] || return 1
    printf '%s/files/%s\n' "$dir" "$rel"
}
