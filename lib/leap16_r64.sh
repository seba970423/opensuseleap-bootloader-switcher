#!/usr/bin/env bash
# leap16-r64: complete the openSUSE Leap 16 four-bootloader matrix by adding
# rEFInd as a first-class live + backup/restore adapter.
#
# Safety contract:
#   * rEFInd is always staged as one canonical \EFI\refind\refind_x64.efi
#     Boot#### while the source remains persistent-first.
#   * rEFInd direct-kernel runtime proof retains r33 PreviousBoot validation.
#   * rEFInd never claims EFI/BOOT as its own fallback.  A source-owned generic
#     fallback is retired only after rEFInd runtime proof; unrelated fallback
#     state is preserved byte-for-byte.
#   * source retirement is Leap-aware: every exact source alias is removed from
#     BootOrder while its EFI bytes still exist, then those exact aliases are
#     deleted, then only the frozen ownership manifest is retired.
#   * rEFInd -> Limine uses two independent hardware proofs: canonical Limine,
#     then byte-identical Limine EFI/BOOT fallback, before rEFInd retirement.
#   * rEFInd backup restore excludes mutable EFI/refind/vars from immutable
#     restoration and requires fresh PreviousBoot proof on the new boot.

LEAP16_R64_REFIND_BACKUP_SCHEMA='leap16-r64-refind-v1'
LEAP16_R64_REFIND_PAYLOAD_POLICY='opensuse-refind-owned-paths'
LEAP16_R64_REFIND_MARKER='# Managed by openSUSE Bootloader Switcher leap16-r64'
LEAP16_R64_REFIND_EFI='\EFI\refind\refind_x64.efi'
LEAP16_R64_REFIND_LABEL='openSUSE rEFInd'
LEAP16_R64_FIRMWARE_BASELINE='r64-firmware-baseline.txt'
LEAP16_R64_META='r64-edge.tsv'
LEAP16_R64_RESTORE_DIR=''
LEAP16_R64_ACTIVE_TARGET=''
LEAP16_R64_STAGING=0

# ---------------------------------------------------------------------------
# Small helpers / direction predicates
# ---------------------------------------------------------------------------

leap16_r64_refind_edge() {
    case "$1:$2" in
        grub:refind|limine:refind|systemd-boot:refind|\
        refind:grub|refind:limine|refind:systemd-boot) return 0 ;;
        *) return 1 ;;
    esac
}

leap16_r64_pending_edge() {
    [[ ${PENDING_FORMAT:-} == ${R26_PENDING_FORMAT:-5} ]] || return 1
    leap16_r64_refind_edge "${PENDING_SOURCE:-}" "${PENDING_TARGET:-}"
}

leap16_r64_pending_refind_limine() {
    [[ ${PENDING_FORMAT:-} == ${R26_PENDING_FORMAT:-5} \
       && ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == refind:limine ]]
}

leap16_r64_snapshot_dir() {
    local d=${PENDING_TRANSACTION_SNAPSHOT_DIR:-${TRANSACTION_SNAPSHOT_DIR:-}}
    [[ -n $d ]] || return 1
    printf '%s\n' "$d"
}

leap16_r64_meta_path() {
    local d
    d=$(leap16_r64_snapshot_dir) || return 1
    printf '%s/%s\n' "$d" "$LEAP16_R64_META"
}

leap16_r64_meta_value() {
    local key=$1 p
    p=$(leap16_r64_meta_path) || return 1
    awk -F'\t' -v k="$key" '$1==k{print $2;exit}' "$p" 2>/dev/null
}

leap16_r64_write_meta() {
    local direction=$1 direct=${2:-} primary_hash=${3:-} fallback=${4:-} fallback_hash=${5:-} transferred_hash=${6:-}
    local p tmp
    p=$(leap16_r64_meta_path) || return 1
    tmp="$p.tmp.$$"
    {
        printf 'format\t1\n'
        printf 'direction\t%s\n' "$direction"
        printf 'grub_direct_id\t%s\n' "${direct^^}"
        printf 'limine_primary_conf_hash\t%s\n' "$primary_hash"
        printf 'limine_fallback_id\t%s\n' "${fallback^^}"
        printf 'limine_fallback_hash\t%s\n' "$fallback_hash"
        printf 'limine_transferred_conf_hash\t%s\n' "$transferred_hash"
        printf 'created\t%s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
    } >"$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 600 -- "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$p"
}

