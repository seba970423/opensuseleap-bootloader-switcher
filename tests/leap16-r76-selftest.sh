#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"
layer="$ROOT/lib/leap16_r76.sh"
fail_test(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f $layer ]] || fail_test 'r76 layer missing'
grep -Fq 'SWITCHER_RELEASE="leap16-r76"' "$main" || fail_test 'release is not r76'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r76.sh"' "$main" || fail_test 'r76 layer is not sourced'
[[ $(grep -n 'source "$SCRIPT_DIR/lib/leap16_r76.sh"' "$main" | tail -n1 | cut -d: -f1) -gt \
   $(grep -n 'source "$SCRIPT_DIR/lib/leap16_r75.sh"' "$main" | tail -n1 | cut -d: -f1) ]] \
    || fail_test 'r76 is not the final release layer'
grep -Fq 'leap16_r64_validate_grub_candidate' "$layer" || fail_test 'native GRUB candidate gate is missing'
grep -Fq 'validate_grub_boot_chain runtime' "$layer" || fail_test 'native GRUB runtime gate is missing'
grep -Fq 'leap16_r64_verify_refind_source_passive' "$layer" || fail_test 'passive rEFInd recovery gate is missing'
grep -Fq 'leap16_r64_validate_grub_direct_alias' "$layer" || fail_test 'direct-GRUB recovery gate is missing'
! grep -Eq '(^|[;&|[:space:]])(mkinitcpio|grub-install)([;&|[:space:]]|$)|/boot/grub([^2]|$)|bootloader-id=cachyos' "$layer" \
    || fail_test 'r76 layer invokes an Arch/CachyOS GRUB primitive'

source_effective_stack(){
  local prelude
  prelude=$(awk '/^select_target_bootloader\(\)/{exit} {print}' "$main" | sed '/^SCRIPT_DIR=/d')
  SCRIPT_DIR=$ROOT
  eval "$prelude"
}

# 1) The exact missing outbound direction reaches r76. All other directions
# delegate to the previously effective runtime stack.
(
  source_effective_stack
  PENDING_FORMAT=${R26_PENDING_FORMAT:-5}; PENDING_SOURCE=refind; PENDING_TARGET=grub; called=''
  leap16_r76_validate_refind_grub_runtime(){ called=r76; }
  validate_pending_target_runtime
  [[ $called == r76 ]] || fail_test 'refind:grub did not dispatch to r76 runtime validator'

  PENDING_SOURCE=grub; PENDING_TARGET=refind; called=''
  validate_pending_target_runtime_pre_leap16_r76(){ called=previous; }
  validate_pending_target_runtime
  [[ $called == previous ]] || fail_test 'non-refind:grub runtime direction was not delegated unchanged'
)

# 2) Reproduce the r75 hardware shape. Exact GRUB target + consumed BootNext +
# source-first BootOrder must execute every native/passive proof and persist the
# phase. Nothing here stages, repairs, promotes, or retires the source.
(
  source_effective_stack
  PENDING_FORMAT=${R26_PENDING_FORMAT:-5}; PENDING_SOURCE=refind; PENDING_TARGET=grub
  PENDING_PHASE=boot-armed; PENDING_OLD_BOOT_ID=0000; PENDING_TARGET_BOOT_ID=0002
  PENDING_TARGET_EFI_PATH='\EFI\OPENSUSE\SHIM.EFI'; PENDING_REASON=''; BOOTLOADER=grub; BOOT_CURRENT=0002
  trace=''
  mark(){ trace="${trace:+$trace,}$1"; }
  validate_pending_compatibility(){ mark compat; return 0; }
  detect_bootloader(){ BOOTLOADER=grub; BOOT_CURRENT=0002; mark detect; }
  nvram_id_matches_path(){ [[ $1 == 0002 && $2 == '\EFI\OPENSUSE\SHIM.EFI' ]]; }
  leap16_nvram_entry_matches_current_esp(){ [[ $1 == 0002 ]]; }
  leap16_require_sudo_session(){ mark sudo; }
  run_validation(){ [[ $1 == preflight ]]; mark preflight; }
  pending_bootnext_id(){ return 0; }
  leap16_current_boot_order(){ printf '0000,0002\n'; }
  pending_validate_running_kernel(){ mark kernel; }
  pending_validate_runtime_cmdline_against_source(){ mark cmdline; }
  verify_pending_candidate_ownership_unchanged(){ mark ownership; }
  leap16_r64_validate_grub_candidate(){ mark candidate; }
  validate_grub_boot_chain(){ [[ $1 == runtime ]]; mark grub-runtime; }
  leap16_r64_verify_refind_source_passive(){ mark passive-refind; }
  leap16_r64_validate_grub_direct_alias(){ mark direct; }
  pending_set_phase(){ [[ $1 == runtime-validated ]]; mark phase; }
  pending_capture_runtime_diagnostics(){ mark diagnostics; }
  r35_write_local_transaction_result(){ mark result; }
  ok(){ :; }; warn(){ :; }; fail(){ printf 'unexpected fail: %s\n' "$*" >&2; return 1; }
  bootloader_display_name(){ printf '%s' "$1"; }

  leap16_r76_validate_refind_grub_runtime >/dev/null || fail_test 'r75 hardware-shape runtime continuation failed'
  [[ $PENDING_PHASE == runtime-validated ]] || fail_test 'runtime-validated phase was not persisted in memory'
  for required in compat detect sudo preflight kernel cmdline ownership candidate grub-runtime passive-refind direct phase result; do
    [[ ,$trace, == *,$required,* ]] || fail_test "runtime continuation skipped $required ($trace)"
  done
)

