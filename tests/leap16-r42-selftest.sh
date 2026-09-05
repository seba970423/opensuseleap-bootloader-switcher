#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
pass(){ printf 'PASS: %s\n' "$1"; }
fail(){ printf 'FAIL: %s\n' "$1" >&2; exit 1; }

grep -Fq 'SWITCHER_RELEASE="leap16-r42"' bootloader-switcher.sh || fail 'release is not r42'
grep -Fq 'source "$SCRIPT_DIR/lib/leap16_r42.sh"' bootloader-switcher.sh || fail 'r42 layer is not sourced'
grep -Fq 'r21_hash_privileged "$PENDING_TARGET_EFI_RESOLVED"' lib/leap16_r42.sh || fail 'reverse target hashing is not privilege-stable'
grep -Fq 'leap16_require_sudo_session' lib/leap16_r42.sh || fail 'r42 does not acquire explicit sudo session'

while IFS= read -r f; do bash -n "$f" || fail "syntax: $f"; done < <(find . -type f -name '*.sh' -print | LC_ALL=C sort)
pass 'all shell files parse'

# Exact r41 failure mechanism: generic r26 used only `sudo -n sha256sum`, so a
# fresh interactive process with no cached sudo ticket produced an empty hash and
# falsely reported target mutation.  r42 must use the readable fallback and pass.
(
  set -u
  verify_pending_candidate_ownership_unchanged(){ printf 'OLD_VERIFY\n'; }
  leap16_r39_validate_grub_runtime(){ printf 'OLD_RUNTIME\n'; }
  leap16_r38_finalize(){ printf 'OLD_FINALIZE\n'; }
  leap16_r38_pending(){ return 0; }
  nvram_id_matches_path(){ return 0; }
  fail(){ printf 'FAIL:%s\n' "$*" >&2; return 1; }
  ok(){ printf 'OK:%s\n' "$*"; }
  bootloader_display_name(){ printf 'GRUB2'; }
  r26_verify_owned_manifest(){ return 0; }
  r21_hash_privileged(){ printf '%s\n' "$EXPECTED"; }
  leap16_require_sudo_session(){ return 0; }

  EXPECTED=daa744daf0fa40871d8a58e17d4dd456ca816d0d4aa534d96bf744b16a96f374
  PENDING_TARGET_BOOT_ID=0003
  PENDING_TARGET_EFI_PATH='\EFI\OPENSUSE\SHIM.EFI'
  PENDING_TARGET_EFI_RESOLVED='/boot/efi/EFI/OPENSUSE/SHIM.EFI'
  PENDING_TARGET_EFI_HASH=$EXPECTED
  PENDING_TARGET_MANIFEST=/tmp/fake-target-owned.tsv
  PENDING_TARGET=grub

  source lib/leap16_r42.sh
  verify_pending_candidate_ownership_unchanged >/dev/null
)
pass 'reverse target hash check does not depend on cached sudo -n'

# A real byte mismatch must still fail closed.
(
  set -u
  verify_pending_candidate_ownership_unchanged(){ :; }
  leap16_r39_validate_grub_runtime(){ :; }
  leap16_r38_finalize(){ :; }
  leap16_r38_pending(){ return 0; }
  nvram_id_matches_path(){ return 0; }
  fail(){ return 1; }
  ok(){ :; }
  bootloader_display_name(){ printf 'GRUB2'; }
  r26_verify_owned_manifest(){ return 0; }
  r21_hash_privileged(){ printf '%064d\n' 0; }
  leap16_require_sudo_session(){ return 0; }

  PENDING_TARGET_BOOT_ID=0003
  PENDING_TARGET_EFI_PATH='\EFI\OPENSUSE\SHIM.EFI'
  PENDING_TARGET_EFI_RESOLVED='/boot/efi/EFI/OPENSUSE/SHIM.EFI'
  PENDING_TARGET_EFI_HASH=daa744daf0fa40871d8a58e17d4dd456ca816d0d4aa534d96bf744b16a96f374
  PENDING_TARGET_MANIFEST=/tmp/fake-target-owned.tsv
  PENDING_TARGET=grub

  source lib/leap16_r42.sh
  if verify_pending_candidate_ownership_unchanged >/dev/null 2>&1; then exit 1; fi
)
pass 'real target EFI hash drift remains fail-closed'

# Manual reverse runtime/finalization must acquire privilege before delegating.
(
  set -u
  calls=''
  verify_pending_candidate_ownership_unchanged(){ :; }
  leap16_r39_validate_grub_runtime(){ calls+="runtime "; }
  leap16_r38_finalize(){ calls+="finalize "; }
  leap16_r38_pending(){ return 0; }
  leap16_require_sudo_session(){ calls+="sudo "; return 0; }
  source lib/leap16_r42.sh
  leap16_r39_validate_grub_runtime
  [[ $calls == 'sudo runtime ' ]] || exit 1
  calls=''
  leap16_r38_finalize
  [[ $calls == 'sudo finalize ' ]] || exit 1
)
pass 'manual reverse proof/finalization refresh sudo before privileged gates'

# Non-reverse behavior delegates unchanged and must not demand the r42 sudo gate.
(
  set -u
  verify_pending_candidate_ownership_unchanged(){ printf 'OLD_VERIFY\n'; }
  leap16_r39_validate_grub_runtime(){ printf 'OLD_RUNTIME\n'; }
  leap16_r38_finalize(){ printf 'OLD_FINALIZE\n'; }
  leap16_r38_pending(){ return 1; }
  leap16_require_sudo_session(){ return 99; }
  source lib/leap16_r42.sh
  [[ $(verify_pending_candidate_ownership_unchanged) == OLD_VERIFY ]] || exit 1
  [[ $(leap16_r39_validate_grub_runtime) == OLD_RUNTIME ]] || exit 1
  [[ $(leap16_r38_finalize) == OLD_FINALIZE ]] || exit 1
)
pass 'non-reverse behavior delegates unchanged'

pass 'r42 focused contract passes'
