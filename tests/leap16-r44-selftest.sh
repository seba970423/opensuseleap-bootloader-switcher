#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
pass(){ printf 'PASS: %s\n' "$1"; }
fail(){ printf 'FAIL: %s\n' "$1" >&2; exit 1; }

grep -Fq 'SWITCHER_RELEASE="leap16-r44"' bootloader-switcher.sh || fail 'release is not r44'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r44.sh"' bootloader-switcher.sh || fail 'r44 layer is not sourced'
grep -Fq "LEAP16_R44_SYSTEMD_BACKUP_SCHEMA='leap16-r44-systemd-v1'" lib/leap16_r44.sh || fail 'systemd backup schema missing'
grep -Fq 'offer_operation_backup || return 1' lib/leap16_r44.sh || fail 'backup-before-switch offer missing'
grep -Fq 'restore leap16_r44_restore_grub_backup_from_systemd' lib/leap16_r44.sh || fail 'GRUB restore from systemd source not routed'
grep -Fq 'restore leap16_r44_restore_systemd_backup' lib/leap16_r44.sh || fail 'systemd restore from GRUB source not routed'
grep -Fq 'stage.log' lib/leap16_r44.sh || fail 'interactive stage transcript missing'
grep -Fq 'resume.log' lib/leap16_r44.sh || fail 'resume transcript aggregation missing'

while IFS= read -r f; do bash -n "$f" || fail "syntax: $f"; done < <(find . -type f -name '*.sh' -print | LC_ALL=C sort)
pass 'all shell files parse'

# Isolated contract: r44 backup path enumeration must include exactly the
# switcher-owned systemd namespace plus policy/reference paths, not the entire
# loader/entries directory.
(
  set -u
  ESP_MOUNT=/boot/efi
  KERNEL_VERSIONS=(6.12.0-a 6.12.0-b)
  collect_kernels(){ :; }
  leap16_r32_sdboot_payload_root(){ printf '/boot/efi/MID/opensuse-bootloader-switcher\n'; }
  leap16_r32_sdboot_entry_path(){ printf '/boot/efi/loader/entries/opensuse-%s.conf\n' "$1"; }
  backup_paths_for_bootloader(){ printf 'OLD\n'; }
  validate_backup(){ :; }
  create_current_bootloader_backup(){ :; }
  leap16_r32_write_systemd_boot_candidate(){ :; }
  r22_prepare_resume_bundle(){ :; }
  r13_sync_root_diagnostics_to_user(){ :; }
  run_live_operation(){ :; }
  source lib/leap16_r44.sh
  out=$(backup_paths_for_bootloader systemd-boot)
  grep -Fqx '/boot/efi/EFI/systemd' <<<"$out"
  grep -Fqx '/boot/efi/loader/loader.conf' <<<"$out"
  grep -Fqx '/boot/efi/MID/opensuse-bootloader-switcher' <<<"$out"
  grep -Fqx '/boot/efi/loader/entries/opensuse-6.12.0-a.conf' <<<"$out"
  grep -Fqx '/boot/efi/loader/entries/opensuse-6.12.0-b.conf' <<<"$out"
  ! grep -Fqx '/boot/efi/loader/entries' <<<"$out"
)
pass 'systemd backup path set is ownership-bounded'

# The final dispatcher must put a backup offer on both switch directions and
# must not delegate those edges to the old r32/r38 no-backup wrappers.
(
  set -u
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  LEAP16_DIAGNOSTIC_ROOT="$td/diagnostics"
  BOOTLOADER=grub; calls=''
  detect_bootloader(){ :; }
  leap16_r44_diag_begin(){ LEAP16_R44_TRANSACTION_DIAG_DIR=''; return 1; }
  warn(){ :; }
  leap16_r32_systemd_preflight(){ calls+="preflight "; }
  offer_operation_backup(){ calls+="backup "; }
  show_operation_plan(){ calls+="plan "; }
  confirm_operation(){ calls+="confirm "; }
  r26_execute_adapter_switch(){ calls+="execute-$1 "; }
  leap16_r38_preflight(){ calls+="reverse-preflight "; }
  leap16_r38_plan(){ calls+="reverse-plan "; }
  run_live_operation(){ calls+='old '; }
  validate_backup(){ :; }; create_current_bootloader_backup(){ :; }; backup_paths_for_bootloader(){ :; }
  leap16_r32_write_systemd_boot_candidate(){ :; }; r22_prepare_resume_bundle(){ :; }; r13_sync_root_diagnostics_to_user(){ :; }
  source lib/leap16_r44.sh
  run_live_operation systemd-boot
  [[ $calls == *'backup '* && $calls == *'execute-systemd-boot '* && $calls != *'old '* ]] || { echo "$calls"; exit 1; }
  calls=''; BOOTLOADER=systemd-boot
  run_live_operation grub
  [[ $calls == *'backup '* && $calls == *'execute-grub '* && $calls != *'old '* ]] || { echo "$calls"; exit 1; }
)
pass 'both GRUB2/systemd switch directions restore the user backup offer'

