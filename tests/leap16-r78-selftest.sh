#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"
layer="$ROOT/lib/leap16_r78.sh"
fail_test(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f $layer ]] || fail_test 'r78 layer missing'
grep -Fq 'SWITCHER_RELEASE="leap16-r78"' "$main" || fail_test 'release is not r78'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r78.sh"' "$main" || fail_test 'r78 layer is not sourced'
[[ $(grep -n 'source "$SCRIPT_DIR/lib/leap16_r78.sh"' "$main" | tail -n1 | cut -d: -f1) -gt \
   $(grep -n 'source "$SCRIPT_DIR/lib/leap16_r77.sh"' "$main" | tail -n1 | cut -d: -f1) ]] \
    || fail_test 'r78 is not the final release layer'
grep -Fq 'leap16_r77_cleanup_finalized_grub_duplicates_inner' "$layer" || fail_test 'r77 cleanup executor is not admitted'
grep -Fq '$expected_current == grub && $target == grub && $kind == cleanup && $# == 0' "$layer" \
    || fail_test 'r77 cleanup child contract is not exact/fail-closed'
grep -Fq 'leap16_r46_transcript_child_pre_leap16_r78 "$@"' "$layer" \
    || fail_test 'pre-existing transcript child dispatcher is not delegated unchanged'

# Load the complete release exactly as a fresh transcript child does. Reproduce
# the hardware failure: parent selected grub -> grub cleanup and the child must
# now run the r77 executor instead of rejecting it as unknown. Existing actions
# must still delegate to the inherited closed allowlist.
prelude=$(awk '/^select_target_bootloader\(\)/{exit} {print}' "$main" | sed '/^SCRIPT_DIR=/d')
SCRIPT_DIR=$ROOT
eval "$prelude"
(
  d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
  detect_bootloader(){ BOOTLOADER=grub; }
  leap16_r77_cleanup_finalized_grub_duplicates_inner(){ printf 'r77-cleanup-ran\n'; }
  leap16_r73_run_repair_inner(){ printf 'r73-repair-ran\n'; }

  out=$(leap16_r46_transcript_child "$d" grub grub cleanup leap16_r77_cleanup_finalized_grub_duplicates_inner)
  [[ $out == r77-cleanup-ran ]] || fail_test 'fresh-child r77 cleanup dispatch did not execute'

  out=$(leap16_r46_transcript_child "$d" grub grub repair leap16_r73_run_repair_inner)
  [[ $out == r73-repair-ran ]] || fail_test 'r78 regressed inherited r73 repair dispatch'

  leap16_r46_transcript_child "$d" grub grub cleanup leap16_r77_cleanup_finalized_grub_duplicates_inner unexpected >/dev/null 2>&1 \
      && fail_test 'r77 cleanup child accepted an unexpected argument'
  leap16_r46_transcript_child "$d" grub refind cleanup leap16_r77_cleanup_finalized_grub_duplicates_inner >/dev/null 2>&1 \
      && fail_test 'r77 cleanup child accepted the wrong target'
  leap16_r46_transcript_child "$d" grub grub repair leap16_r77_cleanup_finalized_grub_duplicates_inner >/dev/null 2>&1 \
      && fail_test 'r77 cleanup child accepted the wrong kind'
  leap16_r46_transcript_child "$d" grub grub cleanup definitely_not_allowed >/dev/null 2>&1 \
      && fail_test 'arbitrary transcript child was accepted'
  :
)

printf 'leap16-r78 selftest: PASS\n'
