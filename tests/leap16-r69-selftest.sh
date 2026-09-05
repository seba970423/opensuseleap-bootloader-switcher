#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"
layer="$ROOT/lib/leap16_r69.sh"
fail_test(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ -f $layer ]] || fail_test 'r69 layer missing'
grep -Fq 'SWITCHER_RELEASE="leap16-r69"' "$main" || fail_test 'release is not r69'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r69.sh"' "$main" || fail_test 'r69 layer is not sourced'

source_effective_stack(){
  local prelude
  prelude=$(awk '/^select_target_bootloader\(\)/{exit} {print}' "$main" | sed '/^SCRIPT_DIR=/d')
  SCRIPT_DIR=$ROOT
  eval "$prelude"
}

# 1) Exact hardware regression: GRUB -> rEFInd, phase boot-armed, canonical
# rEFInd BootCurrent, BootNext consumed. Selector [2] must reach r68 runtime
# validation and must never delegate into the historical Limine manager.
(
  set -u
  source_effective_stack
  PENDING_FORMAT=${R26_PENDING_FORMAT:-5}; PENDING_SOURCE=grub; PENDING_TARGET=refind
  PENDING_PHASE=boot-armed; PENDING_OLD_BOOT_ID=0002; PENDING_TARGET_BOOT_ID=0005; PENDING_REASON=''
  BOOTLOADER=refind; BOOT_CURRENT=0005; CALLED=''
  pending_exists(){ return 0; }
  validate_pending_compatibility(){ return 0; }
  detect_bootloader(){ BOOTLOADER=refind; BOOT_CURRENT=0005; }
  show_pending_details(){ :; }
  pending_bootnext_id(){ return 0; }
  leap16_require_sudo_session(){ return 0; }
  validate_pending_target_runtime(){ CALLED=runtime; }
  manage_pending_migration_pre_leap16_r69(){ fail_test 'inbound rEFInd manager fell through to inherited Limine manager'; }
  bootloader_display_name(){ [[ $1 == grub ]] && printf GRUB2 || printf '%s' "$1"; }
  fail(){ return 1; }
  manage_pending_migration >/dev/null <<< '1' || fail_test 'exact r68 hardware state was rejected by r69 manager'
  [[ $CALLED == runtime ]] || fail_test 'selector [2] did not reach rEFInd runtime validator'
)

# 2) After runtime proof in the exact target session, manager must expose and
# dispatch ownership-gated finalization rather than a Limine-specific action.
(
  set -u
  source_effective_stack
  PENDING_FORMAT=${R26_PENDING_FORMAT:-5}; PENDING_SOURCE=grub; PENDING_TARGET=refind
  PENDING_PHASE=runtime-validated; PENDING_OLD_BOOT_ID=0002; PENDING_TARGET_BOOT_ID=0005; PENDING_REASON=''
  BOOTLOADER=refind; BOOT_CURRENT=0005; CALLED=''
  pending_exists(){ return 0; }
  validate_pending_compatibility(){ return 0; }
  detect_bootloader(){ BOOTLOADER=refind; BOOT_CURRENT=0005; }
  show_pending_details(){ :; }
  leap16_current_boot_order(){ printf '0002,0000,0005\n'; }
  leap16_require_sudo_session(){ return 0; }
  r26_finalize_adapter_transaction(){ CALLED=finalize; }
  bootloader_display_name(){ [[ $1 == grub ]] && printf GRUB2 || printf '%s' "$1"; }
  fail(){ return 1; }
  manage_pending_migration >/dev/null <<< '2' || fail_test 'runtime-validated rEFInd target manager failed'
  [[ $CALLED == finalize ]] || fail_test 'runtime-validated target did not dispatch r64 ownership-gated finalizer'
)

