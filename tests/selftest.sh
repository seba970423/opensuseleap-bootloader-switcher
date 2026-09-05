#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

pass() { printf '[PASS] %s\n' "$1"; }
test_fail() { printf '[FAIL] %s\n' "$1" >&2; exit 1; }

# Syntax is the cheapest possible guard against packaging a broken revision.
while IFS= read -r -d '' script; do
    bash -n "$script"
done < <(find . -type f -name '*.sh' -print0)
pass 'bash syntax'

(
    source lib/operations.sh
    operation_supported grub grub
    operation_supported grub limine
    operation_supported limine grub
    ! operation_supported limine limine
    ! operation_supported limine refind
    ! operation_supported grub systemd-boot
)
pass 'enabled operation matrix'

(
    source lib/kernels.sh
    [[ $(kernel_priority_for_pkgbase linux-cachyos) == 000 ]]
    [[ $(kernel_priority_for_pkgbase linux-cachyos-lts) == 900 ]]
)
pass 'regular CachyOS kernel priority before LTS'

(
    set +e
    source lib/common.sh
    source lib/grub_validate.sh
    sudo() { [[ ${1:-} == -n ]] && shift; command "$@"; }
    lsinitcpio() {
        [[ ${1:-} == -l ]] || return 1
        printf 'usr/lib/modules/7.2.0-1-cachyos/kernel/drivers/dummy.ko.zst\ninit\n'
    }
    image=$(mktemp)
    trap 'rm -f "$image"' EXIT
    printf image >"$image"
    grub_initramfs_matches_kernel_version "$image" 7.2.0-1-cachyos || exit 1
    grub_initramfs_matches_kernel_version "$image" 6.18.42-1-cachyos-lts && exit 1
    exit 0
)
pass 'conventional initramfs structural validation binds to exact kernel release'

(
    set +e
    source lib/common.sh
    source lib/grub_validate.sh
    source lib/operations.sh
    sudo() { [[ ${1:-} == -n ]] && shift; command "$@"; }
    root=$(mktemp -d)
    trap 'rm -rf "$root"' EXIT
    ESP_MOUNT="$root/esp"
    mkdir -p "$ESP_MOUNT"
    printf conf >"$ESP_MOUNT/limine.conf"
    source_file="$root/source"
    target_file="$root/target"
    printf identical >"$source_file"
    cp "$source_file" "$target_file"
    limine_conf_field_for_kernel() { printf 'boot():/dummy#deadbeef\n'; }
    verify_limine_uri_hash() { return 0; }
    resolve_limine_boot_uri() { printf '%s\n' "$source_file"; }
    validate_preexisting_grub_artifact_against_limine linux-cachyos 7.2.0-1-cachyos path "$target_file" || exit 1
    printf mismatch >"$target_file"
    validate_preexisting_grub_artifact_against_limine linux-cachyos 7.2.0-1-cachyos path "$target_file" && exit 1
    grub_initramfs_matches_kernel_version() { GRUB_INITRAMFS_REASON=''; return 0; }
    validate_preexisting_grub_artifact_against_limine linux-cachyos 7.2.0-1-cachyos module_path "$target_file" || exit 1
    exit 0
)
pass 'kernel payload remains strict while independently valid conventional initramfs may differ'

(
    set +e
    source lib/common.sh
    source lib/grub_validate.sh

    sudo() {
        [[ ${1:-} == -n ]] || return 99
        shift
        "$@"
    }
    grub-probe() {
        local target=""
        case "$1" in
            --target=*) target=${1#--target=} ;;
            *) return 98 ;;
        esac
        case "$target:$2" in
            device:/) printf '/dev/testroot\n' ;;
            fs:/) printf 'f2fs\n' ;;
            fs_uuid:/) printf 'ROOT-UUID\n' ;;
            device:/boot) printf '/dev/testesp\n' ;;
            fs:/boot) printf 'fat\n' ;;
            fs_uuid:/boot) printf 'ESP-UUID\n' ;;
            fs:/fail)
                printf 'grub-probe: error: synthetic probe failure\n' >&2
                return 7
                ;;
            *) return 97 ;;
        esac
    }

    GRUB_PROBE_DIAGNOSTICS=""
    grub_probe_capture Root fs / || exit 1
    [[ $GRUB_PROBE_VALUE == f2fs && $GRUB_PROBE_RC == 0 ]] || exit 1
    [[ $GRUB_PROBE_DIAGNOSTICS == *'target=fs path=/ rc=0'* ]] || exit 1

    grub_probe_capture Root fs /fail && exit 1
    [[ $GRUB_PROBE_RC == 7 ]] || exit 1
    [[ $GRUB_PROBE_STDERR == *'synthetic probe failure'* ]] || exit 1
    [[ $GRUB_PROBE_DIAGNOSTICS == *'synthetic probe failure'* ]] || exit 1

    grub_validate_probe_path Root / /dev/testroot f2fs ROOT-UUID >/dev/null || exit 1
    [[ $GRUB_PROBE_PATH_FAILURES == 0 ]] || exit 1
    grub_validate_probe_path 'Boot payload' /boot /dev/testesp vfat ESP-UUID >/dev/null || exit 1
    [[ $GRUB_PROBE_PATH_FAILURES == 0 ]] || exit 1
    [[ $(grub_normalize_fs_name vfat) == fat ]] || exit 1
    [[ $(grub_normalize_fs_name ext4) == ext ]] || exit 1
    [[ $(grub_normalize_fs_name ext2) == ext ]] || exit 1
    exit 0
)
pass 'privileged topology-aware grub-probe validation preserves stderr and FAT aliases'

(
    source lib/common.sh
    source lib/grub_validate.sh
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    cat >"$tmp" <<'CFG'
menuentry regular {
 linux /vmlinuz-linux-cachyos root=UUID=abc rw quiet nowatchdog splash
 initrd /intel-ucode.img /initramfs-linux-cachyos.img
}
menuentry lts {
 linux /vmlinuz-linux-cachyos-lts root=UUID=abc rw quiet nowatchdog splash
 initrd /intel-ucode.img /initramfs-linux-cachyos-lts.img
}
CFG
    [[ $(grub_kernel_first_line_number "$tmp" linux-cachyos) -lt $(grub_kernel_first_line_number "$tmp" linux-cachyos-lts) ]]
    [[ $(grub_linux_line_for_kernel "$tmp" linux-cachyos) == *"/vmlinuz-linux-cachyos "* ]]
    [[ $(grub_linux_line_for_kernel "$tmp" linux-cachyos) != *"vmlinuz-linux-cachyos-lts"* ]]
    grub_line_has_reference_tokens 'quiet nowatchdog splash rw root=UUID=abc' "$(grub_linux_line_for_kernel "$tmp" linux-cachyos)"
    ! grub_line_has_reference_tokens 'quiet nowatchdog splash foo=bar rw root=UUID=abc' "$(grub_linux_line_for_kernel "$tmp" linux-cachyos)"
    [[ $GRUB_MISSING_CMDLINE_TOKEN == foo=bar ]]
)
pass 'GRUB cmdline + kernel-order parser'

(
    set +e
    source lib/common.sh
    source lib/operations.sh
    source lib/staged.sh
    sudo() { [[ ${1:-} == -n ]] && shift; command "$@"; }
    root=$(mktemp -d)
    manifest=$(mktemp)
    trap 'rm -rf "$root"; rm -f "$manifest"' EXIT
    mkdir -p "$root/sub"
    printf alpha >"$root/a"
    printf beta >"$root/sub/b"
    ln -s a "$root/link"
    write_privileged_tree_manifest "$root" "$manifest" || exit 1
    pending_verify_tree_manifest "$root" "$manifest" || exit 1
    printf changed >"$root/a"
    pending_verify_tree_manifest "$root" "$manifest" && exit 1
    exit 0
)
pass 'exact ownership manifest detects mutation'

(
    set +e
    source lib/common.sh
    source lib/staged.sh
    sudo() { [[ ${1:-} == -n ]] && shift; command "$@"; }
    root=$(mktemp -d)
    manifest=$(mktemp)
    trap 'rm -rf "$root"; rm -f "$manifest"' EXIT
    printf shared >"$root/shared"
    printf created >"$root/created"
    hs=$(sha256sum "$root/shared" | awk '{print $1}')
    hc=$(sha256sum "$root/created" | awk '{print $1}')
    printf 'shared\t%s\t%s\ncreated\t%s\t%s\n' "$hs" "$root/shared" "$hc" "$root/created" >"$manifest"
    PENDING_FORMAT=4
    pending_verify_grub_artifact_manifest "$manifest" "$root" || exit 1
    printf changed >"$root/shared"
    pending_verify_grub_artifact_manifest "$manifest" "$root" && exit 1
    exit 0
)
pass 'format-4 GRUB artifact manifest distinguishes shared/created state'

(
    source lib/common.sh
    source lib/operations.sh
    export BOOTLOADER_SWITCHER_STATE_DIR
    BOOTLOADER_SWITCHER_STATE_DIR=$(mktemp -d)
    source lib/staged.sh
    trap 'rm -rf "$BOOTLOADER_SWITCHER_STATE_DIR"' EXIT

    snap="$PENDING_STATE_DIR/.prestage.TEST"
    mkdir -p "$snap"
    printf fallback >"$snap/BOOTX64.EFI.before"
    fallback_hash=$(sha256sum "$snap/BOOTX64.EFI.before" | cut -d' ' -f1)
    printf 'created\t%064d\t/boot/dummy\n' 0 >"$snap/grub-artifacts.tsv"
    for f in grub-dir.tsv grub-efi-dir.tsv; do
        printf 'f\t%064d\t/boot/dummy\n' 0 >"$snap/$f"
    done

    BOOT_LABEL=Limine
    BOOT_EFI_PATH='\EFI\LIMINE\LIMINE_X64.EFI'
    SOURCE_LIMINE_EFI_RESOLVED=/boot/EFI/LIMINE/LIMINE_X64.EFI
    SOURCE_LIMINE_EFI_HASH=$(printf 'a%.0s' {1..64})
    SOURCE_LIMINE_CONF_PATH=/boot/limine.conf
    SOURCE_LIMINE_CONF_HASH=$(printf 'b%.0s' {1..64})
    SOURCE_LIMINE_DEFAULT_HASH=$(printf 'c%.0s' {1..64})
    SOURCE_LIMINE_MANAGED_DIR=/boot/machine
    SOURCE_LIMINE_MANAGED_HASH=$(printf 'd%.0s' {1..64})
    OLD_FALLBACK_PATH=/boot/EFI/BOOT/BOOTX64.EFI
    OLD_FALLBACK_HASH=$fallback_hash
    OLD_FALLBACK_EXISTED=1
    OLD_FALLBACK_SNAPSHOT="$snap/BOOTX64.EFI.before"
    POST_STAGE_FALLBACK_HASH=$fallback_hash
    TRANSACTION_SNAPSHOT_DIR=$snap
    TARGET_EFI_RESOLVED=/boot/EFI/CACHYOS/GRUBX64.EFI
    TARGET_EFI_HASH=$(printf 'e%.0s' {1..64})
    TARGET_GRUB_CFG_PATH=/boot/grub/grub.cfg
    TARGET_GRUB_CFG_HASH=$(printf 'f%.0s' {1..64})
    TARGET_GRUB_DIR=/boot/grub
    GRUB_DEFAULT_CREATED=1
    GRUB_DEFAULT_HASH=$(printf '1%.0s' {1..64})
    GRUB_ARTIFACT_MANIFEST="$snap/grub-artifacts.tsv"
    GRUB_DIR_MANIFEST="$snap/grub-dir.tsv"
    TARGET_GRUB_EFI_DIR=/boot/EFI/CACHYOS
    GRUB_EFI_DIR_MANIFEST="$snap/grub-efi-dir.tsv"
    ESP_UUID=ESP
    ROOT_UUID=ROOT
    ESP_SOURCE=/dev/sda1
    ESP_MOUNT=/boot
    OPERATION_BACKUP=''
    GRUB_DIAGNOSTIC_DIR=/tmp/diag

    write_pending_limine_to_grub 0000 0000,0001 0002 candidate-ready
    load_pending_state
    [[ $PENDING_FORMAT == 4 ]]
    [[ $PENDING_SOURCE == limine && $PENDING_TARGET == grub ]]
    [[ $PENDING_TARGET_BOOT_ID == 0002 ]]
    [[ $PENDING_GRUB_ARTIFACT_MANIFEST == "$snap/grub-artifacts.tsv" ]]
)
pass 'Limine -> GRUB pending-state roundtrip'


(
    source lib/common.sh
    source lib/staged.sh
    source_cmd='quiet nowatchdog splash rw root=UUID=abc'
    target_cmd='BOOT_IMAGE=/vmlinuz-linux-cachyos root=UUID=abc rw splash quiet nowatchdog'
    pending_cmdline_equivalent "$source_cmd" "$target_cmd"
    ! pending_cmdline_equivalent "$source_cmd" "$target_cmd extra=1"
    [[ $(pending_cmdline_first_token "$target_cmd" 'root=*') == root=UUID=abc ]]
    [[ $(pending_cmdline_first_token "$target_cmd" 'rw') == rw ]]
)
pass 'runtime cmdline equivalence ignores loader-only tokens but rejects semantic drift'

(
    source lib/common.sh
    source lib/staged.sh
    efibootmgr() {
        cat <<'EFI'
BootCurrent: 0000
BootNext: 0005
BootOrder: 0000,0001,0005
EFI
    }
    [[ $(pending_bootnext_id) == 0005 ]]
    [[ $(pending_bootorder_first) == 0000 ]]
)
pass 'BootNext and persistent source-first BootOrder are parsed independently'

(
    set +e
    source lib/common.sh
    source lib/staged.sh
    TEST_NEXT=''
    TEST_PHASE='candidate-ready'
    PENDING_PHASE='candidate-ready'
    PENDING_SOURCE='limine'
    PENDING_TARGET='grub'
    PENDING_OLD_BOOT_ID='0000'
    PENDING_TARGET_BOOT_ID='0005'
    PENDING_TARGET_EFI_PATH='\\EFI\\CACHYOS\\GRUBX64.EFI'
    BOOTLOADER='limine'
    BOOT_CURRENT='0000'
    bootloader_display_name() { printf '%s' "$1"; }
    validate_pending_compatibility() { return 0; }
    detect_bootloader() { BOOTLOADER='limine'; BOOT_CURRENT='0000'; }
    run_validation() { return 0; }
    verify_pending_source_recovery_unchanged() { return 0; }
    verify_pending_candidate_ownership_unchanged() { return 0; }
    validate_pending_target_deep() { return 0; }
    pending_bootnext_id() { printf '%s\n' "$TEST_NEXT"; }
    pending_bootorder_first() { printf '0000\n'; }
    nvram_id_matches_path() { return 0; }
    pending_set_phase() { TEST_PHASE=$1; PENDING_PHASE=$1; return 0; }
    sudo() {
        if [[ $1 == efibootmgr && $2 == -n && $3 == 0005 ]]; then TEST_NEXT='0005'; return 0; fi
        if [[ $1 == efibootmgr && $2 == -N ]]; then TEST_NEXT=''; return 0; fi
        return 99
    }
    arm_pending_one_time_boot <<<'ARM' >/dev/null || exit 1
    [[ $TEST_NEXT == 0005 && $TEST_PHASE == boot-armed ]] || exit 1
    exit 0
)
pass 'one-time arming sets only target BootNext and persists boot-armed phase'

(
    source lib/common.sh
    export BOOTLOADER_SWITCHER_STATE_DIR
    BOOTLOADER_SWITCHER_STATE_DIR=$(mktemp -d)
    source lib/staged.sh
    trap 'rm -rf "$BOOTLOADER_SWITCHER_STATE_DIR"' EXIT
    cat >"$PENDING_STATE_FILE" <<'STATE'
format	4
phase	runtime-validated
created	2026-08-23T13:00:00+03:00
machine_id	test
source	limine
target	grub
old_boot_id	0000
target_boot_id	0005
source_cmdline	quiet rw root=UUID=abc
STATE
    load_pending_state
    [[ $PENDING_PHASE == runtime-validated ]]
)
pass 'runtime-validated phase is readable without changing r20 candidate formats'


(
    set +e
    source lib/common.sh
    source lib/staged.sh
    TEST_PHASE='boot-armed'
    TEST_NEXT=''
    PENDING_PHASE='boot-armed'
    PENDING_SOURCE='limine'
    PENDING_TARGET='grub'
    PENDING_OLD_BOOT_ID='0000'
    PENDING_TARGET_BOOT_ID='0005'
    PENDING_TARGET_EFI_PATH='\\EFI\\CACHYOS\\GRUBX64.EFI'
    BOOTLOADER='grub'
    BOOT_CURRENT='0005'
    bootloader_display_name() { printf '%s' "$1"; }
    validate_pending_compatibility() { return 0; }
    detect_bootloader() { BOOTLOADER='grub'; BOOT_CURRENT='0005'; }
    nvram_id_matches_path() { return 0; }
    run_validation() { return 0; }
    pending_bootnext_id() { printf '%s\n' "$TEST_NEXT"; }
    pending_bootorder_first() { printf '0000\n'; }
    pending_validate_running_kernel() { return 0; }
    pending_validate_runtime_cmdline_against_source() { return 0; }
    verify_pending_candidate_ownership_unchanged() { return 0; }
    validate_pending_target_deep() { return 0; }
    verify_pending_source_recovery_unchanged() { return 0; }
    pending_capture_runtime_diagnostics() { printf '/tmp/runtime-diag\n'; }
    pending_set_phase() { TEST_PHASE=$1; PENDING_PHASE=$1; return 0; }
    validate_pending_target_runtime >/dev/null || exit 1
    [[ $TEST_PHASE == runtime-validated ]] || exit 1
    exit 0
)
pass 'tool-armed target session can transition boot-armed to runtime-validated only after all runtime gates pass'


(
    source lib/operations.sh
    mapfile -t pkgs < <(bootloader_packages grub)
    [[ " ${pkgs[*]} " == *" grub "* ]]
    [[ " ${pkgs[*]} " == *" grub-hook "* ]]
    [[ " ${pkgs[*]} " == *" cachyos-grub-theme "* ]]
    grep -Fq 'GRUB_THEME="/usr/share/grub/themes/cachyos/theme.txt"' lib/operations.sh
)
pass 'GRUB candidate recipe includes the captured CachyOS theme package/path'

(
    source lib/common.sh
    source lib/operations.sh
    export BOOTLOADER_SWITCHER_STATE_DIR
    BOOTLOADER_SWITCHER_STATE_DIR=$(mktemp -d)
    source lib/staged.sh
    source lib/r21.sh
    trap 'rm -rf "$BOOTLOADER_SWITCHER_STATE_DIR"' EXIT
    mkdir -p "$PENDING_STATE_DIR"
    cat >"$PENDING_STATE_FILE" <<'STATE'
format	4
phase	runtime-validated
created	2026-08-23T13:00:00+03:00
machine_id	test
source	limine
target	grub
old_boot_id	0000
target_boot_id	0005
grub_cfg_hash	old
grub_default_hash	old
source_cmdline	quiet rw root=UUID=abc
STATE
    r21_pending_set_key grub_cfg_hash newcfg
    r21_pending_set_key grub_default_hash newdefault
    [[ $(awk -F'\t' '$1=="grub_cfg_hash"{print $2}' "$PENDING_STATE_FILE") == newcfg ]]
    [[ $(awk -F'\t' '$1=="grub_default_hash"{print $2}' "$PENDING_STATE_FILE") == newdefault ]]
    [[ $(grep -c '^grub_cfg_hash' "$PENDING_STATE_FILE") == 1 ]]
)
pass 'r21 can refresh target hashes without rewriting source identity/runtime proof fields'

(
    source lib/common.sh
    source lib/operations.sh
    export BOOTLOADER_SWITCHER_STATE_DIR
    BOOTLOADER_SWITCHER_STATE_DIR=$(mktemp -d)
    source lib/staged.sh
    source lib/r21.sh
    trap 'rm -rf "$BOOTLOADER_SWITCHER_STATE_DIR"' EXIT
    PENDING_SOURCE=limine
    PENDING_TARGET=grub
    PENDING_TRANSACTION_SNAPSHOT_DIR="$BOOTLOADER_SWITCHER_STATE_DIR/.prestage.test"
    mkdir -p "$PENDING_TRANSACTION_SNAPSHOT_DIR"
    ! r21_theme_required
    printf 'required\n' >"$(r21_theme_marker_path)"
    printf 'f\tabc\t/usr/share/grub/themes/cachyos/theme.txt\n' >"$(r21_theme_manifest_path)"
    r21_theme_required
)
pass 'CachyOS theme runtime-proof requirement is transaction-local and explicit'

(
    set +e
    source lib/common.sh
    source lib/operations.sh
    source lib/staged.sh
    source lib/r21.sh
    PENDING_ESP_SOURCE=/dev/sdc1
    lsblk() { printf 'fd2a8859-c86d-49d1-8a8a-fa1809f3d75f\n'; }
    efibootmgr() {
        cat <<'EFI'
Boot0000* Limine HD(1,GPT,fd2a8859-c86d-49d1-8a8a-fa1809f3d75f,0x1000,0x800000)/\EFI\LIMINE\LIMINE_X64.EFI
Boot0001* UEFI OS HD(1,GPT,fd2a8859-c86d-49d1-8a8a-fa1809f3d75f,0x1000,0x800000)/\EFI\BOOT\BOOTX64.EFI0000424f
Boot0005* cachyos HD(1,GPT,fd2a8859-c86d-49d1-8a8a-fa1809f3d75f,0x1000,0x800000)/\EFI\CACHYOS\GRUBX64.EFI
EFI
    }
    [[ $(r21_nvram_ids_for_esp_path '\EFI\BOOT\BOOTX64.EFI') == 0001 ]] || exit 1
    exit 0
)
pass 'finalizer identifies only the current-ESP generic fallback alias despite trailing firmware optional data'


