#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"

fail_test(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

grep -Fq 'SWITCHER_RELEASE="leap16-r58"' "$main" || fail_test 'release is not r58'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r58.sh"' "$main" || fail_test 'r58 overlay is not sourced'

# Load the exact production library stack in the exact main-script order.
# This catches undefined runtime helpers that a unit test can accidentally hide
# by mocking them, which is exactly what happened in r57.
(
  set -u
  SCRIPT_DIR="$ROOT"
  export SCRIPT_DIR
  while IFS= read -r line; do
      [[ $line == source\ * ]] || continue
      eval "$line"
  done < "$main"

  declare -F leap16_r57_current_pretransfer_fallback_id >/dev/null || fail_test 'r57 identity resolver did not load'
  declare -F leap16_r56_validate_current_fallback_alias >/dev/null || fail_test 'r57-required fallback validator symbol is undefined in production stack'
  declare -F leap16_r58_validate_current_fallback_alias >/dev/null || fail_test 'r58 concrete fallback validator did not load'
)

# Execute the r57 identity resolver without mocking its validator.  Only the
# hardware-query primitives are stubbed; the production r58 validator itself is
# exercised end-to-end.
(
  fail(){ printf 'FAILMSG: %s\n' "$*" >&2; return 1; }
  ok(){ :; }
  r21_hash_privileged(){ printf '%s\n' deadbeef; }
  leap16_r53_current_fallback_ids(){ [[ -n ${CURRENT_IDS:-} ]] && printf '%s\n' $CURRENT_IDS || :; }
  boot_id_exists(){ [[ $1 == 0006 ]]; }
  leap16_boot_entry_is_active(){ [[ $1 == 0006 ]]; }
  leap16_nvram_entry_matches_current_esp(){ [[ $1 == 0006 ]]; }
  nvram_id_matches_path(){ [[ $1 == 0006 && $2 == '\EFI\BOOT\BOOTX64.EFI' ]]; }
  leap16_r51_pending(){ return 0; }
  leap16_r51_fallback_staged(){ return 1; }
  leap16_r51_pending_menu(){ :; }
  leap16_r51_plan(){ :; }
  r21_create_or_adopt_fallback_alias(){ :; }
  r21_remove_staging_fallback_aliases(){ :; }

  PENDING_OLD_FALLBACK_PATH=/esp/EFI/BOOT/BOOTX64.EFI
  PENDING_OLD_FALLBACK_HASH=deadbeef
  PENDING_TARGET_EFI_HASH=cafebabe
  PENDING_OLD_BOOT_ID=0005
  PENDING_TARGET_BOOT_ID=0000
  LEAP16_R21_FALLBACK_EFI_PATH='\EFI\BOOT\BOOTX64.EFI'

  source "$ROOT/lib/leap16_r57.sh"
  source "$ROOT/lib/leap16_r58.sh"

  CURRENT_IDS='0006'
  [[ $(leap16_r57_current_pretransfer_fallback_id) == 0006 ]] || fail_test 'valid current alias was not resolved by production validator'

  CURRENT_IDS=''
  [[ -z $(leap16_r57_current_pretransfer_fallback_id) ]] || fail_test 'zero-alias pre-transfer state was not accepted'

  CURRENT_IDS='0005'
  if leap16_r57_current_pretransfer_fallback_id >/dev/null 2>&1; then
      fail_test 'fallback identity colliding with source Boot#### was accepted'
  fi

  CURRENT_IDS='0000'
  if leap16_r57_current_pretransfer_fallback_id >/dev/null 2>&1; then
      fail_test 'fallback identity colliding with target Boot#### was accepted'
  fi
)

# Guard the historical r57 mistake directly: the only definition of the symbol
# in the shipped tree must be production code, never just a test mock.
prod_defs=$(grep -R --include='*.sh' -l '^leap16_r56_validate_current_fallback_alias()' "$ROOT/lib" | wc -l)
[[ $prod_defs -ge 1 ]] || fail_test 'fallback validator exists only in tests'

echo 'PASS: leap16-r58 production-symbol + identity-resolver integration regression'
