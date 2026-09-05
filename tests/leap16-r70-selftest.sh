#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"
fail_test(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f $ROOT/lib/leap16_r70.sh ]] || fail_test 'r70 layer missing'
grep -Fq 'SWITCHER_RELEASE="leap16-r70"' "$main" || fail_test 'release is not r70'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r70.sh"' "$main" || fail_test 'r70 layer is not sourced'

source_effective_stack(){
  local prelude
  prelude=$(awk '/^select_target_bootloader\(\)/{exit} {print}' "$main" | sed '/^SCRIPT_DIR=/d')
  SCRIPT_DIR=$ROOT
  eval "$prelude"
}

# Exact regression from the first finalized rEFInd backup attempt: two
# byte-identical raw firmware paths containing backslashes must compare equal.
(
  set -u
  source_effective_stack
  a='\EFI\refind\refind_x64.efi'
  b='\EFI\refind\refind_x64.efi'
  [[ "$a" == "$b" ]] || fail_test 'test fixture paths differ'
  # Demonstrate why the historical expression was unsafe; an unquoted RHS is
  # a pattern and consumes backslashes as pattern escapes.
  if [[ ${a,,} == ${b,,} ]]; then
      fail_test 'Bash no longer reproduces the historical unquoted-RHS failure'
  fi
  leap16_r70_efi_path_equal_ci "$a" "$b" || fail_test 'literal EFI comparator rejects identical canonical rEFInd path'
  leap16_r70_efi_path_equal_ci '\EFI\REFIND\REFIND_X64.EFI' "$b" || fail_test 'literal EFI comparator is not case-insensitive'
  ! leap16_r70_efi_path_equal_ci '\EFI\refind\other.efi' "$b" || fail_test 'literal EFI comparator accepts different path'
)

# Exercise the effective r70 rEFInd metadata identity branch itself while
# mocking only the unrelated structural/payload validators.  This proves a
# freshly emitted canonical rEFInd metadata path survives serialization,
# decoding and self-validation.
(
  set -u
  source_effective_stack
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  validate_backup_pre_leap16_r31(){ return 0; }
  leap16_r64_refind_backup_payload_valid(){ return 0; }
  {
    leap16_r31_emit_metadata_kv format_version 4
    leap16_r31_emit_metadata_kv backup_platform "$LEAP16_R31_BACKUP_PLATFORM"
    leap16_r31_emit_metadata_kv backup_schema "$LEAP16_R64_REFIND_BACKUP_SCHEMA"
    leap16_r31_emit_metadata_kv switcher_release leap16-r70
    leap16_r31_emit_metadata_kv bootloader refind
    leap16_r31_emit_metadata_kv payload_policy "$LEAP16_R64_REFIND_PAYLOAD_POLICY"
    leap16_r31_emit_metadata_kv created_epoch 1
    leap16_r31_emit_metadata_kv created_iso 2026-09-03T23:30:00+03:00
    leap16_r31_emit_metadata_kv hostname test
    leap16_r31_emit_metadata_kv machine_id deadbeef
    leap16_r31_emit_metadata_kv esp_source /dev/sdc1
    leap16_r31_emit_metadata_kv esp_mount /boot/efi
    leap16_r31_emit_metadata_kv esp_uuid 18D1-2715
    leap16_r31_emit_metadata_kv root_source /dev/sdc2
    leap16_r31_emit_metadata_kv root_uuid 0b31f269-b3b0-441c-94b2-4c4854385b41
    leap16_r31_emit_metadata_kv boot_current 0005
    leap16_r31_emit_metadata_kv boot_label 'openSUSE rEFInd'
    leap16_r31_emit_metadata_kv boot_efi_path '\EFI\refind\refind_x64.efi'
  } >"$td/metadata.conf"
  validate_backup "$td" || fail_test "effective r70 validator rejects canonical rEFInd metadata: ${BACKUP_VALIDATION_REASON:-unknown}"
  [[ $BACKUP_VALIDATION_REASON == valid ]] || fail_test 'effective r70 validator did not mark metadata valid'
)

# Non-rEFInd backups must still delegate to the exact effective r69 validator.
(
  set -u
  source_effective_stack
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  {
    leap16_r31_emit_metadata_kv bootloader grub
  } >"$td/metadata.conf"
  validate_backup_pre_leap16_r70(){ [[ $1 == "$td" ]]; }
  validate_backup "$td" || fail_test 'non-rEFInd backup no longer delegates to pre-r70 validator'
)

printf 'leap16-r70 selftest: PASS\n'
