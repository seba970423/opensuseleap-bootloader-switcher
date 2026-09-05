#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"
ov="$ROOT/lib/leap16_r55.sh"
grep -Fq 'SWITCHER_RELEASE="leap16-r55"' "$main"
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r55.sh"' "$main"
grep -Fq 'leap16_r55_recover_stranded_pretransfer' "$ov"
grep -Fq 'r28_create_alias_create_only "$LEAP16_R32_SDBOOT_LABEL" "$LEAP16_R32_SDBOOT_EFI"' "$ov"
grep -Fq "Generic EFI fallback is still byte-identical to canonical systemd-boot" "$ov"
grep -Fq "Restored visible Limine EFI fallback menu entry" "$ov"
grep -Fq 'out=("$systemd" "$limine" "$fallback")' "$ov"
grep -Fq 'Do not manually select the EFI/BOOT fallback as a Limine proof; it still contains systemd-boot.' "$ov"
# Recovery must not write Limine bytes into EFI/BOOT and must not delete source systemd state.
! grep -Eq 'r21_atomic_replace[[:space:]]+"?\$PENDING_TARGET_EFI_RESOLVED"?[[:space:]]+"?\$PENDING_OLD_FALLBACK_PATH"?|rm -rf.*EFI/systemd|efibootmgr -b .* -B' "$ov"
echo 'PASS: leap16-r55 stranded pre-transfer source recovery contract'
! grep -Fq 'systemd_id=$(leap16_r55_create_systemd_alias_if_missing)' "$ov"
grep -Fq 'systemd_id=${LEAP16_R55_SYSTEMD_ID^^}' "$ov"