(
    source lib/common.sh
    source lib/operations.sh
    export BOOTLOADER_SWITCHER_STATE_DIR
    BOOTLOADER_SWITCHER_STATE_DIR=$(mktemp -d)
    source lib/staged.sh
    source lib/r21.sh
    source lib/r22.sh
    trap 'rm -rf "$BOOTLOADER_SWITCHER_STATE_DIR"' EXIT
    old="$BOOTLOADER_SWITCHER_STATE_DIR/.prestage.OLD"
    new="/var/lib/cachyos-bootloader-switcher/r22/test/state/.prestage.OLD"
    mkdir -p "$old"
    in=$(mktemp); out=$(mktemp)
    trap 'rm -rf "$BOOTLOADER_SWITCHER_STATE_DIR"; rm -f "$in" "$out"' EXIT
    cat >"$in" <<STATE
transaction_snapshot_dir	$old
old_fallback_snapshot	$old/BOOTX64.EFI.before
grub_dir_manifest	$old/grub-dir.tsv
source_limine_conf_path	/boot/limine.conf
STATE
    r22_rebase_state_snapshot_paths "$in" "$out" "$old" "$new"
    [[ $(awk -F'\t' '$1=="transaction_snapshot_dir"{print $2}' "$out") == "$new" ]]
    [[ $(awk -F'\t' '$1=="old_fallback_snapshot"{print $2}' "$out") == "$new/BOOTX64.EFI.before" ]]
    [[ $(awk -F'\t' '$1=="source_limine_conf_path"{print $2}' "$out") == /boot/limine.conf ]]
)
pass 'r22 root-owned state copy rebases only transaction-private snapshot paths'

(
    source lib/common.sh
    source lib/operations.sh
    source lib/staged.sh
    source lib/r21.sh
    source lib/r22.sh
    unit=$(mktemp)
    trap 'rm -f "$unit"' EXIT
    r22_write_systemd_unit "$unit" /var/lib/cachyos-bootloader-switcher/r22/T /var/lib/cachyos-bootloader-switcher/r22/T/state
    grep -Fq 'ExecStart=/usr/bin/bash /var/lib/cachyos-bootloader-switcher/r22/T/tool/bootloader-switcher.sh --resume-transaction-root' "$unit"
    grep -Fq 'Environment=BOOTLOADER_SWITCHER_STATE_DIR=/var/lib/cachyos-bootloader-switcher/r22/T/state' "$unit"
    ! grep -Fq "$HOME/.local/state" "$unit"
)
pass 'r22 systemd resume unit executes only the root-owned tool/state copy'

(
    set +e
    source lib/common.sh
    source lib/operations.sh
    source lib/staged.sh
    source lib/r21.sh
    source lib/r22.sh
    TEST_NEXT=''
    TEST_PHASE='candidate-ready'
    PENDING_PHASE='candidate-ready'
    PENDING_SOURCE='limine'
    PENDING_TARGET='grub'
    PENDING_OLD_BOOT_ID='0000'
    PENDING_TARGET_BOOT_ID='0005'
    PENDING_TARGET_EFI_PATH='\\EFI\\CACHYOS\\GRUBX64.EFI'
    BOOTLOADER='limine'
    BOOT_CURRENT='0000'
    validate_pending_compatibility() { return 0; }
    detect_bootloader() { BOOTLOADER='limine'; BOOT_CURRENT='0000'; }
    run_validation() { return 0; }
    verify_pending_source_recovery_unchanged() { return 0; }
    verify_pending_candidate_ownership_unchanged() { return 0; }
    validate_pending_target_deep() { return 0; }
    pending_bootnext_id() { printf '%s\n' "$TEST_NEXT"; }
    pending_bootorder_first() { printf '0000\n'; }
    nvram_id_matches_path() { return 0; }
    pending_set_phase() { TEST_PHASE=$1; PENDING_PHASE=$1; return 0; }
    sudo() {
        if [[ $1 == efibootmgr && $2 == -n && $3 == 0005 ]]; then TEST_NEXT='0005'; return 0; fi
        if [[ $1 == efibootmgr && $2 == -N ]]; then TEST_NEXT=''; return 0; fi
        return 99
    }
    r22_arm_candidate_automatically >/dev/null || exit 1
    [[ $TEST_NEXT == 0005 && $TEST_PHASE == boot-armed ]] || exit 1
    exit 0
)
pass 'r22 automatically arms only the validated target BootNext without changing persistent source-first order'

(
    grep -Fq 'r22_after_fresh_limine_to_grub_candidate' lib/operations.sh
    grep -Fq 'R22_AUTO_FINALIZE' lib/r21.sh
    grep -Fq 'Reboot now? [y/N]:' lib/r22.sh
    grep -Fq 'ConditionPathExists=' lib/r22.sh
)
pass 'fresh Limine -> GRUB path is wired to automated resume while still prompting before reboot'


(
    source lib/operations.sh
    mapfile -t pkgs < <(bootloader_packages limine)
    [[ " ${pkgs[*]} " == *" limine "* ]]
    [[ " ${pkgs[*]} " == *" limine-mkinitcpio-hook "* ]]
    [[ " ${pkgs[*]} " == *" cachyos-wallpapers "* ]]
    grep -Fq 'limine-install --fallback' lib/operations.sh
)
pass 'r24 Limine recipe uses canonical CachyOS mkinitcpio hook, wallpaper package and standard fallback install'

(
    source lib/common.sh
    source lib/operations.sh
    export BOOTLOADER_SWITCHER_STATE_DIR
    BOOTLOADER_SWITCHER_STATE_DIR=$(mktemp -d)
    source lib/staged.sh
    source lib/r21.sh
    source lib/r22.sh
    source lib/r23.sh
    trap 'rm -rf "$BOOTLOADER_SWITCHER_STATE_DIR"' EXIT
    src=$(mktemp); conf=$(mktemp)
    trap 'rm -rf "$BOOTLOADER_SWITCHER_STATE_DIR"; rm -f "$src" "$conf"' EXIT
    printf splash >"$src"
    cat() { if [[ ${1:-} == /etc/machine-id ]]; then printf 'machine-test\n'; else command cat "$@"; fi; }
    r23_write_cachyos_limine_theme_base "$conf" "$src"
    grep -Fqx '# CachyOS Limine theme' "$conf"
    grep -Fqx 'term_palette: 1e1e2e;f38ba8;a6e3a1;f9e2af;89b4fa;f5c2e7;94e2d5;cdd6f4' "$conf"
    grep -Fqx 'wallpaper: boot():/limine-splash.png' "$conf"
    grep -Fqx 'comment: machine-id=machine-test' "$conf"
)
pass 'r23 writes the captured CachyOS Limine palette/branding base instead of generic Limine'

(
    set +e
    source lib/common.sh
    source lib/operations.sh
    export BOOTLOADER_SWITCHER_STATE_DIR
    BOOTLOADER_SWITCHER_STATE_DIR=$(mktemp -d)
    source lib/staged.sh
    source lib/r21.sh
    source lib/r22.sh
    source lib/r23.sh
    trap 'rm -rf "$BOOTLOADER_SWITCHER_STATE_DIR"' EXIT
    root=$(mktemp -d); trap 'rm -rf "$BOOTLOADER_SWITCHER_STATE_DIR" "$root"' EXIT
    TRANSACTION_SNAPSHOT_DIR="$root/.prestage.test"; mkdir -p "$TRANSACTION_SNAPSHOT_DIR"
    ESP_MOUNT="$root/esp"; mkdir -p "$ESP_MOUNT"; printf splash >"$ESP_MOUNT/limine-splash.png"
    sudo() { [[ ${1:-} == -n ]] && shift; command "$@"; }
    r23_record_limine_theme_manifest >/dev/null || exit 1
    PENDING_TRANSACTION_SNAPSHOT_DIR="$TRANSACTION_SNAPSHOT_DIR"
    PENDING_SOURCE=grub PENDING_TARGET=limine
    r23_verify_limine_theme_manifest >/dev/null || exit 1
    printf mutation >>"$ESP_MOUNT/limine-splash.png"
    r23_verify_limine_theme_manifest >/dev/null 2>&1 && exit 1
    exit 0
)
pass 'r23 Limine splash ownership manifest detects post-stage mutation'

(
    set +e
    source lib/common.sh
    source lib/operations.sh
    BOOTLOADER='grub'; BOOT_NEXT=''; ESP_MOUNT=$(mktemp -d)
    trap 'rm -rf "$ESP_MOUNT"' EXIT
    mkdir -p "$ESP_MOUNT/EFI/LIMINE"
    printf stale >"$ESP_MOUNT/EFI/LIMINE/limine_x64.efi"
    run_validation() { return 0; }
    is_cachyos() { return 0; }
    have() { return 0; }
    pending_exists() { return 1; }
    pacman() { return 1; }
    find_nvram_entry_for_target() { return 1; }
    path_exists_on_esp_privileged() { return 0; }
    validate_existing_boot_artifacts_for_limine_stage() { return 0; }
    sudo() { [[ ${1:-} == -n ]] && shift; command "$@"; }
    run_switch_preflight limine >/dev/null || exit 1
    exit 0
)
pass 'r23 permits an inactive pre-existing EFI/LIMINE payload when no Limine NVRAM/config/managed state exists'

(
    set +e
    source lib/common.sh
    source lib/operations.sh
    export BOOTLOADER_SWITCHER_STATE_DIR
    BOOTLOADER_SWITCHER_STATE_DIR=$(mktemp -d)
    source lib/staged.sh
    source lib/r21.sh
    source lib/r22.sh
    source lib/r23.sh
    root=$(mktemp -d); trap 'rm -rf "$BOOTLOADER_SWITCHER_STATE_DIR" "$root"' EXIT
    ESP_MOUNT="$root/esp"; TRANSACTION_SNAPSHOT_DIR="$root/state"
    mkdir -p "$ESP_MOUNT/EFI/LIMINE" "$TRANSACTION_SNAPSHOT_DIR"
    printf keep >"$ESP_MOUNT/EFI/LIMINE/unproven.bin"
    printf old >"$ESP_MOUNT/EFI/LIMINE/limine_x64.bak"
    sudo() { [[ ${1:-} == -n ]] && shift; command "$@"; }
    before=$(find "$ESP_MOUNT/EFI/LIMINE" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
    r23_snapshot_prestage_limine_efi_dir >/dev/null || exit 1
    rm -rf "$ESP_MOUNT/EFI/LIMINE"
    mkdir -p "$ESP_MOUNT/EFI/LIMINE"
    printf candidate >"$ESP_MOUNT/EFI/LIMINE/LIMINE_X64.EFI"
    r23_restore_prestage_limine_efi_dir "$TRANSACTION_SNAPSHOT_DIR" >/dev/null || exit 1
    after=$(find "$ESP_MOUNT/EFI/LIMINE" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
    [[ $before == "$after" ]] || exit 1
    [[ ! -e "$ESP_MOUNT/EFI/LIMINE/LIMINE_X64.EFI" ]] || exit 1
    exit 0
)
pass 'r23 snapshots and exactly restores a pre-existing inactive EFI/LIMINE namespace on rollback'

(
    source lib/restore.sh
    d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
    mkdir -p "$d/files/boot"
    cat >"$d/files/boot/limine.conf" <<'THEME'
# CachyOS Limine theme
term_palette: 1e1e2e;f38ba8;a6e3a1;f9e2af;89b4fa;f5c2e7;94e2d5;cdd6f4
term_palette_bright: 585b70;f38ba8;a6e3a1;f9e2af;89b4fa;f5c2e7;94e2d5;cdd6f4
term_background: ffffffff
term_foreground: cdd6f4
term_background_bright: ffffffff
term_foreground_bright: cdd6f4
interface_branding:
wallpaper: boot():/limine-splash.png
THEME
    r23_limine_backup_theme_is_cachyos "$d" /boot
)
pass 'r23 recognizes a validated v3-style backup as the captured CachyOS Limine theme'

(
    set +e
    source lib/common.sh
    source lib/operations.sh
    export BOOTLOADER_SWITCHER_STATE_DIR
    BOOTLOADER_SWITCHER_STATE_DIR=$(mktemp -d)
    source lib/staged.sh
    source lib/r21.sh
    source lib/r22.sh
    source lib/r23.sh
    TEST_NEXT=''; TEST_PHASE='candidate-ready'
    PENDING_PHASE='candidate-ready'; PENDING_SOURCE='grub'; PENDING_TARGET='limine'
    PENDING_OLD_BOOT_ID='0005'; PENDING_TARGET_BOOT_ID='0000'; PENDING_TARGET_EFI_PATH='\\EFI\\LIMINE\\LIMINE_X64.EFI'
    BOOTLOADER='grub'; BOOT_CURRENT='0005'
    bootloader_display_name() { printf '%s' "$1"; }
    validate_pending_compatibility() { return 0; }
    detect_bootloader() { BOOTLOADER='grub'; BOOT_CURRENT='0005'; }
    run_validation() { return 0; }
    verify_pending_source_recovery_unchanged() { return 0; }
    verify_pending_candidate_ownership_unchanged() { return 0; }
    validate_pending_target_deep() { return 0; }
    pending_bootnext_id() { printf '%s\n' "$TEST_NEXT"; }
    pending_bootorder_first() { printf '0005\n'; }
    nvram_id_matches_path() { return 0; }
    pending_set_phase() { TEST_PHASE=$1; PENDING_PHASE=$1; return 0; }
    sudo() {
        if [[ $1 == efibootmgr && $2 == -n && $3 == 0000 ]]; then TEST_NEXT='0000'; return 0; fi
        if [[ $1 == efibootmgr && $2 == -N ]]; then TEST_NEXT=''; return 0; fi
        return 99
    }
    r23_arm_candidate_automatically >/dev/null || exit 1
    [[ $TEST_NEXT == 0000 && $TEST_PHASE == boot-armed ]] || exit 1
    exit 0
)
pass 'r23 automatically arms deeply validated GRUB -> Limine BootNext without changing source-first BootOrder'

(
    grep -Fq 'R23_AUTO_FINALIZE=1 r23_finalize_grub_to_limine' lib/r23.sh
    grep -Fq 'R22_AUTO_FINALIZE=1 r21_finalize_limine_to_grub' lib/r23.sh
    grep -Fq 'r23_after_fresh_grub_to_limine_candidate' lib/r23.sh
    grep -Fq 'Reboot now? [y/N]:' lib/r23.sh
)
pass 'r23 automatic resume dispatches both GRUB <-> Limine directions and still prompts before reboot'

(
    source lib/backup.sh
    ESP_MOUNT=/boot
    cat() { if [[ ${1:-} == /etc/machine-id ]]; then printf 'machine-test\n'; else command cat "$@"; fi; }
    paths=$(backup_paths_for_bootloader limine)
    grep -Fqx '/boot/limine-splash.png' <<<"$paths"
    grep -Fqx '/boot/machine-test' <<<"$paths"
    grep -Fq 'format_version=4' lib/backup.sh
    grep -Fq 'backup_limine_v4_payloads_match_references' lib/backup.sh
)
pass 'Limine backup v4 captures splash + managed payload and validates BLAKE2 reference bytes'

(
    source lib/backup.sh
    d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
    mkdir -p "$d/files/boot/mid/linux-cachyos" "$d/files/boot/EFI/LIMINE"
    printf k >"$d/files/boot/mid/linux-cachyos/vmlinuz"
    printf i >"$d/files/boot/mid/linux-cachyos/initramfs"
    kh=$(b2sum "$d/files/boot/mid/linux-cachyos/vmlinuz" | awk '{print $1}')
    ih=$(b2sum "$d/files/boot/mid/linux-cachyos/initramfs" | awk '{print $1}')
    printf conf >"$d/files/boot/limine.conf"; printf splash >"$d/files/boot/limine-splash.png"; printf efi >"$d/files/boot/EFI/LIMINE/LIMINE_X64.EFI"
    printf '7.2.0-1-cachyos\n' >"$d/kernel-versions.txt"
    printf 'kernel_id\tversion\tkernel_uri\tkernel_b2\tinitramfs_uri\tinitramfs_b2\nlinux-cachyos\t7.2.0-1-cachyos\tboot():/mid/linux-cachyos/vmlinuz#%s\t%s\tboot():/mid/linux-cachyos/initramfs#%s\t%s\n' "$kh" "$kh" "$ih" "$ih" >"$d/limine-staged-reference.tsv"
    printf x >"$d/limine-fallback-reference.conf"
    printf 'format_version=4\nbootloader=limine\nmachine_id=mid\nesp_mount=/boot\n' >"$d/metadata.conf"
    (cd "$d"; find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum >SHA256SUMS)
    validate_backup "$d"
    printf mutation >>"$d/files/boot/mid/linux-cachyos/vmlinuz"
    (cd "$d"; find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum >SHA256SUMS)
    ! validate_backup "$d"
    [[ $BACKUP_VALIDATION_REASON == *'BLAKE2'* ]]
)
pass 'Limine v4 backup validator rejects managed payload drift even with a refreshed SHA256 manifest'

(
    grep -Fq 'case "${format_version:-}" in 2|3|4)' lib/backup.sh
    grep -Fq 'LEGACY RECONSTRUCTABLE' lib/backup.sh
    grep -Fq '3) r23_stage_limine_from_v3_backup' lib/restore.sh
    grep -Fq '4) r23_stage_limine_from_v4_backup' lib/restore.sh
    grep -Fq 'limine) restore_limine_backup' lib/restore.sh
    ! grep -Fq 'r20 has validated this backup' lib/restore.sh
)
pass 'r23 exposes real Limine restore: legacy v3 reconstruction + self-contained v4 restore'

(
    grep -Fq 'r23_snapshot_source_grub_cleanup_ownership' lib/r23.sh
    grep -Fq 'r23_verify_source_grub_cleanup_ownership' lib/r23.sh
    grep -Fq 'r23_remove_source_grub_owned_state' lib/r23.sh
    grep -Fq 'FINALIZED GRUB -> Limine successfully.' lib/r23.sh
)
pass 'GRUB -> Limine finalization is ownership-gated and wired to source GRUB cleanup'

(
    grep -Fq 'setup to $BACKUP_ROOT? [y/n]:' lib/operations.sh
    ! grep -Fq 'case "${ans:-Y}"' lib/operations.sh
    grep -Fq 'Back up the currently booted bootloader? [y/n]:' lib/backup.sh
)
pass 'backup prompts require an explicit yes/no choice instead of silently defaulting to backup'

(
    grep -Fq 'r23_rearm_candidate_with_resume' lib/r23.sh
    grep -Fq 'r23_rearm_runtime_validated_target' lib/r23.sh
    grep -Fq 'Re-arm automated one-time %s test + resume service' lib/r23.sh
    grep -Fq 'Re-arm validated %s target + automatic FINALIZE' lib/r23.sh
)
pass 'r23 recovery UX can re-arm parked or already-proven targets with automatic resume'

(
    grep -Fq "limine) printf '%s\\n' limine limine-mkinitcpio-hook cachyos-wallpapers" lib/operations.sh
    ! grep -Fq "limine-mkinitcpio-hook is installed and conflicts with required limine-entry-tool" lib/operations.sh
    grep -Fq "Canonical CachyOS Limine kernel integration detected: limine-mkinitcpio-hook." lib/operations.sh
    grep -Fq "Transitioning legacy standalone limine-entry-tool to CachyOS limine-mkinitcpio-hook." lib/operations.sh
    grep -Fq "limine-mkinitcpio-hook" lib/detect.sh
)
pass 'r24 accepts current CachyOS limine-mkinitcpio-hook and preserves a legacy transition path'

printf '\nAll inherited r24 self-tests passed.\n'

# r25 regression: GRUB backup restore must be transactional and must not use
# the old direct mkinitcpio/grub-install restore sequence.
grep -Fq 'Transactional GRUB restore plan:' lib/r25.sh || test_fail 'r25 transactional GRUB restore plan missing'
grep -Fq 'run_switch_preflight grub' lib/r25.sh || test_fail 'r25 GRUB restore does not reuse switch preflight'
grep -Fq 'execute_limine_to_grub' lib/r25.sh || test_fail 'r25 GRUB restore does not reuse proven Limine -> GRUB transaction'
grep -Fq 'R25_GRUB_RESTORE_DIR=$dir' lib/r25.sh || test_fail 'r25 GRUB restore does not select backup policy for staging'
if sed -n '/^restore_grub_backup()/,/^}/p' lib/r25.sh | grep -Fq 'sudo mkinitcpio -P'; then test_fail 'r25 GRUB restore still directly rebuilds initramfs with mkinitcpio -P'; fi
pass 'r25 GRUB backup restore reuses the automated runtime-proof transaction instead of direct replacement'

grep -Fq 'cp -a --no-preserve=all' lib/r25.sh || test_fail 'r25 VFAT-safe restore copy does not suppress unsupported archive metadata'
pass 'r25 ESP restore copy avoids uid/gid/mode/xattr preservation on VFAT'

grep -Fq 'limine-mkinitcpio-hook + cachyos-wallpapers' lib/restore.sh || test_fail 'r25 Limine restore plan still advertises standalone limine-entry-tool'
pass 'r25 restore UX advertises the canonical current CachyOS Limine package stack'

printf '\nAll r25 regression tests passed.\n'
awk '/source "\$SCRIPT_DIR\/lib\/restore.sh"/{r=NR} /source "\$SCRIPT_DIR\/lib\/r25.sh"/{p=NR} END{exit !(r && p && p>r)}' bootloader-switcher.sh || test_fail 'r25 overrides are sourced before restore.sh and would be overwritten'
pass 'r25 restore overrides load after the inherited restore backend'

# r25 regression: the failed r24 direct restore can leave inactive GRUB bytes
# behind after metadata-preservation errors on VFAT. r25 may clean them only
# after proving those bytes are owned by the selected validated backup and only
# after the explicit RESTORE confirmation.
grep -Fq 'r25_probe_failed_grub_restore_residue' lib/r25.sh || test_fail 'r25 failed-restore residue ownership probe missing'
grep -Fq 'byte-identical subset of the selected backup' lib/r25.sh || test_fail 'r25 does not require byte-level proof for stale /boot/grub residue'
grep -Fq 'r25_remove_proven_grub_restore_residue "$dir"' lib/r25.sh || test_fail 'r25 does not clean proven failed-restore residue after confirmation'
awk '
/^restore_grub_backup\(\)/{infn=1}
infn && /Type RESTORE to stage/{prompt=NR}
infn && /r25_remove_proven_grub_restore_residue "\$dir"/{cleanup=NR}
infn && /run_switch_preflight grub/{full=NR}
infn && /^}/{exit !(prompt && cleanup>prompt && full>cleanup)}
' lib/r25.sh || test_fail 'r25 residue cleanup/full preflight ordering is not confirmation -> cleanup -> clean-target preflight'
pass 'r25 safely recognizes and retires only backup-proven residue from the failed r24 VFAT restore'

# The selected target backup is not the optional source-recovery backup. Keep
# those identities separate in pending metadata.
if sed -n '/^restore_grub_backup()/,/^}/p' lib/r25.sh | grep -Fq 'OPERATION_BACKUP=$dir'; then
    test_fail 'r25 overwrites source recovery backup metadata with the selected target backup path'
fi
pass 'r25 keeps selected restore input separate from optional source recovery backup metadata'

# No release archaeology in user-visible executable messages. Historical
# internal function/state names may remain for compatibility.
if grep -RInE "^[[:space:]]*(printf|fail|info|ok|die|read[[:space:]]+-r[[:space:]]+-p).*r2[234]" bootloader-switcher.sh lib \
    | grep -vE "r23_theme_snapshot_root|r23_limine_theme_manifest_path|printf 'r22\\\\n'|r22-resume-bundle\\.path" >/dev/null; then
    test_fail 'r25 still leaks an inherited r22/r23/r24 release number in user-visible executable output'
fi
pass 'r25 user-visible executable messages no longer leak inherited release numbers'

printf '\nStarting r26 adapter-framework regression tests.\n'

(
    source lib/detect.sh
    line='Boot0006* UEFI OS      HD(1,GPT,deadbeef,0x1000,0x800000)/\EFI\BOOT\BOOTX64.EFI0000424f'
    [[ $(efi_path_from_efibootmgr_line "$line") == '\EFI\BOOT\BOOTX64.EFI' ]]
)
pass 'r26 EFI parser strips firmware optional data appended directly after .EFI'

(
    source lib/common.sh
    source lib/storage.sh
    source lib/detect.sh
    root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
    ESP_MOUNT="$root/esp"
    mkdir -p "$ESP_MOUNT/EFI/BOOT" "$ESP_MOUNT/EFI/LIMINE"
    printf limine-bytes >"$ESP_MOUNT/EFI/LIMINE/LIMINE_X64.EFI"
    cp "$ESP_MOUNT/EFI/LIMINE/LIMINE_X64.EFI" "$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"
    [[ $(detect_generic_fallback_owner_unprivileged) == limine ]]
    BOOT_EFI_PATH='\EFI\BOOT\BOOTX64.EFI'
    bootcurrent_is_generic_fallback
)
pass 'r26 can identify an unambiguous generic fallback owner but marks the path as fallback'

(
    set +e
    source lib/common.sh
    source lib/systemd_boot_validate.sh
    root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
    ESP_MOUNT="$root/esp"
    mkdir -p "$ESP_MOUNT/loader/entries"
    cat >"$ESP_MOUNT/loader/loader.conf" <<'EOF_LOADER'
default linux-cachyos.conf
timeout 5
console-mode keep
EOF_LOADER
    for kid in linux-cachyos linux-cachyos-lts; do
        printf kernel >"$ESP_MOUNT/vmlinuz-$kid"
        printf initrd >"$ESP_MOUNT/initramfs-$kid.img"
        cat >"$ESP_MOUNT/loader/entries/$kid.conf" <<EOF_ENTRY
title $kid
options root=UUID=test-root rw quiet nowatchdog splash
linux /vmlinuz-$kid
initrd /initramfs-$kid.img
EOF_ENTRY
    done
    PENDING_SOURCE_CMDLINE='quiet nowatchdog splash rw root=UUID=test-root'
    KERNEL_VERSIONS=()
    collect_kernels() { KERNEL_VERSIONS=(7.2.0-1-cachyos 6.18.42-1-cachyos-lts); }
    kernel_pkgbase_for_version() {
        case "$1" in
            7.2.0-1-cachyos) printf 'linux-cachyos\n' ;;
            6.18.42-1-cachyos-lts) printf 'linux-cachyos-lts\n' ;;
            *) return 1 ;;
        esac
    }
    have() { [[ $1 == bootctl ]]; }
    bootctl() { return 0; }
    sudo() { [[ ${1:-} == -n ]] && shift; "$@"; }
    validate_systemd_boot_chain target >/dev/null || exit 1
    exit 0
)
pass 'r26 systemd-boot deep validator accepts deterministic regular+LTS CachyOS loader entries'

