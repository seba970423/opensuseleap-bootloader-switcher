#!/usr/bin/env bash

# r23 completion layer
# --------------------
# Adds the missing half of the transaction engine:
#   * CachyOS-themed GRUB -> Limine migration with the same BootNext/runtime/
#     ownership-gated automatic finalization model as Limine -> GRUB;
#   * validated Limine backup restore, including safe reconstruction of legacy
#     v3 backups and self-contained payload restoration for new v4 backups;
#   * exact CachyOS Limine presentation parity (palette + limine-splash.png).

R23_LIMINE_SPLASH_SOURCE=/usr/share/wallpapers/cachyos-wallpapers/limine-splash.png
R23_LIMINE_SPLASH_NAME=limine-splash.png

r23_theme_snapshot_root() {
    printf '%s\n' "${PENDING_TRANSACTION_SNAPSHOT_DIR:-${TRANSACTION_SNAPSHOT_DIR:-}}"
}

r23_limine_theme_marker_path() {
    printf '%s/limine-theme-required\n' "$(r23_theme_snapshot_root)"
}

r23_limine_theme_manifest_path() {
    printf '%s/limine-theme.tsv\n' "$(r23_theme_snapshot_root)"
}

r23_source_grub_dir_manifest_path() {
    printf '%s/source-grub-dir.tsv\n' "$PENDING_TRANSACTION_SNAPSHOT_DIR"
}

r23_source_grub_efi_dir_manifest_path() {
    printf '%s/source-grub-efi-dir.tsv\n' "$PENDING_TRANSACTION_SNAPSHOT_DIR"
}

r23_source_grub_default_record_path() {
    printf '%s/source-grub-default.tsv\n' "$PENDING_TRANSACTION_SNAPSHOT_DIR"
}

r23_prestage_splash_record_path() {
    local root=${1:-${PENDING_TRANSACTION_SNAPSHOT_DIR:-${TRANSACTION_SNAPSHOT_DIR:-}}}
    printf '%s/prestage-limine-splash.tsv\n' "$root"
}

r23_prestage_splash_snapshot_path() {
    local root=${1:-${PENDING_TRANSACTION_SNAPSHOT_DIR:-${TRANSACTION_SNAPSHOT_DIR:-}}}
    printf '%s/limine-splash.before\n' "$root"
}

r23_prestage_limine_efi_record_path() {
    local root=${1:-${PENDING_TRANSACTION_SNAPSHOT_DIR:-${TRANSACTION_SNAPSHOT_DIR:-}}}
    printf '%s/prestage-limine-efi.tsv\n' "$root"
}

r23_prestage_limine_efi_archive_path() {
    local root=${1:-${PENDING_TRANSACTION_SNAPSHOT_DIR:-${TRANSACTION_SNAPSHOT_DIR:-}}}
    printf '%s/prestage-limine-efi.tar\n' "$root"
}

r23_prestage_limine_efi_manifest_path() {
    local root=${1:-${PENDING_TRANSACTION_SNAPSHOT_DIR:-${TRANSACTION_SNAPSHOT_DIR:-}}}
    printf '%s/prestage-limine-efi-tree.tsv\n' "$root"
}

r23_target_limine_efi_manifest_path() {
    printf '%s/target-limine-efi-dir.tsv\n' "$(r23_theme_snapshot_root)"
}

r23_snapshot_prestage_limine_splash() {
    local root=${TRANSACTION_SNAPSHOT_DIR:-} splash="$ESP_MOUNT/$R23_LIMINE_SPLASH_NAME" record snap hash
    [[ -n $root && -d $root ]] || { fail 'Transaction snapshot directory is unavailable for pre-stage Limine splash ownership'; return 1; }
    record=$(r23_prestage_splash_record_path "$root")
    snap=$(r23_prestage_splash_snapshot_path "$root")
    if sudo -n test -f "$splash" 2>/dev/null || [[ -f $splash ]]; then
        hash=$(sudo -n sha256sum -- "$splash" 2>/dev/null | awk '{print $1}' || sha256sum -- "$splash" 2>/dev/null | awk '{print $1}' || true)
        [[ $hash =~ ^[0-9A-Fa-f]{64}$ ]] || { fail 'Could not hash the pre-stage limine-splash.png'; return 1; }
        if [[ -r $splash ]]; then cat -- "$splash" >"$snap"; else sudo -n cat -- "$splash" >"$snap"; fi || return 1
        [[ $(sha256sum -- "$snap" | awk '{print $1}') == "$hash" ]] || { fail 'Pre-stage Limine splash snapshot hash mismatch'; return 1; }
        printf 'existed\t1\nhash\t%s\n' "$hash" >"$record" || return 1
    else
        printf 'existed\t0\nhash\t\n' >"$record" || return 1
    fi
    chmod 600 -- "$record" "$snap" 2>/dev/null || true
    ok 'Recorded pre-stage limine-splash.png ownership for rollback safety'
}

r23_restore_prestage_limine_splash() {
    local root=$1 splash="$ESP_MOUNT/$R23_LIMINE_SPLASH_NAME" record snap existed expected current
    [[ -n $root ]] || return 0
    record=$(r23_prestage_splash_record_path "$root")
    snap=$(r23_prestage_splash_snapshot_path "$root")
    [[ -f $record ]] || return 0
    existed=$(awk -F'\t' '$1=="existed"{print $2; exit}' "$record")
    expected=$(awk -F'\t' '$1=="hash"{print $2; exit}' "$record")
    if [[ $existed == 1 ]]; then
        [[ -f $snap && $expected =~ ^[0-9A-Fa-f]{64}$ ]] || { fail 'Pre-stage Limine splash rollback snapshot is incomplete'; return 1; }
        sudo install -o root -g root -m 0644 -- "$snap" "$splash" || return 1
        current=$(sudo -n sha256sum -- "$splash" 2>/dev/null | awk '{print $1}' || true)
        [[ $current == "$expected" ]] || { fail 'Could not restore the exact pre-stage Limine splash'; return 1; }
        ok 'Restored pre-stage limine-splash.png'
    else
        sudo rm -f -- "$splash" || return 1
        ok 'Removed transaction-created limine-splash.png'
    fi
}

