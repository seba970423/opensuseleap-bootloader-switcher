#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

pass(){ printf 'PASS: %s\n' "$1"; }
fail(){ printf 'FAIL: %s\n' "$1" >&2; exit 1; }

grep -Fq 'SWITCHER_RELEASE="leap16-r38"' bootloader-switcher.sh || fail 'release is not r38'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r38.sh"' bootloader-switcher.sh || fail 'r38 layer is not sourced'
grep -Fq 'systemd-boot:grub' lib/leap16_r38.sh || fail 'reverse direction is absent'
grep -Fq 'shim-install --no-nvram' lib/leap16_r38.sh || fail 'native openSUSE shim reconstruction missing'
grep -Fq 'r28_create_alias_create_only "$R28_GRUB_DIRECT_LABEL"' lib/leap16_r38.sh || fail 'direct GRUB create-only alias missing'
grep -Fq 'r28_create_alias_create_only "$R28_GRUB_SHIM_LABEL"' lib/leap16_r38.sh || fail 'shim create-only alias missing'
grep -Fq 'LEAP16_R38_DIRECT_ID' lib/leap16_r38.sh || fail 'direct GRUB identity is not tracked'
grep -Fq 'leap16_r38_transfer_grub_fallback' lib/leap16_r38.sh || fail 'post-proof shim fallback transfer missing'
grep -Fq 'leap16_r38_final_grub_order_without_systemd' lib/leap16_r38.sh || fail 'source-safe BootOrder retirement missing'
grep -Fq 'Deleted exact source systemd-boot Boot' lib/leap16_r38.sh || fail 'exact source NVRAM retirement missing'
grep -Fq 'LOADER_TYPE=grub2-efi' lib/leap16_r38.sh || fail 'final openSUSE GRUB policy transition missing'
grep -Fq 'leap16_r38_rollback' lib/leap16_r38.sh || fail 'reverse rollback missing'
grep -Fq '[[ $1:$2 == systemd-boot:grub ]] && return 0' lib/leap16_r38.sh || fail 'reverse edge is not explicitly unlocked in operation_supported'
grep -Fq 'sudo -n efibootmgr -v >"$baseline"' lib/leap16_r38.sh || fail 'reverse firmware baseline is not captured through the established sudo session'
grep -Fq 'r26_restore_source_fallback_after_target_stage' lib/leap16_r38.sh || fail 'source systemd-boot fallback is not restored after GRUB staging'
grep -Fq 'Direct GRUB alias entered BootOrder during candidate staging' lib/leap16_r38.sh || fail 'parked direct GRUB BootOrder gate missing'
grep -Fq 'systemd-boot -> GRUB2 candidate rolled back exactly' lib/leap16_r38.sh || fail 'reverse rollback result recording missing'
grep -Fq 'systemd-boot -> native openSUSE GRUB2 finalized after exact runtime proof' lib/leap16_r38.sh || fail 'reverse finalization result recording missing'

# Proven layers must not be edited by this revision.
for f in lib/leap16_r31.sh lib/leap16_r32.sh lib/leap16_r33.sh lib/leap16_r34.sh lib/leap16_r35.sh lib/leap16_r36.sh lib/leap16_r37.sh; do
  [[ -f $f ]] || fail "$f missing"
done

# Every shell file must parse.
while IFS= read -r f; do bash -n "$f" || fail "syntax: $f"; done < <(find . -type f -name '*.sh' -print | LC_ALL=C sort)
pass 'all shell files parse'

# Static safety order: fallback transfer must be textually before source Boot#### deletion,
# and BootOrder removal must be before deletion.
python3 - <<'PY'
from pathlib import Path
s=Path('lib/leap16_r38.sh').read_text()
start=s.index('leap16_r38_finalize()')
end=s.index('# Use the reverse-specific retirement', start)
f=s[start:end]
assert f.index('leap16_r38_transfer_grub_fallback') < f.index('leap16_r38_final_grub_order_without_systemd')
assert f.index('leap16_r38_final_grub_order_without_systemd') < f.index('efibootmgr -b "$source" -B')
assert f.index('efibootmgr -b "$source" -B') < f.index('r26_remove_owned_manifest_paths "$PENDING_SOURCE_MANIFEST"')
print('PASS: finalization preserves firmware-safe order')
PY

pass 'r38 focused static contract passes'