# 3) Candidate-ready source session remains able to arm the generic adapter
# transaction, and non-rEFInd pending directions are delegated unchanged.
(
  set -u
  source_effective_stack
  PENDING_FORMAT=${R26_PENDING_FORMAT:-5}; PENDING_SOURCE=grub; PENDING_TARGET=refind
  PENDING_PHASE=candidate-ready; PENDING_OLD_BOOT_ID=0002; PENDING_TARGET_BOOT_ID=0005; PENDING_REASON=''
  BOOTLOADER=grub; BOOT_CURRENT=0002; CALLED=''
  pending_exists(){ return 0; }
  validate_pending_compatibility(){ return 0; }
  detect_bootloader(){ BOOTLOADER=grub; BOOT_CURRENT=0002; }
  show_pending_details(){ :; }
  leap16_require_sudo_session(){ return 0; }
  r26_rearm_candidate_with_resume(){ CALLED=rearm; }
  bootloader_display_name(){ [[ $1 == grub ]] && printf GRUB2 || printf '%s' "$1"; }
  fail(){ return 1; }
  manage_pending_migration >/dev/null <<< '2' || fail_test 'candidate-ready inbound rEFInd source manager failed'
  [[ $CALLED == rearm ]] || fail_test 'candidate-ready source did not use generic adapter re-arm'

  PENDING_TARGET=systemd-boot; CALLED=''
  manage_pending_migration_pre_leap16_r69(){ CALLED=legacy; }
  manage_pending_migration >/dev/null
  [[ $CALLED == legacy ]] || fail_test 'non-rEFInd pending direction was not delegated unchanged'
)

# 4) An unrelated BootNext while canonical rEFInd is running must fail closed.
(
  set -u
  source_effective_stack
  PENDING_FORMAT=${R26_PENDING_FORMAT:-5}; PENDING_SOURCE=grub; PENDING_TARGET=refind
  PENDING_PHASE=boot-armed; PENDING_OLD_BOOT_ID=0002; PENDING_TARGET_BOOT_ID=0005; PENDING_REASON=''
  BOOTLOADER=refind; BOOT_CURRENT=0005
  pending_exists(){ return 0; }
  validate_pending_compatibility(){ return 0; }
  detect_bootloader(){ BOOTLOADER=refind; BOOT_CURRENT=0005; }
  show_pending_details(){ :; }
  pending_bootnext_id(){ printf '0009\n'; }
  fail(){ return 1; }
  ! manage_pending_migration >/dev/null 2>&1 || fail_test 'unrelated BootNext was accepted in active rEFInd target session'
)

# 5) Historical r67 result must be rendered as dispatcher failure while the
# exact inbound-rEFInd transaction remains pending, not as an rEFInd proof fail.
(
  set -u
  source_effective_stack
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  PENDING_STATE_DIR=$td; R22_RESULT_FILE_NAME=last-auto-result.txt
  printf 'detail=The automatically booted refind target failed runtime proof; source cleanup was not attempted.\n' >"$td/last-auto-result.txt"
  PENDING_FORMAT=${R26_PENDING_FORMAT:-5}; PENDING_SOURCE=grub; PENDING_TARGET=refind; PENDING_REASON=''
  pending_exists(){ return 0; }
  validate_pending_compatibility(){ return 0; }
  r22_show_last_auto_result_pre_leap16_r69(){ fail_test 'historical r67 result fell through to misleading renderer'; }
  out=$(r22_show_last_auto_result)
  [[ $out == *'Historical r67 resume-dispatch failure'* ]] || fail_test 'historical dispatcher failure note missing'
  [[ $out == *'source cleanup was not attempted'* ]] || fail_test 'historical no-cleanup boundary missing'
)

# 6) Matrix stays HW-PENDING but records the r68 interactive-manager safe-fail.
(
  source_effective_stack
  matrix=$(leap16_r64_print_matrix)
  [[ $matrix == *'openSUSE Leap 16 bootloader matrix — leap16-r69'* ]] || fail_test 'matrix heading is not r69'
  [[ $matrix == *'r68 selector [2]'* && $matrix == *'historical GRUB2 -> Limine pending manager'* ]] || fail_test 'r68 interactive manager failure missing from r69 matrix'
)

printf 'PASS: leap16-r69 inbound rEFInd pending-manager/finalization routing regression\n'
