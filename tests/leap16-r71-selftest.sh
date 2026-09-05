#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"
fail_test(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f $ROOT/lib/leap16_r71.sh ]] || fail_test 'r71 layer missing'
grep -Fq 'SWITCHER_RELEASE="leap16-r71"' "$main" || fail_test 'release is not r71'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r71.sh"' "$main" || fail_test 'r71 layer is not sourced'

grep -Fq 'leap16_r71_validate_grub_files_from_refind' "$ROOT/lib/leap16_r71.sh" || fail_test 'rEFInd-specific GRUB validator missing'
! grep -Fq "systemd-boot-owned generic EFI fallback" "$ROOT/lib/leap16_r71.sh" || fail_test 'r71 reintroduced systemd-boot fallback assertion'
! grep -Fq "LOADER_TYPE remains systemd-boot" "$ROOT/lib/leap16_r71.sh" || fail_test 'r71 reintroduced systemd-boot LOADER_TYPE assertion'
grep -Fq "Generic EFI fallback remains absent, matching finalized rEFInd source state" "$ROOT/lib/leap16_r71.sh" || fail_test 'absent rEFInd fallback state is not handled'
grep -Fq "grub2-efi before GRUB runtime proof" "$ROOT/lib/leap16_r71.sh" || fail_test 'finalized rEFInd compatibility policy is not checked'

# The proven systemd-boot -> GRUB validator must remain untouched and available.
grep -Fq 'systemd-boot-owned generic EFI fallback remains byte-identical to the pre-stage source' "$ROOT/lib/leap16_r38.sh" || fail_test 'historical r38 systemd-boot validator changed'
grep -Fq 'LOADER_TYPE remains systemd-boot while the source is authoritative' "$ROOT/lib/leap16_r38.sh" || fail_test 'historical r38 LOADER_TYPE gate changed'

# Source the effective stack and prove the candidate wrapper now dispatches to
# the rEFInd-specific filesystem validator for the exact live edge.
prelude=$(awk '/^select_target_bootloader\(\)/{exit} {print}' "$main" | sed '/^SCRIPT_DIR=/d')
SCRIPT_DIR=$ROOT
eval "$prelude"
declare -f leap16_r64_validate_grub_candidate | grep -Fq 'leap16_r71_validate_grub_files_from_refind' || fail_test 'effective r64 candidate wrapper is not r71-fixed'


# Exercise the source fallback state contract independently: finalized rEFInd
# may legitimately have no generic EFI fallback, and if one existed it must be
# preserved byte-for-byte.
(
  set -u
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  ok(){ :; }
  fail(){ :; }
  sudo(){ [[ ${1:-} == -n ]] && shift; command "$@"; }
  r21_hash_privileged(){ sha256sum -- "$1" | command awk '{print $1}'; }
  ESP_MOUNT=$td/esp; mkdir -p "$ESP_MOUNT/EFI/BOOT"
  OLD_FALLBACK_PATH=$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI
  OLD_FALLBACK_EXISTED=0 OLD_FALLBACK_HASH=''
  leap16_r71_refind_source_fallback_unchanged || fail_test 'absent finalized-rEFInd fallback state was rejected'
  printf x >"$OLD_FALLBACK_PATH"
  ! leap16_r71_refind_source_fallback_unchanged || fail_test 'unexpected GRUB-created fallback was accepted'
  OLD_FALLBACK_EXISTED=1
  OLD_FALLBACK_HASH=$(sha256sum "$OLD_FALLBACK_PATH" | command awk '{print $1}')
  leap16_r71_refind_source_fallback_unchanged || fail_test 'unchanged pre-existing fallback hash was rejected'
  printf y >"$OLD_FALLBACK_PATH"
  ! leap16_r71_refind_source_fallback_unchanged || fail_test 'changed pre-existing fallback hash was accepted'
)

printf 'leap16-r71 selftest: PASS\n'
