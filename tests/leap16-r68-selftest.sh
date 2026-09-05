#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"
layer="$ROOT/lib/leap16_r68.sh"
fail_test(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f $layer ]] || fail_test 'r68 layer missing'
grep -Fq 'SWITCHER_RELEASE="leap16-r68"' "$main" || fail_test 'release is not r68'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r68.sh"' "$main" || fail_test 'r68 layer is not sourced'

source_effective_stack(){
  local prelude
  prelude=$(awk '/^select_target_bootloader\(\)/{exit} {print}' "$main" | sed '/^SCRIPT_DIR=/d')
  SCRIPT_DIR=$ROOT
  eval "$prelude"
}

# 1) Exact r67 regression: inbound * -> rEFInd must dispatch to the Leap-native
# runtime validator and never fall through to the inherited Limine-only one.
(
  set -u
  source_effective_stack
  CALLED=''
  PENDING_FORMAT=${R26_PENDING_FORMAT:-5}; PENDING_SOURCE=grub; PENDING_TARGET=refind
  leap16_r68_validate_refind_target_runtime(){ CALLED=r68-refind; }
  validate_pending_target_runtime_pre_leap16_r68(){ fail_test 'inbound rEFInd dispatch fell through to inherited validator'; }
  validate_pending_target_runtime
  [[ $CALLED == r68-refind ]] || fail_test 'inbound rEFInd runtime dispatch did not select r68 validator'

  PENDING_TARGET=systemd-boot; CALLED=''
  validate_pending_target_runtime_pre_leap16_r68(){ CALLED=legacy; }
  validate_pending_target_runtime
  [[ $CALLED == legacy ]] || fail_test 'non-rEFInd runtime path was not delegated unchanged'
)

# 2) PreviousBoot accepts either the exact versioned Leap kernel or the exact
# /boot/vmlinuz symlink form observed on r67 hardware, but only when that
# symlink resolves to the currently running versioned payload.
(
  set -u
  source_effective_stack
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  mkdir -p "$td/boot"
  printf kernel >"$td/boot/vmlinuz-6.12.0-test"
  ln -s vmlinuz-6.12.0-test "$td/boot/vmlinuz"
  prev="$td/PreviousBoot"
  LEAP16_R68_BOOT_DIR="$td/boot"
  R33_RUNNING_KERNEL_RELEASE=6.12.0-test
  REFIND_PREVIOUS_BOOT_FILE="$prev"
  PENDING_TARGET=refind
  PENDING_OLD_BOOT_EFI_PATH='\EFI\OPENSUSE\SHIM.EFI'
  is_leap16(){ return 0; }
  ok(){ :; }; fail(){ return 1; }

  printf 'Boot \\boot\\vmlinuz-6.12.0-test from root\n' >"$prev"
  r33_verify_refind_direct_kernel_launch || fail_test 'exact versioned PreviousBoot path was rejected'

  printf 'Boot \\boot\\vmlinuz from root\n' >"$prev"
  r33_verify_refind_direct_kernel_launch || fail_test 'exact openSUSE /boot/vmlinuz symlink PreviousBoot was rejected'

  printf other >"$td/boot/vmlinuz-other"
  ln -sfn vmlinuz-other "$td/boot/vmlinuz"
  ! r33_verify_refind_direct_kernel_launch >/dev/null 2>&1 || fail_test 'wrong /boot/vmlinuz symlink target was accepted'

  ln -sfn vmlinuz-6.12.0-test "$td/boot/vmlinuz"
  printf 'Boot \\EFI\\OPENSUSE\\SHIM.EFI and vmlinuz-6.12.0-test\n' >"$prev"
  ! r33_verify_refind_direct_kernel_launch >/dev/null 2>&1 || fail_test 'protected source EFI chainload was accepted as direct-kernel proof'
)

