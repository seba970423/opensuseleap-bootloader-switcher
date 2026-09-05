#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"
layer="$ROOT/lib/leap16_r62.sh"
fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ -f $layer ]] || fail 'r62 layer missing'
grep -Fq 'SWITCHER_RELEASE="leap16-r62"' "$main" || fail 'release is not r62'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r62.sh"' "$main" || fail 'r62 layer is not sourced'
grep -Fq 'leap16_r61_restore_systemd_backup_from_limine' "$layer" || fail 'Limine -> systemd restore child is not allowlisted'
grep -Fq 'leap16_r61_restore_limine_backup_from_systemd' "$layer" || fail 'systemd -> Limine restore child is not allowlisted'

# Functional child-dispatch regression. Both r61 restore executors must pass the
# strict PTY child gate while arbitrary commands remain rejected.
(
  source "$layer"
  detect_bootloader(){ BOOTLOADER=$expected; }
  leap16_r61_restore_systemd_backup_from_limine(){ printf 'systemd-restore:%s\n' "$1"; }
  leap16_r61_restore_limine_backup_from_systemd(){ printf 'limine-restore:%s\n' "$1"; }
  d=$(mktemp -d)
  trap 'rm -rf "$d"' EXIT

  expected=limine
  out=$(leap16_r46_transcript_child "$d" limine systemd-boot restore leap16_r61_restore_systemd_backup_from_limine /backup/systemd)
  [[ $out == 'systemd-restore:/backup/systemd' ]] || fail 'Limine -> systemd restore child dispatch failed'

  expected=systemd-boot
  out=$(leap16_r46_transcript_child "$d" systemd-boot limine restore leap16_r61_restore_limine_backup_from_systemd /backup/limine)
  [[ $out == 'limine-restore:/backup/limine' ]] || fail 'systemd -> Limine restore child dispatch failed'

  if leap16_r46_transcript_child "$d" systemd-boot limine restore definitely_not_allowed >/dev/null 2>&1; then
    fail 'arbitrary transcript child was accepted'
  fi
)

# r62 must not replace the locale-safe sanitizer supplied by r52.
(
  leap16_r46_sanitize_typescript(){ printf 'r52-sanitizer\n'; }
  source "$layer"
  [[ $(leap16_r46_sanitize_typescript) == r52-sanitizer ]] || fail 'r62 unexpectedly replaced the r52 sanitizer'
)

echo 'PASS: leap16-r62 r61 restore PTY child allowlist regression'