(
    set +e
    source lib/common.sh
    source lib/refind_validate.sh
    root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
    ESP_MOUNT="$root/esp"
    REFIND_BOOT_ROOT="$root/boot"
    REFIND_LINUX_CONF_PATH="$REFIND_BOOT_ROOT/refind_linux.conf"
    mkdir -p "$ESP_MOUNT/EFI/refind" "$REFIND_BOOT_ROOT"
    cat >"$ESP_MOUNT/EFI/refind/refind.conf" <<EOF_REFIND
extra_kernel_version_strings $REFIND_CACHYOS_KERNEL_LIST
EOF_REFIND
    cat >"$REFIND_LINUX_CONF_PATH" <<'EOF_LINUX'
"Boot with standard options" "quiet nowatchdog splash rw root=UUID=test-root"
"Boot to single-user mode" "quiet nowatchdog splash rw root=UUID=test-root single"
EOF_LINUX
    for kid in linux-cachyos linux-cachyos-lts; do
        printf kernel >"$REFIND_BOOT_ROOT/vmlinuz-$kid"
        printf initrd >"$REFIND_BOOT_ROOT/initramfs-$kid.img"
    done
    PENDING_SOURCE_CMDLINE='quiet nowatchdog splash rw root=UUID=test-root'
    KERNEL_VERSIONS=()
    collect_kernels() { KERNEL_VERSIONS=(7.2.0-1-cachyos 6.18.42-1-cachyos-lts); }
    kernel_pkgbase_for_version() {
        case "$1" in
            7.2.0-1-cachyos) printf 'linux-cachyos\n' ;;
            6.18.42-1-cachyos-lts) printf 'linux-cachyos-lts\n' ;;
            *) return 1 ;;
        esac
    }
    grub_initramfs_matches_kernel_version() { GRUB_INITRAMFS_REASON=''; return 0; }
    sudo() { [[ ${1:-} == -n ]] && shift; "$@"; }
    validate_refind_boot_chain target >/dev/null || exit 1
    exit 0
)
pass 'r26 rEFInd deep validator accepts CachyOS kernel scan order and known-good cmdline'

(
    source lib/common.sh
    source lib/storage.sh
    source lib/detect.sh
    source lib/kernels.sh
    source lib/validate.sh
    source lib/limine_validate.sh
    source lib/grub_validate.sh
    source lib/systemd_boot_validate.sh
    source lib/refind_validate.sh
    source lib/backup.sh
    bootloader_display_name() { printf '%s' "$1"; }
    source lib/operations.sh
    source lib/staged.sh
    source lib/r21.sh
    source lib/r22.sh
    source lib/r23.sh
    source lib/restore.sh
    source lib/r25.sh
    source lib/r26.sh
    source lib/r27.sh
    operation_supported grub limine
    operation_supported limine grub
    operation_supported grub systemd-boot
    operation_supported systemd-boot grub
    operation_supported grub refind
    operation_supported refind grub
    ! operation_supported limine refind
    ! operation_supported systemd-boot refind
    declare -F adapter_source_validate >/dev/null
    declare -F adapter_source_snapshot >/dev/null
    declare -F adapter_source_preserve_recovery >/dev/null
    declare -F adapter_source_retire >/dev/null
    declare -F adapter_target_stage >/dev/null
    declare -F adapter_target_validate >/dev/null
    declare -F adapter_target_arm >/dev/null
    declare -F adapter_target_runtime_validate >/dev/null
    declare -F adapter_target_promote >/dev/null
    declare -F adapter_target_final_validate >/dev/null
)
pass 'r26 exposes source/target adapter contracts and enables the GRUB hub certification matrix'

(
    grep -Fq 'sudo bootctl --esp-path="$ESP_MOUNT" --random-seed=no --make-entry-directory=no install' lib/r26.sh
    grep -Fq 'sudo sdboot-manage --esp-path="$ESP_MOUNT" gen' lib/r26.sh
    grep -Fq 'sudo refind-install' lib/r26.sh
    grep -Fq 'R26_STAGED_TARGET_ID=' lib/r26.sh
    ! grep -Fq 'target_id=$(adapter_target_stage' lib/r26.sh
    ! grep -Fq 'mkinitcpio -P' lib/r26.sh
    grep -Fq 'r26_cleanup_uncommitted_target' lib/r26.sh
    grep -Fq 'The current session was booted through the generic UEFI fallback path.' lib/r26.sh
)
pass 'r26 staging uses current CachyOS systemd-boot/rEFInd tools, avoids stdout-ID capture, and has pre-commit rollback'

(
    grep -Fq 'REMOVE_EXISTING="no"' lib/r26.sh
    grep -Fq 'OVERWRITE_EXISTING="yes"' lib/r26.sh
    grep -Fq 'PRESERVE_FOREIGN="yes"' lib/r26.sh
    grep -Fq -- '--random-seed=no --make-entry-directory=no install' lib/r26.sh
)
pass 'r26 systemd-boot staging avoids destructive BLS cleanup and suppresses unrelated bootctl side effects'

(
    source lib/common.sh
    source lib/storage.sh
    source lib/detect.sh
    source lib/kernels.sh
    source lib/validate.sh
    source lib/limine_validate.sh
    source lib/grub_validate.sh
    source lib/systemd_boot_validate.sh
    source lib/refind_validate.sh
    source lib/backup.sh
    bootloader_display_name() { printf '%s' "$1"; }
    source lib/operations.sh
    source lib/staged.sh
    source lib/r21.sh
    source lib/r22.sh
    source lib/r23.sh
    source lib/restore.sh
    source lib/r25.sh
    source lib/r26.sh
    source lib/r27.sh
    ESP_MOUNT=/boot
    collect_kernels() { KERNEL_VERSIONS=(7.2.0-1-cachyos 6.18.42-1-cachyos-lts); }
    kernel_pkgbase_for_version() {
        case "$1" in
            7.2.0-1-cachyos) printf 'linux-cachyos\n' ;;
            6.18.42-1-cachyos-lts) printf 'linux-cachyos-lts\n' ;;
            *) return 1 ;;
        esac
    }
    paths=$(r26_adapter_paths systemd-boot)
    ! grep -Fxq '/boot/loader/entries' <<<"$paths"
    grep -Fxq '/boot/loader/entries/linux-cachyos.conf' <<<"$paths"
    grep -Fxq '/boot/loader/entries/linux-cachyos-fallback.conf' <<<"$paths"
    grep -Fxq '/boot/loader/entries/linux-cachyos-lts.conf' <<<"$paths"
)
pass 'r26 systemd-boot ownership manifest claims exact CachyOS entries, never the shared loader/entries tree'

(
    source lib/common.sh
    source lib/storage.sh
    source lib/detect.sh
    source lib/kernels.sh
    source lib/validate.sh
    source lib/limine_validate.sh
    source lib/grub_validate.sh
    source lib/systemd_boot_validate.sh
    source lib/refind_validate.sh
    source lib/backup.sh
    bootloader_display_name() { printf '%s' "$1"; }
    source lib/operations.sh
    source lib/staged.sh
    source lib/r21.sh
    source lib/r22.sh
    source lib/r23.sh
    source lib/restore.sh
    source lib/r25.sh
    source lib/r26.sh
    source lib/r27.sh
    root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
    PENDING_TARGET=systemd-boot
    PENDING_ESP_MOUNT="$root/esp"
    PENDING_SOURCE_FALLBACK_OWNED=0
    PENDING_OLD_FALLBACK_EXISTED=1
    fallback="$PENDING_ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"
    target="$PENDING_ESP_MOUNT/EFI/systemd/systemd-bootx64.efi"
    mkdir -p "$(dirname "$fallback")" "$(dirname "$target")"
    printf unrelated-fallback >"$fallback"
    printf target-systemd >"$target"
    PENDING_OLD_FALLBACK_HASH=$(sha256sum "$fallback" | awk '{print $1}')
    PENDING_TARGET_EFI_RESOLVED="$target"
    PENDING_TARGET_EFI_HASH=$(sha256sum "$target" | awk '{print $1}')
    before=$(sha256sum "$fallback" | awk '{print $1}')
    sudo() { [[ ${1:-} == -n ]] && shift; command "$@"; }
    r26_finalize_target_fallback >/dev/null
    after=$(sha256sum "$fallback" | awk '{print $1}')
    [[ $before == "$after" ]]
    [[ $after == "$PENDING_OLD_FALLBACK_HASH" ]]
)
pass 'r26 systemd-boot finalization preserves an unrelated pre-existing generic EFI fallback'

(
    awk '/^r26_target_namespace_clean\(\)/,/^}/' lib/r26.sh | grep -Fq 'loader/entries itself is a shared BLS namespace'
    ! awk '/^r26_target_namespace_clean\(\)/,/^}/' lib/r26.sh | grep -Fq '"$ESP_MOUNT/loader/entries" /etc/sdboot-manage'
    grep -Fq 'r26_systemd_entry_paths' lib/r26.sh
)
pass 'r26 systemd-boot namespace gate permits a shared BLS directory while rejecting adapter-owned entry filenames'

(
    grep -Fq 'Automatic post-boot validation/finalization is still running in the background.' lib/r26.sh
    grep -Fq 'r26_rearm_candidate_with_resume' lib/r26.sh
    grep -Fq 'r26_rearm_runtime_validated_target' lib/r26.sh
    grep -Fq 'Description=CachyOS Bootloader Switcher transaction resume' lib/r22.sh
)
pass 'r26 pending UX exposes background-finalization state and automated recovery re-arm'

(
    source lib/backup.sh
    source lib/r27.sh
    root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
    cat >"$root/metadata.conf" <<'META'
format_version=4
bootloader=systemd-boot
payload_policy=bootloader-owned-paths
created_epoch=1787508000
created_iso=2026-08-23T20:00:00+03:00
hostname=test
machine_id=0123456789abcdef0123456789abcdef
esp_source=/dev/sdc1
esp_mount=/boot
esp_uuid=4228-F0B6
root_source=/dev/sdc2
root_uuid=11571e27-bc5f-4a34-a3a5-eaadab4e19f9
boot_current=0000
boot_label=Linux\ Boot\ Manager
boot_efi_path=\\EFI\\systemd\\systemd-bootx64.efi
META
    (cd "$root" && sha256sum metadata.conf >SHA256SUMS)
    validate_backup "$root" || exit 1
    load_backup_metadata "$root" || exit 1
    [[ $bootloader == systemd-boot ]]
    [[ $boot_label == 'Linux Boot Manager' ]]
    [[ $boot_efi_path == '\EFI\systemd\systemd-bootx64.efi' ]]
)
pass 'r27 accepts printf-%q escaped systemd-boot backup metadata and validates the backup'

(
    source lib/backup.sh
    source lib/r27.sh
    root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
    marker="$root/SHOULD_NOT_EXIST"
    cat >"$root/metadata.conf" <<META
format_version=4
bootloader=systemd-boot
machine_id=0123456789abcdef0123456789abcdef
boot_label=\$(touch\ $marker)
META
    load_backup_metadata "$root" || exit 1
    [[ ! -e $marker ]]
    [[ $boot_label == "\$(touch $marker)" ]]
    printf 'unknown_key=value\n' >>"$root/metadata.conf"
    ! load_backup_metadata "$root"
)
pass 'r27 parses backup metadata as inert data and rejects keys outside the schema'

(
    source lib/backup.sh
    source lib/r27.sh
    root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
    cat >"$root/metadata.conf" <<'META'
format_version=4
bootloader=systemd-boot
bootloader=grub
META
    ! load_backup_metadata "$root"
)
pass 'r27 rejects duplicate backup metadata keys'

printf '\nAll r27 regression tests passed.\n' 

printf '\nStarting r28 systemd-boot restore regression tests.\n'

(
    source lib/common.sh
    source lib/storage.sh
    source lib/detect.sh
    source lib/kernels.sh
    source lib/validate.sh
    source lib/limine_validate.sh
    source lib/grub_validate.sh
    source lib/systemd_boot_validate.sh
    source lib/refind_validate.sh
    source lib/backup.sh
    bootloader_display_name() { printf '%s' "$1"; }
    source lib/operations.sh
    source lib/staged.sh
    source lib/r21.sh
    source lib/r22.sh
    source lib/r23.sh
    source lib/restore.sh
    source lib/r25.sh
    source lib/r26.sh
    source lib/r27.sh
    source lib/r28.sh

    root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
    dir="$root/backup"
    mkdir -p "$dir/files/boot/EFI/systemd" "$dir/files/boot/loader/entries" "$dir/files/etc/sdboot-manage.conf.d"
    printf efi >"$dir/files/boot/EFI/systemd/systemd-bootx64.efi"
    cat >"$dir/files/boot/loader/loader.conf" <<'LOADER'
default linux-cachyos.conf
timeout 5
console-mode keep
LOADER
    cat >"$dir/files/etc/sdboot-manage.conf.d/90-cachyos-bootloader-switcher.conf" <<'POLICY'
LINUX_OPTIONS="quiet nowatchdog splash"
REMOVE_EXISTING="no"
OVERWRITE_EXISTING="yes"
PRESERVE_FOREIGN="yes"
POLICY
    cat >"$dir/files/boot/loader/entries/linux-cachyos.conf" <<'ENTRY'
title Linux Cachyos
options root=UUID=test-root rw quiet nowatchdog splash
linux /vmlinuz-linux-cachyos
initrd /initramfs-linux-cachyos.img
ENTRY
    cat >"$dir/kernel-versions.txt" <<'VERS'
7.2.0-1-cachyos
VERS
    format_version=4
    bootloader=systemd-boot
    payload_policy=bootloader-owned-paths
    boot_efi_path='\EFI\systemd\systemd-bootx64.efi'
    esp_mount=/boot
    ESP_MOUNT=/boot
    collect_kernels() { KERNEL_VERSIONS=(7.2.0-1-cachyos); }
    kernel_pkgbase_for_version() { [[ $1 == 7.2.0-1-cachyos ]] && printf 'linux-cachyos\n'; }
    sdboot_path_exists() { return 0; }
    ref='root=UUID=test-root rw quiet nowatchdog splash'
    r28_validate_systemd_backup_payload "$dir" "$ref"
    ! r28_validate_systemd_backup_payload "$dir" 'root=UUID=test-root rw quiet nowatchdog splash mitigations=off'
)
pass 'r28 validates systemd-boot v4 owned restore payloads and rejects cmdline semantic drift'

(
    grep -Fq 'systemd-boot) restore_systemd_boot_backup "$dir"' lib/r28.sh
    grep -Fq 'r26_generic_preflight systemd-boot' lib/r28.sh
    grep -Fq 'r23_arm_candidate_automatically' lib/r28.sh
    grep -Fq 'r22_prepare_resume_bundle' lib/r28.sh
    grep -Fq 'r26_write_pending_adapter "$source" systemd-boot' lib/r28.sh
    grep -Fq 'r26_cleanup_uncommitted_target systemd-boot' lib/r28.sh
)
pass 'r28 wires systemd-boot restore into the r26 BootNext/runtime-proof transaction engine'

(
    body=$(awk '/^r28_stage_systemd_boot_from_backup\(\)/,/^}/' lib/r28.sh)
    grep -Fq -- '--random-seed=no --make-entry-directory=no install' <<<"$body"
    ! grep -Fq 'sdboot-manage --esp-path' <<<"$body"
    grep -Fq 'loader/entries/$kid.conf' <<<"$body"
    grep -Fq '90-cachyos-bootloader-switcher.conf' <<<"$body"
    ! grep -Fq 'restore_copy_from_backup' <<<"$body"
    ! grep -Fq 'loader/random-seed' <<<"$body"
)
pass 'r28 restores only systemd-boot adapter-owned state and never blindly copies the shared loader tree'

(
    grep -Fq 'Transactional systemd-boot restore currently requires the verified source bootloader to be GRUB.' lib/r28.sh
    grep -Fq 'Installed kernel versions do not exactly match the selected systemd-boot backup.' lib/r28.sh
    grep -Fq 'Foreign loader/entries files, loader random-seed/keys' lib/r28.sh
    grep -Fq 'If target proof fails, GRUB cleanup is not authorized.' lib/r28.sh
)
pass 'r28 restore preflight is GRUB-hub, topology/kernel exact, and foreign-BLS preserving'

printf '\nAll r28 regression tests passed.\n'


printf '\nStarting r29 nounset restore-path regression tests.\n'

(
    set -u
    source lib/r28.sh
    source lib/r29.sh
    unset -v backup_mount 2>/dev/null || true
    got=$(r28_systemd_backup_esp_path /tmp/r29-backup /boot)
    [[ $got == /tmp/r29-backup/files/boot ]]
)
pass 'r29 systemd-boot backup ESP path helper is safe under nounset with no dynamically-scoped backup_mount'

(
    body=$(awk '/^r28_systemd_backup_esp_path\(\)/,/^}/' lib/r29.sh)
    grep -Fq 'local dir=$1 backup_mount=$2 rel' <<<"$body"
    grep -Fq 'rel=${backup_mount#/}' <<<"$body"
    ! grep -Fq 'local dir=$1 backup_mount=$2 rel=${backup_mount#/}' <<<"$body"
)
pass 'r29 keeps the restore hotfix surgical and separates local declaration from dependent expansion'

printf '\nAll r29 regression tests passed.\n'

