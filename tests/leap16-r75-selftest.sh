#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"
layer="$ROOT/lib/leap16_r75.sh"
fail_test(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f $layer ]] || fail_test 'r75 layer missing'
grep -Fq 'SWITCHER_RELEASE="leap16-r75"' "$main" || fail_test 'release is not r75'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r75.sh"' "$main" || fail_test 'r75 layer is not sourced'
[[ $(grep -n 'source "$SCRIPT_DIR/lib/leap16_r75.sh"' "$main" | tail -n1 | cut -d: -f1) -gt \
   $(grep -n 'source "$SCRIPT_DIR/lib/leap16_r74.sh"' "$main" | tail -n1 | cut -d: -f1) ]] \
    || fail_test 'r75 is not the final release layer'
grep -Fq 'leap16_r64_refind_namespace_clean || rc=$?' "$layer" || fail_test 'unchanged r64 clean-target gate is not enforced after cleanup'
grep -Fq 'validate_grub_boot_chain current' "$layer" || fail_test 'canonical GRUB validation is missing'
grep -Fq 'LEAP16_R66_REFIND_DOWNLOAD_MARKER' "$layer" || fail_test 'exact controlled-source marker proof is missing'
grep -Fq 'LEAP16_R64_REFIND_MARKER' "$layer" || fail_test 'managed rEFInd policy marker proof is missing'
grep -Fq 'leap16_r75_firmware_unchanged' "$layer" || fail_test 'full firmware immutability proof is missing'
! grep -Eq 'efibootmgr[[:space:]]+-(b|B|o|n|N|c)|shim-install|grub-install|mkinitcpio' "$layer" \
    || fail_test 'cleanup layer contains a firmware/package/Arch write primitive'

prelude=$(awk '/^select_target_bootloader\(\)/{exit} {print}' "$main" | sed '/^SCRIPT_DIR=/d')
SCRIPT_DIR=$ROOT
eval "$prelude"

# Strict fresh-child contract: cleanup is admitted only as a zero-argument
# grub:refind cleanup action; all pre-existing r64/r73 actions remain usable.
(
  d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
  detect_bootloader(){ BOOTLOADER=grub; }
  leap16_r75_run_cleanup_inner(){ printf 'r75-cleanup-ran\n'; }
  leap16_r73_run_repair_inner(){ printf 'r73-repair-ran\n'; }
  leap16_r64_run_refind_edge_inner(){ printf 'r64-refind:%s\n' "$1"; }
  out=$(leap16_r46_transcript_child "$d" grub refind cleanup leap16_r75_run_cleanup_inner)
  [[ $out == r75-cleanup-ran ]] || fail_test 'fresh-child cleanup dispatch failed'
  out=$(leap16_r46_transcript_child "$d" grub grub repair leap16_r73_run_repair_inner)
  [[ $out == r73-repair-ran ]] || fail_test 'r75 regressed the r73 repair child'
  out=$(leap16_r46_transcript_child "$d" grub refind switch leap16_r64_run_refind_edge_inner refind)
  [[ $out == r64-refind:refind ]] || fail_test 'r75 regressed the r64 stage child'
  leap16_r46_transcript_child "$d" grub refind cleanup leap16_r75_run_cleanup_inner extra >/dev/null 2>&1 \
      && fail_test 'cleanup child accepted an argument'
  leap16_r46_transcript_child "$d" grub refind switch leap16_r75_run_cleanup_inner >/dev/null 2>&1 \
      && fail_test 'cleanup child accepted the wrong kind'
  leap16_r46_transcript_child "$d" grub refind cleanup definitely_not_allowed >/dev/null 2>&1 \
      && fail_test 'arbitrary transcript child was accepted'
  :
)

# Parent dispatch performs cleanup only when GRUB -> rEFInd has occupied target
# paths. A clean target still delegates to the unchanged r64 staging stack.
(
  BOOTLOADER=grub; trace=''
  detect_bootloader(){ BOOTLOADER=grub; }
  leap16_r75_refind_residue_present(){ return 0; }
  leap16_r44_with_transaction_transcript(){ trace="$1:$2:$3:$4:$#"; }
  run_live_operation refind
  [[ $trace == grub:refind:cleanup:leap16_r75_run_cleanup_inner:4 ]] \
      || fail_test "occupied target did not dispatch isolated cleanup ($trace)"
  leap16_r75_refind_residue_present(){ return 1; }
  run_live_operation_pre_leap16_r75(){ trace="delegate:$1"; }
  run_live_operation refind
  [[ $trace == delegate:refind ]] || fail_test 'clean target did not delegate to normal staging'
)

