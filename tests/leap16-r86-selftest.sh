#!/usr/bin/env bash
set -eu
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"
fail_test(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
source_effective_stack(){
  local prelude
  prelude=$(awk '/^select_target_bootloader\(\)/{exit} {print}' "$main" | sed '/^SCRIPT_DIR=/d')
  SCRIPT_DIR=$ROOT
  eval "$prelude"
}

(
  source_effective_stack
  [[ $SWITCHER_RELEASE == leap16-r86 ]] || fail_test 'r86 release not loaded'
  matrix=$(leap16_r64_print_matrix)
  [[ $matrix == *'matrix — leap16-r86'* ]] || fail_test 'matrix heading is stale'
)

# Exact hardware recovery state: rEFInd Boot0001 staged systemd Boot0000,
# BootNext consumed, exact systemd target currently running, phase boot-armed.
# First prove the pre-r86 interactive dispatcher still reaches stale
# GRUB2/Limine wording, then prove r86 intercepts it and reaches r85 runtime.
(
  source_effective_stack
  PENDING_FORMAT=${R26_PENDING_FORMAT:-5}
  PENDING_SOURCE=refind; PENDING_TARGET=systemd-boot; PENDING_PHASE=boot-armed
  PENDING_TARGET_BOOT_ID=0000; PENDING_OLD_BOOT_ID=0001
  PENDING_REASON=''; PENDING_BACKUP_PATH=''
  BOOTLOADER=systemd-boot; BOOT_CURRENT=0000
  pending_exists(){ return 0; }
  load_pending_state(){ return 0; }
  validate_pending_compatibility(){ return 0; }
  detect_bootloader(){ BOOTLOADER=systemd-boot; BOOT_CURRENT=0000; }
  show_pending_details(){ :; }
  pending_bootnext_id(){ return 0; }
  r26_resume_service_state(){ printf 'not-found\n'; }
  leap16_require_sudo_session(){ return 0; }
  hit=''
  validate_pending_target_runtime(){ hit=runtime; return 0; }
  fail(){ printf '[FAIL] %s\n' "$*"; return 1; }

  oldf=$(mktemp); newf=$(mktemp); trap 'rm -f "$oldf" "$newf"' EXIT
  if manage_pending_migration_pre_leap16_r86 >"$oldf" 2>&1 </dev/null; then
    fail_test 'pre-r86 manager unexpectedly accepted exact systemd target'
  fi
  grep -Fq 'Current bootloader is neither the recorded GRUB2 source nor Limine target' "$oldf" \
    || fail_test 'exact r85 stale pending-dispatch failure was not reproduced'

  manage_pending_migration >"$newf" 2>&1 <<<'1' || fail_test 'r86 target boot-armed pending manager failed'
  [[ $hit == runtime ]] || fail_test 'r86 did not route target session to runtime validator'
  grep -Fq 'exact native openSUSE systemd-boot target Boot0000 is running' "$newf" \
    || fail_test 'direction-correct target menu was not rendered'
  ! grep -Fq 'GRUB2 source nor Limine target' "$newf" || fail_test 'stale Limine manager leaked through r86'
)

# Once runtime proof is persisted, the same target session must expose the
# unchanged r64 adapter finalizer rather than another stale manager.
(
  source_effective_stack
  PENDING_FORMAT=${R26_PENDING_FORMAT:-5}
  PENDING_SOURCE=refind; PENDING_TARGET=systemd-boot; PENDING_PHASE=runtime-validated
  PENDING_TARGET_BOOT_ID=0000; PENDING_OLD_BOOT_ID=0001; PENDING_REASON=''
  BOOTLOADER=systemd-boot; BOOT_CURRENT=0000
  pending_exists(){ return 0; }; load_pending_state(){ return 0; }; validate_pending_compatibility(){ return 0; }
  detect_bootloader(){ BOOTLOADER=systemd-boot; BOOT_CURRENT=0000; }
  show_pending_details(){ :; }; r26_resume_service_state(){ printf 'not-found\n'; }
  leap16_current_boot_order(){ printf '0001,0000\n'; }
  leap16_require_sudo_session(){ return 0; }
  hit=''; r26_finalize_adapter_transaction(){ hit=finalizer; return 0; }
  fail(){ printf '[FAIL] %s\n' "$*"; return 1; }
  manage_pending_migration >/dev/null 2>&1 <<<'2' || fail_test 'r86 runtime-validated target menu failed'
  [[ $hit == finalizer ]] || fail_test 'r86 did not route persisted proof to unchanged r64 finalizer'
)

# Source-side continuation also needs to be direction-correct.  This covers a
# fresh candidate and therefore both live and restore-backed transactions.
(
  source_effective_stack
  PENDING_FORMAT=${R26_PENDING_FORMAT:-5}
  PENDING_SOURCE=refind; PENDING_TARGET=systemd-boot; PENDING_PHASE=candidate-ready
  PENDING_TARGET_BOOT_ID=0000; PENDING_OLD_BOOT_ID=0001; PENDING_REASON=''
  BOOTLOADER=refind; BOOT_CURRENT=0001
  pending_exists(){ return 0; }; load_pending_state(){ return 0; }; validate_pending_compatibility(){ return 0; }
  detect_bootloader(){ BOOTLOADER=refind; BOOT_CURRENT=0001; }
  show_pending_details(){ :; }; leap16_require_sudo_session(){ return 0; }
  hit=''; r26_rearm_candidate_with_resume(){ hit=arm; return 0; }
  fail(){ printf '[FAIL] %s\n' "$*"; return 1; }
  manage_pending_migration >/dev/null 2>&1 <<<'2' || fail_test 'r86 source candidate menu failed'
  [[ $hit == arm ]] || fail_test 'r86 source candidate did not reach generic safe arm+resume helper'
)

# Backup provenance must not alter dispatcher selection: restore-backed
# rEFInd -> systemd-boot uses the exact same pending state machine.
(
  source_effective_stack
  PENDING_FORMAT=${R26_PENDING_FORMAT:-5}; PENDING_SOURCE=refind; PENDING_TARGET=systemd-boot
  PENDING_BACKUP_PATH=/mock/systemd-backup
  leap16_r86_refind_systemd_pending || fail_test 'restore-backed pending edge was not recognized'
)

# Unrelated already-proven edges remain delegated byte-for-byte.
(
  source_effective_stack
  PENDING_SOURCE=grub; PENDING_TARGET=systemd-boot
  pending_exists(){ return 0; }; load_pending_state(){ return 0; }; validate_pending_compatibility(){ return 0; }
  hit=''; manage_pending_migration_pre_leap16_r86(){ hit=delegated; return 0; }
  manage_pending_migration || fail_test 'unrelated pending edge delegation failed'
  [[ $hit == delegated ]] || fail_test 'r86 stole an unrelated pending edge'
)

printf 'leap16-r86 selftest: PASS\n'