printf '\nStarting r30 generalized cross-backend restore regression tests.\n'

(
    source lib/common.sh
    source lib/storage.sh
    source lib/detect.sh
    source lib/kernels.sh
    source lib/validate.sh
    source lib/limine_validate.sh
    source lib/grub_validate.sh
    source lib/systemd_boot_validate.sh
    source lib/refind_validate.sh
    source lib/backup.sh
    bootloader_display_name() { printf '%s' "$1"; }
    source lib/operations.sh
    source lib/staged.sh
    source lib/r21.sh
    source lib/r22.sh
    source lib/r23.sh
    source lib/restore.sh
    source lib/r25.sh
    source lib/r26.sh
    source lib/r27.sh
    source lib/r28.sh
    source lib/r29.sh
    source lib/r30.sh

    r30_cross_restore_supported grub limine
    r30_cross_restore_supported limine grub
    r30_cross_restore_supported grub systemd-boot
    r30_cross_restore_supported systemd-boot grub
    r30_cross_restore_supported limine systemd-boot
    r30_cross_restore_supported systemd-boot limine
    ! r30_cross_restore_supported grub grub
    ! r30_cross_restore_supported systemd-boot systemd-boot
    ! r30_cross_restore_supported refind grub
    ! r30_cross_restore_supported grub refind

    # Restore matrix expansion must not silently expand the live migration matrix.
    ! operation_supported limine systemd-boot
    ! operation_supported systemd-boot limine
)
pass 'r30 enables all six GRUB/Limine/systemd-boot cross-restore pairs without expanding live migration certification'

(
    source lib/common.sh
    source lib/storage.sh
    source lib/detect.sh
    source lib/kernels.sh
    source lib/validate.sh
    source lib/limine_validate.sh
    source lib/grub_validate.sh
    source lib/systemd_boot_validate.sh
    source lib/refind_validate.sh
    source lib/backup.sh
    bootloader_display_name() { printf '%s' "$1"; }
    source lib/operations.sh
    source lib/staged.sh
    source lib/r21.sh
    source lib/r22.sh
    source lib/r23.sh
    source lib/restore.sh
    source lib/r25.sh
    source lib/r26.sh
    source lib/r27.sh
    source lib/r28.sh
    source lib/r29.sh
    source lib/r30.sh

    root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
    PENDING_STATE_FILE="$root/pending.tsv"
    PENDING_STATE_DIR="$root"
    write_state() {
        local source=$1 target=$2
        cat >"$PENDING_STATE_FILE" <<STATE
format	5
phase	candidate-ready
created	2026-08-23T21:00:00+03:00
machine_id	machine
source	$source
target	$target
old_boot_id	0000
old_boot_label	Source
old_boot_efi_path	\\EFI\\source\\source.efi
old_fallback_path	/boot/EFI/BOOT/BOOTX64.EFI
old_fallback_hash	$(printf a%.0s {1..64})
old_fallback_existed	1
old_fallback_snapshot	$root/fallback
post_stage_fallback_hash	$(printf b%.0s {1..64})
transaction_snapshot_dir	$root/snapshot
original_boot_order	0000,0001
target_boot_id	0001
target_efi_path	\\EFI\\target\\target.efi
target_efi_resolved	/boot/EFI/target/target.efi
target_efi_hash	$(printf c%.0s {1..64})
source_efi_resolved	/boot/EFI/source/source.efi
source_efi_hash	$(printf d%.0s {1..64})
source_manifest	$root/snapshot/source.tsv
target_manifest	$root/snapshot/target.tsv
source_fallback_owned	1
adapter_revision	1
esp_uuid	ESP
root_uuid	ROOT
esp_source	/dev/sda1
esp_mount	/boot
backup_path	/backup
source_cmdline	root=UUID=ROOT rw quiet
STATE
    }
    write_state limine systemd-boot
    load_pending_state
    [[ $PENDING_SOURCE == limine && $PENDING_TARGET == systemd-boot && $PENDING_REASON == valid ]]
    write_state systemd-boot limine
    load_pending_state
    [[ $PENDING_SOURCE == systemd-boot && $PENDING_TARGET == limine && $PENDING_REASON == valid ]]
    write_state limine refind
    ! load_pending_state
    [[ $PENDING_REASON == 'unsupported r26 adapter migration direction' ]]
)
pass 'r30 pending-state parser admits only the two new non-GRUB restore adapter pairs'

(
    source lib/common.sh
    source lib/kernels.sh
    source lib/grub_validate.sh
    source lib/r30.sh
    root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
    dir="$root/grub-backup"
    mkdir -p "$dir/files/etc/default" "$dir/files/boot/grub"
    cat >"$dir/files/etc/default/grub" <<'POLICY'
GRUB_DEFAULT=0
GRUB_TOP_LEVEL="/boot/vmlinuz-linux-cachyos"
GRUB_THEME="/usr/share/grub/themes/cachyos/theme.txt"
POLICY
    cat >"$dir/files/boot/grub/grub.cfg" <<'CFG'
menuentry 'Linux Cachyos' {
 linux /boot/vmlinuz-linux-cachyos root=UUID=test-root rw quiet nowatchdog splash
 initrd /boot/intel-ucode.img /boot/initramfs-linux-cachyos.img
}
menuentry 'Linux Cachyos Lts' {
 linux /boot/vmlinuz-linux-cachyos-lts root=UUID=test-root rw quiet nowatchdog splash
 initrd /boot/intel-ucode.img /boot/initramfs-linux-cachyos-lts.img
}
CFG
    format_version=4
    bootloader=grub
    payload_policy=bootloader-owned-paths
    boot_efi_path='\EFI\CACHYOS\GRUBX64.EFI'
    collect_kernels() { KERNEL_VERSIONS=(7.2.0-1-cachyos 6.18.42-1-cachyos-lts); KERNEL_PKGBASES=(linux-cachyos linux-cachyos-lts); }
    kernel_pkgbase_for_version() {
        case "$1" in
            7.2.0-1-cachyos) printf 'linux-cachyos\n' ;;
            6.18.42-1-cachyos-lts) printf 'linux-cachyos-lts\n' ;;
            *) return 1 ;;
        esac
    }
    r30_validate_grub_backup_payload "$dir" 'root=UUID=test-root rw quiet nowatchdog splash'
    ! r30_validate_grub_backup_payload "$dir" 'root=UUID=test-root rw quiet nowatchdog splash mitigations=off'
)
pass 'r30 validates GRUB v4 restore policy/grub.cfg semantics and rejects source cmdline drift'

(
    source lib/common.sh
    source lib/backup.sh
    source lib/operations.sh
    source lib/staged.sh
    source lib/r25.sh
    source lib/r26.sh
    source lib/r28.sh
    source lib/r29.sh
    source lib/r30.sh
    root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
    ESP_MOUNT="$root/boot"
    TRANSACTION_SNAPSHOT_DIR="$root/txn"
    mkdir -p "$ESP_MOUNT/EFI/LIMINE" "$TRANSACTION_SNAPSHOT_DIR"
    printf original-efi >"$ESP_MOUNT/EFI/LIMINE/limine_x64.bak"
    printf original-splash >"$ESP_MOUNT/limine-splash.png"
    r26_adapter_paths() { printf '%s\n' "$ESP_MOUNT/EFI/LIMINE" "$ESP_MOUNT/limine-splash.png"; }
    sudo() { [[ ${1:-} == -n ]] && shift; command "$@"; }

    r30_prepare_limine_target_residue
    [[ ! -e "$ESP_MOUNT/EFI/LIMINE" && ! -e "$ESP_MOUNT/limine-splash.png" ]]
    mkdir -p "$ESP_MOUNT/EFI/LIMINE"
    printf candidate >"$ESP_MOUNT/EFI/LIMINE/limine_x64.efi"
    printf candidate >"$ESP_MOUNT/limine-splash.png"
    r30_restore_limine_target_residue "$TRANSACTION_SNAPSHOT_DIR"
    [[ $(cat "$ESP_MOUNT/EFI/LIMINE/limine_x64.bak") == original-efi ]]
    [[ ! -e "$ESP_MOUNT/EFI/LIMINE/limine_x64.efi" ]]
    [[ $(cat "$ESP_MOUNT/limine-splash.png") == original-splash ]]
)
pass 'r30 snapshots inactive Limine target residue and restores it exactly on rollback'

(
    source lib/common.sh
    source lib/staged.sh
    source lib/r26.sh
    source lib/r30.sh
    root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
    PENDING_FORMAT=$R26_PENDING_FORMAT
    PENDING_TARGET=limine
    PENDING_ESP_MOUNT="$root/esp"
    PENDING_SOURCE_FALLBACK_OWNED=1
    PENDING_OLD_FALLBACK_EXISTED=1
    PENDING_TARGET_EFI_RESOLVED="$PENDING_ESP_MOUNT/EFI/LIMINE/LIMINE_X64.EFI"
    mkdir -p "$(dirname "$PENDING_TARGET_EFI_RESOLVED")"
    printf limine-target >"$PENDING_TARGET_EFI_RESOLVED"
    PENDING_TARGET_EFI_HASH=$(sha256sum "$PENDING_TARGET_EFI_RESOLVED" | awk '{print $1}')
    sudo() { [[ ${1:-} == -n ]] && shift; command "$@"; }
    r26_finalize_target_fallback
    fallback="$PENDING_ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"
    [[ -f $fallback ]]
    [[ $(sha256sum "$fallback" | awk '{print $1}') == "$PENDING_TARGET_EFI_HASH" ]]
)
pass 'r30 finalization materializes a byte-identical Limine generic fallback only after runtime proof'

(
    grep -Fq 'systemd-boot:grub) r30_restore_grub_backup "$dir"' lib/r30.sh
    grep -Fq 'systemd-boot:limine) r30_restore_limine_backup "$dir"' lib/r30.sh
    grep -Fq 'limine:systemd-boot) r30_restore_systemd_boot_backup "$dir"' lib/r30.sh
    grep -Fq 'r26_write_pending_adapter "$source" "$target"' lib/r30.sh
    grep -Fq 'r23_arm_candidate_automatically' lib/r30.sh
    grep -Fq 'r22_prepare_resume_bundle' lib/r30.sh
    grep -Fq 'r26_cleanup_uncommitted_target "$target"' lib/r30.sh
    grep -Fq 'rEFInd restore remains disabled' lib/r30.sh
)
pass 'r30 routes only the three missing cross-restore pairs through the source-preserving BootNext/runtime-proof engine'

(
    source lib/common.sh
    source lib/backup.sh
    source lib/operations.sh
    source lib/staged.sh
    source lib/r25.sh
    source lib/r26.sh
    source lib/r28.sh
    source lib/r29.sh
    source lib/r30.sh
    root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
    marker="$root/which"
    r26_state_format() { printf '%s\n' "$R26_PENDING_FORMAT"; }
    load_pending_state() { PENDING_TARGET=limine; PENDING_SOURCE=systemd-boot; return 0; }
    r30_rollback_pending_limine_restore() { printf custom >"$marker"; }
    rollback_pending_candidate_pre_r30() { printf legacy >"$marker"; }
    rollback_pending_candidate
    [[ $(cat "$marker") == custom ]]
    load_pending_state() { PENDING_TARGET=grub; PENDING_SOURCE=systemd-boot; return 0; }
    rollback_pending_candidate
    [[ $(cat "$marker") == legacy ]]
)
pass 'r30 rollback dispatcher reloads pending state and selects the Limine residue-aware rollback only for systemd-boot -> Limine'

printf '\nAll r30 regression tests passed.\n'

printf '\nStarting r31 legacy GRUB v3 cross-backend restore regression tests.\n'

(
    source lib/common.sh
    source lib/kernels.sh
    source lib/grub_validate.sh
    source lib/r31.sh
    root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
    dir="$root/grub-v3"
    mkdir -p "$dir/files/etc/default" "$dir/files/boot/grub"
    cat >"$dir/metadata.conf" <<'META'
format_version=3
bootloader=grub
payload_policy=bootloader-owned-paths
boot_efi_path=\\EFI\\CACHYOS\\GRUBX64.EFI
META
    cat >"$dir/files/etc/default/grub" <<'POLICY'
GRUB_DEFAULT=0
GRUB_TOP_LEVEL="/boot/vmlinuz-linux-cachyos"
GRUB_THEME="/usr/share/grub/themes/cachyos/theme.txt"
POLICY
    cat >"$dir/files/boot/grub/grub.cfg" <<'CFG'
menuentry 'Linux Cachyos' {
 linux /boot/vmlinuz-linux-cachyos root=UUID=test-root rw quiet nowatchdog splash
 initrd /boot/intel-ucode.img /boot/initramfs-linux-cachyos.img
}
menuentry 'Linux Cachyos Lts' {
 linux /boot/vmlinuz-linux-cachyos-lts root=UUID=test-root rw quiet nowatchdog splash
 initrd /boot/intel-ucode.img /boot/initramfs-linux-cachyos-lts.img
}
CFG
    printf '%s\n' 7.2.0-1-cachyos 6.18.42-1-cachyos-lts >"$dir/kernel-versions.txt"
    (
        cd "$dir"
        sha256sum ./metadata.conf ./kernel-versions.txt ./files/etc/default/grub ./files/boot/grub/grub.cfg >SHA256SUMS
    )
    format_version=3
    bootloader=grub
    payload_policy=bootloader-owned-paths
    boot_efi_path='\EFI\CACHYOS\GRUBX64.EFI'
    collect_kernels() { KERNEL_VERSIONS=(7.2.0-1-cachyos 6.18.42-1-cachyos-lts); KERNEL_PKGBASES=(linux-cachyos linux-cachyos-lts); }
    kernel_pkgbase_for_version() {
        case "$1" in
            7.2.0-1-cachyos) printf 'linux-cachyos\n' ;;
            6.18.42-1-cachyos-lts) printf 'linux-cachyos-lts\n' ;;
            *) return 1 ;;
        esac
    }
    r31_validate_grub_backup_payload "$dir" 'root=UUID=test-root rw quiet nowatchdog splash'
    grep -vF '  ./files/boot/grub/grub.cfg' "$dir/SHA256SUMS" >"$dir/SHA256SUMS.tmp"
    mv "$dir/SHA256SUMS.tmp" "$dir/SHA256SUMS"
    ! r31_validate_grub_backup_payload "$dir" 'root=UUID=test-root rw quiet nowatchdog splash'
    [[ $R30_GRUB_RESTORE_REASON == *'does not integrity-cover required restore evidence: files/boot/grub/grub.cfg'* ]]
)
pass 'r31 accepts semantically valid GRUB v3 restore evidence only when every consumed legacy file is integrity-covered'

(
    source lib/common.sh
    source lib/kernels.sh
    source lib/grub_validate.sh
    source lib/r31.sh
    root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
    dir="$root/grub-v4"
    mkdir -p "$dir/files/etc/default" "$dir/files/boot/grub"
    cat >"$dir/files/etc/default/grub" <<'POLICY'
GRUB_DEFAULT=0
GRUB_TOP_LEVEL="/boot/vmlinuz-linux-cachyos"
GRUB_THEME="/usr/share/grub/themes/cachyos/theme.txt"
POLICY
    cat >"$dir/files/boot/grub/grub.cfg" <<'CFG'
menuentry 'Linux Cachyos' {
 linux /boot/vmlinuz-linux-cachyos root=UUID=test-root rw quiet nowatchdog splash
 initrd /boot/intel-ucode.img /boot/initramfs-linux-cachyos.img
}
menuentry 'Linux Cachyos Lts' {
 linux /boot/vmlinuz-linux-cachyos-lts root=UUID=test-root rw quiet nowatchdog splash
 initrd /boot/intel-ucode.img /boot/initramfs-linux-cachyos-lts.img
}
CFG
    format_version=4
    bootloader=grub
    payload_policy=bootloader-owned-paths
    boot_efi_path='\EFI\CACHYOS\GRUBX64.EFI'
    collect_kernels() { KERNEL_VERSIONS=(7.2.0-1-cachyos 6.18.42-1-cachyos-lts); KERNEL_PKGBASES=(linux-cachyos linux-cachyos-lts); }
    kernel_pkgbase_for_version() {
        case "$1" in
            7.2.0-1-cachyos) printf 'linux-cachyos\n' ;;
            6.18.42-1-cachyos-lts) printf 'linux-cachyos-lts\n' ;;
            *) return 1 ;;
        esac
    }
    r31_validate_grub_backup_payload "$dir" 'root=UUID=test-root rw quiet nowatchdog splash'
)
pass 'r31 preserves GRUB v4 cross-source payload validation while adding v3 compatibility'

(
    source lib/r31.sh
    root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
    d="$root/grub-old"
    mkdir -p "$d"
    DISCOVERED_BACKUPS=()
    BACKUP_ROOT="$root"
    discover_backups_quiet() { DISCOVERED_BACKUPS=("$d"); }
    validate_backup_compatibility() { BACKUP_COMPATIBILITY_REASON='compatible'; return 0; }
    load_backup_metadata() { format_version=3; bootloader=grub; return 0; }
    out=$(list_backups)
    [[ $out == *'[v3, VALID, COMPATIBLE]'* ]]
)
pass 'r31 backup chooser surfaces the format version instead of hiding legacy v3/v4 differences'

(
    grep -Fq 'source "$SCRIPT_DIR/lib/r31.sh"' bootloader-switcher.sh
    grep -Fq '3|4)' lib/r31.sh
    grep -Fq 'Cross-source GRUB restore requires backup format v3 or v4' lib/r31.sh
    grep -Fq 'r30_execute_restored_adapter "$dir" grub r30_stage_grub_from_backup' lib/r31.sh
    grep -Fq 'rEFInd restore remains disabled' lib/r30.sh
)
pass 'r31 widens only the GRUB backup-generation contract and keeps the r30 transactional executor/rEFInd boundary intact'

printf '\nAll r31 regression tests passed.\n'

printf '\nStarting r32 rEFInd duplicate-ESP-mount regression tests.\n'

(
    source lib/common.sh
    source lib/storage.sh
    source lib/r32.sh

    have() { [[ $1 == lsblk ]]; }
    findmnt() {
        # Duplicate identical /boot records reproduce the real rEFInd hardware case.
        if [[ "$*" == *'-M /boot'* && "$*" == *'SOURCE,FSTYPE'* ]]; then
            printf '/dev/sdc1 vfat\n/dev/sdc1 vfat\n'
            return 0
        fi
        return 1
    }
    lsblk() {
        if [[ "$*" == *'PARTTYPE'* ]]; then
            printf 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b\n'
        elif [[ "$*" == *'UUID'* ]]; then
            printf '4228-F0B6\n'
        fi
    }
    resolve_uuid() { printf '4228-F0B6\n'; }

    ESP_SOURCE='' ESP_MOUNT='' ESP_FSTYPE='' ESP_UUID='' ESP_PARTTYPE=''
    find_esp_from_mounts
    [[ $ESP_SOURCE == /dev/sdc1 ]]
    [[ $ESP_MOUNT == /boot ]]
    [[ $ESP_FSTYPE == vfat ]]
    [[ $ESP_UUID == 4228-F0B6 ]]
    [[ $ESP_MOUNT_STACK_DEPTH == 2 ]]
)
pass 'r32 logically deduplicates identical stacked /boot ESP mounts while retaining stack-depth diagnostics'

(
    set +e
    source lib/common.sh
    source lib/storage.sh
    source lib/r32.sh

    have() { [[ $1 == lsblk ]]; }
    findmnt() {
        if [[ "$*" == *'-M /boot'* && "$*" == *'SOURCE,FSTYPE'* ]]; then
            printf '/dev/sdc1 vfat\n/dev/sdd1 vfat\n'
            return 0
        fi
        return 1
    }
    lsblk() { printf 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b\n'; }
    resolve_uuid() { printf 'synthetic\n'; }

    ESP_SOURCE='' ESP_MOUNT='' ESP_FSTYPE='' ESP_UUID='' ESP_PARTTYPE=''
    find_esp_from_mounts && exit 1
    [[ $ESP_DETECTION_REASON == 'multiple distinct mount identities are stacked at /boot' ]] || exit 1
    exit 0
)
pass 'r32 refuses genuinely conflicting stacked ESP candidates instead of arbitrarily picking one'
\

(
    set +e
    source lib/common.sh
    source lib/storage.sh
    source lib/r32.sh

    have() { [[ $1 == lsblk ]]; }
    findmnt() {
        if [[ "$*" == *'-M /boot'* && "$*" == *'SOURCE,FSTYPE'* ]]; then
            printf '/dev/sdc1 vfat\n/dev/sdc2 ext4\n'
            return 0
        fi
        return 1
    }
    lsblk() {
        case "$*" in
            *'/dev/sdc1'*) printf 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b\n' ;;
            *) printf '0fc63daf-8483-4772-8e79-3d69d8477de4\n' ;;
        esac
    }
    resolve_uuid() { printf 'synthetic\n'; }

    ESP_SOURCE='' ESP_MOUNT='' ESP_FSTYPE='' ESP_UUID='' ESP_PARTTYPE=''
    find_esp_from_mounts && exit 1
    [[ $ESP_DETECTION_REASON == 'multiple distinct mount identities are stacked at /boot' ]] || exit 1
    exit 0
)
pass 'r32 refuses mixed filesystem mount stacks at the ESP target even when only one row looks like an ESP'

(
    set +e
    source lib/common.sh
    source lib/storage.sh
    source lib/r32.sh

    collect_storage_info() {
        ESP_SOURCE=/dev/sdc1
        ESP_MOUNT=/boot
        ESP_FSTYPE=vfat
        ESP_UUID=4228-F0B6
        ESP_MOUNT_STACK_DEPTH=2
        ESP_DETECTION_REASON=''
    }
    r32_sources_equivalent() { [[ $1 == "$2" ]]; }
    r32_verify_refind_post_install_esp /dev/sdc1 /boot vfat 4228-F0B6 >/dev/null || exit 1

    collect_storage_info() {
        ESP_SOURCE=/dev/sdd1
        ESP_MOUNT=/boot
        ESP_FSTYPE=vfat
        ESP_UUID=DEAD-BEEF
        ESP_MOUNT_STACK_DEPTH=1
        ESP_DETECTION_REASON=''
    }
    r32_verify_refind_post_install_esp /dev/sdc1 /boot vfat 4228-F0B6 >/dev/null 2>&1 && exit 1
    exit 0
)
pass 'r32 post-refind-install topology gate accepts identical mount stacking but rejects source/UUID drift'

