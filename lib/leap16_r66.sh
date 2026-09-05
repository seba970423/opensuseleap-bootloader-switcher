#!/usr/bin/env bash

# leap16-r66
# rEFInd acquisition/staging hardening after the second real Leap hardware run.
#
# Hardware proved that Leap 16's configured repositories do not provide a
# `refind` package.  More importantly, the upstream rEFInd RPM/package path is
# unsuitable for this transaction engine because its installer can copy to the
# ESP and register/promote firmware state on its own.  r66 therefore stages a
# fixed upstream *binary archive* manually and keeps every ESP/NVRAM mutation
# under the switcher's create-only/source-first transaction choreography.
#
# Existing GRUB/Limine/systemd-boot engines and r65's corrected native zypper
# helper remain untouched.

LEAP16_R66_REFIND_VERSION='0.14.2'
LEAP16_R66_REFIND_ARCHIVE_NAME="refind-bin-${LEAP16_R66_REFIND_VERSION}.zip"
LEAP16_R66_REFIND_ARCHIVE_URL="https://downloads.sourceforge.net/project/refind/${LEAP16_R66_REFIND_VERSION}/${LEAP16_R66_REFIND_ARCHIVE_NAME}"
LEAP16_R66_REFIND_ARCHIVE_ROOT="refind-bin-${LEAP16_R66_REFIND_VERSION}/refind"
LEAP16_R66_REFIND_DOWNLOAD_MARKER='# opensuse-bootloader-switcher r66: upstream rEFInd binary archive, manually staged'

LEAP16_R66_REFIND_WORKDIR=''
LEAP16_R66_REFIND_BUNDLE_ROOT=''
LEAP16_R66_REFIND_ARCHIVE_SHA256=''

leap16_r66_cleanup_refind_bundle() {
    if [[ -n ${LEAP16_R66_REFIND_WORKDIR:-} && -d ${LEAP16_R66_REFIND_WORKDIR:-} ]]; then
        rm -rf -- "$LEAP16_R66_REFIND_WORKDIR"
    fi
    LEAP16_R66_REFIND_WORKDIR=''
    LEAP16_R66_REFIND_BUNDLE_ROOT=''
    LEAP16_R66_REFIND_ARCHIVE_SHA256=''
}

