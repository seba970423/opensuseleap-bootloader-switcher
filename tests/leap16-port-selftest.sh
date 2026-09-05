#!/usr/bin/env bash
set -u

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
failures=0
pass() { printf '[PASS] %s\n' "$*"; }
fail_test() { printf '[FAIL] %s\n' "$*" >&2; failures=$((failures + 1)); }

printf 'openSUSE Leap 16 r21 port self-test\n'
printf '===================================\n\n'

syntax_ok=1
while IFS= read -r -d '' f; do bash -n "$f" || syntax_ok=0; done < <(find "$ROOT" -type f -name '*.sh' -print0)
[[ $syntax_ok == 1 ]] && pass 'all shell files parse' || fail_test 'one or more shell files failed bash -n'

main="$ROOT/bootloader-switcher.sh"
adapter="$ROOT/lib/opensuse_leap16.sh"
r21layer="$ROOT/lib/leap16_r21.sh"
selectors=(
    '[1] Select bootloader to switch/repair'
    '[2] Manage pending/staged migration'
    '[3] Create backup of currently booted bootloader'
    '[4] List and validate backups'
    '[5] Restore a validated backup'
    '[6] Show restore plan for a backup (read-only)'
    '[7] Deep-validate current boot chain (read-only)'
    '[8] Refresh detection'
    '[9] Exit'
)
menu_ok=1
for label in "${selectors[@]}"; do grep -Fq "$label" "$main" || menu_ok=0; done
[[ $menu_ok == 1 ]] && pass 'all nine r47 top-level menu selectors are preserved' || fail_test 'one or more top-level menu selectors changed or disappeared'

r47_line=$(grep -n 'source "$SCRIPT_DIR/lib/r47.sh"' "$main" | cut -d: -f1 | head -n1)
leap_line=$(grep -n 'source "$SCRIPT_DIR/lib/opensuse_leap16.sh"' "$main" | cut -d: -f1 | head -n1)
r21_line=$(grep -n 'source "$SCRIPT_DIR/lib/leap16_r21.sh"' "$main" | cut -d: -f1 | head -n1)
[[ -n $r47_line && -n $leap_line && -n $r21_line && $leap_line -gt $r47_line && $r21_line -gt $leap_line ]] \
    && pass 'Leap adapter remains after r47 and the r21 completion layer is loaded last' \
    || fail_test 'Leap/r21 layering order is incorrect'

expected_r47=df5eaed08caff3a6dff4f1020fcd04ca6a064a13788c5814192ca50b83a70e29
actual_r47=$(sha256sum "$ROOT/lib/r47.sh" | awk '{print $1}')
[[ $actual_r47 == "$expected_r47" ]] && pass 'lib/r47.sh remains byte-identical to the user r47 source' || fail_test 'lib/r47.sh was modified'

if grep -Eq 'SWITCHER_RELEASE="leap16-r(21|22|23|24|25|26|27|28|29|30|31)"' "$main" \
   && grep -Fq 'LEAP16_PORT_PHASE="grub2-limine-two-way-automatic-transaction"' "$adapter" \
   && grep -Fq 'LEAP16_R21_FALLBACK_EFI_PATH=' "$r21layer"; then
    pass 'package identifies itself as a supported leap16-r21..r31 release with the explicit Limine fallback completion layer'
else
    fail_test 'Leap release/phase markers are inconsistent'
fi

(
    PATH=/usr/bin:/bin
    export PATH
    source "$adapter"
    case ":$PATH:" in *:/usr/sbin:*) ;; *) exit 20 ;; esac
    case ":$PATH:" in *:/sbin:*) ;; *) exit 21 ;; esac
)
[[ $? == 0 ]] && pass 'normal-user command discovery still adds Leap administrative paths process-locally' || fail_test 'Leap administrative PATH regression failed'


# r14 must change only the freshly generated Limine OS group label.  The
# captured CachyOS visual theme remains intact, while /+CachyOS no longer leaks
# into a new openSUSE candidate.
branding_fixture_rc=0
(
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/r23.sh"
    source "$adapter"
    tmp=$(mktemp -d)
    trap 'rm -rf -- "$tmp"' EXIT
    splash="$tmp/splash.png"
    conf="$tmp/limine.conf"
    printf '\211PNG\r\n\032\nfixture' >"$splash"
    R23_LIMINE_SPLASH_SOURCE="$splash"
    r23_write_cachyos_limine_theme_base "$conf" "$splash" || exit 22
    grep -Fqx -- '/+openSUSE' "$conf" || exit 23
    ! grep -Fqx -- '/+CachyOS' "$conf" || exit 24
    grep -Fqx -- '# CachyOS Limine theme' "$conf" || exit 25
    grep -Fqx -- 'wallpaper: boot():/limine-splash.png' "$conf" || exit 26
) || branding_fixture_rc=$?
case $branding_fixture_rc in
    0) pass 'r14 brands fresh Limine OS groups as openSUSE while preserving the CachyOS visual theme' ;;
    *) fail_test "r14 Limine menu-branding regression failed (rc=$branding_fixture_rc)" ;;
esac

# Load the real r47 helper lineage, then the Leap final override, for pure
# predicate/order/config fixtures. No privileged or host-mutating function is run.
(
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/storage.sh"
    source "$ROOT/lib/detect.sh"
    source "$ROOT/lib/kernels.sh"
    source "$ROOT/lib/validate.sh"
    source "$ROOT/lib/limine_validate.sh"
    source "$ROOT/lib/grub_validate.sh"
    source "$ROOT/lib/operations.sh"
    source "$ROOT/lib/staged.sh"
    source "$ROOT/lib/r22.sh"
    source "$ROOT/lib/r23.sh"
    source "$ROOT/lib/r42.sh"
    source "$adapter"

    operation_supported grub limine || exit 30
    operation_supported limine grub || exit 31
    ! operation_supported grub grub || exit 32
    ! operation_supported grub systemd-boot || exit 33
    ! operation_supported grub refind || exit 34

    boot_id_exists() { case ${1^^} in 0000|0003|0001|0002|0004|0005|0006|0007) return 0 ;; *) return 1 ;; esac; }
    [[ $(leap16_expected_candidate_order 0000 0007 '0000,0003,0001,0002,0004,0005,0006') == '0000,0003,0001,0002,0004,0005,0006,0007' ]] || exit 35

    tmp=$(mktemp -d)
    trap 'rm -rf -- "$tmp"' EXIT
    ESP_MOUNT="$tmp/esp"
    mkdir -p "$ESP_MOUNT/machine/kernel"
    printf 'kernel-bytes' >"$ESP_MOUNT/machine/kernel/vmlinuz-kernel"
    printf 'initrd-bytes' >"$ESP_MOUNT/machine/kernel/initrd-kernel"
    kh=$(b2sum "$ESP_MOUNT/machine/kernel/vmlinuz-kernel" | awk '{print $1}')
    ih=$(b2sum "$ESP_MOUNT/machine/kernel/initrd-kernel" | awk '{print $1}')
    cat >"$tmp/limine.conf" <<EOF_CONF
/+CachyOS
  //kernel
  comment: kernel-version=1.0-test
  comment: kernel-id=kernel
  protocol: linux
  module_path: boot():/machine/kernel/initrd-kernel#$ih
  path: boot():/machine/kernel/vmlinuz-kernel#$kh
  cmdline: root=UUID=test quiet
/EFI fallback
protocol: efi
path: boot():/EFI/BOOT/BOOTX64.EFI
EOF_CONF
    [[ $(limine_conf_kernel_id_count kernel "$tmp/limine.conf") == 1 ]] || exit 36
    pv=$(limine_conf_field_for_kernel kernel path "$tmp/limine.conf")
    iv=$(limine_conf_field_for_kernel kernel module_path "$tmp/limine.conf")
    [[ $pv == boot\(\):/machine/kernel/vmlinuz-kernel\#* ]] || exit 37
    [[ $iv == boot\(\):/machine/kernel/initrd-kernel\#* ]] || exit 38
    verify_limine_uri_hash "$pv" || exit 39
    verify_limine_uri_hash "$iv" || exit 40
)
fixture_rc=$?
case $fixture_rc in
    0)
        pass 'r15 enables exactly GRUB2 <-> Limine and keeps systemd-boot/rEFInd edges closed'
        pass 'r47 source-first candidate ordering appends only the Limine target after all original entries'
        pass 'direct Leap Limine entries remain compatible with r47 kernel-id parsing and BLAKE2 verification'
        ;;
    30|31|32|33|34) fail_test "r13 operation matrix fixture failed (rc=$fixture_rc)" ;;
    35) fail_test 'source-first/target-last BootOrder fixture failed' ;;
    36|37|38|39|40) fail_test "Limine config/hash compatibility fixture failed (rc=$fixture_rc)" ;;
    *) fail_test "r13 fixture failed unexpectedly (rc=$fixture_rc)" ;;
esac

# Verify the Leap-only Boot#### identity helpers against the exact shape emitted
# by efibootmgr on the test machine.  These are pure shell fixtures; no EFI
# variables are accessed or changed.
(
    source "$adapter"
    efibootmgr() {
        case "${1:-}" in
            -v)
                cat <<'EOF_EFI_V'
BootCurrent: 0000
BootOrder: 0000,0003,0001,0007
Boot0000* opensuse-secureboot	HD(1,GPT,d11b13a9-ad31-4920-a923-4f1441233c71,0x800,0x100000)/File(\EFI\opensuse\shim.efi)
Boot0007* openSUSE Limine	HD(1,GPT,d11b13a9-ad31-4920-a923-4f1441233c71,0x800,0x100000)/File(\EFI\LIMINE\LIMINE_X64.EFI)
EOF_EFI_V
                ;;
            *)
                cat <<'EOF_EFI'
BootCurrent: 0000
BootOrder: 0000,0003,0001,0007
Boot0000* opensuse-secureboot
Boot0007* openSUSE Limine
EOF_EFI
                ;;
        esac
    }
    lsblk() {
        if [[ "$*" == *PARTUUID* ]]; then
            printf '%s\n' d11b13a9-ad31-4920-a923-4f1441233c71
        else
            return 1
        fi
    }
    ESP_SOURCE=/dev/sdc1
    line=$(leap16_boot_entry_line_for_id 0007)
    [[ $line == Boot0007\*' '* ]] || exit 50
    leap16_boot_entry_is_active 0007 || exit 51
    leap16_nvram_entry_matches_current_esp 0007 || exit 52
    ! leap16_boot_entry_is_active 0008 || exit 53
)
nvram_fixture_rc=$?
case $nvram_fixture_rc in
    0) pass 'new Boot#### identity helpers require an active entry on the exact detected ESP' ;;
    *) fail_test "Boot#### identity fixture failed (rc=$nvram_fixture_rc)" ;;
esac

if grep -Fq 'LEAP16_LIMINE_VERSION="12.6.0"' "$adapter" \
   && grep -Fq '8edf447b9c3c9bbd55b1e1e43528289ccb9fc8cb6f6f9edb4de3b7a2380671fe' "$adapter" \
   && grep -Fq 'limine-binary.tar.gz' "$adapter"; then
    pass 'Limine payload acquisition is pinned to the v12.6.0 binary-release SHA256'
else
    fail_test 'pinned Limine payload contract is missing'
fi

if grep -Fq 'efibootmgr --create-only' "$adapter" \
   && grep -Fq 'efibootmgr --create-only unexpectedly changed persistent BootOrder' "$adapter" \
   && grep -Fq 'BootNext appeared during --create-only' "$adapter" \
   && grep -Fq 'One or more pre-existing Boot#### entries changed during --create-only' "$adapter" \
   && grep -Fq 'leap16_boot_entry_is_active "$target_id"' "$adapter" \
   && grep -Fq 'leap16_nvram_entry_matches_current_esp "$target_id"' "$adapter" \
   && grep -Fq 'set_source_first_boot_order "$BOOT_CURRENT" "$target_id" "$original_order"' "$adapter" \
   && ! grep -Eq 'efibootmgr[[:space:]]+-c([[:space:]]|$)|efibootmgr[[:space:]]+--create([[:space:]]|$)' "$adapter"; then
    pass 'create-only is proven non-reordering/non-BootNext before explicit source-first target-last commit'
else
    fail_test 'r13 NVRAM creation does not enforce the create-only isolation boundary'
fi

if grep -Fq 'path: boot():/EFI/BOOT/BOOTX64.EFI' "$adapter" \
   && grep -Fq 'Generic EFI fallback remained byte-identical' "$adapter" \
   && ! grep -Eq '(install|cp|mv).*EFI/BOOT/BOOTX64\.EFI' "$adapter"; then
    pass 'r13 preserves EFI/BOOT/BOOTX64.EFI byte-for-byte and exposes it only as Limine recovery menu state'
else
    fail_test 'generic EFI fallback preservation contract is missing or a direct fallback write appeared'
fi