(
    body=$(declare -f r26_stage_refind_target 2>/dev/null || true)
    # Source through r32 so the override is the function under inspection.
    source lib/common.sh
    source lib/r32.sh
    body=$(declare -f r26_stage_refind_target)
    install_line=$(grep -nF 'sudo refind-install' <<<"$body" | cut -d: -f1)
    gate_line=$(grep -nF 'r32_verify_refind_post_install_esp' <<<"$body" | cut -d: -f1)
    config_line=$(grep -nF 'r26_patch_refind_config' <<<"$body" | cut -d: -f1)
    [[ -n $install_line && -n $gate_line && -n $config_line ]]
    (( install_line < gate_line && gate_line < config_line ))
)
pass 'r32 re-proves ESP identity immediately after refind-install and before touching generated rEFInd configuration'

(
    awk '/source "\$SCRIPT_DIR\/lib\/r31.sh"/{a=NR} /source "\$SCRIPT_DIR\/lib\/r32.sh"/{b=NR} END{exit !(a && b && b>a)}' bootloader-switcher.sh
    grep -Fq 'candidate-ready' README.md
    grep -Fq 'Manage pending/staged migration' README.md
)
pass 'r32 loads after r31 and documents reuse of the parked candidate-ready rEFInd transaction'


printf '\nStarting r33 rEFInd runtime-proof regression tests.\n'
(
    set +e
    source lib/common.sh
    source lib/storage.sh
    source lib/detect.sh
    source lib/kernels.sh
    source lib/validate.sh
    source lib/limine_validate.sh
    source lib/grub_validate.sh
    source lib/systemd_boot_validate.sh
    source lib/refind_validate.sh
    source lib/backup.sh
    bootloader_display_name() { printf '%s' "$1"; }
    source lib/operations.sh
    source lib/staged.sh
    source lib/r21.sh
    source lib/r22.sh
    source lib/r23.sh
    source lib/restore.sh
    source lib/r25.sh
    source lib/r26.sh
    source lib/r27.sh
    source lib/r28.sh
    source lib/r29.sh
    source lib/r30.sh
    source lib/r31.sh
    source lib/r32.sh
    source lib/r33.sh
    sudo() { [[ ${1:-} == -n ]] && shift; command "$@"; }

    root=$(mktemp -d)
    old=$(mktemp)
    new=$(mktemp)
    trap 'rm -rf "$root"; rm -f "$old" "$new"' EXIT
    mkdir -p "$root/icons" "$root/vars"
    printf efi >"$root/refind_x64.efi"
    printf conf >"$root/refind.conf"
    printf icon >"$root/icons/os_arch.png"

    # Simulate an r32-era full-tree snapshot, then rEFInd legitimately writes
    # PreviousBoot after the first real boot.
    write_privileged_tree_manifest "$root" "$old" || exit 1
    printf 'Boot vmlinuz-linux-cachyos from FAT volume\n' >"$root/vars/PreviousBoot"
    r33_verify_refind_immutable_tree_manifest "$root" "$old" || exit 1

    # New r33 snapshots exclude the mutable vars namespace entirely.
    r33_write_refind_immutable_tree_manifest "$root" "$new" || exit 1
    grep -F "$root/vars" "$new" >/dev/null && exit 1

    # Immutable install/config bytes remain protected.
    printf tampered >>"$root/refind.conf"
    r33_verify_refind_immutable_tree_manifest "$root" "$old" >/dev/null 2>&1 && exit 1
    exit 0
)
pass 'r33 treats only rEFInd vars as mutable while immutable rEFInd install state remains ownership-proven'

(
    set +e
    source lib/common.sh
    source lib/storage.sh
    source lib/detect.sh
    source lib/kernels.sh
    source lib/validate.sh
    source lib/limine_validate.sh
    source lib/grub_validate.sh
    source lib/systemd_boot_validate.sh
    source lib/refind_validate.sh
    source lib/backup.sh
    bootloader_display_name() { printf '%s' "$1"; }
    source lib/operations.sh
    source lib/staged.sh
    source lib/r21.sh
    source lib/r22.sh
    source lib/r23.sh
    source lib/restore.sh
    source lib/r25.sh
    source lib/r26.sh
    source lib/r27.sh
    source lib/r28.sh
    source lib/r29.sh
    source lib/r30.sh
    source lib/r31.sh
    source lib/r32.sh
    source lib/r33.sh

    previous=$(mktemp)
    trap 'rm -f "$previous"' EXIT
    REFIND_PREVIOUS_BOOT_FILE=$previous
    R33_RUNNING_KERNEL_RELEASE=7.2.0-1-cachyos
    PENDING_TARGET=refind
    PENDING_OLD_BOOT_EFI_PATH='\\EFI\\CACHYOS\\GRUBX64.EFI'
    kernel_pkgbase_for_version() { [[ $1 == 7.2.0-1-cachyos ]] && printf 'linux-cachyos\n'; }

    printf 'Boot vmlinuz-linux-cachyos from 3 GiB FAT volume\n' >"$previous"
    r33_verify_refind_direct_kernel_launch >/dev/null || exit 1

    printf 'Boot EFI\\cachyos\\grubx64.efi from 3 GiB FAT volume\n' >"$previous"
    r33_verify_refind_direct_kernel_launch >/dev/null 2>&1 && exit 1
    exit 0
)
pass 'r33 PreviousBoot proof accepts direct CachyOS kernel launch and rejects protected GRUB chainload'

(
    awk '/source "\$SCRIPT_DIR\/lib\/r32.sh"/{a=NR} /source "\$SCRIPT_DIR\/lib\/r33.sh"/{b=NR} END{exit !(a && b && b>a)}' bootloader-switcher.sh
    grep -Fq 'rEFInd mutable runtime state + direct-kernel proof' README.md
    grep -Fq 'PreviousBoot' README.md
)
pass 'r33 loads after r32 and documents mutable-vars plus direct-kernel runtime proof'

printf '\nAll r33 regression tests passed.\n'

printf '\nStarting r34 nounset/local-initialization regression tests.\n'

(
    set +e
    # These helpers must fail normally for a nonexistent kernel without relying
    # on any dynamically scoped caller-local named `ver`.
    out=$(bash -uc '
        source lib/common.sh
        source lib/kernels.sh
        unset ver 2>/dev/null || true
        kernel_pkgbase_from_modules definitely-not-a-real-kernel
    ' 2>&1)
    rc=$?
    ((rc != 0)) || exit 1
    [[ $out != *"unbound variable"* ]] || exit 1

    out=$(bash -uc '
        source lib/common.sh
        source lib/kernels.sh
        source lib/limine_validate.sh
        unset ver 2>/dev/null || true
        kernel_pkgbase_for_version definitely-not-a-real-kernel
    ' 2>&1)
    rc=$?
    ((rc != 0)) || exit 1
    [[ $out != *"unbound variable"* ]] || exit 1
    exit 0
)
pass 'r34 kernel pkgbase helpers are nounset-safe without caller-local ver masking'

(
    set +e
    source lib/common.sh
    source lib/storage.sh
    source lib/detect.sh
    source lib/kernels.sh
    source lib/validate.sh
    source lib/limine_validate.sh
    source lib/grub_validate.sh
    source lib/systemd_boot_validate.sh
    source lib/refind_validate.sh
    source lib/backup.sh
    bootloader_display_name() { printf '%s' "$1"; }
    source lib/operations.sh
    source lib/staged.sh
    source lib/r21.sh
    source lib/r22.sh
    source lib/r23.sh
    source lib/restore.sh
    source lib/r25.sh
    source lib/r26.sh
    source lib/r27.sh
    source lib/r28.sh
    source lib/r29.sh
    source lib/r30.sh
    source lib/r31.sh
    source lib/r32.sh
    source lib/r33.sh
    source lib/r34.sh

    # Active r25 definitions must no longer derive path locals from another
    # local assigned on the same command.
    declare -f r25_probe_failed_grub_restore_residue | grep -F 'local dir=$1 backup_default="$dir' >/dev/null && exit 1
    declare -f r25_validate_grub_backup_policy | grep -F 'local dir=$1 src="$dir' >/dev/null && exit 1
    declare -f r25_install_grub_policy_from_backup | grep -F 'local dir=$1 src="$dir' >/dev/null && exit 1
    exit 0
)
pass 'r34 removes the remaining active r25 dependent-local initializers'

(
    grep -Fq 'source "$SCRIPT_DIR/lib/r34.sh"' bootloader-switcher.sh
    awk '/source "\$SCRIPT_DIR\/lib\/r33.sh"/{a=NR} /source "\$SCRIPT_DIR\/lib\/r34.sh"/{b=NR} END{exit !(a && b && b>a)}' bootloader-switcher.sh
    grep -Fq 'r34 nounset / dynamic-scope hardening' README.md
)
pass 'r34 loads after r33 and documents nounset/dynamic-scope hardening'

printf '\nAll r34 regression tests passed.\n'

printf '\nStarting r35 rEFInd restore/status regression tests.\n'

(
    set +e
    source lib/common.sh
    source lib/storage.sh
    source lib/detect.sh
    source lib/kernels.sh
    source lib/validate.sh
    source lib/limine_validate.sh
    source lib/grub_validate.sh
    source lib/systemd_boot_validate.sh
    source lib/refind_validate.sh
    source lib/backup.sh
    bootloader_display_name() { case "$1" in grub) printf 'GRUB';; refind) printf 'rEFInd';; *) printf '%s' "$1";; esac; }
    source lib/operations.sh
    source lib/staged.sh
    source lib/r21.sh
    source lib/r22.sh
    source lib/r23.sh
    source lib/restore.sh
    source lib/r25.sh
    source lib/r26.sh
    source lib/r27.sh
    source lib/r28.sh
    source lib/r29.sh
    source lib/r30.sh
    source lib/r31.sh
    source lib/r32.sh
    source lib/r33.sh
    source lib/r34.sh
    source lib/r35.sh

    root=$(mktemp -d)
    trap 'rm -rf "$root"' EXIT
    dir="$root/refind-backup"
    mkdir -p "$dir/files/boot/EFI/refind/icons" "$dir/files/boot/EFI/refind/vars" "$dir/files/etc/refind.d"
    printf efi >"$dir/files/boot/EFI/refind/refind_x64.efi"
    cat >"$dir/files/boot/EFI/refind/refind.conf" <<CONF
extra_kernel_version_strings $REFIND_CACHYOS_KERNEL_LIST
CONF
    printf icon >"$dir/files/boot/EFI/refind/icons/os_arch.png"
    printf 'Boot vmlinuz-linux-cachyos from FAT volume\n' >"$dir/files/boot/EFI/refind/vars/PreviousBoot"
    cat >"$dir/files/boot/refind_linux.conf" <<'LINUXCONF'
"Boot with standard options" "root=UUID=ROOT rw quiet nowatchdog splash"
"Boot to single-user mode" "root=UUID=ROOT rw quiet nowatchdog splash single"
LINUXCONF

    format_version=4
    bootloader=refind
    payload_policy=bootloader-owned-paths
    boot_efi_path='\EFI\refind\refind_x64.efi'
    esp_mount=/boot
    reference='BOOT_IMAGE=/vmlinuz-linux-cachyos root=UUID=ROOT rw quiet nowatchdog splash'
    r35_validate_refind_backup_payload "$dir" "$reference" || exit 1

    sed -i 's/ splash"/ splash broken"/' "$dir/files/boot/refind_linux.conf"
    r35_validate_refind_backup_payload "$dir" "$reference" >/dev/null 2>&1 && exit 1
    exit 0
)
pass 'r35 accepts only canonical rEFInd v4 payloads whose backed-up boot options match the proven source runtime'

(
    set +e
    source lib/common.sh
    source lib/storage.sh
    source lib/detect.sh
    source lib/kernels.sh
    source lib/validate.sh
    source lib/limine_validate.sh
    source lib/grub_validate.sh
    source lib/systemd_boot_validate.sh
    source lib/refind_validate.sh
    source lib/backup.sh
    bootloader_display_name() { printf '%s' "$1"; }
    source lib/operations.sh
    source lib/staged.sh
    source lib/r21.sh
    source lib/r22.sh
    source lib/r23.sh
    source lib/restore.sh
    source lib/r25.sh
    source lib/r26.sh
    source lib/r27.sh
    source lib/r28.sh
    source lib/r29.sh
    source lib/r30.sh
    source lib/r31.sh
    source lib/r32.sh
    source lib/r33.sh
    source lib/r34.sh
    source lib/r35.sh

    sudo() {
        [[ ${1:-} == -n ]] && shift
        command "$@"
    }
    root=$(mktemp -d)
    trap 'rm -rf "$root"' EXIT
    src="$root/src"
    dst="$root/esp/EFI/refind"
    mkdir -p "$src/icons" "$src/vars" "$root/esp/EFI"
    printf binary >"$src/refind_x64.efi"
    printf config >"$src/refind.conf"
    printf icon >"$src/icons/os_arch.png"
    printf stale >"$src/vars/PreviousBoot"

    r35_restore_refind_immutable_tree "$src" "$dst" >/dev/null || exit 1
    [[ -f $dst/refind_x64.efi && -f $dst/refind.conf && -f $dst/icons/os_arch.png ]] || exit 1
    [[ ! -e $dst/vars ]] || exit 1
    [[ $(cat "$dst/refind_x64.efi") == binary ]] || exit 1
    exit 0
)
pass 'r35 restores the immutable rEFInd tree byte-for-byte while deliberately dropping stale vars/PreviousBoot evidence'

(
    body=$(declare -f r35_stage_refind_from_backup 2>/dev/null || true)
    [[ -z $body ]] && {
        # Load the full stack only if this test process has no definition.
        source lib/common.sh
        source lib/storage.sh
        source lib/detect.sh
        source lib/kernels.sh
        source lib/validate.sh
        source lib/limine_validate.sh
        source lib/grub_validate.sh
        source lib/systemd_boot_validate.sh
        source lib/refind_validate.sh
        source lib/backup.sh
        bootloader_display_name() { printf '%s' "$1"; }
        source lib/operations.sh
        source lib/staged.sh
        source lib/r21.sh
        source lib/r22.sh
        source lib/r23.sh
        source lib/restore.sh
        source lib/r25.sh
        source lib/r26.sh
        source lib/r27.sh
        source lib/r28.sh
        source lib/r29.sh
        source lib/r30.sh
        source lib/r31.sh
        source lib/r32.sh
        source lib/r33.sh
        source lib/r34.sh
        source lib/r35.sh
        body=$(declare -f r35_stage_refind_from_backup)
    }
    grep -Fq 'sudo refind-install' <<<"$body"
    grep -Fq 'r32_verify_refind_post_install_esp' <<<"$body"
    grep -Fq 'r35_restore_refind_immutable_tree' <<<"$body"
    grep -Fq 'r28_restore_backup_file "$linuxconf" /boot/refind_linux.conf' <<<"$body"
    grep -Fq 'set_source_first_boot_order' <<<"$body"
    grep -Fq 'r26_restore_source_fallback_after_target_stage' <<<"$body"
    grep -Fq 'adapter_target_validate refind' <<<"$body"
    grep -Fq 'r26_record_target_adapter refind' <<<"$body"
)
pass 'r35 restored-rEFInd staging reuses r32 topology proof and the r26 source-first ownership transaction gates'

(
    grep -Fq 'grub:refind) r35_restore_refind_backup "$dir"' lib/r35.sh
    grep -Fq 'transactional rEFInd backup restore currently requires the verified source bootloader to be GRUB' lib/r35.sh
    grep -Fq 'Same-backend rEFInd rollback and non-GRUB restore sources remain deliberately disabled' lib/r35.sh
)
pass 'r35 enables only GRUB -> restored-rEFInd v4 and keeps broader rEFInd restore directions closed'

(
    set +e
    source lib/common.sh
    PENDING_STATE_DIR=$(mktemp -d)
    trap 'rm -rf "$PENDING_STATE_DIR"' EXIT
    R22_RESULT_FILE_NAME=last-auto-result.txt
    pending_exists() { [[ -f "$PENDING_STATE_DIR/pending-migration.tsv" ]]; }
    source lib/r35.sh 2>/dev/null || exit 1
    r35_write_local_transaction_result failed 'old automatic failure' || exit 1
    out=$(r22_show_last_auto_result)
    [[ $out == *'Last recorded transaction event (historical; no migration is pending):'* ]] || exit 1
    [[ $out != *'Last automated transaction result:'* ]] || exit 1
    touch "$PENDING_STATE_DIR/pending-migration.tsv"
    out=$(r22_show_last_auto_result)
    [[ $out == *'Last transaction result:'* ]] || exit 1
    r35_write_local_transaction_result success 'manual finalization won' || exit 1
    grep -Fqx 'status=success' "$PENDING_STATE_DIR/$R22_RESULT_FILE_NAME" || exit 1
    grep -Fqx 'detail=manual finalization won' "$PENDING_STATE_DIR/$R22_RESULT_FILE_NAME" || exit 1
    exit 0
)
pass 'r35 status UI labels stale no-pending records historical and lets successful manual outcomes replace obsolete failures'

(
    grep -Fq 'r35_write_local_transaction_result runtime-validated' lib/r35.sh || exit 1
    body=$(sed -n '/^validate_pending_target_runtime()/,/^}/p' lib/r35.sh)
    [[ $body == *'This exact adapter target state now has runtime proof. FINALIZE is eligible'* ]] || exit 1
    [[ $body != *'predates r21 CachyOS theme parity'* ]] || exit 1
    fbody=$(sed -n '/^r26_finalize_adapter_transaction()/,/^}/p' lib/r35.sh)
    [[ $fbody == *'r35_write_local_transaction_result success'* ]] || exit 1
)
pass 'r35 manual runtime/finalize paths publish truthful status and remove the stale r21 theme-parity message for r26 adapters'

(
    awk '/source "\$SCRIPT_DIR\/lib\/r34.sh"/{a=NR} /source "\$SCRIPT_DIR\/lib\/r35.sh"/{b=NR} END{exit !(a && b && b>a)}' bootloader-switcher.sh
    grep -Fq 'r35: rEFInd v4 restore + truthful transaction status' README.md
    grep -Fq 'GRUB → restored rEFInd v4' README.md
)
pass 'r35 loads after r34 and documents the newly enabled rEFInd restore contract plus status fix'

printf '\nAll r35 regression tests passed.\n'

printf '\nStarting r36 direct rEFInd -> Limine live-adapter regression tests.\n'

(
    set +e
    source lib/common.sh
    source lib/storage.sh
    source lib/detect.sh
    source lib/kernels.sh
    source lib/validate.sh
    source lib/limine_validate.sh
    source lib/grub_validate.sh
    source lib/systemd_boot_validate.sh
    source lib/refind_validate.sh
    source lib/backup.sh
    bootloader_display_name() { printf '%s' "$1"; }
    source lib/operations.sh
    source lib/staged.sh
    source lib/r21.sh
    source lib/r22.sh
    source lib/r23.sh
    source lib/restore.sh
    source lib/r25.sh
    source lib/r26.sh
    source lib/r27.sh
    source lib/r28.sh
    source lib/r29.sh
    source lib/r30.sh
    source lib/r31.sh
    source lib/r32.sh
    source lib/r33.sh
    source lib/r34.sh
    source lib/r35.sh
    source lib/r36.sh

    operation_supported refind limine || exit 1
    operation_supported refind grub || exit 1
    operation_supported grub refind || exit 1
    ! operation_supported limine refind || exit 1
    ! operation_supported refind systemd-boot || exit 1
    exit 0
)
pass 'r36 opens only the rEFInd -> Limine direct live edge and leaves the other non-GRUB live edges closed'

(
    set +e
    source lib/common.sh
    source lib/storage.sh
    source lib/detect.sh
    source lib/kernels.sh
    source lib/validate.sh
    source lib/limine_validate.sh
    source lib/grub_validate.sh
    source lib/systemd_boot_validate.sh
    source lib/refind_validate.sh
    source lib/backup.sh
    bootloader_display_name() { printf '%s' "$1"; }
    source lib/operations.sh
    source lib/staged.sh
    source lib/r21.sh
    source lib/r22.sh
    source lib/r23.sh
    source lib/restore.sh
    source lib/r25.sh
    source lib/r26.sh
    source lib/r27.sh
    source lib/r28.sh
    source lib/r29.sh
    source lib/r30.sh
    source lib/r31.sh
    source lib/r32.sh
    source lib/r33.sh
    source lib/r34.sh
    source lib/r35.sh
    source lib/r36.sh

    root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
    PENDING_STATE_FILE="$root/pending.tsv"
    PENDING_STATE_DIR="$root"
    mkdir -p "$root/snapshot"
    : >"$root/snapshot/source.tsv"
    : >"$root/snapshot/target.tsv"
    # Non-empty ownership records are required by the parser contract.
    printf 'file\t/boot/source\t%s\n' "$(printf a%.0s {1..64})" >"$root/snapshot/source.tsv"
    printf 'file\t/boot/target\t%s\n' "$(printf b%.0s {1..64})" >"$root/snapshot/target.tsv"
    cat >"$PENDING_STATE_FILE" <<STATE
format	5
phase	candidate-ready
created	2026-08-24T12:00:00+03:00
machine_id	machine
source	refind
target	limine
old_boot_id	0000
old_boot_label	rEFInd Boot Manager
old_boot_efi_path	\EFI\refind\refind_x64.efi
old_fallback_path	/boot/EFI/BOOT/BOOTX64.EFI
old_fallback_hash	$(printf c%.0s {1..64})
old_fallback_existed	0
old_fallback_snapshot	
post_stage_fallback_hash	
transaction_snapshot_dir	$root/snapshot
original_boot_order	0000,0001
target_boot_id	0001
target_efi_path	\EFI\LIMINE\limine_x64.efi
target_efi_resolved	/boot/EFI/LIMINE/limine_x64.efi
target_efi_hash	$(printf d%.0s {1..64})
source_efi_resolved	/boot/EFI/refind/refind_x64.efi
source_efi_hash	$(printf e%.0s {1..64})
source_manifest	$root/snapshot/source.tsv
target_manifest	$root/snapshot/target.tsv
source_fallback_owned	0
adapter_revision	1
esp_uuid	ESP
root_uuid	ROOT
esp_source	/dev/sda1
esp_mount	/boot
backup_path	
source_cmdline	root=UUID=ROOT rw quiet
STATE
    load_pending_state || exit 1
    [[ $PENDING_SOURCE == refind && $PENDING_TARGET == limine && $PENDING_REASON == valid ]] || exit 1
    exit 0
)
pass 'r36 format-5 pending-state parser admits the new rEFInd -> Limine transaction direction'

