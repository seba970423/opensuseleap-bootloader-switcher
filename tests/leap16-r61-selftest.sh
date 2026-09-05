#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"
fail_test(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

grep -Fq 'SWITCHER_RELEASE="leap16-r61"' "$main" || fail_test 'release is not r61'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r61.sh"' "$main" || fail_test 'r61 overlay is not sourced'
grep -Fq 'limine:systemd-boot)' "$ROOT/lib/leap16_r61.sh" || fail_test 'Limine -> systemd-boot restore dispatch is missing'
grep -Fq 'systemd-boot:limine)' "$ROOT/lib/leap16_r61.sh" || fail_test 'systemd-boot -> Limine restore dispatch is missing'

# Production stack must load with both direct restore executors active.
(
  set -u
  SCRIPT_DIR="$ROOT"; export SCRIPT_DIR
  while IFS= read -r line; do [[ $line == source\ * ]] && eval "$line"; done < "$main"
  declare -F leap16_r61_restore_systemd_backup_from_limine >/dev/null || fail_test 'r61 Limine -> restored systemd executor missing'
  declare -F leap16_r61_restore_limine_backup_from_systemd >/dev/null || fail_test 'r61 systemd -> restored Limine executor missing'
  body=$(declare -f restore_backup_interactive)
  grep -Fq 'limine:systemd-boot' <<<"$body" || fail_test 'final restore selector does not expose Limine -> systemd-boot'
  grep -Fq 'systemd-boot:limine' <<<"$body" || fail_test 'final restore selector does not expose systemd-boot -> Limine'
)

# A valid staged firmware table is immutable evidence. Rebinding must skip the
# redundant efibootmgr capture and remove any interrupted atomic scratch file.
(
  set -u
  r13_sync_root_diagnostics_to_user(){ :; }
  restore_plan_interactive(){ :; }
  leap16_r60_valid_efibootmgr_dump(){
    [[ -s $1 ]] && grep -q '^BootCurrent:' "$1" && grep -q '^BootOrder:' "$1" && grep -q '^Boot[0-9A-Fa-f]\{4\}' "$1"
  }
  source "$ROOT/lib/leap16_r61.sh"
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  LEAP16_R44_TRANSACTION_DIAG_DIR="$td/diag"; mkdir -p "$LEAP16_R44_TRANSACTION_DIAG_DIR"
  PENDING_TRANSACTION_SNAPSHOT_DIR="$td/snap"; mkdir -p "$PENDING_TRANSACTION_SNAPSHOT_DIR"
  LEAP16_R44_DIAG_POINTER=diag.pointer
  PENDING_STATE_FILE="$td/pending"; printf 'phase\tboot-armed\n' >"$PENDING_STATE_FILE"
  staged="$LEAP16_R44_TRANSACTION_DIAG_DIR/staged-efibootmgr-v.txt"
  printf 'BootCurrent: 0001\nBootOrder: 0001\nBoot0001* target\n' >"$staged"
  : >"$LEAP16_R44_TRANSACTION_DIAG_DIR/.staged-efibootmgr-v.interrupted"
  calls=0
  efibootmgr(){ calls=$((calls+1)); return 1; }
  before=$(sha256sum -- "$staged")
  leap16_r44_diag_bind_pending
  after=$(sha256sum -- "$staged")
  [[ $before == "$after" ]] || fail_test 'valid staged firmware evidence changed during rebind'
  ((calls == 0)) || fail_test 'valid staged firmware evidence was redundantly recaptured'
  ! find "$LEAP16_R44_TRANSACTION_DIAG_DIR" -maxdepth 1 -type f -name '.staged-efibootmgr-v.*' -print -quit | grep -q . \
    || fail_test 'interrupted staged capture scratch survived rebind'
)

# Trusted root resume sync must also remove a stranded atomic capture without
# changing the pre-r61 sync result.
(
  set -u
  r13_sync_root_diagnostics_to_user(){ return 7; }
  restore_plan_interactive(){ :; }
  r22_conf_value(){
    case $2 in
      user_diagnostic_root) printf '%s\n' "$TEST_DEST" ;;
      user_uid) printf '%s\n' "$(id -u)" ;;
      user_gid) printf '%s\n' "$(id -g)" ;;
    esac
  }
  r22_realpath_m(){ realpath -m -- "$1"; }
  source "$ROOT/lib/leap16_r61.sh"
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  TEST_DEST="$td/diagnostics"; diag="$TEST_DEST/tx"; bundle="$td/bundle"; mkdir -p "$diag" "$bundle"
  LEAP16_R44_DIAG_POINTER=diag.pointer
  printf '%s\n' "$diag" >"$bundle/$LEAP16_R44_DIAG_POINTER"
  : >"$diag/.staged-efibootmgr-v.aborted"
  set +e
  r13_sync_root_diagnostics_to_user "$td/conf" "$bundle" resume
  rc=$?
  set -e
  ((rc == 7)) || fail_test 'r61 resume wrapper did not preserve previous sync status'
  [[ ! -e $diag/.staged-efibootmgr-v.aborted ]] || fail_test 'trusted resume sync left atomic staged-capture residue'
)