leap16_r66_refind_archive_path_is_safe() {
    local p=$1 resolved
    [[ $p == /* ]] || { fail 'BOOTLOADER_SWITCHER_REFIND_ARCHIVE must be an absolute path'; return 1; }
    [[ -f $p && ! -L $p ]] || { fail "rEFInd archive is not a regular non-symlink file: $p"; return 1; }
    resolved=$(readlink -f -- "$p" 2>/dev/null || true)
    [[ -n $resolved && $resolved == "$p" ]] || { fail 'rEFInd archive path could not be resolved exactly'; return 1; }
}

leap16_r66_download_refind_archive() {
    local out=$1
    printf 'Downloading fixed upstream rEFInd %s binary archive from SourceForge...\n' "$LEAP16_R66_REFIND_VERSION"
    if have curl; then
        curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 --retry-delay 1 \
            --output "$out" "$LEAP16_R66_REFIND_ARCHIVE_URL" || return 1
    elif have wget; then
        wget --https-only --tries=3 --timeout=30 -O "$out" "$LEAP16_R66_REFIND_ARCHIVE_URL" || return 1
    else
        fail 'curl or wget is required unless BOOTLOADER_SWITCHER_REFIND_ARCHIVE points to a local upstream binary ZIP'
        return 1
    fi
    [[ -s $out ]] || { fail 'Downloaded rEFInd archive is empty'; return 1; }
}

leap16_r66_refind_archive_names_safe() {
    local archive=$1 name
    while IFS= read -r name; do
        [[ -n $name ]] || continue
        [[ $name != /* ]] || { fail "rEFInd ZIP contains an absolute path: $name"; return 1; }
        [[ $name != *'\\'* ]] || { fail "rEFInd ZIP contains a backslash path: $name"; return 1; }
        case "/$name/" in
            */../*|*/./*) fail "rEFInd ZIP contains an unsafe traversal component: $name"; return 1 ;;
        esac
    done < <(unzip -Z1 -- "$archive" 2>/dev/null) || return 1
}

leap16_r66_verify_refind_bundle() {
    local root=$1 efi driver sample magic
    efi="$root/refind_x64.efi"; driver="$root/drivers_x64/ext4_x64.efi"; sample="$root/refind.conf-sample"
    [[ -f $efi && ! -L $efi ]] || { fail 'Upstream archive lacks a regular refind_x64.efi'; return 1; }
    [[ -f $driver && ! -L $driver ]] || { fail 'Upstream archive lacks the required regular ext4_x64.efi driver'; return 1; }
    [[ -f $sample && ! -L $sample ]] || { fail 'Upstream archive lacks a regular refind.conf-sample'; return 1; }
    [[ -d $root/icons && ! -L $root/icons ]] || { fail 'Upstream archive lacks the rEFInd icons directory'; return 1; }
    if find "$root/icons" -type l -print -quit | grep -q .; then
        fail 'Upstream rEFInd icons tree contains a symlink; refusing transaction staging'
        return 1
    fi
    magic=$(od -An -tx1 -N2 -- "$efi" 2>/dev/null | tr -d '[:space:]')
    [[ $magic == 4d5a ]] || { fail 'Upstream refind_x64.efi lacks an MZ/PE header'; return 1; }
    magic=$(od -An -tx1 -N2 -- "$driver" 2>/dev/null | tr -d '[:space:]')
    [[ $magic == 4d5a ]] || { fail 'Upstream ext4_x64.efi lacks an MZ/PE header'; return 1; }
    if have file; then
        leap16_is_x86_64_efi_application "$efi" || { fail 'Upstream refind_x64.efi is not an x86-64 EFI application'; return 1; }
        leap16_is_x86_64_efi_application "$driver" || { fail 'Upstream ext4_x64.efi is not an x86-64 EFI application'; return 1; }
    fi
    ok "Validated upstream rEFInd ${LEAP16_R66_REFIND_VERSION} x64 binary, ext4 driver, config sample and icon tree"
}

leap16_r66_acquire_refind_bundle() {
    local supplied=${BOOTLOADER_SWITCHER_REFIND_ARCHIVE:-} expected=${BOOTLOADER_SWITCHER_REFIND_ARCHIVE_SHA256:-}
    local archive extract hash
    leap16_r66_cleanup_refind_bundle
    have unzip || { fail 'unzip is required for the upstream rEFInd binary archive'; return 1; }
    have sha256sum || { fail 'sha256sum is required for rEFInd archive evidence'; return 1; }

    LEAP16_R66_REFIND_WORKDIR=$(mktemp -d) || return 1
    archive="$LEAP16_R66_REFIND_WORKDIR/$LEAP16_R66_REFIND_ARCHIVE_NAME"
    extract="$LEAP16_R66_REFIND_WORKDIR/extract"
    mkdir -p -- "$extract" || { leap16_r66_cleanup_refind_bundle; return 1; }

    if [[ -n $supplied ]]; then
        leap16_r66_refind_archive_path_is_safe "$supplied" || { leap16_r66_cleanup_refind_bundle; return 1; }
        cp -- "$supplied" "$archive" || { leap16_r66_cleanup_refind_bundle; return 1; }
        ok 'Using user-supplied local upstream rEFInd binary archive'
    else
        leap16_r66_download_refind_archive "$archive" || { leap16_r66_cleanup_refind_bundle; fail 'Could not download the fixed upstream rEFInd binary archive'; return 1; }
    fi

    hash=$(sha256sum -- "$archive" | awk '{print $1}')
    [[ $hash =~ ^[0-9a-f]{64}$ ]] || { leap16_r66_cleanup_refind_bundle; fail 'Could not hash the rEFInd archive'; return 1; }
    if [[ -n $expected ]]; then
        expected=${expected,,}
        [[ $expected =~ ^[0-9a-f]{64}$ ]] || { leap16_r66_cleanup_refind_bundle; fail 'BOOTLOADER_SWITCHER_REFIND_ARCHIVE_SHA256 is not a SHA-256 digest'; return 1; }
        [[ $hash == "$expected" ]] || { leap16_r66_cleanup_refind_bundle; fail 'Local rEFInd archive SHA-256 does not match BOOTLOADER_SWITCHER_REFIND_ARCHIVE_SHA256'; return 1; }
        ok "Verified user-pinned rEFInd archive SHA-256: $hash"
    else
        info "rEFInd archive SHA-256 for this transaction: $hash"
    fi
    LEAP16_R66_REFIND_ARCHIVE_SHA256=$hash

    unzip -tq -- "$archive" >/dev/null || { leap16_r66_cleanup_refind_bundle; fail 'rEFInd binary ZIP integrity test failed'; return 1; }
    leap16_r66_refind_archive_names_safe "$archive" || { leap16_r66_cleanup_refind_bundle; return 1; }

    # Extract only the immutable x64 payload required by this backend.  Do not
    # run refind-install or any package post-install scripts.
    unzip -qq -- "$archive" \
        "$LEAP16_R66_REFIND_ARCHIVE_ROOT/refind_x64.efi" \
        "$LEAP16_R66_REFIND_ARCHIVE_ROOT/drivers_x64/ext4_x64.efi" \
        "$LEAP16_R66_REFIND_ARCHIVE_ROOT/refind.conf-sample" \
        "$LEAP16_R66_REFIND_ARCHIVE_ROOT/icons/*" \
        -d "$extract" || { leap16_r66_cleanup_refind_bundle; fail 'Could not extract the required rEFInd x64 payload'; return 1; }

    LEAP16_R66_REFIND_BUNDLE_ROOT="$extract/$LEAP16_R66_REFIND_ARCHIVE_ROOT"
    leap16_r66_verify_refind_bundle "$LEAP16_R66_REFIND_BUNDLE_ROOT" || { leap16_r66_cleanup_refind_bundle; return 1; }
}

# r66 must never call the RPM/package installer for rEFInd.  The upstream RPM
# invokes installation logic that can register firmware state outside our
# source-first/create-only transaction boundary.
leap16_r64_install_refind_package() {
    fail 'r66 forbids RPM/package-script rEFInd staging; use the manually controlled upstream binary-archive path'
    return 1
}

leap16_r66_install_refind_tree() {
    local root=$LEAP16_R66_REFIND_BUNDLE_ROOT dst="${ESP_MOUNT%/}/EFI/refind"
    [[ -n $root && -d $root ]] || { fail 'Validated rEFInd bundle is unavailable at the write boundary'; return 1; }
    sudo install -d -m 0755 -- "$dst" "$dst/drivers_x64" "$dst/icons" || return 1
    sudo install -m 0644 -- "$root/refind_x64.efi" "$dst/refind_x64.efi" || return 1
    sudo install -m 0644 -- "$root/drivers_x64/ext4_x64.efi" "$dst/drivers_x64/ext4_x64.efi" || return 1
    sudo install -m 0644 -- "$root/refind.conf-sample" "$dst/refind.conf" || return 1
    # The icon tree is immutable adapter payload.  Copy regular files only;
    # bundle validation already rejected symlinks.
    while IFS= read -r -d '' item; do
        local rel=${item#"$root/icons/"}
        sudo install -d -m 0755 -- "$dst/icons/$(dirname -- "$rel")" || return 1
        sudo install -m 0644 -- "$item" "$dst/icons/$rel" || return 1
    done < <(find "$root/icons" -type f -print0)
    printf '%s\n' "$LEAP16_R66_REFIND_DOWNLOAD_MARKER" | sudo tee "$dst/.opensuse-bootloader-switcher-source" >/dev/null || return 1
    ok 'Installed rEFInd x64 payload manually; no package post-install script or firmware mutation was executed'
}

leap16_r66_patch_refind_config() {
    local conf="${ESP_MOUNT%/}/EFI/refind/refind.conf" tmp out
    (sudo -n test -f "$conf" 2>/dev/null || [[ -f $conf ]]) || { fail 'Manually staged rEFInd refind.conf is missing'; return 1; }
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
    ok 'Applied Leap-native rEFInd direct-kernel scanner policy to the manually staged config'
}

# Preserve the effective r65/r64 implementation for non-Leap contexts.
if declare -F r26_stage_refind_target >/dev/null 2>&1; then
    eval "$(declare -f r26_stage_refind_target | sed '1s/r26_stage_refind_target/r26_stage_refind_target_pre_leap16_r66/')"
fi
r26_stage_refind_target() {
    local source_id=${1^^} original_order=$2 reference=$3 target_id
    local expected_source expected_mount expected_fstype expected_uuid next rc=0
    if ! is_leap16; then r26_stage_refind_target_pre_leap16_r66 "$@"; return $?; fi
    expected_source=$ESP_SOURCE; expected_mount=$ESP_MOUNT; expected_fstype=$ESP_FSTYPE; expected_uuid=$ESP_UUID

    # A validated rEFInd backup is already self-contained.  Do not introduce
    # an unnecessary network/upstream dependency into restore: restore its
    # exact immutable tree directly into the clean target namespace, then let
    # the normal create-only/source-first transaction earn fresh PreviousBoot.
    if [[ -n ${LEAP16_R64_RESTORE_DIR:-} ]]; then
        leap16_r64_restore_refind_payload_at_write_boundary "$LEAP16_R64_RESTORE_DIR" "$reference" || rc=$?
        if ((rc == 0)); then r32_verify_refind_post_install_esp "$expected_source" "$expected_mount" "$expected_fstype" "$expected_uuid" || rc=$?; fi
    else
        leap16_r66_acquire_refind_bundle || return 1
        leap16_r66_install_refind_tree || rc=$?
        if ((rc == 0)); then r32_verify_refind_post_install_esp "$expected_source" "$expected_mount" "$expected_fstype" "$expected_uuid" || rc=$?; fi
        if ((rc == 0)); then leap16_r66_patch_refind_config || rc=$?; fi
        if ((rc == 0)); then r26_write_refind_linux_conf "$reference" || rc=$?; fi
    fi

    if ((rc == 0)); then
        r28_create_alias_create_only "$LEAP16_R64_REFIND_LABEL" "$LEAP16_R64_REFIND_EFI" || rc=$?
    fi
    if ((rc == 0)); then
        target_id=${R28_CREATED_ALIAS_ID^^}
        [[ $target_id =~ ^[0-9A-F]{4}$ ]] || { fail 'create-only did not publish a valid canonical rEFInd Boot####'; rc=1; }
    fi
    if ((rc == 0)); then
        set_source_first_boot_order "$source_id" "$target_id" "$original_order" || rc=$?
    fi
    if ((rc == 0)); then
        next=$(pending_bootnext_id 2>/dev/null || true)
        [[ -z $next ]] || { fail "BootNext appeared during manual create-only rEFInd staging: Boot${next^^}"; rc=1; }
    fi
    if ((rc == 0)); then r26_restore_source_fallback_after_target_stage || rc=$?; fi
    if ((rc == 0)); then adapter_target_validate refind || rc=$?; fi
    if ((rc == 0)); then r26_record_target_adapter refind || rc=$?; fi
    if ((rc == 0)); then
        R26_STAGED_TARGET_ID=$target_id
        leap16_r64_write_meta "${BOOTLOADER}:refind" || rc=$?
    fi

    leap16_r66_cleanup_refind_bundle
    ((rc == 0)) || return "$rc"
    if [[ -n ${LEAP16_R64_RESTORE_DIR:-} ]]; then
        ok "Staged canonical Leap rEFInd target as parked Boot$R26_STAGED_TARGET_ID from the exact validated backup payload"
    else
        ok "Staged canonical Leap rEFInd target as parked Boot$R26_STAGED_TARGET_ID from controlled upstream binary payload"
    fi
}

# Add acquisition/create-only capability checks to the existing r64 rEFInd
# edge preflight while preserving every already-proven source/target gate.
if declare -F leap16_r64_preflight >/dev/null 2>&1; then
    eval "$(declare -f leap16_r64_preflight | sed '1s/leap16_r64_preflight/leap16_r64_preflight_pre_leap16_r66/')"
fi
leap16_r64_preflight() {
    local target=$1
    leap16_r64_preflight_pre_leap16_r66 "$@" || return $?
    if [[ $target == refind ]]; then
        # Keep the read-only identity preflight compatible with self-contained
        # backup restore.  Live-switch archive prerequisites are checked at the
        # write boundary before any target ESP/NVRAM state is created.
        efibootmgr --help 2>&1 | grep -q -- '--create-only' || { fail 'efibootmgr lacks --create-only required for parked rEFInd creation'; return 1; }
        ok 'r66 rEFInd create-only prerequisite is available; live archive acquisition is validated before target mutation at the write boundary'
    fi
}


# r64's first draft assumed an installed RPM would always exist and therefore
# required a `refind-*` line in package-state.txt.  r66 deliberately stages
# from the upstream binary ZIP without installing an RPM, so backup identity is
# instead proven by either the legacy package snapshot OR the exact r66 source
# marker captured inside the immutable EFI/refind tree.
leap16_r64_refind_backup_payload_valid() {
    local dir=$1 reference=${2:-} root conf efi linuxconf driver options value low m marker pkg_ok=0 marker_ok=0
    root=$(leap16_r64_refind_backup_root "$dir") || { BACKUP_VALIDATION_REASON='invalid rEFInd backup ESP mount metadata'; return 1; }
    conf="$root/refind.conf"; efi="$root/refind_x64.efi"; driver="$root/drivers_x64/ext4_x64.efi"; linuxconf="$dir/files/boot/refind_linux.conf"
    [[ -d $root && ! -L $root ]] || { BACKUP_VALIDATION_REASON='rEFInd backup is missing a safe EFI/refind tree'; return 1; }
    [[ -f $conf && ! -L $conf && -f $efi && ! -L $efi && -f $linuxconf && ! -L $linuxconf ]] \
        || { BACKUP_VALIDATION_REASON='rEFInd backup is missing canonical EFI/config/refind_linux.conf state'; return 1; }
    [[ ! -e $root/vars && ! -L $root/vars ]] || { BACKUP_VALIDATION_REASON='mutable EFI/refind/vars must not be present in an immutable rEFInd backup'; return 1; }
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
    grep -Eq '^refind-[^[:space:]]+' "$dir/package-state.txt" && pkg_ok=1
    marker="$root/.opensuse-bootloader-switcher-source"
    if [[ -f $marker && ! -L $marker ]] && [[ $(cat -- "$marker" 2>/dev/null) == "$LEAP16_R66_REFIND_DOWNLOAD_MARKER" ]]; then marker_ok=1; fi
    ((pkg_ok || marker_ok)) || { BACKUP_VALIDATION_REASON='rEFInd backup has neither a legacy package identity nor the exact r66 controlled-binary source marker'; return 1; }
    return 0
}

if declare -F leap16_r64_plan >/dev/null 2>&1; then
    eval "$(declare -f leap16_r64_plan | sed '1s/leap16_r64_plan/leap16_r64_plan_pre_leap16_r66/')"
fi
leap16_r64_plan() {
    local current=$1 target=$2
    if [[ $target != refind ]]; then leap16_r64_plan_pre_leap16_r66 "$@"; return $?; fi
    printf '\nLeap rEFInd transaction plan:\n'
    printf '  1. Freeze exact source files, generic-fallback state and the complete firmware table.\n'
    printf '  2. Acquire fixed upstream rEFInd %s binary ZIP (or explicit local ZIP), validate its x64 payload, and never execute RPM/refind-install package scripts.\n' "$LEAP16_R66_REFIND_VERSION"
    printf '  3. Manually stage only refind_x64.efi, ext4_x64.efi, config and icons; write source-cmdline refind_linux.conf; exclude EFI source/reference namespaces.\n'
    printf '  4. Create exactly one parked canonical rEFInd Boot#### with efibootmgr --create-only, keep %s persistent-first, then arm exactly one BootNext.\n' "$(bootloader_display_name "$current")"
    printf '  5. Require canonical rEFInd BootCurrent + PreviousBoot direct-kernel proof. Only then remove bounded source aliases/files. rEFInd does not claim EFI/BOOT.\n'
    printf '  Rollback before proof removes only transaction-owned target state and restores the frozen source/fallback topology.\n'
}

# Release-accurate matrix with both safe-fail hardware discoveries retained.
leap16_r64_print_matrix() {
    cat <<'MATRIX'
openSUSE Leap 16 bootloader matrix — leap16-r66

Legend:
  HW-PROVEN       completed on real hardware before r64
  HW-PENDING      implemented + regression-covered; requires a successful real rEFInd boot transaction
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

rEFInd ACQUISITION CONTRACT
  fixed upstream SourceForge binary ZIP 0.14.2 -> manual immutable x64 payload staging -> efibootmgr --create-only
  no rEFInd RPM/package post-install scripts and no refind-install execution are permitted in r66
  BOOTLOADER_SWITCHER_REFIND_ARCHIVE=/absolute/refind-bin-0.14.2.zip may supply a local archive
  BOOTLOADER_SWITCHER_REFIND_ARCHIVE_SHA256=<digest> may additionally pin a user-supplied archive

HARDWARE ATTEMPTS INVOLVING rEFInd
  GRUB2 -> rEFInd  r64: SAFE-FAIL before candidate commit (zypper option-scope bug); not a boot proof
  GRUB2 -> rEFInd  r65: SAFE-FAIL before candidate commit (Leap repos have no refind provider); not a boot proof
MATRIX
}
