#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"
layer="$ROOT/lib/leap16_r65.sh"
fail_test(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f $layer ]] || fail_test 'r65 layer missing'
grep -Fq 'SWITCHER_RELEASE="leap16-r65"' "$main" || fail_test 'release is not r65'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r65.sh"' "$main" || fail_test 'r65 layer is not sourced'
grep -Fq 'zypper --non-interactive install --no-recommends "$@"' "$layer" || fail_test 'correct zypper global/command option ordering missing'

source_effective_stack(){
  local prelude
  prelude=$(awk '/^select_target_bootloader\(\)/{exit} {print}' "$main" | sed '/^SCRIPT_DIR=/d')
  SCRIPT_DIR=$ROOT
  eval "$prelude"
}

# Exact parser regression for the hardware-observed r64 failure.
(
  set -u
  source_effective_stack
  have(){ [[ $1 == zypper ]] || command -v "$1" >/dev/null 2>&1; }
  fail(){ printf 'FAIL-MSG: %s\n' "$*" >&2; return 1; }
  sudo(){ "$@"; }
  zypper(){
    if [[ ${1:-} == install && ${2:-} == --help ]]; then
      printf '  --no-recommends  Do not install recommended packages\n'
      return 0
    fi
    # Model Leap's option scoping: global --non-interactive before command,
    # command-specific --no-recommends after install.
    [[ ${1:-} == --non-interactive ]] || return 91
    [[ ${2:-} == install ]] || return 92
    [[ ${3:-} == --no-recommends ]] || return 93
    shift 3
    [[ $# -ge 1 ]] || return 94
    printf '%s\n' "$*" >"$td/args"
  }
  td=$(mktemp -d); trap 'rm -rf "$td"' EXIT
  leap16_r65_zypper_install_no_recommends refind || fail_test 'correctly scoped zypper call was rejected'
  [[ $(cat "$td/args") == refind ]] || fail_test 'package argument did not survive helper'
)

# Capability probe must fail closed instead of silently allowing recommends.
(
  set -u
  source_effective_stack
  have(){ [[ $1 == zypper ]] || command -v "$1" >/dev/null 2>&1; }
  fail(){ return 1; }
  sudo(){ fail_test 'sudo must not run when --no-recommends capability is absent'; }
  zypper(){ [[ ${1:-} == install && ${2:-} == --help ]] && printf 'install help without solver flag\n'; }
  ! leap16_r65_zypper_install_no_recommends refind || fail_test 'missing --no-recommends capability did not fail closed'
)

# Effective package installers for all three native package families must use
# the corrected helper, closing the same latent branch in older adapters.
(
  set -u
  source_effective_stack
  [[ $(declare -f leap16_r32_install_systemd_boot_package) == *'leap16_r65_zypper_install_no_recommends systemd-boot'* ]] || fail_test 'systemd-boot fresh-package path still uses old ordering'
  [[ $(declare -f leap16_r38_install_grub_packages_if_needed) == *'leap16_r65_zypper_install_no_recommends grub2-common grub2-x86_64-efi shim'* ]] || fail_test 'GRUB fresh-package path still uses old ordering'
  [[ $(declare -f leap16_r64_install_refind_package) == *'leap16_r65_zypper_install_no_recommends refind'* ]] || fail_test 'rEFInd repository install path still uses old ordering'
  [[ $(declare -f leap16_r64_install_refind_package) == *'leap16_r65_zypper_install_no_recommends "$rpm_path"'* ]] || fail_test 'rEFInd local-RPM install path still uses old ordering'
)

# r64 matrix and six rEFInd edges must remain enabled; this hotfix is package
# acquisition only.
(
  set -u
  source_effective_stack
  for pair in 'grub refind' 'limine refind' 'systemd-boot refind' 'refind grub' 'refind limine' 'refind systemd-boot'; do
    read -r s t <<<"$pair"
    leap16_r64_refind_edge "$s" "$t" || fail_test "rEFInd edge regressed: $s->$t"
  done
  matrix=$(leap16_r64_print_matrix)
  [[ $matrix == *'leap16-r65'* ]] || fail_test 'matrix output still reports r64'
  [[ $matrix == *'SAFE-FAIL before candidate commit'* ]] || fail_test 'matrix does not track the first rEFInd hardware attempt'
)

printf 'PASS: leap16-r65 zypper option-scope regression\n'