if grep -Fq 'r13_arm_candidate_automatically()' "$adapter" \
   && grep -Fq 'R22_SYSTEM_ROOT=/var/lib/opensuse-bootloader-switcher/r13' "$adapter" \
   && grep -Fq 'Environment=LEAP16_AUTO_RESUME=1' "$adapter" \
   && grep -Fq 'leap16_promote_runtime_proven_limine_core()' "$adapter" \
   && grep -Fq 'r21 checkpoint: GRUB2 retirement stays locked until the separate Limine fallback runtime proof' "$adapter" \
   && grep -Fq 'r21_validate_fallback_runtime || return 1' "$r21layer"; then
    pass 'r13 primary automation remains intact and r21 keeps GRUB2 retirement locked behind the separate fallback proof'
else
    fail_test 'r13/r21 automated-resume/fallback-retirement boundary is missing or inconsistent'
fi

if grep -Fq 'cleanup_uncommitted_limine_candidate_pre_leap16_r04' "$adapter" \
   && grep -Fq 'Cleared unexpected transaction-owned BootNext=Boot$next before candidate cleanup' "$adapter" \
   && grep -Fq 'Unrelated BootNext=Boot$next appeared during the r13 stage; leaving it untouched' "$adapter"; then
    pass 'uncommitted cleanup clears only an unexpected transaction-owned Limine BootNext and preserves unrelated intent'
else
    fail_test 'r13 uncommitted cleanup lacks the transaction-owned BootNext safety guard'
fi

if grep -Fq '/boot/initrd-$ver' "$adapter" \
   && grep -Fq 'local grub_dir=/boot/grub2' "$adapter" \
   && grep -Fq 'r23_snapshot_source_grub_cleanup_ownership' "$adapter"; then
    pass 'r47 ownership snapshot choreography is adapted to native Leap GRUB2/kernel paths'
else
    fail_test 'Leap source ownership path adaptation is incomplete'
fi

if grep -Fq 'margin=$((32 * 1024 * 1024))' "$adapter" \
   && grep -Fq 'stat -Lc' "$adapter" \
   && grep -Fq 'df -Pk -- "$ESP_MOUNT"' "$adapter" \
   && grep -Fq 'leap16_verify_esp_capacity || return 1' "$adapter"; then
    pass 'write preflight requires exact kernel/initrd payload space plus a 32 MiB ESP margin'
else
    fail_test 'ESP candidate-capacity gate is missing or incomplete'
fi

if grep -Fq '[1] Re-run source + candidate validation' "$adapter" \
   && grep -Fq '[2] Arm Limine + install automatic resume' "$adapter" \
   && grep -Fq '[3] Roll back this exact candidate' "$adapter" \
   && grep -Fq '[PARKED; AUTO-ARM AVAILABLE]' "$adapter" \
   && grep -Fq 'After Limine reaches userspace, the transaction will prove the exact primary target, promote it, then stage the separate Limine fallback proof.' "$adapter"; then
    pass 'parked-candidate UX exposes automatic one-shot/resume handoff plus validation/rollback'
else
    fail_test 'r13 parked-candidate automation UX is incomplete'
fi

# Reproduce the real r04 failure under nounset without network access.  The
# mocked curl copies a local fixture into the requested -o path, so this executes
# leap16_download_to() itself and proves the dependent tmp assignment is safe.
(
    set -u
    source "$adapter"
    tmpd=$(mktemp -d)
    trap 'rm -rf -- "$tmpd"' EXIT
    printf 'payload' >"$tmpd/source"
    have() { [[ $1 == curl ]]; }
    curl() {
        local out="" src=""
        while (($#)); do
            case "$1" in
                -o) out=$2; shift 2 ;;
                --) shift; src=$1; shift ;;
                *) shift ;;
            esac
        done
        cp -- "$src" "$out"
    }
    leap16_download_to "$tmpd/source" "$tmpd/final" || exit 60
    [[ $(cat "$tmpd/final") == payload ]] || exit 61
    [[ ! -e "$tmpd/final.part" ]] || exit 62
)
download_fixture_rc=$?
case $download_fixture_rc in
    0) pass 'r13 payload download helper survives set -u and atomically renames the .part file' ;;
    *) fail_test "r13 nounset download regression failed (rc=$download_fixture_rc)" ;;
esac

# Reproduce the real r05 false-negative: openSUSE/file may render a perfectly
# valid x86-64 EFI PE image as "PE32+ executable for EFI (application), x86-64"
# instead of the exact "EFI application" phrase used by r05.
(
    set -u
    source "$adapter"
    tmpd=$(mktemp -d)
    trap 'rm -rf -- "$tmpd"' EXIT
    printf 'dummy' >"$tmpd/efi"
    file() { printf '%s\n' 'PE32+ executable for EFI (application), x86-64 (stripped to external PDB), 3 sections'; }
    leap16_is_x86_64_efi_application "$tmpd/efi" || exit 70
    file() { printf '%s\n' 'PE32+ executable (EFI application) x86-64, for MS Windows, 3 sections'; }
    leap16_is_x86_64_efi_application "$tmpd/efi" || exit 71
    file() { printf '%s\n' 'PE32+ executable for EFI (application), Aarch64, 3 sections'; }
    ! leap16_is_x86_64_efi_application "$tmpd/efi" || exit 72
)
efi_file_fixture_rc=$?
case $efi_file_fixture_rc in
    0) pass 'r13 accepts distro-varying file(1) wording while still requiring PE32+ + EFI + x86-64' ;;
    *) fail_test "r13 EFI file(1) semantic regression failed (rc=$efi_file_fixture_rc)" ;;
esac


# Reproduce the r06 /dev/sdc1 failure without relying on lsblk PARTN.  Leap may
# provide PKNAME while PARTN is absent/unusable, so the adapter must derive the
# partition number from sysfs/udev/name fallback.  Cover SATA and NVMe naming.
(
    set -u
    source "$adapter"
    leap16_sysfs_partition_number() { return 1; }
    leap16_udev_partition_number() { return 1; }
    lsblk() {
        local src=${!#}
        case "$src" in
            /dev/sdc1) printf '%s\n' sdc ;;
            /dev/nvme0n1p3) printf '%s\n' nvme0n1 ;;
            *) return 1 ;;
        esac
    }
    ESP_SOURCE=/dev/sdc1
    [[ $(leap16_esp_disk_part) == $'/dev/sdc\t1' ]] || exit 80
    ESP_SOURCE=/dev/nvme0n1p3
    [[ $(leap16_esp_disk_part) == $'/dev/nvme0n1\t3' ]] || exit 81
)
esp_part_fixture_rc=$?
case $esp_part_fixture_rc in
    0) pass 'r13 derives ESP disk/partition without depending on lsblk PARTN (SATA + NVMe fixtures)' ;;
    *) fail_test "r13 ESP disk/partition regression failed (rc=$esp_part_fixture_rc)" ;;
esac

# Restore the r47 diagnostic UX for the Leap override: timestamped user-owned
# directories only, with Leap-specific rpm/GRUB2/EFI state and no auto archive.
(
    set -u
    source "$ROOT/lib/common.sh"
    source "$adapter"
    tmpd=$(mktemp -d)
    trap 'rm -rf -- "$tmpd"' EXIT
    LEAP16_DIAGNOSTIC_ROOT="$tmpd/opensuse-bootloader-diagnostics"
    ESP_MOUNT="$tmpd/esp"
    ESP_SOURCE=/dev/sdc1
    ESP_UUID=TEST-ESP
    ROOT_SOURCE=/dev/sdc2
    ROOT_UUID=test-root
    BOOTLOADER=grub
    BOOT_CURRENT=0000
    BOOT_NEXT=""
    mkdir -p "$ESP_MOUNT/EFI/BOOT" "$ESP_MOUNT/EFI/LIMINE"
    printf 'fallback' >"$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"
    printf 'limine config' >"$ESP_MOUNT/limine.conf"
    printf 'efi' >"$ESP_MOUNT/EFI/LIMINE/LIMINE_X64.EFI"
    efibootmgr() {
        if [[ ${1:-} == -v ]]; then
            printf '%s\n' 'BootCurrent: 0000' 'BootOrder: 0000,0001' 'Boot0000* opensuse-secureboot';
        else
            printf '%s\n' 'BootCurrent: 0000' 'BootOrder: 0000,0001';
        fi
    }
    out=$(leap16_capture_diagnostics candidate-nvram-stage-failed | tail -n1) || exit 90
    [[ -d $out ]] || exit 91
    [[ $out == "$LEAP16_DIAGNOSTIC_ROOT/"*-candidate-nvram-stage-failed ]] || exit 92
    [[ -s $out/switcher-state.txt && -s $out/efibootmgr-v.txt && -s $out/lsblk-f.txt ]] || exit 93
    [[ -s $out/limine.conf && -s $out/boot-artifact-sha256.txt ]] || exit 94
    if find "$LEAP16_DIAGNOSTIC_ROOT" -maxdepth 1 -type f \( -name '*.tar' -o -name '*.tar.gz' -o -name '*.tgz' \) | grep -q .; then exit 95; fi
)
diag_fixture_rc=$?
case $diag_fixture_rc in
    0) pass 'r13 restores timestamped Leap diagnostic folders with no auto-created diagnostic archives' ;;
    *) fail_test "r13 diagnostic-folder regression failed (rc=$diag_fixture_rc)" ;;
esac

if grep -Fq 'leap16_abort_uncommitted_candidate candidate-nvram-stage-failed' "$adapter" \
   && grep -Fq 'leap16_stage_diagnostic candidate-pass' "$adapter" \
   && grep -Fq 'LEAP16_DIAGNOSTIC_ROOT=' "$adapter" \
   && grep -Fq 'Diagnostic snapshot: %s' "$adapter"; then
    pass 'candidate failures are captured before rollback and candidate-pass diagnostics are persisted into r47 pending metadata'
else
    fail_test 'candidate-stage diagnostics are not wired at the r47-equivalent checkpoints'
fi


# r13 must not use the current-backend GRUB validator while Limine is actually
# BootCurrent. Verify the dispatch chooses the recorded-source validator only in
# the target session and delegates to the inherited source-session path on GRUB.
(
    set -u
    source "$adapter"
    leap16_validate_recorded_grub_source_recovery() { return 0; }
    verify_pending_source_recovery_unchanged_pre_leap16_r10() { return 77; }
    PENDING_SOURCE=grub PENDING_TARGET=limine BOOTLOADER=limine
    verify_pending_source_recovery_unchanged || exit 100
    BOOTLOADER=grub
    verify_pending_source_recovery_unchanged
    [[ $? == 77 ]] || exit 101
)
source_dispatch_rc=$?
case $source_dispatch_rc in
    0) pass 'runtime source recovery validates recorded GRUB2 state from Limine without pretending GRUB2 is BootCurrent' ;;
    *) fail_test "r13 recorded-source GRUB2 dispatch regression failed (rc=$source_dispatch_rc)" ;;
esac

# Execute the r13 BootNext arming function against a fully mocked firmware
# interface. This proves that it writes only BootNext, leaves persistent
# BootOrder unchanged, persists boot-armed, and requires a diagnostic folder.
(
    set -u
    source "$adapter"
    ok() { :; }
    warn() { :; }
    fail() { return 1; }
    tmpd=$(mktemp -d)
    trap 'rm -rf -- "$tmpd"' EXIT
    MOCK_NEXT=""
    MOCK_ORDER='0000,0001,0002,0003,0004,0005'
    PENDING_PHASE=candidate-ready
    PENDING_SOURCE=grub PENDING_TARGET=limine
    PENDING_OLD_BOOT_ID=0000 PENDING_TARGET_BOOT_ID=0005
    PENDING_OLD_BOOT_EFI_PATH='\\EFI\\OPENSUSE\\SHIM.EFI'
    PENDING_TARGET_EFI_PATH='\\EFI\\LIMINE\\LIMINE_X64.EFI'
    PENDING_ORIGINAL_BOOT_ORDER='0000,0001,0002,0003,0004'
    BOOTLOADER=grub BOOT_CURRENT=0000 BOOT_NEXT=""
    validate_pending_compatibility() { return 0; }
    detect_bootloader() { BOOTLOADER=grub; BOOT_CURRENT=0000; BOOT_NEXT=$MOCK_NEXT; }
    leap16_require_sudo_session() { return 0; }
    run_validation() { return 0; }
    verify_pending_source_recovery_unchanged() { return 0; }
    verify_pending_candidate_ownership_unchanged() { return 0; }
    validate_pending_target_deep() { return 0; }
    pending_bootnext_id() { printf '%s\n' "$MOCK_NEXT"; }
    leap16_current_boot_order() { printf '%s\n' "$MOCK_ORDER"; }
    leap16_expected_pending_candidate_order() { printf '%s\n' "$MOCK_ORDER"; }
    leap16_validate_pending_firmware_order() { return 0; }
    nvram_id_matches_path() { return 0; }
    leap16_nvram_entry_matches_current_esp() { return 0; }
    pending_set_phase() { PENDING_PHASE=$1; return 0; }
    leap16_capture_required_diagnostic() { mkdir -p "$tmpd/$1"; printf '%s\n' "$tmpd/$1"; }
    leap16_stage_diagnostic() { return 0; }
    sudo() {
        if [[ $1 == efibootmgr && $2 == -n && $3 == 0005 ]]; then MOCK_NEXT=0005; return 0; fi
        if [[ $1 == efibootmgr && $2 == -N ]]; then MOCK_NEXT=""; return 0; fi
        return 0
    }
    arm_pending_one_time_boot <<<ARM >/dev/null || exit 110
    [[ $MOCK_NEXT == 0005 ]] || exit 111
    [[ $PENDING_PHASE == boot-armed ]] || exit 112
    [[ $MOCK_ORDER == '0000,0001,0002,0003,0004,0005' ]] || exit 113
    [[ -d $tmpd/bootnext-armed ]] || exit 114
)
arm_fixture_rc=$?
case $arm_fixture_rc in
    0) pass 'mocked r13 arming sets only transaction BootNext, preserves exact BootOrder, persists boot-armed and captures diagnostics' ;;
    *) fail_test "r13 mocked BootNext arming regression failed (rc=$arm_fixture_rc)" ;;
