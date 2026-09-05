#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"
layer="$ROOT/lib/leap16_r51.sh"
[[ -f $layer ]] || { echo 'FAIL: r51 layer missing'; exit 1; }
grep -Fq 'SWITCHER_RELEASE="leap16-r51"' "$main"
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r51.sh"' "$main"
grep -Fq 'systemd-boot:limine' "$layer"
grep -Fq 'r26_execute_adapter_switch limine' "$layer"
grep -Fq 'leap16_r51_validate_primary_runtime' "$layer"
grep -Fq 'leap16_r51_promote_and_stage_fallback' "$layer"
grep -Fq 'leap16_r51_validate_fallback_runtime' "$layer"
grep -Fq 'leap16_r51_retire_systemd_after_fallback_proof' "$layer"
grep -Fq 'openSUSE systemd-boot recovery' "$layer"
grep -Fq 'r26_remove_owned_manifest_paths "$PENDING_SOURCE_MANIFEST"' "$layer"
grep -Fq '[[ $1:$2 == systemd-boot:limine ]] && return 0' "$layer"
# The reverse edge must use two proof gates before source retirement.
python3 - "$layer" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
ret=s.index('leap16_r51_retire_systemd_after_fallback_proof()')
body=s[ret:s.index('\n}\n',ret)+3]
assert 'leap16_r51_validate_fallback_runtime || return 1' in body
assert 'r26_remove_owned_manifest_paths "$PENDING_SOURCE_MANIFEST"' in body
assert body.index('leap16_r51_validate_fallback_runtime') < body.index('r26_remove_owned_manifest_paths')
assert 'sudo rm -rf -- "${PENDING_ESP_MOUNT%/}/${PENDING_MACHINE_ID}"' not in s
assert 'sudo rmdir -- "${PENDING_ESP_MOUNT%/}/${PENDING_MACHINE_ID}"' in s
PY
echo 'PASS: leap16-r51 live Limine <-> systemd-boot matrix overlay'
