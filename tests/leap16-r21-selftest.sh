#!/usr/bin/env bash
set -u

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 1

failures=0
pass() { printf '[PASS] %s\n' "$*"; }
fail_test() { printf '[FAIL] %s\n' "$*" >&2; failures=$((failures + 1)); }

printf 'openSUSE Leap 16 r21 focused self-test\n'
printf '======================================\n\n'

if find . -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n; then
    pass 'all shell files parse'
else
    fail_test 'one or more shell files fail bash -n'
fi

if grep -Eq 'SWITCHER_RELEASE="leap16-r(2[5-9]|[3-9][0-9])"' bootloader-switcher.sh \
   && awk '/source "\$SCRIPT_DIR\/lib\/opensuse_leap16.sh"/{a=NR} /source "\$SCRIPT_DIR\/lib\/leap16_r21.sh"/{b=NR} /source "\$SCRIPT_DIR\/lib\/leap16_r22.sh"/{c=NR} /source "\$SCRIPT_DIR\/lib\/leap16_r23.sh"/{d=NR} /source "\$SCRIPT_DIR\/lib\/leap16_r24.sh"/{e=NR} END{exit !(a && b && c && d && e && b>a && c>b && d>c && e>d)}' bootloader-switcher.sh; then
    pass 'r21 completion layer plus r22/r23/r24 fixes load after the Leap adapter'
else
    fail_test 'r21/r22/r23/r24 release/load ordering is wrong'
fi

# Load just enough of the transaction lineage for focused Leap fixtures.
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

(
    set -u
    t=$(mktemp -d); trap 'rm -rf -- "$t"' EXIT
    mkdir -p "$t/EFI/BOOT" "$t/EFI/OPENSUSE" "$t/EFI/LIMINE"
    printf 'shim-bytes\n' >"$t/EFI/OPENSUSE/SHIM.EFI"
    printf 'grub-bytes\n' >"$t/EFI/OPENSUSE/GRUBX64.EFI"
    printf 'limine-bytes\n' >"$t/EFI/LIMINE/LIMINE_X64.EFI"

    resolve_efi_path_on_esp() {
        local p=${1//\\//}; p=${p#/}
        case "$p" in
            EFI/BOOT/BOOTX64.EFI) printf '%s\n' "$t/EFI/BOOT/BOOTX64.EFI" ;;
            EFI/opensuse/shim.efi|EFI/OPENSUSE/SHIM.EFI) printf '%s\n' "$t/EFI/OPENSUSE/SHIM.EFI" ;;
            EFI/opensuse/grubx64.efi|EFI/OPENSUSE/GRUBX64.EFI) printf '%s\n' "$t/EFI/OPENSUSE/GRUBX64.EFI" ;;
            EFI/LIMINE/LIMINE_X64.EFI) printf '%s\n' "$t/EFI/LIMINE/LIMINE_X64.EFI" ;;
            *) return 1 ;;
        esac
    }

    cp "$t/EFI/OPENSUSE/SHIM.EFI" "$t/EFI/BOOT/BOOTX64.EFI"
    [[ $(leap16_generic_fallback_owner) == grub ]] || exit 10

    cp "$t/EFI/LIMINE/LIMINE_X64.EFI" "$t/EFI/BOOT/BOOTX64.EFI"
    [[ $(leap16_generic_fallback_owner) == limine ]] || exit 11

    collect_storage_info() { :; }
    parse_efibootmgr() {
        BOOT_EFI_PATH='\EFI\BOOT\BOOTX64.EFI'
        BOOT_CURRENT=0007
        BOOT_LABEL='UEFI OS'
        BOOT_NEXT=''
        BOOT_ORDER='0002,0007,0000,0001'
    }
    have() { return 1; }
    detect_bootloader
    [[ $BOOTLOADER == limine ]] || exit 12
    [[ ${DETECTION_EVIDENCE[*]} == *'byte-identical to canonical Limine'* ]] || exit 13

    # If two different owners become byte-identical, generic-path ownership is
    # deliberately ambiguous and must fail closed.
    cp "$t/EFI/LIMINE/LIMINE_X64.EFI" "$t/EFI/OPENSUSE/SHIM.EFI"
    leap16_generic_fallback_owner >/dev/null 2>&1 && exit 14
    exit 0
)
case $? in
    0) pass 'generic UEFI fallback detects shim as GRUB, transferred bytes as Limine, and ambiguity fails closed' ;;
    *) fail_test 'generic UEFI fallback owner/detection fixture failed' ;;