leap16_r64_update_limine_fallback_meta() {
    local fallback=${1^^} fh=$2 ch=$3 p tmp direction direct primary
    p=$(leap16_r64_meta_path) || return 1
    direction=$(leap16_r64_meta_value direction)
    direct=$(leap16_r64_meta_value grub_direct_id)
    primary=$(leap16_r64_meta_value limine_primary_conf_hash)
    [[ $direction == refind:limine && $fallback =~ ^[0-9A-F]{4}$ ]] || return 1
    [[ $primary =~ ^[0-9A-Fa-f]{64}$ && $fh =~ ^[0-9A-Fa-f]{64}$ && $ch =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
    leap16_r64_write_meta "$direction" "$direct" "$primary" "$fallback" "$fh" "$ch"
}

leap16_r64_grub_direct_id() {
    local id
    id=$(leap16_r64_meta_value grub_direct_id 2>/dev/null || true); id=${id^^}
    [[ $id =~ ^[0-9A-F]{4}$ ]] || return 1
    printf '%s\n' "$id"
}

leap16_r64_limine_fallback_id() {
    local id
    id=$(leap16_r64_meta_value limine_fallback_id 2>/dev/null || true); id=${id^^}
    [[ $id =~ ^[0-9A-F]{4}$ ]] || return 1
    printf '%s\n' "$id"
}

leap16_r64_limine_fallback_staged() {
    leap16_r64_limine_fallback_id >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Leap-native rEFInd deep validation
# ---------------------------------------------------------------------------

leap16_r64_refind_read() {
    local p=$1
    if [[ -r $p ]]; then cat -- "$p"; else sudo -n cat -- "$p" 2>/dev/null; fi
}

leap16_r64_refind_config_value() {
    local conf=$1 key=$2
    leap16_r64_refind_read "$conf" | awk -v k="$key" '
        /^[[:space:]]*#/ {next}
        $1==k {$1=""; sub(/^[[:space:]]+/,""); print; exit}
    '
}

leap16_r64_refind_driver_path() {
    printf '%s/EFI/refind/drivers_x64/ext4_x64.efi\n' "${ESP_MOUNT%/}"
}

leap16_r64_refind_source_gate() {
    local ids order path
    validate_refind_boot_chain current || return 1
    ids=$(leap16_r48_ids_for_current_esp_path "$LEAP16_R64_REFIND_EFI" | paste -sd, -)
    [[ -n $ids && $ids != *,* && ${ids^^} == ${BOOT_CURRENT^^} ]] \
        || { fail "Expected exactly one canonical rEFInd alias matching BootCurrent; found ${ids:-none}"; return 1; }
    path=$(normalize_efi_path "${BOOT_EFI_PATH:-}" | tr '[:upper:]' '[:lower:]')
    [[ $path == efi/refind/refind_x64.efi ]] || { fail 'BootCurrent is not canonical rEFInd'; return 1; }
    order=$(leap16_current_boot_order)
    [[ ${order%%,*} == ${BOOT_CURRENT^^} ]] || { fail "Persistent BootOrder is not canonical rEFInd Boot${BOOT_CURRENT^^} first ($order)"; return 1; }
    ok "Finalized rEFInd source is canonical and persistent-first: Boot${BOOT_CURRENT^^}"
}

# Replace the CachyOS-specific validator only on Leap.  The public function
# name is retained so all inherited adapter contracts continue to compose.
if declare -F validate_refind_boot_chain >/dev/null 2>&1; then
    eval "$(declare -f validate_refind_boot_chain | sed '1s/validate_refind_boot_chain/validate_refind_boot_chain_pre_leap16_r64/')"
fi
validate_refind_boot_chain() {
    local mode=${1:-current} esp=${ESP_MOUNT:-/boot/efi} root conf linuxconf driver options expected id ids order
    local failures=0 ver kernel initrd
    if ! is_leap16; then
        validate_refind_boot_chain_pre_leap16_r64 "$@"
        return $?
    fi
    esp=${esp%/}; root="$esp/EFI/refind"; conf="$root/refind.conf"; linuxconf=/boot/refind_linux.conf
    driver=$(leap16_r64_refind_driver_path)
    printf '\nDeep openSUSE rEFInd boot-chain validation (%s):\n' "$mode"

    if sudo -n test -f "$root/refind_x64.efi" 2>/dev/null || [[ -f $root/refind_x64.efi ]]; then
        [[ $(leap16_r32_sdboot_read "$root/refind_x64.efi" 2>/dev/null | od -An -tx1 -N2 | tr -d '[:space:]') == 4d5a ]] \
            && { ok 'Canonical rEFInd EFI executable has an MZ header'; } \
            || { fail 'Canonical rEFInd EFI executable is malformed'; ((failures+=1)); }
        if have file && ! leap16_is_x86_64_efi_application "$root/refind_x64.efi"; then fail 'Canonical rEFInd EFI is not an x86-64 EFI application'; ((failures+=1)); fi
    else
        fail "Canonical rEFInd EFI is missing: $root/refind_x64.efi"; ((failures+=1))
    fi

    (sudo -n test -f "$conf" 2>/dev/null || [[ -f $conf ]]) || { fail 'rEFInd refind.conf is missing'; ((failures+=1)); }
    (sudo -n test -f "$linuxconf" 2>/dev/null || [[ -f $linuxconf ]]) || { fail '/boot/refind_linux.conf is missing'; ((failures+=1)); }
    if [[ ${ROOT_FSTYPE:-$(findmnt -rn -M / -o FSTYPE 2>/dev/null)} == ext4 ]]; then
        if sudo -n test -f "$driver" 2>/dev/null || [[ -f $driver ]]; then
            ok 'rEFInd ext4 filesystem driver exists for direct access to the Leap /boot kernel tree'
        else
            fail "rEFInd ext4 driver is missing: $driver"; ((failures+=1))
        fi
    fi

    if ((failures == 0)) || (sudo -n test -f "$conf" 2>/dev/null || [[ -f $conf ]]); then
        expected=$(leap16_r64_refind_config_value "$conf" scan_all_linux_kernels 2>/dev/null || true)
        [[ ${expected,,} == true ]] && ok 'scan_all_linux_kernels=true' || { fail 'rEFInd does not enable scan_all_linux_kernels=true'; ((failures+=1)); }
        expected=$(leap16_r64_refind_config_value "$conf" use_nvram 2>/dev/null || true)
        [[ ${expected,,} == false ]] && ok 'use_nvram=false keeps rEFInd PreviousBoot state disk-backed when possible' || { fail 'rEFInd use_nvram is not false'; ((failures+=1)); }
        expected=$(leap16_r64_refind_config_value "$conf" scanfor 2>/dev/null || true)
        [[ ${expected// /} == *internal* ]] && ok 'rEFInd scans internal direct-boot targets' || { fail 'rEFInd scanfor does not include internal'; ((failures+=1)); }
        expected=$(leap16_r64_refind_config_value "$conf" dont_scan_dirs 2>/dev/null || true)
        local low=${expected,,}
        for id in efi/boot efi/opensuse efi/limine efi/systemd efi/opensuse-bootloader-switcher; do
            [[ $low == *"$id"* ]] || { fail "rEFInd dont_scan_dirs is missing $id"; ((failures+=1)); }
        done
        ((failures == 0)) && ok 'rEFInd scanner excludes source/fallback/reference EFI namespaces that must never masquerade as direct kernel boots'
    fi

    if sudo -n test -f "$linuxconf" 2>/dev/null || [[ -f $linuxconf ]]; then
        options=$(refind_standard_options "$linuxconf" 2>/dev/null || true)
        [[ -n $options ]] || { fail 'rEFInd standard kernel options are missing'; ((failures+=1)); }
        if [[ -n $options ]]; then
            local reference=${PENDING_SOURCE_CMDLINE:-$(cat /proc/cmdline 2>/dev/null || true)}
            pending_cmdline_equivalent "$options" "$reference" \
                && ok 'rEFInd standard kernel options are token-equivalent to the proven source/running cmdline' \
                || { fail 'rEFInd standard options are not token-equivalent to the proven source/running cmdline'; ((failures+=1)); }
        fi
        grep -Eq '^"Boot to single-user mode"[[:space:]]+".+[[:space:]]single"$' "$linuxconf" 2>/dev/null \
            && ok 'rEFInd single-user options line is present' \
            || { fail 'rEFInd single-user options line is missing'; ((failures+=1)); }
    fi

    collect_kernels
    ((${#KERNEL_VERSIONS[@]} > 0)) || { fail 'No complete Leap kernel/initrd pairs were found'; ((failures+=1)); }
    for ver in "${KERNEL_VERSIONS[@]}"; do
        kernel="/boot/vmlinuz-$ver"; initrd="/boot/initrd-$ver"
        [[ -f $kernel ]] && ok "$ver kernel exists at /boot/vmlinuz-$ver" || { fail "$ver kernel is missing"; ((failures+=1)); }
        [[ -f $initrd ]] && ok "$ver initrd exists at /boot/initrd-$ver" || { fail "$ver initrd is missing"; ((failures+=1)); }
        if [[ -f $initrd ]] && declare -F grub_initramfs_matches_kernel_version >/dev/null 2>&1; then
            grub_initramfs_matches_kernel_version "$initrd" "$ver" \
                && ok "$ver initrd structurally matches the kernel release" \
                || { fail "$ver initrd does not structurally match the kernel release"; ((failures+=1)); }
        fi
    done

    ids=$(leap16_r48_ids_for_current_esp_path "$LEAP16_R64_REFIND_EFI" | paste -sd, -)
    case "$mode" in
        current|source|final|runtime)
            if [[ ${BOOTLOADER:-} == refind ]]; then
                [[ -n $ids && $ids != *,* ]] && ok "Exactly one canonical rEFInd same-ESP NVRAM alias exists: Boot${ids^^}" \
                    || { fail "Canonical rEFInd NVRAM alias set is ambiguous (${ids:-none})"; ((failures+=1)); }
            fi
            ;;
    esac
    if [[ ${BOOTLOADER:-} == refind ]]; then
        order=$(leap16_current_boot_order 2>/dev/null || true)
        [[ -n $order ]] || { fail 'BootOrder is unavailable while validating active rEFInd'; ((failures+=1)); }
    fi
    printf '  rEFInd deep summary: %d failure(s)\n' "$failures"
    ((failures == 0))
}

# Ensure generic adapter calls use the Leap validator above, not the old
# CachyOS theme/shape assumptions.
if declare -F r26_adapter_validate >/dev/null 2>&1; then
    eval "$(declare -f r26_adapter_validate | sed '1s/r26_adapter_validate/r26_adapter_validate_pre_leap16_r64/')"
fi
r26_adapter_validate() {
    local bl=$1 mode=${2:-migration}
    if [[ $bl == refind && $(is_leap16; echo $?) == 0 ]]; then
        validate_refind_boot_chain "$mode"
        return $?
    fi
    # During an r64 rEFInd -> GRUB candidate, use the native Leap candidate
    # validator because GRUB is not BootCurrent yet.
    if [[ $bl == grub && ( ${LEAP16_R64_STAGING:-0} == 1 || ( ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == refind:grub && ${BOOTLOADER:-} != grub ) ) ]]; then
        leap16_r64_validate_grub_candidate
        return $?
    fi
    r26_adapter_validate_pre_leap16_r64 "$@"
}

# ---------------------------------------------------------------------------
# rEFInd staging and scanner policy
# ---------------------------------------------------------------------------

leap16_r64_refind_namespace_clean() {
    local p ids
    ids=$(leap16_r48_ids_for_current_esp_path "$LEAP16_R64_REFIND_EFI" | paste -sd, -)
    [[ -z $ids ]] || { fail "Pre-existing canonical rEFInd NVRAM alias(es) block staging: Boot${ids//,/ Boot}"; return 1; }
    for p in "${ESP_MOUNT%/}/EFI/refind" /boot/refind_linux.conf; do
        if sudo -n test -e "$p" 2>/dev/null || sudo -n test -L "$p" 2>/dev/null || [[ -e $p || -L $p ]]; then
            fail "rEFInd target namespace already exists: $p"
            return 1
        fi
    done
    return 0
}

leap16_r64_patch_refind_config() {
    local conf="${ESP_MOUNT%/}/EFI/refind/refind.conf" tmp out
    (sudo -n test -f "$conf" 2>/dev/null || [[ -f $conf ]]) || { fail 'refind-install did not create refind.conf'; return 1; }
    tmp=$(mktemp) || return 1; out=$(mktemp) || { rm -f -- "$tmp"; return 1; }
    leap16_r64_refind_read "$conf" >"$tmp" || { rm -f -- "$tmp" "$out"; return 1; }
    awk '
        BEGIN{IGNORECASE=1}
        /^[[:space:]]*#?[[:space:]]*(timeout|use_nvram|scanfor|scan_all_linux_kernels|dont_scan_dirs|extra_kernel_version_strings)[[:space:]]+/ {next}
        {print}
    ' "$tmp" >"$out" || { rm -f -- "$tmp" "$out"; return 1; }
    {
        printf '\n%s\n' "$LEAP16_R64_REFIND_MARKER"
        printf 'timeout 5\n'
        printf 'use_nvram false\n'
        printf 'scanfor internal,manual\n'
        printf 'scan_all_linux_kernels true\n'
        printf 'dont_scan_dirs EFI/BOOT,EFI/OPENSUSE,EFI/LIMINE,EFI/systemd,EFI/opensuse-bootloader-switcher\n'
    } >>"$out"
    sudo install -o root -g root -m 0644 -- "$out" "$conf" || { rm -f -- "$tmp" "$out"; return 1; }
    rm -f -- "$tmp" "$out"
    ok 'Applied Leap-native rEFInd direct-kernel scanner policy and excluded source/reference EFI namespaces'
}

leap16_r64_ensure_refind_ext4_driver() {
    local dst src
    [[ ${ROOT_FSTYPE:-$(findmnt -rn -M / -o FSTYPE 2>/dev/null)} == ext4 ]] || return 0
    dst=$(leap16_r64_refind_driver_path)
    if sudo -n test -f "$dst" 2>/dev/null || [[ -f $dst ]]; then
        ok 'rEFInd ext4 driver is already installed on the ESP'
        return 0
    fi
    src=$(rpm -ql refind 2>/dev/null | awk '/\/ext4_x64\.efi$/{print;exit}')
    [[ -n $src && -f $src ]] || { fail 'The installed openSUSE rEFInd package exposes no ext4_x64.efi driver required for this Leap /boot layout'; return 1; }
    rpm -qf "$src" 2>/dev/null | grep -q '^refind-' || { fail 'Candidate ext4_x64.efi is not owned by the installed refind RPM'; return 1; }
    sudo install -d -m 0755 -- "$(dirname -- "$dst")" || return 1
    sudo install -m 0644 -- "$src" "$dst" || return 1
    ok 'Installed the RPM-owned rEFInd ext4 filesystem driver for direct /boot kernel access'
}

leap16_r64_install_refind_package() {
    if rpm -q refind >/dev/null 2>&1 && have refind-install; then
        ok 'openSUSE rEFInd package/tool set is already installed'
        return 0
    fi
    have zypper || { fail 'zypper is required to install rEFInd on openSUSE Leap'; return 1; }
    printf 'Installing native openSUSE rEFInd package without weak dependencies...\n'
    sudo zypper --non-interactive --no-recommends install refind || return 1
    rpm -q refind >/dev/null 2>&1 || { fail 'rEFInd RPM is not installed after zypper returned'; return 1; }
    have refind-install || { fail 'refind-install is unavailable after package installation'; return 1; }
    ok 'Native openSUSE rEFInd package/tool set is ready'
}

leap16_r64_refind_ids() {
    leap16_r48_ids_for_current_esp_path "$LEAP16_R64_REFIND_EFI"
}

leap16_r64_normalize_refind_aliases() {
    local source=${1^^} original_order=$2 id keep='' order
    local -a ids=()
    mapfile -t ids < <(leap16_r64_refind_ids | LC_ALL=C sort -u)
    ((${#ids[@]} > 0)) || { fail 'refind-install did not create a canonical same-ESP rEFInd NVRAM alias'; return 1; }
    keep=${ids[0]^^}
    set_source_first_boot_order "$source" "$keep" "$original_order" || return 1
    for id in "${ids[@]}"; do
        id=${id^^}; [[ $id != "$keep" ]] || continue
        leap16_nvram_entry_matches_current_esp "$id" || { fail "Refusing to normalize rEFInd Boot$id because its ESP binding is unexpected"; return 1; }
        nvram_id_matches_path "$id" "$LEAP16_R64_REFIND_EFI" || return 1
        sudo efibootmgr -b "$id" -B >/dev/null || return 1
        ok "Removed transaction-created duplicate canonical rEFInd alias Boot$id"
    done
    mapfile -t ids < <(leap16_r64_refind_ids)
    ((${#ids[@]} == 1)) || { fail 'Canonical rEFInd alias set did not normalize to exactly one entry'; return 1; }
    order=$(leap16_current_boot_order)
    [[ ${order%%,*} == "$source" ]] || { fail 'Source lost persistent-first position while normalizing rEFInd aliases'; return 1; }
    printf '%s\n' "$keep"
}

# Preserve the inherited stage for non-Leap/non-r64 contexts.
if declare -F r26_stage_refind_target >/dev/null 2>&1; then
    eval "$(declare -f r26_stage_refind_target | sed '1s/r26_stage_refind_target/r26_stage_refind_target_pre_leap16_r64/')"
fi
r26_stage_refind_target() {
    local source_id=${1^^} original_order=$2 reference=$3 target_id expected_source expected_mount expected_fstype expected_uuid
    if ! is_leap16; then r26_stage_refind_target_pre_leap16_r64 "$@"; return $?; fi
    expected_source=$ESP_SOURCE; expected_mount=$ESP_MOUNT; expected_fstype=$ESP_FSTYPE; expected_uuid=$ESP_UUID
    leap16_r64_install_refind_package || return 1
    sudo refind-install --yes || { fail 'refind-install failed'; return 1; }
    r32_verify_refind_post_install_esp "$expected_source" "$expected_mount" "$expected_fstype" "$expected_uuid" || return 1
    leap16_r64_ensure_refind_ext4_driver || return 1
    leap16_r64_patch_refind_config || return 1
    r26_write_refind_linux_conf "$reference" || return 1

    # A restore substitutes only the integrity-validated immutable rEFInd tree
    # and refind_linux.conf.  Mutable vars remain freshly created by rEFInd.
    if [[ -n ${LEAP16_R64_RESTORE_DIR:-} ]]; then
        leap16_r64_restore_refind_payload_at_write_boundary "$LEAP16_R64_RESTORE_DIR" "$reference" || return 1
    fi

    target_id=$(leap16_r64_normalize_refind_aliases "$source_id" "$original_order") || return 1
    # refind-install must not retain an installer-owned BootNext.  Preflight
    # proved it was clear; only a canonical rEFInd value can be ours here.
    local next
    next=$(pending_bootnext_id 2>/dev/null || true)
    if [[ -n $next ]]; then
        if [[ ${next^^} == ${target_id^^} ]]; then
            sudo efibootmgr -N >/dev/null || return 1
            ok 'Cleared refind-install-created transaction-owned BootNext before candidate commit'
        else
            fail "refind-install created/left unrelated BootNext=Boot${next^^}; refusing to commit candidate"
            return 1
        fi
    fi
    r26_restore_source_fallback_after_target_stage || return 1
    adapter_target_validate refind || return 1
    r26_record_target_adapter refind || return 1
    R26_STAGED_TARGET_ID=${target_id^^}
    leap16_r64_write_meta "${BOOTLOADER}:refind" || return 1
    ok "Staged canonical Leap rEFInd target as parked Boot$R26_STAGED_TARGET_ID"
}

# ---------------------------------------------------------------------------
# Source snapshots / firmware ownership baseline
# ---------------------------------------------------------------------------

if declare -F adapter_source_snapshot >/dev/null 2>&1; then
    eval "$(declare -f adapter_source_snapshot | sed '1s/adapter_source_snapshot/adapter_source_snapshot_pre_leap16_r64/')"
fi
adapter_source_snapshot() {
    local source=$1 baseline
    adapter_source_snapshot_pre_leap16_r64 "$@" || return $?
    if [[ $source != refind && ${LEAP16_R64_ACTIVE_TARGET:-} != refind ]]; then return 0; fi
    baseline="$TRANSACTION_SNAPSHOT_DIR/$LEAP16_R64_FIRMWARE_BASELINE"
    sudo -n efibootmgr -v >"$baseline" || { fail 'Could not capture complete pre-stage firmware table for r64 ownership gating'; return 1; }
    chmod 600 -- "$baseline" 2>/dev/null || true
    grep -Eq '^BootCurrent:[[:space:]]+' "$baseline" || { fail 'r64 pre-stage firmware baseline has no BootCurrent'; return 1; }
    grep -Eq '^BootOrder:[[:space:]]+' "$baseline" || { fail 'r64 pre-stage firmware baseline has no BootOrder'; return 1; }
    ok 'Recorded complete pre-stage firmware table for rEFInd-edge alias ownership'
}

leap16_r64_baseline_path() {
    local d
    d=$(leap16_r64_snapshot_dir) || return 1
    printf '%s/%s\n' "$d" "$LEAP16_R64_FIRMWARE_BASELINE"
}

leap16_r64_source_paths() {
    local source=$1
    case "$source" in
        grub) printf '%s\n' "$R28_GRUB_SHIM_PATH" "$R28_GRUB_DIRECT_PATH" ;;
        limine) printf '%s\n' '\EFI\LIMINE\LIMINE_X64.EFI' "$LEAP16_R21_FALLBACK_EFI_PATH" ;;
        systemd-boot) printf '%s\n' "$LEAP16_R32_SDBOOT_EFI" ; [[ ${PENDING_SOURCE_FALLBACK_OWNED:-0} == 1 ]] && printf '%s\n' "$LEAP16_R21_FALLBACK_EFI_PATH" ;;
        refind) printf '%s\n' "$LEAP16_R64_REFIND_EFI" ;;
    esac
}

leap16_r64_ids_from_baseline_for_source() {
    local source=$1 baseline line id path wanted norm wnorm
    baseline=$(leap16_r64_baseline_path) || return 1
    [[ -s $baseline ]] || return 1
    while IFS= read -r line; do
        [[ $line =~ ^Boot([0-9A-Fa-f]{4})\*?[[:space:]] ]] || continue
        id=${BASH_REMATCH[1]^^}
        path=$(efi_path_from_efibootmgr_line "$line" 2>/dev/null || true)
        [[ -n $path ]] || continue
        norm=$(normalize_efi_path "$path" | tr '[:upper:]' '[:lower:]')
        while IFS= read -r wanted; do
            wnorm=$(normalize_efi_path "$wanted" | tr '[:upper:]' '[:lower:]')
            [[ $norm == "$wnorm" ]] && { printf '%s\n' "$id"; break; }
        done < <(leap16_r64_source_paths "$source")
    done <"$baseline" | LC_ALL=C sort -u
}

leap16_r64_current_ids_for_source_paths() {
    local source=$1 wanted id
    while IFS= read -r wanted; do
        while IFS= read -r id; do
            id=${id^^}; [[ $id =~ ^[0-9A-F]{4}$ ]] || continue
            leap16_nvram_entry_matches_current_esp "$id" || continue
            nvram_id_matches_path "$id" "$wanted" || continue
            printf '%s\n' "$id"
        done < <(r21_nvram_ids_for_esp_path "$wanted")
    done < <(leap16_r64_source_paths "$source") | LC_ALL=C sort -u
}

leap16_r64_verify_source_alias_superset() {
    local source=$1 expected current id
    expected=$(leap16_r64_ids_from_baseline_for_source "$source" | paste -sd, -) || return 1
    current=$(leap16_r64_current_ids_for_source_paths "$source" | paste -sd, -)
    [[ -n $expected ]] || { fail "r64 baseline contains no source $(bootloader_display_name "$source") firmware alias"; return 1; }
    IFS=',' read -ra _r64_expected <<<"$expected"
    for id in "${_r64_expected[@]}"; do
        case ",$current," in *,"$id",*) ;; *) fail "Baseline-owned source Boot$id disappeared before retirement"; return 1 ;; esac
    done
    case ",$expected," in *","${PENDING_OLD_BOOT_ID^^}","*) ;; *) fail "Baseline source set does not include Boot${PENDING_OLD_BOOT_ID^^}"; return 1 ;; esac
    ok "Every pre-stage $(bootloader_display_name "$source") firmware alias remains present; same-path extras, if any, are bounded firmware churn"
}

# ---------------------------------------------------------------------------
# Outgoing rEFInd target stages: systemd-boot / native GRUB / Limine
# ---------------------------------------------------------------------------

leap16_r64_systemd_namespace_clean() { leap16_r48_systemd_namespace_clean; }
leap16_r64_grub_namespace_clean() { leap16_r38_target_namespace_clean; }

leap16_r64_limine_namespace_clean() {
    local mid parent p base
    [[ $(count_nvram_entries_for_target limine) == 0 ]] || { fail 'Pre-existing Limine NVRAM state is ambiguous'; return 1; }
    for p in "${ESP_MOUNT%/}/EFI/LIMINE" "${ESP_MOUNT%/}/limine.conf" "${ESP_MOUNT%/}/$R23_LIMINE_SPLASH_NAME" /etc/default/limine; do
        if sudo -n test -e "$p" 2>/dev/null || sudo -n test -L "$p" 2>/dev/null || [[ -e $p || -L $p ]]; then fail "Limine target namespace already exists: $p"; return 1; fi
    done
    mid=$(cat /etc/machine-id 2>/dev/null || true); [[ -n $mid ]] || { fail 'Machine ID is unavailable'; return 1; }
    parent="${ESP_MOUNT%/}/$mid"
    if sudo -n test -e "$parent" 2>/dev/null || [[ -e $parent ]]; then
        (sudo -n test -d "$parent" 2>/dev/null || [[ -d $parent ]]) || { fail 'Existing machine-id payload parent is not a directory'; return 1; }
        while IFS= read -r p; do [[ -z $p ]] || { base=${p##*/}; fail "Foreign machine-id child blocks Limine staging from rEFInd: $base"; return 1; }; done < <(sudo -n find "$parent" -mindepth 1 -maxdepth 1 -print 2>/dev/null || true)
    fi
    return 0
}

if declare -F r26_stage_systemd_boot_target >/dev/null 2>&1; then
    eval "$(declare -f r26_stage_systemd_boot_target | sed '1s/r26_stage_systemd_boot_target/r26_stage_systemd_boot_target_pre_leap16_r64/')"
fi
r26_stage_systemd_boot_target() {
    local source_id=$1 original_order=$2 reference=$3 target_id
    if [[ ${BOOTLOADER:-} != refind ]]; then r26_stage_systemd_boot_target_pre_leap16_r64 "$@"; return $?; fi
    leap16_r32_secure_boot_disabled || { fail 'systemd-boot staging requires Secure Boot disabled'; return 1; }
    leap16_r32_install_systemd_boot_package || return 1
    leap16_r32_write_systemd_boot_candidate "$reference" || return 1
    r28_create_alias_create_only "$LEAP16_R32_SDBOOT_LABEL" "$LEAP16_R32_SDBOOT_EFI" || return 1
    target_id=$R28_CREATED_ALIAS_ID
    set_source_first_boot_order "$source_id" "$target_id" "$original_order" || return 1
    r26_restore_source_fallback_after_target_stage || return 1
    adapter_target_validate systemd-boot || return 1
    r26_record_target_adapter systemd-boot || return 1
    R26_STAGED_TARGET_ID=${target_id^^}
    leap16_r64_write_meta 'refind:systemd-boot' || return 1
    ok "Staged native openSUSE systemd-boot target as parked Boot$R26_STAGED_TARGET_ID from rEFInd"
}

leap16_r64_validate_grub_direct_alias() {
    local direct
    direct=$(leap16_r64_grub_direct_id) || { fail 'Recorded direct GRUB alias is unavailable'; return 1; }
    boot_id_exists "$direct" || { fail "Recorded direct GRUB Boot$direct disappeared"; return 1; }
    nvram_id_matches_path "$direct" "$R28_GRUB_DIRECT_PATH" || { fail "Direct GRUB Boot$direct changed EFI path"; return 1; }
    leap16_nvram_entry_matches_current_esp "$direct" || { fail "Direct GRUB Boot$direct changed ESP binding"; return 1; }
    ok "Recorded direct GRUB recovery alias remains exact: Boot$direct"
}

leap16_r64_validate_grub_candidate() {
    local direct target order
    direct=${LEAP16_R64_STAGED_GRUB_DIRECT:-$(leap16_r64_grub_direct_id 2>/dev/null || true)}
    target=${LEAP16_R64_STAGED_GRUB_TARGET:-${PENDING_TARGET_BOOT_ID:-}}
    direct=${direct^^}; target=${target^^}
    [[ $direct =~ ^[0-9A-F]{4}$ && $target =~ ^[0-9A-F]{4}$ ]] || { fail 'GRUB candidate alias identities are incomplete'; return 1; }
    boot_id_exists "$target" && nvram_id_matches_path "$target" "$R28_GRUB_SHIM_PATH" && leap16_nvram_entry_matches_current_esp "$target" \
        || { fail "GRUB shim target Boot$target is not exact"; return 1; }
    boot_id_exists "$direct" && nvram_id_matches_path "$direct" "$R28_GRUB_DIRECT_PATH" && leap16_nvram_entry_matches_current_esp "$direct" \
        || { fail "Direct GRUB target Boot$direct is not exact"; return 1; }
    order=$(leap16_current_boot_order)
    leap16_order_has_id "$order" "$direct" && { fail "Parked direct GRUB Boot$direct entered BootOrder before finalization"; return 1; }
    leap16_r38_validate_grub_files_candidate || return 1
    ok "Native GRUB2 candidate is exact: shim Boot$target; direct Boot$direct parked outside BootOrder"
}

if declare -F r26_stage_grub_target >/dev/null 2>&1; then
    eval "$(declare -f r26_stage_grub_target | sed '1s/r26_stage_grub_target/r26_stage_grub_target_pre_leap16_r64/')"
fi
r26_stage_grub_target() {
    local source_id=$1 original_order=$2 reference=$3 direct target
    if [[ ${BOOTLOADER:-} != refind ]]; then r26_stage_grub_target_pre_leap16_r64 "$@"; return $?; fi
    leap16_r38_install_grub_packages_if_needed || return 1
    r28_snapshot_source_boot_aux || return 1
    leap16_r38_install_native_grub_files || return 1
    r28_create_alias_create_only "$R28_GRUB_DIRECT_LABEL" "$R28_GRUB_DIRECT_PATH" || return 1; direct=$R28_CREATED_ALIAS_ID
    r28_create_alias_create_only "$R28_GRUB_SHIM_LABEL" "$R28_GRUB_SHIM_PATH" || return 1; target=$R28_CREATED_ALIAS_ID
    LEAP16_R64_STAGED_GRUB_DIRECT=${direct^^}; LEAP16_R64_STAGED_GRUB_TARGET=${target^^}
    set_source_first_boot_order "$source_id" "$target" "$original_order" || return 1
    ! leap16_order_has_id "$(leap16_current_boot_order)" "$direct" || { fail 'Direct GRUB alias entered BootOrder during candidate staging'; return 1; }
    r26_restore_source_fallback_after_target_stage || return 1
    r28_restore_source_boot_aux || return 1
    LEAP16_R64_STAGING=1
    leap16_r64_validate_grub_candidate || { LEAP16_R64_STAGING=0; return 1; }
    r26_record_target_adapter grub || { LEAP16_R64_STAGING=0; return 1; }
    leap16_r64_write_meta 'refind:grub' "$direct" || { LEAP16_R64_STAGING=0; return 1; }
    LEAP16_R64_STAGING=0
    R26_STAGED_TARGET_ID=${target^^}
    ok "Staged native openSUSE shim target as Boot${target^^}; direct GRUB Boot${direct^^} is parked outside BootOrder"
}

leap16_r64_patch_limine_pretransfer_comment() {
    local conf="${ESP_MOUNT%/}/limine.conf" tmp
    tmp=$(mktemp) || return 1
    leap16_r64_refind_read "$conf" >"$tmp" || { rm -f -- "$tmp"; return 1; }
    sed -i 's|^comment: Preserved openSUSE generic fallback / GRUB2 recovery path$|comment: Preserved openSUSE generic fallback / rEFInd recovery path|' "$tmp" || { rm -f -- "$tmp"; return 1; }
    sudo install -o root -g root -m 0644 -- "$tmp" "$conf" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
}

leap16_r64_stage_limine_target() {
    local source_id=${1^^} original_order=$2 reference=$3 target_id conf_hash
    [[ ${BOOTLOADER:-} == refind ]] || return 1
    LEAP16_R64_STAGING=1
    leap16_prepare_limine_assets || { LEAP16_R64_STAGING=0; return 1; }
    write_limine_candidate_policy || { LEAP16_R64_STAGING=0; return 1; }
    stage_limine_kernel_entries_from_existing_artifacts || { LEAP16_R64_STAGING=0; return 1; }
    leap16_r64_patch_limine_pretransfer_comment || { LEAP16_R64_STAGING=0; return 1; }
    leap16_install_limine_efi_payload || { LEAP16_R64_STAGING=0; return 1; }
    r26_restore_source_fallback_after_target_stage || { LEAP16_R64_STAGING=0; return 1; }
    validate_limine_boot_chain migration || { LEAP16_R64_STAGING=0; return 1; }
    LEAP16_CREATED_TARGET_ID=''
    leap16_create_limine_nvram_candidate "$original_order" || { LEAP16_R64_STAGING=0; return 1; }
    target_id=${LEAP16_CREATED_TARGET_ID^^}
    [[ $target_id =~ ^[0-9A-F]{4}$ ]] || { LEAP16_R64_STAGING=0; fail 'Limine staging did not publish a valid Boot####'; return 1; }
    [[ ${BOOT_CURRENT^^} == "$source_id" ]] || { LEAP16_R64_STAGING=0; fail 'rEFInd BootCurrent changed during Limine staging'; return 1; }
    r26_restore_source_fallback_after_target_stage || { LEAP16_R64_STAGING=0; return 1; }
    adapter_target_validate limine || { LEAP16_R64_STAGING=0; return 1; }
    r26_record_target_adapter limine || { LEAP16_R64_STAGING=0; return 1; }
    conf_hash=$(r21_hash_privileged "${ESP_MOUNT%/}/limine.conf")
    [[ $conf_hash =~ ^[0-9A-Fa-f]{64}$ ]] || { LEAP16_R64_STAGING=0; fail 'Could not freeze primary Limine config hash'; return 1; }
    leap16_r64_write_meta 'refind:limine' '' "$conf_hash" || { LEAP16_R64_STAGING=0; return 1; }
    LEAP16_R64_STAGING=0
    R26_STAGED_TARGET_ID=$target_id
    ok "Staged canonical Limine target as parked Boot$target_id while rEFInd remains persistent first"
}

if declare -F adapter_target_stage >/dev/null 2>&1; then
    eval "$(declare -f adapter_target_stage | sed '1s/adapter_target_stage/adapter_target_stage_pre_leap16_r64/')"
fi
adapter_target_stage() {
    local target=$1
    if [[ ${BOOTLOADER:-} == refind && $target == limine ]]; then
        leap16_r64_stage_limine_target "$2" "$3" "$4"
    else
        adapter_target_stage_pre_leap16_r64 "$@"
    fi
}

# ---------------------------------------------------------------------------
# Pending compatibility + candidate ownership extensions
# ---------------------------------------------------------------------------

if declare -F validate_pending_compatibility >/dev/null 2>&1; then
    eval "$(declare -f validate_pending_compatibility | sed '1s/validate_pending_compatibility/validate_pending_compatibility_pre_leap16_r64/')"
fi
validate_pending_compatibility() {
    validate_pending_compatibility_pre_leap16_r64 "$@" || return $?
    leap16_r64_pending_edge || return 0
    local p direction
    p=$(leap16_r64_meta_path 2>/dev/null || true)
    [[ -s $p ]] || { PENDING_REASON='r64 rEFInd-edge metadata is missing'; return 1; }
    direction=$(leap16_r64_meta_value direction)
    [[ $direction == "${PENDING_SOURCE}:${PENDING_TARGET}" ]] || { PENDING_REASON='r64 direction metadata disagrees with pending state'; return 1; }
    [[ -s "$PENDING_TRANSACTION_SNAPSHOT_DIR/$LEAP16_R64_FIRMWARE_BASELINE" ]] || { PENDING_REASON='r64 pre-stage firmware baseline is missing'; return 1; }
    if [[ $direction == refind:grub ]]; then
        leap16_r64_grub_direct_id >/dev/null || { PENDING_REASON='r64 direct GRUB alias metadata is invalid'; return 1; }
        [[ -s "$PENDING_TRANSACTION_SNAPSHOT_DIR/r28-efi-boot-aux-before.tsv" && -s "$PENDING_TRANSACTION_SNAPSHOT_DIR/r28-efi-boot-aux-generated.tsv" ]] \
            || { PENDING_REASON='r64 GRUB EFI/BOOT auxiliary ownership metadata is incomplete'; return 1; }
    elif [[ $direction == refind:limine ]]; then
        local ph fh ch fid
        ph=$(leap16_r64_meta_value limine_primary_conf_hash)
        [[ $ph =~ ^[0-9A-Fa-f]{64}$ ]] || { PENDING_REASON='r64 primary Limine config hash is invalid'; return 1; }
        fid=$(leap16_r64_meta_value limine_fallback_id); fh=$(leap16_r64_meta_value limine_fallback_hash); ch=$(leap16_r64_meta_value limine_transferred_conf_hash)
        if [[ -n $fid || -n $fh || -n $ch ]]; then
            [[ ${fid^^} =~ ^[0-9A-F]{4}$ && $fh =~ ^[0-9A-Fa-f]{64}$ && $ch =~ ^[0-9A-Fa-f]{64}$ ]] \
                || { PENDING_REASON='r64 Limine fallback metadata is malformed'; return 1; }
            [[ $fh == "$PENDING_TARGET_EFI_HASH" ]] || { PENDING_REASON='r64 Limine fallback hash is not byte-bound to the primary Limine EFI'; return 1; }
        fi
    fi
    PENDING_REASON='compatible'
    return 0
}

if declare -F verify_pending_candidate_ownership_unchanged >/dev/null 2>&1; then
    eval "$(declare -f verify_pending_candidate_ownership_unchanged | sed '1s/verify_pending_candidate_ownership_unchanged/verify_pending_candidate_ownership_unchanged_pre_leap16_r64/')"
fi
verify_pending_candidate_ownership_unchanged() {
    verify_pending_candidate_ownership_unchanged_pre_leap16_r64 "$@" || return $?
    if [[ ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == refind:grub ]]; then leap16_r64_validate_grub_direct_alias || return 1; fi
    return 0
}

# ---------------------------------------------------------------------------
# Preflight / live plans / dispatch
# ---------------------------------------------------------------------------

leap16_r64_preflight() {
    local target=$1 current=${BOOTLOADER:-unknown} p
    leap16_r64_refind_edge "$current" "$target" || return 1
    printf '\n%s %s -> %s preflight:\n' "${SWITCHER_RELEASE:-leap16-r64}" "$(bootloader_display_name "$current")" "$(bootloader_display_name "$target")"
    run_validation preflight || { fail 'Base preflight failed; nothing was modified'; return 1; }
    is_leap16 || { fail 'r64 rEFInd adapters are restricted to openSUSE Leap 16'; return 1; }
    leap16_require_sudo_session || return 1
    bootcurrent_is_generic_fallback && { fail 'A canonical source BootCurrent is required; current session came through generic EFI fallback'; return 1; }
    pending_exists && { fail 'A bootloader transaction is already pending'; return 1; }
    [[ -z ${BOOT_NEXT:-} ]] || { fail "BootNext is already set to Boot${BOOT_NEXT^^}"; return 1; }
    printf '\nSource adapter deep gate (%s):\n' "$(bootloader_display_name "$current")"
    case "$current" in
        refind) leap16_r64_refind_source_gate || return 1 ;;
        limine) validate_limine_boot_chain current && leap16_r48_source_topology_gate || return 1 ;;
        systemd-boot) leap16_r51_systemd_source_gate || return 1 ;;
        grub) validate_grub_boot_chain current || return 1 ;;
        *) return 1 ;;
    esac
    case "$target" in
        refind) leap16_r64_refind_namespace_clean || return 1 ;;
        systemd-boot) leap16_r32_secure_boot_disabled || return 1; leap16_r64_systemd_namespace_clean || return 1 ;;
        grub) leap16_r64_grub_namespace_clean || return 1 ;;
        limine)
            leap16_r64_limine_namespace_clean || return 1
            for p in efibootmgr lsblk findmnt sha256sum b2sum tar od cmp stat df; do have "$p" || { fail "Required command is missing: $p"; return 1; }; done
            (have curl || have wget || [[ -n ${BOOTLOADER_SWITCHER_LIMINE_ARCHIVE:-} ]]) || { fail 'curl or wget is required unless a pinned Limine archive is configured'; return 1; }
            efibootmgr --help 2>&1 | grep -q -- '--create-only' || { fail 'efibootmgr lacks --create-only'; return 1; }
            leap16_verify_esp_capacity || return 1
            ;;
    esac
    collect_kernels; ((${#KERNEL_VERSIONS[@]} > 0)) || { fail 'No complete Leap kernel/initrd pairs are available'; return 1; }
    ok "r64 preflight passed; $(bootloader_display_name "$current") remains authoritative until target runtime proof"
}

leap16_r64_plan() {
    local current=$1 target=$2
    printf '\nLeap rEFInd transaction plan:\n'
    printf '  1. Freeze exact source files, generic-fallback state and the complete firmware table.\n'
    printf '  2. Stage %s without changing /etc/fstab and keep %s persistent-first.\n' "$(bootloader_display_name "$target")" "$(bootloader_display_name "$current")"
    if [[ $target == refind ]]; then
        printf '  3. Install native openSUSE rEFInd + ext4 driver, direct-kernel scanner policy and source-cmdline refind_linux.conf; exclude EFI source/reference namespaces.\n'
        printf '  4. Arm exactly one canonical rEFInd BootNext and require PreviousBoot to prove direct launch of the running Leap kernel.\n'
        printf '  5. Only after proof: remove every bounded source alias from BootOrder while source EFI still exists, then retire exact source-owned files. rEFInd does not claim EFI/BOOT.\n'
    elif [[ $current == refind && $target == limine ]]; then
        printf '  3. Stage canonical Limine; after its first runtime proof promote it but keep rEFInd as direct recovery.\n'
        printf '  4. Transfer EFI/BOOT to byte-identical Limine, create/adopt one explicit fallback Boot#### and require a second independent BootNext proof.\n'
        printf '  5. Only after fallback BootCurrent proof: retire exact rEFInd NVRAM/files and leave Limine primary+fallback first.\n'
    elif [[ $current == refind && $target == grub ]]; then
        printf '  3. Reconstruct native openSUSE shim/GRUB, stage shim as target and park the direct-GRUB alias outside BootOrder.\n'
        printf '  4. After shim runtime proof: promote shim, transfer EFI/BOOT, make direct GRUB second, then retire exact rEFInd state.\n'
    else
        printf '  3. Stage native openSUSE systemd-boot+BLS and require exact runtime proof.\n'
        printf '  4. After proof: promote systemd-boot, transfer EFI/BOOT to it, then retire exact rEFInd state.\n'
    fi
    printf '  Rollback before proof removes only transaction-owned target state and restores the frozen source/fallback topology.\n'
}

leap16_r64_run_refind_edge_inner() {
    local target=$1 current=$BOOTLOADER rc=0
    leap16_r64_preflight "$target" || return 1
    offer_operation_backup || return 1
    leap16_r64_plan "$current" "$target"
    confirm_operation "$current" "$target" || { printf '\nOperation cancelled. No boot state was modified.\n'; return 0; }
    printf '\nRe-running the complete r64 preflight at the write boundary...\n'
    leap16_r64_preflight "$target" || { printf '\nWrite-boundary revalidation failed. Nothing was modified.\n'; return 1; }
    LEAP16_R64_ACTIVE_TARGET=$target
    r26_execute_adapter_switch "$target" || rc=$?
    LEAP16_R64_ACTIVE_TARGET=''
    return "$rc"
}

if declare -F operation_supported >/dev/null 2>&1; then
    eval "$(declare -f operation_supported | sed '1s/operation_supported/operation_supported_pre_leap16_r64/')"
fi
operation_supported() {
    leap16_r64_refind_edge "$1" "$2" && return 0
    operation_supported_pre_leap16_r64 "$@"
}

if declare -F run_live_operation >/dev/null 2>&1; then
    eval "$(declare -f run_live_operation | sed '1s/run_live_operation/run_live_operation_pre_leap16_r64/')"
fi
run_live_operation() {
    local target=$1 current=$BOOTLOADER
    if leap16_r64_refind_edge "$current" "$target"; then
        leap16_r44_with_transaction_transcript "$current" "$target" switch leap16_r64_run_refind_edge_inner "$target"
        return $?
    fi
    run_live_operation_pre_leap16_r64 "$@"
}


# ---------------------------------------------------------------------------
# Leap-safe source retirement for a runtime-proven rEFInd target
# ---------------------------------------------------------------------------

leap16_r64_order_without_source_ids() {
    local target=${PENDING_TARGET_BOOT_ID^^} source=${PENDING_SOURCE} source_ids order id joined
    local -a current=() out=("$target")
    source_ids=$(leap16_r64_current_ids_for_source_paths "$source" | paste -sd, -)
    [[ -n $source_ids ]] || { fail 'No bounded source firmware aliases are visible before source retirement'; return 1; }
    order=$(leap16_current_boot_order) || return 1
    IFS=',' read -ra current <<<"$order"
    for id in "${current[@]}"; do
        id=${id^^}; [[ -n $id && $id != "$target" ]] || continue
        case ",$source_ids," in *,"$id",*) continue ;; esac
        boot_id_exists "$id" && out+=("$id")
    done
    joined=$(IFS=,; printf '%s' "${out[*]}")
    sudo efibootmgr -o "$joined" >/dev/null || return 1
    [[ $(pending_bootorder_first) == "$target" ]] || { fail 'rEFInd target is not first after source aliases were removed from BootOrder'; return 1; }
    for id in ${source_ids//,/ }; do leap16_order_has_id "$(leap16_current_boot_order)" "$id" && { fail "Source Boot$id remains in persistent BootOrder"; return 1; }; done
    ok 'Removed all bounded source aliases from persistent BootOrder while their EFI files still exist'
}

leap16_r64_delete_source_ids_exact() {
    local source=$PENDING_SOURCE ids id baseline expected
    leap16_r64_verify_source_alias_superset "$source" || return 1
    ids=$(leap16_r64_current_ids_for_source_paths "$source" | paste -sd, -)
    [[ -n $ids ]] || return 1
    # Delete all current same-path/same-ESP source aliases.  Baseline aliases
    # are mandatory; extras are bounded firmware-created aliases to those same
    # exact source paths and are safe to normalize away before files retire.
    IFS=',' read -ra _r64_source_ids <<<"$ids"
    for id in "${_r64_source_ids[@]}"; do
        id=${id^^}; [[ $id =~ ^[0-9A-F]{4}$ ]] || return 1
        leap16_nvram_entry_matches_current_esp "$id" || { fail "Source Boot$id changed ESP binding"; return 1; }
        sudo efibootmgr -b "$id" -B >/dev/null || { fail "Could not delete source Boot$id"; return 1; }
        boot_id_exists "$id" && { fail "Firmware still exposes source Boot$id after deletion"; return 1; }
        ok "Deleted bounded source Boot$id only after it was absent from persistent BootOrder"
    done
    [[ -z $(leap16_r64_current_ids_for_source_paths "$source" | awk 'NF') ]] || { fail 'A bounded source-path alias remains after retirement'; return 1; }
}

leap16_r64_retire_source_manifest_and_fallback() {
    local source=$PENDING_SOURCE fallback="$PENDING_OLD_FALLBACK_PATH" hash
    r26_verify_owned_manifest "$PENDING_SOURCE_MANIFEST" || return 1
    r26_remove_owned_manifest_paths "$PENDING_SOURCE_MANIFEST" || return 1
    case "$source" in
        systemd-boot)
            sudo rmdir -- "$PENDING_ESP_MOUNT/loader/entries" 2>/dev/null || true
            sudo rmdir -- "$PENDING_ESP_MOUNT/loader" 2>/dev/null || true
            sudo rmdir -- "$PENDING_ESP_MOUNT/$PENDING_MACHINE_ID" 2>/dev/null || true
            ;;
        limine) leap16_r47_cleanup_empty_machine_id_parent || true ;;
    esac
    if [[ $PENDING_OLD_FALLBACK_EXISTED == 1 && $PENDING_SOURCE_FALLBACK_OWNED == 1 ]]; then
        hash=$(r21_hash_privileged "$fallback")
        [[ $hash == "$PENDING_OLD_FALLBACK_HASH" ]] || { fail 'Source-owned generic fallback changed before rEFInd retirement'; return 1; }
        sudo rm -f -- "$fallback" || return 1
        ok 'Removed ownership-proven source generic EFI fallback; rEFInd intentionally does not claim EFI/BOOT'
    elif [[ $PENDING_OLD_FALLBACK_EXISTED == 1 ]]; then
        hash=$(r21_hash_privileged "$fallback")
        [[ $hash == "$PENDING_OLD_FALLBACK_HASH" ]] || { fail 'Unrelated generic EFI fallback changed during rEFInd transaction'; return 1; }
        ok 'Preserved unrelated pre-existing generic EFI fallback byte-for-byte'
    fi
}

