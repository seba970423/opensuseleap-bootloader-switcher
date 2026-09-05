#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r46.sh"' bootloader-switcher.sh || fail 'r46 overlay not sourced'
grep -Fq -- '--r46-transcript-child' bootloader-switcher.sh || fail 'r46 hidden transcript child dispatch missing'
grep -Fq 'script -qefc "$child_cmd" "$raw"' lib/leap16_r46.sh || fail 'PTY recorder missing'
! grep -Fq 'exec > >(leap16_r45_stage_log_filter | tee -a "$log")' lib/leap16_r46.sh || fail 'r45 async tee transport leaked into r46 override'
grep -Fq 'leap16_r44_run_systemd_edge_inner|leap16_r44_restore_grub_backup_from_systemd|leap16_r44_restore_systemd_backup' lib/leap16_r46.sh || fail 'child command allowlist missing'

# Verify sanitizer removes script(1) metadata, CR and CSI controls from the file.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
printf 'Script started on now [COMMAND="x"]\nA\rB\n\033[2KC\nScript done on now [COMMAND_EXIT_CODE="0"]\n' >"$tmp/raw"
# Source only the overlay; sanitizer has no external switcher dependencies.
source lib/leap16_r46.sh
leap16_r46_sanitize_typescript "$tmp/raw" "$tmp/out"
grep -Fxq 'A' "$tmp/out" || fail 'CR normalization missing A'
grep -Fxq 'B' "$tmp/out" || fail 'CR normalization missing B'
grep -Fxq 'C' "$tmp/out" || fail 'CSI stripping missing C'
! grep -Fq 'Script started' "$tmp/out" || fail 'script header not removed'
! grep -Fq $'\033' "$tmp/out" || fail 'ANSI escape survived sanitizer'

printf 'PASS: leap16-r46 PTY transcript regression\n'