r23_snapshot_prestage_limine_efi_dir() {
    local root=${TRANSACTION_SNAPSHOT_DIR:-} dir="$ESP_MOUNT/EFI/LIMINE" record archive manifest hash
    [[ -n $root && -d $root ]] || { fail 'Transaction snapshot directory is unavailable for pre-stage Limine EFI ownership'; return 1; }
    record=$(r23_prestage_limine_efi_record_path "$root")
    archive=$(r23_prestage_limine_efi_archive_path "$root")
    manifest=$(r23_prestage_limine_efi_manifest_path "$root")
    if sudo -n test -d "$dir" 2>/dev/null || [[ -d $dir ]]; then
        # A prior finalized Limine -> GRUB transaction may intentionally leave
        # unproven inactive files in EFI/LIMINE. A new explicit Limine target
        # transaction may replace that namespace, but rollback must be exact.
        sudo tar -C "$ESP_MOUNT/EFI" -cpf - LIMINE >"$archive" || { fail 'Could not archive the pre-stage EFI/LIMINE directory'; return 1; }
        hash=$(sha256sum -- "$archive" | awk '{print $1}')
        [[ $hash =~ ^[0-9A-Fa-f]{64}$ ]] || { fail 'Could not hash the pre-stage EFI/LIMINE archive'; return 1; }
        write_privileged_tree_manifest "$dir" "$manifest" || { fail 'Could not manifest the pre-stage EFI/LIMINE directory'; return 1; }
        printf 'existed\t1\narchive_sha256\t%s\n' "$hash" >"$record" || return 1
        ok 'Snapshotted the pre-existing inactive EFI/LIMINE namespace for exact rollback'
    else
        printf 'existed\t0\narchive_sha256\t\n' >"$record" || return 1
        : >"$manifest" || return 1
        ok 'Recorded that no EFI/LIMINE directory existed before staging'
    fi
    chmod 600 -- "$record" "$archive" "$manifest" 2>/dev/null || true
}

r23_copy_prestage_limine_efi_snapshot() {
    local source_root=$1 out_root=$2 f
    mkdir -p -- "$out_root" || return 1
    for f in prestage-limine-efi.tsv prestage-limine-efi.tar prestage-limine-efi-tree.tsv; do
        [[ -e $source_root/$f ]] && cp -a -- "$source_root/$f" "$out_root/$f" || true
    done
}

r23_restore_prestage_limine_efi_dir() {
    local root=$1 dir="$ESP_MOUNT/EFI/LIMINE" record archive manifest existed expected actual
    record=$(r23_prestage_limine_efi_record_path "$root")
    archive=$(r23_prestage_limine_efi_archive_path "$root")
    manifest=$(r23_prestage_limine_efi_manifest_path "$root")
    [[ -f $record ]] || return 0
    existed=$(awk -F'\t' '$1=="existed"{print $2; exit}' "$record")
    expected=$(awk -F'\t' '$1=="archive_sha256"{print $2; exit}' "$record")
    if [[ $existed == 1 ]]; then
        [[ -f $archive && -s $manifest && $expected =~ ^[0-9A-Fa-f]{64}$ ]] || { fail 'Pre-stage EFI/LIMINE rollback snapshot is incomplete'; return 1; }
        actual=$(sha256sum -- "$archive" | awk '{print $1}')
        [[ $actual == "$expected" ]] || { fail 'Pre-stage EFI/LIMINE rollback archive hash mismatch'; return 1; }
        sudo rm -rf -- "$dir" || return 1
        sudo mkdir -p -- "$ESP_MOUNT/EFI" || return 1
        sudo tar -C "$ESP_MOUNT/EFI" -xpf "$archive" || return 1
        pending_verify_tree_manifest "$dir" "$manifest" || { fail 'Restored EFI/LIMINE namespace does not match the pre-stage manifest'; return 1; }
        ok 'Restored the exact pre-stage EFI/LIMINE namespace'
    else
        sudo rm -rf -- "$dir" || return 1
        ok 'Removed transaction-created EFI/LIMINE namespace'
    fi
}

r23_write_cachyos_limine_theme_base() {
    local conf=$1 machine_id splash_src=${2:-$R23_LIMINE_SPLASH_SOURCE}
    machine_id=$(cat /etc/machine-id 2>/dev/null || true)
    [[ -n $machine_id ]] || { fail 'Machine ID is unavailable while writing the CachyOS Limine theme'; return 1; }
    [[ -r $splash_src ]] || { fail "CachyOS Limine splash source is missing/unreadable: $splash_src"; return 1; }

    cat >"$conf" <<EOF_THEME
timeout: 5
default_entry: 2
remember_last_entry: yes

# CachyOS Limine theme
# Author: diegons490 (https://github.com/diegons490/cachyos-limine-theme)
term_palette: 1e1e2e;f38ba8;a6e3a1;f9e2af;89b4fa;f5c2e7;94e2d5;cdd6f4
term_palette_bright: 585b70;f38ba8;a6e3a1;f9e2af;89b4fa;f5c2e7;94e2d5;cdd6f4
term_background: ffffffff
term_foreground: cdd6f4
term_background_bright: ffffffff
term_foreground_bright: cdd6f4
interface_branding:
wallpaper: boot():/$R23_LIMINE_SPLASH_NAME

comment: machine-id=$machine_id
/+CachyOS
EOF_THEME
}

r23_install_cachyos_limine_splash() {
    local src=${1:-$R23_LIMINE_SPLASH_SOURCE} dst="$ESP_MOUNT/$R23_LIMINE_SPLASH_NAME"
    [[ -r $src ]] || { fail "CachyOS Limine splash source is missing/unreadable: $src"; return 1; }
    sudo install -o root -g root -m 0644 -- "$src" "$dst" || return 1
    ok "Installed CachyOS Limine splash: $dst"
}

validate_cachyos_limine_theme() {
    local conf="${ESP_MOUNT:-/boot}/limine.conf" splash="${ESP_MOUNT:-/boot}/$R23_LIMINE_SPLASH_NAME" failures=0
    printf '\nCachyOS Limine theme validation:\n'
    local required=(
        '# CachyOS Limine theme'
        'term_palette: 1e1e2e;f38ba8;a6e3a1;f9e2af;89b4fa;f5c2e7;94e2d5;cdd6f4'
        'term_palette_bright: 585b70;f38ba8;a6e3a1;f9e2af;89b4fa;f5c2e7;94e2d5;cdd6f4'
        'term_background: ffffffff'
        'term_foreground: cdd6f4'
        'term_background_bright: ffffffff'
        'term_foreground_bright: cdd6f4'
        'interface_branding:'
        "wallpaper: boot():/$R23_LIMINE_SPLASH_NAME"
    ) line

    if [[ -r $conf ]] || sudo -n test -r "$conf" 2>/dev/null; then
        ok "Limine config is available for theme validation: $conf"
    else
        fail "Limine config is unavailable: $conf"; ((failures++))
    fi
    for line in "${required[@]}"; do
        if grep -Fqx -- "$line" "$conf" 2>/dev/null || sudo -n grep -Fqx -- "$line" "$conf" 2>/dev/null; then
            :
        else
            fail "Missing CachyOS Limine theme line: $line"; ((failures++))
        fi
    done
    if ((failures == 0)); then ok 'CachyOS Limine palette/branding block matches the captured installer reference'; fi

    if [[ -f $splash && -r $splash ]] || sudo -n test -f "$splash" 2>/dev/null; then
        ok "CachyOS Limine splash exists: $splash"
    else
        fail "CachyOS Limine splash is missing: $splash"; ((failures++))
    fi

    if [[ -r $R23_LIMINE_SPLASH_SOURCE ]]; then
        local src_hash dst_hash
        src_hash=$(sha256sum -- "$R23_LIMINE_SPLASH_SOURCE" 2>/dev/null | awk '{print $1}' || true)
        dst_hash=$(sudo -n sha256sum -- "$splash" 2>/dev/null | awk '{print $1}' || sha256sum -- "$splash" 2>/dev/null | awk '{print $1}' || true)
        if [[ -n $src_hash && $src_hash == "$dst_hash" ]]; then
            ok 'ESP splash is byte-identical to the installed CachyOS wallpaper asset'
        else
            warn 'ESP splash differs from the currently installed CachyOS wallpaper asset; transaction/backup hash ownership must prove the staged image'
        fi
    else
        warn 'Installed CachyOS wallpaper source is unavailable; validating the ESP splash by transaction/backup hash only'
    fi
    printf '  Theme summary: %d failure(s)\n' "$failures"
    ((failures == 0))
}