# 3) While the target rEFInd session is BootCurrent, source recovery must be
# validated passively.  An active source adapter validator is forbidden here.
(
  set -u
  source_effective_stack
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  PENDING_FORMAT=${R26_PENDING_FORMAT:-5}; PENDING_SOURCE=grub; PENDING_TARGET=refind
  PENDING_TARGET_BOOT_ID=0005; PENDING_OLD_BOOT_ID=0002; PENDING_OLD_BOOT_EFI_PATH='\EFI\OPENSUSE\SHIM.EFI'
  PENDING_SOURCE_EFI_RESOLVED="$td/shim.efi"; printf shim >"$PENDING_SOURCE_EFI_RESOLVED"; PENDING_SOURCE_EFI_HASH=abc
  PENDING_SOURCE_MANIFEST="$td/source.tsv"; : >"$PENDING_SOURCE_MANIFEST"
  PENDING_OLD_FALLBACK_EXISTED=0; PENDING_OLD_FALLBACK_PATH="$td/nonexistent-fallback"
  BOOTLOADER=refind; BOOT_CURRENT=0005
  boot_id_exists(){ [[ ${1^^} == 0002 ]]; }
  nvram_id_matches_path(){ return 0; }
  leap16_nvram_entry_matches_current_esp(){ return 0; }
  r21_hash_privileged(){ printf 'abc\n'; }
  r26_verify_owned_manifest(){ return 0; }
  leap16_r64_verify_source_alias_superset(){ return 0; }
  have(){ return 1; }
  validate_cachyos_grub_theme(){ return 0; }
  sudo(){ [[ ${1:-} == -n ]] && shift; "$@"; }
  adapter_source_validate(){ fail_test 'active source adapter validator was called from an rEFInd target session'; }
  ok(){ :; }; fail(){ return 1; }
  verify_pending_source_recovery_unchanged || fail_test 'passive GRUB recovery proof failed under rEFInd BootCurrent'
)

# 4) Full r68 runtime choreography mock: canonical target, source-first
# persistent order, kernel/cmdline/PreviousBoot ownership proof, target deep
# validation and passive source proof must all complete and persist phase.
(
  set -u
  source_effective_stack
  PENDING_FORMAT=${R26_PENDING_FORMAT:-5}; PENDING_SOURCE=grub; PENDING_TARGET=refind
  PENDING_PHASE=boot-armed; PENDING_TARGET_BOOT_ID=0005; PENDING_OLD_BOOT_ID=0002
  PENDING_TARGET_EFI_PATH='\EFI\refind\refind_x64.efi'; PENDING_REASON=''
  BOOTLOADER=refind; BOOT_CURRENT=0005; SEQ=''
  validate_pending_compatibility(){ return 0; }
  detect_bootloader(){ BOOTLOADER=refind; BOOT_CURRENT=0005; }
  nvram_id_matches_path(){ return 0; }
  leap16_nvram_entry_matches_current_esp(){ return 0; }
  leap16_require_sudo_session(){ return 0; }
  run_validation(){ SEQ+=" preflight"; }
  pending_bootnext_id(){ return 0; }
  leap16_current_boot_order(){ printf '0002,0005,0000\n'; }
  pending_validate_running_kernel(){ SEQ+=" kernel"; }
  pending_validate_runtime_cmdline_against_source(){ SEQ+=" cmdline"; }
  verify_pending_candidate_ownership_unchanged(){ SEQ+=" candidate"; }
  leap16_r68_normalize_refind_target_aliases_after_proof(){ SEQ+=" aliases"; }
  validate_pending_target_deep(){ SEQ+=" target-deep"; }
  leap16_r68_verify_source_recovery_while_refind_active(){ SEQ+=" source-passive"; }
  pending_set_phase(){ [[ $1 == runtime-validated ]] || return 1; SEQ+=" phase"; }
  pending_capture_runtime_diagnostics(){ :; }
  r35_write_local_transaction_result(){ :; }
  bootloader_display_name(){ printf '%s' "$1"; }
  ok(){ :; }; warn(){ :; }; fail(){ return 1; }
  leap16_r68_validate_refind_target_runtime >/dev/null || fail_test 'mock inbound rEFInd runtime validation failed'
  [[ $PENDING_PHASE == runtime-validated ]] || fail_test 'runtime validator did not persist runtime-validated phase'
  [[ $SEQ == *' preflight kernel cmdline candidate aliases target-deep source-passive phase'* ]] || {
      printf 'sequence:%s\n' "$SEQ" >&2; fail_test 'runtime proof choreography/order changed'; }
)