esac

if grep -Fq 'runtime-arrival' "$adapter" \
   && grep -Fq 'runtime-pass' "$adapter" \
   && grep -Fq 'source-return-pass' "$adapter" \
   && grep -Fq "leap16_validate_pending_firmware_order 'Runtime'" "$adapter" \
   && grep -Fq 'leap16_validate_recorded_grub_source_recovery' "$adapter"; then
    pass 'r13 runtime proof captures arrival/pass/source-return diagnostics and re-proves GRUB2 recovery through the BBS-aware firmware gate'
else
    fail_test 'r13 runtime/source-return proof wiring is incomplete'
fi


# Reproduce the ASUS hardware behavior that motivated r13. The recorded
# candidate baseline contains three BBS placeholders; current firmware has
# garbage-collected them. The stable EFI-file topology must pass, while loss of
# a real EFI entry (Boot0001) must fail rather than being normalized away.
(
    set -u
    source "$ROOT/lib/detect.sh"
    source "$adapter"
    tmpd=$(mktemp -d)
    trap 'rm -rf -- "$tmpd"' EXIT
    mkdir -p "$tmpd/candidate"
    cat >"$tmpd/candidate/efibootmgr-v.txt" <<'EOF_BASE'
BootCurrent: 0000
BootOrder: 0000,0001,0002,0003,0004,0005
Boot0000* opensuse-secureboot HD(1,GPT,test)/File(\EFI\OPENSUSE\SHIM.EFI)
Boot0001* opensuse HD(1,GPT,test)/File(\EFI\OPENSUSE\GRUBX64.EFI)
Boot0002* UEFI:CD/DVD Drive BBS(129,,0x0)
Boot0003* UEFI:Removable Device BBS(130,,0x0)
Boot0004* UEFI:Network Device BBS(131,,0x0)
Boot0005* openSUSE Limine HD(1,GPT,test)/File(\EFI\LIMINE\LIMINE_X64.EFI)
EOF_BASE
    PENDING_OLD_BOOT_ID=0000
    PENDING_TARGET_BOOT_ID=0005
    PENDING_ORIGINAL_BOOT_ORDER=0000,0001,0002,0003,0004
    PENDING_DIAGNOSTIC_PATH="$tmpd/candidate"
    PENDING_TRANSACTION_SNAPSHOT_DIR=""
    efibootmgr() {
        cat <<'EOF_CURRENT'
BootCurrent: 0005
BootOrder: 0000,0001,0005
Boot0000* opensuse-secureboot HD(1,GPT,test)/File(\EFI\OPENSUSE\SHIM.EFI)
Boot0001* opensuse HD(1,GPT,test)/File(\EFI\OPENSUSE\GRUBX64.EFI)
Boot0005* openSUSE Limine HD(1,GPT,test)/File(\EFI\LIMINE\LIMINE_X64.EFI)
EOF_CURRENT
    }
    leap16_assess_pending_firmware_order || exit 120
    [[ $LEAP16_ORDER_EXPECTED_STABLE == 0000,0001,0005 ]] || exit 121
    [[ $LEAP16_ORDER_CURRENT_STABLE == 0000,0001,0005 ]] || exit 122
    [[ $LEAP16_ORDER_BBS_ORIGINAL == 0002,0003,0004 ]] || exit 123
    [[ $LEAP16_ORDER_BBS_MISSING == 0002,0003,0004 ]] || exit 124

    efibootmgr() {
        cat <<'EOF_BAD'
BootCurrent: 0005
BootOrder: 0000,0005
Boot0000* opensuse-secureboot HD(1,GPT,test)/File(\EFI\OPENSUSE\SHIM.EFI)
Boot0005* openSUSE Limine HD(1,GPT,test)/File(\EFI\LIMINE\LIMINE_X64.EFI)
EOF_BAD
    }
    ! leap16_assess_pending_firmware_order || exit 125
    [[ $LEAP16_ORDER_REASON == *'Boot0001 disappeared'* ]] || exit 126
)
bbs_fixture_rc=$?
case $bbs_fixture_rc in
    0) pass 'r13 tolerates/report ASUS BBS garbage-collection but fails loss of a real EFI-file Boot#### entry' ;;
    *) fail_test "r13 BBS-aware firmware-order regression failed (rc=$bbs_fixture_rc)" ;;
esac

# Post-reboot diagnostics must recover transaction identity from persisted r47
# pending metadata when the live staging globals are absent. This reproduces
# the source-return-pass defect seen in r08.
(
    set -u
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/detect.sh"
    source "$adapter"
    tmpd=$(mktemp -d)
    trap 'rm -rf -- "$tmpd"' EXIT
    LEAP16_DIAGNOSTIC_ROOT="$tmpd/diag"
    PENDING_STATE_DIR="$tmpd/state"
    PENDING_STATE_FILE="$PENDING_STATE_DIR/pending-migration.tsv"
    mkdir -p "$PENDING_STATE_DIR" "$tmpd/snapshot" "$tmpd/candidate" "$tmpd/esp/EFI/BOOT"
    {
        printf 'phase\truntime-validated\n'
        printf 'old_boot_id\t0000\n'
        printf 'target_boot_id\t0005\n'
        printf 'transaction_snapshot_dir\t%s/snapshot\n' "$tmpd"
        printf 'original_boot_order\t0000,0001,0002,0003,0004\n'
        printf 'diagnostic_path\t%s/candidate\n' "$tmpd"
    } >"$PENDING_STATE_FILE"
    cat >"$tmpd/candidate/efibootmgr-v.txt" <<'EOF_BASE2'
BootCurrent: 0000
BootOrder: 0000,0001,0002,0003,0004,0005
Boot0000* opensuse-secureboot HD(1,GPT,test)/File(\EFI\OPENSUSE\SHIM.EFI)
Boot0001* opensuse HD(1,GPT,test)/File(\EFI\OPENSUSE\GRUBX64.EFI)
Boot0002* UEFI:CD/DVD Drive BBS(129,,0x0)
Boot0003* UEFI:Removable Device BBS(130,,0x0)
Boot0004* UEFI:Network Device BBS(131,,0x0)
Boot0005* openSUSE Limine HD(1,GPT,test)/File(\EFI\LIMINE\LIMINE_X64.EFI)
EOF_BASE2
    ESP_MOUNT="$tmpd/esp" ESP_SOURCE=/dev/sdc1 ESP_UUID=TEST ROOT_SOURCE=/dev/sdc2 ROOT_UUID=ROOT
    BOOTLOADER=grub BOOT_CURRENT=0000 BOOT_NEXT=""
    unset TRANSACTION_SNAPSHOT_DIR LEAP16_CREATED_TARGET_ID PENDING_TRANSACTION_SNAPSHOT_DIR PENDING_TARGET_BOOT_ID PENDING_ORIGINAL_BOOT_ORDER PENDING_OLD_BOOT_ID PENDING_PHASE PENDING_DIAGNOSTIC_PATH 2>/dev/null || true
    printf fallback >"$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"
    efibootmgr() {
        cat <<'EOF_NOW'
BootCurrent: 0000
BootOrder: 0000,0001,0005
Boot0000* opensuse-secureboot HD(1,GPT,test)/File(\EFI\OPENSUSE\SHIM.EFI)
Boot0001* opensuse HD(1,GPT,test)/File(\EFI\OPENSUSE\GRUBX64.EFI)
Boot0005* openSUSE Limine HD(1,GPT,test)/File(\EFI\LIMINE\LIMINE_X64.EFI)
EOF_NOW
    }
    out=$(leap16_capture_diagnostics source-return-pass | tail -n1) || exit 130
    grep -Fqx 'transaction_phase=runtime-validated' "$out/switcher-state.txt" || exit 131
    grep -Fqx "transaction_snapshot_dir=$tmpd/snapshot" "$out/switcher-state.txt" || exit 132
    grep -Fqx 'created_target_id=0005' "$out/switcher-state.txt" || exit 133
    grep -Fqx 'original_boot_order=0000,0001,0002,0003,0004' "$out/switcher-state.txt" || exit 134
    grep -Fqx 'stable_expected_boot_order=0000,0001,0005' "$out/firmware-order.txt" || exit 135
    grep -Fqx 'missing_original_bbs_ids=0002,0003,0004' "$out/firmware-order.txt" || exit 136
)
diag_persist_rc=$?
case $diag_persist_rc in
    0) pass 'r13 post-reboot diagnostics recover persisted transaction identity and record explicit BBS firmware churn' ;;
    *) fail_test "r13 post-reboot diagnostic persistence regression failed (rc=$diag_persist_rc)" ;;
esac

# r13 must suppress only the irrelevant "source asset unavailable" warning.
# The actual installed ESP splash and all inherited hard failures remain intact.
(
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/r23.sh"
    source "$adapter"

    tmp=$(mktemp -d)
    trap 'rm -rf -- "$tmp"' EXIT
    ESP_MOUNT="$tmp/esp"
    mkdir -p "$ESP_MOUNT"
    R23_LIMINE_SPLASH_SOURCE="$tmp/nonexistent-staging-source.png"
    R23_LIMINE_SPLASH_NAME=limine-splash.png
    printf 'splash-bytes' >"$ESP_MOUNT/$R23_LIMINE_SPLASH_NAME"
    cat >"$ESP_MOUNT/limine.conf" <<'EOF_THEME'
# CachyOS Limine theme
term_palette: 1e1e2e;f38ba8;a6e3a1;f9e2af;89b4fa;f5c2e7;94e2d5;cdd6f4
term_palette_bright: 585b70;f38ba8;a6e3a1;f9e2af;89b4fa;f5c2e7;94e2d5;cdd6f4
term_background: ffffffff
term_foreground: cdd6f4
term_background_bright: ffffffff
term_foreground_bright: cdd6f4
interface_branding:
wallpaper: boot():/limine-splash.png
EOF_THEME

    out=$(validate_cachyos_limine_theme) || exit 80
    ! grep -Fq 'Installed CachyOS wallpaper source is unavailable' <<<"$out" || exit 81
    grep -Fq 'Theme summary: 0 failure(s)' <<<"$out" || exit 82

    rm -f -- "$ESP_MOUNT/$R23_LIMINE_SPLASH_NAME"
    bad=$(validate_cachyos_limine_theme 2>&1) && exit 83
    grep -Fq 'CachyOS Limine splash is missing' <<<"$bad" || exit 84

    printf 'installed-splash' >"$ESP_MOUNT/$R23_LIMINE_SPLASH_NAME"
    printf 'different-source' >"$R23_LIMINE_SPLASH_SOURCE"
    mismatch=$(validate_cachyos_limine_theme) || exit 85
    grep -Fq 'ESP splash differs from the currently installed CachyOS wallpaper asset' <<<"$mismatch" || exit 86
)
theme_warning_rc=$?
case $theme_warning_rc in
    0) pass 'r13 suppresses only the irrelevant missing staging-source warning while preserving real splash failures/mismatch warnings' ;;
    *) fail_test "r13 Limine splash warning regression failed (rc=$theme_warning_rc)" ;;
esac



