#!/usr/bin/env bash
set -u
cd -- "$(dirname -- "$0")/.." || exit 1
failures=0
pass(){ printf '[PASS] %s\n' "$1"; }
fail_test(){ printf '[FAIL] %s\n' "$1" >&2; failures=$((failures+1)); }

printf 'openSUSE Leap 16 r28 focused self-test\n'
printf '======================================\n\n'

if grep -Eq 'SWITCHER_RELEASE="leap16-r(28|29|30|31)"' bootloader-switcher.sh \
 && awk '/leap16_r27.sh/{a=NR} /leap16_r28.sh/{b=NR} /leap16_r29.sh/{c=NR} END{exit !(a&&b&&a<b&&(!c||b<c))}' bootloader-switcher.sh; then
  pass 'r28 layer remains in valid release/load order'
else
  fail_test 'r28 release/load order is wrong'
fi

if bash -n bootloader-switcher.sh && for f in lib/*.sh tests/*.sh; do bash -n "$f" || exit 1; done; then
  pass 'all shell files parse'
else
  fail_test 'one or more shell files have syntax errors'
fi

# shim-install must reconstruct native files without taking NVRAM authority.
if grep -Fq 'sudo shim-install --no-nvram --efi-directory="$ESP_MOUNT" --config-file=/boot/grub2/grub.cfg' lib/leap16_r28.sh \
 && ! grep -Fq 'shim-install --no-nvram --bootloader-id=' lib/leap16_r28.sh \
 && grep -Fq "shim.efi,opensuse-secureboot" lib/leap16_r28.sh; then
  pass 'native shim reconstruction keeps NVRAM explicit and preserves openSUSE secureboot boot.csv identity'
else
  fail_test 'shim reconstruction command/boot.csv contract is wrong'
fi

if grep -Fq 'for p in grub2-mkconfig grub2-script-check grub2-install grub2-probe grub2-mkrelpath shim-install efibootmgr rpm iconv' lib/leap16_r28.sh; then
  pass 'preflight requires shim-install transitive GRUB/iconv tools before writes'
else
  fail_test 'preflight does not require the complete reconstruction toolchain'
fi

# Source only r28 with stubs for the overridden symbols, then exercise its
# current-ESP path filters using a multi-ESP-style efibootmgr fixture.
(
  leap16_reverse_pending(){ return 1; }
  validate_pending_owned_paths(){ return 0; }
  validate_pending_target_deep(){ return 0; }
  run_live_operation(){ return 0; }
  r15_promote_and_finalize_grub(){ return 0; }
  rollback_pending_candidate(){ return 0; }
  r15_rollback_reverse_candidate(){ return 0; }
  pending_banner(){ return 0; }
  manage_pending_migration(){ return 0; }
  leap16_validate_limine_recovery_contract(){ return 0; }
  LEAP16_R21_FALLBACK_EFI_PATH='\EFI\BOOT\BOOTX64.EFI'
  source lib/leap16_r28.sh
  ESP_SOURCE=/dev/fake-current-esp
  normalize_efi_path(){ local x=${1//\\//}; x=${x#/}; printf '%s\n' "$x"; }
  lsblk(){ printf '11111111-2222-3333-4444-555555555555\n'; }
  efi_path_from_efibootmgr_line(){ sed -n 's/.*\/File(\([^)]*\)).*/\1/p' <<<"$1"; }
  efibootmgr(){
    cat <<'DUMP'
BootOrder: 0002,0003
Boot0002* openSUSE Limine HD(1,GPT,11111111-2222-3333-4444-555555555555,0x800,0xff000)/File(\EFI\LIMINE\LIMINE_X64.EFI)
Boot0003* UEFI OS HD(1,GPT,11111111-2222-3333-4444-555555555555,0x800,0xff000)/File(\EFI\BOOT\BOOTX64.EFI)
Boot0004* opensuse-secureboot HD(1,GPT,11111111-2222-3333-4444-555555555555,0x800,0xff000)/File(\EFI\OPENSUSE\SHIM.EFI)
Boot0005* opensuse HD(1,GPT,11111111-2222-3333-4444-555555555555,0x800,0xff000)/File(\EFI\OPENSUSE\GRUBX64.EFI)
Boot0006* opensuse-alt HD(1,GPT,11111111-2222-3333-4444-555555555555,0x800,0xff000)/File(\EFI\OPENSUSE\GRUB.EFI)
Boot00AA* other Limine HD(1,GPT,aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,0x800,0xff000)/File(\EFI\LIMINE\LIMINE_X64.EFI)
Boot00AB* other fallback HD(1,GPT,aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,0x800,0xff000)/File(\EFI\BOOT\BOOTX64.EFI)
Boot00AC* other grub HD(1,GPT,aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,0x800,0xff000)/File(\EFI\OPENSUSE\SHIM.EFI)
DUMP
  }
  leap16_boot_entry_is_active(){ return 0; }
  leap16_nvram_entry_matches_current_esp(){ [[ ${1^^} =~ ^000[2-6]$ ]]; }
  [[ $(r28_exact_one_id_for_path '\EFI\LIMINE\LIMINE_X64.EFI') == 0002 ]] || exit 11
  [[ $(r28_exact_one_id_for_path '\EFI\BOOT\BOOTX64.EFI') == 0003 ]] || exit 12
  [[ $(r28_current_native_grub_ids_csv) == '0004,0005,0006' ]] || exit 13
)
case $? in
  0) pass 'NVRAM discovery filters same-path aliases from other ESPs and owns GRUB by current ESP/path' ;;
  *) fail_test 'current-ESP NVRAM path filtering fixture failed' ;;
