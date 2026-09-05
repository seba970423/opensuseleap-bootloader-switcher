#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"
lib="$ROOT/lib/leap16_r56.sh"
grep -Fq 'SWITCHER_RELEASE="leap16-r56"' "$main"
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r56.sh"' "$main"
grep -Fq "RECOVERED-SOURCE-CLEANUP-AUTHORIZED checkpoint" "$lib"
grep -Fq 'leap16_r56_manifest_remaining_is_owned_subset' "$lib"
grep -Fq 'leap16_r56_order_without_recovery_aliases' "$lib"
grep -Fq "r56-recovered-source-pre-cleanup" "$lib"
grep -Fq "r56-recovered-source-cleanup-pass" "$lib"
grep -Fq 'A fresh systemd-boot -> Limine transaction can now be staged' "$lib"
# Recovery cleanup may delete the NVRAM alias to EFI/BOOT but must never delete
# or overwrite the EFI/BOOT file itself.
if grep -E 'rm[[:space:]].*EFI/BOOT/BOOTX64\.EFI|atomic_replace.*EFI/BOOT|install .*EFI/BOOT/BOOTX64\.EFI' "$lib" >/dev/null; then
  echo 'FAIL: r56 recovery cleanup mutates/deletes EFI/BOOT bytes' >&2
  exit 1
fi
# Fresh reverse migration must be blocked while cleanup is pending.
grep -Fq 'operation_supported_pre_leap16_r56' "$lib"
grep -Fq 'systemd-boot:limine' "$lib"
echo 'PASS: leap16-r56 recovered-source cleanup regression'