# r13 must repair the exact partial rollback state observed on hardware: r10
# could already remove the transaction-created splash/EFI namespace and then
# strand pending metadata.  The r13 verifier accepts only that ownership-proven
# already-absent state, still verifies the remaining managed payload bytes, and
# the rollback implementation must never replay the stale original BootOrder.
(
    set -u
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/storage.sh"
    source "$ROOT/lib/detect.sh"
    source "$ROOT/lib/limine_validate.sh"
    source "$ROOT/lib/staged.sh"
    source "$ROOT/lib/r22.sh"
    source "$ROOT/lib/r23.sh"
    source "$adapter"

    tmp=$(mktemp -d)
    trap 'rm -rf -- "$tmp"' EXIT
    ESP_MOUNT="$tmp/esp"
    mkdir -p "$ESP_MOUNT/machine/k1" "$tmp/snap" "$tmp/diag"
    PENDING_TRANSACTION_SNAPSHOT_DIR="$tmp/snap"
    PENDING_DIAGNOSTIC_PATH="$tmp/diag"
    PENDING_TARGET_BOOT_ID=0005
    PENDING_TARGET_EFI_PATH='\EFI\LIMINE\LIMINE_X64.EFI'
    PENDING_TARGET_EFI_RESOLVED="$ESP_MOUNT/EFI/LIMINE/LIMINE_X64.EFI"
    PENDING_TARGET_EFI_HASH=$(printf 'unused-fixture' | sha256sum | awk '{print $1}')
    PENDING_LIMINE_CONF_PATH="$ESP_MOUNT/limine.conf"
    PENDING_LIMINE_MANAGED_DIR="$ESP_MOUNT/machine"
    PENDING_LIMINE_DEFAULT_CREATED=0
    R23_LIMINE_SPLASH_NAME=limine-splash.png

    printf 'existed\t0\narchive_sha256\t\n' >"$(r23_prestage_limine_efi_record_path "$tmp/snap")"
    printf 'existed\t0\nhash\t\n' >"$(r23_prestage_splash_record_path "$tmp/snap")"
    printf 'payload' >"$ESP_MOUNT/machine/k1/vmlinuz"
    h=$(b2sum "$ESP_MOUNT/machine/k1/vmlinuz" | awk '{print $1}')
    printf 'path: boot():/machine/k1/vmlinuz#%s\n' "$h" >"$tmp/diag/limine.conf"
    PENDING_LIMINE_CONF_HASH=$(sha256sum "$tmp/diag/limine.conf" | awk '{print $1}')

    boot_id_exists() { return 0; }
    nvram_id_matches_path() { return 0; }
    sudo() { [[ ${1:-} == -n ]] && shift; "$@"; }

    leap16_verify_rollback_candidate_state || exit 140
    [[ $LEAP16_ROLLBACK_PARTIAL == 1 ]] || exit 141

    fn=$(declare -f rollback_pending_grub_to_limine_pre_r13)
    grep -Fq 'leap16_verify_rollback_candidate_state || return 1' <<<"$fn" || exit 142
    grep -Fq 'read -r -p' <<<"$fn" || exit 143
    ! grep -Fq 'efibootmgr -o "$PENDING_ORIGINAL_BOOT_ORDER"' <<<"$fn" || exit 144
    ! grep -Fq 'set_source_first_boot_order' <<<"$fn" || exit 145
    grep -Fq 'Persistent BootOrder remains source-first after removing only the target' <<<"$fn" || exit 146
)
rollback_fixture_rc=$?
case $rollback_fixture_rc in
    0) pass 'r13 recovers the real r10 partial rollback state and never resurrects firmware-garbage-collected BBS Boot#### IDs' ;;
    *) fail_test "r13 partial rollback/BBS-preservation regression failed (rc=$rollback_fixture_rc)" ;;
esac

if grep -Fq 'leap16_verify_rollback_fallback_state || return 1' "$adapter" \
   && grep -Fq 'rollback_pending_fallback_state || return 1' "$adapter" \
   && grep -Fq 'leap16_stage_diagnostic rollback-before-cleanup' "$adapter" \
   && grep -Fq 'leap16_stage_diagnostic rollback-pass' "$adapter" \
   && grep -Fq 'ROLLBACK-COMPLETE. GRUB2 remains authoritative' "$adapter"; then
    pass 'r13 proves rollback state before mutation, captures before/after diagnostics and clears the pending transaction only after teardown'
else
    fail_test 'r13 rollback choreography/diagnostic cleanup wiring is incomplete'
fi



# r13 regression: after a rollback in the same interactive process, the loaded
# PENDING_TRANSACTION_SNAPSHOT_DIR may still name the just-deleted old snapshot.
# A fresh active TRANSACTION_SNAPSHOT_DIR must win for r23 theme ownership.
(
    set -u
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/r23.sh"
    source "$adapter"
    tmp=$(mktemp -d)
    trap 'rm -rf -- "$tmp"' EXIT
    ESP_MOUNT="$tmp/esp"
    mkdir -p "$ESP_MOUNT" "$tmp/active"
    TRANSACTION_SNAPSHOT_DIR="$tmp/active"
    PENDING_TRANSACTION_SNAPSHOT_DIR="$tmp/deleted-old-snapshot"
    printf 'splash' >"$ESP_MOUNT/limine-splash.png"
    [[ $(r23_theme_snapshot_root) == "$tmp/active" ]] || exit 160
    sudo() { [[ ${1:-} == -n ]] && shift; "$@"; }
    r23_record_limine_theme_manifest >/dev/null || exit 161
    [[ -f "$tmp/active/limine-theme-required" && -f "$tmp/active/limine-theme.tsv" ]] || exit 162
)
lifecycle_fixture_rc=$?
case $lifecycle_fixture_rc in
    0) pass 'r13 fresh live transaction snapshot outranks stale same-process PENDING_* state after rollback' ;;
    *) fail_test "r13 stale-pending/live-transaction snapshot regression failed (rc=$lifecycle_fixture_rc)" ;;
esac

# r13 rollback-pass diagnostics must represent the actual neutral final state:
# no persisted pending file and target Boot#### excluded from expected stable order.
(
    set -u
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/storage.sh"
    source "$ROOT/lib/detect.sh"
    source "$ROOT/lib/staged.sh"
    source "$adapter"
    tmp=$(mktemp -d)
    trap 'rm -rf -- "$tmp"' EXIT
    mkdir -p "$tmp/snap"
    PENDING_TRANSACTION_SNAPSHOT_DIR="$tmp/snap"
    PENDING_OLD_BOOT_ID=0000
    PENDING_TARGET_BOOT_ID=0005
    PENDING_ORIGINAL_BOOT_ORDER=0000,0001,0002,0003,0004
    cat >"$tmp/snap/prestage-efibootmgr-v.txt" <<'EOF'
BootCurrent: 0000
BootOrder: 0000,0001,0002,0003,0004
Boot0000* opensuse-secureboot HD(1,GPT,aaaa,0x800,0xff000)/File(\EFI\OPENSUSE\SHIM.EFI)
Boot0001* opensuse HD(1,GPT,aaaa,0x800,0xff000)/File(\EFI\OPENSUSE\GRUBX64.EFI)
Boot0002* UEFI:CD/DVD Drive BBS(129,,0x0)
Boot0003* UEFI:Removable Device BBS(130,,0x0)
Boot0004* UEFI:Network Device BBS(131,,0x0)
EOF
    efibootmgr() {
        cat <<'EOF'
BootCurrent: 0000
BootOrder: 0000,0001,0002,0003,0004
Boot0000* opensuse-secureboot HD(1,GPT,aaaa,0x800,0xff000)/File(\EFI\OPENSUSE\SHIM.EFI)
Boot0001* opensuse HD(1,GPT,aaaa,0x800,0xff000)/File(\EFI\OPENSUSE\GRUBX64.EFI)
Boot0002* UEFI:CD/DVD Drive BBS(129,,0x0)
Boot0003* UEFI:Removable Device BBS(130,,0x0)
Boot0004* UEFI:Network Device BBS(131,,0x0)
EOF
    }
    leap16_write_firmware_order_report "$tmp/report" rollback-pass
    grep -Fqx 'assessment=pass' "$tmp/report" || exit 170
    grep -Fqx 'stable_expected_boot_order=0000,0001' "$tmp/report" || exit 171
    grep -Fqx 'stable_current_boot_order=0000,0001' "$tmp/report" || exit 172
)
rollback_pass_fixture_rc=$?
case $rollback_pass_fixture_rc in
    0) pass 'r13 rollback-pass firmware diagnostics expect the source-only stable EFI topology after target deletion' ;;
    *) fail_test "r13 rollback-pass firmware diagnostic regression failed (rc=$rollback_pass_fixture_rc)" ;;
esac

if grep -Fq 'rm -f -- "$PENDING_STATE_FILE"' "$adapter" \
   && grep -Fq 'leap16_stage_diagnostic rollback-pass' "$adapter" \
   && grep -Fq 'pending_reset' "$adapter" \
   && grep -Fq 'if [[ $phase == rollback-pass ]]' "$adapter"; then
    pass 'r13 clears persisted pending state before final rollback-pass capture and resets in-memory transaction state afterward'
else
    fail_test 'r13 rollback-pass final-state lifecycle wiring is incomplete'
fi

# r13 candidate-pass diagnostics are captured before pending state is serialized.
# The live transaction firmware baseline must therefore outrank any stale
# post-reboot/pending lookup.
(
    set -u
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/detect.sh"
    source "$adapter"
    tmp=$(mktemp -d)
    trap 'rm -rf -- "$tmp"' EXIT
    mkdir -p "$tmp/live"
    printf 'BootOrder: 0000,0001\n' >"$tmp/live/prestage-efibootmgr-v.txt"
    TRANSACTION_SNAPSHOT_DIR="$tmp/live"
    PENDING_TRANSACTION_SNAPSHOT_DIR="$tmp/stale"
    [[ $(leap16_pending_firmware_baseline_path) == "$tmp/live/prestage-efibootmgr-v.txt" ]] || exit 180
)
live_fw_baseline_rc=$?
case $live_fw_baseline_rc in
    0) pass 'r13 candidate-pass firmware diagnostics use the live transaction baseline before pending metadata exists' ;;
    *) fail_test "r13 live firmware-baseline precedence regression failed (rc=$live_fw_baseline_rc)" ;;
esac

# Verify the openSUSE-specific r47 root-owned resume unit/config contract without
# installing anything on the host.
(
    set -u
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/r22.sh"
    source "$adapter"
    tmp=$(mktemp -d)
    trap 'rm -rf -- "$tmp"' EXIT
    PENDING_CREATED='2026-08-29T22:00:00+03:00'
    PENDING_MACHINE_ID=fixture-machine
    PENDING_SOURCE=grub
    PENDING_TARGET=limine
    PENDING_OLD_BOOT_ID=0000
    PENDING_TARGET_BOOT_ID=0005
    r22_write_resume_conf "$tmp/resume.conf" '/var/lib/opensuse-bootloader-switcher/r13/bundle' "$tmp/user/pending-migration.tsv" "$tmp/user/.prestage.fixture" 1000 1000 '/home/test' || exit 181
    r22_write_systemd_unit "$tmp/unit" '/var/lib/opensuse-bootloader-switcher/r13/bundle' '/var/lib/opensuse-bootloader-switcher/r13/bundle/state' || exit 182
    grep -Fqx $'user_diagnostic_root\t/home/test/opensuse-bootloader-diagnostics' "$tmp/resume.conf" || exit 183
    grep -Fq 'Environment=LEAP16_AUTO_RESUME=1' "$tmp/unit" || exit 184
    grep -Fq 'BOOTLOADER_SWITCHER_STATE_DIR=/var/lib/opensuse-bootloader-switcher/r13/bundle/state' "$tmp/unit" || exit 185
    grep -Fq 'ExecStart=/usr/bin/bash /var/lib/opensuse-bootloader-switcher/r13/bundle/tool/bootloader-switcher.sh --resume-transaction-root' "$tmp/unit" || exit 186
    grep -Fq 'WantedBy=multi-user.target' "$tmp/unit" || exit 187
)
resume_unit_rc=$?
case $resume_unit_rc in
    0) pass 'r13 ports the r47 root-owned copied-tool/copied-state systemd resume contract into an openSUSE namespace' ;;
    *) fail_test "r13 root-owned resume unit/config fixture failed (rc=$resume_unit_rc)" ;;
esac

# Pure order constructors: promotion changes only the intended priority, while
# recovery returns the source first without manufacturing missing firmware BBS
# IDs.
(
    set -u
    source "$adapter"
    PENDING_OLD_BOOT_ID=0000
    PENDING_TARGET_BOOT_ID=0005
    MOCK_ORDER='0000,0001,0002,0003,0004,0005'
    leap16_current_boot_order() { printf '%s\n' "$MOCK_ORDER"; }
    [[ $(r13_promoted_order_from_current) == '0005,0000,0001,0002,0003,0004' ]] || exit 188
    MOCK_ORDER='0005,0000,0001,0003,0005'
    [[ $(r13_source_first_order_from_current) == '0000,0001,0003,0005' ]] || exit 189
)
order_builder_rc=$?
case $order_builder_rc in
    0) pass 'r13 promotion/source-recovery order builders move only source/target and preserve currently existing unrelated firmware entries' ;;
    *) fail_test "r13 promotion/source-recovery order fixture failed (rc=$order_builder_rc)" ;;
esac

