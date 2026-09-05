#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"
layer="$ROOT/lib/leap16_r80.sh"
fail_test(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ -f $layer ]] || fail_test 'r80 layer missing'
grep -Fq 'SWITCHER_RELEASE="leap16-r80"' "$main" || fail_test 'release is not r80'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r80.sh"' "$main" || fail_test 'r80 layer not sourced'

source_effective_stack(){
  local prelude
  prelude=$(awk '/^select_target_bootloader\(\)/{exit} {print}' "$main" | sed '/^SCRIPT_DIR=/d')
  SCRIPT_DIR=$ROOT
  eval "$prelude"
}

# Limine -> rEFInd: source aliases are claimable when the same numeric ID was
# already the same path+ESP in baseline, or when the numeric ID is entirely new.
(
  source_effective_stack
  PENDING_SOURCE=limine; PENDING_TARGET=refind
  leap16_r80_require_baseline(){ return 0; }
  LEAP16_R21_FALLBACK_EFI_PATH='\EFI\BOOT\BOOTX64.EFI'
  MOCK_PRIMARY_IDS='0001 0008'; MOCK_FALLBACK_IDS='0002 0009'
  leap16_r80_current_ids_for_path(){
    [[ $1 == "$LEAP16_R80_LIMINE_PRIMARY_PATH" ]] && printf '%s\n' $MOCK_PRIMARY_IDS || printf '%s\n' $MOCK_FALLBACK_IDS
  }
  leap16_nvram_entry_matches_current_esp(){ return 0; }; nvram_id_matches_path(){ return 0; }
  leap16_r80_id_existed_in_baseline(){ [[ ${1^^} == 0001 || ${1^^} == 0002 ]]; }
  leap16_r80_baseline_id_matches_path_on_transaction_esp(){
    [[ ${1^^}:$2 == "0001:$LEAP16_R80_LIMINE_PRIMARY_PATH" || ${1^^}:$2 == "0002:$LEAP16_R21_FALLBACK_EFI_PATH" ]]
  }
  ok(){ :; }; fail(){ printf 'unexpected fail: %s\n' "$*" >&2; return 1; }
  leap16_r80_verify_limine_source_alias_claims || fail_test 'valid baseline/new Limine source aliases were rejected'
)

# A current source-path alias that reuses an unrelated pre-stage Boot#### must
# fail closed even though its current path+ESP looks like Limine.
(
  source_effective_stack
  PENDING_SOURCE=limine; PENDING_TARGET=refind
  leap16_r80_require_baseline(){ return 0; }
  LEAP16_R21_FALLBACK_EFI_PATH='\EFI\BOOT\BOOTX64.EFI'
  leap16_r80_current_ids_for_path(){ [[ $1 == "$LEAP16_R80_LIMINE_PRIMARY_PATH" ]] && printf '0003\n'; }
  leap16_nvram_entry_matches_current_esp(){ return 0; }; nvram_id_matches_path(){ return 0; }
  leap16_r80_id_existed_in_baseline(){ [[ ${1^^} == 0003 ]]; }
  leap16_r80_baseline_id_matches_path_on_transaction_esp(){ return 1; }
  ok(){ :; }; fail(){ return 1; }
  ! leap16_r80_verify_limine_source_alias_claims >/dev/null 2>&1 || fail_test 'baseline-ID collision was incorrectly claimed as Limine source ownership'
)