(
    set +e
    source lib/common.sh
    source lib/storage.sh
    source lib/detect.sh
    source lib/kernels.sh
    source lib/validate.sh
    source lib/limine_validate.sh
    source lib/grub_validate.sh
    source lib/systemd_boot_validate.sh
    source lib/refind_validate.sh
    source lib/backup.sh
    bootloader_display_name() { printf '%s' "$1"; }
    source lib/operations.sh
    source lib/staged.sh
    source lib/r21.sh
    source lib/r22.sh
    source lib/r23.sh
    source lib/restore.sh
    source lib/r25.sh
    source lib/r26.sh
    source lib/r27.sh
    source lib/r28.sh
    source lib/r29.sh
    source lib/r30.sh
    source lib/r31.sh
    source lib/r32.sh
    source lib/r33.sh
    source lib/r34.sh
    source lib/r35.sh
    source lib/r36.sh

    trace=$(mktemp); trap 'rm -f "$trace"' EXIT
    install_target_packages() { printf 'packages\n' >>"$trace"; return 0; }
    have() { return 0; }
    write_limine_candidate_policy() { printf 'policy\n' >>"$trace"; return 0; }
    stage_limine_kernel_entries_from_existing_artifacts() { printf 'kernels\n' >>"$trace"; return 0; }
    sudo() {
        if [[ ${1:-} == limine-install ]]; then printf 'limine-install %s\n' "${2:-normal}" >>"$trace"; return 0; fi
        command "$@"
    }
    find_nvram_entry_for_target() { [[ $1 == limine ]] || return 1; TARGET_NVRAM_ID=00A5; return 0; }
    set_source_first_boot_order() { printf 'source-first %s %s\n' "$1" "$2" >>"$trace"; return 0; }
    r26_restore_source_fallback_after_target_stage() { printf 'restore-source-fallback\n' >>"$trace"; return 0; }
    adapter_target_validate() { [[ $1 == limine ]] || return 1; printf 'target-validate\n' >>"$trace"; return 0; }
    r26_record_target_adapter() { [[ $1 == limine ]] || return 1; printf 'target-manifest\n' >>"$trace"; return 0; }

    R26_STAGED_TARGET_ID=''
    r36_stage_limine_target 0000 '0000,0002' 'root=UUID=ROOT rw quiet' || exit 1
    [[ $R26_STAGED_TARGET_ID == 00A5 ]] || exit 1
    expected=$'packages\npolicy\nkernels\nlimine-install normal\nlimine-install --fallback\nsource-first 0000 00A5\nrestore-source-fallback\ntarget-validate\ntarget-manifest'
    [[ $(cat "$trace") == "$expected" ]] || { cat "$trace" >&2; exit 1; }
    exit 0
)
pass 'r36 fresh Limine target stage restores source-first/fallback state before recording the deeply validated candidate'

(
    set +e
    source lib/common.sh
    source lib/r36.sh 2>/dev/null || true
    root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
    ESP_MOUNT="$root/boot"
    mkdir -p "$ESP_MOUNT"
    find_nvram_entry_for_target() { return 1; }
    r26_adapter_paths() { printf '%s\n' "$ESP_MOUNT/EFI/LIMINE" "$ESP_MOUNT/limine.conf"; }
    validate_existing_boot_artifacts_for_limine_stage() { return 0; }
    sudo() { [[ ${1:-} == -n ]] && shift; command "$@"; }
    r36_limine_live_target_clean || exit 1
    mkdir -p "$ESP_MOUNT/EFI/LIMINE"
    r36_limine_live_target_clean >/dev/null 2>&1 && exit 1
    exit 0
)
pass 'r36 fresh live Limine gate refuses pre-existing adapter-owned Limine residue instead of guessing ownership'

(
    grep -Fq 'SWITCHER_RELEASE="r47"' bootloader-switcher.sh
    awk '/source "\$SCRIPT_DIR\/lib\/r36.sh"/{a=NR} /source "\$SCRIPT_DIR\/lib\/r37.sh"/{b=NR} END{exit !(a && b && b>a)}' bootloader-switcher.sh
    grep -Fq 'Executing %s adapter transaction...' lib/r26.sh
    grep -Fq '"${SWITCHER_RELEASE:-r26}"' lib/r26.sh
    ! grep -Fq "printf '\nExecuting r26 adapter transaction...\n'" lib/r26.sh
    grep -Fq 'r37: transactionally preserve inactive Limine residue' README.md
    grep -Fq 'rEFInd → Limine' README.md
)
pass 'r37 keeps active user-facing revision labels centralized on SWITCHER_RELEASE and documents residue-aware staging'

printf '\nStarting r37 inactive-Limine-residue regression tests.\n'

(
    set +e
    source lib/common.sh
    source lib/r37.sh 2>/dev/null || true
    root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
    ESP_MOUNT="$root/boot"
    mkdir -p "$ESP_MOUNT/EFI/LIMINE"
    printf old >"$ESP_MOUNT/EFI/LIMINE/limine_x64.efi"
    find_nvram_entry_for_target() { return 1; }
    r26_adapter_paths() { printf '%s\n' "$ESP_MOUNT/EFI/LIMINE" "$ESP_MOUNT/limine.conf"; }
    validate_existing_boot_artifacts_for_limine_stage() { return 0; }
    info() { :; }
    ok() { :; }
    fail() { :; }
    sudo() { [[ ${1:-} == -n ]] && shift; command "$@"; }
    r37_limine_live_target_preflight || exit 1
    [[ -f "$ESP_MOUNT/EFI/LIMINE/limine_x64.efi" ]] || exit 1
    exit 0
)
pass 'r37 read-only live preflight accepts safe inactive Limine filesystem residue without mutating it'

(
    set +e
    source lib/common.sh
    source lib/r37.sh 2>/dev/null || true
    root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
    ESP_MOUNT="$root/boot"
    mkdir -p "$ESP_MOUNT/EFI"
    mkdir -p "$root/real-limine"
    ln -s "$root/real-limine" "$ESP_MOUNT/EFI/LIMINE"
    find_nvram_entry_for_target() { return 1; }
    r26_adapter_paths() { printf '%s\n' "$ESP_MOUNT/EFI/LIMINE"; }
    validate_existing_boot_artifacts_for_limine_stage() { return 0; }
    info() { :; }
    ok() { :; }
    fail() { :; }
    sudo() { [[ ${1:-} == -n ]] && shift; command "$@"; }
    r37_limine_live_target_preflight >/dev/null 2>&1 && exit 1
    exit 0
)
pass 'r37 refuses symlinked inactive Limine residue before the write boundary'

(
    set +e
    source lib/common.sh
    source lib/r37.sh 2>/dev/null || true
    find_nvram_entry_for_target() { TARGET_NVRAM_ID=00AA; return 0; }
    r26_adapter_paths() { :; }
    validate_existing_boot_artifacts_for_limine_stage() { return 0; }
    fail() { :; }
    r37_limine_live_target_preflight >/dev/null 2>&1 && exit 1
    exit 0
)
pass 'r37 still refuses a pre-existing canonical Limine NVRAM entry as non-losslessly-quarantinable firmware state'

(
    set +e
    source lib/common.sh
    # Minimal function stubs required before loading the layered override.
    adapter_target_stage() { return 91; }
    rollback_pending_candidate() { return 92; }
    show_operation_plan() { return 93; }
    source lib/r37.sh
    root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
    TRANSACTION_SNAPSHOT_DIR="$root/snapshot"; mkdir -p "$TRANSACTION_SNAPSHOT_DIR"
    BOOTLOADER=refind
    trace="$root/trace"
    r30_prepare_limine_target_residue() { printf 'quarantine\n' >>"$trace"; return 0; }
    r36_stage_limine_target() { printf 'stage\n' >>"$trace"; R26_STAGED_TARGET_ID=00A5; return 0; }
    adapter_target_stage limine 0000 '0000,0001' 'root=UUID=ROOT rw quiet' || exit 1
    [[ $(cat "$trace") == $'quarantine\nstage' ]] || exit 1
    exit 0
)
pass 'r37 interposes residue quarantine only after the source transaction snapshot exists and before fresh Limine staging'

(
    set +e
    source lib/common.sh
    source lib/backup.sh
    source lib/restore.sh
    # r30 helper only needs these globals/helpers for this isolated round-trip.
    R30_LIMINE_RESIDUE_SUBDIR=r30-limine-target-residue
    r30_limine_residue_root() {
        local snapshot=${1:-${TRANSACTION_SNAPSHOT_DIR:-}}
        [[ -n $snapshot ]] || return 1
        printf '%s/%s\n' "$snapshot" "$R30_LIMINE_RESIDUE_SUBDIR"
    }
    # Extract the actual r30 implementations rather than reimplementing test logic.
    eval "$(declare -f r30_prepare_limine_target_residue 2>/dev/null || true)"
    # They are not loaded yet in this isolated shell; source the real layer with
    # harmless prerequisites for its top-level overrides.
    r26_remove_uncommitted_target_namespaces() { :; }
    rollback_pending_candidate() { :; }
    r26_finalize_target_fallback() { :; }
    source lib/r30.sh >/dev/null 2>&1 || exit 1
    root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
    ESP_MOUNT="$root/boot"; TRANSACTION_SNAPSHOT_DIR="$root/tx"
    mkdir -p "$ESP_MOUNT/EFI/LIMINE" "$TRANSACTION_SNAPSHOT_DIR"
    printf 'old-efi' >"$ESP_MOUNT/EFI/LIMINE/limine_x64.efi"
    printf 'old-conf' >"$ESP_MOUNT/limine.conf"
    r26_adapter_paths() { printf '%s\n' "$ESP_MOUNT/EFI/LIMINE" "$ESP_MOUNT/limine.conf"; }
    sudo() { [[ ${1:-} == -n ]] && shift; command "$@"; }
    r30_prepare_limine_target_residue || exit 1
    [[ ! -e "$ESP_MOUNT/EFI/LIMINE" && ! -e "$ESP_MOUNT/limine.conf" ]] || exit 1
    mkdir -p "$ESP_MOUNT/EFI/LIMINE"
    printf 'candidate' >"$ESP_MOUNT/EFI/LIMINE/limine_x64.efi"
    printf 'candidate-conf' >"$ESP_MOUNT/limine.conf"
    r30_restore_limine_target_residue "$TRANSACTION_SNAPSHOT_DIR" || exit 1
    [[ $(cat "$ESP_MOUNT/EFI/LIMINE/limine_x64.efi") == old-efi ]] || exit 1
    [[ $(cat "$ESP_MOUNT/limine.conf") == old-conf ]] || exit 1
    exit 0
)
pass 'r37 reuses the r30 transaction snapshot to restore exact inactive Limine filesystem residue over a failed candidate'

(
    grep -Fq 'SWITCHER_RELEASE="r47"' bootloader-switcher.sh
    grep -Fq 'source "$SCRIPT_DIR/lib/r37.sh"' bootloader-switcher.sh
    grep -Fq 'r30_prepare_limine_target_residue' lib/r37.sh
    grep -Fq 'r30_restore_limine_target_residue' lib/r37.sh
    grep -Fq 'PENDING_SOURCE == refind && $PENDING_TARGET == limine' lib/r37.sh
    grep -Fq '**r37 hardware result (superseded by r39 retest requirement):**' README.md
)
pass 'r37 residue-aware live rollback remains loaded beneath r38 after the live edge earned hardware proof'

printf '\nAll r37 regression tests passed.\n'


printf '\nStarting r38 Limine <-> rEFInd backup-restore regression tests.\n'

(
    set +e
    source lib/common.sh
    source lib/storage.sh
    source lib/detect.sh
    source lib/kernels.sh
    source lib/validate.sh
    source lib/limine_validate.sh
    source lib/grub_validate.sh
    source lib/systemd_boot_validate.sh
    source lib/refind_validate.sh
    source lib/backup.sh
    bootloader_display_name() { printf '%s' "$1"; }
    source lib/operations.sh
    source lib/staged.sh
    source lib/r21.sh
    source lib/r22.sh
    source lib/r23.sh
    source lib/restore.sh
    source lib/r25.sh
    source lib/r26.sh
    source lib/r27.sh
    source lib/r28.sh
    source lib/r29.sh
    source lib/r30.sh
    source lib/r31.sh
    source lib/r32.sh
    source lib/r33.sh
    source lib/r34.sh
    source lib/r35.sh
    source lib/r36.sh
    source lib/r37.sh
    source lib/r38.sh

    r30_cross_restore_supported limine refind || exit 1
    r30_cross_restore_supported refind limine || exit 1
    r30_cross_restore_supported grub limine || exit 1
    ! r30_cross_restore_supported refind systemd-boot || exit 1
    ! r30_cross_restore_supported systemd-boot refind || exit 1
    exit 0
)
pass 'r38 opens only the Limine <-> rEFInd backup-restore matrix extension and preserves existing restore routes'

(
    set +e
    source lib/common.sh
    source lib/storage.sh
    source lib/detect.sh
    source lib/kernels.sh
    source lib/validate.sh
    source lib/limine_validate.sh
    source lib/grub_validate.sh
    source lib/systemd_boot_validate.sh
    source lib/refind_validate.sh
    source lib/backup.sh
    bootloader_display_name() { printf '%s' "$1"; }
    source lib/operations.sh
    source lib/staged.sh
    source lib/r21.sh
    source lib/r22.sh
    source lib/r23.sh
    source lib/restore.sh
    source lib/r25.sh
    source lib/r26.sh
    source lib/r27.sh
    source lib/r28.sh
    source lib/r29.sh
    source lib/r30.sh
    source lib/r31.sh
    source lib/r32.sh
    source lib/r33.sh
    source lib/r34.sh
    source lib/r35.sh
    source lib/r36.sh
    source lib/r37.sh
    source lib/r38.sh

    root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
    PENDING_STATE_FILE="$root/pending.tsv"
    PENDING_STATE_DIR="$root"
    mkdir -p "$root/snapshot"
    printf 'file\t/boot/source\t%s\n' "$(printf a%.0s {1..64})" >"$root/snapshot/source.tsv"
    printf 'file\t/boot/target\t%s\n' "$(printf b%.0s {1..64})" >"$root/snapshot/target.tsv"
    cat >"$PENDING_STATE_FILE" <<STATE
format	5
phase	candidate-ready
created	2026-08-24T13:30:00+03:00
machine_id	machine
source	limine
target	refind
old_boot_id	0001
old_boot_label	Limine
old_boot_efi_path	\EFI\LIMINE\limine_x64.efi
old_fallback_path	/boot/EFI/BOOT/BOOTX64.EFI
old_fallback_hash	$(printf c%.0s {1..64})
old_fallback_existed	1
old_fallback_snapshot	$root/snapshot/BOOTX64.EFI.before
post_stage_fallback_hash	$(printf c%.0s {1..64})
transaction_snapshot_dir	$root/snapshot
original_boot_order	0001
 target_boot_id	0000
STATE
    # Replace the accidentally spaced key and append the remaining canonical fields.
    sed -i 's/^ target_boot_id/target_boot_id/' "$PENDING_STATE_FILE"
    cat >>"$PENDING_STATE_FILE" <<STATE
target_efi_path	\EFI\refind\refind_x64.efi
target_efi_resolved	/boot/EFI/refind/refind_x64.efi
target_efi_hash	$(printf d%.0s {1..64})
source_efi_resolved	/boot/EFI/LIMINE/limine_x64.efi
source_efi_hash	$(printf e%.0s {1..64})
source_manifest	$root/snapshot/source.tsv
target_manifest	$root/snapshot/target.tsv
source_fallback_owned	1
adapter_revision	1
esp_uuid	ESP
root_uuid	ROOT
esp_source	/dev/sda1
esp_mount	/boot
backup_path	/backups/refind-v4
source_cmdline	root=UUID=ROOT rw quiet
STATE
    printf 'fallback' >"$root/snapshot/BOOTX64.EFI.before"
    load_pending_state || exit 1
    [[ $PENDING_SOURCE == limine && $PENDING_TARGET == refind && $PENDING_REASON == valid ]] || exit 1
    exit 0
)
pass 'r38 format-5 pending-state parser admits Limine -> restored-rEFInd transactions across reboot'

(
    set +e
    source lib/common.sh
    source lib/storage.sh
    source lib/detect.sh
    source lib/kernels.sh
    source lib/validate.sh
    source lib/limine_validate.sh
    source lib/grub_validate.sh
    source lib/systemd_boot_validate.sh
    source lib/refind_validate.sh
    source lib/backup.sh
    bootloader_display_name() { printf '%s' "$1"; }
    source lib/operations.sh
    source lib/staged.sh
    source lib/r21.sh
    source lib/r22.sh
    source lib/r23.sh
    source lib/restore.sh
    source lib/r25.sh
    source lib/r26.sh
    source lib/r27.sh
    source lib/r28.sh
    source lib/r29.sh
    source lib/r30.sh
    source lib/r31.sh
    source lib/r32.sh
    source lib/r33.sh
    source lib/r34.sh
    source lib/r35.sh
    source lib/r36.sh
    source lib/r37.sh
    source lib/r38.sh

    BOOTLOADER=limine BOOT_CURRENT=0001 BOOT_NEXT='' ESP_MOUNT=/boot
    pending_exists() { return 1; }
    validate_backup_compatibility() { return 0; }
    load_backup_metadata() { bootloader=refind; format_version=4; esp_mount=/boot; return 0; }
    detect_bootloader() { BOOTLOADER=limine; BOOT_CURRENT=0001; }
    run_validation() { return 0; }
    is_cachyos() { return 0; }
    bootcurrent_is_generic_fallback() { return 1; }
    have() { return 0; }
    adapter_source_validate() { [[ $1 == limine ]]; }
    r26_target_namespace_clean() { [[ $1 == refind ]]; }
    r35_refind_backup_kernel_set_matches() { return 0; }
    r35_validate_refind_backup_payload() { return 0; }
    ok() { :; }
    info() { :; }
    fail() { printf '%s\n' "$*" >&2; }

    r35_refind_restore_preflight /fake/refind-v4 || exit 1
    exit 0
)
pass 'r38 generalizes the strict rEFInd-v4 restore preflight to a deeply validated Limine source'

(
    grep -Fq 'grub:refind|limine:refind) r38_restore_refind_backup "$dir"' lib/r38.sh || exit 1
    grep -Fq 'refind:limine) r30_restore_limine_backup "$dir"' lib/r38.sh || exit 1
    grep -Fq 'Limine -> rEFInd *live migration*' lib/r38.sh || exit 1
    grep -Fq 'SWITCHER_RELEASE="r47"' bootloader-switcher.sh || exit 1
    grep -Fq 'source "$SCRIPT_DIR/lib/r38.sh"' bootloader-switcher.sh || exit 1
    grep -Fq 'r38: bidirectional Limine' README.md || exit 1
)
pass 'r38 package wires both requested backup-restore directions without silently enabling the separate Limine -> rEFInd live edge'



(
    set +e
    source lib/common.sh
    source lib/storage.sh
    source lib/detect.sh
    source lib/kernels.sh
    source lib/validate.sh
    source lib/limine_validate.sh
    source lib/grub_validate.sh
    source lib/systemd_boot_validate.sh
    source lib/refind_validate.sh
    source lib/backup.sh
    bootloader_display_name() { printf '%s' "$1"; }
    source lib/operations.sh
    source lib/staged.sh
    source lib/r21.sh
    source lib/r22.sh
    source lib/r23.sh
    source lib/restore.sh
    source lib/r25.sh
    source lib/r26.sh
    source lib/r27.sh
    source lib/r28.sh
    source lib/r29.sh
    source lib/r30.sh
    source lib/r31.sh
    source lib/r32.sh
    source lib/r33.sh
    source lib/r34.sh
    source lib/r35.sh
    source lib/r36.sh
    source lib/r37.sh
    source lib/r38.sh
    source lib/r39.sh

    root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
    conf="$root/limine.conf" out="$root/out.conf" count="$root/count"
    cat >"$conf" <<'CONF'
timeout: 5
/+CachyOS
  //linux-cachyos
  protocol: linux
  path: boot():/machine/linux-cachyos/vmlinuz#abcdef
  //rEFInd
  ### This EFI entry is auto-generated by limine-entry-tool
  comment: rEFInd bootloader
  protocol: efi
  path: boot():/EFI/refind/refind_x64.efi
  //Other EFI
  protocol: efi
  path: boot():/EFI/other/other_x64.efi
/EFI fallback
protocol: efi
path: boot():/EFI/BOOT/BOOTX64.EFI
CONF
    [[ $(r39_limine_source_reference_count "$conf" '\EFI\refind\refind_x64.efi') == 1 ]] || exit 1
    r39_strip_limine_source_entries "$conf" '\EFI\refind\refind_x64.efi' "$out" "$count" || exit 1
    [[ $(cat "$count") == 1 ]] || exit 1
    ! grep -Fq 'rEFInd bootloader' "$out" || exit 1
    ! grep -Fiq 'EFI/refind/refind_x64.efi' "$out" || exit 1
    grep -Fq 'linux-cachyos' "$out" || exit 1
    grep -Fq 'EFI/other/other_x64.efi' "$out" || exit 1
    grep -Fq 'EFI/BOOT/BOOTX64.EFI' "$out" || exit 1
    exit 0
)
pass 'r39 removes only the stale source-EFI Limine menu chunk and preserves kernels, foreign EFI entries, and generic fallback'