# 3) Wrong target identity and unrelated BootNext fail before proof/phase writes.
(
  source_effective_stack
  PENDING_FORMAT=${R26_PENDING_FORMAT:-5}; PENDING_SOURCE=refind; PENDING_TARGET=grub
  PENDING_PHASE=boot-armed; PENDING_OLD_BOOT_ID=0000; PENDING_TARGET_BOOT_ID=0002
  PENDING_TARGET_EFI_PATH='\EFI\OPENSUSE\SHIM.EFI'; PENDING_REASON=''; BOOTLOADER=grub; BOOT_CURRENT=0002
  validate_pending_compatibility(){ return 0; }
  detect_bootloader(){ BOOTLOADER=grub; BOOT_CURRENT=0002; }
  nvram_id_matches_path(){ return 0; }
  leap16_nvram_entry_matches_current_esp(){ return 0; }
  leap16_require_sudo_session(){ return 0; }
  run_validation(){ return 0; }
  pending_bootnext_id(){ printf '0009\n'; }
  pending_set_phase(){ fail_test 'unrelated BootNext reached phase write'; }
  fail(){ return 1; }; ok(){ :; }
  ! leap16_r76_validate_refind_grub_runtime >/dev/null 2>&1 || fail_test 'unrelated BootNext was accepted'

  pending_bootnext_id(){ return 0; }
  detect_bootloader(){ BOOTLOADER=grub; BOOT_CURRENT=0007; }
  ! leap16_r76_validate_refind_grub_runtime >/dev/null 2>&1 || fail_test 'wrong BootCurrent was accepted'
)

# 4) The pending manager reaches runtime proof from the stranded target and
# reaches the existing ownership-gated finalizer only after persisted proof.
(
  source_effective_stack
  PENDING_FORMAT=${R26_PENDING_FORMAT:-5}; PENDING_SOURCE=refind; PENDING_TARGET=grub
  PENDING_PHASE=boot-armed; PENDING_OLD_BOOT_ID=0000; PENDING_TARGET_BOOT_ID=0002; PENDING_REASON=''
  BOOTLOADER=grub; BOOT_CURRENT=0002; called=''
  pending_exists(){ return 0; }; load_pending_state(){ return 0; }; validate_pending_compatibility(){ return 0; }
  detect_bootloader(){ BOOTLOADER=grub; BOOT_CURRENT=0002; }
  show_pending_details(){ :; }; pending_bootnext_id(){ return 0; }
  leap16_require_sudo_session(){ return 0; }
  validate_pending_target_runtime(){ called=runtime; }
  manage_pending_migration_pre_leap16_r76(){ fail_test 'refind:grub manager fell through to an inherited manager'; }
  manage_pending_migration >/dev/null <<< '1' || fail_test 'stranded target menu rejected runtime continuation'
  [[ $called == runtime ]] || fail_test 'target menu did not dispatch runtime validation'

  PENDING_PHASE=runtime-validated; called=''
  leap16_current_boot_order(){ printf '0000,0002\n'; }
  r26_finalize_adapter_transaction(){ called=finalize; }
  manage_pending_migration >/dev/null <<< '2' || fail_test 'runtime-validated target menu rejected finalization'
  [[ $called == finalize ]] || fail_test 'target menu did not dispatch the ownership-gated finalizer'
)