r23_record_limine_theme_manifest() {
    local snapshot_root
    snapshot_root=$(r23_theme_snapshot_root)
    [[ -n $snapshot_root && -d $snapshot_root ]] || { fail 'Transaction snapshot directory is unavailable for Limine theme ownership'; return 1; }
    local splash="$ESP_MOUNT/$R23_LIMINE_SPLASH_NAME" hash marker manifest
    hash=$(sudo -n sha256sum -- "$splash" 2>/dev/null | awk '{print $1}' || sha256sum -- "$splash" 2>/dev/null | awk '{print $1}' || true)
    [[ $hash =~ ^[0-9A-Fa-f]{64}$ ]] || { fail 'Could not hash the staged CachyOS Limine splash'; return 1; }
    marker=$(r23_limine_theme_marker_path)
    manifest=$(r23_limine_theme_manifest_path)
    printf 'required\n' >"$marker" || return 1
    printf 'splash_sha256\t%s\n' "$hash" >"$manifest" || return 1
    chmod 600 -- "$marker" "$manifest" 2>/dev/null || true
    ok 'Recorded CachyOS Limine theme/splash identity in the transaction manifest'
}

r23_limine_theme_required() {
    [[ ${PENDING_SOURCE:-} == grub && ${PENDING_TARGET:-} == limine ]] || return 1
    [[ -f $(r23_limine_theme_marker_path) && -f $(r23_limine_theme_manifest_path) ]]
}

r23_verify_limine_theme_manifest() {
    r23_limine_theme_required || { fail 'CachyOS Limine theme ownership marker is missing'; return 1; }
    local expected actual splash="$ESP_MOUNT/$R23_LIMINE_SPLASH_NAME"
    expected=$(awk -F'\t' '$1=="splash_sha256"{print $2; exit}' "$(r23_limine_theme_manifest_path)" 2>/dev/null || true)
    [[ $expected =~ ^[0-9A-Fa-f]{64}$ ]] || { fail 'Recorded Limine splash hash is invalid'; return 1; }
    actual=$(sudo -n sha256sum -- "$splash" 2>/dev/null | awk '{print $1}' || sha256sum -- "$splash" 2>/dev/null | awk '{print $1}' || true)
    [[ -n $actual && $actual == "$expected" ]] || { fail 'CachyOS Limine splash changed since candidate creation'; return 1; }
    ok 'CachyOS Limine splash still matches the transaction manifest'
}

# Save the source GRUB config/EFI trees so finalization can remove only exact,
# unchanged source-owned state. This is independent of the optional user backup.
r23_snapshot_source_grub_cleanup_ownership() {
    [[ -n ${TRANSACTION_SNAPSHOT_DIR:-} && -d $TRANSACTION_SNAPSHOT_DIR ]] || { fail 'Transaction snapshot directory is unavailable for source GRUB ownership'; return 1; }
    local grub_dir=/boot/grub efi_dir record hash
    efi_dir=$(dirname -- "$OLD_GRUB_EFI_RESOLVED")
    sudo -n test -d "$grub_dir" 2>/dev/null || { fail 'Source /boot/grub directory is missing before staging'; return 1; }
    sudo -n test -d "$efi_dir" 2>/dev/null || { fail "Source GRUB EFI directory is missing before staging: $efi_dir"; return 1; }
    write_privileged_tree_manifest "$grub_dir" "$TRANSACTION_SNAPSHOT_DIR/source-grub-dir.tsv" || { fail 'Could not record source /boot/grub ownership manifest'; return 1; }
    write_privileged_tree_manifest "$efi_dir" "$TRANSACTION_SNAPSHOT_DIR/source-grub-efi-dir.tsv" || { fail 'Could not record source GRUB EFI directory manifest'; return 1; }
    record="$TRANSACTION_SNAPSHOT_DIR/source-grub-default.tsv"
    if [[ -f /etc/default/grub ]] || sudo -n test -f /etc/default/grub 2>/dev/null; then
        hash=$(sha256sum /etc/default/grub 2>/dev/null | awk '{print $1}' || sudo -n sha256sum /etc/default/grub 2>/dev/null | awk '{print $1}' || true)
        [[ $hash =~ ^[0-9A-Fa-f]{64}$ ]] || { fail 'Could not hash source /etc/default/grub'; return 1; }
        printf 'present\t1\nhash\t%s\npath\t/etc/default/grub\n' "$hash" >"$record" || return 1
    else
        printf 'present\t0\nhash\t\npath\t/etc/default/grub\n' >"$record" || return 1
    fi
    chmod 600 -- "$TRANSACTION_SNAPSHOT_DIR"/source-grub-*.tsv 2>/dev/null || true
    ok 'Recorded exact source GRUB config/EFI ownership for post-proof cleanup'
}

r23_verify_source_grub_cleanup_ownership() {
    local dm em rec present expected actual
    dm=$(r23_source_grub_dir_manifest_path)
    em=$(r23_source_grub_efi_dir_manifest_path)
    rec=$(r23_source_grub_default_record_path)
    [[ -s $dm && -s $em && -f $rec ]] || { fail 'Source GRUB cleanup ownership manifests are missing'; return 1; }
    pending_verify_tree_manifest /boot/grub "$dm" || { fail 'Source /boot/grub changed since staging'; return 1; }
    pending_verify_tree_manifest "$(dirname -- "$PENDING_OLD_GRUB_EFI_RESOLVED")" "$em" || { fail 'Source GRUB EFI directory changed since staging'; return 1; }
    present=$(awk -F'\t' '$1=="present"{print $2; exit}' "$rec")
    expected=$(awk -F'\t' '$1=="hash"{print $2; exit}' "$rec")
    if [[ $present == 1 ]]; then
        actual=$(sha256sum /etc/default/grub 2>/dev/null | awk '{print $1}' || sudo -n sha256sum /etc/default/grub 2>/dev/null | awk '{print $1}' || true)
        [[ -n $actual && $actual == "$expected" ]] || { fail 'Source /etc/default/grub changed since staging'; return 1; }
    else
        [[ ! -e /etc/default/grub ]] || { fail '/etc/default/grub appeared after staging'; return 1; }
    fi
    ok 'Source GRUB cleanup ownership still matches the pre-stage transaction snapshot'
}

