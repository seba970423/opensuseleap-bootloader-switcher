#!/usr/bin/env bash
set -u
cd -- "$(dirname -- "$0")/.." || exit 1
failures=0
pass(){ printf '[PASS] %s\n' "$1"; }
fail_test(){ printf '[FAIL] %s\n' "$1" >&2; failures=$((failures+1)); }

if grep -Eq 'SWITCHER_RELEASE="leap16-r(25|2[6-9]|[3-9][0-9])"' bootloader-switcher.sh \
 && awk '/leap16_r24.sh/{a=NR} /leap16_r25.sh/{b=NR} END{exit !(a&&b&&b>a)}' bootloader-switcher.sh; then
  pass 'r25 layer is present in release/load order'
else
  fail_test 'r25 layer is missing or load order is wrong'
fi

# Ensure the override contains exactly the single-backslash EFI path expected
# in efibootmgr -v output, not r24's double-backslash literal.
python3 - <<'PY2'
from pathlib import Path
import re
s=Path('lib/leap16_r25.sh').read_text()
m=re.search(r"r21_nvram_ids_for_esp_path '([^']+)'", s)
if not m or m.group(1) != r"\EFI\LIMINE\LIMINE_X64.EFI":
    raise SystemExit(1)
PY2
case $? in
  0) pass 'primary Limine lookup uses literal efibootmgr EFI path' ;;
  *) fail_test 'primary Limine lookup escaping is wrong' ;;
esac

# Behavioral matcher fixture using the exact topology observed on the ASUS.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/efibootmgr" <<'OUT'
#!/usr/bin/env bash
cat <<'EOT'
BootCurrent: 0002
BootOrder: 0002,0003
Boot0002* openSUSE Limine HD(1,GPT,81720d70-39ac-4515-a24e-7e00d3b3d438,0x800,0xff000)/File(\EFI\LIMINE\LIMINE_X64.EFI)
Boot0003* UEFI OS HD(1,GPT,81720d70-39ac-4515-a24e-7e00d3b3d438,0x800,0xff000)/File(\EFI\BOOT\BOOTX64.EFI)
EOT
OUT
chmod +x "$tmp/efibootmgr"
cat >"$tmp/lsblk" <<'OUT'
#!/usr/bin/env bash
printf '%s\n' 81720d70-39ac-4515-a24e-7e00d3b3d438
OUT
chmod +x "$tmp/lsblk"

(
  PATH="$tmp:$PATH"
  PENDING_ESP_SOURCE=/dev/sdc1
  source lib/r21.sh
  a=$(r21_nvram_ids_for_esp_path '\EFI\LIMINE\LIMINE_X64.EFI')
  b=$(r21_nvram_ids_for_esp_path '\EFI\BOOT\BOOTX64.EFI')
  [[ $a == 0002 && $b == 0003 ]]
)
case $? in
  0) pass 'real ASUS primary/fallback efibootmgr paths resolve to Boot0002/Boot0003' ;;
  *) fail_test 'real ASUS primary/fallback efibootmgr path fixture failed' ;;
esac

if (( failures == 0 )); then
  printf 'All focused openSUSE Leap 16 r25 self-tests passed.\n'
  exit 0
fi
printf '%d focused r25 self-test(s) failed.\n' "$failures" >&2
exit 1
