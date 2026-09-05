#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"
layer="$ROOT/lib/leap16_r63.sh"
fail_test(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f $layer ]] || fail_test 'r63 layer missing'
grep -Fq 'SWITCHER_RELEASE="leap16-r63"' "$main" || fail_test 'release is not r63'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r63.sh"' "$main" || fail_test 'r63 layer is not sourced'
grep -Fq 'shared machine-id parent' "$layer" || fail_test 'r63 shared-parent restore contract is missing'

# r63 must strengthen the existing r61 systemd-source Limine backup validation,
# not replace its integrity/cmdline/kernel checks.
(
  set -u
  base_calls=0 helper_calls=0
  leap16_r61_validate_limine_backup_payload_for_systemd_source(){ base_calls=$((base_calls+1)); [[ $1 == /backup ]]; }
  stage_limine_kernel_entries_from_existing_artifacts(){ :; }
  source "$layer"
  leap16_r63_validate_limine_backup_children_for_systemd_merge(){ helper_calls=$((helper_calls+1)); [[ $1 == /backup ]]; }
  leap16_r61_validate_limine_backup_payload_for_systemd_source /backup
  ((base_calls == 1)) || fail_test 'r61 Limine backup validator was bypassed'
  ((helper_calls == 1)) || fail_test 'r63 exact-child shape validator was not added'
)

# A systemd-source restore must merge only Limine sibling children into the
# existing machine-id parent and leave the exact systemd child untouched.
(
  set -u
  leap16_r61_validate_limine_backup_payload_for_systemd_source(){ :; }
  stage_limine_kernel_entries_from_existing_artifacts(){ printf 'delegated\n'; }
  source "$layer"
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  TEST_ESP="$td/esp"; ESP_MOUNT=$TEST_ESP; TEST_MID=machine123; backup="$td/backup"
  LEAP16_R48_SYSTEMD_CHILD=opensuse-bootloader-switcher
  mkdir -p "$TEST_ESP/$TEST_MID/$LEAP16_R48_SYSTEMD_CHILD" "$backup/files/${TEST_ESP#/}/$TEST_MID/kernel-a" "$backup/files/${TEST_ESP#/}/$TEST_MID/kernel-b"
  printf 'source-owned\n' >"$TEST_ESP/$TEST_MID/$LEAP16_R48_SYSTEMD_CHILD/sentinel"
  printf 'A-kernel\n' >"$backup/files/${TEST_ESP#/}/$TEST_MID/kernel-a/vmlinuz-kernel-a"
  printf 'A-initrd\n' >"$backup/files/${TEST_ESP#/}/$TEST_MID/kernel-a/initrd-kernel-a"
  printf 'B-kernel\n' >"$backup/files/${TEST_ESP#/}/$TEST_MID/kernel-b/vmlinuz-kernel-b"
  printf 'B-initrd\n' >"$backup/files/${TEST_ESP#/}/$TEST_MID/kernel-b/initrd-kernel-b"
  load_backup_metadata(){ esp_mount=$TEST_ESP; machine_id=$TEST_MID; }
  leap16_r48_expected_limine_child_paths(){ printf '%s\n' "$ESP_MOUNT/$TEST_MID/kernel-a" "$ESP_MOUNT/$TEST_MID/kernel-b"; }
  fail(){ printf 'FAIL-MSG: %s\n' "$*" >&2; }
  ok(){ :; }
  sudo(){ [[ ${1:-} == -n ]] && shift; "$@"; }
  BOOTLOADER=systemd-boot
  LEAP16_R31_RESTORE_DIR=$backup

  leap16_r63_validate_limine_backup_children_for_systemd_merge "$backup" || fail_test 'valid Limine sibling backup shape was rejected'
  stage_limine_kernel_entries_from_existing_artifacts || fail_test 'systemd-source Limine sibling merge failed'
  [[ $(cat "$TEST_ESP/$TEST_MID/$LEAP16_R48_SYSTEMD_CHILD/sentinel") == source-owned ]] || fail_test 'systemd source child was modified'
  cmp -s "$backup/files/${TEST_ESP#/}/$TEST_MID/kernel-a/vmlinuz-kernel-a" "$TEST_ESP/$TEST_MID/kernel-a/vmlinuz-kernel-a" || fail_test 'kernel-a was not restored exactly'
  cmp -s "$backup/files/${TEST_ESP#/}/$TEST_MID/kernel-b/initrd-kernel-b" "$TEST_ESP/$TEST_MID/kernel-b/initrd-kernel-b" || fail_test 'kernel-b was not restored exactly'
  [[ -d $TEST_ESP/$TEST_MID/$LEAP16_R48_SYSTEMD_CHILD ]] || fail_test 'systemd source child disappeared'
)

