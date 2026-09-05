#!/usr/bin/env bash
set -u
cd -- "$(dirname -- "$0")/.." || exit 1
failures=0
pass(){ printf '[PASS] %s\n' "$1"; }
fail_test(){ printf '[FAIL] %s\n' "$1" >&2; failures=$((failures+1)); }

printf 'openSUSE Leap 16 r30 focused self-test\n======================================\n\n'

if grep -Fq 'SWITCHER_RELEASE="leap16-r31"' bootloader-switcher.sh \
 && awk '/leap16_r29.sh/{a=NR} /leap16_r30.sh/{b=NR} /leap16_r31.sh/{c=NR} END{exit !(a&&b&&c&&a<b&&b<c)}' bootloader-switcher.sh; then
  pass 'r30 hardware-fix layer remains loaded beneath the r31 UX/backup layer'
else
  fail_test 'r30 regression layer/load order is wrong beneath r31'
fi

if bash -n bootloader-switcher.sh && for f in lib/*.sh tests/*.sh; do bash -n "$f" || exit 1; done; then
  pass 'all shell files parse'
else
  fail_test 'one or more shell files have syntax errors'
fi

# Exact hardware failure fixture: core candidate order 0000,0001,0003 plus a
# newly synthesized direct-GRUB alias 0004. Recorded parked direct alias 0002
# still exists outside BootOrder.
(
  r15_validate_grub_target_runtime(){ :; }
  r15_promote_and_finalize_grub(){ :; }
  source lib/leap16_r30.sh
  PENDING_OLD_BOOT_ID=0000
  PENDING_TARGET_BOOT_ID=0003
  R28_GRUB_DIRECT_PATH='\EFI\OPENSUSE\GRUBX64.EFI'
  r28_rebuilt_reverse_pending(){ return 0; }
  r28_meta_value(){ case "$1" in source_fallback_boot_id) printf '0001\n';; direct_grub_boot_id) printf '0002\n';; esac; }
  nvram_id_matches_path(){ [[ $1 == 0002 && $2 == "$R28_GRUB_DIRECT_PATH" ]]; }
  leap16_nvram_entry_matches_current_esp(){ return 0; }
  efibootmgr(){ cat <<'DUMP'
BootCurrent: 0003
BootOrder: 0000,0001,0003,0004
Boot0000* openSUSE Limine HD(...) /File(\EFI\LIMINE\LIMINE_X64.EFI)
Boot0001* UEFI OS HD(...) /File(\EFI\BOOT\BOOTX64.EFI)
Boot0002* opensuse HD(...) /File(\EFI\OPENSUSE\GRUBX64.EFI)
Boot0003* opensuse-secureboot HD(...) /File(\EFI\OPENSUSE\SHIM.EFI)
Boot0004* opensuse HD(...) /File(\EFI\OPENSUSE\GRUBX64.EFI)0000424f
DUMP
  }
  leap16_line_for_id_in_dump(){ grep -E "^Boot${2}" <<<"$1" | head -n1; }
  leap16_line_is_bbs(){ return 1; }
  efi_path_from_efibootmgr_line(){ sed -n 's/.*\/File(\([^)]*\)).*/\1/p' <<<"$1"; }
  normalize_efi_path(){ printf '%s\n' "$1"; }
  fail(){ printf 'FAIL:%s\n' "$*" >&2; }
  warn(){ :; }
  ok(){ :; }
  r30_validate_reconstructed_runtime_order || exit 21
  [[ ${R30_RUNTIME_DIRECT_EXTRAS:-} == 0004 ]] || exit 22
)
case $? in
  0) pass 'runtime order accepts the exact ASUS-synthesized same-ESP direct-GRUB trailing alias' ;;
  *) fail_test 'ASUS synthesized direct-GRUB runtime-order fixture failed' ;;
esac

# An unrelated EFI path in the same position must still fail closed.
(
  r15_validate_grub_target_runtime(){ :; }
  r15_promote_and_finalize_grub(){ :; }
  source lib/leap16_r30.sh
  PENDING_OLD_BOOT_ID=0000; PENDING_TARGET_BOOT_ID=0003; R28_GRUB_DIRECT_PATH='\EFI\OPENSUSE\GRUBX64.EFI'
  r28_rebuilt_reverse_pending(){ return 0; }
  r28_meta_value(){ case "$1" in source_fallback_boot_id) printf '0001\n';; direct_grub_boot_id) printf '0002\n';; esac; }
  nvram_id_matches_path(){ return 0; }
  leap16_nvram_entry_matches_current_esp(){ return 0; }
  efibootmgr(){ cat <<'DUMP'
BootOrder: 0000,0001,0003,0004
Boot0000* Limine /File(\EFI\LIMINE\LIMINE_X64.EFI)
Boot0001* UEFI OS /File(\EFI\BOOT\BOOTX64.EFI)
Boot0002* opensuse /File(\EFI\OPENSUSE\GRUBX64.EFI)
Boot0003* opensuse-secureboot /File(\EFI\OPENSUSE\SHIM.EFI)
Boot0004* Other /File(\EFI\OTHER\OTHER.EFI)
DUMP
  }
  leap16_line_for_id_in_dump(){ grep -E "^Boot${2}" <<<"$1" | head -n1; }
  leap16_line_is_bbs(){ return 1; }
  efi_path_from_efibootmgr_line(){ sed -n 's/.*\/File(\([^)]*\)).*/\1/p' <<<"$1"; }
  normalize_efi_path(){ printf '%s\n' "$1"; }
  fail(){ :; }; warn(){ :; }; ok(){ :; }
  ! r30_validate_reconstructed_runtime_order
)
case $? in
  0) pass 'runtime order still rejects unrelated extra EFI aliases' ;;
  *) fail_test 'unrelated EFI alias was incorrectly accepted' ;;