leap16_r64_set_refind_policy() {
    # openSUSE has no native LOADER_TYPE=rEFInd contract.  Use the established
    # non-systemd compatibility value already used by finalized Limine, while
    # rEFInd itself remains proven by BootCurrent/path/config ownership.
    leap16_r51_set_final_limine_policy
}

leap16_r64_finalize_to_refind() {
    local target=${PENDING_TARGET_BOOT_ID^^} source=$PENDING_SOURCE detail
    validate_pending_compatibility || { fail "Pending rEFInd transaction is incompatible: $PENDING_REASON"; return 1; }
    [[ $PENDING_PHASE == runtime-validated && $PENDING_TARGET == refind ]] || { fail 'rEFInd finalization requires runtime-validated target state'; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == refind && ${BOOT_CURRENT^^} == "$target" ]] || { fail "Finalization must run from runtime-proven rEFInd Boot$target"; return 1; }
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext must be clear before rEFInd finalization'; return 1; }
    run_validation preflight || return 1
    pending_validate_running_kernel || return 1
    pending_validate_runtime_cmdline_against_source || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    r33_verify_refind_direct_kernel_launch || return 1
    validate_refind_boot_chain runtime || return 1
    verify_pending_source_recovery_unchanged || return 1
    leap16_r64_verify_source_alias_superset "$source" || return 1

    printf '\nFINALIZE %s -> rEFInd only after direct-kernel runtime proof:\n' "$(bootloader_display_name "$source")"
    printf '  - promote rEFInd Boot%s first while every source recovery alias/file is still exact\n' "$target"
    printf '  - remove every bounded source alias from BootOrder before deleting any source EFI bytes\n'
    printf '  - retire only the frozen source ownership manifest; never claim an unrelated EFI/BOOT fallback\n'

    leap16_r34_target_first_keep_recovery || { fail 'Could not promote rEFInd while retaining source recovery'; return 1; }
    validate_refind_boot_chain target || { fail 'rEFInd validation failed after promotion; source cleanup was not attempted'; return 1; }
    verify_pending_source_recovery_unchanged || { fail 'Source recovery changed after rEFInd promotion; cleanup refused'; return 1; }
    leap16_r64_verify_source_alias_superset "$source" || return 1
    leap16_r64_order_without_source_ids || return 1
    leap16_r64_delete_source_ids_exact || return 1
    leap16_r64_retire_source_manifest_and_fallback || return 1
    leap16_r64_set_refind_policy || return 1

    detect_bootloader
    [[ $BOOTLOADER == refind && ${BOOT_CURRENT^^} == "$target" ]] || { fail 'rEFInd BootCurrent identity changed during source retirement'; return 1; }
    [[ $(pending_bootorder_first) == "$target" ]] || { fail 'rEFInd is not persistent-first after source retirement'; return 1; }
    [[ -z $(leap16_r64_current_ids_for_source_paths "$source" | awk 'NF') ]] || { fail 'Source NVRAM alias remains after rEFInd finalization'; return 1; }
    validate_refind_boot_chain final || return 1
    r33_verify_refind_direct_kernel_launch || return 1
    pending_capture_runtime_diagnostics "finalized-refind-from-$source" >/dev/null 2>&1 || true
    if [[ -n ${PENDING_BACKUP_PATH:-} ]]; then
        detail="$(bootloader_display_name "$source") -> restored rEFInd backup completed after direct-kernel runtime proof. rEFInd Boot$target is first; exact source-owned NVRAM/files were retired; unrelated EFI/BOOT state was preserved. Backup: $PENDING_BACKUP_PATH"
    else
        detail="$(bootloader_display_name "$source") -> rEFInd completed after direct-kernel runtime proof. rEFInd Boot$target is first; exact source-owned NVRAM/files were retired; unrelated EFI/BOOT state was preserved."
    fi
    r35_write_local_transaction_result success "$detail" || true
    remove_pending_transaction_snapshot || warn 'Could not remove private r64 snapshot after successful rEFInd finalization'
    rm -f -- "$PENDING_STATE_FILE"
    printf '\nFINALIZED %s -> rEFInd successfully.\n' "$(bootloader_display_name "$source")"
}

# ---------------------------------------------------------------------------
# rEFInd -> systemd-boot finalization
# ---------------------------------------------------------------------------

leap16_r64_remove_refind_from_order_keep() {
    local -a prefix=("$@") current=() out=() seen=() ; local order id p joined skip
    order=$(leap16_current_boot_order) || return 1
    out=("${prefix[@]}")
    IFS=',' read -ra current <<<"$order"
    for id in "${current[@]}"; do
        id=${id^^}; [[ -n $id ]] || continue
        skip=0
        for p in "${prefix[@]}" "${PENDING_OLD_BOOT_ID^^}"; do [[ $id == ${p^^} ]] && { skip=1; break; }; done
        ((skip)) && continue
        boot_id_exists "$id" && out+=("$id")
    done
    joined=$(IFS=,; printf '%s' "${out[*]}")
    sudo efibootmgr -o "$joined" >/dev/null || return 1
    [[ $(leap16_current_boot_order) == "$(IFS=,; printf '%s' "${prefix[*]}")"* ]] || return 1
}

leap16_r64_delete_refind_source() {
    local source=${PENDING_OLD_BOOT_ID^^}
    boot_id_exists "$source" || { fail "rEFInd source Boot$source disappeared before retirement"; return 1; }
    nvram_id_matches_path "$source" "$LEAP16_R64_REFIND_EFI" || { fail 'rEFInd source path changed before retirement'; return 1; }
    leap16_nvram_entry_matches_current_esp "$source" || { fail 'rEFInd source ESP binding changed before retirement'; return 1; }
    sudo efibootmgr -b "$source" -B >/dev/null || return 1
    boot_id_exists "$source" && { fail "rEFInd source Boot$source remains after deletion"; return 1; }
    r26_remove_owned_manifest_paths "$PENDING_SOURCE_MANIFEST" || return 1
    ok 'Retired exact rEFInd source NVRAM + immutable adapter-owned files; mutable vars disappeared with the owned EFI/refind tree'
}

leap16_r64_finalize_refind_to_systemd() {
    local target=${PENDING_TARGET_BOOT_ID^^} source=${PENDING_OLD_BOOT_ID^^} detail
    validate_pending_compatibility || return 1
    [[ ${PENDING_SOURCE}:${PENDING_TARGET} == refind:systemd-boot && $PENDING_PHASE == runtime-validated ]] || return 1
    detect_bootloader
    [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == "$target" ]] || { fail 'systemd-boot finalization must run from the exact runtime-proven target'; return 1; }
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext must be clear before finalization'; return 1; }
    run_validation preflight || return 1
    pending_validate_running_kernel || return 1
    pending_validate_runtime_cmdline_against_source || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    leap16_r34_validate_systemd_boot_chain runtime || return 1
    verify_pending_source_recovery_unchanged || return 1
    leap16_r34_target_first_keep_recovery || return 1
    leap16_r34_validate_systemd_boot_chain target || return 1
    verify_pending_source_recovery_unchanged || return 1
    leap16_r34_transfer_systemd_fallback || return 1
    # Fallback may have transferred only if the old state was absent/source-owned.
    r26_verify_owned_manifest "$PENDING_SOURCE_MANIFEST" || return 1
    leap16_r64_remove_refind_from_order_keep "$target" || { fail 'Could not remove rEFInd from BootOrder while its EFI still exists'; return 1; }
    leap16_r64_delete_refind_source || return 1
    leap16_r34_set_loader_policy_systemd || return 1
    detect_bootloader
    [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == "$target" ]] || return 1
    [[ $(pending_bootorder_first) == "$target" ]] || return 1
    leap16_r34_validate_systemd_boot_chain final || return 1
    pending_capture_runtime_diagnostics finalized-systemd-boot-from-refind >/dev/null 2>&1 || true
    if [[ -n ${PENDING_BACKUP_PATH:-} ]]; then detail="rEFInd -> restored systemd-boot backup finalized after exact runtime proof. systemd-boot Boot$target is first and rEFInd source state is retired. Backup: $PENDING_BACKUP_PATH"; else detail="rEFInd -> systemd-boot finalized after exact runtime proof. systemd-boot Boot$target is first and rEFInd source state is retired."; fi
    r35_write_local_transaction_result success "$detail" || true
    remove_pending_transaction_snapshot || true; rm -f -- "$PENDING_STATE_FILE"
    printf '\nFINALIZED rEFInd -> systemd-boot successfully.\n'
}

# ---------------------------------------------------------------------------
# rEFInd -> native GRUB finalization
# ---------------------------------------------------------------------------

leap16_r64_final_grub_order() {
    local target=${PENDING_TARGET_BOOT_ID^^} direct source=${PENDING_OLD_BOOT_ID^^} order id joined
    direct=$(leap16_r64_grub_direct_id) || return 1
    local -a current=() out=("$target" "$direct")
    order=$(leap16_current_boot_order) || return 1
    IFS=',' read -ra current <<<"$order"
    for id in "${current[@]}"; do
        id=${id^^}; [[ -n $id && $id != "$target" && $id != "$direct" && $id != "$source" ]] || continue
        boot_id_exists "$id" && out+=("$id")
    done
    joined=$(IFS=,; printf '%s' "${out[*]}")
    sudo efibootmgr -o "$joined" >/dev/null || return 1
    [[ $(leap16_current_boot_order) == "$target,$direct"* ]] || { fail 'Final GRUB order does not begin shim,direct'; return 1; }
}

leap16_r64_finalize_refind_to_grub() {
    local target=${PENDING_TARGET_BOOT_ID^^} source=${PENDING_OLD_BOOT_ID^^} direct detail
    direct=$(leap16_r64_grub_direct_id) || return 1
    validate_pending_compatibility || return 1
    [[ ${PENDING_SOURCE}:${PENDING_TARGET} == refind:grub && $PENDING_PHASE == runtime-validated ]] || return 1
    detect_bootloader
    [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == "$target" ]] || { fail "GRUB finalization must run from runtime-proven shim Boot$target"; return 1; }
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext must be clear before GRUB finalization'; return 1; }
    run_validation preflight || return 1
    pending_validate_running_kernel || return 1
    pending_validate_runtime_cmdline_against_source || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_grub_boot_chain runtime || return 1
    verify_pending_source_recovery_unchanged || return 1
    leap16_r64_validate_grub_direct_alias || return 1

    leap16_r34_target_first_keep_recovery || { fail 'Could not promote GRUB shim while retaining rEFInd recovery'; return 1; }
    validate_grub_boot_chain target || return 1
    verify_pending_source_recovery_unchanged || return 1
    leap16_r38_transfer_grub_fallback || return 1
    r26_verify_owned_manifest "$PENDING_SOURCE_MANIFEST" || return 1
    leap16_r64_final_grub_order || return 1
    leap16_r64_delete_refind_source || return 1
    leap16_r38_set_loader_policy_grub || return 1

    detect_bootloader
    [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == "$target" ]] || return 1
    [[ $(leap16_current_boot_order) == "$target,$direct"* ]] || return 1
    [[ $(r21_hash_privileged "$PENDING_ESP_MOUNT/EFI/BOOT/BOOTX64.EFI") == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'Final EFI/BOOT is not byte-identical to the proven shim'; return 1; }
    validate_grub_boot_chain final || return 1
    leap16_r64_validate_grub_direct_alias || return 1
    pending_capture_runtime_diagnostics finalized-grub-from-refind >/dev/null 2>&1 || true
    if [[ -n ${PENDING_BACKUP_PATH:-} ]]; then detail="rEFInd -> restored native GRUB2 backup finalized after exact shim runtime proof. Shim Boot$target is first; direct GRUB Boot$direct second; EFI/BOOT is shim-owned; rEFInd is retired. Backup: $PENDING_BACKUP_PATH"; else detail="rEFInd -> native GRUB2 finalized after exact shim runtime proof. Shim Boot$target is first; direct GRUB Boot$direct second; EFI/BOOT is shim-owned; rEFInd is retired."; fi
    r35_write_local_transaction_result success "$detail" || true
    remove_pending_transaction_snapshot || true; rm -f -- "$PENDING_STATE_FILE"
    printf '\nFINALIZED rEFInd -> native GRUB2 successfully.\n'
}