# Override the r22 source-artifact snapshot to additionally record cleanup
# ownership while GRUB is still the verified active source.
eval "$(declare -f snapshot_source_boot_artifacts | sed '1s/snapshot_source_boot_artifacts/snapshot_source_boot_artifacts_r22/')"
snapshot_source_boot_artifacts() {
    snapshot_source_boot_artifacts_r22 "$@" || return $?
    if [[ ${BOOTLOADER:-} == grub ]]; then
        r23_snapshot_source_grub_cleanup_ownership || return 1
        r23_snapshot_prestage_limine_splash || return 1
        r23_snapshot_prestage_limine_efi_dir || return 1
    fi
}

# Generate the exact CachyOS/Calamares-style themed Limine base instead of the
# generic limine-entry-tool presentation.
write_limine_candidate_policy() {
    local cmdline tmp conf_tmp
    [[ ! -e /etc/default/limine ]] || { fail '/etc/default/limine appeared after preflight; refusing to overwrite it'; return 1; }
    [[ ! -e "$ESP_MOUNT/limine.conf" ]] || { fail 'limine.conf appeared after preflight; refusing to overwrite it'; return 1; }
    cmdline=$(cat /proc/cmdline 2>/dev/null || true)
    [[ -n $cmdline ]] || { fail 'Running kernel cmdline is empty; cannot materialize Limine policy'; return 1; }
    [[ $cmdline != *$'\n'* && $cmdline != *$'\r'* ]] || { fail 'Running kernel cmdline contains a line break; refusing unsafe policy serialization'; return 1; }
    [[ -n $ESP_MOUNT ]] || { fail 'ESP mountpoint is unresolved'; return 1; }
    [[ -r $R23_LIMINE_SPLASH_SOURCE ]] || { fail "CachyOS Limine splash asset is unavailable: $R23_LIMINE_SPLASH_SOURCE"; return 1; }

    tmp=$(mktemp) || return 1
    conf_tmp=$(mktemp) || { rm -f -- "$tmp"; return 1; }
    chmod 600 -- "$tmp" "$conf_tmp" 2>/dev/null || true
    printf 'ESP_PATH="%s"\n' "$ESP_MOUNT" >"$tmp"
    printf 'KERNEL_CMDLINE[default]+=%s\n' "$cmdline" >>"$tmp"
    printf 'BOOT_ORDER="*, *lts, *fallback, Snapshots"\n' >>"$tmp"
    r23_write_cachyos_limine_theme_base "$conf_tmp" "$R23_LIMINE_SPLASH_SOURCE" || { rm -f -- "$tmp" "$conf_tmp"; return 1; }

    sudo install -o root -g root -m 0644 -- "$tmp" /etc/default/limine || { rm -f -- "$tmp" "$conf_tmp"; return 1; }
    sudo install -o root -g root -m 0644 -- "$conf_tmp" "$ESP_MOUNT/limine.conf" || { rm -f -- "$tmp" "$conf_tmp"; return 1; }
    rm -f -- "$tmp" "$conf_tmp"
    r23_install_cachyos_limine_splash || return 1
    LIMINE_DEFAULT_CREATED=1
    LIMINE_DEFAULT_HASH=$(sha256sum /etc/default/limine 2>/dev/null | awk '{print $1}' || sudo -n sha256sum /etc/default/limine 2>/dev/null | awk '{print $1}' || true)
    [[ -n $LIMINE_DEFAULT_HASH ]] || { fail 'Could not hash generated /etc/default/limine'; return 1; }
    ok 'Created transaction-owned CachyOS-themed Limine base + policy from the running cmdline and detected ESP'
}

# Extend candidate metadata with an exact splash identity.
eval "$(declare -f snapshot_limine_candidate_metadata | sed '1s/snapshot_limine_candidate_metadata/snapshot_limine_candidate_metadata_r22/')"
snapshot_limine_candidate_metadata() {
    snapshot_limine_candidate_metadata_r22 "$@" || return $?
    validate_cachyos_limine_theme || return 1
    r23_record_limine_theme_manifest || return 1
    local efi_dir="$ESP_MOUNT/EFI/LIMINE" manifest
    manifest=$(r23_target_limine_efi_manifest_path)
    write_privileged_tree_manifest "$efi_dir" "$manifest" || { fail 'Could not record the complete staged EFI/LIMINE namespace'; return 1; }
    chmod 600 -- "$manifest" 2>/dev/null || true
    ok 'Recorded exact ownership manifest for the staged EFI/LIMINE namespace'
}

# Extend deep target validation for Limine with presentation parity and the
# transaction-local splash ownership gate.
eval "$(declare -f validate_pending_target_deep | sed '1s/validate_pending_target_deep/validate_pending_target_deep_r22/')"
validate_pending_target_deep() {
    validate_pending_target_deep_r22 "$@" || return $?
    if [[ ${PENDING_TARGET:-} == limine ]]; then
        validate_cachyos_limine_theme || return 1
        if [[ ${PENDING_SOURCE:-} == grub ]]; then r23_verify_limine_theme_manifest || return 1; fi
    fi
}

r23_verify_target_limine_fallback_ownership() {
    [[ ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == grub:limine ]] || return 0
    local fallback=${PENDING_OLD_FALLBACK_PATH:-${ESP_MOUNT:-/boot}/EFI/BOOT/BOOTX64.EFI} actual
    [[ ${PENDING_POST_STAGE_FALLBACK_HASH:-} =~ ^[0-9A-Fa-f]{64}$ ]] || { fail 'Recorded target Limine EFI/BOOT fallback hash is missing/invalid'; return 1; }
    actual=$(sudo -n sha256sum -- "$fallback" 2>/dev/null | awk '{print $1}' || sha256sum -- "$fallback" 2>/dev/null | awk '{print $1}' || true)
    [[ -n $actual && $actual == "$PENDING_POST_STAGE_FALLBACK_HASH" ]] || { fail 'Target Limine EFI/BOOT fallback changed or disappeared since candidate creation'; return 1; }
    if [[ ${PENDING_OLD_FALLBACK_WAS_GRUB:-0} == 1 && -n ${PENDING_OLD_FALLBACK_HASH:-} && $actual == "$PENDING_OLD_FALLBACK_HASH" ]]; then
        fail 'Target fallback still contains the old GRUB bytes instead of the staged Limine fallback'
        return 1
    fi
    ok 'Target Limine EFI/BOOT fallback still matches the transaction-owned post-stage hash'
}

