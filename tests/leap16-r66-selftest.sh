#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"
layer="$ROOT/lib/leap16_r66.sh"
fail_test(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f $layer ]] || fail_test 'r66 layer missing'
grep -Fq 'SWITCHER_RELEASE="leap16-r66"' "$main" || fail_test 'release is not r66'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r66.sh"' "$main" || fail_test 'r66 layer is not sourced'
grep -Fq 'downloads.sourceforge.net/project/refind/' "$layer" || fail_test 'fixed upstream SourceForge archive URL missing'
! grep -Fq '/latest/' "$layer" || fail_test 'r66 must not use an unversioned latest archive URL'

source_effective_stack(){
  local prelude
  prelude=$(awk '/^select_target_bootloader\(\)/{exit} {print}' "$main" | sed '/^SCRIPT_DIR=/d')
  SCRIPT_DIR=$ROOT
  eval "$prelude"
}

# Build a minimal synthetic upstream-shaped ZIP.  PE type validation is
# intentionally bypassed in this unit because these are tiny MZ fixtures.
td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
prefix="$td/tree/refind-bin-0.14.2/refind"
mkdir -p "$prefix/drivers_x64" "$prefix/icons/sub"
printf 'MZfake-refind\n' >"$prefix/refind_x64.efi"
printf 'MZfake-ext4\n' >"$prefix/drivers_x64/ext4_x64.efi"
printf '# sample\ntimeout 20\n' >"$prefix/refind.conf-sample"
printf 'icon\n' >"$prefix/icons/os_linux.png"
printf 'icon2\n' >"$prefix/icons/sub/nested.png"
( cd "$td/tree" && zip -qr "$td/refind-bin-0.14.2.zip" refind-bin-0.14.2 )

(
  set -u
  source_effective_stack
  fail(){ printf 'FAIL-MSG: %s\n' "$*" >&2; return 1; }
  ok(){ :; }
  info(){ :; }
  have(){ [[ $1 != file ]] && command -v "$1" >/dev/null 2>&1; }
  BOOTLOADER_SWITCHER_REFIND_ARCHIVE="$td/refind-bin-0.14.2.zip"
  BOOTLOADER_SWITCHER_REFIND_ARCHIVE_SHA256=$(sha256sum "$td/refind-bin-0.14.2.zip" | awk '{print $1}')
  leap16_r66_acquire_refind_bundle || fail_test 'safe local archive acquisition failed'
  [[ -f $LEAP16_R66_REFIND_BUNDLE_ROOT/refind_x64.efi ]] || fail_test 'refind binary not extracted'
  [[ -f $LEAP16_R66_REFIND_BUNDLE_ROOT/drivers_x64/ext4_x64.efi ]] || fail_test 'ext4 driver not extracted'
  [[ -f $LEAP16_R66_REFIND_BUNDLE_ROOT/icons/sub/nested.png ]] || fail_test 'icon tree not extracted'
  [[ $LEAP16_R66_REFIND_ARCHIVE_SHA256 == "$BOOTLOADER_SWITCHER_REFIND_ARCHIVE_SHA256" ]] || fail_test 'archive hash evidence not retained'
  leap16_r66_cleanup_refind_bundle
)

# Incorrect user pin must fail before any ESP/NVRAM action.
(
  set -u
  source_effective_stack
  fail(){ return 1; }
  ok(){ :; }
  info(){ :; }
  have(){ [[ $1 != file ]] && command -v "$1" >/dev/null 2>&1; }
  BOOTLOADER_SWITCHER_REFIND_ARCHIVE="$td/refind-bin-0.14.2.zip"
  BOOTLOADER_SWITCHER_REFIND_ARCHIVE_SHA256=$(printf '0%.0s' {1..64})
  ! leap16_r66_acquire_refind_bundle || fail_test 'wrong archive SHA-256 did not fail closed'
)

# Archive traversal must be rejected even when all required payload names are
# also present.
python3 - "$td/bad.zip" <<'PY'
import sys, zipfile
p=sys.argv[1]
with zipfile.ZipFile(p,'w') as z:
    base='refind-bin-0.14.2/refind/'
    z.writestr(base+'refind_x64.efi',b'MZx')
    z.writestr(base+'drivers_x64/ext4_x64.efi',b'MZd')
    z.writestr(base+'refind.conf-sample',b'# c')
    z.writestr(base+'icons/a.png',b'i')
    z.writestr('../evil',b'no')