# ---------------------------------------------------------------------------
# r64 completion overlay: pending admission, backups/restores, two-proof
# rEFInd->Limine completion, root resume, rollback, strict transcript dispatch,
# and explicit matrix reporting.
# ---------------------------------------------------------------------------

# r51's active loader still rejects the six new format-v5 rEFInd directions.
if declare -F load_pending_state >/dev/null 2>&1; then
    eval "$(declare -f load_pending_state | sed '1s/load_pending_state/load_pending_state_pre_leap16_r64/')"
fi
load_pending_state() {
    if load_pending_state_pre_leap16_r64 "$@"; then
        return 0
    fi
    [[ $(r26_state_format 2>/dev/null || true) == "$R26_PENDING_FORMAT" \
       && ${PENDING_REASON:-} == 'unsupported r26 adapter migration direction' ]] || return 1
    leap16_r64_refind_edge "${PENDING_SOURCE:-}" "${PENDING_TARGET:-}" || return 1
    [[ $PENDING_PHASE == candidate-ready || $PENDING_PHASE == boot-armed || $PENDING_PHASE == runtime-validated ]] \
        || { PENDING_REASON='unsupported r64 pending-state phase'; return 1; }
    [[ $PENDING_FORMAT == "$R26_PENDING_FORMAT" ]] || { PENDING_REASON='wrong r26 state format'; return 1; }
    [[ $PENDING_ADAPTER_REVISION == "$R26_ADAPTER_REVISION" ]] || { PENDING_REASON='unsupported adapter-state revision'; return 1; }
    [[ -n $PENDING_MACHINE_ID && -n $PENDING_OLD_BOOT_ID && -n $PENDING_TARGET_BOOT_ID ]] \
        || { PENDING_REASON='missing transaction identity'; return 1; }
    [[ -n $PENDING_SOURCE_CMDLINE && -n $PENDING_SOURCE_MANIFEST && -n $PENDING_TARGET_MANIFEST ]] \
        || { PENDING_REASON='missing r64 source/candidate evidence'; return 1; }
    PENDING_REASON='valid'
    return 0
}

# ---------------------------------------------------------------------------
# rEFInd user backup: immutable EFI/refind tree + /boot/refind_linux.conf.
# EFI/refind/vars is intentionally excluded because PreviousBoot is runtime
# evidence and must be recreated by the next real rEFInd boot.
# ---------------------------------------------------------------------------

leap16_r64_refind_backup_root() {
    local dir=$1 mount=${2:-${esp_mount:-}} rel
    rel=${mount#/}
    [[ -n $rel && $rel != *'..'* ]] || return 1
    printf '%s/files/%s/EFI/refind\n' "$dir" "$rel"
}

leap16_r64_refind_backup_payload_valid() {
    local dir=$1 reference=${2:-} root conf efi linuxconf driver options value low m
    root=$(leap16_r64_refind_backup_root "$dir") || { BACKUP_VALIDATION_REASON='invalid rEFInd backup ESP mount metadata'; return 1; }
    conf="$root/refind.conf"; efi="$root/refind_x64.efi"; driver="$root/drivers_x64/ext4_x64.efi"; linuxconf="$dir/files/boot/refind_linux.conf"
    [[ -d $root && ! -L $root ]] || { BACKUP_VALIDATION_REASON='rEFInd backup is missing a safe EFI/refind tree'; return 1; }
    [[ -f $conf && ! -L $conf && -f $efi && ! -L $efi && -f $linuxconf && ! -L $linuxconf ]] \
        || { BACKUP_VALIDATION_REASON='rEFInd backup is missing canonical EFI/config/refind_linux.conf state'; return 1; }
    [[ ! -e $root/vars && ! -L $root/vars ]] || { BACKUP_VALIDATION_REASON='mutable EFI/refind/vars must not be present in an immutable r64 backup'; return 1; }
    m=$(mktemp) || return 1
    r35_refind_tree_manifest "$root" "$m" user || { rm -f -- "$m"; BACKUP_VALIDATION_REASON='rEFInd immutable tree contains an unsafe object'; return 1; }
    rm -f -- "$m"
    [[ $(od -An -tx1 -N2 -- "$efi" 2>/dev/null | tr -d '[:space:]') == 4d5a ]] \
        || { BACKUP_VALIDATION_REASON='backed-up rEFInd EFI lacks an MZ header'; return 1; }
    if have file; then leap16_is_x86_64_efi_application "$efi" || { BACKUP_VALIDATION_REASON='backed-up rEFInd EFI is not x86-64'; return 1; }; fi
    [[ -f $driver && ! -L $driver ]] || { BACKUP_VALIDATION_REASON='rEFInd backup is missing the ext4 filesystem driver'; return 1; }

    value=$(awk 'BEGIN{IGNORECASE=1} /^[[:space:]]*#/ {next} $1=="scan_all_linux_kernels"{print $2;exit}' "$conf")
    [[ ${value,,} == true ]] || { BACKUP_VALIDATION_REASON='backed-up rEFInd does not enable scan_all_linux_kernels'; return 1; }
    value=$(awk 'BEGIN{IGNORECASE=1} /^[[:space:]]*#/ {next} $1=="use_nvram"{print $2;exit}' "$conf")
    [[ ${value,,} == false ]] || { BACKUP_VALIDATION_REASON='backed-up rEFInd use_nvram policy is not false'; return 1; }
    value=$(awk 'BEGIN{IGNORECASE=1} /^[[:space:]]*#/ {next} $1=="scanfor"{$1="";sub(/^[[:space:]]+/,"");print;exit}' "$conf")
    [[ ${value// /} == *internal* ]] || { BACKUP_VALIDATION_REASON='backed-up rEFInd scanfor does not include internal'; return 1; }
    value=$(awk 'BEGIN{IGNORECASE=1} /^[[:space:]]*#/ {next} $1=="dont_scan_dirs"{$1="";sub(/^[[:space:]]+/,"");print;exit}' "$conf"); low=${value,,}
    local d
    for d in efi/boot efi/opensuse efi/limine efi/systemd efi/opensuse-bootloader-switcher; do
        [[ $low == *"$d"* ]] || { BACKUP_VALIDATION_REASON="backed-up rEFInd scanner exclusion is missing $d"; return 1; }
    done
    options=$(refind_standard_options "$linuxconf" 2>/dev/null || true)
    [[ -n $options ]] || { BACKUP_VALIDATION_REASON='backed-up refind_linux.conf has no standard options'; return 1; }
    [[ -n ${root_uuid:-} ]] && grep -Eq "(^|[[:space:]])root=UUID=${root_uuid//./\\.}([[:space:]]|$)" <<<"$options" \
        || { BACKUP_VALIDATION_REASON='backed-up rEFInd options do not reference the recorded root UUID'; return 1; }
    if [[ -n $reference ]]; then
        pending_cmdline_equivalent "$options" "$reference" || { BACKUP_VALIDATION_REASON='backed-up rEFInd options are not token-equivalent to the current proven runtime cmdline'; return 1; }
    fi
    grep -Eq '^"Boot to single-user mode"[[:space:]]+".+[[:space:]]single"$' "$linuxconf" \
        || { BACKUP_VALIDATION_REASON='backed-up rEFInd single-user options line is missing'; return 1; }
    [[ -s $dir/kernel-versions.txt ]] || { BACKUP_VALIDATION_REASON='rEFInd backup kernel list is missing'; return 1; }
    [[ -s $dir/package-state.txt ]] || { BACKUP_VALIDATION_REASON='rEFInd backup RPM package snapshot is missing'; return 1; }
    grep -Eq '^refind-[^[:space:]]+' "$dir/package-state.txt" || { BACKUP_VALIDATION_REASON='rEFInd package is absent from the backup RPM snapshot'; return 1; }
    return 0
}

if declare -F validate_backup >/dev/null 2>&1; then
    eval "$(declare -f validate_backup | sed '1s/validate_backup/validate_backup_pre_leap16_r64/')"
fi
validate_backup() {
    local dir=$1
    unset format_version backup_platform backup_schema switcher_release bootloader payload_policy \
          created_epoch created_iso hostname machine_id esp_source esp_mount esp_uuid \
          root_source root_uuid boot_current boot_label boot_efi_path
    if load_backup_metadata "$dir" 2>/dev/null && [[ ${bootloader:-} != refind ]]; then
        validate_backup_pre_leap16_r64 "$dir"
        return $?
    fi
    BACKUP_VALIDATION_REASON=''
    declare -F validate_backup_pre_leap16_r31 >/dev/null 2>&1 || { BACKUP_VALIDATION_REASON='structural backup validator unavailable'; return 1; }
    validate_backup_pre_leap16_r31 "$dir" || return 1
    load_backup_metadata "$dir" || { BACKUP_VALIDATION_REASON='metadata format is invalid'; return 1; }
    [[ ${format_version:-} == 4 ]] || { BACKUP_VALIDATION_REASON='rEFInd backup requires self-contained format v4'; return 1; }
    [[ ${backup_platform:-} == "$LEAP16_R31_BACKUP_PLATFORM" ]] || { BACKUP_VALIDATION_REASON='rEFInd backup is not from the Leap layer'; return 1; }
    [[ ${backup_schema:-} == "$LEAP16_R64_REFIND_BACKUP_SCHEMA" ]] || { BACKUP_VALIDATION_REASON='unsupported Leap rEFInd backup schema'; return 1; }
    [[ ${bootloader:-} == refind ]] || { BACKUP_VALIDATION_REASON='rEFInd validator received wrong backend'; return 1; }
    [[ ${payload_policy:-} == "$LEAP16_R64_REFIND_PAYLOAD_POLICY" ]] || { BACKUP_VALIDATION_REASON='unexpected rEFInd backup payload policy'; return 1; }
    [[ ${boot_efi_path,,} == ${LEAP16_R64_REFIND_EFI,,} ]] || { BACKUP_VALIDATION_REASON='backup does not identify canonical rEFInd BootCurrent path'; return 1; }
    leap16_r64_refind_backup_payload_valid "$dir" || return 1
    BACKUP_VALIDATION_REASON='valid'
    return 0
}

leap16_r64_copy_refind_immutable_tree_to_backup() {
    local dir=$1 src="${ESP_MOUNT%/}/EFI/refind" rel=${ESP_MOUNT#/} dst="$dir/files/${ESP_MOUNT#/}/EFI/refind" item base sm dm
    [[ -d $src && ! -L $src ]] || { BACKUP_CREATE_ERROR='current EFI/refind tree is unavailable'; return 1; }
    mkdir -p -- "$dst" || return 1
    while IFS= read -r -d '' item; do
        base=$(basename -- "$item"); [[ $base == vars ]] && continue
        [[ ! -L $item && ( -f $item || -d $item ) ]] || { BACKUP_CREATE_ERROR="unsafe object in current rEFInd tree: $item"; return 1; }
        cp -a -- "$item" "$dst/" 2>/dev/null || sudo -n cp -a -- "$item" "$dst/" || { BACKUP_CREATE_ERROR="could not capture $item"; return 1; }
    done < <(find "$src" -mindepth 1 -maxdepth 1 -print0 2>/dev/null | LC_ALL=C sort -z)
    sm=$(mktemp); dm=$(mktemp) || { rm -f -- "$sm"; return 1; }
    r35_refind_tree_manifest "$src" "$sm" protected || { rm -f -- "$sm" "$dm"; BACKUP_CREATE_ERROR='could not manifest current immutable rEFInd tree'; return 1; }
    r35_refind_tree_manifest "$dst" "$dm" user || { rm -f -- "$sm" "$dm"; BACKUP_CREATE_ERROR='could not manifest copied immutable rEFInd tree'; return 1; }
    LC_ALL=C sort -o "$sm" "$sm"; LC_ALL=C sort -o "$dm" "$dm"
    cmp -s -- "$sm" "$dm" || { rm -f -- "$sm" "$dm"; BACKUP_CREATE_ERROR='immutable rEFInd backup copy does not byte/shape-match source'; return 1; }
    rm -f -- "$sm" "$dm"
}

if declare -F create_current_bootloader_backup >/dev/null 2>&1; then
    eval "$(declare -f create_current_bootloader_backup | sed '1s/create_current_bootloader_backup/create_current_bootloader_backup_pre_leap16_r64/')"
fi
create_current_bootloader_backup() {
    detect_bootloader
    if [[ $BOOTLOADER != refind ]]; then create_current_bootloader_backup_pre_leap16_r64 "$@"; return $?; fi
    CREATED_BACKUP_DIR=''; BACKUP_CREATE_ERROR=''
    collect_kernels
    leap16_require_sudo_session || { BACKUP_CREATE_ERROR='sudo authorization is required'; return 2; }
    run_validation preflight >/dev/null || { BACKUP_CREATE_ERROR='preflight validation failed'; return 2; }
    leap16_r64_refind_source_gate || { BACKUP_CREATE_ERROR='current rEFInd source failed deep/final topology validation'; return 2; }
    local ts dir rel efi_src
    ts=$(date '+%Y%m%d-%H%M%S'); dir="$BACKUP_ROOT/refind-$ts"
    mkdir -p -- "$dir/files" || { BACKUP_CREATE_ERROR="could not create backup directory: $dir"; return 3; }
    chmod 700 -- "$BACKUP_ROOT" "$dir" 2>/dev/null || true
    if ! (
        set -e
        leap16_r31_emit_metadata_kv format_version 4
        leap16_r31_emit_metadata_kv backup_platform "$LEAP16_R31_BACKUP_PLATFORM"
        leap16_r31_emit_metadata_kv backup_schema "$LEAP16_R64_REFIND_BACKUP_SCHEMA"
        leap16_r31_emit_metadata_kv switcher_release "${SWITCHER_RELEASE:-leap16-r64}"
        leap16_r31_emit_metadata_kv bootloader refind
        leap16_r31_emit_metadata_kv payload_policy "$LEAP16_R64_REFIND_PAYLOAD_POLICY"
        leap16_r31_emit_metadata_kv created_epoch "$(date +%s)"
        leap16_r31_emit_metadata_kv created_iso "$(date --iso-8601=seconds 2>/dev/null || date)"
        leap16_r31_emit_metadata_kv hostname "$(hostname)"
        leap16_r31_emit_metadata_kv machine_id "$(cat /etc/machine-id 2>/dev/null || true)"
        leap16_r31_emit_metadata_kv esp_source "$ESP_SOURCE"
        leap16_r31_emit_metadata_kv esp_mount "$ESP_MOUNT"
        leap16_r31_emit_metadata_kv esp_uuid "$ESP_UUID"
        leap16_r31_emit_metadata_kv root_source "$ROOT_SOURCE"
        leap16_r31_emit_metadata_kv root_uuid "$ROOT_UUID"
        leap16_r31_emit_metadata_kv boot_current "$BOOT_CURRENT"
        leap16_r31_emit_metadata_kv boot_label "$BOOT_LABEL"
        leap16_r31_emit_metadata_kv boot_efi_path "$BOOT_EFI_PATH"
    ) >"$dir/metadata.conf"; then rm -rf -- "$dir"; BACKUP_CREATE_ERROR='could not write rEFInd metadata'; return 3; fi
    efibootmgr -v >"$dir/efibootmgr-v.txt" 2>&1 || true
    findmnt --fstab >"$dir/fstab-parsed.txt" 2>&1 || true
    cp -a -- /etc/fstab "$dir/fstab.reference" 2>/dev/null || true
    rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | LC_ALL=C sort >"$dir/package-state.txt" || true
    printf '%s\n' "${KERNEL_VERSIONS[@]}" >"$dir/kernel-versions.txt"
    printf '%s\n' "${ESP_MOUNT%/}/EFI/refind (immutable; vars excluded)" /boot/refind_linux.conf >"$dir/owned-paths.txt"
    leap16_r64_copy_refind_immutable_tree_to_backup "$dir" || { rm -rf -- "$dir"; return 3; }
    copy_path_into_backup /boot/refind_linux.conf "$dir" || { rm -rf -- "$dir"; return 3; }
    printf 'EFI/refind/vars\tmutable runtime state intentionally excluded (PreviousBoot)\n' >"$dir/refind-mutable-exclusions.txt"
    rel=${BOOT_EFI_PATH//\\//}; rel=${rel#/}; efi_src="$ESP_MOUNT/$rel"
    printf '%s\n' "$efi_src" >"$dir/bootcurrent-efi-source.txt"
    create_manifest_hashes "$dir" || { rm -rf -- "$dir"; BACKUP_CREATE_ERROR='could not create integrity manifest'; return 3; }
    validate_backup "$dir" || { BACKUP_CREATE_ERROR="new rEFInd backup failed self-validation: $BACKUP_VALIDATION_REASON"; rm -rf -- "$dir"; return 3; }
    CREATED_BACKUP_DIR=$dir
}

if declare -F create_current_bootloader_backup_interactive >/dev/null 2>&1; then
    eval "$(declare -f create_current_bootloader_backup_interactive | sed '1s/create_current_bootloader_backup_interactive/create_current_bootloader_backup_interactive_pre_leap16_r64/')"
fi
create_current_bootloader_backup_interactive() {
    detect_bootloader
    if [[ $BOOTLOADER != refind ]]; then create_current_bootloader_backup_interactive_pre_leap16_r64 "$@"; return $?; fi
    local ans rc
    printf '\nCurrent bootloader: rEFInd\nBackup directory:   %s\n\n' "$BACKUP_ROOT"
    read -r -p 'Back up the currently booted rEFInd setup? [y/n]: ' ans
    case "$ans" in
        y|Y|yes|YES) create_current_bootloader_backup; rc=$?; if ((rc==0)); then printf '\nBackup created: %s\n' "$CREATED_BACKUP_DIR"; validate_backup_compatibility "$CREATED_BACKUP_DIR" && printf 'Backup validation: VALID, COMPATIBLE\n' || printf 'Backup validation: FAILED (%s)\n' "$BACKUP_COMPATIBILITY_REASON"; else printf '\nBackup failed safely: %s\n' "${BACKUP_CREATE_ERROR:-unknown error}"; fi; return "$rc" ;;
        *) printf 'Backup cancelled.\n'; return 0 ;;
    esac
}

# ---------------------------------------------------------------------------
# Restore payload validators and write-boundary substitution.
# ---------------------------------------------------------------------------

leap16_r64_restore_refind_identity_preflight() {
    local dir=$1 reference
    validate_backup_compatibility "$dir" || { fail "Backup is not compatible: $BACKUP_COMPATIBILITY_REASON"; return 1; }
    load_backup_metadata "$dir" || return 1
    [[ $bootloader == refind && $backup_schema == "$LEAP16_R64_REFIND_BACKUP_SCHEMA" ]] || { fail 'Selected backup is not an r64 Leap rEFInd backup'; return 1; }
    detect_bootloader; [[ $BOOTLOADER != refind ]] || { fail 'Same-backend rEFInd restore is not exposed as a cross-loader transaction'; return 1; }
    leap16_r64_refind_edge "$BOOTLOADER" refind || return 1
    leap16_r64_preflight refind || return 1
    leap16_r31_backup_kernel_set_matches "$dir" || { fail 'Installed kernel set does not exactly match the selected rEFInd backup'; return 1; }
    reference=$(cat /proc/cmdline 2>/dev/null || true)
    BACKUP_VALIDATION_REASON=''; leap16_r64_refind_backup_payload_valid "$dir" "$reference" || { fail "$BACKUP_VALIDATION_REASON"; return 1; }
    ok 'Validated self-contained immutable rEFInd backup against the current source/kernel/root topology'
}

leap16_r64_restore_refind_payload_at_write_boundary() {
    local dir=$1 reference=$2 backup_root dst linux_src
    # Revalidate bytes and runtime policy immediately before replacing installer output.
    validate_backup_compatibility "$dir" || { fail "Write-boundary rEFInd backup compatibility failed: $BACKUP_COMPATIBILITY_REASON"; return 1; }
    load_backup_metadata "$dir" || return 1
    [[ $bootloader == refind && $backup_schema == "$LEAP16_R64_REFIND_BACKUP_SCHEMA" ]] || return 1
    leap16_r31_backup_kernel_set_matches "$dir" || { fail 'Kernel set changed before rEFInd restore write boundary'; return 1; }
    BACKUP_VALIDATION_REASON=''; leap16_r64_refind_backup_payload_valid "$dir" "$reference" || { fail "$BACKUP_VALIDATION_REASON"; return 1; }
    backup_root=$(leap16_r64_refind_backup_root "$dir") || return 1
    dst="${ESP_MOUNT%/}/EFI/refind"; linux_src="$dir/files/boot/refind_linux.conf"
    r35_restore_refind_immutable_tree "$backup_root" "$dst" || return 1
    sudo install -o root -g root -m 0644 -- "$linux_src" /boot/refind_linux.conf || return 1
    [[ ! -e $dst/vars && ! -L $dst/vars ]] || { fail 'Mutable rEFInd vars unexpectedly survived immutable restore'; return 1; }
    ok 'Restored exact validated rEFInd immutable payload; fresh PreviousBoot proof remains unearned'
}

leap16_r64_target_backup_preflight_from_refind() {
    local dir=$1 target=$2 current_cmd
    validate_backup_compatibility "$dir" || { fail "Backup is not compatible: $BACKUP_COMPATIBILITY_REASON"; return 1; }
    load_backup_metadata "$dir" || return 1
    [[ $bootloader == "$target" ]] || { fail "Selected backup is not a $(bootloader_display_name "$target") backup"; return 1; }
    detect_bootloader; [[ $BOOTLOADER == refind ]] || { fail 'This restore executor requires finalized rEFInd as source'; return 1; }
    leap16_r64_preflight "$target" || return 1
    leap16_r31_backup_kernel_set_matches "$dir" || { fail 'Installed kernel set differs from selected backup'; return 1; }
    case "$target" in
        grub)
            [[ $backup_schema == "$LEAP16_R31_BACKUP_SCHEMA" && $payload_policy == opensuse-bootloader-owned-paths ]] || { fail 'Unexpected GRUB backup schema/policy'; return 1; }
            [[ -f $dir/files/etc/default/grub && ! -L $dir/files/etc/default/grub ]] || { fail 'GRUB backup policy is missing'; return 1; }
            [[ -f $dir/files/boot/grub2/grub.cfg && ! -L $dir/files/boot/grub2/grub.cfg ]] || { fail 'GRUB backup grub.cfg is missing'; return 1; }
            have grub2-script-check && grub2-script-check "$dir/files/boot/grub2/grub.cfg" >/dev/null 2>&1 || { fail 'Backed-up GRUB configuration failed grub2-script-check'; return 1; }
            ;;
        limine)
            [[ $backup_schema == "$LEAP16_R31_BACKUP_SCHEMA" && $payload_policy == config-efi-splash-plus-staged-payload ]] || { fail 'Unexpected Limine backup schema/policy'; return 1; }
            leap16_r61_validate_limine_backup_payload_for_systemd_source "$dir" || return 1
            ;;
        systemd-boot)
            [[ $backup_schema == "$LEAP16_R44_SYSTEMD_BACKUP_SCHEMA" && $payload_policy == "$LEAP16_R44_SYSTEMD_PAYLOAD_POLICY" ]] || { fail 'Unexpected systemd-boot backup schema/policy'; return 1; }
            current_cmd=$(leap16_r32_portable_cmdline "$(cat /proc/cmdline 2>/dev/null || true)")
            BACKUP_VALIDATION_REASON=''; leap16_r44_systemd_backup_payload_valid "$dir" "$current_cmd" || { fail "$BACKUP_VALIDATION_REASON"; return 1; }
            ;;
    esac
    ok "Validated restored $(bootloader_display_name "$target") payload against finalized rEFInd source"
}

leap16_r64_restore_refind_backup() {
    local dir=$1 ans rc=0
    leap16_r64_restore_refind_identity_preflight "$dir" || return 1
    printf '\nLeap-native rEFInd backup restore transaction plan:\n  - restore immutable validated EFI/refind + /boot/refind_linux.conf; never restore vars/PreviousBoot;\n  - keep the current source authoritative until a real canonical rEFInd direct-kernel PreviousBoot proof;\n  - only then retire exact bounded source state; rEFInd does not claim EFI/BOOT.\n\n'
    offer_operation_backup || return 1
    read -r -p 'Type RESTORE to stage this validated rEFInd backup, or anything else to cancel: ' ans
    [[ $ans == RESTORE ]] || { printf 'Restore cancelled.\n'; return 0; }
    leap16_r64_restore_refind_identity_preflight "$dir" || { fail 'Write-boundary rEFInd restore preflight failed'; return 1; }
    LEAP16_R64_RESTORE_DIR=$dir; OPERATION_BACKUP=$dir; LEAP16_R64_ACTIVE_TARGET=refind
    r26_execute_adapter_switch refind || rc=$?
    LEAP16_R64_ACTIVE_TARGET=''; LEAP16_R64_RESTORE_DIR=''
    leap16_r44_diag_bind_pending
    return "$rc"
}

leap16_r64_restore_from_refind_inner() {
    local dir=$1 target=$2 ans rc=0
    leap16_r64_target_backup_preflight_from_refind "$dir" "$target" || return 1
    printf '\nLeap-native rEFInd -> restored %s transaction plan:\n' "$(bootloader_display_name "$target")"
    leap16_r64_plan refind "$target"
    offer_operation_backup || return 1
    read -r -p "Type RESTORE to stage this validated $(bootloader_display_name "$target") backup, or anything else to cancel: " ans
    [[ $ans == RESTORE ]] || { printf 'Restore cancelled.\n'; return 0; }
    leap16_r64_target_backup_preflight_from_refind "$dir" "$target" || { fail 'Write-boundary target backup revalidation failed'; return 1; }
    OPERATION_BACKUP=$dir; LEAP16_R64_ACTIVE_TARGET=$target
    case "$target" in
        grub|limine) LEAP16_R31_RESTORE_DIR=$dir ;;
        systemd-boot) LEAP16_R44_RESTORE_DIR=$dir ;;
        *) return 2 ;;
    esac
    r26_execute_adapter_switch "$target" || rc=$?
    LEAP16_R31_RESTORE_DIR=''; LEAP16_R44_RESTORE_DIR=''; LEAP16_R64_ACTIVE_TARGET=''
    leap16_r44_diag_bind_pending
    return "$rc"
}
leap16_r64_restore_grub_backup_from_refind() { leap16_r64_restore_from_refind_inner "$1" grub; }
leap16_r64_restore_limine_backup_from_refind() { leap16_r64_restore_from_refind_inner "$1" limine; }
leap16_r64_restore_systemd_backup_from_refind() { leap16_r64_restore_from_refind_inner "$1" systemd-boot; }


