#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

bash -n bootloader-switcher.sh
bash -n lib/leap16_r32.sh

grep -Eq 'SWITCHER_RELEASE="leap16-r3[2-6]"' bootloader-switcher.sh
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r32.sh"' bootloader-switcher.sh
grep -Fq '[[ $current:$target == grub:systemd-boot ]] && return 0' lib/leap16_r32.sh
grep -Fq 'systemd-boot -> GRUB2 remain locked' lib/leap16_r32.sh
grep -Fq 'zypper --non-interactive install systemd-boot' lib/leap16_r32.sh
grep -Fq 'efibootmgr --create-only' lib/leap16_r32.sh
grep -Fq 'No systemd-boot user backup/restore integration is enabled in %s' lib/leap16_r32.sh
# Proven GRUB/Limine implementation remains sourced before the r32 extension.
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r31.sh"' bootloader-switcher.sh
printf 'leap16-r32 static selftest: PASS\n'