# Promotion accounting must accept ASUS removal of firmware-owned BBS entries,
# but still reject disappearance of a real EFI-file entry such as Boot0001.
(
    set -u
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/detect.sh"
    source "$ROOT/lib/staged.sh"
    source "$adapter"
    tmp=$(mktemp -d)
    trap 'rm -rf -- "$tmp"' EXIT
    mkdir -p "$tmp/snap"
    TRANSACTION_SNAPSHOT_DIR="$tmp/snap"
    PENDING_TRANSACTION_SNAPSHOT_DIR="$tmp/snap"
    PENDING_OLD_BOOT_ID=0000
    PENDING_TARGET_BOOT_ID=0005
    PENDING_OLD_BOOT_EFI_PATH='\\EFI\\OPENSUSE\\SHIM.EFI'
    PENDING_TARGET_EFI_PATH='\\EFI\\LIMINE\\LIMINE_X64.EFI'
    PENDING_ORIGINAL_BOOT_ORDER='0000,0001,0002,0003,0004'
    cat >"$tmp/snap/prestage-efibootmgr-v.txt" <<'EOF_BASE'
BootCurrent: 0000
BootOrder: 0000,0001,0002,0003,0004
Boot0000* opensuse-secureboot HD(1,GPT,aaaa,0x800,0xff000)/File(\EFI\OPENSUSE\SHIM.EFI)
Boot0001* opensuse HD(1,GPT,aaaa,0x800,0xff000)/File(\EFI\OPENSUSE\GRUBX64.EFI)
Boot0002* UEFI:CD/DVD Drive BBS(129,,0x0)
Boot0003* UEFI:Removable Device BBS(130,,0x0)
Boot0004* UEFI:Network Device BBS(131,,0x0)
EOF_BASE
    MOCK_LOSE_REAL=0
    efibootmgr() {
        if ((MOCK_LOSE_REAL)); then
            cat <<'EOF_CUR_BAD'
BootCurrent: 0005
BootOrder: 0005,0000
Boot0005* openSUSE Limine HD(1,GPT,aaaa,0x800,0xff000)/File(\EFI\LIMINE\LIMINE_X64.EFI)
Boot0000* opensuse-secureboot HD(1,GPT,aaaa,0x800,0xff000)/File(\EFI\OPENSUSE\SHIM.EFI)
EOF_CUR_BAD
        else
            cat <<'EOF_CUR'
BootCurrent: 0005
BootOrder: 0005,0000,0001
Boot0005* openSUSE Limine HD(1,GPT,aaaa,0x800,0xff000)/File(\EFI\LIMINE\LIMINE_X64.EFI)
Boot0000* opensuse-secureboot HD(1,GPT,aaaa,0x800,0xff000)/File(\EFI\OPENSUSE\SHIM.EFI)
Boot0001* opensuse HD(1,GPT,aaaa,0x800,0xff000)/File(\EFI\OPENSUSE\GRUBX64.EFI)
EOF_CUR
        fi
    }
    leap16_boot_entry_is_active() { case ${1^^} in 0000|0001|0005) ((MOCK_LOSE_REAL == 0 || ${1^^} != 0001));; *) return 1;; esac; }
    nvram_id_matches_path() { return 0; }
    leap16_assess_promoted_firmware_order || exit 190
    [[ $LEAP16_ORDER_EXPECTED_STABLE == '0005,0000,0001' ]] || exit 191
    [[ $LEAP16_ORDER_CURRENT_STABLE == '0005,0000,0001' ]] || exit 192
    [[ $LEAP16_ORDER_BBS_MISSING == '0002,0003,0004' ]] || exit 193
    MOCK_LOSE_REAL=1
    ! leap16_assess_promoted_firmware_order || exit 194
    [[ $LEAP16_ORDER_REASON == *'Boot0001 disappeared'* ]] || exit 195
)
promoted_order_rc=$?
case $promoted_order_rc in
    0) pass 'r13 promoted-order gate tolerates ASUS BBS churn but still fails loss of any real pre-existing EFI-file Boot####' ;;
    *) fail_test "r13 promoted-order BBS/real-entry regression failed (rc=$promoted_order_rc)" ;;
esac

# Execute the new automatic armer with a mocked firmware interface. It must set
# only BootNext, persist boot-armed, capture diagnostics, prepare the root resume
# bundle, and never change persistent BootOrder.
(
    set -u
    source "$adapter"
    ok() { :; }
    warn() { :; }
    fail() { return 1; }
    tmp=$(mktemp -d)
    trap 'rm -rf -- "$tmp"' EXIT
    MOCK_NEXT=''
    MOCK_ORDER='0000,0001,0002,0003,0004,0005'
    PREPARED=0
    PROMPTED=0
    PENDING_PHASE=candidate-ready
    PENDING_SOURCE=grub
    PENDING_TARGET=limine
    PENDING_OLD_BOOT_ID=0000
    PENDING_TARGET_BOOT_ID=0005
    BOOTLOADER=grub
    BOOT_CURRENT=0000
    BOOT_NEXT=''
    validate_pending_compatibility() { return 0; }
    detect_bootloader() { BOOTLOADER=grub; BOOT_CURRENT=0000; BOOT_NEXT=$MOCK_NEXT; }
    leap16_require_sudo_session() { return 0; }
    run_validation() { return 0; }
    leap16_validate_pending_firmware_order() { return 0; }
    verify_pending_source_recovery_unchanged() { return 0; }
    verify_pending_candidate_ownership_unchanged() { return 0; }
    validate_pending_target_deep() { return 0; }
    pending_bootnext_id() { printf '%s\n' "$MOCK_NEXT"; }
    leap16_current_boot_order() { printf '%s\n' "$MOCK_ORDER"; }
    pending_set_phase() { PENDING_PHASE=$1; return 0; }
    leap16_capture_required_diagnostic() { mkdir -p "$tmp/$1"; printf '%s\n' "$tmp/$1"; }
    r22_prepare_resume_bundle() { PREPARED=1; return 0; }
    r13_prompt_reboot() { PROMPTED=1; return 0; }
    sudo() {
        if [[ ${1:-} == efibootmgr && ${2:-} == -n && ${3:-} == 0005 ]]; then MOCK_NEXT=0005; return 0; fi
        if [[ ${1:-} == efibootmgr && ${2:-} == -N ]]; then MOCK_NEXT=''; return 0; fi
        return 0
    }
    r13_arm_candidate_automatically >/dev/null || exit 196
    [[ $MOCK_NEXT == 0005 ]] || exit 197
    [[ $MOCK_ORDER == '0000,0001,0002,0003,0004,0005' ]] || exit 198
    [[ $PENDING_PHASE == boot-armed ]] || exit 199
    [[ $PREPARED == 1 && $PROMPTED == 1 ]] || exit 200
    [[ -d $tmp/bootnext-armed ]] || exit 201
)
auto_arm_rc=$?
case $auto_arm_rc in
    0) pass 'r13 automatic armer changes only BootNext, captures the armed checkpoint and prepares root-owned continuation' ;;
    *) fail_test "r13 automatic arming/resume-prep regression failed (rc=$auto_arm_rc)" ;;
esac

# Inspect the final effective overrides rather than historical disabled r12
# definitions still present earlier in the layered adapter.
(
    set -u
    source "$adapter"
    root_fn=$(declare -f r22_resume_transaction_root_pre_r15)
    promote_fn=$(declare -f leap16_promote_runtime_proven_limine_core)
    fresh_fn=$(declare -f execute_grub_to_limine)
    adopt_fn=$(declare -f r13_prepare_resume_for_existing_armed_transaction)
    sync_fn=$(declare -f r13_sync_root_diagnostics_to_user)

    runtime_line=$(grep -n 'validate_pending_target_runtime' <<<"$root_fn" | head -n1 | cut -d: -f1)
    promote_line=$(grep -n 'leap16_promote_runtime_proven_limine_core' <<<"$root_fn" | head -n1 | cut -d: -f1)
    [[ -n $runtime_line && -n $promote_line && $runtime_line -lt $promote_line ]] || exit 202
    grep -Fq 'r22_sync_user_phase_from_root "$conf" runtime-validated' <<<"$root_fn" || exit 203
    grep -Fq 'leap16_promote_runtime_proven_limine_core' <<<"$root_fn" || exit 204
    grep -Fq 'r13_sync_root_diagnostics_to_user' <<<"$root_fn" || exit 205

    grep -Fq 'leap16_verify_grub_recovery_after_promotion' <<<"$promote_fn" || exit 206
    grep -Fq 'r13_restore_source_first_after_failed_promotion' <<<"$promote_fn" || exit 207
    ! grep -Fq 'r23_remove_source_grub_owned_state' <<<"$promote_fn" || exit 208
    ! grep -Eq 'efibootmgr[[:space:]]+-b[[:space:]].*PENDING_OLD_BOOT_ID.*-B' <<<"$promote_fn" || exit 209
    ! grep -Eq 'rm[[:space:]]+-rf.*(/boot/grub2|EFI/opensuse)' <<<"$promote_fn" || exit 210

    grep -Fq 'r13_arm_candidate_automatically' <<<"$fresh_fn" || exit 211
    grep -Fq 'r22_prepare_resume_bundle' <<<"$adopt_fn" || exit 212
    ! grep -Fq 'efibootmgr -n' <<<"$adopt_fn" || exit 213
    grep -Fq 'operation.log' <<<"$sync_fn" || exit 214
    ! grep -Eq 'tar[[:space:]]|\.tar\.gz|gzip' <<<"$sync_fn" || exit 215
)
automation_wiring_rc=$?
case $automation_wiring_rc in
    0)
        pass 'r13 root resume proves exact Limine runtime before promotion and syncs automatic diagnostics back to the user'
        pass 'r13 promotion retains GRUB2/shim/config/fallback recovery and attempts source-first recovery on any post-promotion gate failure'
        pass 'r13 fresh stages auto-arm, while already-armed r12/r13 transactions can be adopted without rewriting BootNext'
        pass 'r13 automatic diagnostics include operation.log and remain folder-only with no auto-created archives'
        ;;
    *) fail_test "r13 automatic-resume/promotion wiring regression failed (rc=$automation_wiring_rc)" ;;
esac

# Execute the final root resume dispatcher in a fully mocked bundle.  The target
# path must record runtime proof before promotion; the source-fallback path must
# never reach promotion at all.
(
    set -u
    source "$adapter"
    tmp=$(mktemp -d)
    trace=$(mktemp)
    trap 'rm -rf -- "$tmp" "$trace"' EXIT
    mkdir -p "$tmp/bundle"
    R22_RESUME_BUNDLE="$tmp/bundle"
    export R22_RESUME_BUNDLE
    r22_root_bundle_preflight() { return 0; }
    load_pending_state() {
        PENDING_SOURCE=grub
        PENDING_TARGET=limine
        PENDING_OLD_BOOT_ID=0000
        PENDING_TARGET_BOOT_ID=0005
        PENDING_PHASE=boot-armed
        PENDING_REASON=''
        PENDING_TRANSACTION_SNAPSHOT_DIR="$tmp/bundle/state/.prestage.fixture"
        PENDING_STATE_FILE="$tmp/bundle/state/pending-migration.tsv"
        mkdir -p "$PENDING_TRANSACTION_SNAPSHOT_DIR"
        : >"$PENDING_STATE_FILE"
        return 0
    }
    validate_pending_compatibility() { return 0; }
    detect_bootloader() { BOOTLOADER=limine; BOOT_CURRENT=0005; }
    validate_pending_target_runtime() { printf 'runtime\n' >>"$trace"; return 0; }
    r22_sync_user_phase_from_root() { printf 'sync-%s\n' "$2" >>"$trace"; return 0; }
    leap16_promote_runtime_proven_limine_core() {
        [[ $PENDING_PHASE == runtime-validated ]] || return 1
        printf 'promote\n' >>"$trace"
        return 0
    }
    leap16_capture_diagnostics() { printf 'diag-%s\n' "$1" >>"$trace"; return 0; }
    r13_sync_root_diagnostics_to_user() { printf 'copy-diag\n' >>"$trace"; return 0; }
    r22_write_user_result() { printf 'result-%s\n' "$2" >>"$trace"; return 0; }
    remove_pending_transaction_snapshot() { printf 'remove-root-snapshot\n' >>"$trace"; return 0; }
    r22_cleanup_user_shadow_after_success() { printf 'cleanup-user-shadow\n' >>"$trace"; return 0; }
    r22_remove_resume_service_files() { printf 'remove-service\n' >>"$trace"; return 0; }
    r22_resume_transaction_root >/dev/null 2>&1 || exit 216
    rline=$(grep -n '^runtime$' "$trace" | cut -d: -f1)
    pline=$(grep -n '^promote$' "$trace" | cut -d: -f1)
    [[ -n $rline && -n $pline && $rline -lt $pline ]] || exit 217
    grep -Fqx 'sync-runtime-validated' "$trace" || exit 218
    grep -Fqx 'result-success' "$trace" || exit 219
)
root_target_exec_rc=$?
case $root_target_exec_rc in
    0) pass 'mocked r13 root service executes runtime proof before promotion and completes the user-result handoff' ;;
    *) fail_test "r13 mocked root target-resume execution failed (rc=$root_target_exec_rc)" ;;
esac