# 5) Source-session lifecycle remains direction-correct and nonmatching pending
# directions delegate unchanged.
(
  source_effective_stack
  PENDING_FORMAT=${R26_PENDING_FORMAT:-5}; PENDING_SOURCE=refind; PENDING_TARGET=grub
  PENDING_PHASE=candidate-ready; PENDING_OLD_BOOT_ID=0000; PENDING_TARGET_BOOT_ID=0002; PENDING_REASON=''
  BOOTLOADER=refind; BOOT_CURRENT=0000; called=''
  pending_exists(){ return 0; }; load_pending_state(){ return 0; }; validate_pending_compatibility(){ return 0; }
  detect_bootloader(){ BOOTLOADER=refind; BOOT_CURRENT=0000; }
  show_pending_details(){ :; }; leap16_require_sudo_session(){ return 0; }
  r26_rearm_candidate_with_resume(){ called=rearm; }
  manage_pending_migration >/dev/null <<< '2' || fail_test 'source manager rejected candidate re-arm'
  [[ $called == rearm ]] || fail_test 'source manager did not use generic adapter re-arm'

  PENDING_SOURCE=grub; PENDING_TARGET=refind; called=''
  manage_pending_migration_pre_leap16_r76(){ called=previous; }
  manage_pending_migration >/dev/null
  [[ $called == previous ]] || fail_test 'non-refind:grub pending direction was not delegated unchanged'
)

# 6) Historical failed result is accurately labeled while this exact pending
# transaction exists.
(
  source_effective_stack
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  PENDING_STATE_DIR=$td; R22_RESULT_FILE_NAME=last-auto-result.txt
  printf 'detail=The automatically booted grub target failed runtime proof; source cleanup was not attempted.\n' >"$td/last-auto-result.txt"
  PENDING_FORMAT=${R26_PENDING_FORMAT:-5}; PENDING_SOURCE=refind; PENDING_TARGET=grub; PENDING_REASON=''
  pending_exists(){ return 0; }; validate_pending_compatibility(){ return 0; }
  r22_show_last_auto_result_pre_leap16_r76(){ fail_test 'historical r75 result fell through to misleading renderer'; }
  out=$(r22_show_last_auto_result)
  [[ $out == *'Historical r75 resume-dispatch failure'* ]] || fail_test 'historical dispatch-failure note missing'
  [[ $out == *'source cleanup was not attempted'* ]] || fail_test 'historical no-cleanup boundary missing'
)

# 7) Post-finalization diagnostics accept the real finalized topology and reject
# a surviving source alias.
(
  source_effective_stack
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  PENDING_SOURCE=refind; PENDING_TARGET=grub; PENDING_TARGET_BOOT_ID=0002; BOOT_CURRENT=0002
  R28_GRUB_SHIM_PATH='\EFI\OPENSUSE\SHIM.EFI'; R28_GRUB_DIRECT_PATH='\EFI\OPENSUSE\GRUBX64.EFI'
  LEAP16_R64_REFIND_EFI='\EFI\refind\refind_x64.efi'
  leap16_current_boot_order(){ printf '0002,0001\n'; }
  pending_bootnext_id(){ return 0; }
  leap16_r64_grub_direct_id(){ printf '0001\n'; }
  leap16_r48_ids_for_current_esp_path(){ return 0; }
  boot_id_exists(){ return 0; }
  nvram_id_matches_path(){ return 0; }
  leap16_nvram_entry_matches_current_esp(){ return 0; }
  leap16_write_firmware_order_report "$td/pass" auto-resume-pass
  grep -Fq 'assessment=pass' "$td/pass" || fail_test 'real finalized refind:grub topology was mislabeled'

  leap16_r48_ids_for_current_esp_path(){ printf '0000\n'; }
  leap16_write_firmware_order_report "$td/fail" auto-resume-pass
  grep -Fq 'assessment=fail' "$td/fail" || fail_test 'surviving rEFInd source alias was not diagnosed'
)

# 8) Evidence ledger advances only the completed inbound rEFInd edge.
(
  source_effective_stack
  matrix=$(leap16_r64_print_matrix)
  [[ $matrix == *'openSUSE Leap 16 bootloader matrix — leap16-r76'* ]] || fail_test 'matrix heading is not r76'
  [[ $matrix == *'GRUB2          —            HW-PROVEN    HW-PROVEN     HW-PROVEN'* ]] || fail_test 'hardware-proven GRUB2 -> rEFInd result is missing'
  [[ $matrix == *'rEFInd         HW-PENDING'* ]] || fail_test 'incomplete rEFInd -> GRUB edge was prematurely promoted'
)

printf 'leap16-r76 selftest: PASS\n'