# ---------------------------------------------------------------------------
# rEFInd -> Limine two-proof transaction.
# Unlike rEFInd itself, finalized Limine owns a genuine EFI/BOOT fallback; the
# source is therefore retained through canonical proof #1 and fallback proof #2.
# ---------------------------------------------------------------------------

leap16_r64_limine_preconf_path() { local d; d=$(leap16_r64_snapshot_dir) || return 1; printf '%s/r64-limine-primary.conf\n' "$d"; }
leap16_r64_limine_primary_manifest_path() { local d; d=$(leap16_r64_snapshot_dir) || return 1; printf '%s/r64-limine-primary-manifest.tsv\n' "$d"; }

# Tighten only the rEFInd->Limine preflight: at most one pre-existing exact
# fallback alias may exist. Multiple aliases make adoption/rollback ambiguous.
eval "$(declare -f leap16_r64_preflight | sed '1s/leap16_r64_preflight/leap16_r64_preflight_pre_completion/')"
leap16_r64_preflight() {
    local target=$1 rc ids
    leap16_r64_preflight_pre_completion "$@" || return $?
    if [[ ${BOOTLOADER:-}:$target == refind:limine ]]; then
        ids=$(r21_fallback_ids_now | sed '/^$/d' | wc -l)
        ((ids <= 1)) || { fail "rEFInd -> Limine requires at most one exact same-ESP EFI/BOOT alias before staging; found $ids"; return 1; }
    fi
    return 0
}

leap16_r64_verify_refind_source_passive() {
    local source=${PENDING_OLD_BOOT_ID^^} hash ids
    boot_id_exists "$source" || { fail "rEFInd source Boot$source disappeared"; return 1; }
    nvram_id_matches_path "$source" "$LEAP16_R64_REFIND_EFI" || { fail 'rEFInd source path changed'; return 1; }
    leap16_nvram_entry_matches_current_esp "$source" || { fail 'rEFInd source ESP binding changed'; return 1; }
    hash=$(r21_hash_privileged "$PENDING_SOURCE_EFI_RESOLVED")
    [[ $hash == "$PENDING_SOURCE_EFI_HASH" ]] || { fail 'rEFInd source EFI bytes changed'; return 1; }
    r26_verify_owned_manifest "$PENDING_SOURCE_MANIFEST" || return 1
    ids=$(leap16_r48_ids_for_current_esp_path "$LEAP16_R64_REFIND_EFI" | paste -sd, -)
    [[ -n $ids && $ids != *,* && ${ids^^} == "$source" ]] || { fail "Canonical rEFInd recovery alias set changed (${ids:-none})"; return 1; }
    validate_refind_boot_chain recovery || return 1
    ok "Canonical rEFInd Boot$source remains exact passive recovery"
}

leap16_r64_validate_limine_primary_runtime() {
    local target=${PENDING_TARGET_BOOT_ID^^} order first diag
    validate_pending_compatibility || { fail "Pending transaction is incompatible: $PENDING_REASON"; return 1; }
    leap16_r64_pending_refind_limine || return 1
    leap16_r64_limine_fallback_staged && { fail 'Primary validator is not valid after fallback staging'; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == "$target" ]] || { fail "Primary proof requires canonical Limine Boot$target"; return 1; }
    leap16_require_sudo_session || return 1
    run_validation preflight || return 1
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext was not consumed/cleared by firmware'; return 1; }
    order=$(leap16_current_boot_order); first=${order%%,*}
    [[ ${first^^} == ${PENDING_OLD_BOOT_ID^^} || ${first^^} == "$target" ]] || { fail "Persistent BootOrder drifted before primary proof ($order)"; return 1; }
    pending_validate_running_kernel || return 1
    pending_validate_runtime_cmdline_against_source || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1
    leap16_r64_verify_refind_source_passive || return 1
    if [[ $PENDING_PHASE == boot-armed ]]; then pending_set_phase runtime-validated || return 1; PENDING_PHASE=runtime-validated; fi
    [[ $PENDING_PHASE == runtime-validated ]] || return 1
    diag=$(pending_capture_runtime_diagnostics runtime-pass-limine-from-refind | tail -n1 || true)
    [[ -n $diag ]] && printf 'Runtime diagnostic snapshot: %s\n' "$diag"
    printf '\nPRIMARY-RUNTIME-VALIDATED rEFInd -> Limine. rEFInd remains exact recovery until EFI/BOOT Limine proof succeeds.\n'
}

# Preserve active runtime validator for all other directions.
eval "$(declare -f validate_pending_target_runtime | sed '1s/validate_pending_target_runtime/validate_pending_target_runtime_pre_leap16_r64_completion/')"
validate_pending_target_runtime() {
    if leap16_r64_pending_refind_limine; then leap16_r64_validate_limine_primary_runtime; else validate_pending_target_runtime_pre_leap16_r64_completion "$@"; fi
}

leap16_r64_rewrite_limine_recovery_to_refind() {
    local conf="${PENDING_ESP_MOUNT%/}/limine.conf" pre out line a b c d found=0 expected current new_hash
    pre=$(leap16_r64_limine_preconf_path) || return 1
    expected=$(leap16_r64_meta_value limine_primary_conf_hash); current=$(r21_hash_privileged "$conf")
    [[ $expected =~ ^[0-9A-Fa-f]{64}$ && $current == "$expected" ]] || { fail 'Primary limine.conf changed before fallback transfer'; return 1; }
    leap16_r64_refind_read "$conf" >"$pre" || return 1
    [[ $(sha256sum -- "$pre" | awk '{print $1}') == "$expected" ]] || return 1
    chmod 600 -- "$pre" 2>/dev/null || true
    out=$(mktemp) || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == '/EFI fallback' ]]; then
            IFS= read -r a || { rm -f -- "$out"; return 1; }; IFS= read -r b || { rm -f -- "$out"; return 1; }
            IFS= read -r c || { rm -f -- "$out"; return 1; }; IFS= read -r d || { rm -f -- "$out"; return 1; }
            [[ $c == 'protocol: efi' && $d == 'path: boot():/EFI/BOOT/BOOTX64.EFI' ]] || { rm -f -- "$out"; fail 'Generated Limine fallback block changed before transfer'; return 1; }
            printf '/openSUSE rEFInd recovery\n### Temporary direct recovery path retained until Limine fallback proof completes\ncomment: Native openSUSE rEFInd recovery path\nprotocol: efi\npath: boot():/EFI/refind/refind_x64.efi\n' >>"$out"
            found=$((found+1))
        else printf '%s\n' "$line" >>"$out"; fi
    done <"$pre"
    [[ $found == 1 ]] || { rm -f -- "$out"; fail "Expected exactly one Limine EFI fallback block, found $found"; return 1; }
    new_hash=$(sha256sum -- "$out" | awk '{print $1}')
    r21_atomic_replace "$out" "$conf" "$new_hash" || { rm -f -- "$out"; return 1; }
    rm -f -- "$out"; printf '%s\n' "$new_hash"
}

leap16_r64_remove_limine_refind_recovery_block() {
    local conf="${PENDING_ESP_MOUNT%/}/limine.conf" expected out line a b c d found=0 new_hash
    expected=$(leap16_r64_meta_value limine_transferred_conf_hash)
    [[ $expected =~ ^[0-9A-Fa-f]{64}$ && $(r21_hash_privileged "$conf") == "$expected" ]] || { fail 'Transferred limine.conf changed before rEFInd retirement'; return 1; }
    out=$(mktemp) || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == '/openSUSE rEFInd recovery' ]]; then
            IFS= read -r a || { rm -f -- "$out"; return 1; }; IFS= read -r b || { rm -f -- "$out"; return 1; }
            IFS= read -r c || { rm -f -- "$out"; return 1; }; IFS= read -r d || { rm -f -- "$out"; return 1; }
            [[ $c == 'protocol: efi' && $d == 'path: boot():/EFI/refind/refind_x64.efi' ]] || { rm -f -- "$out"; fail 'Temporary rEFInd recovery block changed'; return 1; }
            found=$((found+1))
        else printf '%s\n' "$line" >>"$out"; fi
    done < <(leap16_r64_refind_read "$conf")
    [[ $found == 1 ]] || { rm -f -- "$out"; fail "Expected exactly one temporary rEFInd recovery block, found $found"; return 1; }
    new_hash=$(sha256sum -- "$out" | awk '{print $1}')
    r21_atomic_replace "$out" "$conf" "$new_hash" || { rm -f -- "$out"; return 1; }
    rm -f -- "$out"; printf '%s\n' "$new_hash"
}

leap16_r64_create_or_adopt_limine_fallback_alias() {
    local id; local -a ids=()
    mapfile -t ids < <(r21_fallback_ids_now | LC_ALL=C sort -u)
    ((${#ids[@]} <= 1)) || { fail "Fallback alias set is ambiguous (${#ids[@]})"; return 1; }
    if ((${#ids[@]} == 1)); then
        id=${ids[0]^^}; leap16_nvram_entry_matches_current_esp "$id" && nvram_id_matches_path "$id" "$LEAP16_R21_FALLBACK_EFI_PATH" || return 1
        printf '%s\n' "$id"; return 0
    fi
    r28_create_alias_create_only 'UEFI OS' "$LEAP16_R21_FALLBACK_EFI_PATH" || return 1
    id=${R28_CREATED_ALIAS_ID^^}; [[ $id =~ ^[0-9A-F]{4}$ ]] || return 1
    printf '%s\n' "$id"
}

leap16_r64_refresh_limine_manifest() { leap16_r51_refresh_target_manifest; }

leap16_r64_restore_pre_limine_fallback_state() {
    local fallback next pre primary_hash pm
    fallback=$(leap16_r64_limine_fallback_id 2>/dev/null || true); next=$(pending_bootnext_id 2>/dev/null || true)
    [[ -n $fallback && ${next^^} == "$fallback" ]] && sudo efibootmgr -N >/dev/null 2>&1 || true
    # Remove only fallback aliases absent from the pre-stage firmware baseline.
    local id baseline; baseline=$(leap16_r64_baseline_path)
    while IFS= read -r id; do
        id=${id^^}; [[ $id =~ ^[0-9A-F]{4}$ ]] || continue
        if ! grep -Eq "^Boot${id}\\*?[[:space:]]" "$baseline" 2>/dev/null; then sudo efibootmgr -b "$id" -B >/dev/null 2>&1 || true; fi
    done < <(r21_fallback_ids_now)
    if [[ ${PENDING_OLD_FALLBACK_EXISTED:-0} == 1 ]]; then
        [[ -f $PENDING_OLD_FALLBACK_SNAPSHOT ]] || return 1
        r21_atomic_replace "$PENDING_OLD_FALLBACK_SNAPSHOT" "$PENDING_OLD_FALLBACK_PATH" "$PENDING_OLD_FALLBACK_HASH" || return 1
    else sudo rm -f -- "$PENDING_OLD_FALLBACK_PATH" 2>/dev/null || true; fi
    pre=$(leap16_r64_limine_preconf_path); primary_hash=$(leap16_r64_meta_value limine_primary_conf_hash)
    [[ -f $pre && $primary_hash =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
    r21_atomic_replace "$pre" "${PENDING_ESP_MOUNT%/}/limine.conf" "$primary_hash" || return 1
    pm=$(leap16_r64_limine_primary_manifest_path)
    [[ -s $pm ]] && cp -f -- "$pm" "$PENDING_TARGET_MANIFEST" || leap16_r64_refresh_limine_manifest || return 1
    r21_order_primary_then_source_recovery || return 1
    leap16_r64_write_meta refind:limine '' "$primary_hash" || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    leap16_r64_verify_refind_source_passive || return 1
    ok 'Restored primary-Limine + exact rEFInd recovery topology; second proof remains unearned'
}

leap16_r64_verify_transferred_limine() {
    local fallback hash ch order
    fallback=$(leap16_r64_limine_fallback_id) || return 1
    hash=$(r21_hash_privileged "$PENDING_OLD_FALLBACK_PATH")
    [[ $hash == "$PENDING_TARGET_EFI_HASH" && $hash == $(leap16_r64_meta_value limine_fallback_hash) ]] || { fail 'EFI/BOOT is not byte-identical to canonical Limine'; return 1; }
    ch=$(leap16_r64_meta_value limine_transferred_conf_hash)
    [[ $(r21_hash_privileged "${PENDING_ESP_MOUNT%/}/limine.conf") == "$ch" ]] || { fail 'Transferred limine.conf changed'; return 1; }
    boot_id_exists "$fallback" && nvram_id_matches_path "$fallback" "$LEAP16_R21_FALLBACK_EFI_PATH" && leap16_nvram_entry_matches_current_esp "$fallback" || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_limine_boot_chain migration || return 1
    leap16_r64_verify_refind_source_passive || return 1
    order=$(leap16_current_boot_order); [[ $order == "${PENDING_TARGET_BOOT_ID^^},$fallback"* ]] || { fail "Primary/fallback topology is wrong ($order)"; return 1; }
    ok 'Canonical Limine + byte-identical fallback + passive rEFInd recovery remain exact'
}

leap16_r64_promote_and_stage_limine_fallback() {
    local source=${PENDING_OLD_BOOT_ID^^} target=${PENDING_TARGET_BOOT_ID^^} order conf_hash fallback_hash fallback_id before next pm
    validate_pending_compatibility || return 1
    [[ $PENDING_PHASE == runtime-validated ]] || return 1
    detect_bootloader; [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == "$target" ]] || return 1
    leap16_r64_validate_limine_primary_runtime || return 1
    order=$(leap16_current_boot_order); [[ ${order%%,*} == "$source" ]] && adapter_target_promote "$target" "$source" || true
    [[ $(leap16_current_boot_order | cut -d, -f1,2) == "$target,$source" ]] || { fail 'Canonical Limine/rEFInd promoted recovery topology is not exact'; return 1; }
    pm=$(leap16_r64_limine_primary_manifest_path); cp -f -- "$PENDING_TARGET_MANIFEST" "$pm" || return 1; chmod 600 -- "$pm" 2>/dev/null || true
    conf_hash=$(leap16_r64_rewrite_limine_recovery_to_refind) || return 1
    if ! r21_atomic_replace "$PENDING_TARGET_EFI_RESOLVED" "$PENDING_OLD_FALLBACK_PATH" "$PENDING_TARGET_EFI_HASH"; then leap16_r64_restore_pre_limine_fallback_state || true; return 1; fi
    fallback_hash=$(r21_hash_privileged "$PENDING_OLD_FALLBACK_PATH"); [[ $fallback_hash == "$PENDING_TARGET_EFI_HASH" ]] || { leap16_r64_restore_pre_limine_fallback_state || true; return 1; }
    fallback_id=$(leap16_r64_create_or_adopt_limine_fallback_alias) || { leap16_r64_restore_pre_limine_fallback_state || true; return 1; }; fallback_id=${fallback_id^^}
    leap16_r64_refresh_limine_manifest || { leap16_r64_restore_pre_limine_fallback_state || true; return 1; }
    leap16_r64_update_limine_fallback_meta "$fallback_id" "$fallback_hash" "$conf_hash" || { leap16_r64_restore_pre_limine_fallback_state || true; return 1; }
    order=$(r21_order_primary_fallback_then_existing "$fallback_id") || { leap16_r64_restore_pre_limine_fallback_state || true; return 1; }
    leap16_r64_verify_transferred_limine || { leap16_r64_restore_pre_limine_fallback_state || true; return 1; }
    before=$(leap16_current_boot_order); sudo efibootmgr -n "$fallback_id" >/dev/null || { leap16_r64_restore_pre_limine_fallback_state || true; return 1; }
    next=$(pending_bootnext_id); [[ ${next^^} == "$fallback_id" && $(leap16_current_boot_order) == "$before" ]] || { leap16_r64_restore_pre_limine_fallback_state || true; fail 'Fallback BootNext arming failed or changed BootOrder'; return 1; }
    pending_capture_runtime_diagnostics fallback-armed-limine-from-refind >/dev/null 2>&1 || true
    printf '\nPRIMARY PROOF COMPLETE. Limine EFI/BOOT Boot%s is armed for proof #2; rEFInd Boot%s remains intact.\n' "$fallback_id" "$source"
}

leap16_r64_validate_limine_fallback_runtime() {
    local fallback next order
    validate_pending_compatibility || return 1; leap16_r64_limine_fallback_staged || return 1
    fallback=$(leap16_r64_limine_fallback_id) || return 1
    detect_bootloader; [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == "$fallback" ]] || { fail "Fallback proof requires BootCurrent=Boot$fallback"; return 1; }
    nvram_id_matches_path "$fallback" "$LEAP16_R21_FALLBACK_EFI_PATH" && leap16_nvram_entry_matches_current_esp "$fallback" || return 1
    run_validation preflight || return 1
    next=$(pending_bootnext_id); if [[ -n $next && ${next^^} == "$fallback" ]]; then sudo efibootmgr -N >/dev/null || return 1; elif [[ -n $next ]]; then fail "Unrelated BootNext=Boot$next"; return 1; fi
    pending_validate_running_kernel || return 1; pending_validate_runtime_cmdline_against_source || return 1
    [[ $(r21_hash_privileged "$PENDING_OLD_FALLBACK_PATH") == "$PENDING_TARGET_EFI_HASH" ]] || return 1
    leap16_r64_verify_transferred_limine || return 1
    order=$(leap16_current_boot_order); [[ $order == "${PENDING_TARGET_BOOT_ID^^},$fallback"* ]] || return 1
    pending_capture_runtime_diagnostics fallback-runtime-pass-limine-from-refind >/dev/null 2>&1 || true
    printf '\nFALLBACK-RUNTIME-VALIDATED. rEFInd -> Limine now has two independent hardware proofs.\n'
}

leap16_r64_extra_fallback_ids() {
    local keep baseline id
    keep=$(leap16_r64_limine_fallback_id) || return 1; baseline=$(leap16_r64_baseline_path) || return 1
    while IFS= read -r id; do id=${id^^}; [[ $id =~ ^[0-9A-F]{4}$ && $id != "$keep" ]] || continue; leap16_nvram_entry_matches_current_esp "$id" || continue; nvram_id_matches_path "$id" "$LEAP16_R21_FALLBACK_EFI_PATH" || continue; grep -Eq "^Boot${id}\\*?[[:space:]]" "$baseline" && { fail "A second baseline fallback alias Boot$id is not transaction-owned" >&2; return 1; }; printf '%s\n' "$id"; done < <(r21_fallback_ids_now)
}

leap16_r64_final_limine_order() {
    local target=${PENDING_TARGET_BOOT_ID^^} source=${PENDING_OLD_BOOT_ID^^} fallback order id joined x owned; local -a cur=() out=() extras=()
    fallback=$(leap16_r64_limine_fallback_id) || return 1; mapfile -t extras < <(leap16_r64_extra_fallback_ids) || return 1; out=("$target" "$fallback")
    order=$(leap16_current_boot_order); IFS=',' read -ra cur <<<"$order"
    for id in "${cur[@]}"; do id=${id^^}; [[ -n $id && $id != "$target" && $id != "$fallback" && $id != "$source" ]] || continue; owned=0; for x in "${extras[@]}"; do [[ $id == "$x" ]] && owned=1; done; ((owned)) || { boot_id_exists "$id" && out+=("$id"); }; done
    joined=$(IFS=,; printf '%s' "${out[*]}"); sudo efibootmgr -o "$joined" >/dev/null || return 1
    [[ $(leap16_current_boot_order) == "$target,$fallback"* ]] || return 1
}

leap16_r64_retire_refind_after_limine_fallback_proof() {
    local source=${PENDING_OLD_BOOT_ID^^} target=${PENDING_TARGET_BOOT_ID^^} fallback final_hash id detail; local -a extras=()
    leap16_r64_validate_limine_fallback_runtime || return 1
    fallback=$(leap16_r64_limine_fallback_id); mapfile -t extras < <(leap16_r64_extra_fallback_ids) || return 1
    leap16_r64_final_limine_order || return 1
    for id in "${extras[@]}"; do boot_id_exists "$id" && sudo efibootmgr -b "$id" -B >/dev/null || true; done
    leap16_r64_delete_refind_source || return 1
    leap16_r51_set_final_limine_policy || return 1
    final_hash=$(leap16_r64_remove_limine_refind_recovery_block) || return 1
    leap16_r64_refresh_limine_manifest || return 1
    detect_bootloader
    [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == "$fallback" ]] || return 1
    [[ $(leap16_current_boot_order) == "$target,$fallback"* ]] || return 1
    [[ -z $(leap16_r48_ids_for_current_esp_path "$LEAP16_R64_REFIND_EFI" | awk 'NF') ]] || { fail 'Canonical rEFInd alias remains after retirement'; return 1; }
    [[ $(r21_hash_privileged "$PENDING_OLD_FALLBACK_PATH") == "$PENDING_TARGET_EFI_HASH" ]] || return 1
    validate_limine_boot_chain migration || return 1
    [[ $(r21_hash_privileged "${PENDING_ESP_MOUNT%/}/limine.conf") == "$final_hash" ]] || return 1
    pending_capture_runtime_diagnostics finalized-limine-from-refind >/dev/null 2>&1 || true
    if [[ -n ${PENDING_BACKUP_PATH:-} ]]; then detail="rEFInd -> restored Limine backup completed with two independent runtime proofs. Primary Limine Boot$target is first; genuine Limine fallback Boot$fallback second; exact rEFInd source retired. Backup: $PENDING_BACKUP_PATH"; else detail="rEFInd -> Limine completed with two independent runtime proofs. Primary Limine Boot$target is first; genuine Limine fallback Boot$fallback second; exact rEFInd source retired."; fi
    r35_write_local_transaction_result success "$detail" || true
    remove_pending_transaction_snapshot || true; rm -f -- "$PENDING_STATE_FILE"
    printf '\nFINALIZED rEFInd -> Limine after canonical + EFI/BOOT proofs.\n'
}

# Finalizer dispatch for all six rEFInd directions.
eval "$(declare -f r26_finalize_adapter_transaction | sed '1s/r26_finalize_adapter_transaction/r26_finalize_adapter_transaction_pre_leap16_r64_completion/')"
r26_finalize_adapter_transaction() {
    if ! leap16_r64_pending_edge; then r26_finalize_adapter_transaction_pre_leap16_r64_completion "$@"; return $?; fi
    case "${PENDING_SOURCE}:${PENDING_TARGET}" in
        grub:refind|limine:refind|systemd-boot:refind) leap16_r64_finalize_to_refind ;;
        refind:systemd-boot) leap16_r64_finalize_refind_to_systemd ;;
        refind:grub) leap16_r64_finalize_refind_to_grub ;;
        refind:limine) if leap16_r64_limine_fallback_staged; then leap16_r64_retire_refind_after_limine_fallback_proof; else leap16_r64_promote_and_stage_limine_fallback; fi ;;
        *) return 2 ;;
    esac
}