(
    set -u
    source "$adapter"
    tmp=$(mktemp -d)
    trace=$(mktemp)
    trap 'rm -rf -- "$tmp" "$trace"' EXIT
    mkdir -p "$tmp/bundle"
    R22_RESUME_BUNDLE="$tmp/bundle"
    export R22_RESUME_BUNDLE
    r22_root_bundle_preflight() { return 0; }
    load_pending_state() {
        PENDING_SOURCE=grub
        PENDING_TARGET=limine
        PENDING_OLD_BOOT_ID=0000
        PENDING_TARGET_BOOT_ID=0005
        PENDING_PHASE=boot-armed
        PENDING_REASON=''
        return 0
    }
    validate_pending_compatibility() { return 0; }
    detect_bootloader() { BOOTLOADER=grub; BOOT_CURRENT=0000; }
    r22_resume_source_fallback() { printf 'source-fallback\n' >>"$trace"; return 0; }
    leap16_promote_runtime_proven_limine_core() { printf 'BAD-PROMOTE\n' >>"$trace"; return 1; }
    leap16_capture_diagnostics() { return 0; }
    r13_sync_root_diagnostics_to_user() { return 0; }
    r22_resume_transaction_root >/dev/null 2>&1 || exit 220
    grep -Fqx 'source-fallback' "$trace" || exit 221
    ! grep -Fq 'BAD-PROMOTE' "$trace" || exit 222
)
root_source_exec_rc=$?
case $root_source_exec_rc in
    0) pass 'mocked r13 root service treats a firmware return to GRUB2 as safe fallback and never promotes Limine' ;;
    *) fail_test "r13 mocked root source-fallback execution failed (rc=$root_source_exec_rc)" ;;
esac

if grep -Fq 'leap16_execute_limine_to_retained_grub()' "$adapter" \
   && grep -Fq 'r15_retire_proven_limine_source()' "$adapter" \
   && grep -Fq 'Preserved shared openSUSE EFI/BOOT/BOOTX64.EFI fallback byte-for-byte' "$adapter" \
   && grep -Fq 'systemd-boot and rEFInd writes remain disabled' "$main"; then
    pass 'r15 adds ownership-gated Limine -> GRUB2 finalization while preserving the openSUSE shim fallback; other backends remain locked'
else
    fail_test 'r15 reverse-finalization safety boundary is not documented/wired consistently'
fi


# r15 reverse-path contract: native openSUSE GRUB2/shim is adopted as a
# pre-existing target; no grub reinstall/target namespace creation is allowed.
(
    set -u
    source "$adapter"
    [[ $(target_expected_efi_path grub) == '\EFI\OPENSUSE\SHIM.EFI' ]] || exit 230
    operation_supported limine grub || exit 231
    operation_supported grub limine || exit 232
    ! operation_supported limine refind || exit 233
    ! operation_supported limine systemd-boot || exit 234
    reverse_fn=$(declare -f leap16_execute_limine_to_retained_grub)
    ! grep -Eq 'grub2-install|grub-install|zypper.*grub' <<<"$reverse_fn" || exit 235
    grep -Fq 'leap16_snapshot_retained_grub_target' <<<"$reverse_fn" || exit 236
    grep -Fq 'set_source_first_boot_order "$old_id" "$target_id" "$original_order"' <<<"$reverse_fn" || exit 237
)
reverse_contract_rc=$?
case $reverse_contract_rc in
    0) pass 'r15 reverse backend adopts the retained native openSUSE shim/GRUB2 target without reinstalling GRUB and keeps source-first/target-last candidate semantics' ;;
    *) fail_test "r15 retained-GRUB2 reverse contract failed (rc=$reverse_contract_rc)" ;;
esac

# The reverse format-4 path validator must accept Leap-native /boot/grub2 +
# EFI/opensuse ownership with grub_default_created=0, rather than CachyOS paths
# or transaction-created GRUB policy.
(
    set -u
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/storage.sh"
    source "$ROOT/lib/detect.sh"
    source "$ROOT/lib/kernels.sh"
    source "$ROOT/lib/validate.sh"
    source "$ROOT/lib/limine_validate.sh"
    source "$ROOT/lib/grub_validate.sh"
    source "$ROOT/lib/operations.sh"
    source "$ROOT/lib/staged.sh"
    source "$ROOT/lib/r21.sh"
    source "$ROOT/lib/r22.sh"
    source "$ROOT/lib/r23.sh"
    source "$ROOT/lib/restore.sh"
    for n in {25..47}; do [[ -f $ROOT/lib/r$n.sh ]] && source "$ROOT/lib/r$n.sh"; done
    source "$adapter"
    t=$(mktemp -d); trap 'rm -rf -- "$t"' EXIT
    ESP_MOUNT="$t/esp"; PENDING_STATE_DIR="$t/state"; snap="$PENDING_STATE_DIR/.prestage.fixture"
    mkdir -p "$ESP_MOUNT/EFI/OPENSUSE" "$ESP_MOUNT/EFI/LIMINE" "$snap"
    mid=$(cat /etc/machine-id); mkdir -p "$ESP_MOUNT/$mid"
    for f in grub-artifacts.tsv grub-dir.tsv grub-efi-dir.tsv source-limine-efi-dir.tsv source-limine-managed-dir.tsv; do printf 'fixture\n' >"$snap/$f"; done
    h=$(printf '%064d' 0)
    PENDING_FORMAT=4; PENDING_SOURCE=limine; PENDING_TARGET=grub; PENDING_GRUB_DEFAULT_CREATED=0
    PENDING_TRANSACTION_SNAPSHOT_DIR="$snap"
    PENDING_TARGET_EFI_RESOLVED="$ESP_MOUNT/EFI/OPENSUSE/SHIM.EFI"; PENDING_TARGET_EFI_HASH=$h
    PENDING_OLD_BOOT_EFI_PATH='\EFI\LIMINE\LIMINE_X64.EFI'
    PENDING_SOURCE_LIMINE_EFI_RESOLVED="$ESP_MOUNT/EFI/LIMINE/LIMINE_X64.EFI"; PENDING_SOURCE_LIMINE_EFI_HASH=$h
    PENDING_SOURCE_LIMINE_CONF_PATH="$ESP_MOUNT/limine.conf"; PENDING_SOURCE_LIMINE_CONF_HASH=$h
    PENDING_SOURCE_LIMINE_DEFAULT_HASH=$h; PENDING_SOURCE_LIMINE_MANAGED_DIR="$ESP_MOUNT/$mid"; PENDING_SOURCE_LIMINE_MANAGED_HASH=$h
    PENDING_GRUB_CFG_PATH=/boot/grub2/grub.cfg; PENDING_GRUB_CFG_HASH=$h; PENDING_GRUB_DIR=/boot/grub2; PENDING_GRUB_DEFAULT_HASH=$h
    PENDING_GRUB_ARTIFACT_MANIFEST="$snap/grub-artifacts.tsv"; PENDING_GRUB_DIR_MANIFEST="$snap/grub-dir.tsv"
    PENDING_GRUB_EFI_DIR="$ESP_MOUNT/EFI/OPENSUSE"; PENDING_GRUB_EFI_DIR_MANIFEST="$snap/grub-efi-dir.tsv"
    PENDING_OLD_FALLBACK_PATH="$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"; PENDING_OLD_FALLBACK_HASH=''; PENDING_POST_STAGE_FALLBACK_HASH=''; PENDING_OLD_FALLBACK_EXISTED=0; PENDING_OLD_FALLBACK_SNAPSHOT=''
    pending_validate_snapshot_dir() { return 0; }
    pending_validate_fallback_metadata() { return 0; }
    validate_pending_owned_paths || exit 238
    PENDING_GRUB_DEFAULT_CREATED=1
    ! validate_pending_owned_paths || exit 239
)
reverse_paths_rc=$?
case $reverse_paths_rc in
    0) pass 'r15 reverse pending-state validation accepts only retained Leap /boot/grub2 + EFI/opensuse ownership and rejects transaction-created GRUB policy' ;;
    *) fail_test "r15 reverse ownership-path fixture failed (rc=$reverse_paths_rc)" ;;
esac

# Promotion/finalization order is safety-critical: persistent GRUB2 promotion
# and post-promotion source proof must happen before any Limine retirement.
(
    set -u
    source "$adapter"
    trace=$(mktemp); trap 'rm -f -- "$trace"' EXIT
    PENDING_FORMAT=4; PENDING_SOURCE=limine; PENDING_TARGET=grub; PENDING_GRUB_DEFAULT_CREATED=0
    PENDING_PHASE=runtime-validated; PENDING_OLD_BOOT_ID=0005; PENDING_TARGET_BOOT_ID=0000
    PENDING_TARGET_EFI_PATH='\EFI\OPENSUSE\SHIM.EFI'; BOOTLOADER=grub; BOOT_CURRENT=0000
    validate_pending_compatibility(){ return 0; }; leap16_reverse_pending(){ return 0; }
    detect_bootloader(){ BOOTLOADER=grub; BOOT_CURRENT=0000; }; pending_bootnext_id(){ :; }
    verify_pending_candidate_ownership_unchanged(){ printf 'candidate\n' >>"$trace"; }
    validate_pending_target_deep(){ printf 'targetdeep\n' >>"$trace"; }
    verify_pending_source_recovery_unchanged(){ printf 'sourcepre\n' >>"$trace"; }
    leap16_validate_pending_firmware_order(){ printf 'orderpre\n' >>"$trace"; }
    r13_promoted_order_from_current(){ printf '0000,0005,0001\n'; }
    sudo(){ [[ ${1:-} == efibootmgr && ${2:-} == -o ]] && printf 'promote:%s\n' "$3" >>"$trace"; return 0; }
    leap16_validate_promoted_firmware_order(){ printf 'orderpost\n' >>"$trace"; }
    validate_grub_boot_chain(){ printf 'grubdeep\n' >>"$trace"; }
    leap16_verify_source_limine_after_promotion(){ printf 'sourcepost\n' >>"$trace"; }
    leap16_stage_diagnostic(){ printf 'diag:%s\n' "$1" >>"$trace"; }
    r15_retire_proven_limine_source(){ printf 'retire\n' >>"$trace"; }
    validate_cachyos_grub_theme(){ :; }; validate_target_state(){ :; }
    r15_promote_and_finalize_grub >/dev/null || exit 240
    pl=$(grep -n '^promote:' "$trace"|cut -d: -f1); sl=$(grep -n '^sourcepost$' "$trace"|cut -d: -f1); rl=$(grep -n '^retire$' "$trace"|cut -d: -f1)
    [[ -n $pl && -n $sl && -n $rl && $pl -lt $sl && $sl -lt $rl ]] || exit 241
)
reverse_finalize_rc=$?
case $reverse_finalize_rc in
    0) pass 'r15 reverse finalizer promotes GRUB2, re-proves exact Limine ownership, and only then retires Limine' ;;
    *) fail_test "r15 reverse finalization ordering fixture failed (rc=$reverse_finalize_rc)" ;;
esac

# A failed promoted-order gate must recover toward Limine-first and must never
# reach source retirement.
(
    set -u
    source "$adapter"
    trace=$(mktemp); trap 'rm -f -- "$trace"' EXIT
    PENDING_FORMAT=4; PENDING_SOURCE=limine; PENDING_TARGET=grub; PENDING_GRUB_DEFAULT_CREATED=0
    PENDING_PHASE=runtime-validated; PENDING_OLD_BOOT_ID=0005; PENDING_TARGET_BOOT_ID=0000
    PENDING_TARGET_EFI_PATH='\EFI\OPENSUSE\SHIM.EFI'; BOOTLOADER=grub; BOOT_CURRENT=0000
    validate_pending_compatibility(){ return 0; }; leap16_reverse_pending(){ return 0; }
    detect_bootloader(){ BOOTLOADER=grub; BOOT_CURRENT=0000; }; pending_bootnext_id(){ :; }
    verify_pending_candidate_ownership_unchanged(){ :; }; validate_pending_target_deep(){ :; }; verify_pending_source_recovery_unchanged(){ :; }
    leap16_validate_pending_firmware_order(){ :; }; r13_promoted_order_from_current(){ printf '0000,0005,0001\n'; }
    sudo(){ return 0; }; leap16_validate_promoted_firmware_order(){ return 1; }
    r15_recover_source_first_after_failed_reverse_promotion(){ printf 'recover\n' >>"$trace"; return 0; }
    r15_retire_proven_limine_source(){ printf 'BAD-retire\n' >>"$trace"; return 0; }
    r15_promote_and_finalize_grub >/dev/null 2>&1 && exit 242
    grep -Fqx 'recover' "$trace" || exit 243
    ! grep -Fq 'BAD-retire' "$trace" || exit 244
)
reverse_fail_rc=$?
case $reverse_fail_rc in
    0) pass 'r15 reverse promotion failure restores source-first intent and cannot reach Limine retirement' ;;
    *) fail_test "r15 reverse promotion-failure fixture failed (rc=$reverse_fail_rc)" ;;
esac