# Limine -> systemd restore must set only r44's target substitution variable,
# call the proven generic/direct-edge executor, then clear the substitution.
(
  set -u
  r13_sync_root_diagnostics_to_user(){ :; }
  restore_plan_interactive(){ :; }
  source "$ROOT/lib/leap16_r61.sh"
  expected=/validated/systemd-backup
  checks=0
  leap16_r61_restore_systemd_from_limine_preflight(){ [[ $1 == "$expected" ]] || return 1; checks=$((checks+1)); }
  offer_operation_backup(){ return 0; }
  leap16_r44_diag_bind_pending(){ :; }
  r26_execute_adapter_switch(){
    [[ $1 == systemd-boot ]] || return 91
    [[ ${LEAP16_R44_RESTORE_DIR:-} == "$expected" ]] || return 92
    [[ ${LEAP16_R31_RESTORE_DIR:-} == '' ]] || return 93
    return 23
  }
  set +e
  leap16_r61_restore_systemd_backup_from_limine "$expected" <<<'RESTORE' >/dev/null
  rc=$?
  set -e
  ((rc == 23)) || fail_test 'Limine -> systemd restore did not propagate direct-edge executor status'
  ((checks == 2)) || fail_test 'Limine -> systemd backup was not revalidated at the write boundary'
  [[ -z ${LEAP16_R44_RESTORE_DIR:-} ]] || fail_test 'systemd restore substitution leaked after executor return'
)

# systemd -> Limine restore is symmetrical but must use r31's Limine payload
# substitution hook so r51 still owns both runtime proofs and source retirement.
(
  set -u
  r13_sync_root_diagnostics_to_user(){ :; }
  restore_plan_interactive(){ :; }
  source "$ROOT/lib/leap16_r61.sh"
  expected=/validated/limine-backup
  checks=0
  leap16_r61_restore_limine_from_systemd_preflight(){ [[ $1 == "$expected" ]] || return 1; checks=$((checks+1)); }
  offer_operation_backup(){ return 0; }
  leap16_r44_diag_bind_pending(){ :; }
  r26_execute_adapter_switch(){
    [[ $1 == limine ]] || return 91
    [[ ${LEAP16_R31_RESTORE_DIR:-} == "$expected" ]] || return 92
    [[ ${LEAP16_R44_RESTORE_DIR:-} == '' ]] || return 93
    return 24
  }
  set +e
  leap16_r61_restore_limine_backup_from_systemd "$expected" <<<'RESTORE' >/dev/null
  rc=$?
  set -e
  ((rc == 24)) || fail_test 'systemd -> Limine restore did not propagate direct-edge executor status'
  ((checks == 2)) || fail_test 'systemd -> Limine backup was not revalidated at the write boundary'
  [[ -z ${LEAP16_R31_RESTORE_DIR:-} ]] || fail_test 'Limine restore substitution leaked after executor return'
)

# The new preflights must bind the selected backup to the current proven direct
# source, rather than falling through the old GRUB-only restore preflights.
(
  set -u
  r13_sync_root_diagnostics_to_user(){ :; }
  restore_plan_interactive(){ :; }
  source "$ROOT/lib/leap16_r61.sh"
  LEAP16_R44_SYSTEMD_BACKUP_SCHEMA=leap16-r44-systemd-v1
  validate_backup_compatibility(){ BACKUP_COMPATIBILITY_REASON=''; return 0; }
  load_backup_metadata(){ bootloader=systemd-boot; backup_schema=$LEAP16_R44_SYSTEMD_BACKUP_SCHEMA; return 0; }
  detect_bootloader(){ BOOTLOADER=limine; }
  leap16_r48_preflight(){ [[ $1 == systemd-boot ]]; }
  leap16_r31_backup_kernel_set_matches(){ return 0; }
  r42_portable_limine_cmdline(){ printf 'root=UUID=test quiet\n'; }
  leap16_r44_systemd_backup_payload_valid(){ [[ $2 == 'root=UUID=test quiet' ]]; }
  ok(){ :; }; fail(){ printf 'FAIL-MSG: %s\n' "$*" >&2; }
  leap16_r61_restore_systemd_from_limine_preflight /backup >/dev/null || fail_test 'Limine source was not accepted for restored systemd target'

  leap16_r31_restore_identity_preflight(){ payload_policy=config-efi-splash-plus-staged-payload; return 0; }
  detect_bootloader(){ BOOTLOADER=systemd-boot; }
  leap16_r51_preflight(){ [[ $1 == limine ]]; }
  leap16_r61_validate_limine_backup_payload_for_systemd_source(){ return 0; }
  leap16_r61_restore_limine_from_systemd_preflight /backup >/dev/null || fail_test 'systemd source was not accepted for restored Limine target'
)

# Read-only restore plan wording must no longer claim systemd backup execution is
# GRUB-only or describe the old two-edge matrix.
(
  set -u
  r13_sync_root_diagnostics_to_user(){ :; }
  restore_plan_interactive(){
    printf 'Restore execution is enabled from GRUB2 through the proven GRUB2 -> systemd-boot transaction engine.\n'
    printf 'Restore execution is available from selector [5] on its hardware-proven cross-backend matrix.\n'
  }
  source "$ROOT/lib/leap16_r61.sh"
  out=$(restore_plan_interactive)
  grep -Fq 'enabled from GRUB2 or Limine' <<<"$out" || fail_test 'systemd restore-plan wording still says GRUB-only'
  grep -Fq 'complete hardware-proven GRUB2 <-> Limine <-> systemd-boot cross-backend matrix' <<<"$out" || fail_test 'restore-plan wording still describes incomplete matrix'
)

echo 'PASS: leap16-r61 Limine <-> systemd-boot backup restore regression'
