#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"
ov="$ROOT/lib/leap16_r57.sh"
grep -Fq 'SWITCHER_RELEASE="leap16-r57"' "$main"
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r57.sh"' "$main"
grep -Fq 'Boot#### IDs remain diagnostics, not a reboot-stability contract' "$ov"
grep -Fq 'Re-arm the exact canonical Limine one-shot + automatic resume' "$ov"
! grep -Eq 'efibootmgr[[:space:]]+-b|rm[[:space:]]+-rf' "$ov"

# Synthetic identity gate: the complete baseline ID set must not constrain the
# current exact-path identity. 0 or 1 current alias passes; 2 is ambiguous.
(
  fail(){ echo "FAILMSG: $*" >&2; return 1; }
  ok(){ :; }
  leap16_r51_pending(){ return 0; }
  leap16_r51_fallback_staged(){ return 1; }
  leap16_r51_pending_menu(){ :; }
  leap16_r51_plan(){ :; }
  r21_create_or_adopt_fallback_alias(){ :; }
  r21_remove_staging_fallback_aliases(){ :; }
  r21_hash_privileged(){ printf '%s\n' "$EXPECTED_HASH"; }
  leap16_r53_current_fallback_ids(){ [[ -n ${CURRENT_IDS:-} ]] && printf '%s\n' $CURRENT_IDS || :; }
  leap16_r56_validate_current_fallback_alias(){ [[ $1 =~ ^[0-9A-F]{4}$ ]]; }
  leap16_boot_entry_is_active(){ :; }
  leap16_nvram_entry_matches_current_esp(){ :; }
  nvram_id_matches_path(){ :; }
  PENDING_OLD_FALLBACK_PATH=/esp/EFI/BOOT/BOOTX64.EFI
  PENDING_OLD_FALLBACK_HASH=deadbeef
  PENDING_TARGET_EFI_HASH=cafebabe
  PENDING_OLD_BOOT_ID=0005
  PENDING_TARGET_BOOT_ID=0000
  PENDING_PHASE=boot-armed
  LEAP16_R21_FALLBACK_EFI_PATH='\EFI\BOOT\BOOTX64.EFI'
  EXPECTED_HASH=deadbeef
  source "$ov"

  CURRENT_IDS=''
  leap16_r53_verify_pretransfer_fallback_alias_set
  CURRENT_IDS='0006'
  leap16_r53_verify_pretransfer_fallback_alias_set
  CURRENT_IDS='0009'
  leap16_r53_verify_pretransfer_fallback_alias_set
  CURRENT_IDS=$'0006\n0009'
  if leap16_r53_verify_pretransfer_fallback_alias_set >/dev/null 2>&1; then
      echo 'FAIL: two current fallback identities were accepted'
      exit 1
  fi
  EXPECTED_HASH=bad
  CURRENT_IDS='0006'
  if leap16_r53_verify_pretransfer_fallback_alias_set >/dev/null 2>&1; then
      echo 'FAIL: changed pre-transfer fallback payload was accepted'
      exit 1
  fi
)

# Synthetic pending-menu recovery: boot-armed + BootNext consumed + source
# current must expose and execute the existing safe primary re-arm helper.
(
  CALLED=0
  leap16_r51_pending(){ return 0; }
  leap16_r51_fallback_staged(){ return 1; }
  leap16_r51_pending_menu(){ :; }
  leap16_r51_plan(){ :; }
  r21_create_or_adopt_fallback_alias(){ :; }
  r21_remove_staging_fallback_aliases(){ :; }
  detect_bootloader(){ BOOTLOADER=systemd-boot; BOOT_CURRENT=0005; }
  pending_bootnext_id(){ printf '\n'; }
  show_pending_details(){ :; }
  leap16_r51_rearm_primary(){ CALLED=1; }
  leap16_require_sudo_session(){ :; }
  verify_pending_source_recovery_unchanged(){ :; }
  verify_pending_candidate_ownership_unchanged(){ :; }
  validate_pending_target_deep(){ :; }
  leap16_r51_rollback_candidate(){ :; }
  PENDING_PHASE=boot-armed
  PENDING_OLD_BOOT_ID=0005
  PENDING_TARGET_BOOT_ID=0000
  source "$ov"
  leap16_r51_pending_menu <<<"1"
  [[ $CALLED == 1 ]] || { echo 'FAIL: consumed one-shot did not reach safe re-arm helper'; exit 1; }
)

echo 'PASS: leap16-r57 identity fallback + consumed one-shot re-arm regression'