# ---------------------------------------------------------------------------
# Post-audit ownership fixes.
# ---------------------------------------------------------------------------

# Include an ownership-proven generic fallback path in the bounded source alias
# set for every source that owns it. This prevents a stale UEFI OS alias from
# surviving after the corresponding fallback payload is retired.
leap16_r64_source_paths() {
    local source=$1
    case "$source" in
        grub)
            printf '%s\n' "$R28_GRUB_SHIM_PATH" "$R28_GRUB_DIRECT_PATH"
            [[ ${PENDING_SOURCE_FALLBACK_OWNED:-0} == 1 ]] && printf '%s\n' "$LEAP16_R21_FALLBACK_EFI_PATH"
            ;;
        limine) printf '%s\n' '\EFI\LIMINE\LIMINE_X64.EFI' "$LEAP16_R21_FALLBACK_EFI_PATH" ;;
        systemd-boot)
            printf '%s\n' "$LEAP16_R32_SDBOOT_EFI"
            [[ ${PENDING_SOURCE_FALLBACK_OWNED:-0} == 1 ]] && printf '%s\n' "$LEAP16_R21_FALLBACK_EFI_PATH"
            ;;
        refind) printf '%s\n' "$LEAP16_R64_REFIND_EFI" ;;
    esac
}

leap16_r64_transfer_systemd_fallback_exact() {
    local fallback="$PENDING_OLD_FALLBACK_PATH" hash id order joined; local -a cur=() out=()
    sudo mkdir -p -- "$(dirname -- "$fallback")" || return 1
    r21_atomic_replace "$PENDING_TARGET_EFI_RESOLVED" "$fallback" "$PENDING_TARGET_EFI_HASH" || return 1
    hash=$(r21_hash_privileged "$fallback"); [[ $hash == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'systemd-boot fallback transfer hash mismatch'; return 1; }
    # Finalized Leap systemd-boot intentionally has no explicit EFI/BOOT alias.
    order=$(leap16_current_boot_order); IFS=',' read -ra cur <<<"$order"
    for id in "${cur[@]}"; do
        id=${id^^}; [[ -n $id ]] || continue
        if leap16_nvram_entry_matches_current_esp "$id" && nvram_id_matches_path "$id" "$LEAP16_R21_FALLBACK_EFI_PATH"; then continue; fi
        boot_id_exists "$id" && out+=("$id")
    done
    ((${#out[@]} > 0)) || return 1
    joined=$(IFS=,; printf '%s' "${out[*]}"); sudo efibootmgr -o "$joined" >/dev/null || return 1
    while IFS= read -r id; do id=${id^^}; [[ $id =~ ^[0-9A-F]{4}$ ]] || continue; leap16_nvram_entry_matches_current_esp "$id" && nvram_id_matches_path "$id" "$LEAP16_R21_FALLBACK_EFI_PATH" || continue; sudo efibootmgr -b "$id" -B >/dev/null || return 1; done < <(r21_fallback_ids_now)
    [[ -z $(r21_fallback_ids_now | awk 'NF') ]] || { fail 'Explicit EFI/BOOT alias remains after systemd-boot fallback normalization'; return 1; }
    ok 'Transferred EFI/BOOT to byte-identical systemd-boot and normalized explicit generic-fallback aliases only after target runtime proof'
}

# Replace the earlier partial finalizer with a finalized-systemd topology that
# is acceptable as a later source for every proven systemd edge.
leap16_r64_finalize_refind_to_systemd() {
    local target=${PENDING_TARGET_BOOT_ID^^} detail
    validate_pending_compatibility || return 1
    [[ ${PENDING_SOURCE}:${PENDING_TARGET} == refind:systemd-boot && $PENDING_PHASE == runtime-validated ]] || return 1
    detect_bootloader; [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == "$target" ]] || { fail 'systemd-boot finalization requires exact runtime-proven target'; return 1; }
    [[ -z $(pending_bootnext_id) ]] || return 1
    run_validation preflight || return 1; pending_validate_running_kernel || return 1; pending_validate_runtime_cmdline_against_source || return 1
    verify_pending_candidate_ownership_unchanged || return 1; leap16_r34_validate_systemd_boot_chain runtime || return 1; leap16_r64_verify_refind_source_passive || return 1
    leap16_r34_target_first_keep_recovery || return 1
    leap16_r34_validate_systemd_boot_chain target || return 1; leap16_r64_verify_refind_source_passive || return 1
    leap16_r64_transfer_systemd_fallback_exact || return 1
    r26_verify_owned_manifest "$PENDING_SOURCE_MANIFEST" || return 1
    leap16_r64_remove_refind_from_order_keep "$target" || return 1
    leap16_r64_delete_refind_source || return 1
    leap16_r34_set_loader_policy_systemd || return 1
    detect_bootloader; [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == "$target" ]] || return 1
    leap16_r51_systemd_source_gate || return 1
    pending_capture_runtime_diagnostics finalized-systemd-boot-from-refind >/dev/null 2>&1 || true
    if [[ -n ${PENDING_BACKUP_PATH:-} ]]; then detail="rEFInd -> restored systemd-boot backup finalized after exact runtime proof. systemd-boot Boot$target is first, owns byte-identical EFI/BOOT, and exact rEFInd source state is retired. Backup: $PENDING_BACKUP_PATH"; else detail="rEFInd -> systemd-boot finalized after exact runtime proof. systemd-boot Boot$target is first, owns byte-identical EFI/BOOT, and exact rEFInd source state is retired."; fi
    r35_write_local_transaction_result success "$detail" || true
    remove_pending_transaction_snapshot || true; rm -f -- "$PENDING_STATE_FILE"
    printf '\nFINALIZED rEFInd -> systemd-boot successfully.\n'
}


# ---------------------------------------------------------------------------
# Root-owned automatic continuation for every rEFInd edge.
# ---------------------------------------------------------------------------

leap16_r64_sync_fallback_state_to_user() {
    local conf=$1 user_snapshot uid gid src base
    r22_user_shadow_matches_conf "$conf" || return 1
    user_snapshot=$(r22_conf_value "$conf" user_snapshot_dir); uid=$(r22_conf_value "$conf" user_uid); gid=$(r22_conf_value "$conf" user_gid)
    [[ -d $user_snapshot && $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ ]] || return 1
    for src in "$(leap16_r64_meta_path)" "$(leap16_r64_limine_preconf_path)" "$(leap16_r64_limine_primary_manifest_path)" "$PENDING_TARGET_MANIFEST"; do
        [[ -f $src ]] || continue; base=${src##*/}; cp -f -- "$src" "$user_snapshot/$base" || return 1; chown "$uid:$gid" -- "$user_snapshot/$base" 2>/dev/null || true; chmod 600 -- "$user_snapshot/$base" 2>/dev/null || true
    done
}

leap16_r64_result_detail() {
    local source=$1 target=$2 target_id=${3:-${PENDING_TARGET_BOOT_ID:-}} fallback=${4:-}
    local suffix=''
    [[ -n ${PENDING_BACKUP_PATH:-} ]] && suffix=" Restored backup: $PENDING_BACKUP_PATH"
    if [[ $source:$target == refind:limine ]]; then
        printf 'rEFInd -> %sLimine completed with two independent runtime proofs. Primary Limine Boot%s is first; genuine Limine fallback Boot%s is second and byte-identical; exact rEFInd source state was retired.%s\n' "$([[ -n ${PENDING_BACKUP_PATH:-} ]] && printf 'restored ' || true)" "$target_id" "$fallback" "$suffix"
    elif [[ $target == refind ]]; then
        printf '%s -> %srEFInd completed after canonical direct-kernel PreviousBoot runtime proof. rEFInd Boot%s is persistent first; bounded source NVRAM/files were retired; rEFInd does not claim EFI/BOOT.%s\n' "$(bootloader_display_name "$source")" "$([[ -n ${PENDING_BACKUP_PATH:-} ]] && printf 'restored ' || true)" "$target_id" "$suffix"
    else
        printf 'rEFInd -> %s%s completed after exact runtime proof and target-native finalization. Target Boot%s is persistent first; exact rEFInd source state was retired.%s\n' "$([[ -n ${PENDING_BACKUP_PATH:-} ]] && printf 'restored ' || true)" "$(bootloader_display_name "$target")" "$target_id" "$suffix"
    fi
}

leap16_r64_resume_root() {
    r22_root_bundle_preflight || return 1
    local bundle=$R22_RESUME_BUNDLE conf="$R22_RESUME_BUNDLE/resume.conf" source target fallback detail
    mkdir -p -- "$bundle/diagnostics" || return 1
    LEAP16_DIAGNOSTIC_ROOT="$bundle/diagnostics" LEAP16_AUTO_RESUME=1; export LEAP16_DIAGNOSTIC_ROOT LEAP16_AUTO_RESUME
    exec > >(tee -a "$bundle/automatic-resume.log") 2>&1
    printf 'openSUSE Bootloader Switcher %s automatic rEFInd-edge resume\nBundle: %s\n' "${SWITCHER_RELEASE:-leap16-r64}" "$bundle"
    load_pending_state || { r22_write_user_result "$conf" failed "Invalid r64 pending state: $PENDING_REASON" || true; r22_remove_resume_service_files; return 1; }
    validate_pending_compatibility || { r22_write_user_result "$conf" failed "Incompatible r64 pending state: $PENDING_REASON" || true; r22_remove_resume_service_files; return 1; }
    source=$PENDING_SOURCE; target=$PENDING_TARGET
    detect_bootloader

    if [[ $source:$target == refind:limine ]]; then
        if leap16_r64_limine_fallback_staged; then
            fallback=$(leap16_r64_limine_fallback_id)
            if [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == "$fallback" ]]; then
                leap16_r64_retire_refind_after_limine_fallback_proof || { r22_write_user_result "$conf" failed 'Limine fallback arrived but r64 second-proof finalization failed; no unproven rEFInd retirement was authorized beyond completed ownership-gated steps.' || true; r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true; r22_remove_resume_service_files; return 1; }
                leap16_capture_diagnostics auto-resume-pass >/dev/null 2>&1 || true
                r13_sync_root_diagnostics_to_user "$conf" "$bundle" success || true
                detail=$(leap16_r64_result_detail "$source" "$target" "$PENDING_TARGET_BOOT_ID" "$fallback")
                r22_cleanup_user_shadow_after_success "$conf"; r22_write_user_result "$conf" success "$detail" || true; r22_remove_resume_service_files; rm -rf -- "$bundle" 2>/dev/null || true; return 0
            fi
            if [[ $BOOTLOADER == refind && ${BOOT_CURRENT^^} == ${PENDING_OLD_BOOT_ID^^} ]]; then
                if leap16_r64_restore_pre_limine_fallback_state; then
                    leap16_r64_sync_fallback_state_to_user "$conf" || true; r13_sync_root_diagnostics_to_user "$conf" "$bundle" safe-fallback || true
                    r22_write_user_result "$conf" safe-fallback 'The second Limine fallback proof was not obtained. Canonical Limine remains proven; the exact pre-transfer fallback and rEFInd recovery topology were restored.' || true
                    r22_remove_resume_service_files; return 0
                fi
            fi
            r22_write_user_result "$conf" failed 'The armed Limine fallback did not become exact BootCurrent and safe fallback-transfer rollback was not completed. rEFInd retirement was not attempted.' || true
            r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true; r22_remove_resume_service_files; return 1
        fi

        if [[ $BOOTLOADER == refind && ${BOOT_CURRENT^^} == ${PENDING_OLD_BOOT_ID^^} ]]; then
            printf 'Automatic resume returned to rEFInd source; no Limine proof/promotion is allowed.\n'
            r22_resume_source_fallback "$conf"; local rc=$?; r13_sync_root_diagnostics_to_user "$conf" "$bundle" "$([[ $rc == 0 ]] && printf safe-fallback || printf failed)" || true; return "$rc"
        fi
        [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { r22_write_user_result "$conf" failed 'rEFInd -> Limine resume saw unexpected BootCurrent; source cleanup was not attempted.' || true; r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true; r22_remove_resume_service_files; return 1; }
        case "$PENDING_PHASE" in
            boot-armed) leap16_r64_validate_limine_primary_runtime || { r22_write_user_result "$conf" failed 'Canonical Limine booted but primary proof failed; rEFInd remains intact and no fallback transfer occurred.' || true; r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true; r22_remove_resume_service_files; return 1; }; r22_sync_user_phase_from_root "$conf" runtime-validated || true ;;
            runtime-validated) printf 'Primary Limine proof already persisted; continuing fallback staging.\n' ;;
            *) r22_write_user_result "$conf" failed "Unexpected r64 resume phase: $PENDING_PHASE" || true; r22_remove_resume_service_files; return 1 ;;
        esac
        leap16_r64_promote_and_stage_limine_fallback || { r22_write_user_result "$conf" failed 'Primary Limine proof passed but fallback staging failed. rEFInd retirement was not attempted.' || true; r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true; r22_remove_resume_service_files; return 1; }
        leap16_r64_sync_fallback_state_to_user "$conf" || warn 'Could not mirror r64 fallback sidecars to the user snapshot; root bundle remains authoritative'
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" fallback-armed || true
        fallback=$(leap16_r64_limine_fallback_id); r22_write_user_result "$conf" pending "Primary Limine is proven. Genuine Limine EFI/BOOT Boot$fallback is armed for proof #2; exact rEFInd recovery remains intact until that proof succeeds." || true
        printf '\nr64 phase 1 complete. Rebooting once into explicit Limine fallback Boot%s.\n' "$fallback"
        systemctl reboot || { printf 'Automatic reboot request failed. BootNext remains armed; reboot normally to continue.\n' >&2; return 1; }
        return 0
    fi

    # The other five rEFInd edges need one exact target runtime proof.
    if [[ $BOOTLOADER == "$source" && ${BOOT_CURRENT^^} == ${PENDING_OLD_BOOT_ID^^} ]]; then
        r22_resume_source_fallback "$conf"; local rc=$?; r13_sync_root_diagnostics_to_user "$conf" "$bundle" "$([[ $rc == 0 ]] && printf safe-fallback || printf failed)" || true; return "$rc"
    fi
    [[ $BOOTLOADER == "$target" && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { r22_write_user_result "$conf" failed 'Automatic r64 resume saw unexpected target identity; source cleanup was not attempted.' || true; r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true; r22_remove_resume_service_files; return 1; }
    case "$PENDING_PHASE" in
        boot-armed) validate_pending_target_runtime || { r22_write_user_result "$conf" failed "The automatically booted $target target failed runtime proof; source cleanup was not attempted." || true; r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true; r22_remove_resume_service_files; return 1; }; r22_sync_user_phase_from_root "$conf" runtime-validated || true ;;
        runtime-validated) printf 'Runtime proof already persisted; continuing r64 finalization.\n' ;;
        *) r22_write_user_result "$conf" failed "Unexpected r64 resume phase: $PENDING_PHASE" || true; r22_remove_resume_service_files; return 1 ;;
    esac
    r26_finalize_adapter_transaction || { r22_write_user_result "$conf" failed "Runtime proof passed but ownership-gated $source -> $target finalization failed." || true; r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true; r22_remove_resume_service_files; return 1; }
    leap16_capture_diagnostics auto-resume-pass >/dev/null 2>&1 || true; r13_sync_root_diagnostics_to_user "$conf" "$bundle" success || true
    detail=$(leap16_r64_result_detail "$source" "$target" "$PENDING_TARGET_BOOT_ID")
    r22_cleanup_user_shadow_after_success "$conf"; r22_write_user_result "$conf" success "$detail" || true; r22_remove_resume_service_files; rm -rf -- "$bundle" 2>/dev/null || true
}

