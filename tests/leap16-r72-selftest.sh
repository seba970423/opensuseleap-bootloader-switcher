#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"
fail_test(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f $ROOT/lib/leap16_r72.sh ]] || fail_test 'r72 layer missing'
grep -Fq 'SWITCHER_RELEASE="leap16-r72"' "$main" || fail_test 'release is not r72'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r72.sh"' "$main" || fail_test 'r72 layer is not sourced'
grep -Fq 'leap16_r72_cleanup_uncommitted_refind_to_grub' "$ROOT/lib/leap16_r72.sh" || fail_test 'specialized cleanup missing'
grep -Fq 'EFI/OPENSUSE' "$ROOT/lib/leap16_r72.sh" || fail_test 'native EFI namespace cleanup missing'
grep -Fq '/boot/grub2' "$ROOT/lib/leap16_r72.sh" || fail_test 'native /boot/grub2 cleanup missing'
grep -Fq 'R28_GRUB_DIRECT_PATH' "$ROOT/lib/leap16_r72.sh" || fail_test 'parked direct-GRUB cleanup missing'
grep -Fq 'r28_restore_source_boot_aux' "$ROOT/lib/leap16_r72.sh" || fail_test 'EFI/BOOT aux restoration missing'
grep -Fq 'r26_restore_source_fallback_after_target_stage' "$ROOT/lib/leap16_r72.sh" || fail_test 'generic fallback restoration missing'

# Load the effective stack and prove r26 cleanup dispatches only the exact
# rEFInd -> GRUB failure into r72.
prelude=$(awk '/^select_target_bootloader\(\)/{exit} {print}' "$main" | sed '/^SCRIPT_DIR=/d')
SCRIPT_DIR=$ROOT
eval "$prelude"
declare -f r26_cleanup_uncommitted_target | grep -Fq 'leap16_r72_cleanup_uncommitted_refind_to_grub' || fail_test 'effective r26 cleanup is not r72-intercepted'

# Dynamic regression for the r70 hardware failure shape: native GRUB staging
# created shim Boot0001 + parked direct Boot0000 and native Leap filesystem
# namespaces, then failed before a pending candidate was committed.  r72 must
# delete both aliases, restore source auxiliary/fallback state + exact order,
# and re-prove rEFInd.
(
  set -u
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  ESP_MOUNT="$td/esp"; mkdir -p "$ESP_MOUNT/EFI/OPENSUSE"
  TRANSACTION_SNAPSHOT_DIR="$td/snap"; mkdir -p "$TRANSACTION_SNAPSHOT_DIR"
  R28_GRUB_SHIM_PATH='\EFI\OPENSUSE\SHIM.EFI'
  R28_GRUB_DIRECT_PATH='\EFI\OPENSUSE\GRUBX64.EFI'
  BOOTLOADER=refind; BOOT_CURRENT=0005; ORDER=0005; NEXT=''
  SHIM_IDS=0001; DIRECT_IDS=0000
  AUX_RESTORED=0; FALLBACK_RESTORED=0; SOURCE_VALIDATED=0; RM_CALLS=''
  R26_SOURCE_EFI_HASH=''; R26_SOURCE_EFI_RESOLVED=''; R26_SOURCE_MANIFEST=''

  ok(){ :; }; fail(){ printf 'mock fail: %s\n' "$*" >&2; }
  detect_bootloader(){ BOOTLOADER=refind; BOOT_CURRENT=0005; }
  pending_bootnext_id(){ printf '%s' "$NEXT"; }
  leap16_current_boot_order(){ printf '%s\n' "$ORDER"; }
  leap16_r48_ids_for_current_esp_path(){
    case "$1" in
      "$R28_GRUB_SHIM_PATH") [[ -n $SHIM_IDS ]] && printf '%s\n' "$SHIM_IDS" ;;
      "$R28_GRUB_DIRECT_PATH") [[ -n $DIRECT_IDS ]] && printf '%s\n' "$DIRECT_IDS" ;;
    esac
  }
  leap16_nvram_entry_matches_current_esp(){ return 0; }
  nvram_id_matches_path(){
    case "$1:$2" in
      0001:"$R28_GRUB_SHIM_PATH"|0000:"$R28_GRUB_DIRECT_PATH") return 0 ;;
      *) return 1 ;;
    esac
  }
  r28_restore_source_boot_aux(){ AUX_RESTORED=1; return 0; }
  r26_restore_source_fallback_after_target_stage(){ FALLBACK_RESTORED=1; return 0; }
  adapter_source_validate(){ [[ $1 == refind ]] || return 1; SOURCE_VALIDATED=1; return 0; }
  r26_verify_owned_manifest(){ return 0; }
  r21_hash_privileged(){ return 1; }
  sudo(){
    [[ ${1:-} == -n ]] && shift
    if [[ ${1:-} == efibootmgr ]]; then
      shift
      if [[ ${1:-} == -b ]]; then
        local id=${2^^}; shift 3
        [[ $id == 0001 ]] && SHIM_IDS=''
        [[ $id == 0000 ]] && DIRECT_IDS=''
        return 0
      elif [[ ${1:-} == -o ]]; then ORDER=$2; return 0
      elif [[ ${1:-} == -N ]]; then NEXT=''; return 0
      fi
    elif [[ ${1:-} == rm ]]; then
      RM_CALLS+=" $*"
      return 0
    fi
    command "$@"
  }

  leap16_r72_cleanup_uncommitted_refind_to_grub 0005 0005 || fail_test 'r70-shape cleanup failed'
  [[ -z $SHIM_IDS && -z $DIRECT_IDS ]] || fail_test 'both native-GRUB aliases were not removed'
  [[ $ORDER == 0005 ]] || fail_test 'exact source BootOrder was not restored'
  [[ $AUX_RESTORED == 1 && $FALLBACK_RESTORED == 1 ]] || fail_test 'source EFI/BOOT state was not restored'
  [[ $SOURCE_VALIDATED == 1 ]] || fail_test 'rEFInd source was not re-proved after cleanup'
  [[ $RM_CALLS == *'/boot/grub2'* && $RM_CALLS == *'/etc/default/grub'* && $RM_CALLS == *'EFI/OPENSUSE'* ]] || fail_test 'native Leap GRUB filesystem cleanup was not issued'
  [[ ! -d $TRANSACTION_SNAPSHOT_DIR ]] || fail_test 'successful cleanup did not retire temporary snapshot'
)

# Non-rEFInd->GRUB must still delegate. Inspect the preserved implementation
# rather than mutating another proven edge in this test.
declare -F r26_cleanup_uncommitted_target_pre_leap16_r72 >/dev/null || fail_test 'historical cleanup delegate is missing'

printf 'leap16-r72 selftest: PASS\n'