# Candidate ownership checks also bind the splash bytes.
eval "$(declare -f verify_pending_candidate_ownership_unchanged | sed '1s/verify_pending_candidate_ownership_unchanged/verify_pending_candidate_ownership_unchanged_r22/')"
verify_pending_candidate_ownership_unchanged() {
    verify_pending_candidate_ownership_unchanged_r22 "$@" || return $?
    if [[ ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == grub:limine ]]; then
        r23_verify_limine_theme_manifest || return 1
        r23_verify_target_limine_fallback_ownership || return 1
        local target_efi_manifest
        target_efi_manifest=$(r23_target_limine_efi_manifest_path)
        [[ -s $target_efi_manifest ]] || { fail 'Target EFI/LIMINE ownership manifest is missing'; return 1; }
        pending_verify_tree_manifest "$ESP_MOUNT/EFI/LIMINE" "$target_efi_manifest" || { fail 'Target EFI/LIMINE namespace changed since candidate creation'; return 1; }
        ok 'Target EFI/LIMINE namespace still matches the transaction manifest'
    fi
}

r23_set_target_first() {
    local target_id=$1 source_id=$2
    set_target_first_preserving_other_entries "$target_id" "$source_id" >/dev/null || return 1
    [[ $(pending_bootorder_first) == "${target_id^^}" ]]
}

r23_remove_source_grub_owned_state() {
    local old_id=$PENDING_OLD_BOOT_ID efi_dir dm em rec present expected actual
    printf '\nRetiring ownership-proven source GRUB state:\n'

    if boot_id_exists "$old_id"; then
        nvram_id_matches_path "$old_id" "$PENDING_OLD_BOOT_EFI_PATH" || { fail "Boot$old_id no longer matches the recorded GRUB path"; return 1; }
        sudo efibootmgr -b "$old_id" -B >/dev/null || return 1
        ok "Removed source GRUB NVRAM entry Boot$old_id"
    fi

    dm=$(r23_source_grub_dir_manifest_path); em=$(r23_source_grub_efi_dir_manifest_path); rec=$(r23_source_grub_default_record_path)
    pending_verify_tree_manifest /boot/grub "$dm" || { fail 'Refusing to remove changed /boot/grub'; return 1; }
    sudo rm -rf -- /boot/grub || return 1
    ok 'Removed ownership-proven source /boot/grub tree'

    efi_dir=$(dirname -- "$PENDING_OLD_GRUB_EFI_RESOLVED")
    pending_verify_tree_manifest "$efi_dir" "$em" || { fail 'Refusing to remove changed source GRUB EFI directory'; return 1; }
    sudo rm -rf -- "$efi_dir" || return 1
    ok "Removed ownership-proven source GRUB EFI directory: $efi_dir"

    present=$(awk -F'\t' '$1=="present"{print $2; exit}' "$rec")
    expected=$(awk -F'\t' '$1=="hash"{print $2; exit}' "$rec")
    if [[ $present == 1 && -e /etc/default/grub ]]; then
        actual=$(sha256sum /etc/default/grub 2>/dev/null | awk '{print $1}' || sudo -n sha256sum /etc/default/grub 2>/dev/null | awk '{print $1}' || true)
        [[ -n $actual && $actual == "$expected" ]] || { fail 'Refusing to remove changed /etc/default/grub'; return 1; }
        sudo rm -f -- /etc/default/grub || return 1
        ok 'Removed ownership-proven source /etc/default/grub'
    fi

    # The generic EFI fallback is target-owned only if Limine actually replaced
    # the old GRUB bytes during staging. If it still has the old GRUB hash, do
    # not silently leave a GRUB fallback behind in the finalized Limine state.
    if [[ -n $PENDING_OLD_FALLBACK_PATH && -f $PENDING_OLD_FALLBACK_PATH ]] || sudo -n test -f "$PENDING_OLD_FALLBACK_PATH" 2>/dev/null; then
        actual=$(sudo -n sha256sum -- "$PENDING_OLD_FALLBACK_PATH" 2>/dev/null | awk '{print $1}' || true)
        if [[ $PENDING_OLD_FALLBACK_WAS_GRUB == 1 && $actual == "$PENDING_OLD_FALLBACK_HASH" ]]; then
            fail 'EFI/BOOT fallback still contains the old GRUB bytes; refusing to finalize Limine without a target-owned fallback'
            return 1
        fi
        if [[ -n $PENDING_POST_STAGE_FALLBACK_HASH && $actual == "$PENDING_POST_STAGE_FALLBACK_HASH" ]]; then
            ok 'Retained transaction-recorded Limine EFI/BOOT fallback payload'
        else
            fail 'EFI/BOOT fallback changed after staging; refusing finalization'
            return 1
        fi
    fi
    return 0
}

