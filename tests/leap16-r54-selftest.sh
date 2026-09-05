#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"
layer="$ROOT/lib/leap16_r54.sh"
[[ -f $layer ]] || { echo 'FAIL: r54 layer missing'; exit 1; }
grep -Fq 'SWITCHER_RELEASE="leap16-r54"' "$main"
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r54.sh"' "$main"
grep -Fq "LEAP16_R54_RETIRE_AUTH='r54-systemd-retirement-authorized.tsv'" "$layer"
grep -Fq 'Repaired r51-r53 stranded topology' "$layer"
grep -Fq 'Persisted RETIREMENT-AUTHORIZED checkpoint' "$layer"
grep -Fq 'leap16_r54_remove_source_manifest_idempotent' "$layer"
grep -Fq 'leap16_r54_finalize_limine_conf_idempotent' "$layer"
grep -Fq 'r21_order_primary_then_source_recovery' "$layer"

python3 - "$layer" <<'PY'
from pathlib import Path
import sys,re
s=Path(sys.argv[1]).read_text()
# The r54 replacement of the reverse promotion function must not use the
# generic helper that drops the source from BootOrder.
start=s.index('leap16_r51_promote_and_stage_fallback()')
end=s.index('\n}\n', start)+3
body=s[start:end]
assert 'adapter_target_promote' not in body
assert 'r21_order_primary_then_source_recovery' in body
assert body.index('r21_order_primary_then_source_recovery') < body.index('r21_atomic_replace')
# Retirement must persist authorization before any source NVRAM/path deletion.
start=s.index('leap16_r51_retire_systemd_after_fallback_proof()')
end=s.index('\n}\n', start)+3
body=s[start:end]
assert 'leap16_r54_write_retire_auth' in body
assert 'efibootmgr -b "$source" -B' in body
assert 'leap16_r54_remove_source_manifest_idempotent' in body
assert body.index('leap16_r54_write_retire_auth') < body.index('efibootmgr -b "$source" -B')
assert body.index('leap16_r54_write_retire_auth') < body.index('leap16_r54_remove_source_manifest_idempotent')
# Never broaden shared machine-id cleanup.
assert not re.search(r'rm\s+-rf[^\n]*PENDING_MACHINE_ID', s)
PY

# Synthetic reproduction of the r53 stranded topology:
# target Limine first, firmware fallback second, exact systemd source Boot####
# still exists but was accidentally dropped from BootOrder. r54 must restore
# target,source and preserve the firmware alias behind them.
(
  fail(){ echo "FAILMSG: $*" >&2; return 1; }
  ok(){ :; }
  info(){ :; }
  leap16_r51_validate_primary_runtime(){ :; }
  leap16_r51_plan(){ :; }
  leap16_r51_pending(){ return 0; }
  leap16_r51_fallback_staged(){ return 1; }
  detect_bootloader(){ BOOTLOADER=limine; BOOT_CURRENT=0000; }
  ORDER='0000,0002'
  leap16_current_boot_order(){ printf '%s\n' "$ORDER"; }
  boot_id_exists(){ [[ $1 == 0001 ]]; }
  nvram_id_matches_path(){ :; }
  leap16_nvram_entry_matches_current_esp(){ :; }
  r21_hash_privileged(){ printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; }
  r26_verify_owned_manifest(){ :; }
  leap16_r34_validate_systemd_boot_chain(){ :; }
  leap16_r53_verify_pretransfer_fallback_alias_set(){ :; }
  r21_order_primary_then_source_recovery(){ ORDER='0000,0001,0002'; }
  sudo(){
    [[ ${1:-} == -n ]] && shift
    command "$@"
  }
  grep(){ command grep "$@"; }
  PENDING_FORMAT=5 PENDING_SOURCE=systemd-boot PENDING_TARGET=limine
  PENDING_PHASE=runtime-validated PENDING_OLD_BOOT_ID=0001 PENDING_TARGET_BOOT_ID=0000
  PENDING_OLD_BOOT_EFI_PATH='\\EFI\\systemd\\systemd-bootx64.efi'
  PENDING_SOURCE_EFI_RESOLVED=/tmp/fake-systemd.efi
  PENDING_SOURCE_EFI_HASH=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  PENDING_SOURCE_MANIFEST=/tmp/fake-source-manifest
  printf 'x\n' >/tmp/fake-source-manifest
  mkdir -p /tmp/r54-sysconfig.$$
  trap 'rm -f /tmp/fake-source-manifest; rm -rf /tmp/r54-sysconfig.$$' EXIT
  # Make the hard-coded LOADER_TYPE probe in the repair helper succeed in this
  # isolated synthetic test without touching the host.
  eval "$(sed "s#grep -Eq '\^\[\[:space:\]\]\*LOADER_TYPE=.*systemd-boot' /etc/sysconfig/bootloader 2>/dev/null#true#" "$layer")"
  leap16_r54_repair_promoted_recovery_order_if_needed
  [[ $ORDER == '0000,0001,0002' ]] || { echo "FAIL: stranded order repaired to $ORDER"; exit 1; }
)

# Fail-closed machine-id enumeration contract: a find failure must not be
# interpreted as a harmless empty namespace.
(
  fail(){ return 1; }; ok(){ :; }; info(){ :; }
  leap16_r51_validate_primary_runtime(){ :; }
  leap16_r51_plan(){ :; }
  source "$layer"
  d=$(mktemp -d)
  trap 'rm -rf "$d"' EXIT
  sudo(){
    [[ ${1:-} == -n ]] && shift
    if [[ ${1:-} == find ]]; then return 1; fi
    command "$@"
  }
  if leap16_r47_machine_id_parent_is_empty_dir "$d"; then
      echo 'FAIL: failed enumeration was accepted as empty'
      exit 1
  fi
  if ! leap16_r47_limine_machine_namespace_conflicts "$d"; then
      echo 'FAIL: failed enumeration was not treated as a conflict'
      exit 1
  fi
)

echo 'PASS: leap16-r54 reverse promotion + resumable retirement regression'
