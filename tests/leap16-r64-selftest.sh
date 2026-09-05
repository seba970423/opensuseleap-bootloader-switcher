#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"
layer="$ROOT/lib/leap16_r64.sh"
fail_test(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f $layer ]] || fail_test 'r64 layer missing'
grep -Fq 'SWITCHER_RELEASE="leap16-r64"' "$main" || fail_test 'release is not r64'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r64.sh"' "$main" || fail_test 'r64 layer is not sourced'
grep -Fq -- '--matrix) leap16_r64_print_matrix' "$main" || fail_test '--matrix is not wired'
! grep -Eq '(^|[^[:alnum:]_])pacman([^[:alnum:]_]|$)' "$layer" || fail_test 'r64 layer contains an inherited pacman execution path'
grep -Fq 'zypper --non-interactive --no-recommends install refind' "$layer" || fail_test 'native zypper rEFInd install path missing'
grep -Fq 'drivers_x64/ext4_x64.efi' "$layer" || fail_test 'ext4 rEFInd driver contract missing'
grep -Fq 'dont_scan_dirs EFI/BOOT,EFI/OPENSUSE,EFI/LIMINE,EFI/systemd,EFI/opensuse-bootloader-switcher' "$layer" || fail_test 'rEFInd scanner isolation policy missing'
grep -Fq 'mutable EFI/refind/vars must not be present' "$layer" || fail_test 'mutable rEFInd vars backup exclusion missing'
grep -Fq 'FALLBACK-RUNTIME-VALIDATED' "$layer" || fail_test 'rEFInd -> Limine second-proof state machine missing'

# Source the effective stack without executing main.
source_effective_stack(){
  local prelude
  prelude=$(awk '/^select_target_bootloader\(\)/{exit} {print}' "$main" | sed '/^SCRIPT_DIR=/d')
  SCRIPT_DIR=$ROOT
  eval "$prelude"
}

(
  set -u
  source_effective_stack
  local_edges=(
    'grub refind' 'limine refind' 'systemd-boot refind'
    'refind grub' 'refind limine' 'refind systemd-boot'
  )
  for pair in "${local_edges[@]}"; do
    read -r s t <<<"$pair"
    leap16_r64_refind_edge "$s" "$t" || fail_test "live rEFInd edge $s->$t not enabled"
  done
  matrix=$(leap16_r64_print_matrix)
  grep -Fq 'GRUB2          —            HW-PROVEN    HW-PROVEN     HW-PENDING' <<<"$matrix" || fail_test 'live matrix ledger missing GRUB->rEFInd HW-PENDING'
  grep -Fq 'rEFInd         HW-PENDING   HW-PENDING    HW-PENDING    —' <<<"$matrix" || fail_test 'matrix ledger missing outbound rEFInd edges'
  rf=$(declare -f restore_backup_interactive); [[ $rf == *'grub:refind'* && $rf == *'limine:refind'* && $rf == *'systemd-boot:refind'* ]] || fail_test 'inbound rEFInd restore selector missing'
  [[ $(declare -f restore_backup_interactive) == *'refind:grub'* && $(declare -f restore_backup_interactive) == *'refind:limine'* && $(declare -f restore_backup_interactive) == *'refind:systemd-boot'* ]] || fail_test 'outbound rEFInd restore selectors missing'
  [[ $(declare -f leap16_r46_transcript_child) == *'leap16_r64_restore_refind_backup'* ]] || fail_test 'strict transcript allowlist missing inbound rEFInd restore executor'
  [[ $(declare -f leap16_r46_transcript_child) == *'leap16_r64_restore_limine_backup_from_refind'* ]] || fail_test 'strict transcript allowlist missing outbound rEFInd restore executor'
  [[ $(declare -f r22_resume_transaction_root) == *'leap16_r64_refind_edge'* ]] || fail_test 'root resume does not intercept rEFInd edges'
  [[ $(declare -f rollback_pending_candidate) == *'leap16_r64_pending_edge'* ]] || fail_test 'rollback does not intercept rEFInd edges'
)

# Config rewrite must deterministically isolate auto-scanning from all managed
# EFI namespaces while leaving rEFInd direct-kernel scanning enabled.
(
  set -u
  source_effective_stack
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  ESP_MOUNT="$td/esp"; mkdir -p "$ESP_MOUNT/EFI/refind"
  cat >"$ESP_MOUNT/EFI/refind/refind.conf" <<'CONF'
timeout 20
use_nvram true
scanfor internal,external,optical
scan_all_linux_kernels false
dont_scan_dirs EFI/foo
CONF
  is_leap16(){ return 0; }
  sudo(){ [[ ${1:-} == -n ]] && shift; "$@"; }
  ok(){ :; }; fail(){ printf 'FAIL-MSG: %s\n' "$*" >&2; }
  leap16_r64_patch_refind_config >/dev/null || fail_test 'rEFInd config rewrite failed'
  conf="$ESP_MOUNT/EFI/refind/refind.conf"
  grep -Fxq 'use_nvram false' "$conf" || fail_test 'use_nvram=false missing after rewrite'
  grep -Fxq 'scanfor internal,manual' "$conf" || fail_test 'scanfor policy missing after rewrite'
  grep -Fxq 'scan_all_linux_kernels true' "$conf" || fail_test 'direct-kernel scanning missing after rewrite'
  grep -Fxq 'dont_scan_dirs EFI/BOOT,EFI/OPENSUSE,EFI/LIMINE,EFI/systemd,EFI/opensuse-bootloader-switcher' "$conf" || fail_test 'managed namespace exclusion missing after rewrite'
  [[ $(grep -c '^use_nvram ' "$conf") == 1 ]] || fail_test 'config rewrite left duplicate use_nvram directives'
)