r23_finalize_grub_to_limine() {
    validate_pending_compatibility || { fail "Pending migration is not compatible: $PENDING_REASON"; return 1; }
    [[ $PENDING_SOURCE == grub && $PENDING_TARGET == limine ]] || { fail 'This finalizer is only for GRUB -> Limine'; return 1; }
    [[ $PENDING_PHASE == runtime-validated ]] || { fail 'FINALIZE requires runtime-validated target proof'; return 1; }
    r23_limine_theme_required || { fail 'FINALIZE is locked until the exact CachyOS-themed Limine candidate has runtime proof'; return 1; }

    detect_bootloader
    [[ $BOOTLOADER == limine && $BOOT_CURRENT == "$PENDING_TARGET_BOOT_ID" ]] || { fail 'FINALIZE requires the recorded Limine target session to be running'; return 1; }
    run_validation preflight || return 1
    pending_validate_running_kernel || return 1
    pending_validate_runtime_cmdline_against_source || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1
    verify_pending_source_recovery_unchanged || return 1
    r23_verify_source_grub_cleanup_ownership || return 1

    local next answer
    next=$(pending_bootnext_id)
    [[ -z $next || $next == "$PENDING_TARGET_BOOT_ID" ]] || { fail "Unrelated BootNext=Boot$next exists; refusing finalization"; return 1; }
    if [[ $next == "$PENDING_TARGET_BOOT_ID" ]]; then
        sudo efibootmgr -N >/dev/null || return 1
        ok 'Cleared lingering transaction-owned BootNext before persistent promotion'
    fi

    printf '\nFINALIZE GRUB -> Limine:\n'
    printf '  - keep the runtime-proven CachyOS-themed Limine Boot%s\n' "$PENDING_TARGET_BOOT_ID"
    printf '  - promote Limine to first place in persistent BootOrder\n'
    printf '  - remove only exact ownership-proven source GRUB NVRAM/EFI/config state\n'
    printf '  - keep the target-owned Limine EFI/BOOT fallback\n'
    printf '  - validate Limine + CachyOS theme again after cleanup\n'
    if [[ ${R23_AUTO_FINALIZE:-0} != 1 ]]; then
        read -r -p 'Type FINALIZE to commit Limine as the intended bootloader: ' answer
        [[ $answer == FINALIZE ]] || { printf 'Finalization cancelled. Runtime proof is preserved.\n'; return 0; }
    fi

    r23_set_target_first "$PENDING_TARGET_BOOT_ID" "$PENDING_OLD_BOOT_ID" || { fail 'Could not promote Limine to first in persistent BootOrder'; return 1; }
    ok "Persistent BootOrder now starts with target Limine Boot$PENDING_TARGET_BOOT_ID"
    validate_pending_target_deep || { fail 'Target validation failed after promotion; source cleanup was NOT attempted'; return 1; }
    r23_remove_source_grub_owned_state || return 1
    detect_bootloader
    [[ $BOOTLOADER == limine && $BOOT_CURRENT == "$PENDING_TARGET_BOOT_ID" ]] || { fail 'Current Limine target identity changed during finalization'; return 1; }
    [[ $(pending_bootorder_first) == "$PENDING_TARGET_BOOT_ID" ]] || { fail 'Limine is not first in persistent BootOrder after finalization'; return 1; }
    boot_id_exists "$PENDING_OLD_BOOT_ID" && { fail 'Source GRUB NVRAM entry still exists after deletion'; return 1; }
    validate_target_state limine || return 1
    validate_limine_boot_chain migration || return 1
    validate_cachyos_limine_theme || return 1
    r23_verify_limine_theme_manifest || return 1
    r23_verify_target_limine_fallback_ownership || return 1

    local diag
    diag=$(pending_capture_runtime_diagnostics finalized-limine | tail -n1 || true)
    [[ -n $diag ]] && printf 'Finalization diagnostic snapshot: %s\n' "$diag"
    remove_pending_transaction_snapshot || true
    rm -f -- "$PENDING_STATE_FILE"
    printf '\nFINALIZED GRUB -> Limine successfully.\n'
    printf 'Limine Boot%s is the intended managed bootloader and is first in persistent BootOrder.\n' "$PENDING_TARGET_BOOT_ID"
    printf 'The CachyOS Limine palette + splash and deep boot-chain validation pass after source GRUB cleanup.\n'
    printf 'GRUB packages are intentionally left installed/inactive; package removal is not mixed into runtime-proven boot-state finalization.\n'
    return 0
}

r23_arm_candidate_automatically() {
    validate_pending_compatibility || { fail "Pending migration is not compatible: $PENDING_REASON"; return 1; }
    [[ $PENDING_PHASE == candidate-ready ]] || { fail 'Automatic arming requires candidate-ready'; return 1; }
    case "$PENDING_SOURCE:$PENDING_TARGET" in
        limine:grub|grub:limine) ;;
        *) fail 'Automatic arming currently supports only GRUB <-> Limine transactions'; return 1 ;;
    esac
    detect_bootloader
    [[ $BOOTLOADER == "$PENDING_SOURCE" && $BOOT_CURRENT == "$PENDING_OLD_BOOT_ID" ]] || { fail 'Automatic arming requires the recorded source session to be active'; return 1; }
    run_validation preflight || return 1
    verify_pending_source_recovery_unchanged || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext is already owned by another request'; return 1; }
    [[ $(pending_bootorder_first) == "$PENDING_OLD_BOOT_ID" ]] || { fail 'Persistent BootOrder is no longer source-first'; return 1; }
    nvram_id_matches_path "$PENDING_TARGET_BOOT_ID" "$PENDING_TARGET_EFI_PATH" || { fail 'Target NVRAM path changed before automatic arming'; return 1; }
    sudo efibootmgr -n "$PENDING_TARGET_BOOT_ID" >/dev/null || return 1
    [[ $(pending_bootnext_id) == "$PENDING_TARGET_BOOT_ID" ]] || { sudo efibootmgr -N >/dev/null 2>&1 || true; fail 'BootNext verification failed during automatic arming'; return 1; }
    pending_set_phase boot-armed || { sudo efibootmgr -N >/dev/null 2>&1 || true; fail 'Could not persist boot-armed phase; BootNext was cleared'; return 1; }
    PENDING_PHASE=boot-armed
    ok "Armed one-time $(bootloader_display_name "$PENDING_TARGET") test as BootNext=Boot$PENDING_TARGET_BOOT_ID"
    ok "Persistent BootOrder remains source $(bootloader_display_name "$PENDING_SOURCE") Boot$PENDING_OLD_BOOT_ID first until runtime proof"
}

r23_prompt_reboot() {
    local answer
    printf '\nThe one-time %s test is armed and the switcher will resume automatically after reboot.\n' "$(bootloader_display_name "$PENDING_TARGET")"
    printf 'If runtime validation passes, the switcher will finalize %s automatically and retire only ownership-proven %s state.\n' "$(bootloader_display_name "$PENDING_TARGET")" "$(bootloader_display_name "$PENDING_SOURCE")"
    read -r -p 'Reboot now? [y/N]: ' answer
    case "$answer" in
        y|Y|yes|YES) printf 'Rebooting now. No firmware-menu selection is required.\n'; sudo systemctl reboot ;;
        *) printf 'Reboot deferred. BootNext and the temporary resume service remain armed for your next normal reboot.\n' ;;
    esac
}

r23_after_fresh_grub_to_limine_candidate() {
    load_pending_state || { fail "Could not reload the newly staged transaction: $PENDING_REASON"; return 1; }
    validate_pending_compatibility || return 1
    r23_limine_theme_required || { fail 'Fresh Limine candidate is missing its CachyOS theme ownership marker'; return 1; }
    verify_pending_candidate_ownership_unchanged || return 1
    r23_arm_candidate_automatically || return 1
    if ! r22_prepare_resume_bundle; then
        fail 'Could not prepare automatic post-reboot continuation. Clearing the one-time boot for safety.'
        r22_rollback_automation_arm
        return 1
    fi
    r23_prompt_reboot
}

# Wrap the existing GRUB -> Limine staged backend. It now stages the themed
# candidate, then immediately moves into the same automated resumable flow as
# Limine -> GRUB.
eval "$(declare -f execute_grub_to_limine | sed '1s/execute_grub_to_limine/execute_grub_to_limine_r22/')"
execute_grub_to_limine() {
    execute_grub_to_limine_r22 "$@" || return $?
    pending_exists || return 0
    load_pending_state || return 1
    if [[ $PENDING_SOURCE == grub && $PENDING_TARGET == limine && $PENDING_PHASE == candidate-ready ]]; then
        r23_after_fresh_grub_to_limine_candidate
    fi
}