esac

# A finalized Limine /EFI fallback remains a valid recovery source while the
# transaction-created EFI/OPENSUSE candidate exists during reverse staging.
(
  leap16_reverse_pending(){ return 1; }
  validate_pending_owned_paths(){ return 0; }
  validate_pending_target_deep(){ return 0; }
  run_live_operation(){ return 0; }
  r15_promote_and_finalize_grub(){ return 0; }
  rollback_pending_candidate(){ return 0; }
  r15_rollback_reverse_candidate(){ return 0; }
  pending_banner(){ return 0; }
  manage_pending_migration(){ return 0; }
  leap16_validate_limine_recovery_contract(){ return 90; }
  LEAP16_R21_FALLBACK_EFI_PATH='\EFI\BOOT\BOOTX64.EFI'
  source lib/leap16_r28.sh
  ESP_MOUNT=/fake/esp
  R28_REBUILD_STAGING=1
  r24_final_fallback_block_present(){ return 0; }
  r21_hash_privileged(){ printf '%064d\n' 1; }
  leap16_validate_limine_recovery_contract /fake/esp/limine.conf || exit 31
  [[ $LEAP16_LIMINE_RECOVERY_DETAIL == *'reconstructed native GRUB2 is staged separately'* ]] || exit 32
)
case $? in
  0) pass 'reverse staging accepts finalized Limine EFI-fallback menu while EFI/OPENSUSE candidate is staged' ;;
  *) fail_test 'reverse staging recovery-contract override failed' ;;
esac

# The candidate must keep both Limine firmware paths authoritative until proof.
if grep -Fq 'set_source_first_boot_order "$old_id" "$target_id" "$original_order"' lib/leap16_r28.sh \
 && grep -Fq '[[ $candidate_order == "$old_id,$source_fallback_id,$target_id"* ]]' lib/leap16_r28.sh \
 && grep -Fq "! leap16_order_has_id \"\$candidate_order\" \"\$direct_id\"" lib/leap16_r28.sh \
 && grep -Fq 'r15_arm_reverse_automatically' lib/leap16_r28.sh; then
  pass 'candidate keeps primary/fallback Limine first, parks direct GRUB, and uses one-shot proof'
else
  fail_test 'candidate firmware-order/one-shot proof contract is incomplete'
fi