# Immutable rEFInd manifests and restore copies must exclude vars/PreviousBoot.
(
  set -u
  source_effective_stack
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  src="$td/src"; dst="$td/dst"; mkdir -p "$src/vars" "$src/drivers_x64"
  printf 'MZpayload\n' >"$src/refind_x64.efi"
  printf 'cfg\n' >"$src/refind.conf"
  printf 'driver\n' >"$src/drivers_x64/ext4_x64.efi"
  printf 'STALE\n' >"$src/vars/PreviousBoot"
  m="$td/manifest"
  r35_refind_tree_manifest "$src" "$m" user || fail_test 'immutable rEFInd manifest failed'
  ! grep -q 'vars' "$m" || fail_test 'mutable vars leaked into immutable manifest'
  sudo(){ [[ ${1:-} == -n ]] && shift; "$@"; }
  ok(){ :; }; fail(){ printf 'FAIL-MSG: %s\n' "$*" >&2; }
  r35_restore_refind_immutable_tree "$src" "$dst" >/dev/null || fail_test 'immutable rEFInd restore copy failed'
  [[ -f $dst/refind_x64.efi && -f $dst/drivers_x64/ext4_x64.efi ]] || fail_test 'immutable rEFInd payload missing after restore'
  [[ ! -e $dst/vars ]] || fail_test 'stale PreviousBoot vars were restored'
)

# Restore result text must retain backup provenance.
(
  set -u
  source_effective_stack
  PENDING_SOURCE=grub; PENDING_TARGET=refind; PENDING_BACKUP_PATH=/backup/refind-test
  out=$(leap16_r64_result_detail success 0001 2>/dev/null || true)
  [[ $out == *'/backup/refind-test'* || $(declare -f leap16_r64_result_detail) == *'PENDING_BACKUP_PATH'* ]] || fail_test 'restore result provenance is not retained'
)

# Finalizers must prove final target shape before source deletion.
(
  set -u
  source_effective_stack
  sf=$(declare -f leap16_r64_finalize_refind_to_systemd)
  gf=$(declare -f leap16_r64_finalize_refind_to_grub)
  lf=$(declare -f leap16_r64_retire_refind_after_limine_fallback_proof)
  [[ ${sf%%leap16_r64_delete_refind_source*} == *'leap16_r51_systemd_source_gate'* ]] || fail_test 'systemd final topology is not proven before rEFInd deletion'
  [[ ${gf%%leap16_r64_delete_refind_source*} == *'leap16_r38_transfer_grub_fallback'* ]] || fail_test 'GRUB native fallback is not proven before rEFInd deletion'
  [[ ${lf%%leap16_r64_delete_refind_source*} == *'leap16_r64_remove_limine_refind_recovery_block'* && ${lf%%leap16_r64_delete_refind_source*} == *'verify_pending_candidate_ownership_unchanged'* ]] || fail_test 'final Limine config is not frozen/proven before rEFInd deletion'
)


# Final audit: rEFInd is deliberately fail-closed outside the first
# hardware-test topology (/boot on ext4 root), and package acquisition has a
# trusted local-RPM escape hatch instead of an unpinned network downloader.
grep -Fq 'leap16_r64_require_tested_boot_filesystem' "$layer" || fail_test 'tested /boot filesystem gate missing'
grep -Fq 'BOOTLOADER_SWITCHER_REFIND_RPM' "$layer" || fail_test 'trusted local rEFInd RPM override missing'
grep -Fq 'rpm -K -- "$rpm_path"' "$layer" || fail_test 'local rEFInd RPM integrity/signature gate missing'
! grep -Eq 'curl.+refind|wget.+refind' "$layer" || fail_test 'r64 must not fetch an unpinned rEFInd package'
grep -Fq 'running openSUSE Leap kernel' "$layer" || fail_test 'Leap-specific PreviousBoot proof diagnostics missing'

# Verify the filesystem topology gate accepts only /boot on the ext4 root.
(
  set -u
  source_effective_stack
  fail(){ :; }; ok(){ :; }
  findmnt(){
    case "$*" in
      *'-M / -o SOURCE'*) printf '/dev/sdc2\n' ;;
      *'-M / -o FSTYPE'*) printf 'ext4\n' ;;
      *'-T /boot -o SOURCE'*) printf '/dev/sdc2\n' ;;
      *'-T /boot -o FSTYPE'*) printf 'ext4\n' ;;
      *) return 1 ;;
    esac
  }
  leap16_r64_require_tested_boot_filesystem || fail_test 'tested ext4-root /boot topology was rejected'
  findmnt(){
    case "$*" in
      *'-M / -o SOURCE'*) printf '/dev/sdc2\n' ;;
      *'-M / -o FSTYPE'*) printf 'ext4\n' ;;
      *'-T /boot -o SOURCE'*) printf '/dev/sdc3\n' ;;
      *'-T /boot -o FSTYPE'*) printf 'ext4\n' ;;
      *) return 1 ;;
    esac
  }
  ! leap16_r64_require_tested_boot_filesystem || fail_test 'separate /boot unexpectedly passed the first-hardware rEFInd topology gate'
)

