#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"
layer="$ROOT/lib/leap16_r74.sh"
fail_test(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f $layer ]] || fail_test 'r74 layer missing'
grep -Fq 'SWITCHER_RELEASE="leap16-r74"' "$main" || fail_test 'release is not r74'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r74.sh"' "$main" || fail_test 'r74 layer is not sourced last'
grep -Fq 'leap16_r73_run_repair_inner)' "$layer" || fail_test 'r73 repair executor is not strictly allowlisted'
for preserved in leap16_r64_run_refind_edge_inner leap16_r64_restore_refind_backup \
                 leap16_r64_restore_grub_backup_from_refind leap16_r64_restore_limine_backup_from_refind \
                 leap16_r64_restore_systemd_backup_from_refind; do
  grep -Fq "$preserved" "$layer" || fail_test "existing r64 child executor was dropped: $preserved"
done
grep -Fq '$expected_current == grub && $target == grub && $kind == repair && $# == 0' "$layer" \
    || fail_test 'same-GRUB/no-argument child contract is missing'

# Load the complete release exactly as a fresh transcript child does, then
# replace only hardware/UI functions. The effective r74 allowlist must execute
# the repair action and continue rejecting arbitrary or malformed child calls.
prelude=$(awk '/^select_target_bootloader\(\)/{exit} {print}' "$main" | sed '/^SCRIPT_DIR=/d')
SCRIPT_DIR=$ROOT
eval "$prelude"
(
  d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
  detect_bootloader(){ BOOTLOADER=grub; }
  leap16_r73_run_repair_inner(){ printf 'r73-repair-ran\n'; }
  leap16_r64_run_refind_edge_inner(){ printf 'r64-refind:%s\n' "$1"; }

  out=$(leap16_r46_transcript_child "$d" grub grub repair leap16_r73_run_repair_inner)
  [[ $out == r73-repair-ran ]] || fail_test 'fresh-child repair dispatch did not execute r73'

  out=$(leap16_r46_transcript_child "$d" grub refind switch leap16_r64_run_refind_edge_inner refind)
  [[ $out == r64-refind:refind ]] || fail_test 'r74 regressed the existing r64 child dispatch'

  leap16_r46_transcript_child "$d" grub grub repair leap16_r73_run_repair_inner unexpected >/dev/null 2>&1 \
      && fail_test 'r73 child accepted an unexpected argument'
  leap16_r46_transcript_child "$d" grub refind switch leap16_r73_run_repair_inner >/dev/null 2>&1 \
      && fail_test 'r73 child accepted the wrong direction/kind'
  leap16_r46_transcript_child "$d" grub grub repair definitely_not_allowed >/dev/null 2>&1 \
      && fail_test 'arbitrary transcript child was accepted'
  :
)

printf 'leap16-r74 selftest: PASS\n'