# rEFInd -> Limine: normalize post-stage duplicate primary/fallback aliases.
# The recorded primary/fallback remain exact; duplicates are removed from order
# before deletion and the final alias sets converge to exactly one each.
(
  source_effective_stack
  PENDING_FORMAT=${R26_PENDING_FORMAT:-5}; PENDING_SOURCE=refind; PENDING_TARGET=limine; PENDING_PHASE=runtime-validated
  PENDING_TARGET_BOOT_ID=0002; PENDING_OLD_BOOT_ID=0000; BOOTLOADER=limine; BOOT_CURRENT=0004
  leap16_r80_require_baseline(){ return 0; }
  LEAP16_R21_FALLBACK_EFI_PATH='\EFI\BOOT\BOOTX64.EFI'
  MOCK_PRIMARY='0002 0005'; MOCK_FALLBACK='0004 0006'; MOCK_ORDER='0002,0004,0000,0005,0006,0007'; trace=''
  leap16_r64_limine_fallback_staged(){ return 0; }; leap16_r64_limine_fallback_id(){ printf '0004\n'; }
  leap16_r80_current_ids_for_path(){
    [[ $1 == "$LEAP16_R80_LIMINE_PRIMARY_PATH" ]] && printf '%s\n' $MOCK_PRIMARY || printf '%s\n' $MOCK_FALLBACK
  }
  leap16_r80_id_existed_in_baseline(){ return 1; }
  leap16_nvram_entry_matches_current_esp(){ return 0; }; nvram_id_matches_path(){ return 0; }
  boot_id_exists(){
    local q=${1^^} x
    [[ $q == 0000 || $q == 0007 ]] && return 0
    for x in $MOCK_PRIMARY $MOCK_FALLBACK; do [[ ${x^^} == "$q" ]] && return 0; done
    return 1
  }
  leap16_current_boot_order(){ printf '%s\n' "$MOCK_ORDER"; }
  leap16_order_has_id(){ case ",$1," in *",${2^^},"*) return 0;; *) return 1;; esac; }
  sudo(){
    [[ $1 == efibootmgr ]] || return 1; shift
    if [[ ${1:-} == -o ]]; then MOCK_ORDER=${2^^}; trace+=" order=$MOCK_ORDER"; return 0; fi
    if [[ ${1:-} == -b && ${3:-} == -B ]]; then
      local del=${2^^} x new=''
      for x in $MOCK_PRIMARY; do [[ ${x^^} == "$del" ]] || new+="${new:+ }${x^^}"; done; MOCK_PRIMARY=$new
      new=''; for x in $MOCK_FALLBACK; do [[ ${x^^} == "$del" ]] || new+="${new:+ }${x^^}"; done; MOCK_FALLBACK=$new
      trace+=" del=$del"; return 0
    fi
    return 1
  }
  ok(){ :; }; fail(){ printf 'unexpected fail: %s\n' "$*" >&2; return 1; }
  leap16_r80_normalize_limine_aliases_after_fallback_proof || fail_test 'valid post-stage Limine duplicates were not normalized'
  [[ $MOCK_PRIMARY == 0002 ]] || fail_test "primary duplicates survived ($MOCK_PRIMARY)"
  [[ $MOCK_FALLBACK == 0004 ]] || fail_test "fallback duplicates survived ($MOCK_FALLBACK)"
  [[ $MOCK_ORDER == '0002,0004,0000,0007' ]] || fail_test "duplicates were not removed from BootOrder first ($MOCK_ORDER)"
  [[ $trace == *'del=0005'* && $trace == *'del=0006'* ]] || fail_test "expected duplicate deletions absent ($trace)"
)

# A duplicate alias may not recycle any pre-stage numeric ID.
(
  source_effective_stack
  PENDING_FORMAT=${R26_PENDING_FORMAT:-5}; PENDING_SOURCE=refind; PENDING_TARGET=limine; PENDING_PHASE=runtime-validated
  PENDING_TARGET_BOOT_ID=0002; LEAP16_R21_FALLBACK_EFI_PATH='\EFI\BOOT\BOOTX64.EFI'
  leap16_r80_require_baseline(){ return 0; }
  leap16_r64_limine_fallback_staged(){ return 0; }; leap16_r64_limine_fallback_id(){ printf '0004\n'; }
  leap16_r80_current_ids_for_path(){ [[ $1 == "$LEAP16_R80_LIMINE_PRIMARY_PATH" ]] && printf '0002\n0005\n' || printf '0004\n'; }
  leap16_r80_id_existed_in_baseline(){ [[ ${1^^} == 0005 ]]; }
  leap16_nvram_entry_matches_current_esp(){ return 0; }; nvram_id_matches_path(){ return 0; }; boot_id_exists(){ return 0; }
  ok(){ :; }; fail(){ return 1; }
  ! leap16_r80_normalize_limine_aliases_after_fallback_proof >/dev/null 2>&1 || fail_test 'pre-stage ID collision was incorrectly deleted as a Limine duplicate'
)

