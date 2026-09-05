#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
pass(){ printf 'PASS: %s\n' "$1"; }
fail(){ printf 'FAIL: %s\n' "$1" >&2; exit 1; }

grep -Fq 'SWITCHER_RELEASE="leap16-r41"' bootloader-switcher.sh || fail 'release is not r41'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r41.sh"' bootloader-switcher.sh || fail 'r41 layer is not sourced'
grep -Fq 'direct=$(leap16_r38_direct_id)' lib/leap16_r41.sh || fail 'direct identity is not assigned explicitly'
grep -Fq 'out=("$target" "$direct")' lib/leap16_r41.sh || fail 'final shim/direct order is not built after assignment'

while IFS= read -r f; do bash -n "$f" || fail "syntax: $f"; done < <(find . -type f -name '*.sh' -print | LC_ALL=C sort)
pass 'all shell files parse'

# Reproduce the exact partial-finalization shape from hardware after r40:
# target shim already promoted, source systemd still present, fallback transfer
# already persisted, and firmware churn 0001/0004 still live.  Under set -u the
# r39 helper crashed before touching BootOrder.  r41 must safely converge to
# shim/direct only and delete only the recorded churn IDs.
(
  set -u
  leap16_r38_final_grub_order_without_systemd(){ printf 'OLD_HELPER\n'; }
  leap16_r38_pending(){ return 0; }
  leap16_r38_direct_id(){ printf '0002\n'; }
  leap16_r39_churn_retired_path(){ printf '%s/retired\n' "$tmp"; }
  leap16_r39_recorded_churn_ids(){ printf '0001\n0004\n'; }
  leap16_r39_verify_recorded_churn(){ return 0; }
  leap16_order_has_id(){ [[ ",${1^^}," == *",${2^^},"* ]]; }
  ok(){ printf 'OK:%s\n' "$*"; }
  fail(){ printf 'FAIL:%s\n' "$*" >&2; return 1; }

  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  FW_ORDER='0003,0000,0001,0004'
  declare -A live=([0000]=1 [0001]=1 [0002]=1 [0003]=1 [0004]=1)
  leap16_current_boot_order(){ printf '%s\n' "$FW_ORDER"; }
  boot_id_exists(){ [[ ${live[${1^^}]:-0} == 1 ]]; }
  sudo(){
    [[ $1 == efibootmgr ]] || return 1
    shift
    if [[ ${1:-} == -o ]]; then
      FW_ORDER=$2
      return 0
    fi
    if [[ ${1:-} == -b && ${3:-} == -B ]]; then
      unset 'live['"${2^^}"']'
      return 0
    fi
    return 1
  }

  source lib/leap16_r41.sh
  PENDING_TARGET_BOOT_ID=0003 PENDING_OLD_BOOT_ID=0000
  leap16_r38_final_grub_order_without_systemd
  [[ $FW_ORDER == '0003,0002' ]] || { printf 'bad final order: %s\n' "$FW_ORDER" >&2; exit 1; }
  [[ ${live[0001]:-0} == 0 && ${live[0004]:-0} == 0 ]] || exit 1
  [[ ${live[0000]:-0} == 1 && ${live[0002]:-0} == 1 && ${live[0003]:-0} == 1 ]] || exit 1
)
pass 'partial r40 finalization converges without unbound direct and only churn is retired'

# Non-reverse users of the helper must still delegate to the prior implementation.
(
  leap16_r38_final_grub_order_without_systemd(){ printf 'OLD_HELPER\n'; }
  leap16_r38_pending(){ return 1; }
  source lib/leap16_r41.sh
  [[ $(leap16_r38_final_grub_order_without_systemd) == OLD_HELPER ]] || exit 1
)
pass 'non-reverse helper behavior delegates unchanged'

pass 'r41 focused contract passes'
