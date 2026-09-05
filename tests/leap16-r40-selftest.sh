#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
pass(){ printf 'PASS: %s\n' "$1"; }
fail(){ printf 'FAIL: %s\n' "$1" >&2; exit 1; }

grep -Fq 'SWITCHER_RELEASE="leap16-r40"' bootloader-switcher.sh || fail 'release is not r40'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r40.sh"' bootloader-switcher.sh || fail 'r40 layer is not sourced'
grep -Fq 'The exact GRUB2 one-shot target is running.' lib/leap16_r40.sh || fail 'reverse target menu is missing'
grep -Fq 'leap16_r39_validate_grub_runtime' lib/leap16_r40.sh || fail 'reverse menu does not call r39 runtime proof'
grep -Fq 'Finalize GRUB2 and retire exact systemd-boot source' lib/leap16_r40.sh || fail 'reverse manual finalization option is missing'
! grep -Fq 'not recorded source Boot$PENDING_OLD_BOOT_ID' lib/leap16_r40.sh || fail 'stale source-ID gate leaked into r40 reverse menu'

while IFS= read -r f; do bash -n "$f" || fail "syntax: $f"; done < <(find . -type f -name '*.sh' -print | LC_ALL=C sort)
pass 'all shell files parse'

# Reproduce the exact current rescued session: source Boot0000, target GRUB
# Boot0003, boot-armed, BootNext consumed.  The menu must route option 1 into
# r39 target runtime proof instead of demanding BootCurrent == source Boot0000.
(
  manage_pending_migration(){ :; }
  r22_show_last_auto_result(){ :; }
  pending_exists(){ return 0; }
  validate_pending_compatibility(){ return 0; }
  leap16_r38_pending(){ return 0; }
  detect_bootloader(){ BOOTLOADER=grub; BOOT_CURRENT=0003; }
  show_pending_details(){ :; }
  pending_bootnext_id(){ printf ''; }
  leap16_r39_validate_grub_runtime(){ printf 'RUNTIME_OK\n'; }
  fail(){ printf 'FAILMSG:%s\n' "$*"; return 1; }
  source lib/leap16_r40.sh
  PENDING_OLD_BOOT_ID=0000 PENDING_TARGET_BOOT_ID=0003 PENDING_PHASE=boot-armed
  out=$(printf '1\n' | leap16_r40_reverse_pending_menu)
  grep -Fq 'RUNTIME_OK' <<<"$out" || exit 1
  ! grep -Fq 'not recorded source' <<<"$out" || exit 1
)
pass 'real GRUB target BootCurrent routes to reverse runtime validation'

# runtime-validated target must expose finalization from the same GRUB session.
(
  manage_pending_migration(){ :; }
  r22_show_last_auto_result(){ :; }
  pending_exists(){ return 0; }
  validate_pending_compatibility(){ return 0; }
  leap16_r38_pending(){ return 0; }
  detect_bootloader(){ BOOTLOADER=grub; BOOT_CURRENT=0003; }
  show_pending_details(){ :; }
  leap16_r39_validate_grub_runtime(){ :; }
  r26_finalize_adapter_transaction(){ printf 'FINALIZE_OK\n'; }
  fail(){ printf 'FAILMSG:%s\n' "$*"; return 1; }
  source lib/leap16_r40.sh
  PENDING_OLD_BOOT_ID=0000 PENDING_TARGET_BOOT_ID=0003 PENDING_PHASE=runtime-validated
  out=$(printf '2\n' | leap16_r40_reverse_pending_menu)
  grep -Fq 'FINALIZE_OK' <<<"$out" || exit 1
)
pass 'runtime-proven GRUB target can enter ownership-gated finalization'

# Non-reverse transactions must still delegate unchanged.
(
  manage_pending_migration(){ printf 'OLD_MENU\n'; }
  r22_show_last_auto_result(){ :; }
  pending_exists(){ return 0; }
  validate_pending_compatibility(){ return 0; }
  leap16_r38_pending(){ return 1; }
  source lib/leap16_r40.sh
  [[ $(manage_pending_migration) == OLD_MENU ]] || exit 1
)
pass 'all non-reverse pending paths delegate unchanged'

pass 'r40 focused contract passes'
