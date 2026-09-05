#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"
layer="$ROOT/lib/leap16_r73.sh"
fail_test(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f $layer ]] || fail_test 'r73 layer missing'
grep -Fq 'SWITCHER_RELEASE="leap16-r73"' "$main" || fail_test 'release is not r73'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r73.sh"' "$main" || fail_test 'r73 layer is not sourced last'

# The Leap repair implementation must never contain or delegate to the Arch
# repair primitives called out by the hardware contamination report.
! grep -Eq '(^|[;&|[:space:]])mkinitcpio([;&|[:space:]]|$)|sudo[[:space:]]+grub-install|--bootloader-id=cachyos|execute_grub_repair[[:space:]]*\(' "$layer" \
    || fail_test 'Arch/CachyOS repair primitive leaked into r73'
grep -Fq 'grub2-mkconfig' "$layer" || fail_test 'native grub2-mkconfig reconstruction missing'
grep -Fq 'shim-install --no-nvram' "$layer" || fail_test 'native shim EFI reconstruction missing'
grep -Fq '/boot/grub2/grub.cfg' "$layer" || fail_test 'native /boot/grub2 topology missing'
grep -Fq 'leap16_r73_snapshot_efi_tree OPENSUSE' "$layer" || fail_test 'EFI/OPENSUSE rollback snapshot missing'
grep -Fq 'leap16_r73_snapshot_efi_tree BOOT' "$layer" || fail_test 'EFI/BOOT rollback snapshot missing'
grep -Fq 'LOADER_TYPE=.*grub2-efi' "$layer" || fail_test 'native LOADER_TYPE gate missing'
grep -Fq 'R28_GRUB_SHIM_PATH' "$layer" || fail_test 'shim topology gate missing'
grep -Fq 'R28_GRUB_DIRECT_PATH' "$layer" || fail_test 'direct-GRUB topology gate missing'
grep -Fq 'validate_grub_boot_chain current' "$layer" || fail_test 'unchanged deep GRUB validator is not used'
first_deep=$(grep -n "Strict deep GRUB validation rejected" "$layer" | head -n1 | cut -d: -f1)
refresh=$(grep -n "leap16_r73_refresh_native_efi ||" "$layer" | head -n1 | cut -d: -f1)
proof=$(grep -n "R73_FILESYSTEM_PROVEN=1" "$layer" | head -n1 | cut -d: -f1)
((first_deep < refresh && refresh < proof)) || fail_test 'EFI refresh/proof ordering is unsafe'

# Load the effective stack and prove the final dispatch owns only grub:grub.
prelude=$(awk '/^select_target_bootloader\(\)/{exit} {print}' "$main" | sed '/^SCRIPT_DIR=/d')
SCRIPT_DIR=$ROOT
eval "$prelude"
declare -f run_live_operation | grep -Fq 'leap16_r73_run_repair_inner' || fail_test 'effective same-GRUB dispatch is not r73'
declare -F run_live_operation_pre_leap16_r73 >/dev/null || fail_test 'non-repair delegate missing'