# The strict transcript child allowlist must still reject arbitrary commands.
(
  set -u
  source_effective_stack
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  set +e
  leap16_r46_transcript_child "$td" grub refind restore definitely_not_an_allowed_executor >/dev/null 2>&1
  rc=$?
  set -e
  [[ $rc == 2 ]] || fail_test 'strict transcript dispatcher did not reject an arbitrary r64 child command'
)

# Dynamically prove each of the six rEFInd restore directions selects the exact
# intended executor rather than relying only on source-text case patterns.
(
  set -u
  source_effective_stack
  EXPECT_SOURCE=''; EXPECT_TARGET=''; CALLED=''
  discover_backups_quiet(){ DISCOVERED_BACKUPS=(/tmp/fake-backup); }
  list_backups(){ :; }
  validate_backup_compatibility(){ return 0; }
  load_backup_metadata(){ bootloader=$EXPECT_TARGET; return 0; }
  detect_bootloader(){ BOOTLOADER=$EXPECT_SOURCE; }
  bootloader_display_name(){ printf '%s' "$1"; }
  leap16_r44_with_transaction_transcript(){ CALLED=$4; }
  leap16_r31_restore_grub_backup(){ CALLED=leap16_r31_restore_grub_backup; }
  leap16_r31_restore_limine_backup(){ CALLED=leap16_r31_restore_limine_backup; }

  check_dispatch(){
    local s=$1 t=$2 expect=$3
    EXPECT_SOURCE=$s; EXPECT_TARGET=$t; CALLED=''
    restore_backup_interactive <<<"1" >/dev/null || fail_test "restore dispatcher failed for $s->$t"
    [[ $CALLED == "$expect" ]] || fail_test "restore dispatcher $s->$t called ${CALLED:-nothing}, expected $expect"
  }
  check_dispatch grub refind leap16_r64_restore_refind_backup
  check_dispatch limine refind leap16_r64_restore_refind_backup
  check_dispatch systemd-boot refind leap16_r64_restore_refind_backup
  check_dispatch refind grub leap16_r64_restore_grub_backup_from_refind
  check_dispatch refind limine leap16_r64_restore_limine_backup_from_refind
  check_dispatch refind systemd-boot leap16_r64_restore_systemd_backup_from_refind
)

# Firmware-created duplicate rEFInd aliases are tolerated only when the
# recorded source alias remains present and all aliases are exact same-path,
# same-ESP identities.  The passive verifier must not fail merely because a
# bounded duplicate exists.
(
  set -u
  source_effective_stack
  PENDING_OLD_BOOT_ID=0001
  PENDING_SOURCE_EFI_RESOLVED=/tmp/refind_x64.efi
  PENDING_SOURCE_EFI_HASH=abc
  PENDING_SOURCE_MANIFEST=/tmp/manifest
  boot_id_exists(){ [[ ${1^^} == 0001 || ${1^^} == 0004 ]]; }
  nvram_id_matches_path(){ return 0; }
  leap16_nvram_entry_matches_current_esp(){ return 0; }
  r21_hash_privileged(){ printf 'abc\n'; }
  r26_verify_owned_manifest(){ return 0; }
  leap16_r64_current_refind_source_ids(){ printf '0001\n0004\n'; }
  validate_refind_boot_chain(){ return 0; }
  warn(){ :; }; ok(){ :; }; fail(){ printf 'FAIL-MSG: %s\n' "$*" >&2; }
  leap16_r64_verify_refind_source_passive || fail_test 'bounded duplicate rEFInd source alias was not tolerated'
  leap16_r64_current_refind_source_ids(){ printf '0004\n'; }
  ! leap16_r64_verify_refind_source_passive >/dev/null 2>&1 || fail_test 'passive rEFInd recovery accepted loss of the recorded canonical source identity'
)

# Target-specific GRUB/Limine final order builders must also consume the
# bounded duplicate-rEFInd alias set before source deletion.
(
  set -u
  source_effective_stack
  gf=$(declare -f leap16_r64_final_grub_order)
  lf=$(declare -f leap16_r64_final_limine_order)
  [[ $gf == *'leap16_r64_current_refind_source_ids'* ]] || fail_test 'final GRUB order does not remove bounded duplicate rEFInd source aliases'
  [[ $lf == *'leap16_r64_current_refind_source_ids'* ]] || fail_test 'final Limine order does not remove bounded duplicate rEFInd source aliases'
)

echo 'PASS: leap16-r64 complete rEFInd backend/restore/matrix regression'
