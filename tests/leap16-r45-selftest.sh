#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

grep -Fq 'SWITCHER_RELEASE="leap16-r45"' bootloader-switcher.sh || fail 'release not r45'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r45.sh"' bootloader-switcher.sh || fail 'r45 overlay not sourced'
grep -Fq "tr '\\r' '\\n'" lib/leap16_r45.sh || fail 'CR normalization missing'
grep -Fq 'tee -a "$log"' lib/leap16_r45.sh || fail 'stage transcript tee missing'
grep -Fq 'wait "$mirror_pid"' lib/leap16_r45.sh || fail 'mirror drain wait missing'
grep -Fq 'leap16_r44_diag_begin' lib/leap16_r45.sh || fail 'r44 transaction directory integration missing'
# r45 must not touch switch/backend implementation layers.
for f in lib/leap16_r31.sh lib/leap16_r37.sh lib/leap16_r43.sh lib/leap16_r44.sh; do
  [[ -f $f ]] || fail "missing $f"
done
printf 'PASS: leap16-r45 transcript UX regression\n'