esac

(
    set -u
    t=$(mktemp -d); trap 'rm -rf -- "$t"' EXIT
    ESP_MOUNT="$t/esp"
    mkdir -p "$ESP_MOUNT/EFI/LIMINE" "$ESP_MOUNT/EFI/BOOT" "$ESP_MOUNT/EFI/OPENSUSE"
    printf 'limine-bytes\n' >"$ESP_MOUNT/EFI/LIMINE/LIMINE_X64.EFI"
    printf 'shim-bytes\n' >"$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"
    printf 'shim-bytes\n' >"$ESP_MOUNT/EFI/OPENSUSE/SHIM.EFI"

    cat >"$t/pre.conf" <<'CONF'
/EFI fallback
### Shared recovery entry
comment: Preserved openSUSE generic fallback / GRUB2 recovery path
protocol: efi
path: boot():/EFI/BOOT/BOOTX64.EFI
CONF
    leap16_validate_limine_recovery_contract "$t/pre.conf" || exit 20

    cp "$ESP_MOUNT/EFI/LIMINE/LIMINE_X64.EFI" "$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"
    cat >"$t/transfer.conf" <<'CONF'
/openSUSE GRUB2 recovery
### Temporary direct recovery path retained until Limine fallback proof completes
comment: Native openSUSE shim/GRUB2 recovery path
protocol: efi
path: boot():/EFI/OPENSUSE/SHIM.EFI
CONF
    leap16_validate_limine_recovery_contract "$t/transfer.conf" || exit 21

    rm -rf "$ESP_MOUNT/EFI/OPENSUSE"
    : >"$t/final.conf"
    leap16_validate_limine_recovery_contract "$t/final.conf" || exit 22

    printf 'drift\n' >"$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"
    leap16_validate_limine_recovery_contract "$t/final.conf" >/dev/null 2>&1 && exit 23
    exit 0
)
case $? in
    0) pass 'Limine recovery contract accepts exactly pre-transfer, fallback-test, and finalized r21 states' ;;
    *) fail_test 'r21 Limine recovery topology fixture failed' ;;
esac

(
    set -u
    t=$(mktemp -d); trap 'rm -rf -- "$t"' EXIT
    PENDING_TRANSACTION_SNAPSHOT_DIR="$t/.prestage.TEST"
    mkdir -p "$PENDING_TRANSACTION_SNAPSHOT_DIR"
    PENDING_ESP_SOURCE=/dev/sda1
    PENDING_OLD_BOOT_ID=0000
    cat >"$PENDING_TRANSACTION_SNAPSHOT_DIR/prestage-efibootmgr-v.txt" <<'BASE'
BootCurrent: 0000
BootOrder: 0000,0001,0005
Boot0000* opensuse-secureboot HD(1,GPT,11111111-2222-3333-4444-555555555555,0x800,0x100000)/File(\EFI\OPENSUSE\SHIM.EFI)
Boot0001* opensuse HD(1,GPT,11111111-2222-3333-4444-555555555555,0x800,0x100000)/File(\EFI\OPENSUSE\GRUBX64.EFI)
Boot0005* Other HD(1,GPT,11111111-2222-3333-4444-555555555555,0x800,0x100000)/File(\EFI\OTHER\BOOT.EFI)
BASE
    leap16_pending_firmware_baseline_path() { printf '%s\n' "$PENDING_TRANSACTION_SNAPSHOT_DIR/prestage-efibootmgr-v.txt"; }
    lsblk() { [[ "$*" == *PARTUUID* ]] && printf '%s\n' 11111111-2222-3333-4444-555555555555; }
    [[ $(r21_source_grub_ids_csv) == '0000,0001' ]] || exit 30

    r21_fallback_ids_now() { printf '0007\n'; }
    leap16_boot_entry_is_active() { return 0; }
    leap16_nvram_entry_matches_current_esp() { return 0; }
    ok() { printf 'STATUS-LINE\n'; }
    got=$(r21_create_or_adopt_fallback_alias 2>/dev/null) || exit 31
    [[ $got == 0007 ]] || exit 32
    exit 0
)
case $? in
    0) pass 'r21 owns both pre-stage openSUSE GRUB aliases and returns an uncontaminated fallback Boot#### value' ;;
    *) fail_test 'r21 firmware ownership/value fixture failed' ;;