# 5) Firmware duplicate target aliases may be normalized only when the recorded
# target survives, extras are exact same-path/same-ESP aliases, and their IDs
# were absent from the pre-stage baseline.
(
  set -u
  source_effective_stack
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  BASELINE_FILE="$td/baseline"; printf 'Boot0002* opensuse ...\n' >"$BASELINE_FILE"
  PENDING_FORMAT=${R26_PENDING_FORMAT:-5}; PENDING_SOURCE=grub; PENDING_TARGET=refind
  PENDING_TARGET_BOOT_ID=0005; BOOTLOADER=refind; BOOT_CURRENT=0005
  LEAP16_R64_REFIND_EFI='\EFI\refind\refind_x64.efi'
  ORDER='0002,0005,0006,0000'; IDS='0005 0006'; DELETED=''
  leap16_r64_baseline_path(){ printf '%s\n' "$BASELINE_FILE"; }
  leap16_r48_ids_for_current_esp_path(){ for x in $IDS; do printf '%s\n' "$x"; done; }
  nvram_id_matches_path(){ return 0; }
  leap16_nvram_entry_matches_current_esp(){ return 0; }
  leap16_current_boot_order(){ printf '%s\n' "$ORDER"; }
  leap16_order_has_id(){ case ",$1," in *,"${2^^}",*) return 0;; *) return 1;; esac; }
  boot_id_exists(){ case " $IDS 0002 0000 " in *" ${1^^} "*) return 0;; *) return 1;; esac; }
  sudo(){
    [[ ${1:-} == -n ]] && shift
    if [[ ${1:-} == efibootmgr ]]; then
      shift
      if [[ ${1:-} == -o ]]; then ORDER=$2; return 0; fi
      if [[ ${1:-} == -b ]]; then
        local doomed=${2^^}; DELETED+=" $doomed"; IDS=$(for x in $IDS; do [[ ${x^^} == "$doomed" ]] || printf '%s ' "$x"; done); return 0
      fi
    fi
    command "$@"
  }
  ok(){ :; }; fail(){ return 1; }
  leap16_r68_normalize_refind_target_aliases_after_proof || fail_test 'bounded post-stage duplicate rEFInd alias was not normalized'
  [[ $ORDER == '0002,0005,0000' && $IDS == *0005* && $IDS != *0006* && $DELETED == *0006* ]] || fail_test 'duplicate target normalization did not preserve recorded target/order'

  # Same alias number present in baseline is not transaction-owned and must be refused.
  ORDER='0002,0005,0006,0000'; IDS='0005 0006'; printf 'Boot0002* opensuse ...\nBoot0006* preexisting ...\n' >"$BASELINE_FILE"
  ! leap16_r68_normalize_refind_target_aliases_after_proof >/dev/null 2>&1 || fail_test 'pre-stage firmware ID was incorrectly claimed as duplicate rEFInd target ownership'
)

# 6) Matrix must retain r67 as a safe runtime-dispatch failure rather than
# claiming the rEFInd edge hardware-proven before finalization succeeds.
(
  source_effective_stack
  matrix=$(leap16_r64_print_matrix)
  [[ $matrix == *'openSUSE Leap 16 bootloader matrix — leap16-r68'* ]] || fail_test 'matrix heading is not release-accurate for r68'
  [[ $matrix == *'r67 GRUB2 -> rEFInd reached canonical rEFInd BootCurrent and direct-booted Leap to userspace'* ]] || fail_test 'r67 hardware direct-boot evidence missing from r68 matrix'
  [[ $matrix == *'SAFE-FAILED before runtime certification/source cleanup'* ]] || fail_test 'r67 failure boundary missing from r68 matrix'
)

printf 'PASS: leap16-r68 inbound rEFInd runtime-dispatch/symlink/passive-source/duplicate-alias regression\n'
