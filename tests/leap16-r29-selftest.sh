#!/usr/bin/env bash
set -u
cd -- "$(dirname -- "$0")/.." || exit 1
failures=0
pass(){ printf '[PASS] %s\n' "$1"; }
fail_test(){ printf '[FAIL] %s\n' "$1" >&2; failures=$((failures+1)); }

printf 'openSUSE Leap 16 r29 focused self-test\n'
printf '======================================\n\n'

if grep -Eq 'SWITCHER_RELEASE="leap16-r(29|30|31)"' bootloader-switcher.sh \
 && awk '/leap16_r28.sh/{a=NR} /leap16_r29.sh/{b=NR} /leap16_r30.sh/{c=NR} END{exit !(a&&b&&a<b&&(!c||b<c))}' bootloader-switcher.sh; then
  pass 'r29 release marker and load order are correct'
else
  fail_test 'r29 release marker/load order is wrong'
fi

if bash -n bootloader-switcher.sh && for f in lib/*.sh tests/*.sh; do bash -n "$f" || exit 1; done; then
  pass 'all shell files parse'
else
  fail_test 'one or more shell files have syntax errors'
fi

# Reproduce the ASUS-observed degraded topology: only the generic fallback has
# a Boot####, canonical Limine bytes still exist, and native GRUB is absent.
(
  run_live_operation(){ return 0; }
  source lib/leap16_r29.sh
  BOOTLOADER=limine
  BOOT_CURRENT=0001
  LEAP16_R21_FALLBACK_EFI_PATH='\EFI\BOOT\BOOTX64.EFI'
  r28_ids_for_path(){
    case "$1" in
      '\EFI\LIMINE\LIMINE_X64.EFI') return 0 ;;
      '\EFI\BOOT\BOOTX64.EFI') printf '0001\n' ;;
    esac
  }
  r28_current_native_grub_ids_csv(){ :; }
  ESP_MOUNT=/definitely/missing/r29-test-esp
  r29_fallback_only_topology_candidate || exit 11
  BOOT_CURRENT=0002
  ! r29_fallback_only_topology_candidate || exit 12
)
case $? in
  0) pass 'fallback-only topology detector recognizes the hardware-observed BootCurrent fallback state only' ;;
  *) fail_test 'fallback-only topology detection fixture failed' ;;
esac

# The repair must capture diagnostics before its first firmware mutation and
# again after topology normalization.
python3 - <<'PY'
from pathlib import Path
s=Path('lib/leap16_r29.sh').read_text()
start=s.index('r29_repair_canonical_limine_alias()')
end=s.index('\nr29_fallback_only_repair_plan()', start)
b=s[start:end]
pre=b.find('r29-fallback-only-prewrite')
write=b.find('sudo efibootmgr --create-only')
post=b.find('r29-fallback-only-repaired')
order=b.find('r29_order_primary_fallback_existing')
raise SystemExit(0 if -1 not in (pre,write,post,order) and pre < write < order < post else 1)
PY
case $? in
  0) pass 'canonical alias recovery requires pre-write diagnostics and post-repair diagnostics around the NVRAM write' ;;
  *) fail_test 'diagnostic/write ordering contract is wrong' ;;
esac

if grep -Fq 'mapfile -t fallback_ids < <(r29_ids_for_path "$LEAP16_R21_FALLBACK_EFI_PATH")' lib/leap16_r29.sh \
 && grep -Fq 'r29_order_primary_fallback_existing "$primary" "$fallback"' lib/leap16_r29.sh \
 && grep -Fq 'No GRUB files or aliases were created by this repair' lib/leap16_r29.sh; then
  pass 'repair re-discovers fallback by ESP/path, restores primary/fallback order, and does not reconstruct GRUB in the degraded session'
else
  fail_test 'fallback rediscovery/order/no-GRUB repair contract is incomplete'
fi

if grep -Fq 'Type REPAIR to recreate the canonical Limine firmware alias' lib/leap16_r29.sh \
 && grep -Fiq 'reboot normally once' lib/leap16_r29.sh \
 && grep -Fq 'run_live_operation_pre_r29 "$@"' lib/leap16_r29.sh; then
  pass 'fallback-only repair is an explicit write boundary and healthy r28 paths remain delegated unchanged'
else
  fail_test 'r29 dispatcher/write-boundary delegation is wrong'
fi

if (( failures == 0 )); then
  printf '\nAll focused openSUSE Leap 16 r29 self-tests passed.\n'
  exit 0
fi
printf '\n%d focused r29 self-test(s) failed.\n' "$failures" >&2
exit 1