# Backup parent shape is fail-closed: extra/foreign siblings are never merged.
(
  set -u
  leap16_r61_validate_limine_backup_payload_for_systemd_source(){ :; }
  stage_limine_kernel_entries_from_existing_artifacts(){ :; }
  source "$layer"
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  TEST_ESP="$td/esp"; ESP_MOUNT=$TEST_ESP; TEST_MID=machine123; backup="$td/backup"
  LEAP16_R48_SYSTEMD_CHILD=opensuse-bootloader-switcher
  src="$backup/files/${TEST_ESP#/}/$TEST_MID"
  mkdir -p "$src/kernel-a" "$src/foreign"
  load_backup_metadata(){ esp_mount=$TEST_ESP; machine_id=$TEST_MID; }
  leap16_r48_expected_limine_child_paths(){ printf '%s\n' "$ESP_MOUNT/$TEST_MID/kernel-a"; }
  fail(){ :; }
  if leap16_r63_validate_limine_backup_children_for_systemd_merge "$backup"; then
    fail_test 'foreign Limine backup sibling was accepted'
  fi
  rm -rf "$src/foreign"; mkdir -p "$src/$LEAP16_R48_SYSTEMD_CHILD"
  if leap16_r63_validate_limine_backup_children_for_systemd_merge "$backup"; then
    fail_test 'reserved systemd child inside Limine backup was accepted'
  fi
)

# Live shared-parent shape is also re-proved at the copy boundary. A foreign or
# overlapping child must stop staging before any backup child is copied.
(
  set -u
  leap16_r61_validate_limine_backup_payload_for_systemd_source(){ :; }
  stage_limine_kernel_entries_from_existing_artifacts(){ :; }
  source "$layer"
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  TEST_ESP="$td/esp"; ESP_MOUNT=$TEST_ESP; TEST_MID=machine123; backup="$td/backup"
  LEAP16_R48_SYSTEMD_CHILD=opensuse-bootloader-switcher
  src="$backup/files/${TEST_ESP#/}/$TEST_MID"
  mkdir -p "$src/kernel-a" "$TEST_ESP/$TEST_MID/$LEAP16_R48_SYSTEMD_CHILD" "$TEST_ESP/$TEST_MID/foreign"
  printf 'payload\n' >"$src/kernel-a/file"
  load_backup_metadata(){ esp_mount=$TEST_ESP; machine_id=$TEST_MID; }
  leap16_r48_expected_limine_child_paths(){ printf '%s\n' "$ESP_MOUNT/$TEST_MID/kernel-a"; }
  fail(){ :; }; ok(){ :; }
  sudo(){ [[ ${1:-} == -n ]] && shift; "$@"; }
  BOOTLOADER=systemd-boot; LEAP16_R31_RESTORE_DIR=$backup
  if stage_limine_kernel_entries_from_existing_artifacts; then fail_test 'foreign live shared-parent child was accepted'; fi
  [[ ! -e $TEST_ESP/$TEST_MID/kernel-a ]] || fail_test 'copy started before foreign-child rejection'

  rm -rf "$TEST_ESP/$TEST_MID/foreign"; mkdir -p "$TEST_ESP/$TEST_MID/kernel-a"
  if stage_limine_kernel_entries_from_existing_artifacts; then fail_test 'overlapping Limine child was accepted'; fi
)

# Non-systemd-source cases retain the pre-r63 staging implementation exactly.
(
  set -u
  leap16_r61_validate_limine_backup_payload_for_systemd_source(){ :; }
  stage_limine_kernel_entries_from_existing_artifacts(){ printf 'old-stage:%s\n' "${1:-none}"; }
  source "$layer"
  BOOTLOADER=grub
  LEAP16_R31_RESTORE_DIR=/backup
  out=$(stage_limine_kernel_entries_from_existing_artifacts marker)
  [[ $out == old-stage:marker ]] || fail_test 'non-systemd restore staging did not delegate unchanged'
)

echo 'PASS: leap16-r63 systemd-source Limine shared-parent restore merge regression'
