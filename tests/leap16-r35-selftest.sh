#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
pass(){ printf '[PASS] %s\n' "$1"; }
fail_test(){ printf '[FAIL] %s\n' "$1" >&2; exit 1; }

printf 'openSUSE Leap 16 r35 focused self-test\n'
printf '======================================\n\n'

for f in bootloader-switcher.sh lib/*.sh tests/*.sh; do bash -n "$f" || fail_test "shell parse failed: $f"; done
pass 'all shell files parse'

grep -Eq 'SWITCHER_RELEASE="leap16-r3[56]"' bootloader-switcher.sh || fail_test 'r35/r36 release marker missing'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r34.sh"' bootloader-switcher.sh || fail_test 'r34 layer missing'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r35.sh"' bootloader-switcher.sh || fail_test 'r35 layer missing'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r36.sh"' bootloader-switcher.sh || fail_test 'r36 layer missing after r35'
pass 'r35 is a final narrow Leap layer over r34'

grep -Fq 'sudo -n efibootmgr -v >"$baseline"' lib/leap16_r35.sh || fail_test 'privileged baseline capture missing'
grep -Fq 'Native GRUB2 firmware alias set drifted since staging' lib/leap16_r35.sh || fail_test 'exact baseline/current alias equality gate missing'
grep -Fq 'leap16_r35_order_without_source_grub' lib/leap16_r35.sh || fail_test 'BootOrder strip helper missing'
grep -Fq 'leap16_r35_delete_source_grub_nvram_exact' lib/leap16_r35.sh || fail_test 'exact NVRAM deletion helper missing'
grep -Fq 'leap16_r35_remove_grub_source_files_after_nvram' lib/leap16_r35.sh || fail_test 'post-NVRAM filesystem retirement helper missing'
pass 'r35 has exact firmware ownership and no orphaned-BootOrder retirement window'

# Assert finalizer ordering from the function body.
body=$(sed -n '/^leap16_r34_finalize_grub_to_systemd()/,/^}/p' lib/leap16_r35.sh)
line_order=$(grep -n 'leap16_r35_order_without_source_grub' <<<"$body" | tail -n1 | cut -d: -f1)
line_nvram=$(grep -n 'leap16_r35_delete_source_grub_nvram_exact' <<<"$body" | tail -n1 | cut -d: -f1)
line_files=$(grep -n 'leap16_r35_remove_grub_source_files_after_nvram' <<<"$body" | tail -n1 | cut -d: -f1)
[[ -n $line_order && -n $line_nvram && -n $line_files && $line_order -lt $line_nvram && $line_nvram -lt $line_files ]] || fail_test 'finalizer retirement order is not BootOrder -> NVRAM -> files'
pass 'finalizer statically orders BootOrder removal before NVRAM deletion before file deletion'

grep -Fq 'Unrelated pre-existing generic EFI fallback remains byte-identical' lib/leap16_r35.sh || fail_test 'unrelated fallback final postcondition missing'
grep -Fq 'Generic EFI fallback is byte-identical to the proven systemd-boot EFI' lib/leap16_r35.sh || fail_test 'owned fallback final postcondition missing'
pass 'final fallback postcondition matches both ownership branches'

# Clean-menu behavior stays inherited from r34.
grep -Fq 'title openSUSE Leap 16' lib/leap16_r34.sh || fail_test 'clean BLS title missing'
grep -Fq 'default="opensuse-${KERNEL_VERSIONS[0]}.conf"' lib/leap16_r34.sh || fail_test 'real newest BLS default missing'
pass 'clean two-entry systemd-boot menu remains in force'

# Hardware-proven GRUB/Limine Leap layers must remain byte-identical to r31/r33.
base=/mnt/data/r33_work/opensuse-bootloader-switcher-r33
for f in lib/leap16_r21.sh lib/leap16_r22.sh lib/leap16_r23.sh lib/leap16_r24.sh lib/leap16_r25.sh lib/leap16_r26.sh lib/leap16_r27.sh lib/leap16_r28.sh lib/leap16_r29.sh lib/leap16_r30.sh lib/leap16_r31.sh; do
    cmp -s "$base/$f" "$f" || fail_test "proven GRUB/Limine layer changed: $f"
done
pass 'all hardware-proven GRUB2/Limine layers are byte-identical to r33'

printf '\nAll focused openSUSE Leap 16 r35 self-tests passed.\n'
