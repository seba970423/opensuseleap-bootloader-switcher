#!/usr/bin/env bash
set -eu
set +o pipefail
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
  [[ $SWITCHER_RELEASE == leap16-r84 ]] || fail_test 'r84 release not loaded'
  matrix=$(leap16_r64_print_matrix)
  [[ $matrix == *'matrix — leap16-r84'* ]] || fail_test 'matrix heading is stale'
)

# Exact hardware regression: with global pipefail disabled, the old
# `grep | head` predicate falsely returned success for absent Boot0000.
# r84 must distinguish absent/new Boot IDs from real pre-stage IDs.
(
  source_effective_stack
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  cat >"$td/base" <<'B'
BootCurrent: 0001
Timeout: 1 seconds
BootOrder: 0001
Boot0001* openSUSE rEFInd HD(1,GPT,81720d70-39ac-4515-a24e-7e00d3b3d438,0x800,0xff000)/File(\EFI\refind\refind_x64.efi)
B
  leap16_r64_baseline_path(){ printf '%s\n' "$td/base"; }

  # Prove the fixture reproduces the r83 shell-status bug.
  if grep -Ei '^Boot0000\*?[[:space:]]' "$td/base" | head -n1 >/dev/null; then
    :
  else
    fail_test 'fixture did not reproduce the no-pipefail grep|head false success'
  fi

  leap16_r80_id_existed_in_baseline 0001 || fail_test 'real baseline Boot0001 was not detected'
  ! leap16_r80_id_existed_in_baseline 0000 || fail_test 'post-stage Boot0000 was falsely classified as pre-stage'
  ! leap16_r80_id_existed_in_baseline 0002 || fail_test 'post-stage Boot0002 was falsely classified as pre-stage'
)

# The exact r83 post-proof topology must pass the keep-alias ownership gate:
# baseline has only rEFInd Boot0001; current target/fallback are new Boot0000/2.
(
  source_effective_stack
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  cat >"$td/base" <<'B'
BootCurrent: 0001
Timeout: 1 seconds
BootOrder: 0001
Boot0001* openSUSE rEFInd HD(1,GPT,81720d70-39ac-4515-a24e-7e00d3b3d438,0x800,0xff000)/File(\EFI\refind\refind_x64.efi)
B
  PENDING_SOURCE=refind; PENDING_TARGET=limine; PENDING_PHASE=runtime-validated
  PENDING_TARGET_BOOT_ID=0000; PENDING_OLD_BOOT_ID=0001
  PENDING_ESP_SOURCE=/dev/mockesp
  LEAP16_R21_FALLBACK_EFI_PATH='\EFI\BOOT\BOOTX64.EFI'
  leap16_r64_baseline_path(){ printf '%s\n' "$td/base"; }
  leap16_r64_limine_fallback_id(){ printf '0002\n'; }
  boot_id_exists(){ [[ ${1^^} == 0000 || ${1^^} == 0002 ]]; }
  leap16_nvram_entry_matches_current_esp(){ return 0; }
  nvram_id_matches_path(){
    case ${1^^}:$2 in
      "0000:$LEAP16_R80_LIMINE_PRIMARY_PATH"|"0002:$LEAP16_R21_FALLBACK_EFI_PATH") return 0;;
      *) return 1;;
    esac
  }
  ok(){ :; }; fail(){ printf 'unexpected fail: %s\n' "$*" >&2; return 1; }
  leap16_r80_validate_limine_keep_aliases \
    || fail_test 'r83 hardware-proven post-stage Limine IDs were rejected as baseline reuse'
)

# The exact post-proof normalization gate that failed on hardware must now pass
# with no firmware mutation when primary/fallback are already unique.
(
  source_effective_stack
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  cat >"$td/base" <<'B'
BootCurrent: 0001
BootOrder: 0001
Boot0001* openSUSE rEFInd HD(1,GPT,81720d70-39ac-4515-a24e-7e00d3b3d438,0x800,0xff000)/File(\EFI\refind\refind_x64.efi)
B
  PENDING_SOURCE=refind; PENDING_TARGET=limine; PENDING_PHASE=runtime-validated
  PENDING_TARGET_BOOT_ID=0000; PENDING_OLD_BOOT_ID=0001
  PENDING_ESP_SOURCE=/dev/mockesp
  LEAP16_R21_FALLBACK_EFI_PATH='\EFI\BOOT\BOOTX64.EFI'
  leap16_r64_baseline_path(){ printf '%s\n' "$td/base"; }
  leap16_r64_limine_fallback_staged(){ return 0; }
  leap16_r64_limine_fallback_id(){ printf '0002\n'; }
  leap16_r80_current_ids_for_path(){
    [[ $1 == "$LEAP16_R80_LIMINE_PRIMARY_PATH" ]] && printf '0000\n' || printf '0002\n'
  }
  leap16_nvram_entry_matches_current_esp(){ return 0; }
  nvram_id_matches_path(){ return 0; }
  boot_id_exists(){ return 0; }
  sudo(){ fail_test "unexpected firmware mutation: $*"; }
  ok(){ :; }; fail(){ printf 'unexpected fail: %s\n' "$*" >&2; return 1; }
  leap16_r80_normalize_limine_aliases_after_fallback_proof \
    || fail_test 'hardware-proven unique primary/fallback topology did not pass normalization'
)

# A genuine baseline collision must still fail closed.  The fix may not weaken
# ownership by simply treating all target IDs as new.
(
  source_effective_stack
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  cat >"$td/base" <<'B'
BootCurrent: 0001
BootOrder: 0001
Boot0001* unrelated HD(1,GPT,81720d70-39ac-4515-a24e-7e00d3b3d438,0x800,0xff000)/File(\EFI\vendor\other.efi)
B
  PENDING_SOURCE=refind; PENDING_TARGET=limine; PENDING_PHASE=runtime-validated
  PENDING_TARGET_BOOT_ID=0001; PENDING_ESP_SOURCE=/dev/mockesp
  LEAP16_R21_FALLBACK_EFI_PATH='\EFI\BOOT\BOOTX64.EFI'
  leap16_r64_baseline_path(){ printf '%s\n' "$td/base"; }
  leap16_r64_limine_fallback_id(){ printf '0002\n'; }
  boot_id_exists(){ return 0; }
  leap16_nvram_entry_matches_current_esp(){ return 0; }
  nvram_id_matches_path(){ return 0; }
  ok(){ :; }; fail(){ return 1; }
  ! leap16_r80_validate_limine_keep_aliases >/dev/null 2>&1 \
    || fail_test 'genuine pre-stage target-ID collision was accepted'
)

printf 'leap16-r84 selftest: PASS\n'