# Hardware-shape NVRAM regression: Boot0003 is current direct GRUB, Boot0000 is
# its duplicate, and shim has no alias.  Filesystem proof must precede any
# firmware write; r73 creates shim, retains current direct, deletes only 0000,
# then makes shim/direct first with no BootNext.
(
  set -u
  R28_GRUB_SHIM_PATH='\EFI\OPENSUSE\SHIM.EFI'
  R28_GRUB_DIRECT_PATH='\EFI\OPENSUSE\GRUBX64.EFI'
  R28_GRUB_SHIM_LABEL='opensuse-secureboot'
  BOOT_CURRENT=0003; BOOTLOADER=grub; R73_FILESYSTEM_PROVEN=1
  SHIM_IDS=''; DIRECT_IDS=$'0000\n0003'; ORDER=0003; NEXT=''; DELETED=''; VALIDATED=0
  ok(){ :; }; fail(){ printf 'mock fail: %s\n' "$*" >&2; }
  leap16_r73_ids_for_native_path(){
    case "$1" in "$R28_GRUB_SHIM_PATH") printf '%s' "$SHIM_IDS";; "$R28_GRUB_DIRECT_PATH") printf '%s\n' "$DIRECT_IDS";; esac
  }
  leap16_nvram_entry_matches_current_esp(){ return 0; }
  nvram_id_matches_path(){ return 0; }
  leap16_current_boot_order(){ printf '%s\n' "$ORDER"; }
  pending_bootnext_id(){ printf '%s' "$NEXT"; }
  validate_grub_boot_chain(){ VALIDATED=1; return 0; }
  r28_create_alias_create_only(){ SHIM_IDS=0004; R28_CREATED_ALIAS_ID=0004; return 0; }
  sudo(){
    [[ ${1:-} == -n ]] && shift
    if [[ ${1:-} == efibootmgr ]]; then
      shift
      if [[ ${1:-} == -b ]]; then
        DELETED+=" ${2^^}"; DIRECT_IDS=0003; return 0
      elif [[ ${1:-} == -o ]]; then ORDER=$2; return 0
      fi
    fi
    command "$@"
  }
  leap16_r73_normalize_nvram || fail_test 'hardware-shape NVRAM normalization failed'
  [[ $DELETED == ' 0000' ]] || fail_test 'r73 did not delete only the non-current duplicate direct alias'
  [[ $DIRECT_IDS == 0003 ]] || fail_test 'current direct alias was not retained'
  [[ $SHIM_IDS == 0004 ]] || fail_test 'missing shim alias was not created'
  [[ $ORDER == 0004,0003 ]] || fail_test "canonical shim/direct order not installed ($ORDER)"
  [[ $VALIDATED == 1 ]] || fail_test 'deep validation did not run after NVRAM normalization'
)

# Hard gate: no NVRAM action may occur without prior repaired-filesystem proof.
(
  R73_FILESYSTEM_PROVEN=0
  fail(){ :; }
  ! leap16_r73_normalize_nvram || fail_test 'NVRAM normalization ran before filesystem proof'
)

# Even a nonzero shim-install may have written firmware before failing. Prove
# r73 discovers that side effect, deletes only the new exact-path alias, and
# restores the pre-call BootOrder before the outer filesystem rollback runs.
(
  set -u
  R28_GRUB_SHIM_PATH='\EFI\OPENSUSE\SHIM.EFI'
  R28_GRUB_DIRECT_PATH='\EFI\OPENSUSE\GRUBX64.EFI'
  BOOT_CURRENT=0003; SHIM_IDS=''; DIRECT_IDS=$'0000\n0003'; ORDER=0003; NEXT=''; DELETED=''
  ok(){ :; }; fail(){ :; }
  leap16_r73_ids_for_native_path(){
    case "$1" in "$R28_GRUB_SHIM_PATH") [[ -n $SHIM_IDS ]] && printf '%s\n' "$SHIM_IDS";; "$R28_GRUB_DIRECT_PATH") printf '%s\n' "$DIRECT_IDS";; esac
  }
  leap16_current_boot_order(){ printf '%s\n' "$ORDER"; }
  pending_bootnext_id(){ printf '%s' "$NEXT"; }
  leap16_nvram_entry_matches_current_esp(){ return 0; }
  nvram_id_matches_path(){ return 0; }
  sudo(){
    [[ ${1:-} == -n ]] && shift
    if [[ ${1:-} == shim-install ]]; then SHIM_IDS=0004; ORDER=0004,0003; return 9; fi
    if [[ ${1:-} == efibootmgr ]]; then
      shift
      if [[ ${1:-} == -b ]]; then DELETED+=" ${2^^}"; SHIM_IDS=''; return 0; fi
      if [[ ${1:-} == -o ]]; then ORDER=$2; return 0; fi
    fi
    command "$@"
  }
  ! leap16_r73_refresh_native_efi || fail_test 'failed shim-install with NVRAM side effects was accepted'
  [[ $DELETED == ' 0004' && -z $SHIM_IDS ]] || fail_test 'unexpected shim alias was not ownership-gated and removed'
  [[ $DIRECT_IDS == $'0000\n0003' ]] || fail_test 'pre-existing direct aliases changed during no-nvram rollback'
  [[ $ORDER == 0003 ]] || fail_test 'pre-shim-install BootOrder was not restored'
)

printf 'leap16-r73 selftest: PASS\n'
