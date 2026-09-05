#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
main="$ROOT/bootloader-switcher.sh"; layer="$ROOT/lib/leap16_r67.sh"
fail_test(){ printf 'FAIL: %s\n' "$1" >&2; exit 1; }
[[ -f $layer ]] || fail_test 'r67 layer missing'
grep -Fq 'SWITCHER_RELEASE="leap16-r67"' "$main" || fail_test 'release is not r67'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r67.sh"' "$main" || fail_test 'r67 layer is not sourced'

body=$(sed -n '/^validate_refind_boot_chain()/,/^}/p' "$layer")
[[ $body == *'leap16_r67_initrd_matches_kernel_release'* ]] || fail_test 'effective r67 validator does not use Leap dracut helper'
[[ $body != *'grub_initramfs_matches_kernel_version'* ]] || fail_test 'r67 validator still invokes mkinitcpio structural helper'
[[ $body == *'follow_symlinks=true'* ]] || fail_test 'r67 validator does not enforce follow_symlinks'
config=$(sed -n '/^leap16_r66_patch_refind_config()/,/^}/p' "$layer")
[[ $config == *"printf 'follow_symlinks true"* ]] || fail_test 'r67 config writer does not enable follow_symlinks'

# Dynamic helper test: parseable dracut listing with exact release passes.
(
  source "$ROOT/lib/common.sh"
  source "$layer"
  tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
  printf x >"$tmp"
  lsinitrd(){
    if [[ ${1:-} == -k ]]; then return 0; fi
    cat <<OUT
Image: $1
-rw-r--r-- 1 root root 123 Jan 1 00:00 usr/lib/modules/6.12.0-test/kernel/drivers/foo.ko
OUT
  }
  leap16_r67_initrd_matches_kernel_release "$tmp" 6.12.0-test || fail_test "exact dracut release rejected: $LEAP16_R67_INITRD_REASON"
  ! leap16_r67_initrd_matches_kernel_release "$tmp" 6.12.1-wrong || fail_test 'wrong dracut release accepted'
)

# Module-less parseable host-only image uses dracut's own exact -k resolver.
(
  source "$ROOT/lib/common.sh"
  source "$layer"
  tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
  printf x >"$tmp"
  lsinitrd(){
    if [[ ${1:-} == -k ]]; then [[ ${2:-} == 6.12.0-test ]]; return; fi
    printf 'Image: %s\nVersion: dracut-test\n' "$1"
  }
  leap16_r67_initrd_matches_kernel_release "$tmp" 6.12.0-test || fail_test 'module-less dracut image with valid -k resolver rejected'
  ! leap16_r67_initrd_matches_kernel_release "$tmp" 6.12.1-wrong || fail_test 'module-less image with wrong -k resolver accepted'
)

source "$layer"
matrix=$(leap16_r64_print_matrix)
[[ $matrix == *'leap16-r67'* ]] || fail_test 'matrix output is not r67'
[[ $matrix == *'r66: SAFE-FAIL'* ]] || fail_test 'r66 hardware safe-fail is not tracked'

printf 'PASS: leap16-r67 Leap-native dracut + openSUSE symlink rEFInd validation regression\n'