# Root-owned resume dispatcher must route a copied Limine -> GRUB2 transaction
# into the r15 reverse continuation while preserving r13 forward dispatch.
(
    set -u
    source "$adapter"
    t=$(mktemp -d); trap 'rm -rf -- "$t"' EXIT
    PENDING_STATE_FILE="$t/pending-migration.tsv"
    printf 'source\tlimine\ntarget\tgrub\n' >"$PENDING_STATE_FILE"
    r15_resume_reverse_root(){ printf 'reverse\n'; }
    r22_resume_transaction_root_pre_r15(){ printf 'forward\n'; }
    [[ $(r22_resume_transaction_root) == reverse ]] || exit 245
    printf 'source\tgrub\ntarget\tlimine\n' >"$PENDING_STATE_FILE"
    [[ $(r22_resume_transaction_root) == forward ]] || exit 246
)
reverse_dispatch_rc=$?
case $reverse_dispatch_rc in
    0) pass 'r15 root-owned resume dispatcher handles both Limine -> GRUB2 and preserved GRUB2 -> Limine automation' ;;
    *) fail_test "r15 two-way root-resume dispatch fixture failed (rc=$reverse_dispatch_rc)" ;;
esac

if grep -Fq 'R22_SYSTEM_ROOT=/var/lib/opensuse-bootloader-switcher/r15' "$adapter" \
   && grep -Fq 'r15_strict_resume_bundle_ready()' "$adapter" \
   && grep -Fq 'ExecStart=/usr/bin/bash $bundle/tool/bootloader-switcher.sh --resume-transaction-root' "$adapter" \
   && grep -Fq 'Automatic reverse resume did not pass its own pre-reboot installation proof; refusing reboot' "$adapter"; then
    pass 'r15 refuses reverse reboot unless the root-owned bundle, pending copy, enabled unit and exact ExecStart are all proven installed'
else
    fail_test 'r15 strict reverse pre-reboot automation proof is incomplete'
fi

# r16 hardware hotfix: reverse GRUB target validation must use the existing
# ESP identity helper and must not reference the typo-level undefined symbol
# that escaped the r15 contract-only fixtures.
if grep -Fq 'leap16_nvram_entry_matches_current_esp "$target_id"' "$adapter" \
   && ! grep -Fq 'leap16_boot_entry_on_current_esp' "$adapter"; then
    pass 'r16 reverse retained-GRUB2 validation uses the proven ESP identity helper and contains no undefined helper reference'
else
    fail_test 'r16 retained-GRUB2 ESP identity hotfix is missing or the undefined r15 helper reference survived'
fi

# r17 hardware hotfix: reverse staging must use the already-defined firmware
# baseline snapshot helper. r15 introduced an undefined near-name that only
# executes after the destructive boundary confirmation on real hardware.
if grep -Fq 'leap16_snapshot_firmware_baseline || { r15_abandon_uncommitted_reverse_candidate "$original_order" firmware-baseline-snapshot-failed; return 1; }' "$adapter" \
   && ! grep -Fq 'leap16_capture_prestage_firmware_baseline' "$adapter"; then
    pass 'r17 reverse staging uses the defined firmware-baseline snapshot helper and contains no undefined near-name'
else
    fail_test 'r17 firmware-baseline hotfix is missing or the undefined r15 near-name survived'
fi


# r18 is diagnostic-only: before reverse cleanup deletes .prestage.*, the
# timestamped diagnostic must preserve the exact expected manifests, regenerate
# live manifests with the same format, and name the first mismatch.
if grep -Fq 'leap16_capture_reverse_ownership_evidence "$out"' "$adapter" \
   && grep -Fq 'ownership-manifest-diff.txt' "$adapter" \
   && grep -Fq 'ownership-first-mismatch.txt' "$adapter" \
   && grep -Fq 'source-limine-managed-dir.tsv' "$adapter"; then
    pass 'r18 wires reverse ownership evidence capture into diagnostics before cleanup'
else
    fail_test 'r18 reverse ownership evidence capture is not wired into the timestamped diagnostic path'
fi

(
    set -u
    source "$adapter"
    t=$(mktemp -d); trap 'rm -rf -- "$t"' EXIT
    snap="$t/.prestage.TEST"; out="$t/diag"
    grub="$t/boot/grub2"; efi="$t/esp/EFI/OPENSUSE"; theme="$grub/themes/openSUSE"
    limine_efi="$t/esp/EFI/LIMINE"; managed="$t/esp/machine"
    mkdir -p "$snap" "$out" "$theme" "$efi" "$limine_efi" "$managed"
    printf 'stable\n' >"$grub/grub.cfg"
    printf 'before\n' >"$grub/grubenv"
    printf 'shim\n' >"$efi/SHIM.EFI"
    printf 'theme\n' >"$theme/theme.txt"
    printf 'limine\n' >"$limine_efi/LIMINE_X64.EFI"
    printf 'kernel\n' >"$managed/vmlinuz-test"
    printf 'initrd\n' >"$managed/initrd-test"
    printf 'kernel-source\n' >"$t/vmlinuz-test"

    # Avoid requiring sudo inside the isolated fixture while preserving the
    # exact r47 tree-manifest line format.
    write_privileged_tree_manifest() {
        local root=$1 dest=$2 path type identity target
        : >"$dest"
        while IFS= read -r -d '' path; do
            if [[ -L $path ]]; then type=l; target=$(readlink -- "$path"); identity=$(printf '%s' "$target" | sha256sum | awk '{print $1}')
            elif [[ -f $path ]]; then type=f; identity=$(sha256sum -- "$path" | awk '{print $1}')
            elif [[ -d $path ]]; then type=d; identity='-'
            else return 1
            fi
            printf '%s\t%s\t%s\n' "$type" "$identity" "$path" >>"$dest"
        done < <(find "$root" -mindepth 1 -print0 | LC_ALL=C sort -z)
        LC_ALL=C sort -o "$dest" "$dest"
    }

    write_privileged_tree_manifest "$grub" "$snap/grub-dir.tsv"
    write_privileged_tree_manifest "$efi" "$snap/grub-efi-dir.tsv"
    write_privileged_tree_manifest "$theme" "$snap/grub-theme-dir.tsv"
    write_privileged_tree_manifest "$limine_efi" "$snap/source-limine-efi-dir.tsv"
    write_privileged_tree_manifest "$managed" "$snap/source-limine-managed-dir.tsv"
    printf 'shared\t%s\t%s\n' "$(sha256sum "$t/vmlinuz-test" | awk '{print $1}')" "$t/vmlinuz-test" >"$snap/grub-artifacts.tsv"

    TRANSACTION_SNAPSHOT_DIR=$snap
    PENDING_TRANSACTION_SNAPSHOT_DIR=''
    PENDING_STATE_FILE="$t/no-pending"
    PENDING_SOURCE=limine; PENDING_TARGET=grub
    PENDING_GRUB_DIR=$grub; TARGET_GRUB_DIR=$grub
    PENDING_GRUB_EFI_DIR=$efi; TARGET_GRUB_EFI_DIR=$efi
    R21_GRUB_THEME_DIR=$theme
    PENDING_SOURCE_LIMINE_EFI_RESOLVED="$limine_efi/LIMINE_X64.EFI"
    SOURCE_LIMINE_EFI_RESOLVED="$limine_efi/LIMINE_X64.EFI"
    PENDING_SOURCE_LIMINE_MANAGED_DIR=$managed; SOURCE_LIMINE_MANAGED_DIR=$managed

    # Mutate one runtime-state file after the expected snapshot. The diagnostic
    # must preserve the old manifest and identify this exact object as changed.
    printf 'after\n' >"$grub/grubenv"
    leap16_capture_reverse_ownership_evidence "$out"

    [[ -s $out/grub-dir.tsv ]] || exit 247
    [[ -s $out/actual-grub-dir.tsv ]] || exit 248
    [[ -s $out/grub-dir.diff ]] || exit 249
    [[ -s $out/ownership-manifest-diff.txt ]] || exit 250
    grep -Fqx 'manifest=grub-dir' "$out/ownership-first-mismatch.txt" || exit 251
    grep -Fqx 'reason=changed' "$out/ownership-first-mismatch.txt" || exit 252
    grep -Fqx "path=$grub/grubenv" "$out/ownership-first-mismatch.txt" || exit 253
)
r18_diag_rc=$?
case $r18_diag_rc in
    0) pass 'r18 reverse ownership diagnostic preserves manifests and reports the exact first changed object' ;;
    *) fail_test "r18 reverse ownership diagnostic fixture failed (rc=$r18_diag_rc)" ;;
esac


# r19 hardware fix: a retained openSUSE kernel path may be a logical /boot
# symlink whose real target lives in /usr/lib/modules.  That is valid shared
# distro state and must be content-proven without weakening logical /boot path
# confinement or allowing transaction-created artifacts.
(
    set -u
    source "$adapter"
    t=$(mktemp -d); trap 'rm -rf -- "$t"' EXIT
    logical_boot="$t/boot"; modules="$t/usr/lib/modules/TEST"; manifest="$t/grub-artifacts.tsv"
    mkdir -p "$logical_boot" "$modules"
    printf 'kernel-bytes\n' >"$modules/vmlinuz"
    ln -s ../usr/lib/modules/TEST/vmlinuz "$logical_boot/vmlinuz-TEST"
    hash=$(sha256sum -- "$logical_boot/vmlinuz-TEST" | awk '{print $1}')
    printf 'shared\t%s\t%s\n' "$hash" "$logical_boot/vmlinuz-TEST" >"$manifest"

    # Minimal inherited hash predicate for this isolated adapter fixture.
    pending_hash_is_sha256(){ [[ ${1:-} =~ ^[0-9A-Fa-f]{64}$ ]]; }
    ok(){ :; }; fail(){ :; }

    resolved=$(realpath -- "$logical_boot/vmlinuz-TEST")
    [[ $resolved == "$modules/vmlinuz" ]] || exit 254
    leap16_path_lexically_under "$logical_boot/vmlinuz-TEST" "$logical_boot" || exit 255
    leap16_verify_retained_grub_artifact_manifest "$manifest" "$logical_boot" || exit 256

    printf 'evil\n' >"$t/outside"
    badhash=$(sha256sum -- "$t/outside" | awk '{print $1}')
    printf 'shared\t%s\t%s\n' "$badhash" "$t/outside" >"$manifest"
    ! leap16_verify_retained_grub_artifact_manifest "$manifest" "$logical_boot" || exit 257
)
r19_symlink_rc=$?
case $r19_symlink_rc in
    0) pass 'r19 accepts hash-stable distro-owned /boot kernel symlinks while still rejecting logical paths outside /boot' ;;
    *) fail_test "r19 retained-GRUB2 shared-artifact symlink fixture failed (rc=$r19_symlink_rc)" ;;
esac

if grep -Fq 'leap16_verify_reverse_candidate_ownership()' "$adapter" \
   && grep -Fq 'leap16_verify_retained_grub_artifact_manifest "$PENDING_GRUB_ARTIFACT_MANIFEST" /boot' "$adapter" \
   && grep -Fq 'verify_pending_candidate_ownership_unchanged_pre_r19' "$adapter"; then
    pass 'r19 overrides only the Leap adopted Limine -> GRUB2 candidate ownership gate and preserves inherited verification elsewhere'
else
    fail_test 'r19 direction-selective retained-GRUB2 ownership override is incomplete'
fi