# Ownership proof accepts only the deterministic managed shape. Marker drift or
# a symlink keeps the target blocked and untouched.
(
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  MOCK_ROOT="$td/EFI/refind"; MOCK_LINUXCONF="$td/refind_linux.conf"
  mkdir -p "$MOCK_ROOT/drivers_x64" "$MOCK_ROOT/icons"
  printf 'MZmock\n' >"$MOCK_ROOT/refind_x64.efi"
  printf 'driver\n' >"$MOCK_ROOT/drivers_x64/ext4_x64.efi"
  printf '%s\nscan_all_linux_kernels true\nfollow_symlinks true\nuse_nvram false\nscanfor internal,manual\ndont_scan_dirs EFI/BOOT,EFI/OPENSUSE,EFI/LIMINE,EFI/systemd,EFI/opensuse-bootloader-switcher\n' \
      "$LEAP16_R64_REFIND_MARKER" >"$MOCK_ROOT/refind.conf"
  printf '%s\n' "$LEAP16_R66_REFIND_DOWNLOAD_MARKER" >"$MOCK_ROOT/.opensuse-bootloader-switcher-source"
  clean=$(r26_refind_cmdline "$(cat /proc/cmdline 2>/dev/null || true)")
  printf '"Boot with standard options" "%s"\n"Boot to single-user mode" "%s single"\n' "$clean" "$clean" >"$MOCK_LINUXCONF"
  leap16_r75_refind_root(){ printf '%s\n' "$MOCK_ROOT"; }
  leap16_r75_refind_linuxconf(){ printf '%s\n' "$MOCK_LINUXCONF"; }
  leap16_r48_ids_for_current_esp_path(){ :; }
  validate_refind_boot_chain(){ return 0; }
  ok(){ :; }; fail(){ :; }
  sudo(){ [[ ${1:-} == -n ]] && shift; command "$@"; }
  leap16_r75_prove_orphaned_refind_residue || fail_test 'valid managed residue was not recognized'
  printf 'foreign marker\n' >"$MOCK_ROOT/.opensuse-bootloader-switcher-source"
  ! leap16_r75_prove_orphaned_refind_residue || fail_test 'foreign source marker was accepted'
  printf '%s\n' "$LEAP16_R66_REFIND_DOWNLOAD_MARKER" >"$MOCK_ROOT/.opensuse-bootloader-switcher-source"
  ln -s refind.conf "$MOCK_ROOT/unsafe-link"
  ! leap16_r75_prove_orphaned_refind_residue || fail_test 'symlink-bearing residue was accepted'
)

# Successful cleanup removes only the two residue paths. A post-delete gate
# failure restores both byte-for-byte from the mandatory snapshot.
(
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  MOCK_ROOT="$td/EFI/refind"; MOCK_LINUXCONF="$td/boot/refind_linux.conf"; PENDING_STATE_DIR="$td/state"
  firmware=$'BootCurrent: 0001\nBootOrder: 0001,0003\nBoot0001* opensuse-secureboot\nBoot0003* opensuse'
  make_residue(){
    mkdir -p "$MOCK_ROOT/icons" "$(dirname "$MOCK_LINUXCONF")"
    printf 'efi payload\n' >"$MOCK_ROOT/refind_x64.efi"
    printf 'config\n' >"$MOCK_ROOT/refind.conf"
    printf 'runtime\n' >"$MOCK_ROOT/icons/os.png"
    printf 'linux options\n' >"$MOCK_LINUXCONF"
  }
  make_residue
  before_root=$(find "$MOCK_ROOT" -type f -exec sha256sum {} + | LC_ALL=C sort)
  before_linux=$(sha256sum "$MOCK_LINUXCONF")
  leap16_r75_refind_root(){ printf '%s\n' "$MOCK_ROOT"; }
  leap16_r75_refind_linuxconf(){ printf '%s\n' "$MOCK_LINUXCONF"; }
  leap16_r75_cleanup_preflight(){ return 0; }
  validate_grub_boot_chain(){ return 0; }
  leap16_r64_refind_namespace_clean(){ [[ ! -e $MOCK_ROOT && ! -e $MOCK_LINUXCONF ]]; }
  ok(){ :; }; fail(){ :; }
  sudo(){
    [[ ${1:-} == -n ]] && shift
    if [[ ${1:-} == efibootmgr && ${2:-} == -v ]]; then printf '%s\n' "$firmware"; return 0; fi
    command "$@"
  }
  leap16_r75_execute_cleanup || fail_test 'valid residue cleanup failed'
  [[ ! -e $MOCK_ROOT && ! -e $MOCK_LINUXCONF ]] || fail_test 'cleanup left a residue path behind'

  make_residue
  leap16_r64_refind_namespace_clean(){ return 1; }
  ! leap16_r75_execute_cleanup || fail_test 'post-delete validation failure was accepted'
  [[ -d $MOCK_ROOT && -f $MOCK_LINUXCONF ]] || fail_test 'failed cleanup did not restore both residue paths'
  [[ $(find "$MOCK_ROOT" -type f -exec sha256sum {} + | LC_ALL=C sort) == "$before_root" ]] \
      || fail_test 'restored rEFInd tree is not byte-identical'
  [[ $(sha256sum "$MOCK_LINUXCONF") == "$before_linux" ]] \
      || fail_test 'restored refind_linux.conf is not byte-identical'
)

printf 'leap16-r75 selftest: PASS\n'