(
    grep -Fq 'SWITCHER_RELEASE="r47"' bootloader-switcher.sh || exit 1
    grep -Fq 'source "$SCRIPT_DIR/lib/r39.sh"' bootloader-switcher.sh || exit 1
    grep -Fq 'r39: Limine post-retirement menu reconciliation' README.md || exit 1
    grep -Fq 'r39_reconcile_limine_before_source_retirement' lib/r39.sh || exit 1
    grep -Fq 'r39_verify_limine_no_source_reference' lib/r39.sh || exit 1
)
pass 'r39 package wires pre-retirement Limine reconciliation and the post-retirement no-zombie invariant'

printf '\nAll r39 regression tests passed.\n'


printf '\nStarting r40 direct Limine -> rEFInd live-adapter regression tests.\n'

(
    set +e
    source lib/common.sh
    source lib/storage.sh
    source lib/detect.sh
    source lib/kernels.sh
    source lib/validate.sh
    source lib/limine_validate.sh
    source lib/grub_validate.sh
    source lib/systemd_boot_validate.sh
    source lib/refind_validate.sh
    source lib/backup.sh
    bootloader_display_name() { printf '%s' "$1"; }
    source lib/operations.sh
    source lib/staged.sh
    source lib/r21.sh
    source lib/r22.sh
    source lib/r23.sh
    source lib/restore.sh
    source lib/r25.sh
    source lib/r26.sh
    source lib/r27.sh
    source lib/r28.sh
    source lib/r29.sh
    source lib/r30.sh
    source lib/r31.sh
    source lib/r32.sh
    source lib/r33.sh
    source lib/r34.sh
    source lib/r35.sh
    source lib/r36.sh
    source lib/r37.sh
    source lib/r38.sh
    source lib/r39.sh
    source lib/r40.sh

    operation_supported limine refind || exit 1
    operation_supported refind limine || exit 1
    operation_supported limine grub || exit 1
    ! operation_supported limine systemd-boot || exit 1
    ! operation_supported systemd-boot refind || exit 1
    ! operation_supported refind systemd-boot || exit 1
    exit 0
)
pass 'r40 opens only the Limine -> rEFInd direct live edge while preserving the rEFInd -> Limine edge and keeping systemd-boot non-GRUB live edges closed'

(
    set +e
    source lib/common.sh
    source lib/storage.sh
    source lib/detect.sh
    source lib/kernels.sh
    source lib/validate.sh
    source lib/limine_validate.sh
    source lib/grub_validate.sh
    source lib/systemd_boot_validate.sh
    source lib/refind_validate.sh
    source lib/backup.sh
    bootloader_display_name() { case "$1" in limine) printf 'Limine';; refind) printf 'rEFInd';; *) printf '%s' "$1";; esac; }
    source lib/operations.sh
    source lib/staged.sh
    source lib/r21.sh
    source lib/r22.sh
    source lib/r23.sh
    source lib/restore.sh
    source lib/r25.sh
    source lib/r26.sh
    source lib/r27.sh
    source lib/r28.sh
    source lib/r29.sh
    source lib/r30.sh
    source lib/r31.sh
    source lib/r32.sh
    source lib/r33.sh
    source lib/r34.sh
    source lib/r35.sh
    source lib/r36.sh
    source lib/r37.sh
    source lib/r38.sh
    source lib/r39.sh
    source lib/r40.sh

    BOOTLOADER=limine BOOT_CURRENT=0001 BOOT_NEXT='' ESP_MOUNT=/boot
    run_validation() { [[ $1 == preflight ]]; }
    is_cachyos() { return 0; }
    bootcurrent_is_generic_fallback() { return 1; }
    have() { return 0; }
    pending_exists() { return 1; }
    adapter_source_validate() { [[ $1 == limine ]]; }
    r26_target_namespace_clean() { [[ $1 == refind ]]; }
    fail() { printf '%s\n' "$*" >&2; }

    r26_generic_preflight refind || exit 1
    BOOT_NEXT=00AA
    r26_generic_preflight refind >/dev/null 2>&1 && exit 1
    exit 0
)
pass 'r40 Limine -> rEFInd live preflight requires canonical Limine source proof, an empty rEFInd namespace, and no pre-existing BootNext intent'

(
    set +e
    source lib/common.sh
    source lib/r40.sh 2>/dev/null || true
    trace=$(mktemp); trap 'rm -f "$trace"' EXIT
    BOOTLOADER=limine
    r26_generic_preflight() { [[ $1 == refind ]] || return 1; printf 'preflight\n' >>"$trace"; }
    offer_operation_backup() { printf 'backup-offer\n' >>"$trace"; }
    show_operation_plan() { [[ $1 == limine && $2 == refind ]] || return 1; printf 'plan\n' >>"$trace"; }
    confirm_operation() { [[ $1 == limine && $2 == refind ]] || return 1; printf 'confirm\n' >>"$trace"; }
    r26_execute_adapter_switch() { [[ $1 == refind ]] || return 1; printf 'execute-refind\n' >>"$trace"; }
    run_live_operation_pre_r40() { printf 'wrong-fallback\n' >>"$trace"; return 9; }
    SWITCHER_RELEASE=r40

    run_live_operation refind >/dev/null || exit 1
    expected=$'preflight\nbackup-offer\nplan\nconfirm\nexecute-refind'
    [[ $(cat "$trace") == "$expected" ]] || { cat "$trace" >&2; exit 1; }
    exit 0
)
pass 'r40 routes Limine -> rEFInd through the generic source-preserving adapter transaction instead of the historical refusal path'

(
    grep -Fq 'SWITCHER_RELEASE="r47"' bootloader-switcher.sh || exit 1
    grep -Fq 'source "$SCRIPT_DIR/lib/r40.sh"' bootloader-switcher.sh || exit 1
    awk '/source "\$SCRIPT_DIR\/lib\/r39.sh"/{a=NR} /source "\$SCRIPT_DIR\/lib\/r40.sh"/{b=NR} END{exit !(a && b && b>a)}' bootloader-switcher.sh || exit 1
    grep -Fq '## r40: direct Limine → rEFInd live migration' README.md || exit 1
    grep -Fq 'Limine | rEFInd | **Enabled — r40 hardware-proven**' README.md || exit 1
    grep -Fq 'Limine -> rEFInd live migration (hardware-proven)' bootloader-switcher.sh || exit 1
)
pass 'r40 historical package wiring remains documented while the current release records its hardware proof'

printf '\nAll r40 regression tests passed.\n'

printf '\nStarting r41 complete systemd-boot/non-GRUB live-matrix regression tests.\n'

(
    set +e
    source lib/common.sh
    source lib/storage.sh
    source lib/detect.sh
    source lib/kernels.sh
    source lib/validate.sh
    source lib/limine_validate.sh
    source lib/grub_validate.sh
    source lib/systemd_boot_validate.sh
    source lib/refind_validate.sh
    source lib/backup.sh
    bootloader_display_name() { printf '%s' "$1"; }
    source lib/operations.sh
    source lib/staged.sh
    source lib/r21.sh
    source lib/r22.sh
    source lib/r23.sh
    source lib/restore.sh
    source lib/r25.sh
    source lib/r26.sh
    source lib/r27.sh
    source lib/r28.sh
    source lib/r29.sh
    source lib/r30.sh
    source lib/r31.sh
    source lib/r32.sh
    source lib/r33.sh
    source lib/r34.sh
    source lib/r35.sh
    source lib/r36.sh
    source lib/r37.sh
    source lib/r38.sh
    source lib/r39.sh
    source lib/r40.sh
    source lib/r41.sh

    operation_supported limine systemd-boot || exit 1
    operation_supported systemd-boot limine || exit 1
    operation_supported refind systemd-boot || exit 1
    operation_supported systemd-boot refind || exit 1

    # Existing proven edges must remain enabled too.
    operation_supported grub systemd-boot || exit 1
    operation_supported systemd-boot grub || exit 1
    operation_supported limine refind || exit 1
    operation_supported refind limine || exit 1
    ! operation_supported systemd-boot systemd-boot || exit 1
    ! operation_supported refind refind || exit 1
    exit 0
)
pass 'r41 opens exactly the four remaining systemd-boot/non-GRUB live directions without creating same-backend switches'

(
    set +e
    R26_PENDING_FORMAT=5
    R26_ADAPTER_REVISION=1
    PENDING_FORMAT=5
    PENDING_ADAPTER_REVISION=1
    PENDING_MACHINE_ID=machine
    PENDING_OLD_BOOT_ID=0001
    PENDING_TARGET_BOOT_ID=0002
    PENDING_SOURCE_CMDLINE='root=UUID=x rw quiet'
    PENDING_SOURCE_MANIFEST=/tmp/source.tsv
    PENDING_TARGET_MANIFEST=/tmp/target.tsv
    PENDING_REASON=''
    PENDING_SOURCE=''
    PENDING_TARGET=''
    r26_state_format() { printf '5\n'; }
    load_pending_state() {
        PENDING_REASON='unsupported r26 adapter migration direction'
        return 1
    }
    r26_generic_preflight() { return 0; }
    adapter_target_stage() { return 0; }
    operation_supported() { return 1; }
    show_operation_plan() { return 0; }
    run_live_operation() { return 0; }
    source lib/r41.sh

    PENDING_SOURCE=refind PENDING_TARGET=systemd-boot PENDING_REASON=''
    load_pending_state || exit 1
    [[ $PENDING_REASON == valid ]] || exit 1

    PENDING_SOURCE=systemd-boot PENDING_TARGET=refind PENDING_REASON=''
    load_pending_state || exit 1
    [[ $PENDING_REASON == valid ]] || exit 1

    PENDING_SOURCE=refind PENDING_TARGET=bogus PENDING_REASON=''
    load_pending_state >/dev/null 2>&1 && exit 1
    exit 0
)
pass 'r41 format-v5 parser admits only the new rEFInd <-> systemd-boot live state beyond inherited directions'

(
    set +e
    trace=$(mktemp); trap 'rm -f "$trace"' EXIT
    r26_state_format() { printf '0\n'; }
    load_pending_state() { return 1; }
    r26_generic_preflight() { printf 'old-preflight:%s\n' "$1" >>"$trace"; return 0; }
    adapter_target_stage() { printf 'old-stage:%s\n' "$1" >>"$trace"; return 0; }
    operation_supported() { return 1; }
    show_operation_plan() { return 0; }
    run_live_operation() { return 0; }
    source lib/r41.sh

    run_validation() { [[ $1 == preflight ]]; }
    is_cachyos() { return 0; }
    bootcurrent_is_generic_fallback() { return 1; }
    have() { return 0; }
    pending_exists() { return 1; }
    adapter_source_validate() { printf 'source:%s\n' "$1" >>"$trace"; return 0; }
    r26_target_namespace_clean() { printf 'clean:%s\n' "$1" >>"$trace"; return 0; }
    r37_limine_live_target_preflight() { printf 'limine-residue-gate\n' >>"$trace"; return 0; }
    bootloader_display_name() { printf '%s' "$1"; }
    fail() { return 1; }
    BOOT_NEXT=''

    BOOTLOADER=limine
    r26_generic_preflight systemd-boot >/dev/null || exit 1
    BOOTLOADER=refind
    r26_generic_preflight systemd-boot >/dev/null || exit 1
    BOOTLOADER=systemd-boot
    r26_generic_preflight refind >/dev/null || exit 1
    r26_generic_preflight limine >/dev/null || exit 1

    expected=$'source:limine\nclean:systemd-boot\nsource:refind\nclean:systemd-boot\nsource:systemd-boot\nclean:refind\nsource:systemd-boot\nlimine-residue-gate'
    [[ $(cat "$trace") == "$expected" ]] || { cat "$trace" >&2; exit 1; }
    exit 0
)
pass 'r41 preflight deep-validates each source and uses clean target gates except the residue-aware Limine target gate'

(
    set +e
    trace=$(mktemp); snap=$(mktemp -d); trap 'rm -f "$trace"; rm -rf "$snap"' EXIT
    r26_state_format() { printf '0\n'; }
    load_pending_state() { return 1; }
    r26_generic_preflight() { return 0; }
    adapter_target_stage() { printf 'old-stage:%s\n' "$1" >>"$trace"; return 0; }
    operation_supported() { return 1; }
    show_operation_plan() { return 0; }
    run_live_operation() { return 0; }
    source lib/r41.sh

    BOOTLOADER=systemd-boot
    TRANSACTION_SNAPSHOT_DIR=$snap
    r30_prepare_limine_target_residue() { printf 'quarantine\n' >>"$trace"; return 0; }
    r36_stage_limine_target() { printf 'stage-limine:%s:%s:%s\n' "$1" "$2" "$3" >>"$trace"; return 0; }
    fail() { printf 'fail:%s\n' "$*" >>"$trace"; return 1; }

    adapter_target_stage limine 0001 0001,0002 'root=UUID=x rw' || exit 1
    expected=$'quarantine\nstage-limine:0001:0001,0002:root=UUID=x rw'
    [[ $(cat "$trace") == "$expected" ]] || { cat "$trace" >&2; exit 1; }
    exit 0
)
pass 'r41 systemd-boot -> Limine staging quarantines inactive Limine residue only after the authoritative source snapshot exists'

(
    set +e
    r26_state_format() { printf '0\n'; }
    load_pending_state() { return 1; }
    r26_generic_preflight() { return 0; }
    adapter_target_stage() { return 0; }
    operation_supported() { return 1; }
    show_operation_plan() { return 0; }
    run_live_operation() { return 0; }
    source lib/r41.sh
    trace=$(mktemp); trap 'rm -f "$trace"' EXIT

    r26_generic_preflight() { printf 'preflight:%s\n' "$1" >>"$trace"; }
    offer_operation_backup() { printf 'backup\n' >>"$trace"; }
    show_operation_plan() { printf 'plan:%s:%s\n' "$1" "$2" >>"$trace"; }
    confirm_operation() { printf 'confirm:%s:%s\n' "$1" "$2" >>"$trace"; }
    r26_execute_adapter_switch() { printf 'execute:%s\n' "$1" >>"$trace"; }
    run_live_operation_pre_r41() { printf 'old:%s\n' "$1" >>"$trace"; return 9; }
    SWITCHER_RELEASE=r41

    for pair in 'limine systemd-boot' 'systemd-boot limine' 'refind systemd-boot' 'systemd-boot refind'; do
        set -- $pair
        BOOTLOADER=$1
        run_live_operation "$2" >/dev/null || exit 1
    done
    grep -Fq 'execute:systemd-boot' "$trace" || exit 1
    grep -Fq 'execute:limine' "$trace" || exit 1
    grep -Fq 'execute:refind' "$trace" || exit 1
    ! grep -Fq 'old:' "$trace" || exit 1
    exit 0
)
pass 'r41 routes all four new live directions through the shared source-preserving adapter executor'

(
    grep -Fq 'SWITCHER_RELEASE="r47"' bootloader-switcher.sh || exit 1
    grep -Fq 'source "$SCRIPT_DIR/lib/r41.sh"' bootloader-switcher.sh || exit 1
    awk '/source "\$SCRIPT_DIR\/lib\/r40.sh"/{a=NR} /source "\$SCRIPT_DIR\/lib\/r41.sh"/{b=NR} END{exit !(a && b && b>a)}' bootloader-switcher.sh || exit 1
    grep -Fq '## r41: complete the direct live matrix with systemd-boot' README.md || exit 1
    grep -Fq 'Limine | systemd-boot | **Hardware-proven on r41**' README.md || exit 1
    grep -Fq 'systemd-boot | Limine | **Hardware-proven on r41**' README.md || exit 1
    grep -Fq 'rEFInd | systemd-boot | **Hardware-proven on r42**' README.md || exit 1
    grep -Fq 'systemd-boot | rEFInd | **Hardware-proven on r42**' README.md || exit 1
    grep -Fq '### Why the previous bootloader may still appear on the first target boot' README.md || exit 1
    grep -Fq 'The **next reboot merely displays the already-finalized configuration**' README.md || exit 1
    grep -Fq 'r41 opened the four remaining direct live systemd-boot/non-GRUB edges' bootloader-switcher.sh || exit 1
    ! grep -Fq 'r41_stage_limine_target_from_systemd_boot' lib/r41.sh || exit 1
    grep -Fq 'r36_stage_limine_target "$source_id" "$original_order" "$reference"' lib/r41.sh || exit 1
)
pass 'r41 package wiring/documentation exposes the full live matrix, preserves hardware-certification boundaries, and documents intentional first-boot source visibility'

printf '\nAll r41 regression tests passed.\n'

printf '\nStarting r42 portable-Limine-cmdline regression tests.\n'

(
    set +e
    # r42.sh preserves these inherited functions before overriding them.
    write_limine_candidate_policy() { return 0; }
    stage_limine_kernel_entries_from_existing_artifacts() { return 0; }
    source lib/r42.sh

    input='BOOT_IMAGE=/vmlinuz-linux-cachyos root=UUID=test rw quiet initrd=\\initramfs-linux-cachyos.img mitigations=off foo=bar'
    got=$(r42_portable_limine_cmdline "$input")
    [[ $got == 'root=UUID=test rw quiet mitigations=off foo=bar' ]] || { printf 'got=%s\n' "$got" >&2; exit 1; }
    [[ $got != *'initrd='* && $got != *'BOOT_IMAGE='* ]] || exit 1
    exit 0
)
pass 'r42 strips only source-loader BOOT_IMAGE/initrd artifacts before Limine policy serialization'

(
    set +e
    write_limine_candidate_policy() { return 0; }
    stage_limine_kernel_entries_from_existing_artifacts() { return 0; }
    source lib/r42.sh
    src=$(declare -f write_limine_candidate_policy)
    grep -Fq 'cmdline=$(r42_portable_limine_cmdline "$raw_cmdline")' <<<"$src" || exit 1
    grep -Fq "printf 'KERNEL_CMDLINE[default]+=%s\\n' \"\$cmdline\"" <<<"$src" || exit 1
    grep -Fq 'r23_write_cachyos_limine_theme_base' <<<"$src" || exit 1
    grep -Fq 'r23_install_cachyos_limine_splash' <<<"$src" || exit 1
    exit 0
)
pass 'r42 Limine policy override preserves the CachyOS theme path while feeding limine-entry-tool a portable cmdline'

(
    set +e
    write_limine_candidate_policy() { return 0; }
    stage_limine_kernel_entries_from_existing_artifacts() { return 0; }
    source lib/r42.sh
    src=$(declare -f stage_limine_kernel_entries_from_existing_artifacts)
    grep -Fq 'tool_output=$(sudo limine-entry-tool --add-kernel' <<<"$src" || exit 1
    grep -Fq "Invalid '[^']+' path:" <<<"$src" || exit 1
    grep -Fq 'refusing to treat the entry as successful' <<<"$src" || exit 1
    exit 0
)
pass 'r42 refuses a zero-exit limine-entry-tool result that still reports an explicit invalid-path diagnostic'

(
    grep -Fq 'SWITCHER_RELEASE="r47"' bootloader-switcher.sh || exit 1
    grep -Fq 'source "$SCRIPT_DIR/lib/r42.sh"' bootloader-switcher.sh || exit 1
    awk '/source "\$SCRIPT_DIR\/lib\/r41.sh"/{a=NR} /source "\$SCRIPT_DIR\/lib\/r42.sh"/{b=NR} END{exit !(a && b && b>a)}' bootloader-switcher.sh || exit 1
    grep -Fq '## r42: portable Limine cmdline staging and strict helper diagnostics' README.md || exit 1
    grep -Fq '## r42: portable Limine cmdline staging and strict helper diagnostics' README.md || exit 1
)
pass 'r42 package wiring loads the surgical Limine hotfix after r41 and exposes the current release consistently'

printf '\nAll r42 regression tests passed.\n'


printf '\nStarting r43 final rEFInd/systemd-boot restore-matrix regression tests.\n'

(
    set +e
    r30_cross_restore_supported() {
        case "$1:$2" in
            grub:limine|limine:grub|grub:systemd-boot|systemd-boot:grub|limine:systemd-boot|systemd-boot:limine|limine:refind|refind:limine) return 0 ;;
            *) return 1 ;;
        esac
    }
    r35_refind_restore_preflight() { return 0; }
    restore_backup_interactive() { return 0; }
    source lib/r43.sh

    r30_cross_restore_supported refind systemd-boot || exit 1
    r30_cross_restore_supported systemd-boot refind || exit 1
    r30_cross_restore_supported limine refind || exit 1
    r30_cross_restore_supported grub systemd-boot || exit 1
    ! r30_cross_restore_supported refind refind || exit 1
    ! r30_cross_restore_supported systemd-boot systemd-boot || exit 1
    exit 0
)
pass 'r43 opens exactly the final two cross-backend restore directions while preserving inherited restore routes'

(
    set +e
    r30_cross_restore_supported() { return 0; }
    r35_refind_restore_preflight() { return 9; }
    restore_backup_interactive() { return 0; }
    source lib/r43.sh

    trace=$(mktemp); trap 'rm -f "$trace"' EXIT
    pending_exists() { return 1; }
    validate_backup_compatibility() { BACKUP_COMPATIBILITY_REASON=''; return 0; }
    load_backup_metadata() { bootloader=refind; format_version=4; esp_mount=/boot; return 0; }
    detect_bootloader() { BOOTLOADER=systemd-boot; }
    run_validation() { [[ $1 == preflight ]]; }
    is_cachyos() { return 0; }
    bootcurrent_is_generic_fallback() { return 1; }
    have() { return 0; }
    adapter_source_validate() { printf 'source:%s\n' "$1" >>"$trace"; return 0; }
    r26_target_namespace_clean() { printf 'clean:%s\n' "$1" >>"$trace"; return 0; }
    r35_refind_backup_kernel_set_matches() { return 0; }
    r35_validate_refind_backup_payload() { return 0; }
    ok() { :; }
    info() { :; }
    fail() { printf 'fail:%s\n' "$*" >>"$trace"; return 1; }
    ESP_MOUNT=/boot
    BOOT_NEXT=''
    SWITCHER_RELEASE=r43

    r35_refind_restore_preflight /fake/refind-v4 >/dev/null || exit 1
    [[ $(cat "$trace") == $'source:systemd-boot\nclean:refind' ]] || { cat "$trace" >&2; exit 1; }
    exit 0
)
pass 'r43 admits systemd-boot as a deeply validated source for the unchanged strict rEFInd-v4 restore target contract'