# r20 is diagnostic-only.  The hardware-proven r19 reverse success archive
# showed three stale post-retirement diagnostics: finalization-pass expected
# source-first candidate order, auto-resume-pass still required the retired
# source Boot####, and ownership evidence called removed source trees a mismatch.
(
    set -u
    source "$adapter"
    t=$(mktemp -d); trap 'rm -rf -- "$t"' EXIT
    baseline="$t/baseline.txt"; current="$t/current.txt"; report="$t/report.txt"; TEST_R20_BASELINE=$baseline
    cat >"$baseline" <<'EOF_BASE'
Boot0005* EFI:\EFI\LIMINE\LIMINE_X64.EFI
Boot0000* EFI:\EFI\OPENSUSE\SHIM.EFI
Boot0001* EFI:\EFI\OPENSUSE\GRUBX64.EFI
Boot0002* BBS:CD
Boot0003* BBS:REMOVABLE
Boot0004* BBS:NETWORK
EOF_BASE

    PENDING_SOURCE=limine; PENDING_TARGET=grub
    PENDING_OLD_BOOT_ID=0005; PENDING_TARGET_BOOT_ID=0000
    PENDING_ORIGINAL_BOOT_ORDER=0005,0000,0001,0002,0003,0004
    PENDING_TARGET_EFI_PATH='\EFI\OPENSUSE\SHIM.EFI'
    PENDING_OLD_BOOT_EFI_PATH='\EFI\LIMINE\LIMINE_X64.EFI'
    SOURCE_EXISTS=1
    leap16_pending_firmware_baseline_path(){ printf '%s\n' "$TEST_R20_BASELINE"; }
    efibootmgr(){ cat "$current"; }
    leap16_line_for_id_in_dump(){ local dump=$1 id=${2^^}; grep -m1 "^Boot${id}\*" <<<"$dump"; }
    leap16_line_is_bbs(){ [[ $1 == *'BBS:'* ]]; }
    efi_path_from_efibootmgr_line(){ sed -n 's/^Boot[0-9A-Fa-f]\{4\}\* EFI://p' <<<"$1"; }
    normalize_efi_path(){ printf '%s\n' "${1//\\//}"; }
    leap16_boot_entry_is_active(){ [[ ${1^^} == 0000 || ( ${1^^} == 0005 && $SOURCE_EXISTS == 1 ) ]]; }
    nvram_id_matches_path(){ return 0; }
    leap16_nvram_entry_matches_current_esp(){ [[ ${1^^} == 0000 ]]; }
    boot_id_exists(){ [[ ${1^^} == 0005 && $SOURCE_EXISTS == 1 ]]; }

    cat >"$current" <<'EOF_PROMOTED'
BootCurrent: 0000
BootOrder: 0000,0005,0001
Boot0000* EFI:\EFI\OPENSUSE\SHIM.EFI
Boot0005* EFI:\EFI\LIMINE\LIMINE_X64.EFI
Boot0001* EFI:\EFI\OPENSUSE\GRUBX64.EFI
EOF_PROMOTED
    leap16_write_firmware_order_report "$report" promotion-pass
    grep -Fqx 'assessment=pass' "$report" || exit 258
    grep -Fqx 'stable_expected_boot_order=0000,0005,0001' "$report" || exit 259
    grep -Fqx 'reason=runtime-proven native GRUB2 target is first; Limine source recovery and other real EFI entries remain exact' "$report" || exit 260

    SOURCE_EXISTS=0
    cat >"$current" <<'EOF_FINAL'
BootCurrent: 0000
BootOrder: 0000,0001
Boot0000* EFI:\EFI\OPENSUSE\SHIM.EFI
Boot0001* EFI:\EFI\OPENSUSE\GRUBX64.EFI
EOF_FINAL
    leap16_write_firmware_order_report "$report" finalization-pass
    grep -Fqx 'assessment=pass' "$report" || exit 261
    grep -Fqx 'stable_expected_boot_order=0000,0001' "$report" || exit 262
    grep -Fqx 'stable_current_boot_order=0000,0001' "$report" || exit 263
    grep -Fqx 'reason=native openSUSE GRUB2 target is first; retired Limine source is absent; other real EFI entries remain exact' "$report" || exit 264

    leap16_write_firmware_order_report "$report" auto-resume-pass
    grep -Fqx 'assessment=pass' "$report" || exit 265
    grep -Fqx 'stable_expected_boot_order=0000,0001' "$report" || exit 266

    SOURCE_EXISTS=1
    leap16_write_firmware_order_report "$report" finalization-pass
    grep -Fqx 'assessment=fail' "$report" || exit 267
    grep -Fqx 'reason=retired source Limine Boot0005 still exists after reverse finalization' "$report" || exit 268
)
r20_order_rc=$?
case $r20_order_rc in
    0) pass 'r20 reverse success firmware diagnostics distinguish promotion from post-retirement topology and require retired Limine Boot#### absence' ;;
    *) fail_test "r20 reverse phase-aware firmware diagnostic fixture failed (rc=$r20_order_rc)" ;;
esac

(
    set -u
    source "$adapter"
    t=$(mktemp -d); trap 'rm -rf -- "$t"' EXIT
    snap="$t/.prestage.TEST"; out="$t/finalized"; out_bad="$t/bad"
    source_efi="$t/esp/EFI/LIMINE/LIMINE_X64.EFI"; managed="$t/esp/machine"
    mkdir -p "$snap" "$out" "$out_bad"
    printf 'f\tdeadbeef\t%s\n' "$source_efi" >"$snap/source-limine-efi-dir.tsv"
    printf 'f\tdeadbeef\t%s\n' "$managed/vmlinuz-test" >"$snap/source-limine-managed-dir.tsv"

    TRANSACTION_SNAPSHOT_DIR=$snap
    PENDING_TRANSACTION_SNAPSHOT_DIR=''
    PENDING_SOURCE=limine; PENDING_TARGET=grub
    PENDING_SOURCE_LIMINE_EFI_RESOLVED=$source_efi
    PENDING_SOURCE_LIMINE_MANAGED_DIR=$managed

    leap16_capture_reverse_ownership_evidence "$out" finalization-pass
    grep -Fqx 'reason=retired-as-expected' "$out/source-limine-efi-dir.first-mismatch.txt" || exit 269
    grep -Fqx 'reason=retired-as-expected' "$out/source-limine-managed-dir.first-mismatch.txt" || exit 270
    grep -Fqx 'reason=none' "$out/ownership-first-mismatch.txt" || exit 271

    mkdir -p "$(dirname -- "$source_efi")" "$managed"
    printf 'still-here\n' >"$source_efi"
    printf 'still-here\n' >"$managed/vmlinuz-test"
    leap16_capture_reverse_ownership_evidence "$out_bad" auto-resume-pass
    grep -Fqx 'reason=unexpectedly-present-after-retirement' "$out_bad/source-limine-efi-dir.first-mismatch.txt" || exit 272
    grep -Fqx 'manifest=source-limine-efi-dir' "$out_bad/ownership-first-mismatch.txt" || exit 273
)
r20_ownership_rc=$?
case $r20_ownership_rc in
    0) pass 'r20 post-retirement ownership diagnostics treat absent Limine source trees as expected and still flag an unexpectedly surviving source' ;;
    *) fail_test "r20 reverse post-retirement ownership diagnostic fixture failed (rc=$r20_ownership_rc)" ;;
esac

if grep -Fq 'leap16_assess_reverse_finalized_firmware_order()' "$adapter" \
   && grep -Fq 'finalization-pass|auto-resume-pass' "$adapter" \
   && grep -Fq 'reason=retired-as-expected' "$adapter"; then
    pass 'r20 phase-aware diagnostic layer is present without changing the r19 transaction mutation path'
else
    fail_test 'r20 phase-aware reverse diagnostic layer is incomplete'
fi

# r21 completes the forward path: canonical Limine proof first, genuine generic
# fallback proof second, and only then native openSUSE GRUB2 retirement.
(
    set -u
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/storage.sh"
    source "$ROOT/lib/detect.sh"
    source "$ROOT/lib/kernels.sh"
    source "$ROOT/lib/validate.sh"
    source "$ROOT/lib/limine_validate.sh"
    source "$ROOT/lib/grub_validate.sh"
    source "$ROOT/lib/operations.sh"
    source "$ROOT/lib/staged.sh"
    source "$ROOT/lib/r21.sh"
    source "$ROOT/lib/r22.sh"
    source "$ROOT/lib/r23.sh"
    source "$ROOT/lib/r42.sh"
    source "$adapter"
    source "$r21layer"

    t=$(mktemp -d); trap 'rm -rf -- "$t"' EXIT
    ESP_MOUNT="$t/esp"; mkdir -p "$ESP_MOUNT/EFI/LIMINE" "$ESP_MOUNT/EFI/BOOT" "$ESP_MOUNT/EFI/OPENSUSE"
    printf 'limine-bytes\n' >"$ESP_MOUNT/EFI/LIMINE/LIMINE_X64.EFI"
    printf 'shim-bytes\n' >"$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"
    printf 'shim-bytes\n' >"$ESP_MOUNT/EFI/OPENSUSE/SHIM.EFI"

    cat >"$t/pre.conf" <<'EOF_PRE'
/EFI fallback
### Shared recovery entry
comment: Preserved openSUSE generic fallback / GRUB2 recovery path
protocol: efi
path: boot():/EFI/BOOT/BOOTX64.EFI
EOF_PRE
    leap16_validate_limine_recovery_contract "$t/pre.conf" || exit 274

    cp "$ESP_MOUNT/EFI/LIMINE/LIMINE_X64.EFI" "$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"
    cat >"$t/transfer.conf" <<'EOF_TRANSFER'
/openSUSE GRUB2 recovery
### Temporary direct recovery path retained until Limine fallback proof completes
comment: Native openSUSE shim/GRUB2 recovery path
protocol: efi
path: boot():/EFI/OPENSUSE/SHIM.EFI
EOF_TRANSFER
    leap16_validate_limine_recovery_contract "$t/transfer.conf" || exit 275

    rm -rf "$ESP_MOUNT/EFI/OPENSUSE"
    : >"$t/final.conf"
    leap16_validate_limine_recovery_contract "$t/final.conf" || exit 276
    printf 'drift\n' >"$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"
    ! leap16_validate_limine_recovery_contract "$t/final.conf" || exit 277
)
r21_recovery_rc=$?
case $r21_recovery_rc in
    0) pass 'r21 Limine deep-validation contract accepts only pre-transfer shim, transferred Limine+direct-GRUB recovery, and finalized Limine-fallback states' ;;
    *) fail_test "r21 recovery topology fixture failed (rc=$r21_recovery_rc)" ;;
esac

(
    set -u
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/storage.sh"
    source "$ROOT/lib/detect.sh"
    source "$ROOT/lib/kernels.sh"
    source "$ROOT/lib/validate.sh"
    source "$ROOT/lib/limine_validate.sh"
    source "$ROOT/lib/grub_validate.sh"
    source "$ROOT/lib/operations.sh"
    source "$ROOT/lib/staged.sh"
    source "$ROOT/lib/r21.sh"
    source "$ROOT/lib/r22.sh"
    source "$ROOT/lib/r23.sh"
    source "$ROOT/lib/r42.sh"
    source "$adapter"
    source "$r21layer"
    t=$(mktemp -d); trap 'rm -rf -- "$t"' EXIT
    PENDING_TRANSACTION_SNAPSHOT_DIR="$t/.prestage.TEST"; mkdir -p "$PENDING_TRANSACTION_SNAPSHOT_DIR"
    PENDING_ESP_SOURCE=/dev/sda1; PENDING_OLD_BOOT_ID=0000
    cat >"$PENDING_TRANSACTION_SNAPSHOT_DIR/prestage-efibootmgr-v.txt" <<'EOF_BASE'
BootCurrent: 0000
BootOrder: 0000,0001,0005
Boot0000* opensuse-secureboot HD(1,GPT,11111111-2222-3333-4444-555555555555,0x800,0x100000)/File(\EFI\OPENSUSE\SHIM.EFI)
Boot0001* opensuse HD(1,GPT,11111111-2222-3333-4444-555555555555,0x800,0x100000)/File(\EFI\OPENSUSE\GRUBX64.EFI)
Boot0005* Other HD(1,GPT,11111111-2222-3333-4444-555555555555,0x800,0x100000)/File(\EFI\OTHER\BOOT.EFI)
EOF_BASE
    leap16_pending_firmware_baseline_path(){ printf '%s\n' "$PENDING_TRANSACTION_SNAPSHOT_DIR/prestage-efibootmgr-v.txt"; }
    lsblk(){ [[ "$*" == *PARTUUID* ]] && printf '%s\n' 11111111-2222-3333-4444-555555555555; }
    [[ $(r21_source_grub_ids_csv) == '0000,0001' ]] || exit 278

    # Status output must never contaminate a Boot#### value returned through
    # command substitution. This guards the bug caught during r21 review.
    r21_fallback_ids_now(){ printf '0007\n'; }
    leap16_boot_entry_is_active(){ return 0; }
    leap16_nvram_entry_matches_current_esp(){ return 0; }
    ok(){ printf 'STATUS-LINE\n'; }
    got=$(r21_create_or_adopt_fallback_alias 2>/dev/null) || exit 279
    [[ $got == 0007 ]] || exit 280
)
r21_ids_rc=$?
case $r21_ids_rc in
    0) pass 'r21 derives both native openSUSE GRUB2 aliases from the pre-stage baseline and returns a clean fallback Boot#### value' ;;
    *) fail_test "r21 firmware ownership/value fixture failed (rc=$r21_ids_rc)" ;;
esac

# Static sequencing guard: fallback runtime proof must precede source deletion.
if grep -Fq 'r21_validate_fallback_runtime || return 1' "$r21layer" \
   && grep -Fq 'r21_remove_source_grub_nvram_ids "$source_ids" || return 1' "$r21layer" \
   && grep -Fq 'r21_remove_source_grub_files || return 1' "$r21layer" \
   && grep -Fq 'sudo efibootmgr -n "$fallback_id"' "$r21layer" \
   && grep -Fq 'EFI/BOOT/BOOTX64.EFI' "$r21layer" \
   && awk '/^r21_retire_grub_after_fallback_proof\(\)/{infn=1} infn && /r21_validate_fallback_runtime \|\| return 1/{proof=NR} infn && /r21_remove_source_grub_nvram_ids/{del=NR} infn && /^}/{if(infn){exit}} END{exit !(proof && del && proof<del)}' "$r21layer"; then
    pass 'r21 statically gates every forward GRUB2 retirement behind the exact second-boot Limine fallback runtime proof'
else
    fail_test 'r21 fallback-proof-before-retirement sequencing guard failed'
fi
printf '\n'
if ((failures == 0)); then
    printf 'All openSUSE Leap 16 r21 port self-tests passed.\n'
    exit 0
fi
printf '%d port self-test(s) failed.\n' "$failures" >&2
exit 1