pass 'r44 focused contract passes'

# A synthetic r44 systemd payload must pass only with the exact r34+ BLS shape,
# root UUID, payload tree and byte-identical generic fallback reference.
(
  set -u
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  b="$td/backup"; esp_rel='boot/efi'; mid='0123456789abcdef0123456789abcdef'; rootid='11111111-2222-3333-4444-555555555555'
  mkdir -p "$b/files/$esp_rel/EFI/systemd" "$b/files/$esp_rel/loader/entries" \
           "$b/files/$esp_rel/$mid/opensuse-bootloader-switcher/k37" \
           "$b/files/$esp_rel/$mid/opensuse-bootloader-switcher/k35" \
           "$b/references/EFI-BOOT"
  printf 'MZsystemd-test\n' >"$b/files/$esp_rel/EFI/systemd/systemd-bootx64.efi"
  cp "$b/files/$esp_rel/EFI/systemd/systemd-bootx64.efi" "$b/references/EFI-BOOT/BOOTX64.EFI"
  h=$(sha256sum "$b/references/EFI-BOOT/BOOTX64.EFI" | awk '{print $1}')
  printf 'name\tpath\texists\tsha256\nBOOTX64.EFI\t/boot/efi/EFI/BOOT/BOOTX64.EFI\t1\t%s\n' "$h" >"$b/systemd-shared-efi-boot-reference.tsv"
  printf 'k37\nk35\n' >"$b/kernel-versions.txt"
  marker='# Managed by openSUSE Bootloader Switcher leap16-r34'
  cat >"$b/files/$esp_rel/loader/loader.conf" <<EOT
$marker
default opensuse-k37.conf
timeout 5
console-mode keep
editor no
EOT
  for v in k37 k35; do
    cat >"$b/files/$esp_rel/loader/entries/opensuse-$v.conf" <<EOT
$marker
title openSUSE Leap 16
version $v
sort-key opensuse
linux /$mid/opensuse-bootloader-switcher/$v/linux
initrd /$mid/opensuse-bootloader-switcher/$v/initrd
options root=UUID=$rootid quiet intel_pstate=passive
EOT
    printf 'kernel-%s\n' "$v" >"$b/files/$esp_rel/$mid/opensuse-bootloader-switcher/$v/linux"
    printf 'initrd-%s\n' "$v" >"$b/files/$esp_rel/$mid/opensuse-bootloader-switcher/$v/initrd"
  done

  validate_backup(){ :; }; create_current_bootloader_backup(){ :; }; backup_paths_for_bootloader(){ :; }
  leap16_r32_write_systemd_boot_candidate(){ :; }; r22_prepare_resume_bundle(){ :; }; r13_sync_root_diagnostics_to_user(){ :; }; run_live_operation(){ :; }
  pending_cmdline_equivalent(){ [[ $1 == "$2" ]]; }
  have(){ return 1; }
  source lib/leap16_r44.sh
  LEAP16_R34_SDBOOT_MARKER="$marker"; esp_mount='/boot/efi'; machine_id="$mid"; root_uuid="$rootid"; BACKUP_VALIDATION_REASON=''
  leap16_r44_systemd_backup_payload_valid "$b" || { echo "$BACKUP_VALIDATION_REASON" >&2; exit 1; }
  sed -i 's/sort-key opensuse/sort-key wrong/' "$b/files/$esp_rel/loader/entries/opensuse-k35.conf"
  ! leap16_r44_systemd_backup_payload_valid "$b" || exit 1
  [[ $BACKUP_VALIDATION_REASON == *'sort-key'* ]] || { echo "$BACKUP_VALIDATION_REASON" >&2; exit 1; }
)
pass 'systemd backup validator enforces exact BLS/payload/fallback ownership shape'
