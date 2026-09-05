#!/usr/bin/env bash
set -u
cd -- "$(dirname -- "$0")/.." || exit 1
failures=0
pass(){ printf '[PASS] %s\n' "$1"; }
fail_test(){ printf '[FAIL] %s\n' "$1" >&2; failures=$((failures+1)); }

if grep -Eq 'SWITCHER_RELEASE="leap16-r(2[6-9]|[3-9][0-9])"' bootloader-switcher.sh \
 && awk '/leap16_r25.sh/{a=NR} /leap16_r26.sh/{b=NR} END{exit !(a&&b&&b>a)}' bootloader-switcher.sh; then
  pass 'r26 release/load order is correct'
else
  fail_test 'r26 release/load order is wrong'
fi

# Reproduce the r25 bug: sudo -n is unavailable, but the file is directly
# readable.  r26 must return the real hash rather than an empty successful
# pipeline result.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf 'Limine fallback fixture\n' >"$tmp/payload"
expected=$(/usr/bin/sha256sum -- "$tmp/payload" | /usr/bin/awk '{print $1}')
mkdir "$tmp/bin"
cat >"$tmp/bin/sudo" <<'OUT'
#!/usr/bin/env bash
exit 1
OUT
chmod +x "$tmp/bin/sudo"
(
  PATH="$tmp/bin:/usr/bin:/bin"
  source lib/leap16_r26.sh
  got=$(r21_hash_privileged "$tmp/payload") || exit 10
  [[ $got == "$expected" ]]
)
case $? in
  0) pass 'hash helper falls back to an ordinary readable file when sudo -n has no ticket' ;;
  *) fail_test 'hash helper still returns an empty/incorrect hash when sudo -n has no ticket' ;;
esac

# A missing/unreadable path must fail rather than silently return success with
# an empty string.
(
  PATH="$tmp/bin:/usr/bin:/bin"
  source lib/leap16_r26.sh
  if got=$(r21_hash_privileged "$tmp/does-not-exist"); then
    exit 11
  fi
  [[ -z ${got:-} ]]
)
case $? in
  0) pass 'hash helper fails closed instead of returning an empty successful hash' ;;
  *) fail_test 'hash helper does not fail closed for an unreadable path' ;;
esac

# Keep the exact ASUS NVRAM matcher regression from r25 in the r26 package.
(
  source lib/r21.sh
  source lib/leap16_r25.sh
  source lib/leap16_r26.sh
  command -v r24_current_final_ids >/dev/null
  command -v r21_hash_privileged >/dev/null
)
case $? in
  0) pass 'r25 NVRAM matcher and r26 hash override load together' ;;
  *) fail_test 'r25/r26 override composition failed' ;;
esac

if (( failures == 0 )); then
  printf 'All focused openSUSE Leap 16 r26 self-tests passed.\n'
  exit 0
fi
printf '%d focused r26 self-test(s) failed.\n' "$failures" >&2
exit 1