PY
(
  set -u
  source_effective_stack
  fail(){ return 1; }
  ok(){ :; }
  info(){ :; }
  have(){ [[ $1 != file ]] && command -v "$1" >/dev/null 2>&1; }
  BOOTLOADER_SWITCHER_REFIND_ARCHIVE="$td/bad.zip"
  BOOTLOADER_SWITCHER_REFIND_ARCHIVE_SHA256=''
  ! leap16_r66_acquire_refind_bundle || fail_test 'path-traversal ZIP did not fail closed'
)

# Effective Leap stage must be transaction-owned manual staging.  No package
# manager, RPM script, or refind-install call is allowed to escape the boundary.
(
  set -u
  source_effective_stack
  body=$(declare -f r26_stage_refind_target)
  [[ $body == *'leap16_r66_acquire_refind_bundle'* ]] || fail_test 'effective stage does not acquire controlled archive'
  [[ $body == *'leap16_r66_install_refind_tree'* ]] || fail_test 'effective stage does not manually install payload'
  [[ $body == *'r28_create_alias_create_only'* ]] || fail_test 'effective stage does not use create-only NVRAM creation'
  [[ $body == *'set_source_first_boot_order'* ]] || fail_test 'effective stage does not explicitly preserve source-first order'
  [[ $body != *'refind-install'* ]] || fail_test 'effective stage still invokes refind-install'
  [[ $body != *'zypper'* ]] || fail_test 'effective stage still invokes zypper for rEFInd'
  [[ $body != *'rpm '* ]] || fail_test 'effective stage still depends on an rEFInd RPM'
  pkg=$(declare -f leap16_r64_install_refind_package)
  [[ $pkg == *'r66 forbids RPM/package-script rEFInd staging'* ]] || fail_test 'package-path kill switch is missing'
  preflight=$(declare -f leap16_r64_preflight)
  [[ $preflight != *'have unzip'* && $preflight != *'have curl'* && $preflight != *'have wget'* ]] || fail_test 'read-only rEFInd preflight still imposes live archive/network requirements on self-contained restore'
  backupv=$(declare -f leap16_r64_refind_backup_payload_valid)
  [[ $backupv == *'.opensuse-bootloader-switcher-source'* && $backupv == *'pkg_ok || marker_ok'* ]] || fail_test 'r66 backup validator does not accept controlled-binary identity without a fake RPM dependency'
)

# Mock the entire effective stage choreography and prove the old package path
# cannot be called accidentally.
(
  set -u
  source_effective_stack
  log="$td/stage-seq"; : >"$log"
  is_leap16(){ return 0; }
  fail(){ printf 'FAIL-MSG: %s\n' "$*" >&2; return 1; }
  ok(){ :; }
  leap16_r66_acquire_refind_bundle(){ echo acquire >>"$log"; LEAP16_R66_REFIND_WORKDIR=''; LEAP16_R66_REFIND_BUNDLE_ROOT=/synthetic; return 0; }
  leap16_r66_install_refind_tree(){ echo install-tree >>"$log"; }
  r32_verify_refind_post_install_esp(){ echo topology >>"$log"; }
  leap16_r66_patch_refind_config(){ echo config >>"$log"; }
  r26_write_refind_linux_conf(){ echo linuxconf >>"$log"; }
  r28_create_alias_create_only(){ echo create-only >>"$log"; R28_CREATED_ALIAS_ID=00AA; }
  set_source_first_boot_order(){ echo source-first >>"$log"; }
  pending_bootnext_id(){ :; }
  r26_restore_source_fallback_after_target_stage(){ echo fallback >>"$log"; }
  adapter_target_validate(){ [[ $1 == refind ]] || return 1; echo validate >>"$log"; }
  r26_record_target_adapter(){ [[ $1 == refind ]] || return 1; echo manifest >>"$log"; }
  leap16_r64_write_meta(){ echo meta >>"$log"; }
  leap16_r66_cleanup_refind_bundle(){ echo cleanup >>"$log"; }
  leap16_r64_install_refind_package(){ fail_test 'package installer was called by effective r66 stage'; }
  refind-install(){ fail_test 'refind-install was called by effective r66 stage'; }
  ESP_SOURCE=/dev/sdc1 ESP_MOUNT=/boot/efi ESP_FSTYPE=vfat ESP_UUID=18D1-2715 BOOTLOADER=grub
  LEAP16_R64_RESTORE_DIR=''
  R26_STAGED_TARGET_ID=''
  r26_stage_refind_target 0002 '0002,0000' 'root=UUID=x quiet' || fail_test 'mock effective stage failed'
  expected=$'acquire\ninstall-tree\ntopology\nconfig\nlinuxconf\ncreate-only\nsource-first\nfallback\nvalidate\nmanifest\nmeta\ncleanup'
  [[ $(cat "$log") == "$expected" ]] || { printf 'got:\n%s\n' "$(cat "$log")" >&2; fail_test 'manual stage choreography order changed'; }
  [[ $R26_STAGED_TARGET_ID == 00AA ]] || fail_test 'effective stage did not publish canonical target ID'
)

