#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"
layer="$ROOT/lib/leap16_r53.sh"
[[ -f $layer ]] || { echo 'FAIL: r53 layer missing'; exit 1; }
grep -Fq 'SWITCHER_RELEASE="leap16-r53"' "$main"
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r53.sh"' "$main"
grep -Fq 'leap16_r53_current_fallback_alias_gate' "$layer"
grep -Fq 'leap16_r53_verify_pretransfer_fallback_alias_set' "$layer"
grep -Fq 'Preserved pre-stage firmware fallback Boot' "$layer"
grep -Fq 'reuse the frozen fallback alias when present' "$layer"
! grep -Fq "Pre-stage generic-fallback NVRAM alias set is not clean" "$layer"

# Static contract: r53 must not broadly delete the shared fallback file or the
# shared machine-id namespace to solve an NVRAM alias problem.
! grep -Eq 'rm[[:space:]]+-rf[^\n]*(EFI/BOOT|PENDING_OLD_FALLBACK_PATH)' "$layer"
! grep -Eq 'rm[[:space:]]+-rf[^\n]*PENDING_MACHINE_ID' "$layer"

# Synthetic source-gate behavior: zero and one exact aliases are accepted;
# two are rejected.  Stub all unrelated source proofs.
(
  fail(){ return 1; }; ok(){ :; }
  leap16_r34_validate_systemd_boot_chain(){ :; }
  leap16_r38_current_systemd_ids(){ printf '0001\n'; }
  leap16_current_boot_order(){ printf '0001,0002\n'; }
  leap16_r38_source_fallback_exact(){ :; }
  leap16_boot_entry_is_active(){ :; }
  leap16_nvram_entry_matches_current_esp(){ :; }
  nvram_id_matches_path(){ :; }
  r21_fallback_ids_now(){ :; }
  BOOT_CURRENT=0001 LEAP16_R21_FALLBACK_EFI_PATH='\EFI\BOOT\BOOTX64.EFI'
  mkdir -p /tmp/r53-test-sysconfig.$$
  trap 'rm -rf /tmp/r53-test-sysconfig.$$' EXIT
  # Source only function definitions after replacing the hard-coded sysconfig
  # probe with a successful command for this isolated test.
  eval "$(sed 's#grep -Eq '\''\^\[\[:space:\]\]\*LOADER_TYPE=.*systemd-boot'\'' /etc/sysconfig/bootloader 2>/dev/null#true#' "$layer")"
  leap16_r51_systemd_source_gate
  r21_fallback_ids_now(){ printf '0002\n'; }
  leap16_r51_systemd_source_gate
  r21_fallback_ids_now(){ printf '0002\n0003\n'; }
  if leap16_r51_systemd_source_gate >/dev/null 2>&1; then
      echo 'FAIL: two pre-stage fallback aliases were accepted'
      exit 1
  fi
)

echo 'PASS: leap16-r53 firmware fallback alias adoption regression'