# Intercept exactly the six rEFInd directions and leave every proven legacy
# resume engine untouched.
eval "$(declare -f r22_resume_transaction_root | sed '1s/r22_resume_transaction_root/r22_resume_transaction_root_pre_leap16_r64/')"
r22_resume_transaction_root() {
    local src='' tgt=''
    if [[ -f ${PENDING_STATE_FILE:-/nonexistent} ]]; then src=$(awk -F'\t' '$1=="source"{print $2;exit}' "$PENDING_STATE_FILE" 2>/dev/null || true); tgt=$(awk -F'\t' '$1=="target"{print $2;exit}' "$PENDING_STATE_FILE" 2>/dev/null || true); fi
    if leap16_r64_refind_edge "$src" "$tgt"; then leap16_r64_resume_root; else r22_resume_transaction_root_pre_leap16_r64 "$@"; fi
}

# ---------------------------------------------------------------------------
# Rollback: generic r26 is sufficient except rEFInd->GRUB has a parked direct
# GRUB alias outside the target ownership manifest, and rEFInd->Limine needs a
# dedicated pre-transfer/fallback-transfer split.
# ---------------------------------------------------------------------------

leap16_r64_rollback_refind_grub() {
    local direct next order id joined; local -a cur=() out=()
    validate_pending_compatibility || return 1; detect_bootloader
    [[ $BOOTLOADER == refind && ${BOOT_CURRENT^^} == ${PENDING_OLD_BOOT_ID^^} ]] || { fail 'Rollback requires recorded rEFInd source session'; return 1; }
    direct=$(leap16_r64_grub_direct_id) || return 1; next=$(pending_bootnext_id)
    [[ -z $next || ${next^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail "Unrelated BootNext=Boot$next exists"; return 1; }
    [[ -z $next ]] || sudo efibootmgr -N >/dev/null || return 1
    verify_pending_source_recovery_unchanged || return 1; verify_pending_candidate_ownership_unchanged || return 1
    order=$(leap16_current_boot_order); IFS=',' read -ra cur <<<"$order"
    for id in "${cur[@]}"; do id=${id^^}; [[ $id != ${PENDING_TARGET_BOOT_ID^^} && $id != "$direct" ]] || continue; boot_id_exists "$id" && out+=("$id"); done
    joined=$(IFS=,; printf '%s' "${out[*]}"); sudo efibootmgr -o "$joined" >/dev/null || return 1
    boot_id_exists "${PENDING_TARGET_BOOT_ID^^}" && sudo efibootmgr -b "${PENDING_TARGET_BOOT_ID^^}" -B >/dev/null || true
    boot_id_exists "$direct" && sudo efibootmgr -b "$direct" -B >/dev/null || true
    r26_remove_owned_manifest_paths "$PENDING_TARGET_MANIFEST" || return 1; r26_restore_fallback_on_rollback || return 1; sudo efibootmgr -o "$PENDING_ORIGINAL_BOOT_ORDER" >/dev/null || return 1
    remove_pending_transaction_snapshot || true; rm -f -- "$PENDING_STATE_FILE"; ok 'Rolled back rEFInd -> GRUB candidate including parked direct-GRUB alias'
}

leap16_r64_rollback_refind_limine() {
    if leap16_r64_limine_fallback_staged; then
        detect_bootloader
        if [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]]; then leap16_r64_restore_pre_limine_fallback_state; return $?; fi
        fail 'Fallback-transfer rollback is allowed only from the proven canonical Limine session; source retirement has not occurred.'; return 1
    fi
    rollback_pending_candidate_pre_leap16_r64_completion "$@"
}

# Capture the active rollback implementation after r51, then intercept only r64.
eval "$(declare -f rollback_pending_candidate | sed '1s/rollback_pending_candidate/rollback_pending_candidate_pre_leap16_r64_completion/')"
rollback_pending_candidate() {
    if ! leap16_r64_pending_edge; then rollback_pending_candidate_pre_leap16_r64_completion "$@"; return $?; fi
    case "${PENDING_SOURCE}:${PENDING_TARGET}" in
        refind:grub) leap16_r64_rollback_refind_grub ;;
        refind:limine) leap16_r64_rollback_refind_limine ;;
        *) rollback_pending_candidate_pre_leap16_r64_completion "$@" ;;
    esac
}


# ---------------------------------------------------------------------------
# Strict PTY child allowlist: admit only exact r64 executors.
# ---------------------------------------------------------------------------
leap16_r46_transcript_child() {
    local diag=${1:-} expected_current=${2:-} target=${3:-} kind=${4:-} command=${5:-}; shift 5 || true
    [[ -n $diag && -d $diag && ! -L $diag ]] || { printf '[FAIL] Invalid r46 transaction diagnostics directory\n' >&2; return 2; }
    case "$command" in
        leap16_r44_run_systemd_edge_inner|leap16_r44_restore_grub_backup_from_systemd|leap16_r44_restore_systemd_backup|\
        leap16_r51_run_systemd_to_limine_inner|leap16_r61_restore_systemd_backup_from_limine|leap16_r61_restore_limine_backup_from_systemd|\
        leap16_r64_run_refind_edge_inner|leap16_r64_restore_refind_backup|leap16_r64_restore_grub_backup_from_refind|\
        leap16_r64_restore_limine_backup_from_refind|leap16_r64_restore_systemd_backup_from_refind) ;;
        *) printf '[FAIL] Refusing unknown r46 transcript child command: %s\n' "$command" >&2; return 2 ;;
    esac
    declare -F "$command" >/dev/null 2>&1 || { printf '[FAIL] r46 transcript child command is unavailable: %s\n' "$command" >&2; return 2; }
    LEAP16_R44_TRANSACTION_DIAG_DIR=$diag; detect_bootloader
    [[ $BOOTLOADER == "$expected_current" ]] || { printf '[FAIL] Bootloader changed before transcript child start: expected %s, detected %s\n' "$expected_current" "$BOOTLOADER" >&2; return 1; }
    "$command" "$@"
}

# ---------------------------------------------------------------------------
# Complete 4-loader cross-backend restore selector (12 directed edges).
# ---------------------------------------------------------------------------
restore_backup_interactive() {
    local n dir target source
    discover_backups_quiet; ((${#DISCOVERED_BACKUPS[@]})) || { printf '\nNo backups found.\n'; return 0; }
    printf '\n'; list_backups; printf '\n'; read -r -p 'Select backup number to restore, or Enter to cancel: ' n
    [[ -n $n ]] || return 0; [[ $n =~ ^[0-9]+$ ]] && ((n>=1 && n<=${#DISCOVERED_BACKUPS[@]})) || { printf 'Invalid selection.\n'; return 1; }
    dir=${DISCOVERED_BACKUPS[n-1]}; validate_backup_compatibility "$dir" || { printf 'Restore refused: %s\n' "$BACKUP_COMPATIBILITY_REASON"; return 1; }
    load_backup_metadata "$dir" || return 1; target=$bootloader; detect_bootloader; source=$BOOTLOADER
    if [[ $source == "$target" ]]; then printf '\nSame-backend %s restore is not exposed as a fake cross-loader transaction.\n' "$(bootloader_display_name "$target")"; return 2; fi
    case "$source:$target" in
        limine:grub) leap16_r31_restore_grub_backup "$dir" ;;
        grub:limine) leap16_r31_restore_limine_backup "$dir" ;;
        systemd-boot:grub) leap16_r44_with_transaction_transcript "$source" "$target" restore leap16_r44_restore_grub_backup_from_systemd "$dir" ;;
        grub:systemd-boot) leap16_r44_with_transaction_transcript "$source" "$target" restore leap16_r44_restore_systemd_backup "$dir" ;;
        limine:systemd-boot) leap16_r44_with_transaction_transcript "$source" "$target" restore leap16_r61_restore_systemd_backup_from_limine "$dir" ;;
        systemd-boot:limine) leap16_r44_with_transaction_transcript "$source" "$target" restore leap16_r61_restore_limine_backup_from_systemd "$dir" ;;
        grub:refind|limine:refind|systemd-boot:refind) leap16_r44_with_transaction_transcript "$source" "$target" restore leap16_r64_restore_refind_backup "$dir" ;;
        refind:grub) leap16_r44_with_transaction_transcript "$source" "$target" restore leap16_r64_restore_grub_backup_from_refind "$dir" ;;
        refind:limine) leap16_r44_with_transaction_transcript "$source" "$target" restore leap16_r64_restore_limine_backup_from_refind "$dir" ;;
        refind:systemd-boot) leap16_r44_with_transaction_transcript "$source" "$target" restore leap16_r64_restore_systemd_backup_from_refind "$dir" ;;
        *) printf 'Restore %s -> %s is not enabled.\n' "$(bootloader_display_name "$source")" "$(bootloader_display_name "$target")"; return 2 ;;
    esac
}

# Keep the inherited detailed plan but correct availability and explain rEFInd.
if declare -F restore_plan_interactive >/dev/null 2>&1; then eval "$(declare -f restore_plan_interactive | sed '1s/restore_plan_interactive/restore_plan_interactive_pre_leap16_r64/')"; fi
restore_plan_interactive() {
    local tmp rc=0
    tmp=$(mktemp) || return 1
    restore_plan_interactive_pre_leap16_r64 "$@" >"$tmp"; rc=$?
    sed -e 's/rEFInd remains locked\./rEFInd cross-loader restore is enabled through the Leap r64 target-specific transaction engines./' \
        -e 's/complete hardware-proven GRUB2 <-> Limine <-> systemd-boot cross-backend matrix/complete hardware-proven three-loader matrix; rEFInd edges are implemented\/test-covered and hardware-pending/' -- "$tmp"
    cat -- "$tmp"; rm -f -- "$tmp"; return "$rc"
}

# ---------------------------------------------------------------------------
# Explicit matrix ledger. Hardware status is evidence, never inferred from code.
# ---------------------------------------------------------------------------
leap16_r64_print_matrix() {
    cat <<'MATRIX'
openSUSE Leap 16 bootloader matrix — leap16-r64

Legend:
  HW-PROVEN       completed on real hardware before r64
  HW-PENDING      implemented + regression-covered; requires real rEFInd hardware run
  —               same-backend; not a cross-loader edge

LIVE SWITCH MATRIX (source rows -> target columns)
                 GRUB2        Limine       systemd-boot  rEFInd
  GRUB2          —            HW-PROVEN    HW-PROVEN     HW-PENDING
  Limine         HW-PROVEN    —            HW-PROVEN     HW-PENDING
  systemd-boot   HW-PROVEN    HW-PROVEN    —             HW-PENDING
  rEFInd         HW-PENDING   HW-PENDING    HW-PENDING    —

CROSS-LOADER RESTORE MATRIX (active source -> restored backup target)
                 GRUB2        Limine       systemd-boot  rEFInd
  GRUB2          —            HW-PROVEN    HW-PROVEN     HW-PENDING
  Limine         HW-PROVEN    —            HW-PROVEN     HW-PENDING
  systemd-boot   HW-PROVEN    HW-PROVEN    —             HW-PENDING
  rEFInd         HW-PENDING   HW-PENDING    HW-PENDING    —

BACKUP BACKENDS
  GRUB2          HW-PROVEN
  Limine         HW-PROVEN
  systemd-boot   HW-PROVEN
  rEFInd         HW-PENDING (immutable EFI/refind + refind_linux.conf; vars excluded)

TARGET PROOF CONTRACTS
  GRUB2          canonical shim runtime proof -> native shim EFI/BOOT ownership -> direct-GRUB recovery second in BootOrder
  Limine         canonical Limine runtime proof -> independent Limine EFI/BOOT BootCurrent proof -> source retirement
  systemd-boot   canonical systemd-boot runtime proof -> exact byte-identical EFI/BOOT transfer -> source retirement
  rEFInd         canonical rEFInd runtime proof + PreviousBoot direct-kernel proof -> source retirement; rEFInd intentionally does NOT claim EFI/BOOT
MATRIX
}


# ---------------------------------------------------------------------------
# Manual pending-state management for the rEFInd -> Limine two-proof edge.
# Other r64 directions reuse the generic adapter menu because their single-proof
# finalizer dispatch is already overridden above.
# ---------------------------------------------------------------------------
leap16_r64_refind_limine_pending_menu() {
    local source=${PENDING_OLD_BOOT_ID^^} target=${PENDING_TARGET_BOOT_ID^^} fallback next choice
    detect_bootloader; show_pending_details
    fallback=$(leap16_r64_limine_fallback_id 2>/dev/null || true)
    if [[ -n $fallback && $BOOTLOADER == limine && ${BOOT_CURRENT^^} == "$fallback" ]]; then
        printf '\nExact Limine EFI/BOOT fallback Boot%s is running; both proofs can now be completed.\n' "$fallback"
        printf '[1] Finish migration and retire exact rEFInd source\n[2] Re-check fallback + rEFInd recovery\n[3] Back\n\n'; read -r -p 'Select an option: ' choice
        case "$choice" in 1) leap16_require_sudo_session && leap16_r64_retire_refind_after_limine_fallback_proof ;; 2) leap16_require_sudo_session && leap16_r64_validate_limine_fallback_runtime ;; 3|'') return 0 ;; *) return 1 ;; esac
        return $?
    fi
    if [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == "$target" ]]; then
        case "$PENDING_PHASE" in
            boot-armed)
                printf '\nCanonical Limine is the one-shot target; rEFInd remains persistent recovery.\n[1] Validate primary Limine now\n[2] Back\n\n'; read -r -p 'Select an option: ' choice
                [[ $choice == 1 ]] && leap16_require_sudo_session && leap16_r64_validate_limine_primary_runtime; return $? ;;
            runtime-validated)
                if leap16_r64_limine_fallback_staged; then
                    next=$(pending_bootnext_id); printf '\nPrimary Limine is proven. Fallback Boot%s is staged; rEFInd remains intact. BootNext=%s\n' "$fallback" "${next:-none}"
                    printf '[1] Re-check transferred Limine + rEFInd recovery\n[2] Reboot into fallback proof\n[3] Roll back only fallback transfer\n[4] Back\n\n'; read -r -p 'Select an option: ' choice
                    case "$choice" in 1) leap16_require_sudo_session && leap16_r64_verify_transferred_limine ;; 2) leap16_require_sudo_session && leap16_r64_verify_transferred_limine && r22_prepare_resume_bundle && r13_prompt_reboot ;; 3) leap16_require_sudo_session && leap16_r64_restore_pre_limine_fallback_state ;; 4|'') return 0 ;; *) return 1 ;; esac
                else
                    printf '\nCanonical Limine has proof #1. rEFInd is still intact.\n[1] Promote Limine + stage EFI/BOOT proof #2\n[2] Re-check primary Limine + rEFInd recovery\n[3] Back\n\n'; read -r -p 'Select an option: ' choice
                    case "$choice" in 1) leap16_require_sudo_session && leap16_r64_promote_and_stage_limine_fallback && r22_prepare_resume_bundle && r13_prompt_reboot ;; 2) leap16_require_sudo_session && leap16_r64_validate_limine_primary_runtime ;; 3|'') return 0 ;; *) return 1 ;; esac
                fi ;;
            *) fail "Unsupported r64 Limine target phase: $PENDING_PHASE"; return 1 ;;
        esac
        return $?
    fi
    if [[ $BOOTLOADER == refind && ${BOOT_CURRENT^^} == "$source" ]]; then
        case "$PENDING_PHASE" in
            candidate-ready)
                printf '\nrEFInd source is active; Limine candidate is parked.\n[1] Revalidate source + candidate\n[2] Arm one-time canonical Limine test\n[3] Roll back candidate\n[4] Back\n\n'; read -r -p 'Select an option: ' choice
                case "$choice" in 1) leap16_require_sudo_session && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep ;; 2) leap16_require_sudo_session && r23_arm_candidate_automatically && r22_prepare_resume_bundle && r23_prompt_reboot ;; 3) rollback_pending_candidate ;; 4|'') return 0 ;; *) return 1 ;; esac ;;
            boot-armed)
                printf '\nCanonical Limine BootNext=%s; rEFInd remains persistent first.\n[1] Re-check source + candidate\n[2] Roll back candidate\n[3] Back\n\n' "$(pending_bootnext_id 2>/dev/null || printf none)"; read -r -p 'Select an option: ' choice
                case "$choice" in 1) leap16_require_sudo_session && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep ;; 2) rollback_pending_candidate ;; 3|'') return 0 ;; *) return 1 ;; esac ;;
            runtime-validated)
                printf '\nPrimary Limine proof exists but rEFInd source is running again. Boot canonical Limine before fallback transfer/finalization.\n'; return 0 ;;
        esac
    fi
    fail 'Current BootCurrent/bootloader does not match a safe r64 rEFInd -> Limine management state'; return 1
}

if declare -F manage_pending_migration >/dev/null 2>&1; then eval "$(declare -f manage_pending_migration | sed '1s/manage_pending_migration/manage_pending_migration_pre_leap16_r64/')"; fi
manage_pending_migration() {
    pending_exists || { printf '\nNo pending migration.\n'; return 0; }
    load_pending_state || { printf '\nPending state is invalid: %s\n' "$PENDING_REASON"; return 1; }
    if leap16_r64_pending_refind_limine; then leap16_r64_refind_limine_pending_menu; else manage_pending_migration_pre_leap16_r64 "$@"; fi
}


# Firmware on the tested ASUS board can re-materialize equivalent Boot#### IDs.
# Bind retirement to exact same-ESP paths, not frozen numeric IDs, while still
# requiring every source path that had a baseline alias to remain represented.
leap16_r64_verify_source_alias_superset() {
    local source=$1 baseline wanted wnorm line path norm had found
    baseline=$(leap16_r64_baseline_path) || return 1; [[ -s $baseline ]] || return 1
    while IFS= read -r wanted; do
        [[ -n $wanted ]] || continue; wnorm=$(normalize_efi_path "$wanted" | tr '[:upper:]' '[:lower:]'); had=0
        while IFS= read -r line; do
            [[ $line =~ ^Boot[0-9A-Fa-f]{4}\*?[[:space:]] ]] || continue
            path=$(efi_path_from_efibootmgr_line "$line" 2>/dev/null || true); [[ -n $path ]] || continue
            norm=$(normalize_efi_path "$path" | tr '[:upper:]' '[:lower:]'); [[ $norm == "$wnorm" ]] && { had=1; break; }
        done <"$baseline"
        ((had)) || continue
        found=0
        while IFS= read -r _id; do [[ -n $_id ]] && { found=1; break; }; done < <(leap16_r48_ids_for_current_esp_path "$wanted")
        ((found)) || { fail "Baseline source path $wanted lost every exact same-ESP firmware alias before retirement"; return 1; }
    done < <(leap16_r64_source_paths "$source")
    # The recorded canonical source identity itself remains guarded by the
    # generic source-recovery verifier; extra same-path aliases are permitted.
    ok "Every baseline source EFI path remains represented; same-path Boot#### churn is tolerated and bounded by path+ESP identity"
}


# Final post-audit systemd ordering: prove the complete finalized target topology
# while rEFInd recovery still exists, then remove rEFInd.
leap16_r64_finalize_refind_to_systemd() {
    local target=${PENDING_TARGET_BOOT_ID^^} detail
    validate_pending_compatibility || return 1
    [[ ${PENDING_SOURCE}:${PENDING_TARGET} == refind:systemd-boot && $PENDING_PHASE == runtime-validated ]] || return 1
    detect_bootloader; [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == "$target" ]] || { fail 'systemd-boot finalization requires exact runtime-proven target'; return 1; }
    [[ -z $(pending_bootnext_id) ]] || return 1
    run_validation preflight || return 1; pending_validate_running_kernel || return 1; pending_validate_runtime_cmdline_against_source || return 1
    verify_pending_candidate_ownership_unchanged || return 1; leap16_r34_validate_systemd_boot_chain runtime || return 1; leap16_r64_verify_refind_source_passive || return 1
    leap16_r34_target_first_keep_recovery || return 1
    leap16_r34_validate_systemd_boot_chain target || return 1; leap16_r64_verify_refind_source_passive || return 1
    leap16_r64_transfer_systemd_fallback_exact || return 1
    leap16_r34_set_loader_policy_systemd || return 1
    # This proves canonical alias, first position, exact fallback bytes, and no
    # explicit fallback alias before source deletion is authorized.
    leap16_r51_systemd_source_gate || { fail 'Complete finalized systemd-boot topology failed before rEFInd retirement; source remains intact'; return 1; }
    r26_verify_owned_manifest "$PENDING_SOURCE_MANIFEST" || return 1
    leap16_r64_remove_refind_from_order_keep "$target" || return 1
    leap16_r64_delete_refind_source || return 1
    detect_bootloader; [[ $BOOTLOADER == systemd-boot && ${BOOT_CURRENT^^} == "$target" ]] || return 1
    leap16_r51_systemd_source_gate || return 1
    pending_capture_runtime_diagnostics finalized-systemd-boot-from-refind >/dev/null 2>&1 || true
    if [[ -n ${PENDING_BACKUP_PATH:-} ]]; then detail="rEFInd -> restored systemd-boot backup finalized after exact runtime proof. systemd-boot Boot$target is first, owns byte-identical EFI/BOOT, and exact rEFInd source state is retired. Backup: $PENDING_BACKUP_PATH"; else detail="rEFInd -> systemd-boot finalized after exact runtime proof. systemd-boot Boot$target is first, owns byte-identical EFI/BOOT, and exact rEFInd source state is retired."; fi
    r35_write_local_transaction_result success "$detail" || true
    remove_pending_transaction_snapshot || true; rm -f -- "$PENDING_STATE_FILE"
    printf '\nFINALIZED rEFInd -> systemd-boot successfully.\n'
}

