#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"
layer="$ROOT/lib/leap16_r77.sh"
fail_test(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f $layer ]] || fail_test 'r77 layer missing'
grep -Fq 'SWITCHER_RELEASE="leap16-r77"' "$main" || fail_test 'release is not r77'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r77.sh"' "$main" || fail_test 'r77 layer is not sourced'
[[ $(grep -n 'source "$SCRIPT_DIR/lib/leap16_r77.sh"' "$main" | tail -n1 | cut -d: -f1) -gt \
   $(grep -n 'source "$SCRIPT_DIR/lib/leap16_r76.sh"' "$main" | tail -n1 | cut -d: -f1) ]] \
    || fail_test 'r77 is not the final release layer'
grep -Fq 'leap16_r64_baseline_path' "$layer" || fail_test 'pre-stage firmware ownership gate is missing'
grep -Fq 'Deleted post-stage duplicate direct-GRUB alias' "$layer" || fail_test 'automatic duplicate deletion is missing'
grep -Fq 'Final GRUB direct alias set is not unique' "$layer" || fail_test 'exact-one final direct alias gate is missing'

source_effective_stack(){
  local prelude
  prelude=$(awk '/^select_target_bootloader\(\)/{exit} {print}' "$main" | sed '/^SCRIPT_DIR=/d')
  SCRIPT_DIR=$ROOT
  eval "$prelude"
}

# 1) Reproduce r76 hardware shape: Boot0003 appears only after staging, points
# to exact same direct-GRUB path+ESP, and is in BootOrder. r77 must remove it
# before/after final-order installation and converge to recorded Boot0001.
(
  source_effective_stack
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  printf 'BootCurrent: 0000\nBootOrder: 0000\nBoot0000* openSUSE rEFInd\n' >"$td/baseline"
  PENDING_FORMAT=${R26_PENDING_FORMAT:-5}; PENDING_SOURCE=refind; PENDING_TARGET=grub; PENDING_PHASE=runtime-validated
  PENDING_TARGET_BOOT_ID=0002; BOOTLOADER=grub; BOOT_CURRENT=0002
  R28_GRUB_SHIM_PATH='\EFI\OPENSUSE\SHIM.EFI'; R28_GRUB_DIRECT_PATH='\EFI\OPENSUSE\GRUBX64.EFI'
  MOCK_ORDER='0000,0002,0001,0003'; MOCK_ALIASES='0001 0003'; trace=''
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
  # Old final-order function would install shim/direct and preserve remaining tail.
  leap16_r64_final_grub_order_pre_leap16_r77(){ MOCK_ORDER='0002,0001'; return 0; }
  leap16_r64_final_grub_order || fail_test 'r76 hardware-shape duplicate normalization failed'
  [[ $MOCK_ALIASES == '0001' ]] || fail_test "duplicate alias survived ($MOCK_ALIASES)"
  [[ $MOCK_ORDER == '0002,0001' ]] || fail_test "final order retained duplicate ($MOCK_ORDER)"
  [[ $trace == *'del=0003'* ]] || fail_test "Boot0003 was not deleted ($trace)"
)

# 2) A duplicate that reuses a pre-stage Boot#### ID is not transaction-owned
# and must be refused even if path+ESP happen to match.
(
  source_effective_stack
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  printf 'BootCurrent: 0000\nBootOrder: 0000,0003\nBoot0000* rEFInd\nBoot0003* unrelated baseline entry\n' >"$td/baseline"
  PENDING_FORMAT=${R26_PENDING_FORMAT:-5}; PENDING_SOURCE=refind; PENDING_TARGET=grub; PENDING_PHASE=runtime-validated
  PENDING_TARGET_BOOT_ID=0002; BOOTLOADER=grub; BOOT_CURRENT=0002
  R28_GRUB_SHIM_PATH='\EFI\OPENSUSE\SHIM.EFI'; R28_GRUB_DIRECT_PATH='\EFI\OPENSUSE\GRUBX64.EFI'
  leap16_r64_grub_direct_id(){ printf '0001\n'; }
  leap16_r64_baseline_path(){ printf '%s\n' "$td/baseline"; }
  leap16_r48_ids_for_current_esp_path(){ printf '0001\n0003\n'; }
  leap16_nvram_entry_matches_current_esp(){ return 0; }; nvram_id_matches_path(){ return 0; }; boot_id_exists(){ return 0; }
  leap16_current_boot_order(){ printf '0000,0002,0001,0003\n'; }
  ok(){ :; }; fail(){ return 1; }
  ! leap16_r77_normalize_refind_grub_direct_aliases_after_proof >/dev/null 2>&1 \
      || fail_test 'pre-stage Boot#### reuse was incorrectly claimed as duplicate ownership'
)

