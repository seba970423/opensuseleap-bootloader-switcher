#!/usr/bin/env bash

TARGET_NVRAM_ID=""
TARGET_NVRAM_PATH=""
TARGET_EFI_RESOLVED=""
TARGET_EFI_HASH=""
TARGET_LIMINE_CONF_PATH=""
TARGET_LIMINE_CONF_HASH=""
TARGET_LIMINE_MANAGED_DIR=""
LIMINE_DEFAULT_CREATED=0
LIMINE_DEFAULT_HASH=""
TRANSACTION_SNAPSHOT_DIR=""
OLD_FALLBACK_EXISTED=0
OLD_FALLBACK_SNAPSHOT=""
POST_STAGE_FALLBACK_HASH=""
declare -a SOURCE_STAGE_ARTIFACTS=()
declare -a SOURCE_STAGE_HASHES=()

SOURCE_LIMINE_EFI_RESOLVED=""
SOURCE_LIMINE_EFI_HASH=""
SOURCE_LIMINE_CONF_PATH=""
SOURCE_LIMINE_CONF_HASH=""
SOURCE_LIMINE_DEFAULT_HASH=""
SOURCE_LIMINE_MANAGED_DIR=""
SOURCE_LIMINE_MANAGED_HASH=""
GRUB_DEFAULT_CREATED=0
GRUB_DEFAULT_HASH=""
TARGET_GRUB_CFG_PATH=""
TARGET_GRUB_CFG_HASH=""
TARGET_GRUB_DIR=""
TARGET_GRUB_EFI_DIR=""
GRUB_DIR_MANIFEST=""
GRUB_EFI_DIR_MANIFEST=""
GRUB_ARTIFACT_MANIFEST=""
declare -a GRUB_CREATED_ARTIFACTS=()
declare -a GRUB_CREATED_HASHES=()
declare -a GRUB_SHARED_ARTIFACTS=()
declare -a GRUB_SHARED_HASHES=()

bootloader_packages() {
    case "$1" in
        grub) printf '%s\n' grub grub-hook cachyos-grub-theme ;;
        limine) printf '%s\n' limine limine-mkinitcpio-hook cachyos-wallpapers ;;
        refind) printf '%s\n' refind ;;
        systemd-boot) printf '%s\n' systemd-boot-manager ;;
    esac
}

target_expected_efi_path() {
    case "$1" in
        grub) printf '\\EFI\\CACHYOS\\GRUBX64.EFI\n' ;;
        limine) printf '\\EFI\\LIMINE\\LIMINE_X64.EFI\n' ;;
        refind) printf '\\EFI\\refind\\refind_x64.efi\n' ;;
        systemd-boot) printf '\\EFI\\systemd\\systemd-bootx64.efi\n' ;;
    esac
}

find_nvram_entry_for_target() {
    local target=$1 out line id path expected_norm actual_norm
    TARGET_NVRAM_ID="" TARGET_NVRAM_PATH=""
    out=$(efibootmgr -v 2>/dev/null) || return 1
    expected_norm=$(normalize_efi_path "$(target_expected_efi_path "$target")")

    while IFS= read -r line; do
        [[ $line =~ ^Boot([0-9A-Fa-f]{4})\*? ]] || continue
        id=${BASH_REMATCH[1]^^}
        path=$(efi_path_from_efibootmgr_line "$line" 2>/dev/null || true)
        [[ -n $path ]] || continue
        actual_norm=$(normalize_efi_path "$path")
        [[ ${actual_norm,,} == ${expected_norm,,} ]] || continue
        TARGET_NVRAM_ID=$id
        TARGET_NVRAM_PATH=$path
        return 0
    done <<<"$out"
    return 1
}

count_nvram_entries_for_target() {
    local target=$1 out line path expected_norm actual_norm count=0
    out=$(efibootmgr -v 2>/dev/null) || { printf '0\n'; return 0; }
    expected_norm=$(normalize_efi_path "$(target_expected_efi_path "$target")")
    while IFS= read -r line; do
        [[ $line =~ ^Boot([0-9A-Fa-f]{4})\*? ]] || continue
        path=$(efi_path_from_efibootmgr_line "$line" 2>/dev/null || true)
        [[ -n $path ]] || continue
        actual_norm=$(normalize_efi_path "$path")
        [[ ${actual_norm,,} == ${expected_norm,,} ]] && ((count++))
    done <<<"$out"
    printf '%d\n' "$count"
}

operation_supported() {
    local current=$1 target=$2
    [[ $current == grub && ( $target == grub || $target == limine ) ]] || \
    [[ $current == limine && $target == grub ]]
}

validate_preexisting_grub_artifact_against_limine() {
    local kid=$1 ver=$2 field=$3 target=$4 conf="${ESP_MOUNT}/limine.conf"
    local tmp value source source_hash target_hash
    tmp=$(mktemp) || return 1
    if [[ -r $conf ]]; then
        cat -- "$conf" >"$tmp"
    else
        sudo -n cat -- "$conf" >"$tmp" 2>/dev/null || { rm -f -- "$tmp"; fail "Could not read source Limine config while classifying $target"; return 1; }
    fi
    value=$(limine_conf_field_for_kernel "$kid" "$field" "$tmp" 2>/dev/null || true)
    if [[ $field == path && -z $value ]]; then
        value=$(limine_conf_field_for_kernel "$kid" kernel_path "$tmp" 2>/dev/null || true)
    fi
    rm -f -- "$tmp"
    [[ -n $value ]] || { fail "Could not resolve source Limine $field reference for $kid"; return 1; }
    verify_limine_uri_hash "$value" || { fail "Source Limine BLAKE2 verification failed for $kid ($field)"; return 1; }
    source=$(resolve_limine_boot_uri "$value" 2>/dev/null || true)
    [[ -n $source ]] || { fail "Could not resolve source Limine artifact for $kid ($field)"; return 1; }
    source_hash=$(sudo -n sha256sum -- "$source" 2>/dev/null | awk '{print $1}' || sha256sum -- "$source" 2>/dev/null | awk '{print $1}' || true)
    target_hash=$(sudo -n sha256sum -- "$target" 2>/dev/null | awk '{print $1}' || sha256sum -- "$target" 2>/dev/null | awk '{print $1}' || true)
    [[ -n $source_hash && -n $target_hash ]] || { fail "Could not hash source/pre-existing artifact while classifying $target"; return 1; }

    if [[ $source_hash == "$target_hash" ]]; then
        ok "Pre-existing conventional artifact is bit-identical to validated Limine state; treating as source-shared: $target"
        return 0
    fi

    # Kernel binaries are expected to be the same payload and remain strict.
    # Initramfs images are different: a clean Limine installation may have a
    # valid conventional mkinitcpio image plus a separately managed Limine copy.
    # When the bytes differ, validate the conventional image independently for
    # the exact kernel release and preserve it as source-owned state.
    if [[ $field == module_path ]]; then
        if grub_initramfs_matches_kernel_version "$target" "$ver"; then
            ok "Pre-existing conventional initramfs differs from the Limine-managed copy but is a valid mkinitcpio image for $ver; treating as source-shared: $target"
            return 0
        fi
        fail "Pre-existing conventional initramfs differs from the validated Limine payload and failed independent validation: $target"
        fail "Reason: ${GRUB_INITRAMFS_REASON:-unknown}"
        return 1
    fi

    fail "Pre-existing conventional kernel artifact differs from the validated Limine payload: $target"
    fail 'Kernel identity is ambiguous; refusing candidate creation.'
    return 1
}

run_switch_preflight() {
    local target=${1:-}
    printf '\nPreflight validation:\n'
    if ! run_validation preflight; then
        printf '\nPreflight failed. Nothing was modified.\n'
        return 1
    fi
    if ! is_cachyos; then
        fail 'This live backend is intentionally restricted to CachyOS/Arch-like systems.'
        return 1
    fi
    if declare -F bootcurrent_is_generic_fallback >/dev/null 2>&1 && bootcurrent_is_generic_fallback; then
        fail 'The system was booted through the generic \EFI\BOOT\BOOTX64.EFI fallback path.'
        fail 'Bootloader switching/restoring requires the canonical source NVRAM entry. Reboot normally and let firmware follow persistent BootOrder.'
        return 1
    fi
    have sudo || { fail 'sudo is required for bootloader changes'; return 1; }
    have pacman || { fail 'pacman is required for the CachyOS backend'; return 1; }
    if pending_exists; then
        fail 'A staged bootloader migration is already pending.'
        fail 'Manage or roll back the existing staged migration before starting another modifying operation.'
        return 1
    fi
    if [[ $target == limine ]]; then
        if pacman -Q limine-mkinitcpio-hook >/dev/null 2>&1; then
            info 'Canonical CachyOS Limine kernel integration detected: limine-mkinitcpio-hook.'
        elif pacman -Q limine-entry-tool >/dev/null 2>&1; then
            info 'Legacy standalone limine-entry-tool package detected; the switcher will transition it to the canonical CachyOS limine-mkinitcpio-hook package at the write boundary.'
        else
            info 'CachyOS Limine kernel integration is not installed yet; the switcher will install limine-mkinitcpio-hook at the write boundary.'
        fi
    fi
    if [[ $target != "$BOOTLOADER" && -n ${BOOT_NEXT:-} ]]; then
        fail "UEFI BootNext is already set to Boot${BOOT_NEXT^^}."
        fail 'A staged migration would overwrite an existing one-time boot request, so the switcher refuses to continue.'
        return 1
    fi

    if [[ $target == grub && $BOOTLOADER == limine ]]; then
        printf '\nSource Limine gate before GRUB staging:\n'
        validate_limine_boot_chain current || {
            fail 'The active Limine source does not pass the known-good deep validator; refusing to stage GRUB.'
            return 1
        }
        if find_nvram_entry_for_target grub; then
            fail "An existing GRUB NVRAM entry (Boot$TARGET_NVRAM_ID) already exists before staging."
            fail 'Target ownership is ambiguous; the switcher requires a clean GRUB target namespace.'
            return 1
        fi
        if path_exists_on_esp_privileged "$(target_expected_efi_path grub)"; then
            fail 'A GRUB EFI executable already exists on the ESP before staging.'
            fail 'The switcher refuses to overwrite/reuse stale GRUB target state automatically.'
            return 1
        fi
        if sudo -n test -e "$ESP_MOUNT/EFI/CACHYOS" 2>/dev/null || [[ -e $ESP_MOUNT/EFI/CACHYOS ]]; then
            fail "The target GRUB EFI directory already exists before staging: $ESP_MOUNT/EFI/CACHYOS"
            fail 'The switcher requires the whole target EFI namespace to be transaction-owned.'
            return 1
        fi
        if sudo -n test -e /boot/grub 2>/dev/null || [[ -e /boot/grub ]]; then
            fail '/boot/grub already exists before staging.'
            fail 'The switcher requires a transaction-owned GRUB directory for the first Limine -> GRUB candidate test.'
            return 1
        fi
        if [[ -e /etc/default/grub ]]; then
            fail '/etc/default/grub already exists before staging.'
            fail 'The switcher refuses to overwrite pre-existing GRUB policy during the controlled candidate test.'
            return 1
        fi
        collect_kernels
        local ver kid kernel_target initrd_target
        for ver in "${KERNEL_VERSIONS[@]}"; do
            kid=$(kernel_pkgbase_for_version "$ver" 2>/dev/null || true)
            [[ -n $kid ]] || { fail "Could not resolve pkgbase for installed kernel $ver"; return 1; }
            kernel_target="/boot/vmlinuz-$kid"
            initrd_target="/boot/initramfs-$kid.img"
            if sudo -n test -e "$kernel_target" 2>/dev/null || [[ -e $kernel_target ]]; then
                validate_preexisting_grub_artifact_against_limine "$kid" "$ver" path "$kernel_target" || return 1
            else
                info "Conventional GRUB kernel artifact is absent and may be transaction-created later: $kernel_target"
            fi
            if sudo -n test -e "$initrd_target" 2>/dev/null || [[ -e $initrd_target ]]; then
                validate_preexisting_grub_artifact_against_limine "$kid" "$ver" module_path "$initrd_target" || return 1
            else
                info "Conventional GRUB initramfs artifact is absent and may be transaction-created later: $initrd_target"
            fi
        done
    fi

    if [[ $target == limine && $BOOTLOADER != limine ]]; then
        if find_nvram_entry_for_target limine; then
            fail "An existing Limine NVRAM entry (Boot$TARGET_NVRAM_ID) already exists before staging."
            fail 'Target ownership is ambiguous; the switcher refuses to overwrite/reuse stale Limine boot state automatically.'
            return 1
        fi
        if path_exists_on_esp_privileged "$(target_expected_efi_path limine)"; then
            # A previous ownership-gated Limine -> GRUB finalization may leave
            # unproven inactive files in EFI/LIMINE while removing Limine's
            # NVRAM/config/managed-kernel state. r23 snapshots the complete
            # pre-stage EFI/LIMINE namespace before any Limine write and can
            # restore it exactly on rollback, so this inactive leftover is not
            # by itself a reason to block an explicit GRUB -> Limine request.
            info 'An inactive Limine EFI payload already exists with no matching Limine NVRAM entry.'
            info 'The switcher will snapshot the complete EFI/LIMINE namespace before staging and restore it exactly if the transaction rolls back.'
        fi
        if sudo -n test -e "$ESP_MOUNT/limine.conf" 2>/dev/null || [[ -e $ESP_MOUNT/limine.conf ]]; then
            fail 'An existing limine.conf is present before staging.'
            fail 'The switcher requires a clean target namespace for the staged GRUB -> Limine transaction.'
            return 1
        fi
        if [[ -e /etc/default/limine ]]; then
            fail '/etc/default/limine already exists before staging.'
            fail 'The switcher refuses to overwrite an existing Limine policy file during the controlled migration test.'
            return 1
        fi
        local machine_id managed_dir
        machine_id=$(cat /etc/machine-id 2>/dev/null || true)
        managed_dir="$ESP_MOUNT/$machine_id"
        if [[ -n $machine_id ]] && { sudo -n test -e "$managed_dir" 2>/dev/null || [[ -e $managed_dir ]]; }; then
            fail "A Limine managed kernel directory already exists before staging: $managed_dir"
            fail 'Target ownership is ambiguous; the switcher requires a clean managed namespace.'
            return 1
        fi
        validate_existing_boot_artifacts_for_limine_stage || {
            fail 'Existing kernel/initramfs source artifacts are incomplete; refusing to stage Limine.'
            return 1
        }
    fi
    return 0
}