# Likewise prove the native GRUB fallback/direct recovery topology before
# deleting rEFInd, then re-prove after cleanup.
leap16_r64_finalize_refind_to_grub() {
    local target=${PENDING_TARGET_BOOT_ID^^} direct detail
    direct=$(leap16_r64_grub_direct_id) || return 1
    validate_pending_compatibility || return 1
    [[ ${PENDING_SOURCE}:${PENDING_TARGET} == refind:grub && $PENDING_PHASE == runtime-validated ]] || return 1
    detect_bootloader; [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == "$target" ]] || { fail "GRUB finalization must run from runtime-proven shim Boot$target"; return 1; }
    [[ -z $(pending_bootnext_id) ]] || return 1
    run_validation preflight || return 1; pending_validate_running_kernel || return 1; pending_validate_runtime_cmdline_against_source || return 1
    verify_pending_candidate_ownership_unchanged || return 1; validate_grub_boot_chain runtime || return 1; leap16_r64_verify_refind_source_passive || return 1; leap16_r64_validate_grub_direct_alias || return 1
    leap16_r34_target_first_keep_recovery || return 1
    validate_grub_boot_chain target || return 1; leap16_r64_verify_refind_source_passive || return 1
    leap16_r38_transfer_grub_fallback || return 1
    [[ $(r21_hash_privileged "$PENDING_OLD_FALLBACK_PATH") == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'Native GRUB shim fallback transfer is not byte-identical before source retirement'; return 1; }
    validate_grub_boot_chain target || return 1; leap16_r64_validate_grub_direct_alias || return 1
    r26_verify_owned_manifest "$PENDING_SOURCE_MANIFEST" || return 1
    leap16_r64_final_grub_order || return 1; leap16_r64_delete_refind_source || return 1; leap16_r38_set_loader_policy_grub || return 1
    detect_bootloader; [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == "$target" ]] || return 1
    [[ $(leap16_current_boot_order) == "$target,$direct"* ]] || return 1
    [[ $(r21_hash_privileged "$PENDING_ESP_MOUNT/EFI/BOOT/BOOTX64.EFI") == "$PENDING_TARGET_EFI_HASH" ]] || return 1
    validate_grub_boot_chain final || return 1; leap16_r64_validate_grub_direct_alias || return 1
    pending_capture_runtime_diagnostics finalized-grub-from-refind >/dev/null 2>&1 || true
    if [[ -n ${PENDING_BACKUP_PATH:-} ]]; then detail="rEFInd -> restored native GRUB2 backup finalized after exact shim runtime proof. Shim Boot$target is first; direct GRUB Boot$direct second; EFI/BOOT is shim-owned; rEFInd is retired. Backup: $PENDING_BACKUP_PATH"; else detail="rEFInd -> native GRUB2 finalized after exact shim runtime proof. Shim Boot$target is first; direct GRUB Boot$direct second; EFI/BOOT is shim-owned; rEFInd is retired."; fi
    r35_write_local_transaction_result success "$detail" || true
    remove_pending_transaction_snapshot || true; rm -f -- "$PENDING_STATE_FILE"
    printf '\nFINALIZED rEFInd -> native GRUB2 successfully.\n'
}


# Post-audit hardening: once the second Limine fallback proof has succeeded,
# convert the target to its final config and re-prove it while rEFInd recovery
# still exists. Only then remove rEFInd from firmware/filesystem ownership.
leap16_r64_retire_refind_after_limine_fallback_proof() {
    local source=${PENDING_OLD_BOOT_ID^^} target=${PENDING_TARGET_BOOT_ID^^} fallback final_hash id detail
    local -a extras=()
    leap16_r64_validate_limine_fallback_runtime || return 1
    fallback=$(leap16_r64_limine_fallback_id) || return 1
    mapfile -t extras < <(leap16_r64_extra_fallback_ids) || return 1

    # The target already owns two independent runtime proofs. Remove the
    # temporary direct-rEFInd recovery stanza and freeze the final Limine
    # manifest before source retirement, so a config/write failure cannot
    # strand us after deleting the recovery source.
    final_hash=$(leap16_r64_remove_limine_refind_recovery_block) || return 1
    leap16_r64_refresh_limine_manifest || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_limine_boot_chain migration || return 1
    [[ $(r21_hash_privileged "${PENDING_ESP_MOUNT%/}/limine.conf") == "$final_hash" ]] || {
        fail 'Final Limine config hash changed before rEFInd retirement'; return 1;
    }
    leap16_r64_verify_refind_source_passive || return 1

    leap16_r51_set_final_limine_policy || return 1
    leap16_r64_final_limine_order || return 1
    for id in "${extras[@]}"; do
        boot_id_exists "$id" && sudo efibootmgr -b "$id" -B >/dev/null || true
    done
    r26_verify_owned_manifest "$PENDING_SOURCE_MANIFEST" || return 1
    leap16_r64_delete_refind_source || return 1

    detect_bootloader
    [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == "$fallback" ]] || return 1
    [[ $(leap16_current_boot_order) == "$target,$fallback"* ]] || return 1
    [[ -z $(leap16_r48_ids_for_current_esp_path "$LEAP16_R64_REFIND_EFI" | awk 'NF') ]] || {
        fail 'Canonical rEFInd alias remains after retirement'; return 1;
    }
    [[ $(r21_hash_privileged "$PENDING_OLD_FALLBACK_PATH") == "$PENDING_TARGET_EFI_HASH" ]] || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_limine_boot_chain migration || return 1
    [[ $(r21_hash_privileged "${PENDING_ESP_MOUNT%/}/limine.conf") == "$final_hash" ]] || return 1
    pending_capture_runtime_diagnostics finalized-limine-from-refind >/dev/null 2>&1 || true

    if [[ -n ${PENDING_BACKUP_PATH:-} ]]; then
        detail="rEFInd -> restored Limine backup completed with two independent runtime proofs. Primary Limine Boot$target is first; genuine Limine fallback Boot$fallback second; exact rEFInd source retired. Backup: $PENDING_BACKUP_PATH"
    else
        detail="rEFInd -> Limine completed with two independent runtime proofs. Primary Limine Boot$target is first; genuine Limine fallback Boot$fallback second; exact rEFInd source retired."
    fi
    r35_write_local_transaction_result success "$detail" || true
    remove_pending_transaction_snapshot || true
    rm -f -- "$PENDING_STATE_FILE"
    printf '\nFINALIZED rEFInd -> Limine after canonical + EFI/BOOT proofs.\n'
}

# ---------------------------------------------------------------------------
# Final r64 post-audit hardening.
# ---------------------------------------------------------------------------

# This first hardware revision deliberately supports the topology actually
# validated by the Leap test environment: /boot is part of the ext4 root
# filesystem and rEFInd direct-boots those kernels through ext4_x64.efi.
# Fail closed on a different /boot filesystem instead of pretending the ext4
# driver covers an untested Btrfs/XFS/XBOOTLDR layout.
leap16_r64_require_tested_boot_filesystem() {
    local root_src root_fs boot_src boot_fs
    root_src=$(findmnt -rn -M / -o SOURCE 2>/dev/null || true)
    root_fs=$(findmnt -rn -M / -o FSTYPE 2>/dev/null || true)
    boot_src=$(findmnt -rn -T /boot -o SOURCE 2>/dev/null || true)
    boot_fs=$(findmnt -rn -T /boot -o FSTYPE 2>/dev/null || true)
    [[ -n $root_src && -n $root_fs && -n $boot_src && -n $boot_fs ]] \
        || { fail 'Could not resolve the root//boot filesystem topology required by the rEFInd backend'; return 1; }
    [[ $root_fs == ext4 && $boot_fs == ext4 && $boot_src == "$root_src" ]] || {
        fail "r64 rEFInd is fail-closed outside the tested Leap topology: /boot must live on the ext4 root filesystem (root=$root_src/$root_fs, boot=$boot_src/$boot_fs)"
        return 1
    }
    ok 'rEFInd direct-kernel topology is the tested Leap layout: /boot lives on the ext4 root filesystem'
}

# A default repository package is preferred, but Leap repository composition
# can vary.  A user may provide a trusted local RPM explicitly; the switcher
# never downloads an unpinned rEFInd RPM on its own.
leap16_r64_install_refind_package() {
    local rpm_path=${BOOTLOADER_SWITCHER_REFIND_RPM:-} resolved=''
    if rpm -q refind >/dev/null 2>&1 && have refind-install; then
        ok 'openSUSE rEFInd package/tool set is already installed'
        return 0
    fi
    have zypper || { fail 'zypper is required to install rEFInd on openSUSE Leap'; return 1; }

    if [[ -n $rpm_path ]]; then
        [[ $rpm_path == /* ]] || { fail 'BOOTLOADER_SWITCHER_REFIND_RPM must be an absolute path to a trusted local RPM'; return 1; }
        [[ -f $rpm_path && ! -L $rpm_path ]] || { fail "Trusted local rEFInd RPM is not a regular non-symlink file: $rpm_path"; return 1; }
        resolved=$(readlink -f -- "$rpm_path" 2>/dev/null || true)
        [[ -n $resolved && $resolved == "$rpm_path" ]] || { fail 'Trusted local rEFInd RPM path could not be resolved exactly'; return 1; }
        rpm -K -- "$rpm_path" >/dev/null 2>&1 || { fail 'Trusted local rEFInd RPM failed rpm -K package-integrity/signature verification'; return 1; }
        printf 'Installing user-supplied trusted rEFInd RPM through zypper...\n'
        sudo zypper --non-interactive --no-recommends install -- "$rpm_path" || return 1
    else
        printf 'Installing native openSUSE rEFInd package without weak dependencies...\n'
        if ! sudo zypper --non-interactive --no-recommends install refind; then
            fail 'zypper could not install package "refind". If it is unavailable in the configured Leap repositories, provide a trusted local RPM with BOOTLOADER_SWITCHER_REFIND_RPM=/absolute/path/to/refind.rpm and retry.'
            return 1
        fi
    fi
    rpm -q refind >/dev/null 2>&1 || { fail 'rEFInd RPM is not installed after zypper returned'; return 1; }
    have refind-install || { fail 'refind-install is unavailable after package installation'; return 1; }
    ok 'Native openSUSE rEFInd package/tool set is ready'
}

# Make the inherited r33 proof diagnostics accurately describe Leap while
# retaining the same PreviousBoot anti-chainload proof semantics.
if declare -F r33_verify_refind_direct_kernel_launch >/dev/null 2>&1; then
    eval "$(declare -f r33_verify_refind_direct_kernel_launch | sed '1s/r33_verify_refind_direct_kernel_launch/r33_verify_refind_direct_kernel_launch_pre_leap16_r64_final/')"
fi
r33_verify_refind_direct_kernel_launch() {
    if ! is_leap16; then
        r33_verify_refind_direct_kernel_launch_pre_leap16_r64_final "$@"
        return $?
    fi
    [[ ${PENDING_TARGET:-} == refind ]] || return 0
    local running expected previous lower_previous source_efi_base
    running=${R33_RUNNING_KERNEL_RELEASE:-$(uname -r)}
    [[ -f /boot/vmlinuz-$running ]] || { fail "rEFInd runtime proof cannot find the running Leap kernel payload /boot/vmlinuz-$running"; return 1; }
    expected="vmlinuz-$running"
    previous=$(r33_refind_previous_boot_text 2>/dev/null || true)
    [[ -n $previous ]] || { fail 'rEFInd runtime proof could not read PreviousBoot from disk-backed vars or EFI NVRAM'; return 1; }
    lower_previous=${previous,,}
    source_efi_base=${PENDING_OLD_BOOT_EFI_PATH##*\\}; source_efi_base=${source_efi_base##*/}
    if [[ -n $source_efi_base && $lower_previous == *"${source_efi_base,,}"* ]]; then
        fail "rEFInd PreviousBoot shows the protected source EFI loader was chainloaded ($source_efi_base); direct-kernel runtime proof is refused"
        return 1
    fi
    [[ $lower_previous == *"${expected,,}"* ]] || {
        fail "rEFInd PreviousBoot does not prove the running openSUSE Leap kernel was launched directly (expected $expected; recorded: $previous)"
        return 1
    }
    ok "rEFInd PreviousBoot proves direct launch of the running openSUSE Leap kernel ($expected)"
}

# Wrap the effective preflight last, after the two-proof Limine tightening, so
# every one of the six rEFInd edges is refused on an untested /boot topology.
eval "$(declare -f leap16_r64_preflight | sed '1s/leap16_r64_preflight/leap16_r64_preflight_pre_final_audit/')"
leap16_r64_preflight() {
    leap16_r64_preflight_pre_final_audit "$@" || return $?
    leap16_r64_require_tested_boot_filesystem || return 1
}

# Firmware is allowed to synthesize duplicate Boot#### aliases to the exact
# canonical rEFInd path.  Keep the recorded source identity mandatory, but
# tolerate same-path/same-ESP extras and normalize every such alias at source
# retirement.  This mirrors the duplicate-GRUB behavior already observed on
# the test firmware without broadening ownership beyond path+ESP identity.
leap16_r64_current_refind_source_ids() {
    local id
    while IFS= read -r id; do
        id=${id^^}; [[ $id =~ ^[0-9A-F]{4}$ ]] || continue
        leap16_nvram_entry_matches_current_esp "$id" || continue
        nvram_id_matches_path "$id" "$LEAP16_R64_REFIND_EFI" || continue
        printf '%s\n' "$id"
    done < <(r21_nvram_ids_for_esp_path "$LEAP16_R64_REFIND_EFI") | LC_ALL=C sort -u
}

leap16_r64_verify_refind_source_passive() {
    local source=${PENDING_OLD_BOOT_ID^^} hash ids
    boot_id_exists "$source" || { fail "rEFInd source Boot$source disappeared"; return 1; }
    nvram_id_matches_path "$source" "$LEAP16_R64_REFIND_EFI" || { fail 'rEFInd source path changed'; return 1; }
    leap16_nvram_entry_matches_current_esp "$source" || { fail 'rEFInd source ESP binding changed'; return 1; }
    hash=$(r21_hash_privileged "$PENDING_SOURCE_EFI_RESOLVED")
    [[ $hash == "$PENDING_SOURCE_EFI_HASH" ]] || { fail 'rEFInd source EFI bytes changed'; return 1; }
    r26_verify_owned_manifest "$PENDING_SOURCE_MANIFEST" || return 1
    ids=$(leap16_r64_current_refind_source_ids | paste -sd, -)
    [[ -n $ids ]] || { fail 'No exact same-ESP canonical rEFInd recovery alias remains'; return 1; }
    case ",$ids," in *,"$source",*) ;; *) fail "Recorded rEFInd source Boot$source is no longer represented in the bounded alias set ($ids)"; return 1 ;; esac
    if [[ $ids == *,* ]]; then warn "Firmware exposed duplicate same-path rEFInd recovery aliases ($ids); they remain bounded and will be normalized at retirement"; fi
    validate_refind_boot_chain recovery || return 1
    ok "Recorded rEFInd Boot$source remains exact passive recovery; same-path aliases are ownership-bounded"
}

leap16_r64_remove_refind_from_order_keep() {
    local -a prefix=("$@") current=() source_ids=() out=(); local order id p joined skip sid
    mapfile -t source_ids < <(leap16_r64_current_refind_source_ids)
    ((${#source_ids[@]} > 0)) || { fail 'No bounded rEFInd source alias is visible before BootOrder cleanup'; return 1; }
    case " ${source_ids[*]} " in *" ${PENDING_OLD_BOOT_ID^^} "*) ;; *) fail "Recorded rEFInd source Boot${PENDING_OLD_BOOT_ID^^} disappeared before BootOrder cleanup"; return 1 ;; esac
    order=$(leap16_current_boot_order) || return 1
    out=("${prefix[@]}")
    IFS=',' read -ra current <<<"$order"
    for id in "${current[@]}"; do
        id=${id^^}; [[ -n $id ]] || continue; skip=0
        for p in "${prefix[@]}"; do [[ $id == ${p^^} ]] && { skip=1; break; }; done
        if (( ! skip )); then for sid in "${source_ids[@]}"; do [[ $id == ${sid^^} ]] && { skip=1; break; }; done; fi
        ((skip)) && continue
        boot_id_exists "$id" && out+=("$id")
    done
    joined=$(IFS=,; printf '%s' "${out[*]}")
    sudo efibootmgr -o "$joined" >/dev/null || return 1
    [[ $(leap16_current_boot_order) == "$(IFS=,; printf '%s' "${prefix[*]}")"* ]] || return 1
    for sid in "${source_ids[@]}"; do leap16_order_has_id "$(leap16_current_boot_order)" "${sid^^}" && { fail "rEFInd source alias Boot${sid^^} remains in persistent BootOrder"; return 1; }; done
    ok 'Removed every bounded canonical rEFInd source alias from persistent BootOrder before source EFI retirement'
}

leap16_r64_delete_refind_source() {
    local source=${PENDING_OLD_BOOT_ID^^} id ids; local -a aliases=()
    leap16_r64_verify_refind_source_passive || return 1
    mapfile -t aliases < <(leap16_r64_current_refind_source_ids)
    ((${#aliases[@]} > 0)) || return 1
    case " ${aliases[*]} " in *" $source "*) ;; *) return 1 ;; esac
    for id in "${aliases[@]}"; do
        id=${id^^}
        leap16_order_has_id "$(leap16_current_boot_order)" "$id" && { fail "Refusing to delete rEFInd Boot$id while it remains in persistent BootOrder"; return 1; }
        nvram_id_matches_path "$id" "$LEAP16_R64_REFIND_EFI" || return 1
        leap16_nvram_entry_matches_current_esp "$id" || return 1
        sudo efibootmgr -b "$id" -B >/dev/null || return 1
        boot_id_exists "$id" && { fail "rEFInd source Boot$id remains after deletion"; return 1; }
        ok "Deleted bounded canonical rEFInd source alias Boot$id after BootOrder retirement"
    done
    [[ -z $(leap16_r64_current_refind_source_ids | awk 'NF') ]] || { fail 'A canonical rEFInd source alias remains after NVRAM cleanup'; return 1; }
    r26_remove_owned_manifest_paths "$PENDING_SOURCE_MANIFEST" || return 1
    sudo rm -f -- /boot/refind_linux.conf 2>/dev/null || true
    ok 'Retired exact immutable rEFInd source files after every bounded source alias was removed'
}

# Complete the duplicate-rEFInd alias hardening for the two finalizers that
# build target-specific orders instead of calling remove_refind_from_order_keep.
leap16_r64_final_grub_order() {
    local target=${PENDING_TARGET_BOOT_ID^^} direct order id joined sid skip
    local -a current=() out=() source_ids=()
    direct=$(leap16_r64_grub_direct_id) || return 1
    mapfile -t source_ids < <(leap16_r64_current_refind_source_ids)
    ((${#source_ids[@]} > 0)) || { fail 'No bounded rEFInd source alias exists before final GRUB ordering'; return 1; }
    case " ${source_ids[*]} " in *" ${PENDING_OLD_BOOT_ID^^} "*) ;; *) return 1 ;; esac
    out=("$target" "$direct")
    order=$(leap16_current_boot_order) || return 1
    IFS=',' read -ra current <<<"$order"
    for id in "${current[@]}"; do
        id=${id^^}; [[ -n $id ]] || continue; skip=0
        [[ $id == "$target" || $id == "$direct" ]] && skip=1
        if (( ! skip )); then for sid in "${source_ids[@]}"; do [[ $id == ${sid^^} ]] && { skip=1; break; }; done; fi
        ((skip)) && continue
        boot_id_exists "$id" && out+=("$id")
    done
    joined=$(IFS=,; printf '%s' "${out[*]}")
    sudo efibootmgr -o "$joined" >/dev/null || return 1
    [[ $(leap16_current_boot_order) == "$target,$direct"* ]] || { fail 'Final GRUB order does not begin shim,direct'; return 1; }
    for sid in "${source_ids[@]}"; do leap16_order_has_id "$(leap16_current_boot_order)" "${sid^^}" && { fail "rEFInd source alias Boot${sid^^} remains in final GRUB BootOrder"; return 1; }; done
    ok 'Final GRUB order excludes every bounded rEFInd source alias while retaining shim + direct recovery first/second'
}

leap16_r64_final_limine_order() {
    local target=${PENDING_TARGET_BOOT_ID^^} fallback order id joined x owned sid skip
    local -a cur=() out=() extras=() source_ids=()
    fallback=$(leap16_r64_limine_fallback_id) || return 1
    mapfile -t extras < <(leap16_r64_extra_fallback_ids) || return 1
    mapfile -t source_ids < <(leap16_r64_current_refind_source_ids)
    ((${#source_ids[@]} > 0)) || { fail 'No bounded rEFInd source alias exists before final Limine ordering'; return 1; }
    case " ${source_ids[*]} " in *" ${PENDING_OLD_BOOT_ID^^} "*) ;; *) return 1 ;; esac
    out=("$target" "$fallback")
    order=$(leap16_current_boot_order) || return 1
    IFS=',' read -ra cur <<<"$order"
    for id in "${cur[@]}"; do
        id=${id^^}; [[ -n $id ]] || continue; skip=0; owned=0
        [[ $id == "$target" || $id == "$fallback" ]] && skip=1
        if (( ! skip )); then for sid in "${source_ids[@]}"; do [[ $id == ${sid^^} ]] && { skip=1; break; }; done; fi
        if (( ! skip )); then for x in "${extras[@]}"; do [[ $id == ${x^^} ]] && { owned=1; break; }; done; fi
        ((skip || owned)) && continue
        boot_id_exists "$id" && out+=("$id")
    done
    joined=$(IFS=,; printf '%s' "${out[*]}")
    sudo efibootmgr -o "$joined" >/dev/null || return 1
    [[ $(leap16_current_boot_order) == "$target,$fallback"* ]] || return 1
    for sid in "${source_ids[@]}"; do leap16_order_has_id "$(leap16_current_boot_order)" "${sid^^}" && { fail "rEFInd source alias Boot${sid^^} remains in final Limine BootOrder"; return 1; }; done
    ok 'Final Limine order excludes every bounded rEFInd source alias and keeps primary + proven fallback first/second'
}