# 3) The final diagnostics must reject an r76-style shim,direct,duplicate order
# even though the stable prefix itself looks correct.
(
  source_effective_stack
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  PENDING_SOURCE=refind; PENDING_TARGET=grub
  leap16_r64_grub_direct_id(){ printf '0001\n'; }
  leap16_r77_current_direct_grub_ids(){ printf '0001\n0003\n'; }
  leap16_r76_write_final_refind_edge_order_report_pre_leap16_r77(){ printf 'assessment=pass\nreason=old-prefix-only-check\n' >"$1"; }
  leap16_r76_write_final_refind_edge_order_report "$td/report" auto-resume-pass
  grep -Fq 'assessment=fail' "$td/report" || fail_test 'duplicate final direct alias was still diagnosed as pass'
  grep -Fq 'expected 0001; found 0001,0003' "$td/report" || fail_test 'final duplicate diagnosis lacks exact alias set'
)

# 4) Existing finalized r76 residue is recognized as cleanup-only shape when
# shim is current/first and multiple direct aliases resolve to the same ESP path.
(
  source_effective_stack
  BOOTLOADER=grub; BOOT_CURRENT=0002; R28_GRUB_SHIM_PATH='\EFI\OPENSUSE\SHIM.EFI'
  leap16_current_boot_order(){ printf '0002,0001,0003\n'; }
  nvram_id_matches_path(){ [[ $1 == 0002 && $2 == "$R28_GRUB_SHIM_PATH" ]]; }
  leap16_nvram_entry_matches_current_esp(){ return 0; }
  leap16_r77_current_direct_grub_ids(){ printf '0001\n0003\n'; }
  leap16_r77_grub_duplicate_residue_shape || fail_test 'r76 finalized duplicate residue was not recognized'
)

# 5) The explicit post-r76 cleanup removes only the trailing exact direct-GRUB
# duplicate, keeps current shim + second direct alias, and changes no files.
(
  source_effective_stack
  PENDING_STATE_FILE=/nonexistent; BOOTLOADER=grub; BOOT_CURRENT=0002
  R28_GRUB_SHIM_PATH='\EFI\OPENSUSE\SHIM.EFI'; R28_GRUB_DIRECT_PATH='\EFI\OPENSUSE\GRUBX64.EFI'
  MOCK_ORDER='0002,0001,0003'; MOCK_ALIASES='0001 0003'; trace=''
  pending_exists(){ return 1; }; leap16_require_sudo_session(){ return 0; }; run_validation(){ return 0; }
  validate_grub_boot_chain(){ [[ $1 == current ]]; return 0; }; pending_bootnext_id(){ return 0; }
  detect_bootloader(){ BOOTLOADER=grub; BOOT_CURRENT=0002; }
  leap16_current_boot_order(){ printf '%s\n' "$MOCK_ORDER"; }
  leap16_r77_current_direct_grub_ids(){ for x in $MOCK_ALIASES; do printf '%s\n' "$x"; done; }
  leap16_nvram_entry_matches_current_esp(){ return 0; }
  nvram_id_matches_path(){
    case "$1:$2" in
      0002:'\EFI\OPENSUSE\SHIM.EFI'|0001:'\EFI\OPENSUSE\GRUBX64.EFI'|0003:'\EFI\OPENSUSE\GRUBX64.EFI') return 0 ;;
      *) return 1 ;;
    esac
  }
  leap16_order_has_id(){ case ",$1," in *",${2^^},"*) return 0;; *) return 1;; esac; }
  boot_id_exists(){ case " $MOCK_ALIASES 0002 " in *" ${1^^} "*) return 0;; *) return 1;; esac; }
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
  ok(){ :; }; fail(){ printf 'unexpected cleanup fail: %s\n' "$*" >&2; return 1; }
  leap16_r77_cleanup_finalized_grub_duplicates_inner >/dev/null <<< 'CLEAN' || fail_test 'explicit finalized-r76 duplicate cleanup failed'
  [[ $MOCK_ORDER == '0002,0001' ]] || fail_test "cleanup final order wrong ($MOCK_ORDER)"
  [[ $MOCK_ALIASES == '0001' ]] || fail_test "cleanup retained duplicate ($MOCK_ALIASES)"
  [[ $trace == *'del=0003'* ]] || fail_test "cleanup did not delete Boot0003 ($trace)"
)

# 6) Matrix does not prematurely promote rEFInd -> GRUB until automatic cleanup
# itself is hardware-proven.
(
  source_effective_stack
  matrix=$(leap16_r64_print_matrix)
  [[ $matrix == *'openSUSE Leap 16 bootloader matrix — leap16-r77'* ]] || fail_test 'matrix heading is not r77'
  [[ $matrix == *'rEFInd         HW-PENDING'* ]] || fail_test 'rEFInd -> GRUB was prematurely promoted'
  [[ $matrix == *'Boot0003'* ]] || fail_test 'r76 duplicate-alias hardware evidence missing from ledger'
)

printf 'leap16-r77 selftest: PASS\n'
