#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

printf 'openSUSE Leap 16 r34 focused self-test\n'
printf '======================================\n\n'

pass(){ printf '[PASS] %s\n' "$1"; }
fail_test(){ printf '[FAIL] %s\n' "$1" >&2; exit 1; }

for f in bootloader-switcher.sh lib/*.sh tests/*.sh; do bash -n "$f" || fail_test "shell parse failed: $f"; done
pass 'all shell files parse'

grep -Eq 'SWITCHER_RELEASE="leap16-r3[4-6]"' bootloader-switcher.sh || fail_test 'r34+ release marker is missing'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r33.sh"' bootloader-switcher.sh || fail_test 'r33 layer is not retained'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r34.sh"' bootloader-switcher.sh || fail_test 'r34 layer is not retained'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r35.sh"' bootloader-switcher.sh || fail_test 'r35 hardening layer is not loaded after r34'
pass 'r34 is retained after r33 and r35 is layered on top without rewriting the proven base'

grep -Fq 'title openSUSE Leap 16' lib/leap16_r34.sh || fail_test 'clean BLS title is missing'
grep -Fq 'version $ver' lib/leap16_r34.sh || fail_test 'BLS version field is missing'
grep -Fq 'sort-key opensuse' lib/leap16_r34.sh || fail_test 'BLS sort-key is missing'
! grep -A30 '^leap16_r32_write_systemd_boot_candidate()' lib/leap16_r34.sh | grep -Fq 'cp -- "$entry"' || fail_test 'r34 still creates a duplicate current alias'
grep -Fq 'default="opensuse-${KERNEL_VERSIONS[0]}.conf"' lib/leap16_r34.sh || fail_test 'loader.conf does not select the real newest entry'
pass 'systemd-boot menu no longer duplicates the newest kernel or embeds the version twice in the title'

grep -Fq 'source-firmware-baseline.txt' lib/leap16_r34.sh || fail_test 'firmware baseline is not recorded'
grep -Fq 'efibootmgr -v >"$baseline"' lib/leap16_r34.sh || fail_test 'full firmware baseline capture is absent'
grep -Fq "This candidate predates r34 and has no complete pre-stage firmware baseline." lib/leap16_r34.sh || fail_test 'pre-r34 finalization lock is absent'
pass 'GRUB2 retirement requires an r34 pre-stage firmware ownership baseline'

grep -Fq 'if [[ $src:$tgt == grub:systemd-boot ]]' lib/leap16_r34.sh || fail_test 'root resume does not dispatch systemd-boot explicitly'
grep -Fq 'leap16_r34_validate_systemd_runtime' lib/leap16_r34.sh || fail_test 'systemd-boot runtime validator is missing'
grep -Fq 'Current bootloader is $(bootloader_display_name "$BOOTLOADER"), not systemd-boot' lib/leap16_r34.sh || fail_test 'runtime identity gate is missing'
pass 'automatic resume no longer falls through to the Limine-only runtime validator'

grep -Fq 'Transferred the generic EFI fallback to byte-identical systemd-boot only after runtime proof and persistent promotion' lib/leap16_r34.sh || fail_test 'post-proof fallback transfer gate is missing'
grep -Fq 'leap16_r34_finalize_grub_to_systemd()' lib/leap16_r35.sh || fail_test 'r35 does not supersede the r34 retirement implementation'
pass 'r34 resume/menu work is retained while r35 supersedes its pre-hardware-test retirement ordering'

# Hardware-proven GRUB/Limine layers remain byte-identical to r33.
base=/mnt/data/r33_work/opensuse-bootloader-switcher-r33
for f in lib/leap16_r21.sh lib/leap16_r22.sh lib/leap16_r23.sh lib/leap16_r24.sh lib/leap16_r25.sh lib/leap16_r26.sh lib/leap16_r27.sh lib/leap16_r28.sh lib/leap16_r29.sh lib/leap16_r30.sh lib/leap16_r31.sh; do
    cmp -s "$base/$f" "$f" || fail_test "proven GRUB/Limine layer changed: $f"
done
pass 'all hardware-proven GRUB2/Limine layers are byte-identical to r33'

printf '\nAll focused openSUSE Leap 16 r34 self-tests passed.\n'
