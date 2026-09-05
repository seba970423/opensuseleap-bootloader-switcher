#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"
layer="$ROOT/lib/leap16_r52.sh"
[[ -f $layer ]] || { echo 'FAIL: r52 layer missing'; exit 1; }
grep -Fq 'SWITCHER_RELEASE="leap16-r52"' "$main"
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r52.sh"' "$main"
grep -Fq 'leap16_r51_run_systemd_to_limine_inner)' "$layer"
grep -Fq 'LC_ALL=C sed -u -E' "$layer"

# Functional allowlist regression: the new r51 transaction child must be
# accepted, while an arbitrary command must still be rejected.
(
  source "$layer"
  detect_bootloader() { BOOTLOADER=systemd-boot; }
  leap16_r51_run_systemd_to_limine_inner() { printf 'r51-child-ok:%s\n' "$1"; }
  d=$(mktemp -d)
  trap 'rm -rf "$d"' EXIT
  out=$(leap16_r46_transcript_child "$d" systemd-boot limine switch leap16_r51_run_systemd_to_limine_inner limine)
  [[ $out == 'r51-child-ok:limine' ]]
  if leap16_r46_transcript_child "$d" systemd-boot limine switch definitely_not_allowed >/dev/null 2>&1; then
    echo 'FAIL: arbitrary transcript child was accepted'
    exit 1
  fi
)

# Functional sanitizer regression: CR/ANSI are normalized and script(1)
# metadata is removed.  Running the regex under C collation avoids the locale
# dependent "Invalid range end" seen on hardware.
(
  source "$layer"
  d=$(mktemp -d)
  trap 'rm -rf "$d"' EXIT
  raw="$d/raw"; out="$d/out"
  printf 'Script started on 2026-09-02 [COMMAND=x]\nalpha\r\033[31mred\033[0m\nScript done on 2026-09-02 [COMMAND_EXIT_CODE=0]\n' >"$raw"
  leap16_r46_sanitize_typescript "$raw" "$out"
  grep -Fqx 'alpha' "$out"
  grep -Fqx 'red' "$out"
  ! grep -Fq $'\033' "$out"
  ! grep -Fq 'Script started on ' "$out"
  ! grep -Fq 'Script done on ' "$out"
)

echo 'PASS: leap16-r52 PTY child dispatch + locale-safe sanitizer regression'
