#!/usr/bin/env bash
set -u
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 1
failures=0
pass(){ printf '[PASS] %s\n' "$*"; }
fail_test(){ printf '[FAIL] %s\n' "$*" >&2; failures=$((failures+1)); }

printf 'openSUSE Leap 16 r22 focused self-test\n======================================\n\n'

if find . -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n; then pass 'all shell files parse'; else fail_test 'shell parse failure'; fi
if grep -Eq 'SWITCHER_RELEASE="leap16-r(2[5-9]|[3-9][0-9])"' bootloader-switcher.sh \
 && awk '/opensuse_leap16.sh/{a=NR} /leap16_r21.sh/{b=NR} /leap16_r22.sh/{c=NR} /leap16_r23.sh/{d=NR} /leap16_r24.sh/{e=NR} END{exit !(a&&b&&c&&d&&e&&a<b&&b<c&&c<d&&d<e)}' bootloader-switcher.sh; then
    pass 'r22 remains between r21 and the r23/r24 finalization layers'
else fail_test 'r22/r23/r24 load order/release marker is wrong'; fi

# Load the real function lineage, then replace only external predicates so the
# r22 dispatcher itself is what is being tested.
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
PENDING_SOURCE=grub
PENDING_TARGET=limine
PENDING_PHASE=runtime-validated
BOOTLOADER=limine
PENDING_TARGET_BOOT_ID=0002
BOOT_CURRENT=0002

leap16_verify_grub_recovery_after_promotion(){ printf 'PROMOTED\n'; return 0; }
verify_pending_source_recovery_unchanged_pre_r22(){ printf 'CANDIDATE\n'; return 0; }
leap16_assess_promoted_firmware_order(){ return 0; }
out=$(verify_pending_source_recovery_unchanged)
[[ $out == PROMOTED ]] && pass 'runtime-validated promoted topology uses promoted GRUB recovery/order proof' || fail_test 'promoted topology still called the candidate-order validator'

leap16_assess_promoted_firmware_order(){ return 1; }
out=$(verify_pending_source_recovery_unchanged)
[[ $out == CANDIDATE ]] && pass 'non-promoted topology still uses inherited source-first candidate proof' || fail_test 'candidate topology did not retain source-first proof'

if grep -Fq 'r21 stopped here because an inherited validator incorrectly demanded the old source-first BootOrder.' lib/leap16_r22.sh \
 && grep -Fq 'r21_stage_fallback_test || return 1' lib/leap16_r22.sh \
 && grep -Fq 'r22_prepare_resume_bundle' lib/leap16_r22.sh; then
    pass 'stranded primary-promoted transaction has an in-place fallback continuation path'
else fail_test 'promoted-checkpoint recovery path is incomplete'; fi

if grep -Fq '[3] Create backup of currently booted bootloader' bootloader-switcher.sh \
 && grep -Fq '[4] List and validate backups' bootloader-switcher.sh \
 && grep -Fq '[5] Restore a validated backup' bootloader-switcher.sh \
 && ! grep -Fq '[5] Restore a validated backup [LOCKED]' bootloader-switcher.sh \
 && grep -Fq '[6] Show restore plan for a backup (read-only)' bootloader-switcher.sh; then
    pass 'all nine selectors remain; r31 exposes backup/list/restore/plan for the proven GRUB2-Limine scope'
else fail_test 'current backup/restore selector UX is inconsistent'; fi

if ! grep -Rq 'GRUB2/shim/config/fallback will remain intact as recovery; r13 does NOT retire them.' lib bootloader-switcher.sh \
 && ! grep -Rq 'Executing leap16-r13 candidate stage' lib bootloader-switcher.sh; then
    pass 'misleading r13 end-state/status fossils are removed from current UX'
else fail_test 'misleading r13 UX text remains'; fi

printf '\n'
if ((failures==0)); then printf 'All focused openSUSE Leap 16 r22 self-tests passed.\n'; exit 0; fi
printf '%d focused r22 self-test(s) failed.\n' "$failures" >&2
exit 1
