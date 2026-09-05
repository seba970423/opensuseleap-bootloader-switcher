#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"
fail_test(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

grep -Fq 'SWITCHER_RELEASE="leap16-r60"' "$main" || fail_test 'release is not r60'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r60.sh"' "$main" || fail_test 'r60 overlay is not sourced'

# r59's status text must never enter the hash-valued stdout channel used by
# finalization. This is the exact false-failure seen after the second proof.
(
  set -u
  SCRIPT_DIR="$ROOT"; export SCRIPT_DIR
  while IFS= read -r line; do [[ $line == source\ * ]] && eval "$line"; done < "$main"
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  PENDING_ESP_MOUNT="$td"; printf '/EFI fallback\n' >"$td/limine.conf"
  expected=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  r24_final_fallback_block_present(){ return 0; }
  r21_hash_privileged(){ printf '%s\n' "$expected"; }
  leap16_r54_auth_value(){ [[ $1 == final_conf_hash ]] && printf '%s\n' "$expected" || printf 'unused\n'; }
  ok(){ printf '[OK] %s\n' "$*"; }
  got=$(leap16_r54_finalize_limine_conf_idempotent 2>"$td/status")
  [[ $got == "$expected" ]] || fail_test 'r59 finalizer still polluted its hash-valued stdout channel'
  grep -Fq '[OK] Visible EFI fallback menu contract is already finalized' "$td/status" || fail_test 'r59 finalizer status was not preserved on stderr'
)

# Production stack must load with the diagnostic-only overrides active.
(
  set -u
  SCRIPT_DIR="$ROOT"; export SCRIPT_DIR
  while IFS= read -r line; do [[ $line == source\ * ]] && eval "$line"; done < "$main"
  declare -F leap16_r60_valid_efibootmgr_dump >/dev/null || fail_test 'r60 dump validator missing'
  declare -F leap16_r60_assess_direct_edge_order >/dev/null || fail_test 'r60 direct-edge reporter missing'
  declare -F pending_capture_runtime_diagnostics >/dev/null || fail_test 'r60 runtime collector missing'
)

# A failed late capture must not truncate the already-valid staged table.
(
  leap16_r44_diag_bind_pending(){ :; }
  leap16_pending_firmware_baseline_path(){ :; }
  pending_capture_runtime_diagnostics(){ :; }
  leap16_write_firmware_order_report(){ :; }
  r13_sync_root_diagnostics_to_user(){ :; }
  source "$ROOT/lib/leap16_r60.sh"
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  LEAP16_R44_TRANSACTION_DIAG_DIR="$td/diag"; mkdir -p "$LEAP16_R44_TRANSACTION_DIAG_DIR"
  PENDING_TRANSACTION_SNAPSHOT_DIR="$td/snap"; mkdir -p "$PENDING_TRANSACTION_SNAPSHOT_DIR"
  LEAP16_R44_DIAG_POINTER=pointer
  PENDING_STATE_FILE="$td/pending"; printf 'phase\tboot-armed\n' >"$PENDING_STATE_FILE"
  mode=good
  efibootmgr(){
    [[ $mode == good ]] || return 1
    printf 'BootCurrent: 0001\nBootOrder: 0001,0002\nBoot0001* source\nBoot0002* target\n'
  }
  leap16_r44_diag_bind_pending
  leap16_r60_valid_efibootmgr_dump "$LEAP16_R44_TRANSACTION_DIAG_DIR/staged-efibootmgr-v.txt" || fail_test 'valid staged capture was not installed'
  before=$(sha256sum "$LEAP16_R44_TRANSACTION_DIAG_DIR/staged-efibootmgr-v.txt")
  mode=bad
  leap16_r44_diag_bind_pending
  after=$(sha256sum "$LEAP16_R44_TRANSACTION_DIAG_DIR/staged-efibootmgr-v.txt")
  [[ $before == "$after" ]] || fail_test 'late failed capture truncated/replaced valid staged evidence'
)

# The shared resolver must accept the adapter baseline filename and retain an
# internal cache for reports emitted after transaction snapshot deletion.
(
  leap16_r44_diag_bind_pending(){ :; }
  leap16_pending_firmware_baseline_path(){ return 1; }
  pending_capture_runtime_diagnostics(){ :; }
  leap16_write_firmware_order_report(){ :; }
  r13_sync_root_diagnostics_to_user(){ :; }
  leap16_diag_pending_value(){ :; }
  source "$ROOT/lib/leap16_r60.sh"
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  PENDING_TRANSACTION_SNAPSHOT_DIR="$td/snap"; mkdir -p "$PENDING_TRANSACTION_SNAPSHOT_DIR"
  LEAP16_DIAGNOSTIC_ROOT="$td/diagnostics"; mkdir -p "$LEAP16_DIAGNOSTIC_ROOT"
  printf 'BootCurrent: 0001\nBootOrder: 0001\nBoot0001* source\n' >"$PENDING_TRANSACTION_SNAPSHOT_DIR/source-firmware-baseline.txt"
  [[ $(leap16_pending_firmware_baseline_path) == "$PENDING_TRANSACTION_SNAPSHOT_DIR/source-firmware-baseline.txt" ]] || fail_test 'adapter baseline was not resolved'
  leap16_r60_cache_firmware_baseline
  rm -rf -- "$PENDING_TRANSACTION_SNAPSHOT_DIR"
  [[ $(leap16_pending_firmware_baseline_path) == "$LEAP16_DIAGNOSTIC_ROOT/$LEAP16_R60_BASELINE_CACHE" ]] || fail_test 'cached baseline was not retained after snapshot cleanup'
)

# systemd-boot must use the Leap diagnostic root, never runtime-home/cachyos.
(
  leap16_r44_diag_bind_pending(){ :; }
  leap16_pending_firmware_baseline_path(){ return 1; }
  leap16_write_firmware_order_report(){ :; }
  r13_sync_root_diagnostics_to_user(){ :; }
  leap16_capture_diagnostics(){ local d="$LEAP16_DIAGNOSTIC_ROOT/20260903-test-$1"; mkdir -p "$d"; printf '%s\n' "$d"; }
  source "$ROOT/lib/leap16_r60.sh"
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  LEAP16_DIAGNOSTIC_ROOT="$td/diagnostics"; mkdir -p "$LEAP16_DIAGNOSTIC_ROOT"
  HOME="$td/runtime-home"; PENDING_TARGET=systemd-boot PENDING_SOURCE=limine
  PENDING_SOURCE_CMDLINE='root=UUID=test'; PENDING_OLD_BOOT_ID=0000 PENDING_TARGET_BOOT_ID=0001 PENDING_ORIGINAL_BOOT_ORDER=0000
  out=$(pending_capture_runtime_diagnostics runtime-pass-systemd-from-limine | tail -n1)
  [[ $out == "$LEAP16_DIAGNOSTIC_ROOT/"* ]] || fail_test 'systemd target diagnostic escaped the Leap bundle'
  [[ $out != "$HOME/cachyos-bootloader-diagnostics/"* ]] || fail_test 'systemd target used legacy CachyOS fallback path'
)

# Replay the exact stable EFI-file order shapes observed in the successful r59
# direct-edge hardware runs. Every legitimate phase must report pass, and an
# altered final order must still report fail.
(
  set -u
  SCRIPT_DIR="$ROOT"; export SCRIPT_DIR
  while IFS= read -r line; do [[ $line == source\ * ]] && eval "$line"; done < "$main"
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  TEST_BASELINE="$td/baseline"; TEST_CURRENT="$td/current"; report="$td/report"
  LEAP16_R21_FALLBACK_EFI_PATH='\EFI\BOOT\BOOTX64.EFI'
  leap16_pending_firmware_baseline_path(){ printf '%s\n' "$TEST_BASELINE"; }
  leap16_r60_direct_edge_fallback_id(){ printf '0002\n'; }
  efibootmgr(){ cat -- "$TEST_CURRENT"; }

  PENDING_SOURCE=systemd-boot PENDING_TARGET=limine
  PENDING_OLD_BOOT_ID=0001 PENDING_TARGET_BOOT_ID=0000 PENDING_ORIGINAL_BOOT_ORDER=0001
  PENDING_OLD_BOOT_EFI_PATH='\EFI\systemd\systemd-bootx64.efi'
  PENDING_TARGET_EFI_PATH='\EFI\LIMINE\LIMINE_X64.EFI'
  cat >"$TEST_BASELINE" <<'EOF_BASELINE_SYSTEMD'
BootCurrent: 0001
BootOrder: 0001
Boot0001* openSUSE systemd-boot HD(1,GPT,aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa,0x800,0xff000)/File(\EFI\systemd\systemd-bootx64.efi)
EOF_BASELINE_SYSTEMD
  cat >"$TEST_CURRENT" <<'EOF_RUNTIME_LIMINE'
BootCurrent: 0000
BootOrder: 0001,0000,0002
Boot0000* openSUSE Limine HD(1,GPT,aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa,0x800,0xff000)/File(\EFI\LIMINE\LIMINE_X64.EFI)
Boot0001* openSUSE systemd-boot HD(1,GPT,aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa,0x800,0xff000)/File(\EFI\systemd\systemd-bootx64.efi)
Boot0002* UEFI OS HD(1,GPT,aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa,0x800,0xff000)/File(\EFI\BOOT\BOOTX64.EFI)
EOF_RUNTIME_LIMINE
  leap16_write_firmware_order_report "$report" runtime-pass-limine-from-systemd
  grep -Fxq 'assessment=pass' "$report" || fail_test 'systemd->Limine primary runtime topology did not pass'
  cat >"$TEST_CURRENT" <<'EOF_FALLBACK_LIMINE'
BootNext: 0002
BootCurrent: 0000
BootOrder: 0000,0002,0001
Boot0000* openSUSE Limine HD(1,GPT,aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa,0x800,0xff000)/File(\EFI\LIMINE\LIMINE_X64.EFI)
Boot0001* openSUSE systemd-boot HD(1,GPT,aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa,0x800,0xff000)/File(\EFI\systemd\systemd-bootx64.efi)
Boot0002* UEFI OS HD(1,GPT,aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa,0x800,0xff000)/File(\EFI\BOOT\BOOTX64.EFI)
EOF_FALLBACK_LIMINE
  leap16_write_firmware_order_report "$report" fallback-armed-limine-from-systemd
  grep -Fxq 'assessment=pass' "$report" || fail_test 'systemd->Limine fallback-armed topology did not pass'
  cat >"$TEST_CURRENT" <<'EOF_FINAL_LIMINE'
BootCurrent: 0002
BootOrder: 0000,0002
Boot0000* openSUSE Limine HD(1,GPT,aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa,0x800,0xff000)/File(\EFI\LIMINE\LIMINE_X64.EFI)
Boot0002* UEFI OS HD(1,GPT,aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa,0x800,0xff000)/File(\EFI\BOOT\BOOTX64.EFI)
EOF_FINAL_LIMINE
  leap16_write_firmware_order_report "$report" finalized-limine-from-systemd
  grep -Fxq 'assessment=pass' "$report" || fail_test 'systemd->Limine finalized topology did not pass'
  leap16_write_firmware_order_report "$report" auto-resume-pass
  grep -Fxq 'assessment=pass' "$report" || fail_test 'systemd->Limine post-cleanup topology did not pass'

  PENDING_SOURCE=limine PENDING_TARGET=systemd-boot
  PENDING_OLD_BOOT_ID=0000 PENDING_TARGET_BOOT_ID=0001 PENDING_ORIGINAL_BOOT_ORDER=0000,0002
  PENDING_OLD_BOOT_EFI_PATH='\EFI\LIMINE\LIMINE_X64.EFI'
  PENDING_TARGET_EFI_PATH='\EFI\systemd\systemd-bootx64.efi'
  cat >"$TEST_BASELINE" <<'EOF_BASELINE_LIMINE'
BootCurrent: 0000
BootOrder: 0000,0002
Boot0000* openSUSE Limine HD(1,GPT,aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa,0x800,0xff000)/File(\EFI\LIMINE\LIMINE_X64.EFI)
Boot0002* UEFI OS HD(1,GPT,aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa,0x800,0xff000)/File(\EFI\BOOT\BOOTX64.EFI)
EOF_BASELINE_LIMINE
  cat >"$TEST_CURRENT" <<'EOF_RUNTIME_SYSTEMD'
BootCurrent: 0001
BootOrder: 0000,0002,0001
Boot0000* openSUSE Limine HD(1,GPT,aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa,0x800,0xff000)/File(\EFI\LIMINE\LIMINE_X64.EFI)
Boot0001* openSUSE systemd-boot HD(1,GPT,aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa,0x800,0xff000)/File(\EFI\systemd\systemd-bootx64.efi)
Boot0002* UEFI OS HD(1,GPT,aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa,0x800,0xff000)/File(\EFI\BOOT\BOOTX64.EFI)
EOF_RUNTIME_SYSTEMD
  leap16_write_firmware_order_report "$report" runtime-pass-systemd-from-limine
  grep -Fxq 'assessment=pass' "$report" || fail_test 'Limine->systemd runtime topology did not pass'
  cat >"$TEST_CURRENT" <<'EOF_FINAL_SYSTEMD'
BootCurrent: 0001
BootOrder: 0001
Boot0001* openSUSE systemd-boot HD(1,GPT,aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa,0x800,0xff000)/File(\EFI\systemd\systemd-bootx64.efi)
EOF_FINAL_SYSTEMD
  leap16_write_firmware_order_report "$report" finalized-systemd-from-limine
  grep -Fxq 'assessment=pass' "$report" || fail_test 'Limine->systemd finalized topology did not pass'
  leap16_write_firmware_order_report "$report" auto-resume-pass
  grep -Fxq 'assessment=pass' "$report" || fail_test 'Limine->systemd post-cleanup topology did not pass'

  sed -i 's/BootOrder: 0001/BootOrder: 0001,0002/' "$TEST_CURRENT"
  leap16_write_firmware_order_report "$report" auto-resume-pass
  grep -Fxq 'assessment=fail' "$report" || fail_test 'direct-edge reporter accepted an altered finalized order'
)

# A reboot can terminate the PTY parent before it sanitizes the raw typescript.
# Root resume sync must finish that diagnostic-only work in the same transaction
# directory and mark the handoff without inventing a child exit status.
(
  set -u
  SCRIPT_DIR="$ROOT"; export SCRIPT_DIR
  while IFS= read -r line; do [[ $line == source\ * ]] && eval "$line"; done < "$main"
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  user_home="$td/user-home"; dest="$user_home/user-diagnostics"; diag="$dest/transaction"; bundle="$td/bundle"; conf="$td/resume.conf"
  mkdir -p -- "$diag" "$bundle"
  printf '%s\n' "$diag" >"$bundle/$LEAP16_R44_DIAG_POINTER"
  printf 'user_home\t%s\nuser_diagnostic_root\t%s\nuser_uid\t%s\nuser_gid\t%s\n' "$user_home" "$dest" "$(id -u)" "$(id -g)" >"$conf"
  printf 'release=leap16-r60\n' >"$diag/transaction.conf"
  printf 'Script started on test [COMMAND=x]\r\n\033[32mproof passed\033[0m\r\nScript done on test [COMMAND_EXIT_CODE=0]\r\n' >"$diag/.stage.typescript.raw"
  r13_sync_root_diagnostics_to_user "$conf" "$bundle" success
  [[ -s $diag/stage.log && ! -e $diag/.stage.typescript.raw ]] || fail_test 'resume sync did not finalize the reboot-terminated PTY transcript'
  grep -Fxq 'proof passed' "$diag/stage.log" || fail_test 'resume-sanitized stage transcript lost its payload'
  grep -Fxq 'stage_completion=automatic-reboot-handoff' "$diag/transaction.conf" || fail_test 'resume sync did not record automatic reboot handoff completion'
  ! grep -Eq '^stage_exit=' "$diag/transaction.conf" || fail_test 'resume sync invented a PTY child exit status'
)

# Static scope guard: r60 must not override migration, cleanup, backup, or
# restore executors.
! rg -n '^(r26_finalize_adapter_transaction|adapter_target_promote|adapter_source_snapshot|restore_backup_interactive|create_current_bootloader_backup|run_live_operation)\(\)' "$ROOT/lib/leap16_r60.sh" >/dev/null \
  || fail_test 'r60 escaped diagnostic-only scope'

echo 'PASS: leap16-r60 shared diagnostic lifecycle regression'