# Fallback rollback classification must preserve baseline aliases and refuse a
# current fallback that recycled an unrelated baseline ID.  Test the baseline
# path classifier itself against a synthetic complete firmware table.
(
  source_effective_stack
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  cat >"$td/base" <<'B'
BootCurrent: 0000
BootOrder: 0000,0007,0008
Boot0000* openSUSE rEFInd HD(1,GPT,aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,0x800,0xff000)/File(\EFI\REFIND\REFIND_X64.EFI)
Boot0007* UEFI OS HD(1,GPT,aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,0x800,0xff000)/File(\EFI\BOOT\BOOTX64.EFI)
Boot0008* unrelated HD(1,GPT,aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,0x800,0xff000)/File(\EFI\VENDOR\OTHER.EFI)
B
  leap16_r64_baseline_path(){ printf '%s\n' "$td/base"; }
  leap16_r80_transaction_partuuid(){ printf 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n'; }
  ids=$(leap16_r80_baseline_ids_for_path '\EFI\BOOT\BOOTX64.EFI' | paste -sd, -)
  [[ $ids == 0007 ]] || fail_test "baseline fallback classifier returned ${ids:-none}"
  leap16_r80_baseline_id_matches_path_on_transaction_esp 0007 '\EFI\BOOT\BOOTX64.EFI' || fail_test 'exact baseline fallback was not recognized'
  ! leap16_r80_baseline_id_matches_path_on_transaction_esp 0008 '\EFI\BOOT\BOOTX64.EFI' || fail_test 'unrelated baseline ID was misclassified as fallback ownership'
)


# Exact fallback-transfer rollback: preserve the one pre-stage EFI/BOOT alias,
# remove only a post-stage duplicate, restore pre-transfer state, and prove the
# final alias set equals the baseline.
(
  source_effective_stack
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  PENDING_FORMAT=${R26_PENDING_FORMAT:-5}; PENDING_SOURCE=refind; PENDING_TARGET=limine; PENDING_PHASE=runtime-validated
  PENDING_TARGET_BOOT_ID=0002; PENDING_OLD_BOOT_ID=0000; PENDING_ESP_MOUNT="$td/esp"; mkdir -p "$PENDING_ESP_MOUNT"
  PENDING_OLD_FALLBACK_PATH="$td/BOOTX64.EFI"; PENDING_OLD_FALLBACK_EXISTED=0
  PENDING_TARGET_MANIFEST="$td/manifest"; printf manifest >"$PENDING_TARGET_MANIFEST"
  LEAP16_R21_FALLBACK_EFI_PATH='\EFI\BOOT\BOOTX64.EFI'
  MOCK_FALLBACK='0007 0008'; MOCK_ORDER='0002,0007,0000,0008'; MOCK_NEXT=0007; trace=''
  printf primary >"$td/pre.conf"
  leap16_r80_require_baseline(){ return 0; }
  leap16_r64_limine_fallback_staged(){ return 0; }; leap16_r64_limine_fallback_id(){ printf '0007\n'; }
  pending_bootnext_id(){ printf '%s\n' "$MOCK_NEXT"; }
  leap16_r80_baseline_ids_for_path(){ printf '0007\n'; }
  leap16_r80_current_limine_fallback_ids(){ printf '%s\n' $MOCK_FALLBACK; }
  leap16_r80_id_existed_in_baseline(){ [[ ${1^^} == 0007 ]]; }
  boot_id_exists(){ local q=${1^^} x; for x in 0000 0002 $MOCK_FALLBACK; do [[ ${x^^} == "$q" ]] && return 0; done; return 1; }
  leap16_nvram_entry_matches_current_esp(){ return 0; }; nvram_id_matches_path(){ return 0; }
  leap16_current_boot_order(){ printf '%s\n' "$MOCK_ORDER"; }
  leap16_order_has_id(){ case ",$1," in *",${2^^},"*) return 0;; *) return 1;; esac; }
  sudo(){
    if [[ $1 == efibootmgr ]]; then shift
      if [[ ${1:-} == -N ]]; then MOCK_NEXT=''; trace+=' clear-next'; return 0; fi
      if [[ ${1:-} == -o ]]; then MOCK_ORDER=${2^^}; trace+=" order=$MOCK_ORDER"; return 0; fi
      if [[ ${1:-} == -b && ${3:-} == -B ]]; then
        local del=${2^^} x new=''; for x in $MOCK_FALLBACK; do [[ ${x^^} == "$del" ]] || new+="${new:+ }${x^^}"; done
        MOCK_FALLBACK=$new; trace+=" del=$del"; return 0
      fi
    fi
    if [[ $1 == rm ]]; then shift; command rm "$@"; return $?; fi
    return 1
  }
  leap16_r64_limine_preconf_path(){ printf '%s\n' "$td/pre.conf"; }
  leap16_r64_meta_value(){ [[ $1 == limine_primary_conf_hash ]] && printf '%064d\n' 1; }
  r21_atomic_replace(){ cp -f -- "$1" "$2"; }
  leap16_r64_limine_primary_manifest_path(){ printf '%s\n' "$td/no-primary-manifest"; }
  leap16_r64_refresh_limine_manifest(){ return 0; }
  r21_order_primary_then_source_recovery(){ MOCK_ORDER='0002,0000,0007'; trace+=' restore-order'; return 0; }
  leap16_r64_write_meta(){ trace+=' clear-meta'; return 0; }
  verify_pending_candidate_ownership_unchanged(){ return 0; }; leap16_r64_verify_refind_source_passive(){ return 0; }
  ok(){ :; }; fail(){ printf 'unexpected fail: %s\n' "$*" >&2; return 1; }
  leap16_r64_restore_pre_limine_fallback_state || fail_test 'exact fallback rollback failed'
  [[ $MOCK_FALLBACK == 0007 ]] || fail_test "rollback did not restore baseline fallback alias set ($MOCK_FALLBACK)"
  [[ $MOCK_NEXT == '' ]] || fail_test 'rollback did not clear transaction BootNext'
  [[ $trace == *'del=0008'* && $trace == *'restore-order'* && $trace == *'clear-meta'* ]] || fail_test "rollback sequence incomplete ($trace)"
)