# r22 root resume is replaced with a direction-aware dispatcher. The root-owned
# bundle/state protection remains unchanged.
# Override the inherited fallback handler too: its r22 implementation hard-coded
# Limine as source and GRUB as target, which is wrong for the new reverse path.
r22_resume_source_fallback() {
    local conf=$1 next source_name target_name
    source_name=$(bootloader_display_name "$PENDING_SOURCE")
    target_name=$(bootloader_display_name "$PENDING_TARGET")
    printf 'Automatic resume: source %s is active after the one-time %s test request; target runtime proof was not obtained.\n' "$source_name" "$target_name"
    next=$(pending_bootnext_id)
    if [[ $next == "$PENDING_TARGET_BOOT_ID" ]]; then
        printf 'Automatic resume: firmware left the transaction BootNext behind; clearing only Boot%s.\n' "$next"
        efibootmgr -N >/dev/null || return 1
    elif [[ -n $next ]]; then
        printf 'Automatic resume: unrelated BootNext=Boot%s exists; leaving it untouched and refusing state reset.\n' "$next" >&2
        return 1
    fi
    reset_consumed_test_to_candidate_ready || return 1
    r22_sync_user_phase_from_root "$conf" candidate-ready || true
    r22_write_user_result "$conf" safe-fallback "The one-time $target_name target did not obtain runtime proof; $source_name remained the source, no source cleanup was attempted, and the candidate was returned to candidate-ready." || true
    r22_remove_resume_service_files
    return 0
}

r22_resume_transaction_root() {
    r22_root_bundle_preflight || return 1
    local bundle=$R22_RESUME_BUNDLE conf="$R22_RESUME_BUNDLE/resume.conf" rc=0 detail
    printf 'CachyOS Bootloader Switcher automatic transaction resume\n'
    printf 'Bundle: %s\n' "$bundle"

    load_pending_state || { printf 'Automatic resume: root-owned pending state is invalid: %s\n' "$PENDING_REASON" >&2; rc=1; }
    ((rc == 0)) && validate_pending_compatibility || rc=1
    if ((rc != 0)); then
        r22_write_user_result "$conf" failed 'The root-owned resume transaction failed compatibility validation; no source cleanup was attempted.' || true
        r22_remove_resume_service_files
        return 1
    fi

    detect_bootloader
    if [[ $BOOTLOADER == "$PENDING_SOURCE" && $BOOT_CURRENT == "$PENDING_OLD_BOOT_ID" ]]; then
        r22_resume_source_fallback "$conf"
        return $?
    fi
    if [[ $BOOTLOADER != "$PENDING_TARGET" || $BOOT_CURRENT != "$PENDING_TARGET_BOOT_ID" ]]; then
        printf 'Automatic resume: neither recorded source nor target is the current EFI boot. Refusing automation.\n' >&2
        r22_write_user_result "$conf" failed 'Automatic resume saw an unexpected BootCurrent/bootloader identity and refused to modify source state.' || true
        r22_remove_resume_service_files
        return 1
    fi

    case "$PENDING_PHASE" in
        boot-armed)
            if ! validate_pending_target_runtime; then
                r22_write_user_result "$conf" failed "The automatically booted $PENDING_TARGET target failed runtime validation; FINALIZE was not attempted." || true
                r22_remove_resume_service_files
                return 1
            fi
            PENDING_PHASE=runtime-validated
            r22_sync_user_phase_from_root "$conf" runtime-validated || true
            ;;
        runtime-validated) printf 'Automatic resume: runtime proof was already persisted; continuing to finalization.\n' ;;
        *)
            r22_write_user_result "$conf" failed "Unexpected automatic-resume phase: $PENDING_PHASE" || true
            r22_remove_resume_service_files
            return 1
            ;;
    esac

    case "$PENDING_SOURCE:$PENDING_TARGET" in
        limine:grub)
            R22_AUTO_FINALIZE=1 r21_finalize_limine_to_grub || {
                r22_write_user_result "$conf" failed 'Runtime proof passed, but ownership-gated Limine -> GRUB finalization failed.' || true
                r22_remove_resume_service_files; return 1; }
            detail="Limine -> GRUB finalized automatically. GRUB Boot$PENDING_TARGET_BOOT_ID is first in persistent BootOrder."
            ;;
        grub:limine)
            R23_AUTO_FINALIZE=1 r23_finalize_grub_to_limine || {
                r22_write_user_result "$conf" failed 'Runtime proof passed, but ownership-gated GRUB -> Limine finalization failed.' || true
                r22_remove_resume_service_files; return 1; }
            detail="GRUB -> Limine finalized automatically. Limine Boot$PENDING_TARGET_BOOT_ID is first in persistent BootOrder with the CachyOS theme."
            ;;
        *)
            r22_write_user_result "$conf" failed 'Automatic finalization direction is unsupported.' || true
            r22_remove_resume_service_files; return 1 ;;
    esac

    r22_cleanup_user_shadow_after_success "$conf"
    r22_write_user_result "$conf" success "$detail" || true
    r22_remove_resume_service_files
    rm -rf -- "$bundle" 2>/dev/null || true
    return 0
}

# Rollback/uncommitted cleanup restores any pre-existing splash exactly instead
# of leaving a candidate presentation artifact behind on a GRUB source system.
eval "$(declare -f cleanup_uncommitted_limine_candidate | sed '1s/cleanup_uncommitted_limine_candidate/cleanup_uncommitted_limine_candidate_r22/')"
cleanup_uncommitted_limine_candidate() {
    local root=${TRANSACTION_SNAPSHOT_DIR:-} keep rc=0
    keep=$(mktemp -d) || return 1
    if [[ -n $root && -d $root ]]; then
        r23_copy_prestage_limine_efi_snapshot "$root" "$keep" || { rm -rf -- "$keep"; return 1; }
        r23_restore_prestage_limine_splash "$root" || { rm -rf -- "$keep"; return 1; }
    fi
    cleanup_uncommitted_limine_candidate_r22 "$@" || rc=$?
    r23_restore_prestage_limine_efi_dir "$keep" || rc=1
    rm -rf -- "$keep"
    return "$rc"
}

eval "$(declare -f rollback_pending_grub_to_limine | sed '1s/rollback_pending_grub_to_limine/rollback_pending_grub_to_limine_r22/')"
rollback_pending_grub_to_limine() {
    local root=$PENDING_TRANSACTION_SNAPSHOT_DIR keep rc=0
    keep=$(mktemp -d) || return 1
    r23_copy_prestage_limine_efi_snapshot "$root" "$keep" || { rm -rf -- "$keep"; return 1; }
    r23_restore_prestage_limine_splash "$root" || { rm -rf -- "$keep"; return 1; }
    rollback_pending_grub_to_limine_r22 "$@" || rc=$?
    r23_restore_prestage_limine_efi_dir "$keep" || rc=1
    rm -rf -- "$keep"
    return "$rc"
}