validate_existing_boot_artifacts_for_limine_stage() {
    collect_kernels
    local ver kid failures=0 kernel_path initrd_path
    printf '\nExisting kernel/initramfs source check:\n'
    for ver in "${KERNEL_VERSIONS[@]}"; do
        kid=$(kernel_pkgbase_for_version "$ver" 2>/dev/null || true)
        if [[ -z $kid ]]; then
            fail "Could not resolve pkgbase for installed kernel $ver"
            ((failures++))
            continue
        fi
        kernel_path="/boot/vmlinuz-$kid"
        initrd_path="/boot/initramfs-$kid.img"
        if sudo -n test -f "$kernel_path" 2>/dev/null || [[ -f $kernel_path ]]; then
            ok "Existing kernel image is present: $kernel_path"
        else
            fail "Existing kernel image is missing: $kernel_path"
            ((failures++))
        fi
        if sudo -n test -f "$initrd_path" 2>/dev/null || [[ -f $initrd_path ]]; then
            ok "Existing initramfs is present: $initrd_path"
        else
            fail "Existing initramfs is missing: $initrd_path"
            ((failures++))
        fi
    done
    ((failures == 0))
}

offer_operation_backup() {
    local ans out rc
    OPERATION_BACKUP=""
    printf '\nBackup offer:\n'
    read -r -p "Back up the currently booted $(bootloader_display_name "$BOOTLOADER") setup to $BACKUP_ROOT? [y/n]: " ans
    case "$ans" in
        y|Y|yes|YES)
            create_current_bootloader_backup; rc=$?
            if ((rc != 0)); then
                printf '\nBackup creation failed: %s\n' "${BACKUP_CREATE_ERROR:-unknown backup error}"
                printf 'The operation is cancelled. No bootloader state was modified.\n'
                return 1
            fi
            out=$CREATED_BACKUP_DIR
            printf 'Backup created: %s\n' "$out"
            if ! validate_backup_compatibility "$out"; then
                printf 'Backup validation FAILED: %s\n' "$BACKUP_COMPATIBILITY_REASON"
                printf 'The operation is cancelled.\n'
                return 1
            fi
            printf 'Backup validation: VALID, COMPATIBLE\n'
            OPERATION_BACKUP=$out
            ;;
        n|N|no|NO)
            printf 'Backup declined by user. Continuing without creating one.\n'
            ;;
        *)
            printf 'Unrecognized response. Operation cancelled.\n'
            return 1
            ;;
    esac
}

show_operation_plan() {
    local current=$1 target=$2 expected
    expected=$(target_expected_efi_path "$target")
    printf '\nExact operation plan:\n'
    if [[ $current == "$target" ]]; then
        printf '  1. Re-run privileged preflight checks.\n'
        printf '  2. Install/refresh required %s packages with pacman --needed.\n' "$(bootloader_display_name "$target")"
        printf '  3. Rebuild initramfs for every installed kernel with mkinitcpio -P.\n'
        case "$target" in
            grub)
                printf '  4. grub-install --target=x86_64-efi --efi-directory=%s --bootloader-id=cachyos --force\n' "$ESP_MOUNT"
                printf '  5. grub-mkconfig -o /boot/grub/grub.cfg\n'
                ;;
        esac
        printf '  6. Verify EFI executable, NVRAM entry, kernels and fstab.\n'
        printf '  No mountpoint/fstab migration will be performed.\n'
        return 0
    fi

    printf '  1. Snapshot and protect the currently booted %s recovery path before target generation.\n' "$(bootloader_display_name "$current")"
    printf '  2. Install/refresh target packages: '
    local p first=1
    while IFS= read -r p; do ((first)) || printf ', '; printf '%s' "$p"; first=0; done < <(bootloader_packages "$target")
    printf '\n'
    case "$current:$target" in
        grub:limine)
            printf '  3. Verify existing kernel/initramfs images; do NOT rebuild them just to stage Limine.\n'
            printf '  4. Create transaction-owned /etc/default/limine and the captured CachyOS Limine palette/branding base from the known-good running cmdline and detected ESP.\n'
            printf '  5. Install the canonical CachyOS limine-splash.png, stage every installed kernel with limine-entry-tool, then run limine-install plus limine-install --fallback.\n'
            printf '  6. Immediately put source GRUB back first in persistent BootOrder.\n'
            printf '  7. Verify source GRUB EFI/NVRAM, config and kernel artifacts are unchanged and record exact target splash/fallback ownership.\n'
            printf '  8. Deep-validate Limine cmdlines, limine.conf entries, staged paths, BLAKE2 hashes and the CachyOS theme/splash.\n'
            ;;
        limine:grub)
            printf '  3. Re-confirm each source Limine kernel/initramfs BLAKE2 identity; preserve independently valid pre-existing conventional initramfs images, and create only missing conventional /boot artifacts for GRUB.\n'
            printf '  4. Create transaction-owned /etc/default/grub preserving known-good non-loader cmdline tokens and explicitly prefer the regular CachyOS kernel with GRUB_TOP_LEVEL.\n'
            printf '  5. Run grub-install against the detected ESP.\n'
            printf '  6. Immediately put source Limine back first in persistent BootOrder and restore its EFI/BOOT fallback if GRUB touched it.\n'
            printf '  7. Generate /boot/grub/grub.cfg and verify source Limine EFI, limine.conf, policy, managed kernel tree and fallback are unchanged.\n'
            printf '  8. Deep-validate privileged GRUB root/boot topology probes, grub.cfg syntax, every installed kernel/initramfs, root UUID/cmdline preservation and regular-before-LTS order.\n'
            ;;
    esac
    printf '  9. Verify target EFI executable (%s) and exact target NVRAM entry.\n' "$expected"
    printf ' 10. Capture a user-owned diagnostic snapshot and persist candidate-ready transaction metadata.\n'
    if { [[ $current == limine && $target == grub ]] && declare -F r22_after_fresh_limine_to_grub_candidate >/dev/null 2>&1; } || \
       { [[ $current == grub && $target == limine ]] && declare -F r23_after_fresh_grub_to_limine_candidate >/dev/null 2>&1; }; then
        printf ' 11. Record the exact CachyOS presentation assets in the transaction ownership manifest.\n'
        printf ' 12. Revalidate source + target, then arm one-time BootNext to the target automatically while the source remains first in persistent BootOrder.\n'
        printf ' 13. Install a temporary root-owned one-shot systemd resume bundle/service for the exact transaction.\n'
        printf ' 14. Prompt before rebooting. If reboot is deferred, the one-time test remains armed for the next normal reboot.\n'
        printf ' 15. After the test boot, automatically run runtime validation. Only if every gate passes: promote the target, retire ownership-proven source state, and validate the target/theme again.\n'
        printf '  If target runtime proof fails, no source cleanup is attempted and the automatic resume service disables itself.\n'
    else
        printf ' 11. STOP at candidate-ready with the source bootloader still first and BootNext unset.\n'
        printf '  No source bootloader cleanup is performed during candidate staging.\n'
    fi
}

confirm_operation() {
    local current=$1 target=$2 token answer
    if [[ $current == "$target" ]]; then token=REPAIR; else token=STAGE; fi
    printf '\nThis is the write boundary. No boot state has been modified yet.\n'
    read -r -p "Type $token to execute, or anything else to cancel: " answer
    [[ $answer == "$token" ]]
}

