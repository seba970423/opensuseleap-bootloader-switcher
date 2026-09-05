#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
pass(){ printf 'PASS: %s\n' "$1"; }
fail(){ printf 'FAIL: %s\n' "$1" >&2; exit 1; }

grep -Fq 'SWITCHER_RELEASE="leap16-r39"' bootloader-switcher.sh || fail 'release is not r39'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r39.sh"' bootloader-switcher.sh || fail 'r39 layer is not sourced'
grep -Fq 'if [[ $src:$tgt == systemd-boot:grub ]]' lib/leap16_r39.sh || fail 'reverse automatic-resume dispatcher is not explicit'
grep -Fq 'leap16_r39_validate_grub_runtime' lib/leap16_r39.sh || fail 'reverse runtime validator is missing'
grep -Fq 'leap16_r39_verify_systemd_recovery_while_grub_active' lib/leap16_r39.sh || fail 'passive systemd recovery proof is missing'
grep -Fq 'r39-firmware-churn.tsv' lib/leap16_r39.sh || fail 'firmware churn ownership record is missing'
grep -Fq 'Removed source systemd-boot Boot$source and recorded firmware churn from BootOrder while every referenced EFI file still exists' lib/leap16_r39.sh || fail 'firmware-safe churn retirement order is missing'

# r39 must be an overlay; r31-r38 production layers remain present and unedited.
for f in lib/leap16_r31.sh lib/leap16_r32.sh lib/leap16_r33.sh lib/leap16_r34.sh lib/leap16_r35.sh lib/leap16_r36.sh lib/leap16_r37.sh lib/leap16_r38.sh; do
  [[ -f $f ]] || fail "$f missing"
done

while IFS= read -r f; do bash -n "$f" || fail "syntax: $f"; done < <(find . -type f -name '*.sh' -print | LC_ALL=C sort)
pass 'all shell files parse'

# Load the overlay with minimal previous-function stubs and reproduce the exact
# first r38 hardware NVRAM shape: baseline Boot0000, recorded direct Boot0002,
# target shim Boot0003, then post-boot UEFI-OS Boot0001 + duplicate direct Boot0004.
(
  verify_pending_source_recovery_unchanged(){ :; }
  leap16_r38_validate_grub_files_candidate(){ :; }
  validate_pending_target_runtime(){ :; }
  leap16_r38_final_grub_order_without_systemd(){ :; }
  leap16_r38_rollback(){ :; }
  r22_resume_transaction_root(){ :; }
  source lib/detect.sh
  source lib/leap16_r39.sh

  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  cat >"$tmp/baseline" <<'BASE'
BootCurrent: 0000
BootOrder: 0000
Boot0000* openSUSE systemd-boot HD(1,GPT,abc,0x800,0xff000)/File(\EFI\SYSTEMD\SYSTEMD-BOOTX64.EFI)
BASE
  cat >"$tmp/current" <<'CUR'
BootCurrent: 0003
BootOrder: 0000,0001,0003,0004
Boot0000* openSUSE systemd-boot HD(1,GPT,abc,0x800,0xff000)/File(\EFI\SYSTEMD\SYSTEMD-BOOTX64.EFI)
Boot0001* UEFI OS HD(1,GPT,abc,0x800,0xff000)/File(\EFI\BOOT\BOOTX64.EFI)0000424f
Boot0002* opensuse HD(1,GPT,abc,0x800,0xff000)/File(\EFI\OPENSUSE\GRUBX64.EFI)
Boot0003* opensuse-secureboot HD(1,GPT,abc,0x800,0xff000)/File(\EFI\OPENSUSE\SHIM.EFI)
Boot0004* opensuse HD(1,GPT,abc,0x800,0xff000)/File(\EFI\OPENSUSE\GRUBX64.EFI)0000424f
CUR
  PENDING_OLD_BOOT_ID=0000 PENDING_TARGET_BOOT_ID=0003
  leap16_r38_direct_id(){ printf '0002\n'; }
  leap16_r34_baseline_path(){ printf '%s\n' "$tmp/baseline"; }
  efibootmgr(){ cat "$tmp/current"; }
  leap16_boot_entry_line_for_id(){ awk -v id="${1^^}" '$0 ~ "^Boot" id {print; exit}' "$tmp/current"; }
  leap16_nvram_entry_matches_current_esp(){ return 0; }

  got=$(leap16_r39_collect_transaction_churn | LC_ALL=C sort)
  expected=$'0001\tefi/boot/bootx64.efi\n0004\tefi/opensuse/grubx64.efi'
  [[ $got == "$expected" ]] || { printf 'unexpected churn classification:\n%s\n' "$got" >&2; exit 1; }
)
pass 'real r38 post-boot aliases classify exactly as baseline-distinguished churn'

(
  verify_pending_source_recovery_unchanged(){ :; }
  leap16_r38_validate_grub_files_candidate(){ :; }
  validate_pending_target_runtime(){ :; }
  leap16_r38_final_grub_order_without_systemd(){ :; }
  leap16_r38_rollback(){ :; }
  r22_resume_transaction_root(){ printf 'OLD\n'; }
  source lib/leap16_r39.sh
  tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
  printf 'source\tsystemd-boot\ntarget\tgrub\n' >"$tmp"
  PENDING_STATE_FILE=$tmp
  leap16_r39_resume_grub_root(){ printf 'R39\n'; }
  [[ $(r22_resume_transaction_root) == R39 ]] || exit 1
)
pass 'systemd-boot -> GRUB2 root resume dispatch cannot fall through to the historical reverse path'

python3 - <<'PY'
from pathlib import Path
s=Path('lib/leap16_r39.sh').read_text()
# The root dispatcher must intercept systemd->grub before delegation.
f=s[s.index('r22_resume_transaction_root()'):]
assert f.index('systemd-boot:grub') < f.index('r22_resume_transaction_root_pre_leap16_r39')
# Churn is removed from BootOrder before its efibootmgr deletion.
g=s[s.index('leap16_r38_final_grub_order_without_systemd()'):s.index('# Rollback must also remove', s.index('leap16_r38_final_grub_order_without_systemd()'))]
assert g.index('efibootmgr -o "$joined"') < g.index('efibootmgr -b "$id" -B')
print('PASS: dispatcher and firmware-safe churn cleanup ordering')
PY

pass 'r39 focused contract passes'
