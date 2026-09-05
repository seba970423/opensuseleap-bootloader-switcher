#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

bash -n bootloader-switcher.sh
bash -n lib/leap16_r33.sh

grep -Eq 'SWITCHER_RELEASE="leap16-r3[3-6]"' bootloader-switcher.sh
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r32.sh"' bootloader-switcher.sh
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r33.sh"' bootloader-switcher.sh
grep -Fq 'zypper --non-interactive --no-recommends install systemd-boot' lib/leap16_r33.sh
grep -Fq 'pending_cmdline_equivalent "$reference" "$options"' lib/leap16_r33.sh
grep -Fq 'Reference cmdline has no explicit rw/ro token; candidate entries must preserve that omission' lib/leap16_r33.sh
grep -Fq 'done < <(leap16_r32_systemd_owned_paths)' lib/leap16_r33.sh
grep -Fq 'leap16_r33_remove_recoverable_systemd_residue' lib/leap16_r33.sh
grep -Fq 'r26_target_namespace_clean_pre_leap16_r33 systemd-boot' lib/leap16_r33.sh
grep -Eq 'systemd-boot\) run_validation preflight && leap16_r3[34]_validate_systemd_boot_chain current ;;' bootloader-switcher.sh

# The proven GRUB/Limine layers must remain byte-identical to r32.
base=/mnt/data/r32_work/opensuse-bootloader-switcher-r31
for f in lib/leap16_r21.sh lib/leap16_r22.sh lib/leap16_r23.sh lib/leap16_r24.sh lib/leap16_r25.sh lib/leap16_r26.sh lib/leap16_r27.sh lib/leap16_r28.sh lib/leap16_r29.sh lib/leap16_r30.sh lib/leap16_r31.sh; do
    cmp -s "$base/$f" "$f"
done

# Dynamic regression: Leap's real source form can omit rw/ro.  The proven
# transaction normalizer must accept exact omission and reject an invented mode.
source lib/staged.sh
ref='BOOT_IMAGE=/boot/vmlinuz-test root=UUID=deadbeef splash=silent quiet security= intel_pstate=passive'
candidate='root=UUID=deadbeef splash=silent quiet security= intel_pstate=passive'
pending_cmdline_equivalent "$ref" "$candidate"
! pending_cmdline_equivalent "$ref" "$candidate rw"

printf 'leap16-r33 focused selftest: PASS\n'