esac

# Post-proof normalization keeps the transaction-created parked direct alias and
# removes only the firmware/openSUSE-created same-path alias that entered
# BootOrder. This restores the exact r28 pre-promotion invariant.
(
  r15_validate_grub_target_runtime(){ :; }
  r15_promote_and_finalize_grub(){ :; }
  source lib/leap16_r30.sh
  PENDING_PHASE=runtime-validated
  R28_GRUB_DIRECT_PATH='\EFI\OPENSUSE\GRUBX64.EFI'
  DIRECT_IDS='0002 0004'
  ORDER='0000,0001,0003,0004'
  r28_rebuilt_reverse_pending(){ return 0; }
  r28_meta_value(){ printf '0002\n'; }
  nvram_id_matches_path(){ [[ $1 == 0002 && $2 == "$R28_GRUB_DIRECT_PATH" ]]; }
  leap16_nvram_entry_matches_current_esp(){ return 0; }
  leap16_current_boot_order(){ printf '%s\n' "$ORDER"; }
  leap16_order_has_id(){ [[ ",$1," == *",$2,"* ]]; }
  r28_ids_for_path(){ for x in $DIRECT_IDS; do printf '%s\n' "$x"; done; }
  sudo(){
    if [[ $1 == efibootmgr && $2 == -b && $3 == 0004 && $4 == -B ]]; then
      DIRECT_IDS='0002'; ORDER='0000,0001,0003'; return 0
    fi
    return 1
  }
  leap16_stage_diagnostic(){ return 0; }
  fail(){ printf 'FAIL:%s\n' "$*" >&2; }; ok(){ :; }
  r30_normalize_reconstructed_direct_aliases || exit 31
  [[ $DIRECT_IDS == 0002 ]] || exit 32
  [[ $ORDER == 0000,0001,0003 ]] || exit 33
)
case $? in
  0) pass 'post-proof normalization removes synthesized duplicate and restores the original parked-direct r28 invariant' ;;
  *) fail_test 'post-proof direct-alias normalization fixture failed' ;;
esac

# The promotion wrapper must normalize before delegating to the unchanged r28
# finalizer.  At delegation time the parked direct alias is again outside
# BootOrder, so r28 can continue without special-case weakening.
(
  r15_validate_grub_target_runtime(){ :; }
  r15_promote_and_finalize_grub(){ return 90; }
  source lib/leap16_r30.sh
  PENDING_PHASE=runtime-validated
  R28_GRUB_DIRECT_PATH='\EFI\OPENSUSE\GRUBX64.EFI'
  DIRECT_IDS='0002 0004'; ORDER='0000,0001,0003,0004'; NORMALIZED=0
  r28_rebuilt_reverse_pending(){ return 0; }
  r28_meta_value(){ printf '0002\n'; }
  nvram_id_matches_path(){ [[ $1 == 0002 ]]; }
  leap16_nvram_entry_matches_current_esp(){ return 0; }
  leap16_current_boot_order(){ printf '%s\n' "$ORDER"; }
  leap16_order_has_id(){ [[ ",$1," == *",$2,"* ]]; }
  r28_ids_for_path(){ for x in $DIRECT_IDS; do printf '%s\n' "$x"; done; }
  sudo(){ if [[ $1 == efibootmgr && $2 == -b && $3 == 0004 && $4 == -B ]]; then DIRECT_IDS='0002'; ORDER='0000,0001,0003'; NORMALIZED=1; return 0; fi; return 1; }
  leap16_stage_diagnostic(){ return 0; }
  fail(){ :; }; ok(){ :; }
  r15_promote_and_finalize_grub_pre_r30(){
    [[ $NORMALIZED == 1 && $DIRECT_IDS == 0002 && $ORDER == 0000,0001,0003 ]] || return 41
    return 0
  }
  r15_promote_and_finalize_grub || exit 42
)
case $? in
  0) pass 'promotion delegates to unchanged r28 finalizer only after duplicate cleanup restored candidate topology' ;;
  *) fail_test 'promotion wrapper did not normalize before r28 finalization' ;;
esac

if (( failures == 0 )); then
  printf '\nAll focused openSUSE Leap 16 r30 self-tests passed.\n'
  exit 0
fi
printf '\n%d focused r30 self-test(s) failed.\n' "$failures" >&2
exit 1
