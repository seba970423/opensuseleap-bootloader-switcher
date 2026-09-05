#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
pass(){ printf 'PASS: %s\n' "$1"; }
fail(){ printf 'FAIL: %s\n' "$1" >&2; exit 1; }

grep -Fq 'SWITCHER_RELEASE="leap16-r43"' bootloader-switcher.sh || fail 'release is not r43'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r43.sh"' bootloader-switcher.sh || fail 'r43 layer is not sourced'
grep -Fq 'A same-ESP generic EFI fallback NVRAM alias remains after final GRUB normalization' lib/leap16_r43.sh || fail 'final fallback-NVRAM absence gate missing'

while IFS= read -r f; do bash -n "$f" || fail "syntax: $f"; done < <(find . -type f -name '*.sh' -print | LC_ALL=C sort)
pass 'all shell files parse'

# Reproduce the hardware topology that r42 finalized as 0003,0002,0001.
# Baseline: source systemd 0000 + generic fallback alias 0001.
# Runtime: target shim 0003, direct GRUB 0002, post-stage churn 0004, and
# source 0000.  r43 must converge to 0003,0002 while preserving BOOTX64 bytes.
(
  set -u
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  BASELINE_FILE="$tmp/source-firmware-baseline.txt"
  cat >"$BASELINE_FILE" <<'BASE'
BootCurrent: 0000
BootOrder: 0000,0001
Boot0000* openSUSE systemd-boot HD(1,GPT,81720d70-39ac-4515-a24e-7e00d3b3d438,0x800,0xff000)/File(\EFI\SYSTEMD\SYSTEMD-BOOTX64.EFI)
Boot0001* UEFI OS HD(1,GPT,81720d70-39ac-4515-a24e-7e00d3b3d438,0x800,0xff000)/File(\EFI\BOOT\BOOTX64.EFI)0000424f
BASE

  leap16_r38_final_grub_order_without_systemd(){ printf 'OLD_HELPER\n'; }
  leap16_r38_pending(){ return 0; }
  leap16_r38_direct_id(){ printf '0002\n'; }
  leap16_r34_baseline_path(){ printf '%s\n' "$BASELINE_FILE"; }
  leap16_r39_churn_retired_path(){ printf '%s/retired\n' "$tmp"; }
  leap16_r39_recorded_churn_ids(){ printf '0004\n'; }
  leap16_r39_verify_recorded_churn(){ return 0; }
  leap16_r39_entry_path_for_id(){
    case ${1^^} in
      0001) printf '\\EFI\\BOOT\\BOOTX64.EFI\n' ;;
      0004) printf '\\EFI\\OPENSUSE\\GRUBX64.EFI\n' ;;
      *) return 1 ;;
    esac
  }
  normalize_efi_path(){ local p=${1#\\}; printf '%s\n' "${p//\\//}"; }
  efi_path_from_efibootmgr_line(){
    [[ $1 =~ (\\EFI\\[^[:space:]]*\.[Ee][Ff][Ii]) ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
  }
  lsblk(){ printf '81720d70-39ac-4515-a24e-7e00d3b3d438\n'; }
  r28_transfer_complete(){ return 0; }
  r21_hash_privileged(){ printf '%s\n' "$HASH"; }
  leap16_order_has_id(){ [[ ",${1^^}," == *",${2^^},"* ]]; }
  leap16_nvram_entry_matches_current_esp(){ [[ ${live[${1^^}]:-0} == 1 ]]; }
  ok(){ :; }
  fail(){ printf 'FAIL:%s\n' "$*" >&2; return 1; }

  FW_ORDER='0003,0000,0001,0004'
  declare -A live=([0000]=1 [0001]=1 [0002]=1 [0003]=1 [0004]=1)
  leap16_current_boot_order(){ printf '%s\n' "$FW_ORDER"; }
  boot_id_exists(){ [[ ${live[${1^^}]:-0} == 1 ]]; }
  r21_nvram_ids_for_esp_path(){
    [[ $1 == '\EFI\BOOT\BOOTX64.EFI' ]] || return 0
    [[ ${live[0001]:-0} == 1 ]] && printf '0001\n'
  }
  sudo(){
    [[ $1 == efibootmgr ]] || return 1
    shift
    if [[ ${1:-} == -o ]]; then FW_ORDER=$2; return 0; fi
    if [[ ${1:-} == -b && ${3:-} == -B ]]; then unset 'live['"${2^^}"']'; return 0; fi
    return 1
  }

  HASH=daa744daf0fa40871d8a58e17d4dd456ca816d0d4aa534d96bf744b16a96f374
  PENDING_PHASE=runtime-validated
  PENDING_TARGET_BOOT_ID=0003
  PENDING_OLD_BOOT_ID=0000
  PENDING_ESP_SOURCE=/dev/sdc1
  PENDING_ESP_MOUNT=/boot/efi
  PENDING_TARGET_EFI_HASH=$HASH

  source lib/leap16_r43.sh
  leap16_r38_final_grub_order_without_systemd
  [[ $FW_ORDER == '0003,0002' ]] || { printf 'bad final order: %s\n' "$FW_ORDER" >&2; exit 1; }
  [[ ${live[0001]:-0} == 0 && ${live[0004]:-0} == 0 ]] || exit 1
  [[ ${live[0000]:-0} == 1 && ${live[0002]:-0} == 1 && ${live[0003]:-0} == 1 ]] || exit 1
)
pass 'r42 hardware shape normalizes to shim/direct with EFI fallback alias removed'

# If a baseline fallback ID is reused or changes path/ESP, fail closed before deletion.
(
  set -u
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  BASELINE_FILE="$tmp/source-firmware-baseline.txt"
  cat >"$BASELINE_FILE" <<'BASE'
BootCurrent: 0000
BootOrder: 0000,0001
Boot0001* UEFI OS HD(1,GPT,81720d70-39ac-4515-a24e-7e00d3b3d438,0x800,0xff000)/File(\EFI\BOOT\BOOTX64.EFI)
BASE
  leap16_r38_final_grub_order_without_systemd(){ :; }
  leap16_r38_pending(){ return 0; }
  leap16_r38_direct_id(){ printf '0002\n'; }
  leap16_r34_baseline_path(){ printf '%s\n' "$BASELINE_FILE"; }
  leap16_r39_entry_path_for_id(){ printf '\\EFI\\SOMETHING\\ELSE.EFI\n'; }
  normalize_efi_path(){ local p=${1#\\}; printf '%s\n' "${p//\\//}"; }
  efi_path_from_efibootmgr_line(){ [[ $1 =~ (\\EFI\\[^[:space:]]*\.[Ee][Ff][Ii]) ]] || return 1; printf '%s\n' "${BASH_REMATCH[1]}"; }
  lsblk(){ printf '81720d70-39ac-4515-a24e-7e00d3b3d438\n'; }
  r28_transfer_complete(){ return 0; }
  r21_hash_privileged(){ printf '%s\n' "$HASH"; }
  boot_id_exists(){ return 0; }
  leap16_nvram_entry_matches_current_esp(){ return 0; }
  fail(){ return 1; }
  ok(){ :; }
  HASH=daa744daf0fa40871d8a58e17d4dd456ca816d0d4aa534d96bf744b16a96f374
  PENDING_PHASE=runtime-validated PENDING_TARGET_BOOT_ID=0003 PENDING_OLD_BOOT_ID=0000
  PENDING_ESP_SOURCE=/dev/sdc1 PENDING_ESP_MOUNT=/boot/efi PENDING_TARGET_EFI_HASH=$HASH
  source lib/leap16_r43.sh
  if leap16_r43_verify_baseline_fallback_aliases_for_retirement >/dev/null 2>&1; then exit 1; fi
)
pass 'baseline fallback alias path drift remains fail-closed'

# Non-reverse callers retain the r41 behavior unchanged.
(
  leap16_r38_final_grub_order_without_systemd(){ printf 'OLD_HELPER\n'; }
  leap16_r38_pending(){ return 1; }
  source lib/leap16_r43.sh
  [[ $(leap16_r38_final_grub_order_without_systemd) == OLD_HELPER ]] || exit 1
)
pass 'non-reverse final-order behavior delegates unchanged'

pass 'r43 focused contract passes'
