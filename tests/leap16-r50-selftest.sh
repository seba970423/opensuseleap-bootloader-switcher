#!/usr/bin/env bash
set -u
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fail(){ printf 'FAIL: %s\n' "$*"; exit 1; }
pass(){ printf 'PASS: %s\n' "$*"; }
main="$ROOT/bootloader-switcher.sh"
ov="$ROOT/lib/leap16_r50.sh"
grep -q 'SWITCHER_RELEASE="leap16-r50"' "$main" || fail 'release is not r50'
grep -q 'source "$SCRIPT_DIR/lib/leap16_r50.sh"' "$main" || fail 'r50 overlay is not sourced'
grep -q 'if leap16_r48_pending; then' "$ov" || fail 'r48 direct pending interception missing'
grep -q 'Continue ownership-gated finalization from this promoted checkpoint' "$ov" || fail 'promoted checkpoint continuation missing'
grep -q 'r26_finalize_adapter_transaction' "$ov" || fail 'r49/r48 finalizer is not reachable from r50 pending manager'
grep -q 'recorded Limine source' "$ov" || fail 'direction-correct source identity text missing'
if grep -q "Current bootloader is neither the recorded GRUB2 source nor Limine target" "$ov"; then fail 'historical wrong-direction message leaked into r50 overlay'; fi
bash -n "$ov" || fail 'r50 overlay syntax'
pass 'leap16-r50 direct pending-manager routing regression'
