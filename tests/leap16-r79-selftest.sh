#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"
layer="$ROOT/lib/leap16_r79.sh"
fail_test(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ -f $layer ]] || fail_test 'r79 layer missing'
grep -Fq 'SWITCHER_RELEASE="leap16-r79"' "$main" || fail_test 'release is not r79'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r79.sh"' "$main" || fail_test 'r79 layer not sourced'

source_effective_stack(){
  local prelude
  prelude=$(awk '/^select_target_bootloader\(\)/{exit} {print}' "$main" | sed '/^SCRIPT_DIR=/d')
  SCRIPT_DIR=$ROOT
  eval "$prelude"
}

# Exact r78 hardware state after successful runtime proof + target promotion:
# Boot0001 is the recorded direct alias but deliberately parked outside order;
# Boot0003 is a post-stage same-path/same-ESP duplicate.  Normalization must
# remove 0003 without demanding 0001 already be in BootOrder.
(
  source_effective_stack
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  printf 'BootCurrent: 0000\nBootOrder: 0000\nBoot0000* openSUSE rEFInd\n' >"$td/baseline"
  PENDING_FORMAT=${R26_PENDING_FORMAT:-5}; PENDING_SOURCE=refind; PENDING_TARGET=grub; PENDING_PHASE=runtime-validated
  PENDING_TARGET_BOOT_ID=0002; PENDING_OLD_BOOT_ID=0000; BOOTLOADER=grub; BOOT_CURRENT=0002
  R28_GRUB_SHIM_PATH='\EFI\OPENSUSE\SHIM.EFI'; R28_GRUB_DIRECT_PATH='\EFI\OPENSUSE\GRUBX64.EFI'
  MOCK_ORDER='0002,0000,0003'; MOCK_ALIASES='0001 0003'; trace=''
  leap16_r64_grub_direct_id(){ printf '0001\n'; }
  leap16_r64_baseline_path(){ printf '%s\n' "$td/baseline"; }
  leap16_r48_ids_for_current_esp_path(){ for x in $MOCK_ALIASES; do printf '%s\n' "$x"; done; }
  leap16_nvram_entry_matches_current_esp(){ return 0; }
  nvram_id_matches_path(){ return 0; }
  leap16_current_boot_order(){ printf '%s\n' "$MOCK_ORDER"; }
  leap16_order_has_id(){ case ",$1," in *",${2^^},"*) return 0;; *) return 1;; esac; }
  boot_id_exists(){ case " $MOCK_ALIASES 0000 0002 " in *" ${1^^} "*) return 0;; *) return 1;; esac; }
  sudo(){
    [[ $1 == efibootmgr ]] || return 1; shift
    if [[ ${1:-} == -o ]]; then MOCK_ORDER=${2^^}; trace+=" order=$MOCK_ORDER"; return 0; fi
    if [[ ${1:-} == -b && ${3:-} == -B ]]; then
      local del=${2^^} new='' x
      for x in $MOCK_ALIASES; do [[ ${x^^} == "$del" ]] || new+="${new:+ }${x^^}"; done
      MOCK_ALIASES=$new; trace+=" del=$del"; return 0
    fi
    return 1
  }
  ok(){ :; }; fail(){ printf 'unexpected fail: %s\n' "$*" >&2; return 1; }
  leap16_r77_normalize_refind_grub_direct_aliases_after_proof || fail_test 'parked-direct r78 hardware shape was rejected'
  [[ $MOCK_ORDER == '0002,0000' ]] || fail_test "duplicate was not removed from pre-final order ($MOCK_ORDER)"
  [[ $MOCK_ALIASES == '0001' ]] || fail_test "duplicate alias survived ($MOCK_ALIASES)"
  [[ $trace == *'del=0003'* ]] || fail_test "Boot0003 was not deleted ($trace)"
)

# A duplicate reusing a pre-stage ID must remain fail-closed.
(
  source_effective_stack
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  printf 'BootCurrent: 0000\nBootOrder: 0000,0003\nBoot0000* rEFInd\nBoot0003* baseline\n' >"$td/baseline"
  PENDING_FORMAT=${R26_PENDING_FORMAT:-5}; PENDING_SOURCE=refind; PENDING_TARGET=grub; PENDING_PHASE=runtime-validated
  PENDING_TARGET_BOOT_ID=0002; BOOTLOADER=grub; BOOT_CURRENT=0002
  R28_GRUB_SHIM_PATH='\EFI\OPENSUSE\SHIM.EFI'; R28_GRUB_DIRECT_PATH='\EFI\OPENSUSE\GRUBX64.EFI'
  leap16_r64_grub_direct_id(){ printf '0001\n'; }
  leap16_r64_baseline_path(){ printf '%s\n' "$td/baseline"; }
  leap16_r48_ids_for_current_esp_path(){ printf '0001\n0003\n'; }
  leap16_nvram_entry_matches_current_esp(){ return 0; }; nvram_id_matches_path(){ return 0; }; boot_id_exists(){ return 0; }
  leap16_current_boot_order(){ printf '0002,0000,0003\n'; }
  leap16_order_has_id(){ case ",$1," in *",${2^^},"*) return 0;; *) return 1;; esac; }
  ok(){ :; }; fail(){ return 1; }
  ! leap16_r77_normalize_refind_grub_direct_aliases_after_proof >/dev/null 2>&1 || fail_test 'pre-stage duplicate ID was incorrectly claimed'
)

printf 'leap16-r79 selftest: PASS\n'