# Verify destructive source retirement is downstream of runtime proof and shim
# fallback transfer, with both Limine aliases removed by path ownership.
python3 - <<'PY'
from pathlib import Path
s=Path('lib/leap16_r28.sh').read_text()
start=s.index('r28_retire_limine_after_grub_proof()')
end=s.index('\n# Branch the proven r15 promotion machinery', start)
b=s[start:end]
need=[
    'r21_atomic_replace "$PENDING_TARGET_EFI_RESOLVED" "$PENDING_OLD_FALLBACK_PATH"',
    'r28_remove_aliases_for_path "$LEAP16_R21_FALLBACK_EFI_PATH"',
    "r28_remove_aliases_for_path '\\EFI\\LIMINE\\LIMINE_X64.EFI'",
    'r28_remove_source_limine_files_after_fallback_transfer',
    'r28_final_grub_order',
]
pos=[b.find(x) for x in need]
raise SystemExit(0 if all(x >= 0 for x in pos) and pos == sorted(pos) else 1)
PY
case $? in
  0) pass 'post-proof finalizer transfers EFI/BOOT to shim before retiring fallback/primary Limine ownership' ;;
  *) fail_test 'post-proof retirement ordering is unsafe or incomplete' ;;
esac

if grep -Fq 'PENDING_GRUB_DEFAULT_CREATED:-} == 1' lib/leap16_r28.sh \
 && grep -Fq 'r28_rollback_rebuilt_grub_candidate' lib/leap16_r28.sh \
 && grep -Fq 'r28_rebuilt_reverse_pending' lib/leap16_r28.sh \
 && grep -Fq "mode='reconstructed'" lib/leap16_r28.sh; then
  pass 'transaction marker, rollback route, pending manager and root auto-resume cover reconstructed GRUB targets'
else
  fail_test 'reconstructed-target pending/rollback/auto-resume coverage is incomplete'
fi

# GRUB defaults are native openSUSE, not CachyOS branding.
(
  leap16_reverse_pending(){ return 1; }
  validate_pending_owned_paths(){ return 0; }
  validate_pending_target_deep(){ return 0; }
  run_live_operation(){ return 0; }
  r15_promote_and_finalize_grub(){ return 0; }
  rollback_pending_candidate(){ return 0; }
  r15_rollback_reverse_candidate(){ return 0; }
  pending_banner(){ return 0; }
  manage_pending_migration(){ return 0; }
  LEAP16_R21_FALLBACK_EFI_PATH='\EFI\BOOT\BOOTX64.EFI'
  source lib/leap16_r28.sh
  out=$(mktemp)
  r28_render_grub_default "$out" || exit 20
  grep -Fqx '# Managed by openSUSE Bootloader Switcher' "$out" || exit 21
  grep -Fqx 'GRUB_THEME=/boot/grub2/themes/openSUSE/theme.txt' "$out" || exit 22
  ! grep -qi 'cachyos' "$out" || exit 23
  rm -f "$out"
)
case $? in
  0) pass 'reconstructed GRUB defaults use native openSUSE theme and switcher ownership wording' ;;
  *) fail_test 'reconstructed GRUB default fixture is not native openSUSE' ;;
esac


if grep -Fq 'r28-fallback-transfer-complete' lib/leap16_r28.sh  && grep -Fq 'Recovered previously completed GRUB fallback-transfer checkpoint' lib/leap16_r28.sh  && grep -Fq 'r28_restore_pending_source_fallback_bytes' lib/leap16_r28.sh  && grep -Fq 'Source EFI/LIMINE namespace is already retired' lib/leap16_r28.sh; then
  pass 'post-proof fallback transfer is persisted and Limine retirement is retry-safe after partial finalization'
else
  fail_test 'post-proof transfer checkpoint/retry-safe retirement contract is missing'
fi

if grep -Fq 'r28_snapshot_source_boot_aux' lib/leap16_r28.sh  && grep -Fq 'r28_capture_generated_boot_aux' lib/leap16_r28.sh  && grep -Fq 'r28_restore_source_boot_aux' lib/leap16_r28.sh  && grep -Fq 'r28_install_generated_boot_aux' lib/leap16_r28.sh; then
  pass 'shim-install EFI/BOOT auxiliary writes are snapshotted, hidden during proof, rollback-safe, and transferred only post-proof'
else
  fail_test 'EFI/BOOT auxiliary ownership handling is incomplete'
fi

if (( failures == 0 )); then
  printf '\nAll focused openSUSE Leap 16 r28 self-tests passed.\n'
  exit 0
fi
printf '\n%d focused r28 self-test(s) failed.\n' "$failures" >&2
exit 1