(
    set +e
    r30_cross_restore_supported() { return 0; }
    r35_refind_restore_preflight() { return 0; }
    restore_backup_interactive() { return 0; }
    source lib/r43.sh

    trace=$(mktemp); trap 'rm -f "$trace"' EXIT
    discover_backups_quiet() { DISCOVERED_BACKUPS=(/fake/backup); }
    list_backups() { :; }
    validate_backup_compatibility() { return 0; }
    load_backup_metadata() { bootloader=$TEST_TARGET; return 0; }
    detect_bootloader() { BOOTLOADER=$TEST_SOURCE; }
    bootloader_display_name() { printf '%s' "$1"; }
    restore_grub_backup() { printf 'wrong:restore-grub\n' >>"$trace"; return 1; }
    restore_limine_backup() { printf 'wrong:restore-limine\n' >>"$trace"; return 1; }
    restore_systemd_boot_backup() { printf 'wrong:old-systemd\n' >>"$trace"; return 1; }
    r30_restore_grub_backup() { printf 'wrong:r30-grub\n' >>"$trace"; return 1; }
    r30_restore_limine_backup() { printf 'wrong:r30-limine\n' >>"$trace"; return 1; }
    r30_restore_systemd_boot_backup() { printf 'systemd:%s\n' "$1" >>"$trace"; return 0; }
    r38_restore_refind_backup() { printf 'refind:%s\n' "$1" >>"$trace"; return 0; }

    TEST_SOURCE=refind TEST_TARGET=systemd-boot
    restore_backup_interactive <<<"1" >/dev/null || exit 1
    TEST_SOURCE=systemd-boot TEST_TARGET=refind
    restore_backup_interactive <<<"1" >/dev/null || exit 1

    expected=$'systemd:/fake/backup\nrefind:/fake/backup'
    [[ $(cat "$trace") == "$expected" ]] || { cat "$trace" >&2; exit 1; }
    exit 0
)
pass 'r43 routes rEFInd -> restored systemd-boot and systemd-boot -> restored rEFInd through the existing strict target executors'

(
    grep -Fq 'SWITCHER_RELEASE="r47"' bootloader-switcher.sh || exit 1
    grep -Fq 'source "$SCRIPT_DIR/lib/r43.sh"' bootloader-switcher.sh || exit 1
    awk '/source "\$SCRIPT_DIR\/lib\/r42.sh"/{a=NR} /source "\$SCRIPT_DIR\/lib\/r43.sh"/{b=NR} END{exit !(a && b && b>a)}' bootloader-switcher.sh || exit 1
    grep -Fq '# CachyOS Bootloader Switcher — r47' README.md || exit 1
    grep -Fq '## r43: add the rEFInd ↔ systemd-boot backup-restore pair' README.md || exit 1
    grep -Fq '**rEFInd → restored systemd-boot v4**' README.md || exit 1
    grep -Fq '**systemd-boot → restored rEFInd v4**' README.md || exit 1
    grep -Fq 'r43 rEFInd <-> systemd-boot v4 backup restore (hardware-proven on real firmware)' bootloader-switcher.sh || exit 1
    ! grep -Fq 'load_pending_state()' lib/r43.sh || exit 1
    exit 0
)
pass 'r43 package wiring preserves the rEFInd/systemd-boot restore pair and reuses the already-admitted format-v5 pending directions'

printf '\nAll r43 regression tests passed.\n'

printf '\nStarting r44 missing rEFInd -> GRUB restore-edge regression tests.\n'

(
    set +e
    # Model the actual predicate state inherited by r44: r30 supplied the six
    # GRUB/Limine/systemd-boot pairs, r38 added Limine <-> rEFInd, and r43 added
    # rEFInd <-> systemd-boot. GRUB -> rEFInd was functional in the dispatcher
    # but historically absent from this predicate; r46 repairs that separately.
    r30_cross_restore_supported() {
        case "$1:$2" in
            grub:limine|grub:systemd-boot|limine:grub|limine:systemd-boot|limine:refind|systemd-boot:grub|systemd-boot:limine|systemd-boot:refind|refind:limine|refind:systemd-boot) return 0 ;;
            *) return 1 ;;
        esac
    }
    restore_backup_interactive() { return 0; }
    source lib/r44.sh

    r30_cross_restore_supported refind grub || exit 1
    ! r30_cross_restore_supported grub refind || exit 1
    ! r30_cross_restore_supported grub grub || exit 1
    ! r30_cross_restore_supported refind refind || exit 1
    exit 0
)
pass 'r44 adds rEFInd -> GRUB to the real inherited predicate state without pretending the historical GRUB -> rEFInd predicate omission was already fixed'

(
    set +e
    r30_cross_restore_supported() { return 0; }
    restore_backup_interactive() { return 0; }
    source lib/r44.sh

    trace=$(mktemp); trap 'rm -f "$trace"' EXIT
    discover_backups_quiet() { DISCOVERED_BACKUPS=(/fake/backup); }
    list_backups() { :; }
    validate_backup_compatibility() { BACKUP_COMPATIBILITY_REASON=''; return 0; }
    load_backup_metadata() { bootloader=$TEST_TARGET; return 0; }
    detect_bootloader() { BOOTLOADER=$TEST_SOURCE; }
    bootloader_display_name() { printf '%s' "$1"; }
    restore_grub_backup() { printf 'restore-grub\n' >>"$trace"; return 0; }
    restore_limine_backup() { printf 'restore-limine\n' >>"$trace"; return 0; }
    restore_systemd_boot_backup() { printf 'restore-systemd-old\n' >>"$trace"; return 0; }
    r30_restore_grub_backup() { printf 'r30-grub\n' >>"$trace"; return 0; }
    r30_restore_limine_backup() { printf 'r30-limine\n' >>"$trace"; return 0; }
    r30_restore_systemd_boot_backup() { printf 'r30-systemd\n' >>"$trace"; return 0; }
    r38_restore_refind_backup() { printf 'r38-refind\n' >>"$trace"; return 0; }

    while read -r TEST_SOURCE TEST_TARGET expected; do
        : >"$trace"
        restore_backup_interactive <<<"1" >/dev/null || exit 1
        [[ $(cat "$trace") == "$expected" ]] || { printf '%s -> %s got=%s expected=%s\n' "$TEST_SOURCE" "$TEST_TARGET" "$(cat "$trace")" "$expected" >&2; exit 1; }
    done <<'CASES'
limine grub restore-grub
grub limine restore-limine
grub systemd-boot restore-systemd-old
systemd-boot grub r30-grub
systemd-boot limine r30-limine
limine systemd-boot r30-systemd
grub refind r38-refind
limine refind r38-refind
systemd-boot refind r38-refind
refind grub r30-grub
refind limine r30-limine
refind systemd-boot r30-systemd
CASES
    exit 0
)
pass 'r44 interactive dispatcher covers the complete 12-edge restore graph and routes rEFInd -> GRUB through the generic r31/r30 GRUB executor'

(
    set +e
    # Source the real generic r30 preflight with only the historical function
    # capture dependencies stubbed, then layer r44 over it.
    load_pending_state() { return 1; }
    rollback_pending_candidate() { return 1; }
    restore_backup_interactive() { return 0; }
    source lib/r30.sh
    source lib/r44.sh

    trace=$(mktemp); trap 'rm -f "$trace"' EXIT
    pending_exists() { return 1; }
    validate_backup_compatibility() { BACKUP_COMPATIBILITY_REASON=''; return 0; }
    load_backup_metadata() { bootloader=grub; return 0; }
    detect_bootloader() { BOOTLOADER=refind; }
    bootloader_display_name() { printf '%s' "$1"; }
    run_validation() { [[ $1 == preflight ]]; }
    is_cachyos() { return 0; }
    bootcurrent_is_generic_fallback() { return 1; }
    have() { return 0; }
    adapter_source_validate() { printf 'source:%s\n' "$1" >>"$trace"; return 0; }
    r26_target_namespace_clean() { printf 'clean:%s\n' "$1" >>"$trace"; return 0; }
    fail() { printf 'fail:%s\n' "$*" >>"$trace"; return 1; }
    BOOT_NEXT=''

    r30_restore_common_preflight /fake/grub grub >/dev/null || exit 1
    [[ $(cat "$trace") == $'source:refind\nclean:grub' ]] || { cat "$trace" >&2; exit 1; }
    exit 0
)
pass 'r44 admits a deeply validated rEFInd source into the existing source-generic GRUB restore preflight without weakening the GRUB target namespace gate'

(
    grep -Fq 'SWITCHER_RELEASE="r47"' bootloader-switcher.sh || exit 1
    grep -Fq 'source "$SCRIPT_DIR/lib/r44.sh"' bootloader-switcher.sh || exit 1
    awk '/source "\$SCRIPT_DIR\/lib\/r43.sh"/{a=NR} /source "\$SCRIPT_DIR\/lib\/r44.sh"/{b=NR} END{exit !(a && b && b>a)}' bootloader-switcher.sh || exit 1
    grep -Fq '# CachyOS Bootloader Switcher — r47' README.md || exit 1
    grep -Fq '## r44: close the restore-matrix hole exposed by sequential sanity testing' README.md || exit 1
    grep -Fq 'refind:grub) r30_restore_grub_backup "$dir"' lib/r44.sh || exit 1
    grep -Fq 'grub:refind|refind:grub' lib/r26.sh || exit 1
    ! grep -Fq 'load_pending_state()' lib/r44.sh || exit 1
    exit 0
)
pass 'r44 stays surgical: one missing dispatcher/allowlist edge, inherited format-v5 pending support, and no duplicate transaction engine'

printf '\nAll r44 regression tests passed.\n'

printf '\nStarting r45 VFAT-safe historical GRUB -> restored-Limine v4 regression tests.\n'

(
    grep -Fq 'SWITCHER_RELEASE="r47"' bootloader-switcher.sh || exit 1
    grep -Fq 'source "$SCRIPT_DIR/lib/r44.sh"' bootloader-switcher.sh || exit 1
    grep -Fq 'source "$SCRIPT_DIR/lib/r45.sh"' bootloader-switcher.sh || exit 1
    awk '/source "\$SCRIPT_DIR\/lib\/r44.sh"/{a=NR} /source "\$SCRIPT_DIR\/lib\/r45.sh"/{b=NR} END{exit !(a && b && b>a)}' bootloader-switcher.sh || exit 1
    grep -Fq '# CachyOS Bootloader Switcher — r47' README.md || exit 1
    grep -Fq '## r45: VFAT-safe GRUB → restored-Limine v4 payload copy' README.md || exit 1
    exit 0
)
pass 'r45 is layered after r44 and exposes the VFAT restore hotfix as the current release'

(
    body=$(awk '/^r23_stage_limine_from_v4_backup\(\)/,/^}/' lib/r45.sh)
    grep -Fq 'r30_limine_v4_payload_shape_safe "$dir" "$backup_mount" "$machine"' <<<"$body" || exit 1
    grep -Fq 'restore_copy_from_backup "$dir" "$managed_rel"' <<<"$body" || exit 1
    ! grep -Fq 'sudo cp -a -- "$managed" "$dst_managed"' <<<"$body" || exit 1
    grep -Fq 'sudo cp -a --no-preserve=all -- "$src" "$dst"' lib/r25.sh || exit 1
    exit 0
)
pass 'r45 replaces the historical raw VFAT cp -a site with the existing r25 no-preserve exact-path helper and keeps the unsafe-object gate'

(
    set +e
    # The historical GRUB-hub transaction still calls the r23 stage helper.
    # Source r45 alone with the helper dependencies mocked and verify that the
    # runtime override delegates exactly the managed directory to the VFAT-safe
    # restore helper rather than changing transaction dispatch/execution.
    source lib/r45.sh
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    backup="$tmp/backup"; esp="$tmp/esp"; machine=machine-test
    mkdir -p "$backup/files/boot/$machine" "$esp"
    : >"$backup/files/boot/limine.conf"
    : >"$backup/files/boot/limine-splash.png"
    : >"$backup/files/boot/$machine/vmlinuz-linux-cachyos"
    : >"$backup/files/boot/$machine/initramfs-linux-cachyos.img"
    ESP_MOUNT=$esp
    R23_LIMINE_SPLASH_NAME=limine-splash.png
    r23_backup_limine_conf_path() { printf '%s/files/boot/limine.conf\n' "$1"; }
    r23_backup_limine_splash_path() { printf '%s/files/boot/limine-splash.png\n' "$1"; }
    r23_backup_limine_managed_path() { printf '%s/files/boot/%s\n' "$1" "$3"; }
    r30_limine_v4_payload_shape_safe() { return 0; }
    r23_install_limine_policy_from_backup() { return 0; }
    fail() { return 1; }
    ok() { :; }
    sudo() { return 0; }
    trace="$tmp/trace"
    restore_copy_from_backup() { printf '%s|%s\n' "$1" "$2" >"$trace"; return 0; }

    r23_stage_limine_from_v4_backup "$backup" /boot "$machine" >/dev/null || exit 1
    [[ $(cat "$trace") == "$backup|boot/$machine" ]] || { cat "$trace" >&2; exit 1; }
    exit 0
)
pass 'r45 runtime override sends the historical GRUB -> Limine v4 managed tree through the VFAT-safe helper at the exact ESP-relative path'

(
    # Keep the restore graph/dispatcher from r44 unchanged. This hotfix is copy
    # semantics only, not another matrix or transaction-engine revision.
    grep -Fq 'grub:limine) restore_limine_backup "$dir"' lib/r44.sh || exit 1
    ! grep -Fq 'restore_backup_interactive()' lib/r45.sh || exit 1
    ! grep -Fq 'load_pending_state()' lib/r45.sh || exit 1
    ! grep -Fq 'r30_cross_restore_supported()' lib/r45.sh || exit 1
    exit 0
)
pass 'r45 stays surgical: restore graph, pending schema, and transaction dispatcher remain inherited from r44'

printf '\nAll r45 regression tests passed.\n'


printf '\nStarting r46 cross-restore predicate-consistency regression tests.\n'

(
    set +e
    # Compose the actual predicate lineage used by the loaded release rather
    # than injecting a synthetic matrix baseline. r30 has a few eval-capture
    # dependencies that are irrelevant to this predicate audit, so stub only
    # those names before sourcing the real layer.
    load_pending_state() { return 1; }
    r26_remove_uncommitted_target_namespaces() { return 0; }
    rollback_pending_candidate() { return 1; }
    r26_finalize_target_fallback() { return 0; }
    restore_backup_interactive() { return 0; }

    source lib/r30.sh
    source lib/r38.sh
    source lib/r43.sh
    source lib/r44.sh
    source lib/r46.sh

    count=0
    for source in grub limine systemd-boot refind; do
        for target in grub limine systemd-boot refind; do
            if [[ $source == "$target" ]]; then
                ! r30_cross_restore_supported "$source" "$target" || { printf 'diagonal unexpectedly open: %s -> %s\n' "$source" "$target" >&2; exit 1; }
            else
                r30_cross_restore_supported "$source" "$target" || { printf 'predicate missing: %s -> %s\n' "$source" "$target" >&2; exit 1; }
                ((count++))
            fi
        done
    done
    [[ $count -eq 12 ]] || exit 1
    exit 0
)
pass 'r46 composes the real r30/r38/r43/r44/r46 predicate lineage and proves exactly all 12 cross-backend restore pairs with all diagonals closed'

(
    grep -Fq 'SWITCHER_RELEASE="r47"' bootloader-switcher.sh || exit 1
    grep -Fq 'source "$SCRIPT_DIR/lib/r45.sh"' bootloader-switcher.sh || exit 1
    grep -Fq 'source "$SCRIPT_DIR/lib/r46.sh"' bootloader-switcher.sh || exit 1
    awk '/source "\$SCRIPT_DIR\/lib\/r45.sh"/{a=NR} /source "\$SCRIPT_DIR\/lib\/r46.sh"/{b=NR} END{exit !(a && b && b>a)}' bootloader-switcher.sh || exit 1
    grep -Fq 'grub:refind) return 0' lib/r46.sh || exit 1
    ! grep -Fq 'restore_backup_interactive()' lib/r46.sh || exit 1
    ! grep -Fq 'load_pending_state()' lib/r46.sh || exit 1
    ! grep -Fq 'r30_execute_restored_adapter' lib/r46.sh || exit 1
    grep -Fq '# CachyOS Bootloader Switcher — r47' README.md || exit 1
    grep -Fq '## r46: make the restore support predicate tell the truth' README.md || exit 1
    exit 0
)
pass 'r46 stays surgical: one support-predicate edge, no dispatcher/pending/transaction-engine duplication, and release wiring is layered after r45'

printf '\nAll r46 regression tests passed.\n'

printf '\nStarting r47 effective Limine backup-cmdline reconstruction regression tests.\n'

(
    set +e
    # r47 is intentionally a narrow runtime override. Provide the inherited
    # extractor symbol, then verify the real multi-assignment shape captured
    # by the NVMe hardware diagnostic.
    r23_backup_limine_cmdline() { return 1; }
    source lib/r47.sh

    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    mkdir -p "$tmp/files/etc/default"
    cat >"$tmp/files/etc/default/limine" <<'CFG'
ESP_PATH="/boot"
KERNEL_CMDLINE[default]+="quiet nowatchdog splash rw root=UUID=042a9144-a5a0-44bb-9dea-e666981f90ce mitigations=off"
BOOT_ORDER="*, *lts, *fallback, Snapshots"

# Added by intel-pstate-governor
KERNEL_CMDLINE[default]+=" intel_pstate=passive"
CFG

    got=$(r23_backup_limine_cmdline "$tmp") || exit 1
    [[ $got == *'quiet nowatchdog splash rw root=UUID=042a9144-a5a0-44bb-9dea-e666981f90ce mitigations=off'* ]] || { printf 'got=%s\n' "$got" >&2; exit 1; }
    [[ $got == *'intel_pstate=passive'* ]] || { printf 'got=%s\n' "$got" >&2; exit 1; }
    exit 0
)
pass 'r47 reconstructs every appended KERNEL_CMDLINE[default] fragment from a Limine backup instead of dropping later policy'

(
    set +e
    source lib/staged.sh
    r23_backup_limine_cmdline() { return 1; }
    source lib/r47.sh

    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    mkdir -p "$tmp/files/etc/default"
    cat >"$tmp/files/etc/default/limine" <<'CFG'
KERNEL_CMDLINE[default]+="quiet nowatchdog splash rw root=UUID=042a9144-a5a0-44bb-9dea-e666981f90ce mitigations=off"
KERNEL_CMDLINE[default]+=" intel_pstate=passive"
CFG

    backup=$(r23_backup_limine_cmdline "$tmp") || exit 1
    grub='BOOT_IMAGE=/vmlinuz-linux-cachyos root=UUID=042a9144-a5a0-44bb-9dea-e666981f90ce rw intel_pstate=passive quiet nowatchdog splash mitigations=off'
    pending_cmdline_equivalent "$backup" "$grub" || { printf 'backup=%s\ngrub=%s\n' "$backup" "$grub" >&2; exit 1; }
    drift=${grub/mitigations=off/mitigations=auto}
    ! pending_cmdline_equivalent "$backup" "$drift" || exit 1
    exit 0
)
pass 'r47 makes the captured Limine backup token-equivalent to the proven GRUB runtime while genuine extra policy still fails closed'

(
    set +e
    r23_backup_limine_cmdline() { return 1; }
    source lib/r47.sh

    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    mkdir -p "$tmp/files/etc/default"
    cat >"$tmp/files/etc/default/limine" <<'CFG'
KERNEL_CMDLINE[default]+="old=1 quiet"
KERNEL_CMDLINE[default]="root=UUID=test rw mitigations=off"
KERNEL_CMDLINE[default]+=' intel_pstate=passive'
CFG

    got=$(r23_backup_limine_cmdline "$tmp") || exit 1
    [[ $got == 'root=UUID=test rw mitigations=off  intel_pstate=passive' ]] || { printf 'got=%q\n' "$got" >&2; exit 1; }
    [[ $got != *'old=1'* ]] || exit 1
    exit 0
)
pass 'r47 honors plain KERNEL_CMDLINE[default]= replacement before later append fragments without evaluating backup code'

(
    grep -Fq 'SWITCHER_RELEASE="r47"' bootloader-switcher.sh || exit 1
    grep -Fq 'source "$SCRIPT_DIR/lib/r46.sh"' bootloader-switcher.sh || exit 1
    grep -Fq 'source "$SCRIPT_DIR/lib/r47.sh"' bootloader-switcher.sh || exit 1
    awk '/source "\$SCRIPT_DIR\/lib\/r46.sh"/{a=NR} /source "\$SCRIPT_DIR\/lib\/r47.sh"/{b=NR} END{exit !(a && b && b>a)}' bootloader-switcher.sh || exit 1
    grep -Fq '# CachyOS Bootloader Switcher — r47' README.md || exit 1
    grep -Fq '## r47: fix multi-assignment Limine backup cmdline restore validation' README.md || exit 1
    ! grep -Eq '(^|[[:space:]])(source|eval)[[:space:]].*files/etc/default/limine' lib/r47.sh || exit 1
    exit 0
)
pass 'r47 is layered after r46, keeps backup parsing non-executing, and exposes the restore-preflight fix as the current release'

printf '\nAll r47 regression tests passed.\n'