# Rollback must refuse to delete a fallback alias whose numeric ID existed in
# the pre-stage table for an unrelated entry.
(
  source_effective_stack
  PENDING_FORMAT=${R26_PENDING_FORMAT:-5}; PENDING_SOURCE=refind; PENDING_TARGET=limine; PENDING_PHASE=runtime-validated
  PENDING_TARGET_BOOT_ID=0002; PENDING_OLD_BOOT_ID=0000; LEAP16_R21_FALLBACK_EFI_PATH='\EFI\BOOT\BOOTX64.EFI'
  MOCK_NEXT=''; trace=''
  leap16_r80_require_baseline(){ return 0; }
  leap16_r64_limine_fallback_staged(){ return 0; }; leap16_r64_limine_fallback_id(){ printf '0007\n'; }
  pending_bootnext_id(){ printf '%s\n' "$MOCK_NEXT"; }
  leap16_r80_baseline_ids_for_path(){ printf '0007\n'; }
  leap16_r80_current_limine_fallback_ids(){ printf '0007\n0008\n'; }
  leap16_r80_id_existed_in_baseline(){ [[ ${1^^} == 0007 || ${1^^} == 0008 ]]; }
  boot_id_exists(){ return 0; }; leap16_nvram_entry_matches_current_esp(){ return 0; }; nvram_id_matches_path(){ return 0; }
  sudo(){ trace+=' MUTATION'; return 0; }
  ok(){ :; }; fail(){ return 1; }
  ! leap16_r64_restore_pre_limine_fallback_state >/dev/null 2>&1 || fail_test 'rollback accepted an unrelated pre-stage ID collision'
  [[ $trace != *MUTATION* ]] || fail_test 'rollback mutated firmware before rejecting baseline-ID collision'
)

# Current alias enumeration failures must propagate.  Ownership code must not
# silently reinterpret a failed efibootmgr/path enumeration as an empty set.
(
  source_effective_stack
  leap16_r48_ids_for_current_esp_path(){ return 1; }
  leap16_nvram_entry_matches_current_esp(){ return 0; }
  nvram_id_matches_path(){ return 0; }
  ! leap16_r80_current_ids_for_path '\EFI\LIMINE\LIMINE_X64.EFI' >/dev/null 2>&1 \
    || fail_test 'current alias enumeration failure was hidden as an empty set'
)

# Restore dispatch must still use the same r64 engines, ensuring r80's live
# finalization/rollback gates also cover both cross-loader restore directions.
grep -Fq 'limine:refind|systemd-boot:refind) leap16_r44_with_transaction_transcript "$source" "$target" restore leap16_r64_restore_refind_backup "$dir"' "$ROOT/lib/leap16_r64.sh" \
  || fail_test 'Limine -> restored rEFInd dispatch is missing'
grep -Fq 'refind:limine) leap16_r44_with_transaction_transcript "$source" "$target" restore leap16_r64_restore_limine_backup_from_refind "$dir"' "$ROOT/lib/leap16_r64.sh" \
  || fail_test 'rEFInd -> restored Limine dispatch is missing'

printf 'leap16-r80 selftest: PASS\n'