esac

(
    set -u
    t=$(mktemp -d); trap 'rm -rf -- "$t"' EXIT
    printf '%s\n' '0002,0000,0001,0004' >"$t/order"
    PENDING_TARGET_BOOT_ID=0002
    leap16_current_boot_order() { cat "$t/order"; }
    boot_id_exists() { return 0; }
    efibootmgr() {
        if [[ ${1:-} == -o ]]; then printf '%s\n' "$2" >"$t/order"; return 0; fi
        return 0
    }
    sudo() { "$@"; }
    out=$(r21_order_primary_fallback_then_existing 0007) || exit 40
    [[ $out == '0002,0007,0000,0001,0004' ]] || exit 41
    [[ $(cat "$t/order") == '0002,0007,0000,0001,0004' ]] || exit 42
    exit 0
)
case $? in
    0) pass 'fallback staging makes primary Limine first and fallback second while preserving existing GRUB/unrelated ordering' ;;
    *) fail_test 'r21 primary/fallback BootOrder builder fixture failed' ;;
esac

if grep -Fq 'r21_validate_fallback_runtime || return 1' lib/leap16_r21.sh \
   && grep -Fq 'r21_remove_source_grub_nvram_ids "$source_ids" || return 1' lib/leap16_r21.sh \
   && grep -Fq 'r21_remove_source_grub_files || return 1' lib/leap16_r21.sh \
   && grep -Fq 'sudo efibootmgr -n "$fallback_id"' lib/leap16_r21.sh \
   && awk '/^r21_retire_grub_after_fallback_proof\(\)/{infn=1} infn && /r21_validate_fallback_runtime \|\| return 1/{proof=NR} infn && /r21_remove_source_grub_nvram_ids/{del=NR} infn && /^}/{if(infn){exit}} END{exit !(proof && del && proof<del)}' lib/leap16_r21.sh; then
    pass 'GRUB2 retirement is statically downstream of exact fallback runtime proof'
else
    fail_test 'fallback-proof-before-GRUB-retirement sequencing guard failed'
fi

if grep -Fq 'if r21_fallback_meta_exists; then' lib/leap16_r21.sh \
   && grep -Fq 'if [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == "$fallback_id" ]]; then' lib/leap16_r21.sh \
   && grep -Fq 'r21_retire_grub_after_fallback_proof' lib/leap16_r21.sh \
   && grep -Fq 'systemctl reboot' lib/leap16_r21.sh; then
    pass 'root-owned resume recognizes the second fallback boot and continues the two-reboot transaction'
else
    fail_test 'second-boot automatic resume path is missing'
fi

printf '\n'
if ((failures == 0)); then
    printf 'All focused openSUSE Leap 16 r21 self-tests passed.\n'
    exit 0
fi
printf '%d focused r21 self-test(s) failed.\n' "$failures" >&2
exit 1
