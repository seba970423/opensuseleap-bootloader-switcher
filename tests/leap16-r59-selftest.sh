#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"
fail_test(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

grep -Fq 'SWITCHER_RELEASE="leap16-r59"' "$main" || fail_test 'release is not r59'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r59.sh"' "$main" || fail_test 'r59 overlay is not sourced'

# Production stack must load and expose the final renderer/repair overrides.
(
  set -u
  SCRIPT_DIR="$ROOT"; export SCRIPT_DIR
  while IFS= read -r line; do
      [[ $line == source\ * ]] || continue
      eval "$line"
  done < "$main"
  declare -F leap16_r54_render_final_limine_conf >/dev/null || fail_test 'r59 final renderer missing'
  declare -F leap16_r59_repair_finalized_limine_menu >/dev/null || fail_test 'r59 finalized-menu repair missing'
  declare -F leap16_r56_validate_current_fallback_alias >/dev/null || fail_test 'r58 production fallback validator regressed'
)

# Pure renderer regression: temporary direct systemd recovery becomes exactly
# one visible EFI fallback and never disappears into a no-entry final menu.
(
  fail(){ printf 'FAILMSG: %s\n' "$*" >&2; return 1; }
  r21_hash_privileged(){ sha256sum "$1" | awk '{print $1}'; }
  leap16_r51_meta_value(){ [[ $1 == transferred_conf_hash ]] && sha256sum "$CONF" | awk '{print $1}'; }
  r24_final_fallback_block_present(){
      grep -Fqx '/EFI fallback' "$1" \
        && grep -Fqx 'protocol: efi' "$1" \
        && grep -Fqx 'path: boot():/EFI/BOOT/BOOTX64.EFI' "$1"
  }
  leap16_r54_render_final_limine_conf(){ :; }
  leap16_validate_limine_recovery_contract(){ :; }
  leap16_r54_finalize_limine_conf_idempotent(){ :; }
  run_live_operation(){ :; }
  leap16_r51_pending(){ return 1; }
  leap16_r54_retirement_authorized(){ return 1; }
  pending_exists(){ return 1; }

  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  CONF="$TMP/limine.conf"; PENDING_ESP_MOUNT="$TMP"; ESP_MOUNT="$TMP"
  cat >"$CONF" <<'CFG'
timeout: 5
/+openSUSE
  //kernel
  protocol: linux

/openSUSE systemd-boot recovery
### Temporary direct recovery path retained until Limine fallback proof completes
comment: Native openSUSE systemd-boot recovery path
protocol: efi
path: boot():/EFI/systemd/systemd-bootx64.efi
CFG
  source "$ROOT/lib/leap16_r59.sh"
  OUT="$TMP/out"
  leap16_r54_render_final_limine_conf "$OUT"
  [[ $(grep -Fxc '/EFI fallback' "$OUT") == 1 ]] || fail_test 'renderer did not create exactly one EFI fallback entry'
  ! grep -Fq '/openSUSE systemd-boot recovery' "$OUT" || fail_test 'renderer kept temporary systemd recovery entry'
  r24_final_fallback_block_present "$OUT" || fail_test 'renderer output does not match finalized fallback contract'
)

# Static guard: the systemd->Limine final renderer must never reproduce the
# r54-r58 behavior of simply deleting the temporary recovery block.
grep -Fq "printf '/EFI fallback\\n'" "$ROOT/lib/leap16_r59.sh" || fail_test 'r59 does not render visible EFI fallback'
grep -Fq 'Converted temporary systemd-boot recovery menu entry into visible EFI fallback' "$ROOT/lib/leap16_r59.sh" || fail_test 'r59 finalization conversion is not wired'

echo 'PASS: leap16-r59 finalized Limine fallback-menu regression'