# A self-contained rEFInd restore must not download or install a baseline
# archive that it immediately overwrites.  It restores validated immutable
# backup bytes directly, then enters the same create-only/source-first proof.
(
  set -u
  source_effective_stack
  log="$td/restore-seq"; : >"$log"
  is_leap16(){ return 0; }
  fail(){ printf 'FAIL-MSG: %s\n' "$*" >&2; return 1; }
  ok(){ :; }
  leap16_r66_acquire_refind_bundle(){ fail_test 'self-contained restore tried to acquire an upstream archive'; }
  leap16_r66_install_refind_tree(){ fail_test 'self-contained restore tried to install an upstream baseline tree'; }
  leap16_r66_patch_refind_config(){ fail_test 'self-contained restore tried to rewrite backed-up refind.conf'; }
  r26_write_refind_linux_conf(){ fail_test 'self-contained restore tried to regenerate backed-up refind_linux.conf'; }
  leap16_r64_restore_refind_payload_at_write_boundary(){ [[ $1 == /backup ]] || return 1; echo restore >>"$log"; }
  r32_verify_refind_post_install_esp(){ echo topology >>"$log"; }
  r28_create_alias_create_only(){ echo create-only >>"$log"; R28_CREATED_ALIAS_ID=00BB; }
  set_source_first_boot_order(){ echo source-first >>"$log"; }
  pending_bootnext_id(){ :; }
  r26_restore_source_fallback_after_target_stage(){ echo fallback >>"$log"; }
  adapter_target_validate(){ [[ $1 == refind ]] || return 1; echo validate >>"$log"; }
  r26_record_target_adapter(){ [[ $1 == refind ]] || return 1; echo manifest >>"$log"; }
  leap16_r64_write_meta(){ echo meta >>"$log"; }
  leap16_r66_cleanup_refind_bundle(){ echo cleanup >>"$log"; }
  ESP_SOURCE=/dev/sdc1 ESP_MOUNT=/boot/efi ESP_FSTYPE=vfat ESP_UUID=18D1-2715 BOOTLOADER=grub
  LEAP16_R64_RESTORE_DIR=/backup
  R26_STAGED_TARGET_ID=''
  r26_stage_refind_target 0002 '0002,0000' 'root=UUID=x quiet' || fail_test 'mock self-contained restore stage failed'
  expected=$'restore\ntopology\ncreate-only\nsource-first\nfallback\nvalidate\nmanifest\nmeta\ncleanup'
  [[ $(cat "$log") == "$expected" ]] || { printf 'got restore sequence:\n%s\n' "$(cat "$log")" >&2; fail_test 'self-contained restore choreography changed'; }
  [[ $R26_STAGED_TARGET_ID == 00BB ]] || fail_test 'restore stage did not publish canonical target ID'
)

# Matrix must preserve both safe-fail hardware attempts and all six rEFInd edges.
(
  set -u
  source_effective_stack
  for pair in 'grub refind' 'limine refind' 'systemd-boot refind' 'refind grub' 'refind limine' 'refind systemd-boot'; do
    read -r s t <<<"$pair"
    leap16_r64_refind_edge "$s" "$t" || fail_test "rEFInd edge regressed: $s->$t"
  done
  matrix=$(leap16_r64_print_matrix)
  [[ $matrix == *'leap16-r66'* ]] || fail_test 'matrix output still reports an older release'
  [[ $matrix == *'r64: SAFE-FAIL'* && $matrix == *'r65: SAFE-FAIL'* ]] || fail_test 'matrix lost hardware safe-fail provenance'
  [[ $matrix == *'no rEFInd RPM/package post-install scripts'* ]] || fail_test 'matrix does not state the controlled acquisition contract'
)

printf 'PASS: leap16-r66 controlled upstream rEFInd archive staging regression\n'
