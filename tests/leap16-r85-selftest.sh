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
  [[ $SWITCHER_RELEASE == leap16-r85 ]] || fail_test 'r85 release not loaded'
  matrix=$(leap16_r64_print_matrix)
  [[ $matrix == *'matrix — leap16-r85'* ]] || fail_test 'matrix heading is stale'
  [[ $matrix == *'rEFInd         HW-PROVEN    HW-PROVEN    HW-PENDING'* ]] || fail_test 'rEFInd live row does not preserve pending systemd edge'
)

# Exact r84 hardware regression: source rEFInd Boot0001, target systemd Boot0000,
# BootNext consumed, persistent recovery-first BootOrder=0001,0000.  The final
# runtime dispatcher must hit r85 rather than the ancient Limine validator.
(
  source_effective_stack
  PENDING_SOURCE=refind
  PENDING_TARGET=systemd-boot
  PENDING_PHASE=boot-armed
  PENDING_TARGET_BOOT_ID=0000
  PENDING_OLD_BOOT_ID=0001
  PENDING_TARGET_EFI_PATH='\\EFI\\systemd\\systemd-bootx64.efi'
  PENDING_TARGET_EFI_RESOLVED=/mock/EFI/systemd/systemd-bootx64.efi
  PENDING_TARGET_EFI_HASH=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  PENDING_BACKUP_PATH=''
  PENDING_REASON=''
  BOOTLOADER=systemd-boot
  BOOT_CURRENT=0000
  calls=''

  validate_pending_compatibility(){ calls="$calls compat"; return 0; }
  detect_bootloader(){ BOOTLOADER=systemd-boot; BOOT_CURRENT=0000; calls="$calls detect"; }
  bootloader_display_name(){ printf '%s' "$1"; }
  nvram_id_matches_path(){ [[ ${1^^} == 0000 && $2 == "$PENDING_TARGET_EFI_PATH" ]]; }
  leap16_nvram_entry_matches_current_esp(){ [[ ${1^^} == 0000 ]]; }
  leap16_require_sudo_session(){ calls="$calls sudo-session"; return 0; }
  run_validation(){ [[ $1 == preflight ]]; calls="$calls preflight"; return 0; }
  pending_bootnext_id(){ return 0; }
  leap16_current_boot_order(){ printf '0001,0000\n'; }
  pending_validate_running_kernel(){ calls="$calls kernel"; return 0; }
  pending_validate_runtime_cmdline_against_source(){ calls="$calls cmdline"; return 0; }
  verify_pending_candidate_ownership_unchanged(){ calls="$calls candidate"; return 0; }
  leap16_r34_validate_systemd_boot_chain(){ [[ $1 == runtime ]]; calls="$calls systemd-deep"; return 0; }
  leap16_r64_verify_refind_source_passive(){ calls="$calls refind-passive"; return 0; }
  pending_set_phase(){ [[ $1 == runtime-validated ]] || return 1; PENDING_PHASE=runtime-validated; calls="$calls phase"; return 0; }
  pending_capture_runtime_diagnostics(){ printf '/mock/runtime-pass-systemd-from-refind\n'; }
  r35_write_local_transaction_result(){ calls="$calls result"; return 0; }
  ok(){ :; }
  warn(){ :; }
  fail(){ printf 'unexpected fail: %s\n' "$*" >&2; return 1; }

  # Reproduce the r84 fall-through first: the captured pre-r85 stack must
  # reject this real systemd session through the stale Limine-only validator.
  oldf=$(mktemp); outf=$(mktemp); trap 'rm -f "$oldf" "$outf"' EXIT
  if validate_pending_target_runtime_pre_leap16_r85 >"$oldf" 2>&1; then
    fail_test 'fixture did not reproduce the r84 stale runtime-dispatch failure'
  fi
  grep -Fq 'not Limine' "$oldf" || fail_test 'r84 reproduction did not reach the stale Limine validator'

  validate_pending_target_runtime >"$outf" || fail_test 'exact r84 target-arrival topology still failed runtime dispatch'
  out=$(cat "$outf")
  [[ $PENDING_PHASE == runtime-validated ]] || fail_test 'runtime proof did not persist phase'
  [[ $calls == *'systemd-deep'* && $calls == *'refind-passive'* ]] || fail_test 'systemd/refind runtime gates were not both reached'
  [[ $out == *'RUNTIME-VALIDATED rEFInd -> systemd-boot'* ]] || fail_test 'r85 success marker missing'
  [[ $out != *'not Limine'* ]] || fail_test 'stale Limine validator still reached'
)

# Restored-systemd targets from rEFInd use the exact same runtime proof path;
# backup provenance must not change dispatcher selection.
(
  source_effective_stack
  PENDING_SOURCE=refind; PENDING_TARGET=systemd-boot; PENDING_BACKUP_PATH=/mock/systemd-backup
  leap16_r85_refind_systemd_pending || fail_test 'restore-backed rEFInd -> systemd edge was not recognized'
)


# The already-implemented r64 finalizer must still own this exact direction;
# r85 repairs proof dispatch only and does not replace retirement semantics.
(
  source_effective_stack
  PENDING_SOURCE=refind; PENDING_TARGET=systemd-boot
  hit=''
  leap16_r64_pending_edge(){ return 0; }
  leap16_r64_finalize_refind_to_systemd(){ hit=systemd-finalizer; return 0; }
  r26_finalize_adapter_transaction || fail_test 'r64 systemd finalizer dispatch failed'
  [[ $hit == systemd-finalizer ]] || fail_test 'rEFInd -> systemd did not reach r64 finalizer'
)

# Every unrelated direction must delegate to the previously effective runtime
# stack.  This protects already-proven edges from r85 collateral changes.
(
  source_effective_stack
  PENDING_SOURCE=grub; PENDING_TARGET=systemd-boot
  hit=''
  leap16_r85_validate_refind_systemd_runtime(){ fail_test 'r85 stole unrelated edge'; }
  validate_pending_target_runtime_pre_leap16_r85(){ hit=delegated; return 0; }
  validate_pending_target_runtime || fail_test 'delegated runtime validator failed'
  [[ $hit == delegated ]] || fail_test 'unrelated edge did not delegate'
)

# First-proof safety: rEFInd must still be persistent-first.  Target-first is
# tolerated only on a runtime-validated retry after proof has already persisted.
(
  source_effective_stack
  PENDING_SOURCE=refind; PENDING_TARGET=systemd-boot; PENDING_PHASE=boot-armed
  PENDING_TARGET_BOOT_ID=0000; PENDING_OLD_BOOT_ID=0001
  PENDING_TARGET_EFI_PATH='\\EFI\\systemd\\systemd-bootx64.efi'; PENDING_REASON=''
  BOOTLOADER=systemd-boot; BOOT_CURRENT=0000
  validate_pending_compatibility(){ return 0; }
  detect_bootloader(){ BOOTLOADER=systemd-boot; BOOT_CURRENT=0000; }
  bootloader_display_name(){ printf '%s' "$1"; }
  nvram_id_matches_path(){ return 0; }
  leap16_nvram_entry_matches_current_esp(){ return 0; }
  leap16_require_sudo_session(){ return 0; }
  run_validation(){ return 0; }
  pending_bootnext_id(){ return 0; }
  leap16_current_boot_order(){ printf '0000,0001\n'; }
  fail(){ return 1; }
  ok(){ :; }; warn(){ :; }
  ! leap16_r85_validate_refind_systemd_runtime >/dev/null 2>&1 || fail_test 'boot-armed proof accepted target-first persistent order'
)

printf 'leap16-r85 selftest: PASS\n'