install_target_packages() {
    local target=$1 pkgs=() p removed_legacy_entry_tool=0
    while IFS= read -r p; do [[ -n $p ]] && pkgs+=("$p"); done < <(bootloader_packages "$target")
    ((${#pkgs[@]})) || return 1

    if [[ $target == limine ]] && ! pacman -Q limine-mkinitcpio-hook >/dev/null 2>&1 \
       && pacman -Q limine-entry-tool >/dev/null 2>&1; then
        info 'Transitioning legacy standalone limine-entry-tool to CachyOS limine-mkinitcpio-hook.'
        if ! sudo pacman -R --noconfirm -- limine-entry-tool; then
            fail 'Could not remove the legacy standalone limine-entry-tool package; no Limine candidate was staged.'
            return 1
        fi
        removed_legacy_entry_tool=1
    fi

    if sudo pacman -S --needed --noconfirm -- "${pkgs[@]}"; then
        if [[ $target == limine ]]; then
            have limine-entry-tool || {
                fail 'limine-mkinitcpio-hook installed, but its limine-entry-tool command is unavailable.'
                return 1
            }
            have limine-mkinitcpio || {
                fail 'limine-mkinitcpio-hook installed, but limine-mkinitcpio is unavailable.'
                return 1
            }
        fi
        return 0
    fi

    if ((removed_legacy_entry_tool)); then
        warn 'Canonical Limine package installation failed; attempting to restore the previous standalone limine-entry-tool package.'
        sudo pacman -S --needed --noconfirm -- limine-entry-tool >/dev/null 2>&1 || \
            warn 'Could not automatically restore limine-entry-tool; boot source was not modified, but package state needs manual review.'
    fi
    return 1
}

snapshot_grub_fallback_ownership() {
    OLD_GRUB_EFI_RESOLVED=""
    OLD_FALLBACK_PATH="$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"
    OLD_FALLBACK_HASH=""
    OLD_GRUB_HASH=""
    OLD_FALLBACK_WAS_GRUB=0
    OLD_FALLBACK_EXISTED=0
    OLD_FALLBACK_SNAPSHOT=""
    POST_STAGE_FALLBACK_HASH=""
    TRANSACTION_SNAPSHOT_DIR=""

    OLD_GRUB_EFI_RESOLVED=$(resolve_efi_path_on_esp_privileged "$BOOT_EFI_PATH" 2>/dev/null || true)
    [[ -n $OLD_GRUB_EFI_RESOLVED ]] || { fail 'Could not resolve the active GRUB EFI executable before staging'; return 1; }
    OLD_GRUB_HASH=$(sudo -n sha256sum -- "$OLD_GRUB_EFI_RESOLVED" 2>/dev/null | awk '{print $1}' || true)
    [[ -n $OLD_GRUB_HASH ]] || { fail 'Could not hash the active GRUB EFI executable before staging'; return 1; }

    mkdir -p -- "$PENDING_STATE_DIR" || return 1
    chmod 700 -- "$PENDING_STATE_DIR" 2>/dev/null || true
    TRANSACTION_SNAPSHOT_DIR=$(mktemp -d "$PENDING_STATE_DIR/.prestage.XXXXXX") || return 1
    chmod 700 -- "$TRANSACTION_SNAPSHOT_DIR" 2>/dev/null || true

    if sudo -n test -f "$OLD_FALLBACK_PATH" 2>/dev/null || [[ -f $OLD_FALLBACK_PATH ]]; then
        OLD_FALLBACK_EXISTED=1
        OLD_FALLBACK_HASH=$(sudo -n sha256sum -- "$OLD_FALLBACK_PATH" 2>/dev/null | awk '{print $1}' || sha256sum -- "$OLD_FALLBACK_PATH" 2>/dev/null | awk '{print $1}' || true)
        [[ -n $OLD_FALLBACK_HASH ]] || { fail 'Could not hash the pre-stage UEFI fallback executable'; return 1; }
        OLD_FALLBACK_SNAPSHOT="$TRANSACTION_SNAPSHOT_DIR/BOOTX64.EFI.before"
        if [[ -r $OLD_FALLBACK_PATH ]]; then
            cat -- "$OLD_FALLBACK_PATH" >"$OLD_FALLBACK_SNAPSHOT" || return 1
        else
            sudo -n cat -- "$OLD_FALLBACK_PATH" >"$OLD_FALLBACK_SNAPSHOT" || return 1
        fi
        chmod 600 -- "$OLD_FALLBACK_SNAPSHOT" 2>/dev/null || true
        [[ $(sha256sum -- "$OLD_FALLBACK_SNAPSHOT" | awk '{print $1}') == "$OLD_FALLBACK_HASH" ]] || {
            fail 'Internal fallback snapshot hash mismatch; refusing to cross the write boundary'
            return 1
        }
        if [[ $OLD_FALLBACK_HASH == "$OLD_GRUB_HASH" ]]; then
            OLD_FALLBACK_WAS_GRUB=1
        fi
    fi
    return 0
}

snapshot_source_boot_artifacts() {
    SOURCE_STAGE_ARTIFACTS=()
    SOURCE_STAGE_HASHES=()
    collect_kernels
    local ver kid path hash
    for ver in "${KERNEL_VERSIONS[@]}"; do
        kid=$(kernel_pkgbase_for_version "$ver" 2>/dev/null || true)
        [[ -n $kid ]] || { fail "Could not resolve pkgbase for $ver while snapshotting source artifacts"; return 1; }
        for path in "/boot/vmlinuz-$kid" "/boot/initramfs-$kid.img"; do
            hash=$(sudo -n sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || true)
            [[ -n $hash ]] || { fail "Could not hash source boot artifact: $path"; return 1; }
            SOURCE_STAGE_ARTIFACTS+=("$path")
            SOURCE_STAGE_HASHES+=("$hash")
        done
    done
    ok "Snapshotted hashes for ${#SOURCE_STAGE_ARTIFACTS[@]} source kernel/initramfs artifact(s)"
}

verify_source_boot_artifacts_unchanged() {
    local i path expected actual failures=0
    for ((i=0; i<${#SOURCE_STAGE_ARTIFACTS[@]}; i++)); do
        path=${SOURCE_STAGE_ARTIFACTS[$i]}
        expected=${SOURCE_STAGE_HASHES[$i]}
        actual=$(sudo -n sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || true)
        if [[ -n $actual && $actual == "$expected" ]]; then
            ok "Source artifact unchanged: $path"
        else
            fail "Source artifact changed during staging: $path"
            ((failures++))
        fi
    done
    ((failures == 0))
}

verify_source_grub_recovery_state() {
    local old_id=${1^^} current_hash order first
    nvram_id_matches_path "$old_id" "$BOOT_EFI_PATH" || { fail "Source Boot$old_id no longer points to the recorded GRUB EFI path"; return 1; }
    current_hash=$(sudo -n sha256sum -- "$OLD_GRUB_EFI_RESOLVED" 2>/dev/null | awk '{print $1}' || true)
    [[ -n $current_hash && $current_hash == "$OLD_GRUB_HASH" ]] || { fail 'The active GRUB EFI executable changed during target staging'; return 1; }
    order=$(efibootmgr 2>/dev/null | awk -F': ' '/^BootOrder:/ {print $2; exit}')
    first=${order%%,*}
    [[ ${first^^} == "$old_id" ]] || { fail "GRUB recovery invariant failed: expected Boot$old_id first in persistent BootOrder"; return 1; }
    ok 'Recorded GRUB EFI/NVRAM recovery path is unchanged and first in persistent BootOrder'
}

write_limine_candidate_policy() {
    local cmdline tmp
    [[ ! -e /etc/default/limine ]] || { fail '/etc/default/limine appeared after preflight; refusing to overwrite it'; return 1; }
    cmdline=$(cat /proc/cmdline 2>/dev/null || true)
    [[ -n $cmdline ]] || { fail 'Running kernel cmdline is empty; cannot materialize Limine policy'; return 1; }
    [[ $cmdline != *$'\n'* && $cmdline != *$'\r'* ]] || { fail 'Running kernel cmdline contains a line break; refusing unsafe policy serialization'; return 1; }
    [[ -n $ESP_MOUNT ]] || { fail 'ESP mountpoint is unresolved'; return 1; }

    tmp=$(mktemp) || return 1
    chmod 600 -- "$tmp" 2>/dev/null || true
    # Keep the generated policy intentionally small and directly comparable to
    # the clean CachyOS/Calamares Limine control installation.
    printf 'ESP_PATH="%s"\n' "$ESP_MOUNT" >"$tmp"
    # limine-entry-tool accepts the command line as the raw value after '=';
    # leaving off outer quotes preserves legitimate quote characters inside
    # parameters such as acpi_osi="...".
    printf 'KERNEL_CMDLINE[default]+=%s\n' "$cmdline" >>"$tmp"
    printf 'BOOT_ORDER="*, *lts, *fallback, Snapshots"\n' >>"$tmp"

    sudo install -o root -g root -m 0644 -- "$tmp" /etc/default/limine || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
    LIMINE_DEFAULT_CREATED=1
    LIMINE_DEFAULT_HASH=$(sha256sum /etc/default/limine 2>/dev/null | awk '{print $1}' || sudo -n sha256sum /etc/default/limine 2>/dev/null | awk '{print $1}' || true)
    [[ -n $LIMINE_DEFAULT_HASH ]] || { fail 'Could not hash generated /etc/default/limine'; return 1; }
    ok 'Created transaction-owned /etc/default/limine from the running cmdline and detected ESP'
}

stage_limine_kernel_entries_from_existing_artifacts() {
    have limine-entry-tool || { fail 'limine-entry-tool is unavailable after package installation'; return 1; }
    collect_kernels
    local ver kid kernel_path initrd_path effective
    for ver in "${KERNEL_VERSIONS[@]}"; do
        kid=$(kernel_pkgbase_for_version "$ver" 2>/dev/null || true)
        [[ -n $kid ]] || { fail "Could not resolve pkgbase for installed kernel $ver"; return 1; }
        kernel_path="/boot/vmlinuz-$kid"
        initrd_path="/boot/initramfs-$kid.img"
        (sudo -n test -f "$kernel_path" 2>/dev/null || [[ -f $kernel_path ]]) || { fail "Kernel source disappeared before Limine staging: $kernel_path"; return 1; }
        (sudo -n test -f "$initrd_path" 2>/dev/null || [[ -f $initrd_path ]]) || { fail "Initramfs source disappeared before Limine staging: $initrd_path"; return 1; }

        # limine-entry-tool 1.37.x accepts an explicit suffix positional
        # argument; an empty suffix creates the normal kernel entry.
        if ! sudo limine-entry-tool --add-kernel "$kid" "$initrd_path" "$kernel_path" "" --comment "kernel-version=$ver" --quiet; then
            fail "limine-entry-tool failed while staging $kid ($ver)"
            return 1
        fi
        effective=$(limine-entry-tool --get-cmdline "$kid" 2>/dev/null || true)
        [[ -n $effective ]] || { fail "Effective Limine cmdline is empty after staging $kid"; return 1; }
        ok "Staged Limine kernel entry from existing artifacts: $kid ($ver)"
    done
}

snapshot_limine_candidate_metadata() {
    local fallback="$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"
    TARGET_EFI_RESOLVED=$(resolve_efi_path_on_esp_privileged "$(target_expected_efi_path limine)" 2>/dev/null || true)
    [[ -n $TARGET_EFI_RESOLVED ]] || { fail 'Could not resolve staged Limine EFI executable for ownership metadata'; return 1; }
    TARGET_EFI_HASH=$(sudo -n sha256sum -- "$TARGET_EFI_RESOLVED" 2>/dev/null | awk '{print $1}' || true)
    [[ -n $TARGET_EFI_HASH ]] || { fail 'Could not hash staged Limine EFI executable'; return 1; }

    TARGET_LIMINE_CONF_PATH="$ESP_MOUNT/limine.conf"
    TARGET_LIMINE_CONF_HASH=$(sudo -n sha256sum -- "$TARGET_LIMINE_CONF_PATH" 2>/dev/null | awk '{print $1}' || sha256sum -- "$TARGET_LIMINE_CONF_PATH" 2>/dev/null | awk '{print $1}' || true)
    [[ -n $TARGET_LIMINE_CONF_HASH ]] || { fail 'Could not hash staged limine.conf'; return 1; }

    local machine_id
    machine_id=$(cat /etc/machine-id 2>/dev/null || true)
    [[ -n $machine_id ]] || { fail 'Machine ID is unavailable while recording candidate ownership'; return 1; }
    TARGET_LIMINE_MANAGED_DIR="$ESP_MOUNT/$machine_id"
    (sudo -n test -d "$TARGET_LIMINE_MANAGED_DIR" 2>/dev/null || [[ -d $TARGET_LIMINE_MANAGED_DIR ]]) || { fail 'Expected Limine managed kernel directory is missing after staging'; return 1; }

    if sudo -n test -f "$fallback" 2>/dev/null || [[ -f $fallback ]]; then
        POST_STAGE_FALLBACK_HASH=$(sudo -n sha256sum -- "$fallback" 2>/dev/null | awk '{print $1}' || sha256sum -- "$fallback" 2>/dev/null | awk '{print $1}' || true)
    else
        POST_STAGE_FALLBACK_HASH=""
    fi
    ok 'Recorded hashes/paths for transaction-owned Limine candidate state'
}

restore_pre_stage_fallback_best_effort() {
    local fallback="$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI" current_hash
    if ((OLD_FALLBACK_EXISTED)); then
        [[ -n $OLD_FALLBACK_SNAPSHOT && -f $OLD_FALLBACK_SNAPSHOT ]] || { fail 'Pre-stage fallback snapshot is unavailable'; return 1; }
        current_hash=$(sudo -n sha256sum -- "$fallback" 2>/dev/null | awk '{print $1}' || true)
        if [[ $current_hash != "$OLD_FALLBACK_HASH" ]]; then
            sudo mkdir -p -- "$(dirname -- "$fallback")" || return 1
            sudo install -m 0644 -- "$OLD_FALLBACK_SNAPSHOT" "$fallback" || return 1
            ok 'Restored the pre-stage UEFI fallback executable'
        fi
    else
        if sudo -n test -f "$fallback" 2>/dev/null; then
            sudo rm -f -- "$fallback" || return 1
            ok 'Removed transaction-created UEFI fallback executable'
        fi
    fi
    return 0
}

cleanup_uncommitted_limine_candidate() {
    local original_order=$1 old_id=${2^^} expected_path id path current_order
    expected_path=$(target_expected_efi_path limine)
    printf '\nRecovering from an uncommitted Limine stage:\n'

    # Preflight proved there was no Limine target namespace before this
    # transaction, so an exact-path entry/file created now is transaction-owned.
    while IFS= read -r id; do
        [[ -n $id ]] || continue
        path=$(boot_entry_path_for_id "$id" 2>/dev/null || true)
        [[ -n $path ]] || continue
        if [[ $(normalize_efi_path "$path" | tr '[:upper:]' '[:lower:]') == $(normalize_efi_path "$expected_path" | tr '[:upper:]' '[:lower:]') ]]; then
            sudo efibootmgr -b "$id" -B >/dev/null 2>&1 && ok "Removed uncommitted Limine NVRAM entry Boot$id"
        fi
    done < <(efibootmgr -v 2>/dev/null | sed -nE 's/^Boot([0-9A-Fa-f]{4})\*?.*/\1/p')

    local target_efi
    target_efi=$(resolve_efi_path_on_esp_privileged "$expected_path" 2>/dev/null || true)
    if [[ -n $target_efi ]]; then
        sudo rm -f -- "$target_efi" >/dev/null 2>&1 && ok 'Removed uncommitted Limine EFI executable'
        sudo rmdir -- "$(dirname -- "$target_efi")" 2>/dev/null || true
    fi
    if sudo -n test -f "$ESP_MOUNT/limine.conf" 2>/dev/null || [[ -f $ESP_MOUNT/limine.conf ]]; then
        sudo rm -f -- "$ESP_MOUNT/limine.conf" >/dev/null 2>&1 && ok 'Removed uncommitted limine.conf'
    fi
    local machine_id managed_dir
    machine_id=$(cat /etc/machine-id 2>/dev/null || true)
    managed_dir="$ESP_MOUNT/$machine_id"
    if [[ -n $machine_id ]] && sudo -n test -d "$managed_dir" 2>/dev/null; then
        sudo rm -rf -- "$managed_dir" >/dev/null 2>&1 && ok 'Removed uncommitted Limine managed kernel directory'
    fi
    if ((LIMINE_DEFAULT_CREATED)) && [[ -e /etc/default/limine ]]; then
        sudo rm -f -- /etc/default/limine >/dev/null 2>&1 && ok 'Removed transaction-created /etc/default/limine'
    fi
    restore_pre_stage_fallback_best_effort || warn 'Could not fully restore the pre-stage UEFI fallback state'

    if [[ -n $original_order ]]; then
        sudo efibootmgr -o "$original_order" >/dev/null 2>&1 || true
    fi
    current_order=$(efibootmgr 2>/dev/null | awk -F': ' '/^BootOrder:/ {print $2; exit}')
    if [[ -n $old_id && ${current_order%%,*} == "$old_id" ]]; then
        ok "Persistent BootOrder is back to the original source-first state (Boot$old_id first)"
    else
        info "Current BootOrder after recovery: ${current_order:-unavailable}"
    fi

    [[ -n $TRANSACTION_SNAPSHOT_DIR ]] && rm -rf -- "$TRANSACTION_SNAPSHOT_DIR" 2>/dev/null || true
}

validate_target_state() {
    local target=$1 expected failures=0 nvram_count
    expected=$(target_expected_efi_path "$target")
    printf '\nTarget validation (%s):\n' "$(bootloader_display_name "$target")"

    if path_exists_on_esp_privileged "$expected"; then
        ok "Target EFI executable exists: $expected"
    else
        fail "Target EFI executable is missing: $expected"
        ((failures++))
    fi

    nvram_count=$(count_nvram_entries_for_target "$target")
    if [[ $nvram_count == 1 ]] && find_nvram_entry_for_target "$target"; then
        ok "Exactly one target NVRAM entry exists at the expected path (Boot$TARGET_NVRAM_ID)"
    elif [[ $nvram_count == 0 ]]; then
        fail 'Target NVRAM entry could not be found'
        ((failures++))
    else
        fail "Found $nvram_count target NVRAM entries at the expected path; ownership is ambiguous"
        ((failures++))
    fi

    collect_kernels
    if ((${#KERNEL_IMAGES[@]})); then ok "${#KERNEL_IMAGES[@]} installed kernel image(s) still present"; else fail 'No installed kernel images found'; ((failures++)); fi
    if findmnt --verify --tab-file /etc/fstab >/dev/null 2>&1; then ok '/etc/fstab still passes verification'; else fail '/etc/fstab verification failed'; ((failures++)); fi
    collect_storage_info
    if [[ -n $ESP_SOURCE && -n $ESP_MOUNT ]]; then ok "ESP remains mounted at $ESP_MOUNT from $ESP_SOURCE"; else fail 'ESP is no longer resolved/mounted'; ((failures++)); fi

    ((failures == 0))
}

set_target_first_preserving_other_entries() {
    local target_id=$1 old_id=$2 out order ids=() id joined
    out=$(efibootmgr 2>/dev/null) || return 1
    order=$(awk -F': ' '/^BootOrder:/ {print $2; exit}' <<<"$out")
    ids+=("$target_id")
    IFS=',' read -ra _existing <<<"$order"
    for id in "${_existing[@]}"; do
        id=${id^^}
        [[ -n $id && $id != "$old_id" && $id != "$target_id" ]] || continue
        ids+=("$id")
    done
    joined=$(IFS=,; printf '%s' "${ids[*]}")
    sudo efibootmgr -o "$joined"
}

cleanup_old_grub_after_limine() {
    local old_id=$1
    printf '\nCleaning old GRUB boot state (target has actually booted and passed validation):\n'

    if ! set_target_first_preserving_other_entries "$TARGET_NVRAM_ID" "$old_id"; then
        fail 'Could not set the target NVRAM entry first. Old GRUB state was NOT removed.'
        return 1
    fi
    ok "BootOrder now prioritizes Boot$TARGET_NVRAM_ID while preserving unrelated entries"

    if [[ -n $old_id ]] && boot_id_exists "$old_id"; then
        if [[ -n ${PENDING_OLD_BOOT_EFI_PATH:-} ]] && ! nvram_id_matches_path "$old_id" "$PENDING_OLD_BOOT_EFI_PATH"; then
            fail "Boot$old_id no longer matches the recorded GRUB EFI path; refusing to delete it"
            return 1
        fi
        if sudo efibootmgr -b "$old_id" -B; then
            ok "Removed old GRUB NVRAM entry Boot$old_id"
        else
            fail "Could not remove old GRUB NVRAM entry Boot$old_id"
            return 1
        fi
    elif [[ -n $old_id ]]; then
        info "Old GRUB NVRAM entry Boot$old_id is already absent"
    fi

    if [[ -n ${OLD_GRUB_EFI_RESOLVED:-} ]] && sudo test -f "$OLD_GRUB_EFI_RESOLVED" 2>/dev/null; then
        if [[ -z ${OLD_GRUB_HASH:-} ]]; then
            fail 'Recorded GRUB EFI hash is unavailable; refusing to delete the EFI executable'
            return 1
        fi
        local current_grub_hash
        current_grub_hash=$(sudo sha256sum -- "$OLD_GRUB_EFI_RESOLVED" 2>/dev/null | awk '{print $1}' || true)
        if [[ -z $current_grub_hash || $current_grub_hash != "$OLD_GRUB_HASH" ]]; then
            fail 'GRUB EFI executable changed since staging; refusing to delete it'
            return 1
        fi
        sudo rm -f -- "$OLD_GRUB_EFI_RESOLVED" || return 1
        sudo rmdir -- "$(dirname -- "$OLD_GRUB_EFI_RESOLVED")" 2>/dev/null || true
        ok "Removed unchanged recorded GRUB EFI executable: $OLD_GRUB_EFI_RESOLVED"
    fi

    if sudo test -d /boot/grub 2>/dev/null; then
        sudo rm -rf -- /boot/grub || return 1
        ok 'Removed old GRUB-owned /boot/grub directory'
    fi

    # The fallback path is deleted only if it was byte-identical to GRUB before
    # target installation AND target installation left those exact bytes there.
    # A clean CachyOS Limine install normally owns an EFI/BOOT fallback, so any
    # changed fallback is preserved rather than guessed to be stale.
    if ((OLD_FALLBACK_WAS_GRUB)) && [[ -n $OLD_FALLBACK_PATH && -n $OLD_FALLBACK_HASH ]] && sudo test -f "$OLD_FALLBACK_PATH" 2>/dev/null; then
        local now_hash
        now_hash=$(sudo sha256sum -- "$OLD_FALLBACK_PATH" 2>/dev/null | awk '{print $1}' || true)
        if [[ -n $now_hash && $now_hash == "$OLD_FALLBACK_HASH" ]]; then
            sudo rm -f -- "$OLD_FALLBACK_PATH" || return 1
            ok 'Removed unchanged stale GRUB-owned UEFI fallback executable'
        else
            info 'UEFI fallback executable differs from the old GRUB fallback; retained as target/non-GRUB state.'
        fi
    fi
    return 0
}

hash_directory_tree_privileged() {
    local dir=$1 tmp path hash
    tmp=$(mktemp) || return 1
    : >"$tmp"
    while IFS= read -r -d '' path; do
        [[ $path != *$'\n'* && $path != *$'\r'* && $path != *$'\t'* ]] || { rm -f -- "$tmp"; return 1; }
        hash=$(sudo -n sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || true)
        [[ -n $hash ]] || { rm -f -- "$tmp"; return 1; }
        printf '%s\t%s\n' "$hash" "$path" >>"$tmp"
    done < <(sudo -n find "$dir" -type f -print0 2>/dev/null | LC_ALL=C sort -z)
    [[ -s $tmp ]] || { rm -f -- "$tmp"; return 1; }
    sha256sum -- "$tmp" | awk '{print $1}'
    rm -f -- "$tmp"
}

snapshot_limine_source_ownership() {
    local fallback="$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI" machine_id snapshot_hash
    SOURCE_LIMINE_EFI_RESOLVED=""
    SOURCE_LIMINE_EFI_HASH=""
    SOURCE_LIMINE_CONF_PATH="$ESP_MOUNT/limine.conf"
    SOURCE_LIMINE_CONF_HASH=""
    SOURCE_LIMINE_DEFAULT_HASH=""
    SOURCE_LIMINE_MANAGED_DIR=""
    SOURCE_LIMINE_MANAGED_HASH=""
    OLD_FALLBACK_PATH=$fallback
    OLD_FALLBACK_HASH=""
    OLD_FALLBACK_EXISTED=0
    OLD_FALLBACK_SNAPSHOT=""
    POST_STAGE_FALLBACK_HASH=""
    TRANSACTION_SNAPSHOT_DIR=""
    GRUB_CREATED_ARTIFACTS=()
    GRUB_CREATED_HASHES=()
    GRUB_SHARED_ARTIFACTS=()
    GRUB_SHARED_HASHES=()

    SOURCE_LIMINE_EFI_RESOLVED=$(resolve_efi_path_on_esp_privileged "$BOOT_EFI_PATH" 2>/dev/null || true)
    [[ -n $SOURCE_LIMINE_EFI_RESOLVED ]] || { fail 'Could not resolve the active Limine EFI executable before staging'; return 1; }
    SOURCE_LIMINE_EFI_HASH=$(sudo -n sha256sum -- "$SOURCE_LIMINE_EFI_RESOLVED" 2>/dev/null | awk '{print $1}' || true)
    [[ -n $SOURCE_LIMINE_EFI_HASH ]] || { fail 'Could not hash the active Limine EFI executable before staging'; return 1; }

    SOURCE_LIMINE_CONF_HASH=$(sudo -n sha256sum -- "$SOURCE_LIMINE_CONF_PATH" 2>/dev/null | awk '{print $1}' || sha256sum -- "$SOURCE_LIMINE_CONF_PATH" 2>/dev/null | awk '{print $1}' || true)
    [[ -n $SOURCE_LIMINE_CONF_HASH ]] || { fail 'Could not hash source limine.conf before staging'; return 1; }
    SOURCE_LIMINE_DEFAULT_HASH=$(sha256sum /etc/default/limine 2>/dev/null | awk '{print $1}' || sudo -n sha256sum /etc/default/limine 2>/dev/null | awk '{print $1}' || true)
    [[ -n $SOURCE_LIMINE_DEFAULT_HASH ]] || { fail 'Could not hash source /etc/default/limine before staging'; return 1; }

    machine_id=$(cat /etc/machine-id 2>/dev/null || true)
    [[ -n $machine_id ]] || { fail 'Machine ID is unavailable'; return 1; }
    SOURCE_LIMINE_MANAGED_DIR="$ESP_MOUNT/$machine_id"
    sudo -n test -d "$SOURCE_LIMINE_MANAGED_DIR" 2>/dev/null || { fail "Source Limine managed directory is missing: $SOURCE_LIMINE_MANAGED_DIR"; return 1; }
    SOURCE_LIMINE_MANAGED_HASH=$(hash_directory_tree_privileged "$SOURCE_LIMINE_MANAGED_DIR" 2>/dev/null || true)
    [[ -n $SOURCE_LIMINE_MANAGED_HASH ]] || { fail 'Could not fingerprint the source Limine managed kernel tree'; return 1; }

    mkdir -p -- "$PENDING_STATE_DIR" || return 1
    chmod 700 -- "$PENDING_STATE_DIR" 2>/dev/null || true
    TRANSACTION_SNAPSHOT_DIR=$(mktemp -d "$PENDING_STATE_DIR/.prestage.XXXXXX") || return 1
    chmod 700 -- "$TRANSACTION_SNAPSHOT_DIR" 2>/dev/null || true
    if sudo -n test -f "$fallback" 2>/dev/null || [[ -f $fallback ]]; then
        OLD_FALLBACK_EXISTED=1
        OLD_FALLBACK_HASH=$(sudo -n sha256sum -- "$fallback" 2>/dev/null | awk '{print $1}' || sha256sum -- "$fallback" 2>/dev/null | awk '{print $1}' || true)
        [[ -n $OLD_FALLBACK_HASH ]] || { fail 'Could not hash the source UEFI fallback executable'; return 1; }
        OLD_FALLBACK_SNAPSHOT="$TRANSACTION_SNAPSHOT_DIR/BOOTX64.EFI.before"
        if [[ -r $fallback ]]; then cat -- "$fallback" >"$OLD_FALLBACK_SNAPSHOT"; else sudo -n cat -- "$fallback" >"$OLD_FALLBACK_SNAPSHOT"; fi || return 1
        chmod 600 -- "$OLD_FALLBACK_SNAPSHOT" 2>/dev/null || true
        snapshot_hash=$(sha256sum -- "$OLD_FALLBACK_SNAPSHOT" 2>/dev/null | awk '{print $1}' || true)
        [[ $snapshot_hash == "$OLD_FALLBACK_HASH" ]] || { fail 'Internal fallback snapshot hash mismatch'; return 1; }
    fi
    ok 'Snapshotted active Limine EFI/config/managed-tree/fallback ownership before GRUB staging'
}

verify_source_limine_recovery_state() {
    local old_id=${1^^} current_hash order first managed_hash fallback_hash
    nvram_id_matches_path "$old_id" "$BOOT_EFI_PATH" || { fail "Source Boot$old_id no longer points to the recorded Limine EFI path"; return 1; }
    current_hash=$(sudo -n sha256sum -- "$SOURCE_LIMINE_EFI_RESOLVED" 2>/dev/null | awk '{print $1}' || true)
    [[ -n $current_hash && $current_hash == "$SOURCE_LIMINE_EFI_HASH" ]] || { fail 'The active Limine EFI executable changed during GRUB staging'; return 1; }
    current_hash=$(sudo -n sha256sum -- "$SOURCE_LIMINE_CONF_PATH" 2>/dev/null | awk '{print $1}' || sha256sum -- "$SOURCE_LIMINE_CONF_PATH" 2>/dev/null | awk '{print $1}' || true)
    [[ -n $current_hash && $current_hash == "$SOURCE_LIMINE_CONF_HASH" ]] || { fail 'limine.conf changed during GRUB staging'; return 1; }
    current_hash=$(sha256sum /etc/default/limine 2>/dev/null | awk '{print $1}' || sudo -n sha256sum /etc/default/limine 2>/dev/null | awk '{print $1}' || true)
    [[ -n $current_hash && $current_hash == "$SOURCE_LIMINE_DEFAULT_HASH" ]] || { fail '/etc/default/limine changed during GRUB staging'; return 1; }
    managed_hash=$(hash_directory_tree_privileged "$SOURCE_LIMINE_MANAGED_DIR" 2>/dev/null || true)
    [[ -n $managed_hash && $managed_hash == "$SOURCE_LIMINE_MANAGED_HASH" ]] || { fail 'Limine managed kernel tree changed during GRUB staging'; return 1; }
    if [[ $OLD_FALLBACK_EXISTED == 1 ]]; then
        fallback_hash=$(sudo -n sha256sum -- "$OLD_FALLBACK_PATH" 2>/dev/null | awk '{print $1}' || true)
        [[ -n $fallback_hash && $fallback_hash == "$OLD_FALLBACK_HASH" ]] || { fail 'Source UEFI fallback executable changed during GRUB staging'; return 1; }
    else
        (sudo -n test ! -e "$OLD_FALLBACK_PATH" 2>/dev/null && [[ ! -e $OLD_FALLBACK_PATH ]]) || { fail 'A UEFI fallback exists even though the Limine source had none'; return 1; }
    fi
    order=$(efibootmgr 2>/dev/null | awk -F': ' '/^BootOrder:/ {print $2; exit}')
    first=${order%%,*}
    [[ ${first^^} == "$old_id" ]] || { fail "Limine recovery invariant failed: expected Boot$old_id first in persistent BootOrder"; return 1; }
    validate_limine_boot_chain migration || { fail 'Source Limine boot chain no longer passes deep validation'; return 1; }
    ok 'Recorded Limine EFI/config/managed-tree recovery state is unchanged and first in persistent BootOrder'
}

restore_source_fallback_after_grub_install() {
    local current_hash snapshot_hash
    if [[ $OLD_FALLBACK_EXISTED == 1 ]]; then
        current_hash=$(sudo -n sha256sum -- "$OLD_FALLBACK_PATH" 2>/dev/null | awk '{print $1}' || true)
        if [[ $current_hash == "$OLD_FALLBACK_HASH" ]]; then
            POST_STAGE_FALLBACK_HASH=$current_hash
            return 0
        fi
        [[ -f $OLD_FALLBACK_SNAPSHOT ]] || { fail 'Source fallback changed and pre-stage snapshot is unavailable'; return 1; }
        snapshot_hash=$(sha256sum -- "$OLD_FALLBACK_SNAPSHOT" 2>/dev/null | awk '{print $1}' || true)
        [[ $snapshot_hash == "$OLD_FALLBACK_HASH" ]] || { fail 'Source fallback snapshot hash mismatch'; return 1; }
        sudo mkdir -p -- "$(dirname -- "$OLD_FALLBACK_PATH")" || return 1
        sudo install -m 0644 -- "$OLD_FALLBACK_SNAPSHOT" "$OLD_FALLBACK_PATH" || return 1
        current_hash=$(sudo -n sha256sum -- "$OLD_FALLBACK_PATH" 2>/dev/null | awk '{print $1}' || true)
        [[ $current_hash == "$OLD_FALLBACK_HASH" ]] || { fail 'Could not restore source Limine fallback after grub-install'; return 1; }
        POST_STAGE_FALLBACK_HASH=$current_hash
        ok 'Restored source Limine UEFI fallback after GRUB installation touched it'
    else
        if sudo -n test -f "$OLD_FALLBACK_PATH" 2>/dev/null; then
            current_hash=$(sudo -n sha256sum -- "$OLD_FALLBACK_PATH" 2>/dev/null | awk '{print $1}' || true)
            POST_STAGE_FALLBACK_HASH=$current_hash
            sudo rm -f -- "$OLD_FALLBACK_PATH" || return 1
            ok 'Removed transaction-created fallback because the Limine source had none'
        fi
    fi
}

materialize_grub_boot_artifacts_from_limine() {
    local tmp ver kid path_value initrd_value kernel_source initrd_source kernel_target initrd_target source_hash target_hash
    GRUB_CREATED_ARTIFACTS=()
    GRUB_CREATED_HASHES=()
    tmp=$(mktemp) || return 1
    if [[ -r $SOURCE_LIMINE_CONF_PATH ]]; then
        cat -- "$SOURCE_LIMINE_CONF_PATH" >"$tmp"
    else
        sudo -n cat -- "$SOURCE_LIMINE_CONF_PATH" >"$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
    fi

    collect_kernels
    printf '\nMaterializing conventional GRUB kernel/initramfs artifacts from verified Limine state:\n'
    for ver in "${KERNEL_VERSIONS[@]}"; do
        kid=$(kernel_pkgbase_for_version "$ver" 2>/dev/null || true)
        [[ -n $kid ]] || { rm -f -- "$tmp"; fail "Could not resolve pkgbase for $ver"; return 1; }
        path_value=$(limine_conf_field_for_kernel "$kid" path "$tmp" 2>/dev/null || true)
        [[ -n $path_value ]] || path_value=$(limine_conf_field_for_kernel "$kid" kernel_path "$tmp" 2>/dev/null || true)
        initrd_value=$(limine_conf_field_for_kernel "$kid" module_path "$tmp" 2>/dev/null || true)
        [[ -n $path_value && -n $initrd_value ]] || { rm -f -- "$tmp"; fail "Could not find Limine kernel/initramfs references for $kid"; return 1; }
        verify_limine_uri_hash "$path_value" || { rm -f -- "$tmp"; fail "Source Limine kernel BLAKE2 hash check failed for $kid"; return 1; }
        verify_limine_uri_hash "$initrd_value" || { rm -f -- "$tmp"; fail "Source Limine initramfs BLAKE2 hash check failed for $kid"; return 1; }
        kernel_source=$(resolve_limine_boot_uri "$path_value" 2>/dev/null || true)
        initrd_source=$(resolve_limine_boot_uri "$initrd_value" 2>/dev/null || true)
        [[ -n $kernel_source && -n $initrd_source ]] || { rm -f -- "$tmp"; fail "Could not resolve Limine staged source artifacts for $kid"; return 1; }

        kernel_target="/boot/vmlinuz-$kid"
        initrd_target="/boot/initramfs-$kid.img"

        source_hash=$(sudo -n sha256sum -- "$kernel_source" 2>/dev/null | awk '{print $1}' || sha256sum -- "$kernel_source" 2>/dev/null | awk '{print $1}' || true)
        [[ -n $source_hash ]] || { rm -f -- "$tmp"; fail "Could not hash source Limine kernel artifact for $kid"; return 1; }
        if sudo -n test -e "$kernel_target" 2>/dev/null || [[ -e $kernel_target ]]; then
            target_hash=$(sudo -n sha256sum -- "$kernel_target" 2>/dev/null | awk '{print $1}' || sha256sum -- "$kernel_target" 2>/dev/null | awk '{print $1}' || true)
            [[ $target_hash == "$source_hash" ]] || { rm -f -- "$tmp"; fail "Pre-existing GRUB kernel artifact no longer matches validated Limine state for $kid"; return 1; }
            GRUB_SHARED_ARTIFACTS+=("$kernel_target"); GRUB_SHARED_HASHES+=("$target_hash")
            ok "Reusing source-shared bit-identical kernel artifact: $kernel_target"
        else
            sudo install -m 0644 -- "$kernel_source" "$kernel_target" || { rm -f -- "$tmp"; return 1; }
            target_hash=$(sudo -n sha256sum -- "$kernel_target" 2>/dev/null | awk '{print $1}' || true)
            [[ $target_hash == "$source_hash" ]] || { rm -f -- "$tmp"; fail "Copied GRUB kernel hash mismatch for $kid"; return 1; }
            GRUB_CREATED_ARTIFACTS+=("$kernel_target"); GRUB_CREATED_HASHES+=("$target_hash")
            ok "Created bit-identical GRUB kernel artifact: $kernel_target"
        fi

        source_hash=$(sudo -n sha256sum -- "$initrd_source" 2>/dev/null | awk '{print $1}' || sha256sum -- "$initrd_source" 2>/dev/null | awk '{print $1}' || true)
        [[ -n $source_hash ]] || { rm -f -- "$tmp"; fail "Could not hash source Limine initramfs artifact for $kid"; return 1; }
        if sudo -n test -e "$initrd_target" 2>/dev/null || [[ -e $initrd_target ]]; then
            target_hash=$(sudo -n sha256sum -- "$initrd_target" 2>/dev/null | awk '{print $1}' || sha256sum -- "$initrd_target" 2>/dev/null | awk '{print $1}' || true)
            [[ -n $target_hash ]] || { rm -f -- "$tmp"; fail "Could not hash pre-existing GRUB initramfs artifact for $kid"; return 1; }
            if [[ $target_hash == "$source_hash" ]]; then
                ok "Reusing source-shared bit-identical initramfs artifact: $initrd_target"
            elif grub_initramfs_matches_kernel_version "$initrd_target" "$ver"; then
                ok "Reusing source-shared conventional initramfs validated independently for $ver: $initrd_target"
            else
                rm -f -- "$tmp"
                fail "Pre-existing GRUB initramfs artifact changed or is not valid for $ver: $initrd_target"
                fail "Reason: ${GRUB_INITRAMFS_REASON:-unknown}"
                return 1
            fi
            GRUB_SHARED_ARTIFACTS+=("$initrd_target"); GRUB_SHARED_HASHES+=("$target_hash")
        else
            sudo install -m 0644 -- "$initrd_source" "$initrd_target" || { rm -f -- "$tmp"; return 1; }
            target_hash=$(sudo -n sha256sum -- "$initrd_target" 2>/dev/null | awk '{print $1}' || true)
            [[ $target_hash == "$source_hash" ]] || { rm -f -- "$tmp"; fail "Copied GRUB initramfs hash mismatch for $kid"; return 1; }
            GRUB_CREATED_ARTIFACTS+=("$initrd_target"); GRUB_CREATED_HASHES+=("$target_hash")
            ok "Created bit-identical GRUB initramfs artifact: $initrd_target"
        fi
    done
    rm -f -- "$tmp"
    return 0
}

shell_single_quote() {
    local s=$1
    s=${s//\'/\'\\\'\'}
    printf "'%s'" "$s"
}

write_grub_candidate_policy() {
    local cmdline token filtered="" encoded preferred top_encoded tmp
    [[ -f /usr/share/grub/themes/cachyos/theme.txt ]] || { fail 'CachyOS GRUB theme asset is missing: /usr/share/grub/themes/cachyos/theme.txt'; return 1; }
    cmdline=$(cat /proc/cmdline 2>/dev/null || true)
    [[ -n $cmdline ]] || { fail 'Running kernel cmdline is empty; cannot materialize GRUB policy'; return 1; }
    collect_kernels
    preferred=${KERNEL_PKGBASES[0]:-}
    [[ -n $preferred ]] || { fail 'Could not determine the preferred kernel for GRUB_TOP_LEVEL'; return 1; }
    for token in $cmdline; do
        case "$token" in BOOT_IMAGE=*|boot_image=*|initrd=*|root=*|rw|ro) continue ;; esac
        filtered+="${filtered:+ }$token"
    done
    encoded=$(shell_single_quote "$filtered")
    top_encoded=$(shell_single_quote "/boot/vmlinuz-$preferred")
    tmp=$(mktemp) || return 1
    chmod 600 -- "$tmp" 2>/dev/null || true
    {
        printf '# Managed by CachyOS Bootloader Switcher staged migration.\n'
        printf '# Preflight proved /etc/default/grub did not exist before this transaction.\n'
        printf 'GRUB_DEFAULT=0\n'
        printf 'GRUB_TIMEOUT=5\n'
        printf 'GRUB_TIMEOUT_STYLE=menu\n'
        printf 'GRUB_DISTRIBUTOR="CachyOS"\n'
        printf 'GRUB_TOP_LEVEL=%s\n' "$top_encoded"
        printf 'GRUB_THEME="/usr/share/grub/themes/cachyos/theme.txt"\n'
        printf 'GRUB_CMDLINE_LINUX_DEFAULT=%s\n' "$encoded"
        printf 'GRUB_CMDLINE_LINUX=""\n'
        printf 'GRUB_DISABLE_RECOVERY=true\n'
        printf 'GRUB_DISABLE_OS_PROBER=true\n'
    } >"$tmp"
    # Installing the grub package can create its packaged /etc/default/grub.
    # Preflight proved there was no user-owned file before the transaction, so
    # replacing that package-created file here is ownership-safe.
    sudo install -o root -g root -m 0644 -- "$tmp" /etc/default/grub || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
    GRUB_DEFAULT_CREATED=1
    GRUB_DEFAULT_HASH=$(sha256sum /etc/default/grub 2>/dev/null | awk '{print $1}' || sudo -n sha256sum /etc/default/grub 2>/dev/null | awk '{print $1}' || true)
    [[ -n $GRUB_DEFAULT_HASH ]] || { fail 'Could not hash generated /etc/default/grub'; return 1; }
    ok "Created deterministic /etc/default/grub; preferred top-level kernel is $preferred"
}

write_privileged_tree_manifest() {
    local root=$1 out=$2 path type identity target count=0
    : >"$out" || return 1
    while IFS= read -r -d '' path; do
        [[ $path != *$'\n'* && $path != *$'\r'* && $path != *$'\t'* ]] || return 1
        if sudo -n test -L "$path" 2>/dev/null; then
            type=l
            target=$(sudo -n readlink -- "$path" 2>/dev/null || true)
            [[ $target != *$'\n'* && $target != *$'\r'* && $target != *$'\t'* ]] || return 1
            identity=$(printf '%s' "$target" | sha256sum | awk '{print $1}')
        elif sudo -n test -f "$path" 2>/dev/null; then
            type=f
            identity=$(sudo -n sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || true)
        elif sudo -n test -d "$path" 2>/dev/null; then
            type=d
            identity='-'
        else
            # Device/special nodes are not expected in these transaction-owned
            # bootloader trees. Refuse to claim ownership if one appears.
            return 1
        fi
        [[ -n $identity ]] || return 1
        printf '%s\t%s\t%s\n' "$type" "$identity" "$path" >>"$out" || return 1
        ((count++))
    done < <(sudo -n find "$root" -mindepth 1 -print0 2>/dev/null | LC_ALL=C sort -z)
    ((count > 0))
}

snapshot_grub_candidate_metadata() {
    local i fallback="$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"
    TARGET_EFI_RESOLVED=$(resolve_efi_path_on_esp_privileged "$(target_expected_efi_path grub)" 2>/dev/null || true)
    [[ -n $TARGET_EFI_RESOLVED ]] || { fail 'Could not resolve staged GRUB EFI executable'; return 1; }
    TARGET_EFI_HASH=$(sudo -n sha256sum -- "$TARGET_EFI_RESOLVED" 2>/dev/null | awk '{print $1}' || true)
    [[ -n $TARGET_EFI_HASH ]] || { fail 'Could not hash staged GRUB EFI executable'; return 1; }
    TARGET_GRUB_DIR=/boot/grub
    TARGET_GRUB_CFG_PATH=/boot/grub/grub.cfg
    TARGET_GRUB_CFG_HASH=$(sudo -n sha256sum -- "$TARGET_GRUB_CFG_PATH" 2>/dev/null | awk '{print $1}' || sha256sum -- "$TARGET_GRUB_CFG_PATH" 2>/dev/null | awk '{print $1}' || true)
    [[ -n $TARGET_GRUB_CFG_HASH ]] || { fail 'Could not hash generated grub.cfg'; return 1; }
    [[ -n $TRANSACTION_SNAPSHOT_DIR && -d $TRANSACTION_SNAPSHOT_DIR ]] || { fail 'Transaction snapshot directory is unavailable'; return 1; }

    GRUB_ARTIFACT_MANIFEST="$TRANSACTION_SNAPSHOT_DIR/grub-artifacts.tsv"
    : >"$GRUB_ARTIFACT_MANIFEST" || return 1
    for ((i=0; i<${#GRUB_CREATED_ARTIFACTS[@]}; i++)); do
        printf 'created\t%s\t%s\n' "${GRUB_CREATED_HASHES[$i]}" "${GRUB_CREATED_ARTIFACTS[$i]}" >>"$GRUB_ARTIFACT_MANIFEST" || return 1
    done
    for ((i=0; i<${#GRUB_SHARED_ARTIFACTS[@]}; i++)); do
        printf 'shared\t%s\t%s\n' "${GRUB_SHARED_HASHES[$i]}" "${GRUB_SHARED_ARTIFACTS[$i]}" >>"$GRUB_ARTIFACT_MANIFEST" || return 1
    done
    [[ -s $GRUB_ARTIFACT_MANIFEST ]] || { fail 'GRUB artifact manifest is empty'; return 1; }

    GRUB_DIR_MANIFEST="$TRANSACTION_SNAPSHOT_DIR/grub-dir.tsv"
    write_privileged_tree_manifest /boot/grub "$GRUB_DIR_MANIFEST" || { fail 'Could not record exact /boot/grub manifest'; return 1; }
    TARGET_GRUB_EFI_DIR="$ESP_MOUNT/EFI/CACHYOS"
    GRUB_EFI_DIR_MANIFEST="$TRANSACTION_SNAPSHOT_DIR/grub-efi-dir.tsv"
    write_privileged_tree_manifest "$TARGET_GRUB_EFI_DIR" "$GRUB_EFI_DIR_MANIFEST" || { fail 'Could not record exact GRUB EFI directory manifest'; return 1; }

    local theme_manifest="$TRANSACTION_SNAPSHOT_DIR/grub-theme-dir.tsv"
    write_privileged_tree_manifest /usr/share/grub/themes/cachyos "$theme_manifest" || { fail 'Could not record exact CachyOS GRUB theme manifest'; return 1; }
    printf 'required\n' >"$TRANSACTION_SNAPSHOT_DIR/grub-theme-required" || return 1
    chmod 600 -- "$GRUB_ARTIFACT_MANIFEST" "$GRUB_DIR_MANIFEST" "$GRUB_EFI_DIR_MANIFEST" "$theme_manifest" "$TRANSACTION_SNAPSHOT_DIR/grub-theme-required" 2>/dev/null || true
    if sudo -n test -f "$fallback" 2>/dev/null || [[ -f $fallback ]]; then
        POST_STAGE_FALLBACK_HASH=$(sudo -n sha256sum -- "$fallback" 2>/dev/null | awk '{print $1}' || sha256sum -- "$fallback" 2>/dev/null | awk '{print $1}' || true)
    else
        POST_STAGE_FALLBACK_HASH=""
    fi
    ok 'Recorded exact hashes/manifests for GRUB candidate state, including created vs source-shared artifacts'
}

cleanup_uncommitted_grub_candidate() {
    local original_order=$1 old_id=${2^^} expected_path id path current_order artifact
    expected_path=$(target_expected_efi_path grub)
    printf '\nBest-effort rollback of uncommitted GRUB candidate:\n'

    while IFS= read -r id; do
        [[ -n $id ]] || continue
        path=$(boot_entry_path_for_id "$id" 2>/dev/null || true)
        [[ -n $path ]] || continue
        if [[ $(normalize_efi_path "$path" | tr '[:upper:]' '[:lower:]') == $(normalize_efi_path "$expected_path" | tr '[:upper:]' '[:lower:]') ]]; then
            sudo efibootmgr -b "$id" -B >/dev/null 2>&1 && ok "Removed uncommitted GRUB NVRAM entry Boot$id" || true
        fi
    done < <(efibootmgr -v 2>/dev/null | sed -nE 's/^Boot([0-9A-Fa-f]{4})\*?.*/\1/p')

    if sudo -n test -d "$ESP_MOUNT/EFI/CACHYOS" 2>/dev/null || [[ -d $ESP_MOUNT/EFI/CACHYOS ]]; then
        sudo rm -rf -- "$ESP_MOUNT/EFI/CACHYOS" >/dev/null 2>&1 && ok 'Removed transaction-created GRUB EFI namespace' || true
    fi
    if sudo -n test -d /boot/grub 2>/dev/null || [[ -d /boot/grub ]]; then
        sudo rm -rf -- /boot/grub >/dev/null 2>&1 && ok 'Removed transaction-created /boot/grub tree' || true
    fi
    for artifact in "${GRUB_CREATED_ARTIFACTS[@]}"; do
        if sudo -n test -e "$artifact" 2>/dev/null || [[ -e $artifact ]]; then
            sudo rm -f -- "$artifact" >/dev/null 2>&1 && ok "Removed transaction-created GRUB boot artifact: $artifact" || true
        fi
    done
    # Preflight proved this file did not exist before the transaction. The grub
    # package itself may have created it before our policy generator ran.
    if [[ -e /etc/default/grub ]]; then
        sudo rm -f -- /etc/default/grub >/dev/null 2>&1 && ok 'Removed transaction-created /etc/default/grub' || true
    fi
    restore_source_fallback_after_grub_install >/dev/null 2>&1 || true

    if [[ -n $original_order ]]; then sudo efibootmgr -o "$original_order" >/dev/null 2>&1 || true; fi
    current_order=$(efibootmgr 2>/dev/null | awk -F': ' '/^BootOrder:/ {print $2; exit}')
    if [[ -n $old_id && ${current_order%%,*} == "$old_id" ]]; then ok "Persistent BootOrder is back to source Limine Boot$old_id first"; else info "Current BootOrder after recovery: ${current_order:-unavailable}"; fi
    [[ -n $TRANSACTION_SNAPSHOT_DIR ]] && rm -rf -- "$TRANSACTION_SNAPSHOT_DIR" 2>/dev/null || true
}

execute_limine_to_grub() {
    local old_id=$BOOT_CURRENT original_order=$BOOT_ORDER target_id="" install_rc=0 mkconfig_rc=0

    snapshot_limine_source_ownership || return 1
    if ! install_target_packages grub; then
        cleanup_uncommitted_grub_candidate "$original_order" "$old_id"
        return 1
    fi
    have grub-install || { fail 'grub-install is unavailable after package installation'; cleanup_uncommitted_grub_candidate "$original_order" "$old_id"; return 1; }
    have grub-mkconfig || { fail 'grub-mkconfig is unavailable after package installation'; cleanup_uncommitted_grub_candidate "$original_order" "$old_id"; return 1; }
    have grub-probe || { fail 'grub-probe is unavailable after package installation'; cleanup_uncommitted_grub_candidate "$original_order" "$old_id"; return 1; }
    have grub-script-check || { fail 'grub-script-check is unavailable after package installation'; cleanup_uncommitted_grub_candidate "$original_order" "$old_id"; return 1; }

    materialize_grub_boot_artifacts_from_limine || {
        capture_grub_diagnostics grub-artifact-stage-failed >/dev/null 2>&1 || true
        cleanup_uncommitted_grub_candidate "$original_order" "$old_id"
        return 1
    }
    write_grub_candidate_policy || { cleanup_uncommitted_grub_candidate "$original_order" "$old_id"; return 1; }
    sudo mkdir -p /boot/grub || { cleanup_uncommitted_grub_candidate "$original_order" "$old_id"; return 1; }

    sudo grub-install --target=x86_64-efi --efi-directory="$ESP_MOUNT" --bootloader-id=cachyos --force || install_rc=$?

    # grub-install may reorder NVRAM and may touch the shared fallback. Restore
    # the proven Limine recovery path immediately, before generating grub.cfg.
    if find_nvram_entry_for_target grub; then
        target_id=$TARGET_NVRAM_ID
        if ! set_source_first_boot_order "$old_id" "$target_id" "$original_order"; then
            fail 'Could not restore Limine as the persistent first BootOrder entry after GRUB installation.'
            capture_grub_diagnostics source-order-recovery-failed >/dev/null 2>&1 || true
            cleanup_uncommitted_grub_candidate "$original_order" "$old_id"
            fail 'Do NOT reboot unless BootOrder is inspected; best-effort rollback was attempted.'
            return 1
        fi
    else
        [[ -n $original_order ]] && sudo efibootmgr -o "$original_order" >/dev/null 2>&1 || true
    fi
    restore_source_fallback_after_grub_install || {
        fail 'Could not restore the original Limine UEFI fallback after grub-install.'
        capture_grub_diagnostics source-fallback-recovery-failed >/dev/null 2>&1 || true
        cleanup_uncommitted_grub_candidate "$original_order" "$old_id"
        return 1
    }

    if ((install_rc != 0)); then
        fail "grub-install exited with status $install_rc after potentially touching EFI/NVRAM state."
        capture_grub_diagnostics grub-install-failed >/dev/null 2>&1 || true
        cleanup_uncommitted_grub_candidate "$original_order" "$old_id"
        return 1
    fi
    [[ -n $target_id ]] || { fail 'GRUB NVRAM entry could not be found at the exact expected EFI path'; cleanup_uncommitted_grub_candidate "$original_order" "$old_id"; return 1; }

    sudo grub-mkconfig -o /boot/grub/grub.cfg || mkconfig_rc=$?
    if ((mkconfig_rc != 0)); then
        fail "grub-mkconfig exited with status $mkconfig_rc."
        capture_grub_diagnostics grub-mkconfig-failed >/dev/null 2>&1 || true
        cleanup_uncommitted_grub_candidate "$original_order" "$old_id"
        return 1
    fi

    printf '\nSource recovery invariants after target generation:\n'
    if ! verify_source_limine_recovery_state "$old_id"; then
        capture_grub_diagnostics source-invariant-failed >/dev/null 2>&1 || true
        cleanup_uncommitted_grub_candidate "$original_order" "$old_id"
        fail 'Source Limine recovery invariants failed. Candidate was NOT committed and BootNext was NOT set.'
        return 1
    fi

    if ! validate_target_state grub; then
        capture_grub_diagnostics candidate-structural-failed >/dev/null 2>&1 || true
        cleanup_uncommitted_grub_candidate "$original_order" "$old_id"
        printf '\nGRUB candidate structural validation failed. Limine remains the source; BootNext was NOT set.\n'
        return 1
    fi
    if ! validate_grub_boot_chain migration; then
        capture_grub_diagnostics candidate-deep-failed >/dev/null 2>&1 || true
        cleanup_uncommitted_grub_candidate "$original_order" "$old_id"
        printf '\nGRUB candidate deep validation failed. Limine remains the source; BootNext was NOT set.\n'
        return 1
    fi
    if ! validate_cachyos_grub_theme; then
        capture_grub_diagnostics candidate-theme-failed >/dev/null 2>&1 || true
        cleanup_uncommitted_grub_candidate "$original_order" "$old_id"
        printf '\nGRUB candidate does not match the CachyOS Calamares theme reference. Limine remains the source.\n'
        return 1
    fi

    find_nvram_entry_for_target grub || { cleanup_uncommitted_grub_candidate "$original_order" "$old_id"; return 1; }
    [[ $TARGET_NVRAM_ID == "$target_id" ]] || { fail "GRUB NVRAM identity changed during validation (expected Boot$target_id, found Boot$TARGET_NVRAM_ID)"; cleanup_uncommitted_grub_candidate "$original_order" "$old_id"; return 1; }
    verify_source_limine_recovery_state "$old_id" || { cleanup_uncommitted_grub_candidate "$original_order" "$old_id"; return 1; }
    snapshot_grub_candidate_metadata || { cleanup_uncommitted_grub_candidate "$original_order" "$old_id"; return 1; }

    capture_grub_diagnostics candidate-pass >/dev/null 2>&1 || true
    [[ -n ${GRUB_DIAGNOSTIC_DIR:-} ]] && printf 'Diagnostic snapshot: %s\n' "$GRUB_DIAGNOSTIC_DIR"

    if ! write_pending_limine_to_grub "$old_id" "$original_order" "$target_id" candidate-ready; then
        fail 'Could not persist Limine -> GRUB candidate-ready migration metadata.'
        cleanup_uncommitted_grub_candidate "$original_order" "$old_id"
        return 1
    fi

    printf '\nCANDIDATE-READY Limine -> GRUB migration staged successfully.\n'
    printf 'Limine remains intact and remains first in normal persistent BootOrder.\n'
    printf 'GRUB passed the structural + deep boot-chain + CachyOS theme gate.\n'
    if declare -F r22_after_fresh_limine_to_grub_candidate >/dev/null 2>&1; then
        printf 'The switcher will now arm the one-time target boot and install its temporary post-reboot resume service.\n'
        r22_after_fresh_limine_to_grub_candidate || return 1
    else
        printf 'BootNext is intentionally NOT set in this staging session.\n'
        printf 'Candidate is parked. Use [2] Manage pending/staged migration to revalidate, arm one-time BootNext, or roll back.\n'
    fi
    return 0
}

execute_grub_repair() {
    local old_id=$BOOT_CURRENT
    install_target_packages grub || return 1
    sudo mkinitcpio -P || return 1
    sudo mkdir -p /boot/grub || return 1
    sudo grub-install --target=x86_64-efi --efi-directory="$ESP_MOUNT" --bootloader-id=cachyos --force || return 1
    sudo grub-mkconfig -o /boot/grub/grub.cfg || return 1

    # GRUB repair should retain/create a GRUB NVRAM entry and EFI executable.
    validate_target_state grub || return 1
    if [[ -n $old_id && -n $TARGET_NVRAM_ID && $TARGET_NVRAM_ID != "$old_id" ]]; then
        info "GRUB created Boot$TARGET_NVRAM_ID instead of the current Boot$old_id; both are left intact in controlled repair mode rather than deleting an entry without a switch transaction."
    fi
    return 0
}

execute_grub_to_limine() {
    local old_id=$BOOT_CURRENT original_order=$BOOT_ORDER target_id="" install_rc=0

    snapshot_grub_fallback_ownership || return 1
    snapshot_source_boot_artifacts || { [[ -n $TRANSACTION_SNAPSHOT_DIR ]] && rm -rf -- "$TRANSACTION_SNAPSHOT_DIR" 2>/dev/null || true; return 1; }

    if ! install_target_packages limine; then
        [[ -n $TRANSACTION_SNAPSHOT_DIR ]] && rm -rf -- "$TRANSACTION_SNAPSHOT_DIR" 2>/dev/null || true
        return 1
    fi
    have limine-install || { fail 'limine-install is unavailable after package installation'; cleanup_uncommitted_limine_candidate "$original_order" "$old_id"; return 1; }
    have limine-entry-tool || { fail 'limine-entry-tool is unavailable after package installation'; cleanup_uncommitted_limine_candidate "$original_order" "$old_id"; return 1; }

    write_limine_candidate_policy || { cleanup_uncommitted_limine_candidate "$original_order" "$old_id"; return 1; }
    stage_limine_kernel_entries_from_existing_artifacts || {
        capture_limine_diagnostics candidate-entry-stage-failed >/dev/null 2>&1 || true
        cleanup_uncommitted_limine_candidate "$original_order" "$old_id"
        return 1
    }

    # limine-install can touch EFI/NVRAM before returning an error. Treat its
    # exit status as one input, not as proof that nothing changed.
    sudo limine-install || install_rc=$?
    if ((install_rc == 0)); then
        # A pre-existing GRUB EFI/BOOT fallback would otherwise be preserved by
        # Limine's default policy. Force the candidate to own the standard
        # fallback as a clean CachyOS Limine install does.
        sudo limine-install --fallback || install_rc=$?
    fi

    if find_nvram_entry_for_target limine; then
        target_id=$TARGET_NVRAM_ID
        if ! set_source_first_boot_order "$old_id" "$target_id" "$original_order"; then
            fail 'Could not restore GRUB as the persistent first BootOrder entry after Limine installation.'
            capture_limine_diagnostics source-order-recovery-failed >/dev/null 2>&1 || true
            cleanup_uncommitted_limine_candidate "$original_order" "$old_id"
            fail 'Do NOT reboot unless BootOrder is inspected; best-effort candidate rollback was attempted.'
            return 1
        fi
    else
        # If no target entry exists, restore the exact pre-stage BootOrder.
        [[ -n $original_order ]] && sudo efibootmgr -o "$original_order" >/dev/null 2>&1 || true
    fi

    if ((install_rc != 0)); then
        fail "limine-install exited with status $install_rc after potentially touching EFI/NVRAM state."
        capture_limine_diagnostics limine-install-failed >/dev/null 2>&1 || true
        cleanup_uncommitted_limine_candidate "$original_order" "$old_id"
        fail 'The uncommitted Limine candidate was rolled back as far as ownership checks allowed. GRUB cleanup was NOT performed.'
        return 1
    fi

    [[ -n $target_id ]] || {
        fail 'Limine NVRAM entry could not be found at the exact expected EFI path after limine-install.'
        capture_limine_diagnostics target-nvram-missing >/dev/null 2>&1 || true
        cleanup_uncommitted_limine_candidate "$original_order" "$old_id"
        return 1
    }

    printf '\nSource recovery invariants after target generation:\n'
    if ! verify_source_grub_recovery_state "$old_id" || ! verify_source_boot_artifacts_unchanged; then
        capture_limine_diagnostics source-invariant-failed >/dev/null 2>&1 || true
        cleanup_uncommitted_limine_candidate "$original_order" "$old_id"
        fail 'Source recovery invariants failed. Candidate was NOT committed and BootNext was NOT set.'
        return 1
    fi

    # Candidate gate: target state must satisfy the same deep invariants that
    # repeatedly pass on the clean Calamares -> Limine control installation.
    if ! validate_target_state limine; then
        capture_limine_diagnostics candidate-structural-failed >/dev/null 2>&1 || true
        [[ -n ${LIMINE_DIAGNOSTIC_DIR:-} ]] && printf 'Diagnostic snapshot: %s\n' "$LIMINE_DIAGNOSTIC_DIR"
        cleanup_uncommitted_limine_candidate "$original_order" "$old_id"
        printf '\nLimine candidate validation failed. The candidate was not committed and BootNext was NOT set.\n'
        return 1
    fi

    if ! validate_limine_boot_chain migration; then
        capture_limine_diagnostics candidate-deep-failed >/dev/null 2>&1 || true
        [[ -n ${LIMINE_DIAGNOSTIC_DIR:-} ]] && printf 'Diagnostic snapshot: %s\n' "$LIMINE_DIAGNOSTIC_DIR"
        cleanup_uncommitted_limine_candidate "$original_order" "$old_id"
        printf '\nDeep Limine candidate validation failed. The generated target did not satisfy the golden boot-chain invariants.\n'
        printf 'GRUB remains the source; no one-time target boot was scheduled.\n'
        return 1
    fi

    find_nvram_entry_for_target limine || {
        fail 'Limine NVRAM entry disappeared after candidate validation'
        cleanup_uncommitted_limine_candidate "$original_order" "$old_id"
        return 1
    }
    [[ $TARGET_NVRAM_ID == "$target_id" ]] || {
        fail "Limine NVRAM entry changed during validation (expected Boot$target_id, found Boot$TARGET_NVRAM_ID)"
        cleanup_uncommitted_limine_candidate "$original_order" "$old_id"
        return 1
    }
    verify_source_grub_recovery_state "$old_id" || {
        cleanup_uncommitted_limine_candidate "$original_order" "$old_id"
        return 1
    }
    snapshot_limine_candidate_metadata || {
        cleanup_uncommitted_limine_candidate "$original_order" "$old_id"
        return 1
    }

    capture_limine_diagnostics candidate-pass >/dev/null 2>&1 || true
    [[ -n ${LIMINE_DIAGNOSTIC_DIR:-} ]] && printf 'Diagnostic snapshot: %s\n' "$LIMINE_DIAGNOSTIC_DIR"

    # Persist the candidate as PARKED state. BootNext is deliberately armed only
    # later from Manage pending/staged migration after another full integrity gate.
    if ! write_pending_grub_to_limine "$old_id" "$original_order" "$target_id" candidate-ready; then
        fail 'Could not persist candidate-ready migration metadata.'
        cleanup_uncommitted_limine_candidate "$original_order" "$old_id"
        return 1
    fi

    printf '\nCANDIDATE-READY migration staged successfully.\n'
    printf 'GRUB remains intact and remains first in normal persistent BootOrder.\n'
    printf 'Limine passed the on-disk structural + deep boot-chain gate.\n'
    printf 'BootNext is intentionally NOT set in this staging session.\n'
    printf 'Candidate is parked. Use [2] Manage pending/staged migration to revalidate, arm one-time BootNext, or roll back.\n'
    if declare -F r23_after_fresh_grub_to_limine_candidate >/dev/null 2>&1; then
        printf 'The switcher will now arm the themed one-time Limine test and prepare automatic resume.\n'
    else
        printf 'Runtime proof is required before ownership-gated finalization.\n'
    fi
    return 0
}

run_live_operation() {
    local target=$1 current=$BOOTLOADER
    if ! operation_supported "$current" "$target"; then
        printf '\nThe %s -> %s live backend is not enabled in this release.\n' "$(bootloader_display_name "$current")" "$(bootloader_display_name "$target")"
        printf 'This release enables GRUB repair plus fully validated automated GRUB <-> Limine migration. Other directions remain disabled.\n'
        return 2
    fi

    run_switch_preflight "$target" || return 1
    offer_operation_backup || return 1
    show_operation_plan "$current" "$target"
    if ! confirm_operation "$current" "$target"; then
        printf '\nOperation cancelled. No boot state was modified.\n'
        return 0
    fi

    printf '\nExecuting staged/repair operation...\n'
    case "$current:$target" in
        grub:grub) execute_grub_repair ;;
        grub:limine) execute_grub_to_limine ;;
        limine:grub) execute_limine_to_grub ;;
        *) return 2 ;;
    esac
}
