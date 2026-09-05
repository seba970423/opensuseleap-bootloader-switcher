#!/usr/bin/env bash
set -u
cd -- "$(dirname -- "$0")/.." || exit 1
failures=0
pass(){ printf '[PASS] %s\n' "$1"; }
fail_test(){ printf '[FAIL] %s\n' "$1" >&2; failures=$((failures+1)); }

printf 'openSUSE Leap 16 r31 focused self-test\n======================================\n\n'

if grep -Eq 'SWITCHER_RELEASE="leap16-r(31|3[2-9]|[4-9][0-9])"' bootloader-switcher.sh \
 && awk '/leap16_r30.sh/{a=NR} /leap16_r31.sh/{b=NR} /leap16_r32.sh/{c=NR} END{exit !(a&&b&&a<b&&(!c||b<c))}' bootloader-switcher.sh; then
  pass 'r31 layer remains loaded in the proven order before later Leap extensions'
else
  fail_test 'r31 layer load order is wrong'
fi

if bash -n bootloader-switcher.sh && for f in lib/*.sh tests/*.sh; do bash -n "$f" || exit 1; done; then
  pass 'all shell files parse'
else
  fail_test 'one or more shell files have syntax errors'
fi

if grep -Fq "printf '[3] Create backup of currently booted bootloader\\n'" bootloader-switcher.sh \
 && grep -Fq "printf '[4] List and validate backups\\n'" bootloader-switcher.sh \
 && grep -Fq "printf '[5] Restore a validated backup\\n'" bootloader-switcher.sh \
 && ! grep -Fq "Restore a validated backup [LOCKED]" bootloader-switcher.sh \
 && grep -Fq "5) restore_backup_interactive; pause ;;" bootloader-switcher.sh \
 && grep -Fq "printf '[6] Show restore plan for a backup (read-only)\\n'" bootloader-switcher.sh; then
  pass 'backup create/list/restore/read-only-plan selectors are exposed and [5] dispatches to the Leap restore menu'
else
  fail_test 'r31 backup/restore menu exposure is wrong'
fi

if grep -Fq '/boot/grub2' lib/leap16_r31.sh \
 && grep -Fq '/etc/sysconfig/bootloader' lib/leap16_r31.sh \
 && grep -Fq '"$esp/EFI/OPENSUSE"' lib/leap16_r31.sh \
 && ! awk '/backup_paths_for_bootloader\(\)/,/^}/' lib/leap16_r31.sh | grep -Fq '/boot/grub '; then
  pass 'GRUB2 user backup path contract is Leap-native (/boot/grub2 + EFI/OPENSUSE)'
else
  fail_test 'GRUB2 backup path contract regressed to CachyOS paths'
fi

if awk '/backup_paths_for_bootloader\(\)/,/^}/' lib/leap16_r31.sh | grep -Fq '"$esp/limine.conf"' \
 && awk '/backup_paths_for_bootloader\(\)/,/^}/' lib/leap16_r31.sh | grep -Fq '"$esp/EFI/LIMINE"' \
 && awk '/backup_paths_for_bootloader\(\)/,/^}/' lib/leap16_r31.sh | grep -Fq '"$esp/$machine_id"' \
 && ! awk '/backup_paths_for_bootloader\(\)/,/^}/' lib/leap16_r31.sh | grep -Fq 'limine-entry-tool'; then
  pass 'Limine user backup path contract matches the hardware-proven Leap payload and has no entry-tool dependency'
else
  fail_test 'Limine backup path contract is wrong'
fi

if grep -Fq 'leap16_r31_emit_metadata_kv backup_platform' lib/leap16_r31.sh \
 && grep -Fq 'leap16_r31_emit_metadata_kv backup_schema' lib/leap16_r31.sh \
 && grep -Fq "rpm -qa --qf" lib/leap16_r31.sh \
 && ! grep -Fq 'pacman -Q >' lib/leap16_r31.sh; then
  pass 'r31 user backups are platform-stamped and record RPM state instead of pacman state'
else
  fail_test 'r31 backup metadata/package-state contract is incomplete'
fi

if grep -Fq 'offer_operation_backup || return 1' lib/leap16_r31.sh \
 && grep -Fq 'grub:limine|limine:grub)' lib/leap16_r31.sh \
 && ! grep -Fq 'No user backup format is enabled in this Leap release' lib/opensuse_leap16.sh; then
  pass 'both proven switch directions offer a user backup before STAGE and stale no-backup text is gone'
else
  fail_test 'operation backup offer is not wired correctly'
fi

if grep -Fq 'automatically stage the genuine EFI fallback and reboot the machine ONE MORE TIME' lib/leap16_r31.sh \
 && grep -Fq 'authorize the possible automatic second reboot' lib/leap16_r31.sh \
 && grep -Fq 'No additional automatic reboot is expected after this fallback proof completes.' lib/leap16_r31.sh; then
  pass 'two-reboot GRUB2->Limine choreography is explicitly disclosed before the first reboot'
else
  fail_test 'second-reboot warning/authorization text is missing'
fi

# Metadata serialization must accept the real Limine label containing a space;
# inherited printf %q output (openSUSE\ Limine) is rejected by the safe loader.
(
  source lib/common.sh
  source lib/backup.sh
  source lib/r27.sh
  confirm_operation(){ :; }
  source lib/leap16_r31.sh
  t=$(mktemp -d); trap 'rm -rf -- "$t"' EXIT
  {
    leap16_r31_emit_metadata_kv format_version 4
    leap16_r31_emit_metadata_kv backup_platform opensuse-leap16
    leap16_r31_emit_metadata_kv backup_schema leap16-r31-v1
    leap16_r31_emit_metadata_kv bootloader limine
    leap16_r31_emit_metadata_kv boot_label 'openSUSE Limine'
  } >"$t/metadata.conf"
  load_backup_metadata "$t" || exit 1
  [[ $boot_label == 'openSUSE Limine' ]] || exit 2
)
case $? in
  0) pass 'r31 metadata serializer round-trips the real spaced Limine NVRAM label safely' ;;
  *) fail_test 'r31 backup metadata serializer cannot round-trip the Limine label' ;;
esac

# Functional prompt wrapper: proven live directions must call the backup offer
# before delegating to the inherited typed write-boundary confirmation.
(
  validate_backup(){ :; }
  confirm_operation(){ printf 'old-confirm\n'; }
  source lib/leap16_r31.sh
  order=''
  offer_operation_backup(){ order="${order}backup "; return 0; }
  confirm_operation_pre_leap16_r31(){ order="${order}confirm"; return 0; }
  confirm_operation grub limine || exit 1
  [[ $order == 'backup confirm' ]] || { printf 'order=%q\n' "$order" >&2; exit 2; }
)
case $? in
  0) pass 'backup offer executes before inherited STAGE confirmation' ;;
  *) fail_test 'backup offer/confirmation ordering is wrong' ;;
esac

# Functional path fixture without touching host boot state.
(
  validate_backup(){ :; }
  confirm_operation(){ :; }
  source lib/leap16_r31.sh
  ESP_MOUNT=/boot/efi
  out=$(backup_paths_for_bootloader grub) || exit 1
  grep -Fxq '/etc/default/grub' <<<"$out" || exit 2
  grep -Fxq '/etc/sysconfig/bootloader' <<<"$out" || exit 3
  grep -Fxq '/boot/grub2' <<<"$out" || exit 4
  grep -Fxq '/boot/efi/EFI/OPENSUSE' <<<"$out" || exit 5
  machine=$(cat /etc/machine-id 2>/dev/null || true)
  out=$(backup_paths_for_bootloader limine) || exit 6
  grep -Fxq '/boot/efi/limine.conf' <<<"$out" || exit 7
  grep -Fxq '/boot/efi/EFI/LIMINE' <<<"$out" || exit 8
  [[ -z $machine ]] || grep -Fxq "/boot/efi/$machine" <<<"$out" || exit 9
)
case $? in
  0) pass 'backup path helper emits the exact GRUB2 and Limine Leap paths' ;;
  *) fail_test 'backup path helper fixture failed' ;;
esac


# Synthetic GRUB backup validation: platform/schema markers and Leap-native
# payload are required, and those markers must not leak across validations.
(
  source lib/common.sh
  source lib/backup.sh
  source lib/r27.sh
  confirm_operation(){ :; }
  source lib/leap16_r31.sh
  t=$(mktemp -d); trap 'rm -rf -- "$t"' EXIT
  mkbackup(){
    local d=$1 stamped=$2
    mkdir -p "$d/files/etc/default" "$d/files/boot/grub2" "$d/files/boot/efi/EFI/OPENSUSE"
    printf 'GRUB_DEFAULT=saved\n' >"$d/files/etc/default/grub"
    printf 'cfg\n' >"$d/files/boot/grub2/grub.cfg"
    printf 'shim\n' >"$d/files/boot/efi/EFI/OPENSUSE/SHIM.EFI"
    printf 'pkg\n' >"$d/package-state.txt"
    {
      printf 'name\tpath\texists\tsha256\n'
      printf 'BOOTX64.EFI\t/boot/efi/EFI/BOOT/BOOTX64.EFI\t0\t\n'
      printf 'fallback.efi\t/boot/efi/EFI/BOOT/fallback.efi\t0\t\n'
      printf 'MokManager.efi\t/boot/efi/EFI/BOOT/MokManager.efi\t0\t\n'
    } >"$d/grub-shared-efi-boot-reference.tsv"
    {
      printf 'format_version=4\n'
      [[ $stamped == 1 ]] && printf 'backup_platform=opensuse-leap16\nbackup_schema=leap16-r31-v1\n'
      printf 'bootloader=grub\npayload_policy=opensuse-bootloader-owned-paths\n'
      printf 'machine_id=test-machine\nesp_source=/dev/test1\nesp_mount=/boot/efi\nesp_uuid=ESP-TEST\nroot_source=/dev/test2\nroot_uuid=ROOT-TEST\n'
      printf 'boot_current=0003\nboot_label=opensuse-secureboot\nboot_efi_path=\\\\EFI\\\\OPENSUSE\\\\SHIM.EFI\n'
    } >"$d/metadata.conf"
    create_manifest_hashes "$d"
  }
  mkbackup "$t/good" 1
  validate_backup "$t/good" || { printf 'good reason=%s\n' "$BACKUP_VALIDATION_REASON" >&2; exit 11; }
  mkbackup "$t/old" 0
  ! validate_backup "$t/old" || exit 12
  [[ $BACKUP_VALIDATION_REASON == 'backup was not created by the openSUSE Leap backup layer' ]] || { printf 'old reason=%s\n' "$BACKUP_VALIDATION_REASON" >&2; exit 13; }
)
case $? in
  0) pass 'backup validator accepts the r31 Leap GRUB schema and rejects an unstamped older backup without stale-global leakage' ;;
  *) fail_test 'r31 backup schema validation fixture failed' ;;
esac


# The metadata loader uses shell globals. A malformed backup must never inherit
# machine/storage identity from a previously validated backup.
(
  source lib/common.sh
  source lib/backup.sh
  source lib/r27.sh
  confirm_operation(){ :; }
  source lib/leap16_r31.sh
  t=$(mktemp -d); trap 'rm -rf -- "$t"' EXIT
  mkbackup(){
    local d=$1 include_identity=$2
    mkdir -p "$d/files/etc/default" "$d/files/boot/grub2" "$d/files/boot/efi/EFI/OPENSUSE"
    printf 'GRUB_DEFAULT=saved\n' >"$d/files/etc/default/grub"
    printf 'cfg\n' >"$d/files/boot/grub2/grub.cfg"
    printf 'shim\n' >"$d/files/boot/efi/EFI/OPENSUSE/SHIM.EFI"
    printf 'pkg\n' >"$d/package-state.txt"
    printf 'name\tpath\texists\tsha256\nBOOTX64.EFI\t/boot/efi/EFI/BOOT/BOOTX64.EFI\t0\t\nfallback.efi\t/boot/efi/EFI/BOOT/fallback.efi\t0\t\nMokManager.efi\t/boot/efi/EFI/BOOT/MokManager.efi\t0\t\n' >"$d/grub-shared-efi-boot-reference.tsv"
    {
      printf 'format_version=4\nbackup_platform=opensuse-leap16\nbackup_schema=leap16-r31-v1\nbootloader=grub\npayload_policy=opensuse-bootloader-owned-paths\n'
      if [[ $include_identity == 1 ]]; then
        printf 'machine_id=test-machine\nesp_source=/dev/test1\nesp_mount=/boot/efi\nesp_uuid=ESP-TEST\nroot_source=/dev/test2\nroot_uuid=ROOT-TEST\n'
      else
        printf 'esp_source=/dev/test1\nesp_mount=/boot/efi\nesp_uuid=ESP-TEST\nroot_source=/dev/test2\nroot_uuid=ROOT-TEST\n'
      fi
      printf 'boot_current=0003\nboot_label=opensuse-secureboot\nboot_efi_path=\\EFI\\OPENSUSE\\SHIM.EFI\n'
    } >"$d/metadata.conf"
    create_manifest_hashes "$d"
  }
  mkbackup "$t/good" 1
  validate_backup "$t/good" || exit 21
  mkbackup "$t/missing-machine" 0
  ! validate_backup "$t/missing-machine" || exit 22
  [[ $BACKUP_VALIDATION_REASON == 'machine ID missing' ]] || { printf 'reason=%s\n' "$BACKUP_VALIDATION_REASON" >&2; exit 23; }
)
case $? in
  0) pass 'backup validation clears inherited metadata globals before reading each backup' ;;
  *) fail_test 'backup metadata stale-global isolation failed' ;;
esac

# Both proven live switch directions must offer the user-owned backup before the
# inherited typed write-boundary confirmation.
(
  validate_backup(){ :; }
  confirm_operation(){ :; }
  source lib/leap16_r31.sh
  order=''
  offer_operation_backup(){ order="${order}backup "; return 0; }
  confirm_operation_pre_leap16_r31(){ order="${order}confirm"; return 0; }
  confirm_operation limine grub || exit 31
  [[ $order == 'backup confirm' ]] || { printf 'order=%q\n' "$order" >&2; exit 32; }
)
case $? in
  0) pass 'reverse Limine -> GRUB2 switch also offers backup before STAGE confirmation' ;;
  *) fail_test 'reverse backup offer/confirmation ordering is wrong' ;;
esac


if grep -Fq 'limine:grub) leap16_r31_restore_grub_backup "$dir"' lib/leap16_r31.sh \
 && grep -Fq 'grub:limine) leap16_r31_restore_limine_backup "$dir"' lib/leap16_r31.sh \
 && grep -Fq 'r28_execute_limine_to_rebuilt_grub' lib/leap16_r31.sh \
 && grep -Fq 'execute_grub_to_limine' lib/leap16_r31.sh \
 && ! awk '/restore_backup_interactive\(\)/,/^}/' lib/leap16_r31.sh | grep -Eq 'pacman|mkinitcpio|limine-install'; then
  pass 'restore selector routes only GRUB2 <-> Limine through Leap-native transaction engines, not CachyOS restore commands'
else
  fail_test 'restore selector is not safely bound to the Leap-native transaction engines'
fi

if grep -Fq 'LEAP16_R31_RESTORE_DIR' lib/leap16_r31.sh \
 && grep -Fq 'Prepared /etc/default/grub from the selected validated Leap backup' lib/leap16_r31.sh \
 && grep -Fq 'Frozen validated Limine backup EFI+splash bytes into the private transaction snapshot' lib/leap16_r31.sh \
 && grep -Fq 'Restored self-contained Limine managed kernel/initrd tree with VFAT-safe copy semantics' lib/leap16_r31.sh; then
  pass 'restore staging substitutes validated backup target payloads while retaining the proven Leap transaction choreography'
else
  fail_test 'restore target-payload substitution hooks are incomplete'
fi

(
  validate_backup(){ :; }
  validate_backup_compatibility(){ return 0; }
  load_backup_metadata(){ bootloader=${TEST_TARGET:-grub}; return 0; }
  discover_backups_quiet(){ DISCOVERED_BACKUPS=(/tmp/fake-backup); }
  list_backups(){ printf '[1] fake\n'; }
  collect_kernels(){ KERNEL_VERSIONS=(test); }
  collect_storage_info(){ :; }
  confirm_operation(){ :; }
  source lib/leap16_r31.sh
  detect_bootloader(){ BOOTLOADER=${TEST_SOURCE:-limine}; }
  leap16_r31_restore_grub_backup(){ printf 'route=grub\n'; }
  leap16_r31_restore_limine_backup(){ printf 'route=limine\n'; }
  TEST_SOURCE=limine TEST_TARGET=grub
  out=$(restore_backup_interactive <<<'1') || exit 41
  grep -Fq 'route=grub' <<<"$out" || exit 42
  TEST_SOURCE=grub TEST_TARGET=limine
  out=$(restore_backup_interactive <<<'1') || exit 43
  grep -Fq 'route=limine' <<<"$out" || exit 44
)
case $? in
  0) pass 'interactive restore dispatcher selects the correct Leap-native GRUB2/Limine target backend' ;;
  *) fail_test 'interactive restore dispatcher fixture failed' ;;
esac


# Real source-order regression: opensuse_leap16.sh defines old Phase-0 backup
# listing stubs, so leap16_r31.sh must explicitly replace them. This is the
# exact path used by the shipped entrypoint and caught the hardware test bug
# where the menu counted two backups but [5] printed "not ported in Phase 0".
(
  source lib/common.sh
  source lib/storage.sh
  source lib/detect.sh
  source lib/kernels.sh
  source lib/validate.sh
  source lib/limine_validate.sh
  source lib/grub_validate.sh
  source lib/systemd_boot_validate.sh
  source lib/refind_validate.sh
  source lib/backup.sh
  source lib/operations.sh
  source lib/staged.sh
  source lib/r21.sh
  source lib/r22.sh
  source lib/r23.sh
  source lib/restore.sh
  source lib/r25.sh
  source lib/r26.sh
  source lib/r27.sh
  source lib/r28.sh
  source lib/r29.sh
  source lib/r30.sh
  source lib/r31.sh
  source lib/r32.sh
  source lib/r33.sh
  source lib/r34.sh
  source lib/r35.sh
  source lib/r36.sh
  source lib/r37.sh
  source lib/r38.sh
  source lib/r39.sh
  source lib/r40.sh
  source lib/r41.sh
  source lib/r42.sh
  source lib/r43.sh
  source lib/r44.sh
  source lib/r45.sh
  source lib/r46.sh
  source lib/r47.sh
  source lib/opensuse_leap16.sh
  source lib/leap16_r21.sh
  source lib/leap16_r22.sh
  source lib/leap16_r23.sh
  source lib/leap16_r24.sh
  source lib/leap16_r25.sh
  source lib/leap16_r26.sh
  source lib/leap16_r27.sh
  source lib/leap16_r28.sh
  source lib/leap16_r29.sh
  source lib/leap16_r30.sh
  source lib/leap16_r31.sh

  ! declare -f list_backups | grep -Fq 'Backup validation is not ported in Phase 0' || exit 51
  ! declare -f list_backups_interactive | grep -Fq 'Backup validation is not ported in Phase 0' || exit 52
  declare -f restore_backup_interactive | grep -Fq 'leap16_r31_restore_limine_backup' || exit 53
)
case $? in
  0) pass 'shipped source order replaces obsolete Phase-0 backup-list stubs before restore selector runs' ;;
  *) fail_test 'Phase-0 backup-list stub still shadows r31 restore/listing path' ;;
esac

if (( failures == 0 )); then
  printf '\nAll focused openSUSE Leap 16 r31 self-tests passed.\n'
  exit 0
fi
printf '\n%d focused r31 self-test(s) failed.\n' "$failures" >&2
exit 1
