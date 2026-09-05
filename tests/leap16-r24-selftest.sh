#!/usr/bin/env bash
set -u
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 1
failures=0
pass(){ printf '[PASS] %s\n' "$*"; }
fail_test(){ printf '[FAIL] %s\n' "$*" >&2; failures=$((failures+1)); }

printf 'openSUSE Leap 16 r24 focused self-test\n======================================\n\n'

if find . -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n; then pass 'all shell files parse'; else fail_test 'shell parse failure'; fi
if grep -Eq 'SWITCHER_RELEASE="leap16-r(2[5-9]|[3-9][0-9])"' bootloader-switcher.sh \
 && awk '/opensuse_leap16.sh/{a=NR} /leap16_r21.sh/{b=NR} /leap16_r22.sh/{c=NR} /leap16_r23.sh/{d=NR} /leap16_r24.sh/{e=NR} END{exit !(a&&b&&c&&d&&e&&a<b&&b<c&&c<d&&d<e)}' bootloader-switcher.sh; then
    pass 'r24 loads after r23 and owns the final release marker'
else fail_test 'r24 load order/release marker is wrong'; fi

if awk '/^r21_retire_grub_after_fallback_proof\(\)/{infn=1} infn && /r23_remove_source_grub_files_efi_first/{files=NR} infn && /r24_replace_direct_grub_recovery_with_efi_fallback/{menu=NR} infn && /r23_sweep_native_grub_nvram_aliases/{sweep=NR} infn && /^}/{if(infn){exit}} END{exit !(files&&menu&&sweep&&files<menu&&menu<sweep)}' lib/leap16_r24.sh; then
    pass 'r24 finalizer retires GRUB files, installs visible EFI fallback menu, then sweeps aliases'
else fail_test 'r24 finalizer ordering is wrong'; fi

if grep -Fq "printf '/EFI fallback\\n'" lib/leap16_r24.sh \
 && grep -Fq "printf 'path: boot():/EFI/BOOT/BOOTX64.EFI\\n'" lib/leap16_r24.sh \
 && grep -Fq 'Finalized Limine exposes the byte-identical standard EFI fallback in its menu' lib/leap16_r24.sh; then
    pass 'final visible EFI fallback menu contract is explicit'
else fail_test 'final EFI fallback menu contract is missing'; fi

if grep -Fq 'r24_add_fallback_menu_to_finalized_limine' lib/leap16_r24.sh \
 && grep -Fq 'Type APPLY to add the menu entry' lib/leap16_r24.sh \
 && grep -Fq 'NVRAM/EFI payloads are not changed.' lib/leap16_r24.sh; then
    pass 'finalized r23 installations have a narrow in-place menu-only upgrade'
else fail_test 'in-place r23 -> r24 menu upgrade is missing'; fi

# Behavioral fixture: exact temporary GRUB block must become exact EFI fallback
# block while preserving unrelated config text.
source lib/common.sh
source lib/storage.sh
source lib/detect.sh
source lib/kernels.sh
source lib/validate.sh
source lib/limine_validate.sh
source lib/grub_validate.sh
source lib/operations.sh
source lib/staged.sh
source lib/r21.sh
source lib/r22.sh
source lib/r23.sh
source lib/opensuse_leap16.sh
source lib/leap16_r21.sh
source lib/leap16_r22.sh
source lib/leap16_r23.sh
source lib/leap16_r24.sh

td=$(mktemp -d)
conf="$td/limine.conf"
cat >"$conf" <<'CFG'
timeout: 3
/openSUSE GRUB2 recovery
### Temporary direct recovery path retained until Limine fallback proof completes
comment: Native openSUSE shim/GRUB2 recovery path
protocol: efi
path: boot():/EFI/OPENSUSE/SHIM.EFI
CFG
PENDING_LIMINE_CONF_PATH=$conf
PENDING_TRANSACTION_SNAPSHOT_DIR=$td
LEAP16_R21_FINALCONF_BASENAME=final.conf
old_hash=$(sha256sum "$conf" | awk '{print $1}')
r21_meta_value(){ [[ $1 == transferred_limine_conf_hash ]] && printf '%s\n' "$old_hash"; }
r21_hash_privileged(){ sha256sum "$1" | awk '{print $1}'; }
r21_atomic_replace(){ cp -- "$1" "$2"; [[ $(sha256sum "$2" | awk '{print $1}') == "$3" ]]; }
fail(){ printf '%s\n' "$*" >&2; }
new_hash=$(r24_replace_direct_grub_recovery_with_efi_fallback)
if [[ -n $new_hash ]] \
 && grep -Fqx '/EFI fallback' "$conf" \
 && grep -Fqx 'path: boot():/EFI/BOOT/BOOTX64.EFI' "$conf" \
 && ! grep -Fq '/openSUSE GRUB2 recovery' "$conf"; then
    pass 'temporary GRUB recovery block converts to visible standard EFI fallback block'
else fail_test 'fallback menu conversion behavioral fixture failed'; fi
rm -rf -- "$td"

printf '\n'
if ((failures==0)); then printf 'All focused openSUSE Leap 16 r24 self-tests passed.\n'; exit 0; fi
printf '%d focused r24 self-test(s) failed.\n' "$failures" >&2
exit 1
