#!/usr/bin/env bash
set -u
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 1
failures=0
pass(){ printf '[PASS] %s\n' "$*"; }
fail_test(){ printf '[FAIL] %s\n' "$*" >&2; failures=$((failures+1)); }

printf 'openSUSE Leap 16 r23 focused self-test\n======================================\n\n'

if find . -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n; then pass 'all shell files parse'; else fail_test 'shell parse failure'; fi
if grep -Eq 'SWITCHER_RELEASE="leap16-r(2[5-9]|[3-9][0-9])"' bootloader-switcher.sh \
 && awk '/opensuse_leap16.sh/{a=NR} /leap16_r21.sh/{b=NR} /leap16_r22.sh/{c=NR} /leap16_r23.sh/{d=NR} /leap16_r24.sh/{e=NR} END{exit !(a&&b&&c&&d&&e&&a<b&&b<c&&c<d&&d<e)}' bootloader-switcher.sh; then
    pass 'r23 remains loaded after r22 and before the r24 menu layer'
else fail_test 'r23/r24 load order/release marker is wrong'; fi

if awk '/^r21_retire_grub_after_fallback_proof\(\)/{infn=1} infn && /r21_remove_direct_grub_recovery_block/{conf=NR} infn && /r23_remove_source_grub_files_efi_first/{files=NR} infn && /r23_sweep_native_grub_nvram_aliases/{sweep=NR} infn && /^}/{if(infn){exit}} END{exit !(conf && files && sweep && conf<files && files<sweep)}' lib/leap16_r23.sh; then
    pass 'finalizer removes temporary recovery/config and owned EFI files before dynamic NVRAM sweep'
else fail_test 'r23 GRUB retirement ordering is wrong'; fi

if awk '/^r23_remove_source_grub_files_efi_first\(\)/{infn=1} infn && /sudo rm -rf -- "\$efi_dir"/{efi=NR} infn && /sudo rm -rf -- \/boot\/grub2/{grub=NR} infn && /^}/{if(infn){exit}} END{exit !(efi && grub && efi<grub)}' lib/leap16_r23.sh; then
    pass 'firmware-discoverable EFI/OPENSUSE is retired before /boot/grub2'
else fail_test 'EFI namespace is not retired first'; fi

if grep -Fq 'r21_current_native_grub_ids' lib/leap16_r23.sh \
 && grep -Fq 'for pass in 1 2 3' lib/leap16_r23.sh \
 && grep -Fq 'Native openSUSE GRUB2 aliases remain after repeated final sweep' lib/leap16_r23.sh; then
    pass 'final NVRAM cleanup is fresh path/ESP discovery with repeated sweep'
else fail_test 'dynamic alias sweep is missing'; fi

if grep -Fq 'Re-arm exact fallback proof and continue with corrected r23 retirement' lib/leap16_r23.sh \
 && grep -Fq 'r22_prepare_resume_bundle' lib/leap16_r23.sh \
 && grep -Fq 'sudo efibootmgr -n "$fallback_id"' lib/leap16_r23.sh; then
    pass 'stranded primary-Limine state can re-arm the exact fallback proof without rollback'
else fail_test 'stranded fallback recovery path is incomplete'; fi

# Behavioral regression: a disappearing alias must be success, not the r21
# false return inherited from the last failed boot_id_exists probe.
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
source lib/r42.sh
source lib/opensuse_leap16.sh
source lib/leap16_r21.sh
source lib/leap16_r22.sh
source lib/leap16_r23.sh

PENDING_ESP_SOURCE=/dev/fake1
PENDING_ESP_MOUNT=/boot/efi
marker=$(mktemp)
rm -f -- "$marker"
r21_current_native_grub_ids(){
    [[ -e $marker ]] || printf '0004\n'
}
leap16_nvram_entry_matches_current_esp(){ return 0; }
sudo(){
    if [[ ${1:-} == efibootmgr ]]; then touch "$marker"; return 0; fi
    command sudo "$@"
}
ok(){ :; }
fail(){ printf '%s\n' "$*" >&2; }
if r23_sweep_native_grub_nvram_aliases; then pass 'alias sweep returns success after the last alias disappears'; else fail_test 'alias sweep inherited false failure after successful deletion'; fi

printf '\n'
if ((failures==0)); then printf 'All focused openSUSE Leap 16 r23 self-tests passed.\n'; exit 0; fi
printf '%d focused r23 self-test(s) failed.\n' "$failures" >&2
exit 1