# Recovery UX remains automated too. If a one-time test fell safely back to the
# source, the user can re-arm the exact candidate + temporary resume service as
# one action. If runtime proof already exists but the user later returned to the
# source, r23 can one-shot the proven target again so automatic FINALIZE can run
# from the required target session.
r23_rearm_candidate_with_resume() {
    load_pending_state || { fail "Could not reload the pending transaction: $PENDING_REASON"; return 1; }
    validate_pending_compatibility || return 1
    [[ $PENDING_PHASE == candidate-ready ]] || { fail 'Automated re-arm requires candidate-ready state'; return 1; }
    case "$PENDING_SOURCE:$PENDING_TARGET" in limine:grub|grub:limine) ;; *) fail 'Automated re-arm supports only GRUB <-> Limine'; return 1 ;; esac
    if [[ $PENDING_TARGET == grub ]]; then
        r21_theme_required || { fail 'The pending GRUB candidate is missing its CachyOS theme ownership marker'; return 1; }
    else
        r23_limine_theme_required || { fail 'The pending Limine candidate is missing its CachyOS theme ownership marker'; return 1; }
    fi
    verify_pending_candidate_ownership_unchanged || return 1
    r23_arm_candidate_automatically || return 1
    if ! r22_prepare_resume_bundle; then
        fail 'Could not prepare automatic post-reboot continuation. Clearing the one-time boot for safety.'
        r22_rollback_automation_arm
        return 1
    fi
    r23_prompt_reboot
}

r23_rearm_runtime_validated_target() {
    load_pending_state || { fail "Could not reload the pending transaction: $PENDING_REASON"; return 1; }
    validate_pending_compatibility || return 1
    [[ $PENDING_PHASE == runtime-validated ]] || { fail 'Validated-target return requires runtime-validated state'; return 1; }
    case "$PENDING_SOURCE:$PENDING_TARGET" in limine:grub|grub:limine) ;; *) fail 'Validated-target return supports only GRUB <-> Limine'; return 1 ;; esac
    detect_bootloader
    [[ $BOOTLOADER == "$PENDING_SOURCE" && $BOOT_CURRENT == "$PENDING_OLD_BOOT_ID" ]] || { fail 'Validated-target return requires the recorded source session to be active'; return 1; }
    run_validation preflight || return 1
    verify_pending_source_recovery_unchanged || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext is already owned by another request'; return 1; }
    [[ $(pending_bootorder_first) == "$PENDING_OLD_BOOT_ID" ]] || { fail 'Persistent BootOrder is no longer source-first'; return 1; }
    nvram_id_matches_path "$PENDING_TARGET_BOOT_ID" "$PENDING_TARGET_EFI_PATH" || { fail 'Target NVRAM path changed before validated return'; return 1; }

    sudo efibootmgr -n "$PENDING_TARGET_BOOT_ID" >/dev/null || return 1
    if [[ $(pending_bootnext_id) != "$PENDING_TARGET_BOOT_ID" ]]; then
        sudo efibootmgr -N >/dev/null 2>&1 || true
        fail 'BootNext verification failed while arming the validated target return'
        return 1
    fi
    if ! r22_prepare_resume_bundle; then
        fail 'Could not prepare automatic finalization continuation. Clearing only the newly armed BootNext; runtime proof is preserved.'
        sudo efibootmgr -N >/dev/null 2>&1 || true
        return 1
    fi
    ok "Armed one-time return to runtime-validated $(bootloader_display_name "$PENDING_TARGET") Boot$PENDING_TARGET_BOOT_ID"
    printf '\nThe target already has runtime proof. The switcher will re-check every gate from the target session and automatically FINALIZE if they still pass.\n'
    r23_prompt_reboot
}

# Manual recovery path: keep recovery automation symmetrical rather than
# dropping back to the older ARM/validate/relaunch choreography.
eval "$(declare -f manage_pending_migration | sed '1s/manage_pending_migration/manage_pending_migration_r22/')"
manage_pending_migration() {
    if pending_exists && load_pending_state >/dev/null 2>&1 && validate_pending_compatibility >/dev/null 2>&1; then
        detect_bootloader
        local choice

        if [[ $BOOTLOADER == "$PENDING_SOURCE" && $BOOT_CURRENT == "$PENDING_OLD_BOOT_ID" ]]; then
            case "$PENDING_PHASE" in
                candidate-ready)
                    case "$PENDING_SOURCE:$PENDING_TARGET" in
                        limine:grub|grub:limine)
                            show_pending_details
                            printf '\nThe source is active and the validated candidate is parked.\n'
                            printf '[1] Re-run deep source + target validation\n'
                            printf '[2] Re-arm automated one-time %s test + resume service\n' "$(bootloader_display_name "$PENDING_TARGET")"
                            printf '[3] Roll back the staged candidate\n[4] Back\n\n'
                            read -r -p 'Select an option: ' choice
                            case "$choice" in
                                1) run_validation preflight && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep ;;
                                2) r23_rearm_candidate_with_resume ;;
                                3) rollback_pending_candidate ;;
                                4|'') return 0 ;;
                                *) printf 'Invalid selection.\n'; return 1 ;;
                            esac
                            return $?
                            ;;
                    esac
                    ;;
                runtime-validated)
                    case "$PENDING_SOURCE:$PENDING_TARGET" in
                        limine:grub|grub:limine)
                            show_pending_details
                            printf '\nRuntime proof is already recorded, but the source is active again.\n'
                            printf 'FINALIZE remains target-session-only. The switcher can return to the proven target automatically.\n'
                            printf '[1] Re-arm validated %s target + automatic FINALIZE\n' "$(bootloader_display_name "$PENDING_TARGET")"
                            printf '[2] Re-check source/candidate ownership\n[3] Roll back target\n[4] Back\n\n'
                            read -r -p 'Select an option: ' choice
                            case "$choice" in
                                1) r23_rearm_runtime_validated_target ;;
                                2) run_validation preflight && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep ;;
                                3) rollback_pending_candidate ;;
                                4|'') return 0 ;;
                                *) printf 'Invalid selection.\n'; return 1 ;;
                            esac
                            return $?
                            ;;
                    esac
                    ;;
            esac
        fi

        if [[ $PENDING_SOURCE == grub && $PENDING_TARGET == limine && $PENDING_PHASE == runtime-validated && $BOOTLOADER == limine && $BOOT_CURRENT == "$PENDING_TARGET_BOOT_ID" ]]; then
            show_pending_details
            printf '\nThe exact CachyOS-themed Limine state has runtime proof. FINALIZE is eligible.\n'
            printf '[1] Re-run runtime validation\n[2] FINALIZE GRUB -> Limine\n[3] Back\n\n'
            read -r -p 'Select an option: ' choice
            case "$choice" in
                1) validate_pending_target_runtime ;;
                2) r23_finalize_grub_to_limine ;;
                3|'') return 0 ;;
                *) printf 'Invalid selection.\n'; return 1 ;;
            esac
            return $?
        fi
    fi
    manage_pending_migration_r22 "$@"
}

