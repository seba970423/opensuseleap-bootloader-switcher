#!/usr/bin/env bash
# openSUSE Leap 16 port layer for the CachyOS r47 codebase.
#
# leap16-r15 adds the reverse Limine -> GRUB2 transaction over the retained
# native openSUSE GRUB2 recovery chain that r13 deliberately preserved.  It
# one-shots the exact retained GRUB2 Boot####, runtime-proves it, promotes it
# persistently, and only then retires ownership-proven Limine source state.
# r14 openSUSE Limine menu branding remains in force.
# r13 ports the r47 root-owned automatic resume choreography onto the
# hardware-proven Leap GRUB2 -> Limine candidate/BootNext path.  Fresh candidates
# are armed automatically, a root-owned systemd one-shot resumes after reboot,
# and exact runtime proof may promote Limine first in persistent BootOrder.
# Forward safety boundary: GRUB2/shim/config and the shared fallback remain recovery after GRUB2 -> Limine.
# r15 reverse finalization can retire only the exact proven Limine source; the openSUSE shim fallback is never retired.
# All nine top-level selectors remain present and there is still no second
# transaction engine here.

LEAP16_PORT_PHASE="grub2-limine-two-way-automatic-transaction"
LEAP16_LIMINE_MENU_GROUP="openSUSE"

# r14 presentation-only override.  r47 still writes the exact captured CachyOS
# Limine theme base; on Leap the top-level OS menu group must identify the
# installed distro, not the theme source.  Keep every theme line byte-for-byte
# and replace only the inherited /+CachyOS group marker in freshly generated
# candidates.  Existing staged r13 candidates are intentionally not rewritten.
if declare -F r23_write_cachyos_limine_theme_base >/dev/null 2>&1; then
    eval "$(declare -f r23_write_cachyos_limine_theme_base | sed '1s/r23_write_cachyos_limine_theme_base/r23_write_cachyos_limine_theme_base_r47/')"
fi
r23_write_cachyos_limine_theme_base() {
    local conf=$1
    declare -F r23_write_cachyos_limine_theme_base_r47 >/dev/null 2>&1 || { fail 'Inherited r47 Limine theme writer is unavailable'; return 1; }
    r23_write_cachyos_limine_theme_base_r47 "$@" || return 1
    grep -Fqx -- '/+CachyOS' "$conf" || { fail 'Inherited CachyOS Limine OS group marker is missing; refusing an ambiguous branding rewrite'; return 1; }
    sed -i 's|^/+CachyOS$|/+openSUSE|' "$conf" || return 1
    grep -Fqx -- "/+$LEAP16_LIMINE_MENU_GROUP" "$conf" || { fail 'Could not rewrite the Limine OS menu group to openSUSE'; return 1; }
}

# openSUSE does not necessarily expose administrative binaries in a normal
# desktop user's PATH.  The stock Leap 16 boot tools used by the inherited
# r47 code live in /usr/sbin (efibootmgr, grub2-mkconfig, grub2-probe, ...).
# Extend PATH only inside this process so command discovery behaves the same
# for a normal user as it does under the root-owned probe environment.
leap16_extend_admin_path() {
    local dir
    for dir in /usr/sbin /sbin; do
        case ":${PATH:-}:" in
            *:"$dir":*) ;;
            *) PATH="${PATH:+$PATH:}$dir" ;;
        esac
    done
    export PATH
}
leap16_extend_admin_path
BACKUP_ROOT="${BOOTLOADER_SWITCHER_BACKUP_ROOT:-$HOME/opensuse-bootloader-backups}"
PENDING_STATE_DIR="${BOOTLOADER_SWITCHER_STATE_DIR:-$HOME/.local/state/opensuse-bootloader-switcher}"
PENDING_STATE_FILE="$PENDING_STATE_DIR/pending-migration.tsv"
LEAP16_DIAGNOSTIC_ROOT="${BOOTLOADER_SWITCHER_DIAGNOSTIC_ROOT:-$HOME/opensuse-bootloader-diagnostics}"

# A fresh live transaction must outrank stale loaded-pending globals.  r23's
# inherited helper prefers PENDING_TRANSACTION_SNAPSHOT_DIR, which is correct
# across reboots but wrong inside the same interactive process immediately after
# rollback if those globals have not yet been reset.  Prefer an existing active
# transaction snapshot first, then an existing persisted-pending snapshot.
r23_theme_snapshot_root() {
    if [[ -n ${TRANSACTION_SNAPSHOT_DIR:-} && -d ${TRANSACTION_SNAPSHOT_DIR:-/nonexistent} ]]; then
        printf '%s\n' "$TRANSACTION_SNAPSHOT_DIR"
        return 0
    fi
    if [[ -n ${PENDING_TRANSACTION_SNAPSHOT_DIR:-} && -d ${PENDING_TRANSACTION_SNAPSHOT_DIR:-/nonexistent} ]]; then
        printf '%s\n' "$PENDING_TRANSACTION_SNAPSHOT_DIR"
        return 0
    fi
    printf '%s\n' "${TRANSACTION_SNAPSHOT_DIR:-${PENDING_TRANSACTION_SNAPSHOT_DIR:-}}"
}

# Keep the CachyOS r47 diagnostic UX: one user-owned timestamped directory per
# checkpoint/failure.  Do not auto-create archives.  The payload is adapted to
# Leap tooling/paths (rpm, /boot/grub2, /etc/sysconfig/bootloader).
leap16_diag_read_file() {
    local src=$1 dst=$2
    if [[ -r $src ]]; then
        cat -- "$src" >"$dst" 2>/dev/null || true
    elif sudo -n test -r "$src" 2>/dev/null; then
        sudo -n cat -- "$src" >"$dst" 2>/dev/null || true
    fi
}

leap16_diag_pending_value() {
    local key=$1
    [[ -n ${PENDING_STATE_FILE:-} && -r ${PENDING_STATE_FILE:-} ]] || return 0
    awk -F'\t' -v key="$key" '$1==key {print $2; exit}' "$PENDING_STATE_FILE" 2>/dev/null || true
}

# r18: reverse ownership failures must preserve the manifests that explain the
# failure before the uncommitted transaction snapshot is deleted.  These
# helpers are diagnostic-only: they do not weaken, replace or retry any r47
# ownership gate.
leap16_diag_existing_transaction_snapshot_dir() {
    local candidate
    for candidate in \
        "${TRANSACTION_SNAPSHOT_DIR:-}" \
        "${PENDING_TRANSACTION_SNAPSHOT_DIR:-}" \
        "$(leap16_diag_pending_value transaction_snapshot_dir)"; do
        [[ -n $candidate && -d $candidate ]] || continue
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}

leap16_diag_copy_snapshot_evidence() {
    local snapshot=$1 out=$2 name
    for name in \
        grub-artifacts.tsv \
        grub-dir.tsv \
        grub-efi-dir.tsv \
        grub-theme-dir.tsv \
        source-limine-efi-dir.tsv \
        source-limine-managed-dir.tsv \
        grub-theme-required \
        source-limine-splash.sha256 \
        source-limine-splash.absent; do
        [[ -e $snapshot/$name ]] || continue
        leap16_diag_read_file "$snapshot/$name" "$out/$name"
    done
}

leap16_diag_write_actual_tree_manifest() {
    local root=$1 out=$2
    [[ -n $root ]] || return 1
    if sudo -n test -d "$root" 2>/dev/null || [[ -d $root ]]; then
        write_privileged_tree_manifest "$root" "$out"
        return $?
    fi
    return 1
}

leap16_diag_first_tree_manifest_mismatch() {
    local expected=$1 actual=$2
    [[ -s $expected && -s $actual ]] || return 1
    awk -F '\t' '
        FNR == NR {
            expected[$3] = $1 FS $2
            order[++count] = $3
            next
        }
        {
            actual[$3] = $1 FS $2
            if (!mismatch && !($3 in expected)) {
                print "reason=appeared"
                print "path=" $3
                print "actual_type=" $1
                print "actual_identity=" $2
                mismatch = 1
                next
            }
            if (!mismatch && expected[$3] != $1 FS $2) {
                split(expected[$3], old, FS)
                print "reason=changed"
                print "path=" $3
                print "expected_type=" old[1]
                print "expected_identity=" old[2]
                print "actual_type=" $1
                print "actual_identity=" $2
                mismatch = 1
            }
        }
        END {
            if (!mismatch) {
                for (i = 1; i <= count; i++) {
                    path = order[i]
                    if (!(path in actual)) {
                        split(expected[path], old, FS)
                        print "reason=missing"
                        print "path=" path
                        print "expected_type=" old[1]
                        print "expected_identity=" old[2]
                        mismatch = 1
                        break
                    }
                }
            }
            if (!mismatch)
                print "reason=none"
        }
    ' "$expected" "$actual"
}

leap16_diag_capture_tree_manifest_comparison() {
    local label=$1 root=$2 expected=$3 out=$4 actual diff summary
    actual="$out/actual-$label.tsv"
    diff="$out/$label.diff"
    summary="$out/$label.first-mismatch.txt"

    if [[ ! -s $expected ]]; then
        printf 'reason=expected-manifest-missing\nmanifest=%s\nroot=%s\n' "$expected" "$root" >"$summary"
        return 1
    fi
    if ! leap16_diag_write_actual_tree_manifest "$root" "$actual"; then
        printf 'reason=actual-tree-unavailable\nmanifest=%s\nroot=%s\n' "$expected" "$root" >"$summary"
        return 1
    fi

    LC_ALL=C diff -u <(LC_ALL=C sort "$expected") <(LC_ALL=C sort "$actual") >"$diff" 2>/dev/null || true
    leap16_diag_first_tree_manifest_mismatch "$expected" "$actual" >"$summary" 2>/dev/null || {
        printf 'reason=comparison-error\nmanifest=%s\nroot=%s\n' "$expected" "$root" >"$summary"
        return 1
    }
    return 0
}

leap16_diag_capture_grub_artifact_comparison() {
    local expected=$1 out=$2 actual="$out/actual-grub-artifacts.tsv" summary="$out/grub-artifacts.first-mismatch.txt"
    local ownership hash path current mismatch=0
    : >"$actual"
    [[ -s $expected ]] || {
        printf 'reason=expected-manifest-missing\nmanifest=%s\n' "$expected" >"$summary"
        return 1
    }

    while IFS=$'\t' read -r ownership hash path; do
        [[ -n $ownership && -n $hash && -n $path ]] || continue
        current=$(sudo -n sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || true)
        if [[ -n $current ]]; then
            printf '%s\t%s\t%s\n' "$ownership" "$current" "$path" >>"$actual"
        else
            printf '%s\tMISSING\t%s\n' "$ownership" "$path" >>"$actual"
        fi
        if ((mismatch == 0)); then
            if [[ -z $current ]]; then
                {
                    printf 'reason=missing\n'
                    printf 'path=%s\n' "$path"
                    printf 'expected_identity=%s\n' "$hash"
                } >"$summary"
                mismatch=1
            elif [[ $current != "$hash" ]]; then
                {
                    printf 'reason=changed\n'
                    printf 'path=%s\n' "$path"
                    printf 'expected_identity=%s\n' "$hash"
                    printf 'actual_identity=%s\n' "$current"
                } >"$summary"
                mismatch=1
            fi
        fi
    done <"$expected"

    LC_ALL=C diff -u "$expected" "$actual" >"$out/grub-artifacts.diff" 2>/dev/null || true
    ((mismatch)) || printf 'reason=none\n' >"$summary"
}

leap16_capture_reverse_ownership_evidence() {
    local out=$1 phase=${2:-snapshot} snapshot grub_dir grub_efi_dir grub_theme source_efi source_efi_dir source_managed report label summary
    local reverse_post_retirement=0
    if [[ ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == limine:grub ]]; then
        case "$phase" in
            finalization-pass|auto-resume-pass|auto-resume-success) reverse_post_retirement=1 ;;
        esac
    fi
    snapshot=$(leap16_diag_existing_transaction_snapshot_dir 2>/dev/null || true)
    [[ -n $snapshot ]] || return 0

    # This evidence set is specific to the inherited format-4 Limine -> GRUB
    # ownership model.  The presence of either retained-GRUB manifest is enough
    # to identify a reverse snapshot even if pending state was only partially
    # serialized when the failure occurred.
    [[ -s $snapshot/grub-dir.tsv || -s $snapshot/grub-efi-dir.tsv || ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == limine:grub ]] || return 0

    leap16_diag_copy_snapshot_evidence "$snapshot" "$out"

    grub_dir=${PENDING_GRUB_DIR:-${TARGET_GRUB_DIR:-/boot/grub2}}
    grub_efi_dir=${PENDING_GRUB_EFI_DIR:-${TARGET_GRUB_EFI_DIR:-${ESP_MOUNT:-/boot/efi}/EFI/OPENSUSE}}
    grub_theme=${R21_GRUB_THEME_DIR:-/boot/grub2/themes/openSUSE}
    source_efi=${PENDING_SOURCE_LIMINE_EFI_RESOLVED:-${SOURCE_LIMINE_EFI_RESOLVED:-${ESP_MOUNT:-/boot/efi}/EFI/LIMINE/LIMINE_X64.EFI}}
    source_efi_dir=$(dirname -- "$source_efi")
    source_managed=${PENDING_SOURCE_LIMINE_MANAGED_DIR:-${SOURCE_LIMINE_MANAGED_DIR:-}}

    [[ -s $snapshot/grub-artifacts.tsv ]] && leap16_diag_capture_grub_artifact_comparison "$snapshot/grub-artifacts.tsv" "$out" || true
    [[ -s $snapshot/grub-dir.tsv ]] && leap16_diag_capture_tree_manifest_comparison grub-dir "$grub_dir" "$snapshot/grub-dir.tsv" "$out" || true
    [[ -s $snapshot/grub-efi-dir.tsv ]] && leap16_diag_capture_tree_manifest_comparison grub-efi-dir "$grub_efi_dir" "$snapshot/grub-efi-dir.tsv" "$out" || true
    [[ -s $snapshot/grub-theme-dir.tsv ]] && leap16_diag_capture_tree_manifest_comparison grub-theme-dir "$grub_theme" "$snapshot/grub-theme-dir.tsv" "$out" || true
    if ((reverse_post_retirement)); then
        if [[ -s $snapshot/source-limine-efi-dir.tsv ]]; then
            if [[ ! -e $source_efi_dir && ! -L $source_efi_dir ]]; then
                printf 'reason=retired-as-expected\nmanifest=%s\nroot=%s\n' \
                    "$snapshot/source-limine-efi-dir.tsv" "$source_efi_dir" >"$out/source-limine-efi-dir.first-mismatch.txt"
            else
                printf 'reason=unexpectedly-present-after-retirement\nmanifest=%s\nroot=%s\n' \
                    "$snapshot/source-limine-efi-dir.tsv" "$source_efi_dir" >"$out/source-limine-efi-dir.first-mismatch.txt"
            fi
        fi
        if [[ -s $snapshot/source-limine-managed-dir.tsv ]]; then
            if [[ -n $source_managed && ! -e $source_managed && ! -L $source_managed ]]; then
                printf 'reason=retired-as-expected\nmanifest=%s\nroot=%s\n' \
                    "$snapshot/source-limine-managed-dir.tsv" "$source_managed" >"$out/source-limine-managed-dir.first-mismatch.txt"
            else
                printf 'reason=unexpectedly-present-after-retirement\nmanifest=%s\nroot=%s\n' \
                    "$snapshot/source-limine-managed-dir.tsv" "${source_managed:-unknown}" >"$out/source-limine-managed-dir.first-mismatch.txt"
            fi
        fi
    else
        [[ -s $snapshot/source-limine-efi-dir.tsv ]] && leap16_diag_capture_tree_manifest_comparison source-limine-efi-dir "$source_efi_dir" "$snapshot/source-limine-efi-dir.tsv" "$out" || true
        if [[ -s $snapshot/source-limine-managed-dir.tsv ]]; then
            if [[ -n $source_managed ]]; then
                leap16_diag_capture_tree_manifest_comparison source-limine-managed-dir "$source_managed" "$snapshot/source-limine-managed-dir.tsv" "$out" || true
            else
                printf 'reason=actual-tree-unavailable\nmanifest=%s\nroot=\n' "$snapshot/source-limine-managed-dir.tsv" >"$out/source-limine-managed-dir.first-mismatch.txt"
            fi
        fi
    fi

    report="$out/ownership-manifest-diff.txt"
    {
        printf 'transaction_snapshot_dir=%s\n' "$snapshot"
        printf 'diagnostic_contract=r20-phase-aware-reverse-ownership\n'
        printf 'diagnostic_phase=%s\n\n' "$phase"
        printf 'The expected manifests below are the exact transaction ownership snapshot.\n'
        if ((reverse_post_retirement)); then
            printf 'Retired Limine source trees are expected to be absent at this phase and are reported as retired-as-expected.\n'
        else
            printf 'actual-*.tsv files are regenerated from the live filesystem with the same tree-manifest writer.\n'
            printf '*.diff files are full expected-vs-actual unified diffs.\n'
        fi
        printf '\n'
        for label in grub-artifacts grub-dir grub-efi-dir grub-theme-dir source-limine-efi-dir source-limine-managed-dir; do
            summary="$out/$label.first-mismatch.txt"
            [[ -f $summary ]] || continue
            printf '[%s]\n' "$label"
            cat -- "$summary"
            printf '\n'
        done
    } >"$report" 2>/dev/null || true

    # Give the operator one compact answer without having to open every diff.
    : >"$out/ownership-first-mismatch.txt"
    for label in grub-artifacts grub-dir grub-efi-dir grub-theme-dir source-limine-efi-dir source-limine-managed-dir; do
        summary="$out/$label.first-mismatch.txt"
        [[ -f $summary ]] || continue
        if ! grep -Eq '^reason=(none|retired-as-expected)$' "$summary" 2>/dev/null; then
            {
                printf 'manifest=%s\n' "$label"
                cat -- "$summary"
            } >"$out/ownership-first-mismatch.txt"
            break
        fi
    done
    [[ -s $out/ownership-first-mismatch.txt ]] || printf 'reason=none\n' >"$out/ownership-first-mismatch.txt"
}

leap16_capture_diagnostics() {
    local phase=${1:-snapshot} stamp out conf fallback
    phase=${phase//[^A-Za-z0-9._-]/-}
    stamp=$(date +%Y%m%d-%H%M%S)
    out="$LEAP16_DIAGNOSTIC_ROOT/${stamp}-${phase}"
    mkdir -p -- "$out" || return 1
    chmod 700 -- "$out" 2>/dev/null || true

    {
        printf 'release=%s\n' "${SWITCHER_RELEASE:-unknown}"
        printf 'phase=%s\n' "$phase"
        printf 'captured_at=%s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
        printf 'bootloader=%s\n' "${BOOTLOADER:-unknown}"
        printf 'boot_current=%s\n' "${BOOT_CURRENT:-}"
        printf 'boot_next=%s\n' "${BOOT_NEXT:-}"
        printf 'boot_order=%s\n' "$(leap16_current_boot_order 2>/dev/null || true)"
        printf 'esp_source=%s\n' "${ESP_SOURCE:-}"
        printf 'esp_mount=%s\n' "${ESP_MOUNT:-}"
        printf 'esp_uuid=%s\n' "${ESP_UUID:-}"
        printf 'root_source=%s\n' "${ROOT_SOURCE:-}"
        printf 'root_uuid=%s\n' "${ROOT_UUID:-}"
        if [[ $phase == rollback-pass ]]; then
            printf 'transaction_phase=\n'
            printf 'transaction_snapshot_dir=\n'
            printf 'created_target_id=\n'
            printf 'original_boot_order=\n'
        else
            printf 'transaction_phase=%s\n' "${PENDING_PHASE:-$(leap16_diag_pending_value phase)}"
            printf 'transaction_snapshot_dir=%s\n' "${TRANSACTION_SNAPSHOT_DIR:-${PENDING_TRANSACTION_SNAPSHOT_DIR:-$(leap16_diag_pending_value transaction_snapshot_dir)}}"
            printf 'created_target_id=%s\n' "${LEAP16_CREATED_TARGET_ID:-${PENDING_TARGET_BOOT_ID:-$(leap16_diag_pending_value target_boot_id)}}"
            printf 'original_boot_order=%s\n' "${LEAP16_ORIGINAL_BOOT_ORDER:-${PENDING_ORIGINAL_BOOT_ORDER:-$(leap16_diag_pending_value original_boot_order)}}"
        fi
    } >"$out/switcher-state.txt" 2>/dev/null || true

    leap16_diag_read_file /proc/cmdline "$out/proc-cmdline.txt"
    leap16_diag_read_file /etc/os-release "$out/os-release.txt"
    leap16_diag_read_file /etc/fstab "$out/fstab.txt"
    leap16_diag_read_file /etc/default/grub "$out/default-grub.txt"
    leap16_diag_read_file /etc/default/limine "$out/default-limine.txt"
    leap16_diag_read_file /etc/sysconfig/bootloader "$out/sysconfig-bootloader.txt"
    leap16_diag_read_file /boot/grub2/grub.cfg "$out/grub.cfg"
    conf="${ESP_MOUNT:-/boot/efi}/limine.conf"
    leap16_diag_read_file "$conf" "$out/limine.conf"
    fallback="${ESP_MOUNT:-/boot/efi}/EFI/BOOT/BOOTX64.EFI"

    efibootmgr -v >"$out/efibootmgr-v.txt" 2>&1 || true
    lsblk -f >"$out/lsblk-f.txt" 2>&1 || true
    lsblk -o NAME,KNAME,PKNAME,PATH,TYPE,FSTYPE,UUID,PARTUUID,MOUNTPOINTS >"$out/lsblk-topology.txt" 2>&1 || true
    findmnt >"$out/findmnt.txt" 2>&1 || true
    findmnt --verify --verbose >"$out/findmnt-verify.txt" 2>&1 || true
    uname -a >"$out/uname-a.txt" 2>&1 || true
    if have mokutil; then mokutil --sb-state >"$out/mokutil-sb-state.txt" 2>&1 || true; fi
    if have rpm; then
        rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>&1 | LC_ALL=C sort >"$out/rpm-qa.txt" || true
        rpm -q grub2-common grub2-x86_64-efi shim efibootmgr kernel-default >"$out/rpm-boot-packages.txt" 2>&1 || true
    fi

    {
        printf '## managed boot files\n'
        for _f in \
            "${ESP_MOUNT:-/boot/efi}/EFI/OPENSUSE/SHIM.EFI" \
            "${ESP_MOUNT:-/boot/efi}/EFI/OPENSUSE/GRUBX64.EFI" \
            "${ESP_MOUNT:-/boot/efi}/EFI/LIMINE/LIMINE_X64.EFI" \
            "$fallback" \
            "${ESP_MOUNT:-/boot/efi}/limine.conf" \
            "${ESP_MOUNT:-/boot/efi}/limine-splash.png"; do
            if sudo -n test -f "$_f" 2>/dev/null || [[ -f $_f ]]; then
                sudo -n sha256sum -- "$_f" 2>/dev/null || sha256sum -- "$_f" 2>/dev/null || true
            else
                printf 'MISSING  %s\n' "$_f"
            fi
        done
        printf '\n## source kernels/initrds\n'
        for _f in /boot/vmlinuz-* /boot/initrd-*; do
            [[ -e $_f ]] || continue
            sudo -n sha256sum -- "$_f" 2>/dev/null || sha256sum -- "$_f" 2>/dev/null || true
        done
    } >"$out/boot-artifact-sha256.txt" 2>&1 || true

    if [[ -n ${ESP_MOUNT:-} ]]; then
        sudo -n find "$ESP_MOUNT/EFI" -maxdepth 3 -printf '%y\t%p\n' >"$out/esp-efi-tree.txt" 2>&1 \
            || find "$ESP_MOUNT/EFI" -maxdepth 3 -printf '%y\t%p\n' >"$out/esp-efi-tree.txt" 2>&1 \
            || true
    fi
    [[ -n ${PENDING_STATE_FILE:-} && -r $PENDING_STATE_FILE ]] && cat -- "$PENDING_STATE_FILE" >"$out/pending-migration.tsv" 2>/dev/null || true
    # r20 preserves reverse ownership evidence and interprets retired source
    # trees according to the diagnostic phase before any snapshot cleanup.
    leap16_capture_reverse_ownership_evidence "$out" "$phase" 2>/dev/null || true
    leap16_write_firmware_order_report "$out/firmware-order.txt" "$phase" 2>/dev/null || true

    LIMINE_DIAGNOSTIC_DIR=$out
    GRUB_DIAGNOSTIC_DIR=$out
    printf '%s\n' "$out"
}

# Preserve the inherited r47 diagnostic APIs while redirecting them into the
# Leap namespace and Leap-specific payload above.
capture_limine_diagnostics() { leap16_capture_diagnostics "${1:-snapshot}"; }
capture_grub_diagnostics() { leap16_capture_diagnostics "${1:-snapshot}"; }


is_leap16() {
    [[ -r /etc/os-release ]] || return 1
    local id="" version=""
    id=$(sed -nE 's/^ID="?([^"[:space:]]+)"?.*/\1/p' /etc/os-release | head -n1)
    version=$(sed -nE 's/^VERSION_ID="?([^"[:space:]]+)"?.*/\1/p' /etc/os-release | head -n1)
    [[ $id == opensuse-leap && $version == 16* ]]
}

leap16_generic_fallback_owner() {
    local fallback candidate fh ch owner_count=0 owner="" grub_match=0 limine_match=0
    fallback=$(resolve_efi_path_on_esp '\EFI\BOOT\BOOTX64.EFI' 2>/dev/null || true)
    [[ -n $fallback && -r $fallback ]] || return 1
    fh=$(sha256sum -- "$fallback" 2>/dev/null | awk '{print $1}' || true)
    [[ $fh =~ ^[0-9A-Fa-f]{64}$ ]] || return 1

    # Leap's stock fallback is shim, not grubx64.efi. Treat either native
    # openSUSE GRUB-chain binary as GRUB only when the bytes match exactly.
    for candidate in \
        "$(resolve_efi_path_on_esp '\EFI\opensuse\shim.efi' 2>/dev/null || true)" \
        "$(resolve_efi_path_on_esp '\EFI\opensuse\grubx64.efi' 2>/dev/null || true)"; do
        [[ -n $candidate && -r $candidate ]] || continue
        ch=$(sha256sum -- "$candidate" 2>/dev/null | awk '{print $1}' || true)
        [[ -n $ch && $ch == "$fh" ]] || continue
        grub_match=1
    done

    # r21 deliberately transfers the generic fallback from openSUSE shim to
    # byte-identical canonical Limine after the primary Limine runtime proof.
    # The second BootNext therefore arrives through \EFI\BOOT\BOOTX64.EFI and
    # must be classified by bytes, not by the generic path or "UEFI OS" label.
    candidate=$(resolve_efi_path_on_esp '\EFI\LIMINE\LIMINE_X64.EFI' 2>/dev/null || true)
    if [[ -n $candidate && -r $candidate ]]; then
        ch=$(sha256sum -- "$candidate" 2>/dev/null | awk '{print $1}' || true)
        [[ -n $ch && $ch == "$fh" ]] && limine_match=1
    fi

    if ((grub_match)); then owner=grub; owner_count=$((owner_count + 1)); fi
    if ((limine_match)); then owner=limine; owner_count=$((owner_count + 1)); fi
    ((owner_count == 1)) || return 1
    printf '%s\n' "$owner"
}

# Override only backend classification. parse_efibootmgr(), storage discovery,
# path normalization and ESP resolution remain the CachyOS r47 implementation.
detect_bootloader() {
    collect_storage_info
    parse_efibootmgr || true
    BOOTLOADER="unknown"
    DETECTION_EVIDENCE=()

    local p fallback_owner
    p=$(normalize_efi_path "${BOOT_EFI_PATH:-}")
    p=${p,,}

    case "$p" in
        efi/opensuse/shim.efi|efi/opensuse/grubx64.efi|efi/opensuse/grub.efi)
            BOOTLOADER=grub
            DETECTION_EVIDENCE+=("BootCurrent points to the native openSUSE GRUB/shim chain")
            ;;
        *limine*.efi)
            BOOTLOADER=limine
            DETECTION_EVIDENCE+=("BootCurrent EFI path points to Limine")
            ;;
        *refind*.efi)
            BOOTLOADER=refind
            DETECTION_EVIDENCE+=("BootCurrent EFI path points to rEFInd")
            ;;
        efi/systemd/systemd-bootx64.efi)
            BOOTLOADER=systemd-boot
            DETECTION_EVIDENCE+=("BootCurrent EFI path points to systemd-boot")
            ;;
        efi/boot/bootx64.efi)
            fallback_owner=$(leap16_generic_fallback_owner 2>/dev/null || true)
            case "$fallback_owner" in
                grub)
                    BOOTLOADER=grub
                    DETECTION_EVIDENCE+=("Generic UEFI fallback is byte-identical to the native openSUSE GRUB/shim chain")
                    ;;
                limine)
                    BOOTLOADER=limine
                    DETECTION_EVIDENCE+=("Generic UEFI fallback is byte-identical to canonical Limine")
                    ;;
            esac
            ;;
    esac

    # Keep the inherited bootctl fallback for systemd-boot only. Do not infer
    # openSUSE GRUB from a friendly NVRAM label when the EFI path is ambiguous.
    if [[ $BOOTLOADER == unknown ]] && have bootctl && bootctl status 2>/dev/null | grep -qi 'systemd-boot.*running\|Product:.*systemd-boot'; then
        BOOTLOADER=systemd-boot
        DETECTION_EVIDENCE+=("bootctl reports the running loader as systemd-boot")
    fi
}

# Leap kernels are exposed as /boot/vmlinuz-<uname-release> with matching
# /boot/initrd-<uname-release>. Do not force the CachyOS pkgbase naming model.
collect_kernels() {
    KERNEL_VERSIONS=()
    KERNEL_IMAGES=()
    KERNEL_PKGBASES=()
    KERNEL_SUMMARY=""

    local path ver owner pkgbase record
    local records=()
    for path in /boot/vmlinuz-*; do
        [[ -e $path ]] || continue
        ver=${path#/boot/vmlinuz-}
        [[ -n $ver && $ver != "$path" ]] || continue
        [[ -e /boot/initrd-$ver ]] || continue
        pkgbase="kernel"
        if have rpm; then
            owner=$(rpm -qf --qf '%{NAME}\n' "$path" 2>/dev/null | head -n1 || true)
            [[ -n $owner ]] && pkgbase=$owner
        fi
        records+=("$ver"$'\t'"$path"$'\t'"$pkgbase")
    done

    if ((${#records[@]})); then
        while IFS=$'\t' read -r ver path pkgbase; do
            KERNEL_VERSIONS+=("$ver")
            KERNEL_IMAGES+=("$path")
            KERNEL_PKGBASES+=("$pkgbase")
        done < <(printf '%s\n' "${records[@]}" | LC_ALL=C sort -t $'\t' -k1,1Vr)
        KERNEL_SUMMARY=$(IFS=,; printf '%s' "${KERNEL_VERSIONS[*]}")
    fi
}

# Compatibility helper used by inherited code. On Leap the kernel identity is
# the full uname release rather than an Arch pkgbase such as linux-cachyos.
kernel_pkgbase_for_version() {
    local ver=${1:-}
    [[ -n $ver && -e /boot/vmlinuz-$ver ]] || return 1
    printf '%s\n' "$ver"
}

leap16_secure_boot_state() {
    local out byte file
    if have mokutil; then
        out=$(mokutil --sb-state 2>/dev/null || true)
        case "${out,,}" in
            *"secureboot disabled"*) printf 'disabled\n'; return 0 ;;
            *"secureboot enabled"*)  printf 'enabled\n'; return 0 ;;
        esac
    fi

    file=$(compgen -G '/sys/firmware/efi/efivars/SecureBoot-*' 2>/dev/null | head -n1 || true)
    if [[ -n $file && -r $file ]] && have od; then
        # efivarfs prefixes four bytes of variable attributes before the value.
        byte=$(od -An -tu1 -j4 -N1 -- "$file" 2>/dev/null | tr -d '[:space:]' || true)
        [[ $byte == 0 ]] && { printf 'disabled\n'; return 0; }
        [[ $byte == 1 ]] && { printf 'enabled\n'; return 0; }
    fi
    printf 'unknown\n'
}

# Keep r47 backend identifiers unchanged internally (grub/limine/systemd-boot/refind),
# but do not leak the historical `grub` token into the Leap user interface.
# This is presentation-only; transaction predicates still receive `grub`.
print_system_report() {
    detect_bootloader
    collect_kernels
    printf 'Detected system:\n'
    printf '  Firmware:       %s\n' "$([[ -d /sys/firmware/efi ]] && printf UEFI || printf 'Legacy/unknown')"
    printf '  Bootloader:     %s\n' "$(bootloader_display_name "$BOOTLOADER")"
    printf '  BootCurrent:    %s\n' "${BOOT_CURRENT:-unavailable}"
    printf '  BootNext:       %s\n' "${BOOT_NEXT:-none}"
    printf '  UEFI label:     %s\n' "${BOOT_LABEL:-unavailable}"
    printf '  EFI executable: %s\n' "${BOOT_EFI_PATH:-unavailable}"
    printf '  ESP device:     %s\n' "${ESP_SOURCE:-unresolved}"
    printf '  ESP mountpoint: %s\n' "${ESP_MOUNT:-unresolved}"
    printf '  ESP filesystem: %s\n' "${ESP_FSTYPE:-unresolved}"
    printf '  ESP UUID:       %s\n' "${ESP_UUID:-unresolved}"
    printf '  Root device:    %s\n' "${ROOT_SOURCE:-unresolved}"
    printf '  Root filesystem:%s%s\n' "$([[ -n $ROOT_FSTYPE ]] && printf ' ' || printf '')" "${ROOT_FSTYPE:-unresolved}"
    printf '  Root UUID:      %s\n' "${ROOT_UUID:-unresolved}"
    printf '  Packages:       %s\n' "$(bootloader_package_state)"
    printf '  Kernels:        %s\n' "${KERNEL_SUMMARY:-none-detected}"
    printf '\nValidation:\n'
    run_validation passive
}

# Same r47 validation entry point, with only Leap-specific identity/kernel text
# added. It remains passive/read-only unless the caller explicitly selected the
# inherited preflight mode for protected read verification.
run_validation() {
    local mode=${1:-passive} secure_boot
    VALIDATION_FAILURES=0
    VALIDATION_WARNINGS=0
    detect_bootloader
    collect_kernels

    is_leap16 && v_ok 'Operating system is openSUSE Leap 16.x' || v_fail 'Operating system is not openSUSE Leap 16.x'
    [[ -d /sys/firmware/efi ]] && v_ok 'System is booted in UEFI mode' || v_fail 'System is not booted in UEFI mode'

    secure_boot=$(leap16_secure_boot_state)
    case "$secure_boot" in
        disabled) v_ok 'UEFI Secure Boot is disabled' ;;
        enabled)  v_fail 'UEFI Secure Boot is enabled; the first r47 port is not enabling a Secure Boot write path' ;;
        *)        v_warn 'UEFI Secure Boot state could not be proven' ;;
    esac

    have efibootmgr && v_ok 'efibootmgr is available' || v_fail 'efibootmgr is missing'
    [[ -n $BOOT_CURRENT ]] && v_ok "BootCurrent is available ($BOOT_CURRENT)" || v_fail 'Unable to resolve BootCurrent'
    [[ $BOOTLOADER != unknown ]] && v_ok "Currently booted bootloader identified as $(bootloader_display_name "$BOOTLOADER")" || v_fail 'Currently booted bootloader could not be identified safely'

    if [[ -n $ESP_MOUNT && -n $ESP_SOURCE ]]; then
        v_ok "ESP is mounted at $ESP_MOUNT from $ESP_SOURCE"
    else
        v_fail 'Unable to resolve a mounted EFI System Partition'
    fi

    if [[ ${ESP_FSTYPE,,} =~ ^(vfat|fat|fat32)$ ]]; then
        v_ok "ESP filesystem is $ESP_FSTYPE"
    else
        v_fail "ESP filesystem is not FAT (${ESP_FSTYPE:-unknown})"
    fi

    if [[ -n $BOOT_EFI_PATH ]]; then
        if path_exists_on_esp "$BOOT_EFI_PATH"; then
            v_ok 'BootCurrent EFI executable exists on the mounted ESP'
        elif [[ $mode == preflight ]]; then
            if path_exists_on_esp_privileged "$BOOT_EFI_PATH"; then
                v_ok 'BootCurrent EFI executable exists on the mounted ESP'
            else
                v_warn 'Could not confirm BootCurrent EFI executable at the resolved ESP mount'
            fi
        else
            v_info 'BootCurrent EFI executable requires privileged verification before protected-ESP operations'
        fi
    else
        v_warn 'BootCurrent EFI path is unavailable'
    fi

    [[ -n $ROOT_SOURCE ]] && v_ok "Root filesystem resolved to $ROOT_SOURCE" || v_fail 'Root filesystem source unresolved'
    [[ -n $ROOT_UUID ]] && v_ok "Root filesystem UUID resolved ($ROOT_UUID)" || v_warn 'Root UUID could not be resolved (valid on some stacked/device-mapper layouts)'

    if ((${#KERNEL_IMAGES[@]})); then
        v_ok "Found ${#KERNEL_IMAGES[@]} complete /boot/vmlinuz-* + /boot/initrd-* kernel pair(s)"
    else
        v_fail 'No complete /boot/vmlinuz-* + /boot/initrd-* kernel pairs found'
    fi

    if have findmnt && findmnt --verify --tab-file /etc/fstab >/dev/null 2>&1; then
        v_ok '/etc/fstab passes findmnt verification'
    else
        v_warn '/etc/fstab did not pass findmnt verification or findmnt lacks --verify support'
    fi

    printf '  Summary: %d failure(s), %d warning(s)\n' "$VALIDATION_FAILURES" "$VALIDATION_WARNINGS"
    ((VALIDATION_FAILURES == 0))
}

# /boot/grub2/grub.cfg is 0600 on a stock Leap 16 install. Deep validation may
# therefore use sudo strictly to READ that file; it never writes it.
leap16_grub_cfg_grep() {
    if [[ -r /boot/grub2/grub.cfg ]]; then
        grep "$@" /boot/grub2/grub.cfg
        return $?
    fi
    have sudo || return 1
    if sudo -n true 2>/dev/null; then
        sudo -n grep "$@" /boot/grub2/grub.cfg
        return $?
    fi
    if [[ -t 0 ]]; then
        sudo grep "$@" /boot/grub2/grub.cfg
        return $?
    fi
    return 1
}

leap16_grub_cfg_script_check() {
    if [[ -r /boot/grub2/grub.cfg ]]; then
        grub2-script-check /boot/grub2/grub.cfg
        return $?
    fi
    have sudo || return 1
    if sudo -n true 2>/dev/null; then
        sudo -n grub2-script-check /boot/grub2/grub.cfg
        return $?
    fi
    if [[ -t 0 ]]; then
        sudo grub2-script-check /boot/grub2/grub.cfg
        return $?
    fi
    return 1
}

bootloader_package_state() {
    have rpm || { printf 'unavailable'; return 0; }
    local p owner state found=0
    local pkgs=(grub2-common grub2-x86_64-efi shim efibootmgr limine refind)
    for p in "${pkgs[@]}"; do
        rpm -q "$p" >/dev/null 2>&1 || continue
        owner=other
        case "$p" in
            grub2-common|grub2-x86_64-efi|shim) owner=grub ;;
            limine) owner=limine ;;
            refind) owner=refind ;;
        esac
        [[ $owner == "$BOOTLOADER" ]] && state=CURRENT || state=INSTALLED
        ((found)) && printf ' '
        printf '%s[%s]' "$p" "$state"
        found=1
    done
    ((found)) || printf 'none-detected'
}

# The inherited name is kept so the existing menu/CLI does not need a second
# validation dispatcher. On Leap it proves the native openSUSE theme instead.
validate_cachyos_grub_theme() {
    local theme=/boot/grub2/themes/openSUSE/theme.txt configured=""
    [[ -f $theme ]] || { fail "Native openSUSE GRUB theme is missing: $theme"; return 1; }
    configured=$(sed -nE 's/^[[:space:]]*GRUB_THEME[[:space:]]*=[[:space:]]*(.*)$/\1/p' /etc/default/grub 2>/dev/null | head -n1)
    if [[ $configured == \"*\" && ${#configured} -ge 2 ]]; then configured=${configured:1:${#configured}-2}; fi
    if [[ $configured == \'*\' && ${#configured} -ge 2 ]]; then configured=${configured:1:${#configured}-2}; fi
    [[ $configured == "$theme" ]] || { fail "GRUB_THEME does not point to the native openSUSE theme (found: ${configured:-unset})"; return 1; }
    leap16_grub_cfg_grep -Fq -- "$theme" >/dev/null 2>&1 || { fail 'Generated grub.cfg does not reference the configured openSUSE theme'; return 1; }
    ok 'Native openSUSE GRUB theme is configured and referenced by grub.cfg'
}

# Read-only Leap adaptation of the current-source GRUB validator. It consumes
# the same BOOTLOADER/ESP/root/kernel globals as the r47 framework; only distro
# paths and tool names differ.
validate_grub_boot_chain() {
    local phase=${1:-current} failures=0 ver line current_efi
    printf '\nDeep GRUB2 validation (%s):\n' "$phase"

    [[ $BOOTLOADER == grub ]] && ok 'Detected current backend is GRUB2/openSUSE shim chain' || { fail "Current backend is ${BOOTLOADER:-unknown}, not GRUB2"; ((failures++)); }
    [[ -n ${BOOT_CURRENT:-} ]] && ok "BootCurrent=Boot${BOOT_CURRENT^^}" || { fail 'BootCurrent is unavailable'; ((failures++)); }
    [[ -n ${ESP_MOUNT:-} && -n ${ESP_SOURCE:-} ]] && ok "ESP topology: $ESP_SOURCE -> $ESP_MOUNT" || { fail 'ESP topology is unresolved'; ((failures++)); }

    current_efi=$(resolve_efi_path_on_esp "${BOOT_EFI_PATH:-}" 2>/dev/null || true)
    if [[ -n $current_efi && -f $current_efi ]]; then
        ok "BootCurrent EFI executable exists: $current_efi"
    else
        fail "BootCurrent EFI executable could not be resolved on the detected ESP: ${BOOT_EFI_PATH:-unknown}"
        ((failures++))
    fi

    [[ -f /boot/grub2/grub.cfg ]] && ok '/boot/grub2/grub.cfg exists' || { fail '/boot/grub2/grub.cfg is missing'; ((failures++)); }
    [[ -f /etc/default/grub ]] && ok '/etc/default/grub exists' || { fail '/etc/default/grub is missing'; ((failures++)); }

    if have grub2-script-check; then
        if leap16_grub_cfg_script_check >/dev/null 2>&1; then
            ok 'grub2-script-check accepts grub.cfg'
        else
            fail 'grub2-script-check rejected grub.cfg'
            ((failures++))
        fi
    else
        warn 'grub2-script-check is unavailable; syntax gate skipped'
    fi

    if grep -Eq '^[[:space:]]*LOADER_TYPE=.*grub2-efi' /etc/sysconfig/bootloader 2>/dev/null; then
        ok 'openSUSE LOADER_TYPE reports grub2-efi'
    else
        warn 'openSUSE LOADER_TYPE is not grub2-efi or /etc/sysconfig/bootloader is unavailable'
    fi

    collect_kernels
    if ((${#KERNEL_VERSIONS[@]} == 0)); then
        fail 'No complete /boot/vmlinuz-* + /boot/initrd-* kernel pairs were detected'
        ((failures++))
    else
        for ver in "${KERNEL_VERSIONS[@]}"; do
            [[ -e /boot/vmlinuz-$ver ]] && ok "Kernel exists: /boot/vmlinuz-$ver" || { fail "Kernel missing: /boot/vmlinuz-$ver"; ((failures++)); }
            [[ -e /boot/initrd-$ver ]] && ok "Initrd exists: /boot/initrd-$ver" || { fail "Initrd missing: /boot/initrd-$ver"; ((failures++)); }
            line=$(leap16_grub_cfg_grep -F -- "/boot/vmlinuz-$ver" 2>/dev/null | head -n1 || true)
            [[ -n $line ]] && ok "grub.cfg contains kernel $ver" || { fail "grub.cfg has no entry for kernel $ver"; ((failures++)); }
        done
    fi

    if [[ -n ${ROOT_UUID:-} ]] && leap16_grub_cfg_grep -Fq -- "root=UUID=$ROOT_UUID" >/dev/null 2>&1; then
        ok 'grub.cfg carries the detected root UUID'
    elif [[ -n ${ROOT_UUID:-} ]]; then
        fail 'grub.cfg does not carry the detected root UUID'
        ((failures++))
    fi

    validate_cachyos_grub_theme || ((failures++))
    ((failures == 0))
}

# Phase-0 support declaration. The menu still shows all four bootloaders, but
# the only first-port live edges that will eventually be enabled are GRUB2 <->
# Limine. No same-backend repair or other adapter route is admitted here.
operation_supported() {
    case "$1:$2" in
        grub:limine|limine:grub) return 0 ;;
        *) return 1 ;;
    esac
}

leap16_phase0_locked() {
    printf '\nPhase 0 is intentionally READ-ONLY.\n'
    printf 'This r01 port is testing the real CachyOS r47 detector/menu path on openSUSE Leap 16.\n'
    printf 'No package, ESP, NVRAM, pending-state, backup, restore, or resume write path is enabled yet.\n'
    printf 'First-port write scope after detection is proven: GRUB2 <-> Limine only.\n'
    return 1
}

# Hard lock every user-facing mutator while leaving the inherited engine files
# byte-for-byte present underneath this port layer.
run_live_operation() { leap16_phase0_locked; }
manage_pending_migration() { leap16_phase0_locked; }
create_current_bootloader_backup_interactive() { leap16_phase0_locked; }
create_current_bootloader_backup() { leap16_phase0_locked; }
restore_backup_interactive() { leap16_phase0_locked; }
restore_plan_interactive() { printf '\nRestore planning is not ported in Phase 0; no backup format is being reinterpreted yet.\n'; return 1; }
list_backups_interactive() { printf '\nBackup validation is not ported in Phase 0; existing CachyOS/openSUSE backups are left untouched.\n'; return 1; }
list_backups() { printf 'Backup validation is not ported in Phase 0.\n'; return 1; }
r22_resume_transaction_root() { leap16_phase0_locked >&2; }

# Avoid showing state from the original CachyOS namespace even if the user has
# run the upstream switcher on the same account. The resume engine remains
# locked, but its namespace helper is also ported so no CachyOS state can leak
# into the Phase-0 UI.
r22_default_user_state_dir() { printf '%s/.local/state/opensuse-bootloader-switcher\n' "$HOME"; }
pending_exists() { [[ -f $PENDING_STATE_FILE ]]; }


# ---------------------------------------------------------------------------
# leap16-r10: first modifying port slice — GRUB2 -> Limine candidate staging
# ---------------------------------------------------------------------------
#
# The r07 candidate stage and r08 one-shot BootNext path remain available. r10
# adds no new write boundary; it only tightens firmware-state accounting:
#   * verified stock openSUSE GRUB2 remains the current source;
#   * the generic EFI fallback remains byte-identical and untouched;
#   * a Limine payload/config/managed kernel tree is staged;
#   * one exact Limine Boot#### is created with efibootmgr --create-only;
#   * persistent BootOrder stays source-first and appends only the proven target;
#   * candidate-ready r47 transaction metadata is persisted;
#   * one-shot BootNext/runtime proof remain explicit and hardware-proven;
#   * promotion, retirement and automatic resume stay hard-locked.
#
# The transaction helpers, pending format and ownership machinery are inherited
# from CachyOS r47.  Only Leap-specific paths/payload acquisition are adapted.

LEAP16_LIMINE_VERSION="12.6.0"
LEAP16_LIMINE_ARCHIVE_URL="https://github.com/Limine-Bootloader/Limine/releases/download/v${LEAP16_LIMINE_VERSION}/limine-binary.tar.gz"
LEAP16_LIMINE_ARCHIVE_SHA256="8edf447b9c3c9bbd55b1e1e43528289ccb9fc8cb6f6f9edb4de3b7a2380671fe"
LEAP16_CACHYOS_SPLASH_URL="https://raw.githubusercontent.com/CachyOS/cachyos-wallpapers/develop/usr/share/wallpapers/cachyos-wallpapers/limine-splash.png"
LEAP16_LIMINE_NVRAM_LABEL="openSUSE Limine"

leap16_current_boot_order() {
    efibootmgr 2>/dev/null | awk -F': ' '/^BootOrder:/ {print toupper($2); exit}'
}

leap16_boot_entry_line_for_id() {
    local id=${1^^}
    efibootmgr -v 2>/dev/null | awk -v id="$id" 'BEGIN{IGNORECASE=1} $0 ~ "^Boot" id "\\*?([[:space:]]|$)" {print; exit}'
}

leap16_boot_entry_is_active() {
    local id=${1^^}
    efibootmgr 2>/dev/null | grep -Eqi "^Boot${id}\\*[[:space:]]"
}

# r10 firmware accounting ---------------------------------------------------
#
# Some ASUS firmware synthesizes BBS(...) Boot#### placeholders for CD/DVD,
# removable and network devices, then garbage-collects those variables during
# a UEFI BootNext cycle.  Those entries are firmware-owned churn, not migration
# ownership.  Real EFI-file entries remain strict: source GRUB2, every original
# non-BBS entry, and the Limine target must preserve exact relative order.

leap16_order_has_id() {
    local order=${1^^} id=${2^^}
    case ",$order," in *",$id,"*) return 0 ;; *) return 1 ;; esac
}

leap16_line_for_id_in_dump() {
    local dump=$1 id=${2^^}
    awk -v id="$id" 'BEGIN{IGNORECASE=1} $0 ~ "^Boot" id "\\*?([[:space:]]|$)" {print; exit}' <<<"$dump"
}

leap16_line_is_bbs() {
    local line=$1
    [[ $line == *'BBS('* ]]
}

leap16_pending_firmware_baseline_path() {
    local snap diag
    snap=${PENDING_TRANSACTION_SNAPSHOT_DIR:-$(leap16_diag_pending_value transaction_snapshot_dir)}
    if [[ -n $snap && -f $snap/prestage-efibootmgr-v.txt ]]; then
        printf '%s\n' "$snap/prestage-efibootmgr-v.txt"
        return 0
    fi
    diag=${PENDING_DIAGNOSTIC_PATH:-$(leap16_diag_pending_value diagnostic_path)}
    if [[ -n $diag && -f $diag/efibootmgr-v.txt ]]; then
        # Existing r07/r08 transactions predate prestage-efibootmgr-v.txt.  The
        # persisted candidate-pass diagnostic still contains every original
        # Boot#### plus the appended target, so it is sufficient to classify
        # the original IDs as BBS vs real EFI entries without restaging.
        printf '%s\n' "$diag/efibootmgr-v.txt"
        return 0
    fi
    return 1
}

leap16_snapshot_firmware_baseline() {
    local out
    [[ -n ${TRANSACTION_SNAPSHOT_DIR:-} && -d ${TRANSACTION_SNAPSHOT_DIR:-/nonexistent} ]] || {
        fail 'Transaction snapshot directory is unavailable for firmware baseline capture'
        return 1
    }
    out="$TRANSACTION_SNAPSHOT_DIR/prestage-efibootmgr-v.txt"
    efibootmgr -v >"$out" 2>&1 || { fail 'Could not capture pre-stage efibootmgr -v baseline'; return 1; }
    chmod 600 -- "$out" 2>/dev/null || true
    ok 'Captured pre-stage firmware entry baseline for BBS-aware post-boot accounting'
}

LEAP16_ORDER_REASON=""
LEAP16_ORDER_CURRENT_FULL=""
LEAP16_ORDER_EXPECTED_STABLE=""
LEAP16_ORDER_CURRENT_STABLE=""
LEAP16_ORDER_BBS_ORIGINAL=""
LEAP16_ORDER_BBS_CURRENT=""
LEAP16_ORDER_BBS_MISSING=""
LEAP16_ORDER_BBS_ADDED=""

leap16_csv_append() {
    local current=$1 value=$2
    [[ -n $current ]] && printf '%s,%s\n' "$current" "$value" || printf '%s\n' "$value"
}

leap16_assess_pending_firmware_order_mode() {
    local include_target=${1:-1}
    LEAP16_ORDER_REASON=""
    LEAP16_ORDER_CURRENT_FULL=""
    LEAP16_ORDER_EXPECTED_STABLE=""
    LEAP16_ORDER_CURRENT_STABLE=""
    LEAP16_ORDER_BBS_ORIGINAL=""
    LEAP16_ORDER_BBS_CURRENT=""
    LEAP16_ORDER_BBS_MISSING=""
    LEAP16_ORDER_BBS_ADDED=""

    local source=${PENDING_OLD_BOOT_ID:-} target=${PENDING_TARGET_BOOT_ID:-}
    local original=${PENDING_ORIGINAL_BOOT_ORDER:-} baseline_path baseline current_dump current_order
    local id line current_line base_path current_path stable="" current_stable="" orig_bbs="" cur_bbs="" missing="" added=""
    local -a ids=()

    source=${source^^}
    target=${target^^}
    original=${original^^}
    [[ $source =~ ^[0-9A-F]{4}$ && $target =~ ^[0-9A-F]{4}$ && -n $original ]] || {
        LEAP16_ORDER_REASON='pending transaction lacks source/target/original BootOrder identity'
        return 1
    }
    baseline_path=$(leap16_pending_firmware_baseline_path 2>/dev/null || true)
    [[ -n $baseline_path && -r $baseline_path ]] || {
        LEAP16_ORDER_REASON='firmware baseline is unavailable; cannot distinguish BBS churn from real EFI-entry loss'
        return 1
    }
    baseline=$(cat -- "$baseline_path" 2>/dev/null || true)
    current_dump=$(efibootmgr -v 2>/dev/null || true)
    current_order=$(awk -F': ' '/^BootOrder:/ {print toupper($2); exit}' <<<"$current_dump")
    [[ -n $current_order ]] || { LEAP16_ORDER_REASON='current BootOrder is unreadable'; return 1; }
    LEAP16_ORDER_CURRENT_FULL=$current_order

    IFS=',' read -ra ids <<<"$original"
    stable=$source
    for id in "${ids[@]}"; do
        id=${id^^}
        [[ -n $id && $id != "$source" && $id != "$target" ]] || continue
        line=$(leap16_line_for_id_in_dump "$baseline" "$id")
        [[ -n $line ]] || {
            LEAP16_ORDER_REASON="original Boot$id is missing from the recorded firmware baseline"
            return 1
        }
        if leap16_line_is_bbs "$line"; then
            orig_bbs=$(leap16_csv_append "$orig_bbs" "$id")
        else
            base_path=$(efi_path_from_efibootmgr_line "$line" 2>/dev/null || true)
            [[ -n $base_path ]] || {
                LEAP16_ORDER_REASON="original non-BBS Boot$id has no EFI-file path in the recorded baseline"
                return 1
            }
            current_line=$(leap16_line_for_id_in_dump "$current_dump" "$id")
            [[ -n $current_line ]] || {
                LEAP16_ORDER_REASON="original EFI-file Boot$id disappeared from firmware variables"
                return 1
            }
            current_path=$(efi_path_from_efibootmgr_line "$current_line" 2>/dev/null || true)
            [[ -n $current_path && $(normalize_efi_path "$current_path" | tr '[:upper:]' '[:lower:]') == $(normalize_efi_path "$base_path" | tr '[:upper:]' '[:lower:]') ]] || {
                LEAP16_ORDER_REASON="original EFI-file Boot$id changed path (expected $base_path, got ${current_path:-missing})"
                return 1
            }
            stable=$(leap16_csv_append "$stable" "$id")
        fi
    done
    if [[ $include_target == 1 ]]; then
        stable=$(leap16_csv_append "$stable" "$target")
    fi
    LEAP16_ORDER_EXPECTED_STABLE=$stable
    LEAP16_ORDER_BBS_ORIGINAL=$orig_bbs

    IFS=',' read -ra ids <<<"$current_order"
    for id in "${ids[@]}"; do
        id=${id^^}
        [[ -n $id ]] || continue
        line=$(leap16_line_for_id_in_dump "$current_dump" "$id")
        [[ -n $line ]] || {
            LEAP16_ORDER_REASON="BootOrder references Boot$id but efibootmgr -v has no matching variable"
            return 1
        }
        if leap16_line_is_bbs "$line"; then
            cur_bbs=$(leap16_csv_append "$cur_bbs" "$id")
        else
            current_stable=$(leap16_csv_append "$current_stable" "$id")
        fi
    done
    LEAP16_ORDER_CURRENT_STABLE=$current_stable
    LEAP16_ORDER_BBS_CURRENT=$cur_bbs

    IFS=',' read -ra ids <<<"$orig_bbs"
    for id in "${ids[@]}"; do
        [[ -n $id ]] || continue
        if ! leap16_order_has_id "$current_order" "$id"; then
            missing=$(leap16_csv_append "$missing" "$id")
        fi
    done
    IFS=',' read -ra ids <<<"$cur_bbs"
    for id in "${ids[@]}"; do
        [[ -n $id ]] || continue
        if ! leap16_order_has_id "$orig_bbs" "$id"; then
            added=$(leap16_csv_append "$added" "$id")
        fi
    done
    LEAP16_ORDER_BBS_MISSING=$missing
    LEAP16_ORDER_BBS_ADDED=$added

    [[ $current_stable == "$stable" ]] || {
        LEAP16_ORDER_REASON="stable EFI-file BootOrder drifted (expected $stable, got ${current_stable:-empty})"
        return 1
    }
    LEAP16_ORDER_REASON='stable EFI-file topology matches; BBS entries are firmware-owned churn only'
    return 0
}

leap16_assess_pending_firmware_order() {
    leap16_assess_pending_firmware_order_mode 1
}

leap16_validate_pending_firmware_order() {
    local context=${1:-transaction}
    if ! leap16_assess_pending_firmware_order; then
        fail "$context firmware-order gate failed: $LEAP16_ORDER_REASON"
        return 1
    fi
    ok "$context stable EFI-file BootOrder is exact ($LEAP16_ORDER_CURRENT_STABLE)"
    if [[ -n $LEAP16_ORDER_BBS_MISSING ]]; then
        warn "Firmware BBS churn: original BBS entries disappeared/left BootOrder: Boot${LEAP16_ORDER_BBS_MISSING//,/ Boot}"
    fi
    if [[ -n $LEAP16_ORDER_BBS_ADDED ]]; then
        warn "Firmware BBS churn: new BBS entries appeared: Boot${LEAP16_ORDER_BBS_ADDED//,/ Boot}"
    fi
    return 0
}

leap16_write_firmware_order_report() {
    local out=$1 phase=${2:-snapshot} rc=0
    if [[ -z ${PENDING_OLD_BOOT_ID:-} || -z ${PENDING_TARGET_BOOT_ID:-} || -z ${PENDING_ORIGINAL_BOOT_ORDER:-} ]]; then
        # Diagnostics may be captured before pending state is written.  Populate
        # only when an existing transaction identity is available.
        local old_pending_old=${PENDING_OLD_BOOT_ID:-} old_pending_target=${PENDING_TARGET_BOOT_ID:-} old_pending_order=${PENDING_ORIGINAL_BOOT_ORDER:-}
        PENDING_OLD_BOOT_ID=${PENDING_OLD_BOOT_ID:-${BOOT_CURRENT:-$(leap16_diag_pending_value old_boot_id)}}
        PENDING_TARGET_BOOT_ID=${PENDING_TARGET_BOOT_ID:-${LEAP16_CREATED_TARGET_ID:-$(leap16_diag_pending_value target_boot_id)}}
        PENDING_ORIGINAL_BOOT_ORDER=${PENDING_ORIGINAL_BOOT_ORDER:-${LEAP16_ORIGINAL_BOOT_ORDER:-$(leap16_diag_pending_value original_boot_order)}}
        if [[ -z ${PENDING_OLD_BOOT_ID:-} || -z ${PENDING_TARGET_BOOT_ID:-} || -z ${PENDING_ORIGINAL_BOOT_ORDER:-} ]]; then
            printf 'assessment=unavailable\nreason=no persisted pending transaction identity at this checkpoint\n' >"$out"
            PENDING_OLD_BOOT_ID=$old_pending_old PENDING_TARGET_BOOT_ID=$old_pending_target PENDING_ORIGINAL_BOOT_ORDER=$old_pending_order
            return 0
        fi
    fi
    if [[ $phase == rollback-pass ]]; then
        if ! leap16_assess_pending_firmware_order_mode 0; then rc=1; fi
    else
        if ! leap16_assess_pending_firmware_order; then rc=1; fi
    fi
    {
        printf 'assessment=%s\n' "$([[ $rc == 0 ]] && printf pass || printf fail)"
        printf 'reason=%s\n' "$LEAP16_ORDER_REASON"
        printf 'full_current_boot_order=%s\n' "$LEAP16_ORDER_CURRENT_FULL"
        printf 'stable_expected_boot_order=%s\n' "$LEAP16_ORDER_EXPECTED_STABLE"
        printf 'stable_current_boot_order=%s\n' "$LEAP16_ORDER_CURRENT_STABLE"
        printf 'original_bbs_ids=%s\n' "$LEAP16_ORDER_BBS_ORIGINAL"
        printf 'current_bbs_ids=%s\n' "$LEAP16_ORDER_BBS_CURRENT"
        printf 'missing_original_bbs_ids=%s\n' "$LEAP16_ORDER_BBS_MISSING"
        printf 'added_bbs_ids=%s\n' "$LEAP16_ORDER_BBS_ADDED"
    } >"$out"
    return 0
}

leap16_nvram_entry_matches_current_esp() {
    local id=${1^^} line partuuid
    line=$(leap16_boot_entry_line_for_id "$id")
    partuuid=$(lsblk -no PARTUUID -- "$ESP_SOURCE" 2>/dev/null | awk 'NF{print tolower($1); exit}')
    [[ -n $line && -n $partuuid ]] || return 1
    grep -Fqi -- "GPT,$partuuid," <<<"$line"
}

leap16_required_candidate_bytes() {
    collect_kernels
    local ver size total=0
    for ver in "${KERNEL_VERSIONS[@]}"; do
        for path in "/boot/vmlinuz-$ver" "/boot/initrd-$ver"; do
            size=$(stat -Lc '%s' -- "$path" 2>/dev/null || sudo -n stat -Lc '%s' -- "$path" 2>/dev/null || true)
            [[ $size =~ ^[0-9]+$ ]] || return 1
            total=$((total + size))
        done
    done
    printf '%s\n' "$total"
}

leap16_verify_esp_capacity() {
    local required available margin=$((32 * 1024 * 1024))
    required=$(leap16_required_candidate_bytes) || { fail 'Could not calculate Limine managed-payload space requirement'; return 1; }
    available=$(df -Pk -- "$ESP_MOUNT" 2>/dev/null | awk 'NR==2 {print $4 * 1024}')
    [[ $required =~ ^[0-9]+$ && $available =~ ^[0-9]+$ ]] || { fail 'Could not determine free space on the ESP'; return 1; }
    if (( available < required + margin )); then
        fail "ESP free space is insufficient for the exact kernel/initrd copies plus safety margin (need $((required + margin)) bytes, have $available)"
        return 1
    fi
    ok "ESP capacity is sufficient for managed kernel/initrd copies ($required bytes) plus 32 MiB safety margin"
}

leap16_download_to() {
    local url=$1 out=$2 tmp
    tmp="${out}.part"
    rm -f -- "$tmp"
    if have curl; then
        curl -fL --retry 2 --connect-timeout 20 --max-time 180 -o "$tmp" -- "$url" || { rm -f -- "$tmp"; return 1; }
    elif have wget; then
        wget -O "$tmp" -- "$url" || { rm -f -- "$tmp"; return 1; }
    else
        fail 'Neither curl nor wget is available for the pinned Limine payload download'
        return 1
    fi
    mv -f -- "$tmp" "$out"
}

leap16_is_x86_64_efi_application() {
    local payload=$1 desc
    [[ -s $payload ]] || return 1
    desc=$(file -b -- "$payload" 2>/dev/null || true)
    # file(1) wording differs across distros/releases.  Examples include:
    #   PE32+ executable (EFI application) x86-64
    #   PE32+ executable for EFI (application), x86-64
    # Require the three semantic facts without depending on their punctuation or
    # exact sentence order.  The archive itself is already pinned by SHA256.
    [[ $desc == *PE32+* ]] || return 1
    [[ ${desc,,} == *efi* ]] || return 1
    [[ ${desc,,} == *x86-64* ]] || return 1
}

leap16_prepare_limine_assets() {
    local root=${TRANSACTION_SNAPSHOT_DIR:-} archive splash payload member count actual source_archive source_splash
    [[ -n $root && -d $root ]] || { fail 'Transaction snapshot directory is unavailable for Limine payload preparation'; return 1; }
    have tar || { fail 'tar is required to extract the pinned Limine binary release'; return 1; }
    have sha256sum || { fail 'sha256sum is required to verify the pinned Limine binary release'; return 1; }

    archive="$root/limine-binary-v${LEAP16_LIMINE_VERSION}.tar.gz"
    splash="$root/limine-splash.png.source"
    payload="$root/BOOTX64.EFI.source"
    source_archive=${BOOTLOADER_SWITCHER_LIMINE_ARCHIVE:-}
    source_splash=${BOOTLOADER_SWITCHER_LIMINE_SPLASH:-}

    if [[ -n $source_archive ]]; then
        [[ -r $source_archive ]] || { fail "BOOTLOADER_SWITCHER_LIMINE_ARCHIVE is unreadable: $source_archive"; return 1; }
        cp -- "$source_archive" "$archive" || return 1
        info "Using user-supplied Limine archive override: $source_archive"
    else
        info "Downloading pinned upstream Limine v${LEAP16_LIMINE_VERSION} binary release"
        leap16_download_to "$LEAP16_LIMINE_ARCHIVE_URL" "$archive" || { fail 'Pinned Limine binary release download failed'; return 1; }
    fi

    actual=$(sha256sum -- "$archive" | awk '{print $1}')
    [[ $actual == "$LEAP16_LIMINE_ARCHIVE_SHA256" ]] || {
        fail "Pinned Limine archive hash mismatch (expected $LEAP16_LIMINE_ARCHIVE_SHA256, got ${actual:-unavailable})"
        return 1
    }
    ok "Pinned Limine v${LEAP16_LIMINE_VERSION} archive SHA256 verified"

    count=$(tar -tzf "$archive" 2>/dev/null | awk 'tolower($0) ~ /(^|\/)bootx64\.efi$/ {n++} END{print n+0}')
    [[ $count == 1 ]] || { fail "Pinned Limine archive contains $count BOOTX64.EFI candidates; expected exactly one"; return 1; }
    member=$(tar -tzf "$archive" 2>/dev/null | awk 'tolower($0) ~ /(^|\/)bootx64\.efi$/ {print; exit}')
    [[ -n $member ]] || return 1
    tar -xOzf "$archive" -- "$member" >"$payload" || { rm -f -- "$payload"; fail 'Could not extract BOOTX64.EFI from the pinned Limine archive'; return 1; }
    [[ -s $payload ]] || { fail 'Extracted Limine BOOTX64.EFI is empty'; return 1; }
    [[ $(od -An -tx1 -N2 -- "$payload" 2>/dev/null | tr -d '[:space:]') == 4d5a ]] || { fail 'Extracted Limine BOOTX64.EFI lacks an MZ executable header'; return 1; }
    if have file; then
        leap16_is_x86_64_efi_application "$payload" || {
            fail 'Extracted Limine BOOTX64.EFI is not identified as an x86-64 EFI application'
            return 1
        }
    fi
    chmod 600 -- "$payload" 2>/dev/null || true
    LEAP16_LIMINE_EFI_SOURCE=$payload

    if [[ -n $source_splash ]]; then
        [[ -r $source_splash ]] || { fail "BOOTLOADER_SWITCHER_LIMINE_SPLASH is unreadable: $source_splash"; return 1; }
        cp -- "$source_splash" "$splash" || return 1
        info "Using user-supplied CachyOS splash override: $source_splash"
    else
        info 'Downloading the CachyOS Limine splash asset used by the r47 theme'
        leap16_download_to "$LEAP16_CACHYOS_SPLASH_URL" "$splash" || { fail 'CachyOS Limine splash download failed'; return 1; }
    fi
    [[ -s $splash ]] || { fail 'CachyOS Limine splash asset is empty'; return 1; }
    [[ $(od -An -tx1 -N8 -- "$splash" 2>/dev/null | tr -d '[:space:]') == 89504e470d0a1a0a ]] || { fail 'Downloaded CachyOS Limine splash is not a PNG file'; return 1; }
    R23_LIMINE_SPLASH_SOURCE=$splash
    LEAP16_LIMINE_SPLASH_SOURCE_SHA256=$(sha256sum -- "$splash" | awk '{print $1}')
    [[ $LEAP16_LIMINE_SPLASH_SOURCE_SHA256 =~ ^[0-9A-Fa-f]{64}$ ]] || { fail 'Could not hash the CachyOS Limine splash asset'; return 1; }
    ok "CachyOS Limine splash acquired (SHA256=$LEAP16_LIMINE_SPLASH_SOURCE_SHA256)"
}

# r23 snapshots source kernel/initramfs ownership using Arch names.  Keep the
# same arrays and ownership-manifest choreography, but bind them to Leap's
# /boot/vmlinuz-<release> + /boot/initrd-<release> convention.
snapshot_source_boot_artifacts() {
    SOURCE_STAGE_ARTIFACTS=()
    SOURCE_STAGE_HASHES=()
    collect_kernels
    local ver path hash
    for ver in "${KERNEL_VERSIONS[@]}"; do
        for path in "/boot/vmlinuz-$ver" "/boot/initrd-$ver"; do
            hash=$(sudo -n sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || true)
            [[ $hash =~ ^[0-9A-Fa-f]{64}$ ]] || { fail "Could not hash source boot artifact: $path"; return 1; }
            SOURCE_STAGE_ARTIFACTS+=("$path")
            SOURCE_STAGE_HASHES+=("$hash")
        done
    done
    ok "Snapshotted hashes for ${#SOURCE_STAGE_ARTIFACTS[@]} source kernel/initrd artifact(s)"
    if [[ ${BOOTLOADER:-} == grub ]]; then
        r23_snapshot_source_grub_cleanup_ownership || return 1
        r23_snapshot_prestage_limine_splash || return 1
        r23_snapshot_prestage_limine_efi_dir || return 1
    fi
}

# Same r23 source-retirement evidence format, with the native Leap GRUB2 tree.
r23_snapshot_source_grub_cleanup_ownership() {
    [[ -n ${TRANSACTION_SNAPSHOT_DIR:-} && -d $TRANSACTION_SNAPSHOT_DIR ]] || { fail 'Transaction snapshot directory is unavailable for source GRUB2 ownership'; return 1; }
    local grub_dir=/boot/grub2 efi_dir record hash
    efi_dir=$(dirname -- "$OLD_GRUB_EFI_RESOLVED")
    sudo -n test -d "$grub_dir" 2>/dev/null || [[ -d $grub_dir ]] || { fail 'Source /boot/grub2 directory is missing before staging'; return 1; }
    sudo -n test -d "$efi_dir" 2>/dev/null || [[ -d $efi_dir ]] || { fail "Source openSUSE EFI directory is missing before staging: $efi_dir"; return 1; }
    write_privileged_tree_manifest "$grub_dir" "$TRANSACTION_SNAPSHOT_DIR/source-grub-dir.tsv" || { fail 'Could not record source /boot/grub2 ownership manifest'; return 1; }
    write_privileged_tree_manifest "$efi_dir" "$TRANSACTION_SNAPSHOT_DIR/source-grub-efi-dir.tsv" || { fail 'Could not record source openSUSE EFI directory manifest'; return 1; }
    record="$TRANSACTION_SNAPSHOT_DIR/source-grub-default.tsv"
    if [[ -f /etc/default/grub ]] || sudo -n test -f /etc/default/grub 2>/dev/null; then
        hash=$(sha256sum /etc/default/grub 2>/dev/null | awk '{print $1}' || sudo -n sha256sum /etc/default/grub 2>/dev/null | awk '{print $1}' || true)
        [[ $hash =~ ^[0-9A-Fa-f]{64}$ ]] || { fail 'Could not hash source /etc/default/grub'; return 1; }
        printf 'present\t1\nhash\t%s\npath\t/etc/default/grub\n' "$hash" >"$record" || return 1
    else
        printf 'present\t0\nhash\t\npath\t/etc/default/grub\n' >"$record" || return 1
    fi
    chmod 600 -- "$TRANSACTION_SNAPSHOT_DIR"/source-grub-*.tsv 2>/dev/null || true
    ok 'Recorded exact native openSUSE GRUB2 config/EFI ownership for future post-proof cleanup'
}

# r10 never transfers generic fallback ownership.  The r47 ownership predicate
# is adapted to require the opposite: the stock openSUSE fallback must stay
# byte-identical to the pre-stage snapshot.
r23_verify_target_limine_fallback_ownership() {
    [[ ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == grub:limine ]] || return 0
    local fallback=${PENDING_OLD_FALLBACK_PATH:-${ESP_MOUNT:-/boot}/EFI/BOOT/BOOTX64.EFI} actual
    if [[ ${PENDING_OLD_FALLBACK_EXISTED:-0} == 1 ]]; then
        actual=$(sudo -n sha256sum -- "$fallback" 2>/dev/null | awk '{print $1}' || sha256sum -- "$fallback" 2>/dev/null | awk '{print $1}' || true)
        [[ -n $actual && $actual == "$PENDING_OLD_FALLBACK_HASH" ]] || { fail 'Shared openSUSE EFI fallback changed since candidate creation'; return 1; }
        [[ -z ${PENDING_POST_STAGE_FALLBACK_HASH:-} || $PENDING_POST_STAGE_FALLBACK_HASH == "$PENDING_OLD_FALLBACK_HASH" ]] || { fail 'Recorded post-stage fallback hash does not match the preserved pre-stage fallback'; return 1; }
        ok 'Shared openSUSE EFI fallback remains byte-identical to the pre-stage source state'
    else
        [[ ! -e $fallback ]] || { fail 'A generic EFI fallback appeared even though none existed before staging'; return 1; }
        ok 'No generic EFI fallback was created by the Limine candidate stage'
    fi
}

leap16_limine_portable_cmdline() {
    local raw
    raw=$(cat /proc/cmdline 2>/dev/null || true)
    [[ -n $raw ]] || return 1
    r42_portable_limine_cmdline "$raw"
}

# Leap does not ship limine-entry-tool.  Reuse the r47 theme base and policy,
# then materialize the exact existing kernel/initrd bytes into the r47 managed
# ESP tree and append equivalent Limine entries directly.
stage_limine_kernel_entries_from_existing_artifacts() {
    collect_kernels
    have b2sum || { fail 'b2sum is required for Limine managed-payload hashes'; return 1; }
    local machine_id cmdline tmp_conf ver kid src_kernel src_initrd dst_dir dst_kernel dst_initrd kh ih
    machine_id=$(cat /etc/machine-id 2>/dev/null || true)
    [[ -n $machine_id ]] || { fail 'Machine ID is unavailable for Limine managed kernel staging'; return 1; }
    cmdline=$(leap16_limine_portable_cmdline) || { fail 'Could not derive portable Limine kernel command line'; return 1; }
    [[ -n $cmdline ]] || { fail 'Portable Limine kernel command line is empty'; return 1; }
    [[ -r "$ESP_MOUNT/limine.conf" ]] || { fail 'CachyOS-themed Limine base config is missing before kernel staging'; return 1; }

    tmp_conf=$(mktemp) || return 1
    cat -- "$ESP_MOUNT/limine.conf" >"$tmp_conf" || { rm -f -- "$tmp_conf"; return 1; }

    for ver in "${KERNEL_VERSIONS[@]}"; do
        kid=$(kernel_pkgbase_for_version "$ver" 2>/dev/null || true)
        [[ -n $kid ]] || { rm -f -- "$tmp_conf"; fail "Could not resolve Leap kernel id for $ver"; return 1; }
        src_kernel="/boot/vmlinuz-$ver"
        src_initrd="/boot/initrd-$ver"
        dst_dir="$ESP_MOUNT/$machine_id/$kid"
        dst_kernel="$dst_dir/vmlinuz-$kid"
        dst_initrd="$dst_dir/initrd-$kid"
        (sudo -n test -f "$src_kernel" 2>/dev/null || [[ -f $src_kernel ]]) || { rm -f -- "$tmp_conf"; fail "Kernel source disappeared: $src_kernel"; return 1; }
        (sudo -n test -f "$src_initrd" 2>/dev/null || [[ -f $src_initrd ]]) || { rm -f -- "$tmp_conf"; fail "Initrd source disappeared: $src_initrd"; return 1; }

        sudo mkdir -p -- "$dst_dir" || { rm -f -- "$tmp_conf"; return 1; }
        sudo install -m 0644 -- "$src_kernel" "$dst_kernel" || { rm -f -- "$tmp_conf"; return 1; }
        sudo install -m 0644 -- "$src_initrd" "$dst_initrd" || { rm -f -- "$tmp_conf"; return 1; }
        sudo cmp -s -- "$src_kernel" "$dst_kernel" || { rm -f -- "$tmp_conf"; fail "Managed Limine kernel copy differs from source: $ver"; return 1; }
        sudo cmp -s -- "$src_initrd" "$dst_initrd" || { rm -f -- "$tmp_conf"; fail "Managed Limine initrd copy differs from source: $ver"; return 1; }
        kh=$(sudo -n b2sum -- "$dst_kernel" 2>/dev/null | awk '{print $1}' || true)
        ih=$(sudo -n b2sum -- "$dst_initrd" 2>/dev/null | awk '{print $1}' || true)
        [[ $kh =~ ^[0-9A-Fa-f]{128}$ && $ih =~ ^[0-9A-Fa-f]{128}$ ]] || { rm -f -- "$tmp_conf"; fail "Could not derive BLAKE2 hashes for managed kernel $ver"; return 1; }

        cat >>"$tmp_conf" <<EOF_ENTRY
  //$kid
  ### Managed by openSUSE Bootloader Switcher
  comment: kernel-version=$ver
  comment: kernel-id=$kid
  protocol: linux
  module_path: boot():/$machine_id/$kid/initrd-$kid#$ih
  path: boot():/$machine_id/$kid/vmlinuz-$kid#$kh
  cmdline: $cmdline

EOF_ENTRY
        ok "Staged r47-style Limine managed kernel entry: $kid"
    done

    cat >>"$tmp_conf" <<'EOF_FALLBACK'
/EFI fallback
### Shared pre-transfer recovery entry; EFI/BOOT remains native openSUSE until primary Limine proof
comment: Preserved openSUSE generic fallback / GRUB2 recovery path
protocol: efi
path: boot():/EFI/BOOT/BOOTX64.EFI
EOF_FALLBACK

    sudo install -o root -g root -m 0644 -- "$tmp_conf" "$ESP_MOUNT/limine.conf" || { rm -f -- "$tmp_conf"; return 1; }
    rm -f -- "$tmp_conf"
    ok 'Completed r47-style Limine kernel entries while preserving the shared EFI fallback as a recovery menu item'
}

leap16_install_limine_efi_payload() {
    local src=${LEAP16_LIMINE_EFI_SOURCE:-} dst="$ESP_MOUNT/EFI/LIMINE/LIMINE_X64.EFI" sh dh
    [[ -r $src ]] || { fail 'Prepared Limine EFI payload is unavailable'; return 1; }
    sudo mkdir -p -- "$ESP_MOUNT/EFI/LIMINE" || return 1
    sudo install -m 0644 -- "$src" "$dst" || return 1
    sh=$(sha256sum -- "$src" | awk '{print $1}')
    dh=$(sudo -n sha256sum -- "$dst" 2>/dev/null | awk '{print $1}' || true)
    [[ -n $dh && $dh == "$sh" ]] || { fail 'Staged Limine EFI executable differs from the verified source payload'; return 1; }
    ok 'Installed verified Limine EFI payload at \EFI\LIMINE\LIMINE_X64.EFI'
}

leap16_sysfs_partition_number() {
    local src=$1 base=${1##*/}
    [[ -r /sys/class/block/$base/partition ]] || return 1
    cat -- "/sys/class/block/$base/partition" 2>/dev/null
}

leap16_udev_partition_number() {
    local src=$1
    have udevadm || return 1
    udevadm info --query=property --name="$src" 2>/dev/null \
        | sed -nE 's/^ID_PART_ENTRY_NUMBER=([0-9]+)$/\1/p' \
        | head -n1
}

leap16_esp_disk_part() {
    local src=${ESP_SOURCE:-} base parent part suffix real
    [[ -n $src ]] || return 1
    src=$(readlink -f -- "$src" 2>/dev/null || printf '%s' "$src")
    base=${src##*/}

    # PKNAME is widely available across util-linux versions.  PARTN is not:
    # Leap 16's lsblk can resolve the parent disk while exposing no PARTN field,
    # which is exactly what the r06 hardware run hit on /dev/sdc1.
    parent=$(lsblk -no PKNAME -- "$src" 2>/dev/null | awk 'NF{print; exit}')
    if [[ -z $parent && -e /sys/class/block/$base ]]; then
        real=$(readlink -f -- "/sys/class/block/$base" 2>/dev/null || true)
        [[ -n $real ]] && parent=$(basename -- "$(dirname -- "$real")")
    fi

    part=$(leap16_sysfs_partition_number "$src" 2>/dev/null | awk 'NF{print; exit}' || true)
    [[ $part =~ ^[0-9]+$ ]] || part=$(leap16_udev_partition_number "$src" 2>/dev/null | awk 'NF{print; exit}' || true)

    # Final deterministic fallback for ordinary partition names:
    #   sdc1 -> parent=sdc, part=1
    #   nvme0n1p1 -> parent=nvme0n1, part=1
    #   mmcblk0p1 -> parent=mmcblk0, part=1
    if [[ -n $parent && ! $part =~ ^[0-9]+$ && $base == "$parent"* ]]; then
        suffix=${base#"$parent"}
        suffix=${suffix#p}
        [[ $suffix =~ ^[0-9]+$ ]] && part=$suffix
    fi

    [[ -n $parent && $part =~ ^[0-9]+$ ]] || return 1
    printf '/dev/%s\t%s\n' "$parent" "$part"
}

leap16_expected_candidate_order() {
    local old_id=${1^^} target_id=${2^^} original_order=$3 id joined
    local -a ids=("$old_id") original=()
    IFS=',' read -ra original <<<"$original_order"
    for id in "${original[@]}"; do
        id=${id^^}
        [[ -n $id && $id != "$old_id" && $id != "$target_id" ]] || continue
        boot_id_exists "$id" && ids+=("$id")
    done
    ids+=("$target_id")
    joined=$(IFS=,; printf '%s' "${ids[*]}")
    printf '%s\n' "$joined"
}

leap16_create_limine_nvram_candidate() {
    local original_order=$1 topology disk part current target_id expected before_entries after_entries
    efibootmgr --help 2>&1 | grep -q -- '--create-only' || { fail 'Installed efibootmgr lacks --create-only; r13 refuses target creation'; return 1; }
    topology=$(leap16_esp_disk_part) || { fail "Could not derive parent disk/partition number from ESP source ${ESP_SOURCE:-unknown}"; return 1; }
    disk=${topology%%$'\t'*}
    part=${topology#*$'\t'}

    before_entries=$(efibootmgr -v 2>/dev/null | grep -Ei '^Boot[0-9A-Fa-f]{4}\*?[[:space:]]' | LC_ALL=C sort || true)
    sudo efibootmgr --create-only --disk "$disk" --part "$part" --label "$LEAP16_LIMINE_NVRAM_LABEL" --loader "$(target_expected_efi_path limine)" >/dev/null || {
        fail 'efibootmgr --create-only failed while creating the Limine candidate entry'
        return 1
    }

    find_nvram_entry_for_target limine || { fail 'New Limine Boot#### could not be resolved at the exact expected EFI path'; return 1; }
    target_id=$TARGET_NVRAM_ID
    [[ $(count_nvram_entries_for_target limine) == 1 ]] || { fail 'Limine NVRAM identity became ambiguous after create-only'; return 1; }
    leap16_boot_entry_is_active "$target_id" || { fail "New Limine Boot$target_id is not marked active"; return 1; }
    leap16_nvram_entry_matches_current_esp "$target_id" || { fail "New Limine Boot$target_id does not point to the detected ESP ${ESP_SOURCE:-unknown}"; return 1; }

    # --create-only must change only the new Boot#### variable.  It must not
    # touch BootOrder, BootNext or any pre-existing Boot#### payload.
    after_entries=$(efibootmgr -v 2>/dev/null | awk -v tid="$target_id" 'BEGIN{IGNORECASE=1} /^Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/ {id=substr($1,5,4); gsub(/\*/,"",id); if (toupper(id) != toupper(tid)) print}' | LC_ALL=C sort)
    [[ $after_entries == "$before_entries" ]] || { fail 'One or more pre-existing Boot#### entries changed during --create-only'; return 1; }
    [[ $(leap16_current_boot_order) == "${original_order^^}" ]] || { fail 'efibootmgr --create-only unexpectedly changed persistent BootOrder'; return 1; }
    [[ -z $(pending_bootnext_id 2>/dev/null || true) ]] || { fail 'BootNext appeared during --create-only'; return 1; }
    ok "Boot$target_id is active, bound to the detected ESP, and --create-only left BootOrder/BootNext/pre-existing entries untouched"

    # Now reproduce r47 candidate topology deliberately: source first, every
    # unrelated original entry preserved in order, and the new target last.
    set_source_first_boot_order "$BOOT_CURRENT" "$target_id" "$original_order" || return 1
    expected=$(leap16_expected_candidate_order "$BOOT_CURRENT" "$target_id" "$original_order")
    current=$(leap16_current_boot_order)
    [[ ${current^^} == ${expected^^} ]] || { fail "Persistent candidate BootOrder mismatch (expected $expected, got ${current:-missing})"; return 1; }
    [[ -z $(pending_bootnext_id 2>/dev/null || true) ]] || { fail 'BootNext appeared during r13 candidate creation; refusing to commit the stage'; return 1; }
    LEAP16_CREATED_TARGET_ID=$target_id
    LEAP16_CANDIDATE_BOOT_ORDER=$current
    ok "Created Limine Boot$target_id with --create-only, then committed r47 source-first/target-last BootOrder"
}

# The inherited uncommitted-stage cleanup already removes exact Limine target
# state and restores the original BootOrder.  r10 adds one firmware-specific
# guard: preflight proved BootNext was empty, so if a buggy --create-only or
# firmware side effect sets BootNext to the transaction-created Limine entry,
# clear that exact one-shot variable before deleting the target.  Never clear
# an unrelated BootNext that appeared concurrently.
eval "$(declare -f cleanup_uncommitted_limine_candidate | sed '1s/cleanup_uncommitted_limine_candidate/cleanup_uncommitted_limine_candidate_pre_leap16_r04/')"
cleanup_uncommitted_limine_candidate() {
    local next path expected rc=0
    next=$(pending_bootnext_id 2>/dev/null || true)
    if [[ -n $next ]]; then
        expected=$(target_expected_efi_path limine)
        path=$(boot_entry_path_for_id "$next" 2>/dev/null || true)
        if [[ -n $path && $(normalize_efi_path "$path" | tr '[:upper:]' '[:lower:]') == $(normalize_efi_path "$expected" | tr '[:upper:]' '[:lower:]') ]]; then
            if sudo efibootmgr -N >/dev/null 2>&1 && [[ -z $(pending_bootnext_id 2>/dev/null || true) ]]; then
                ok "Cleared unexpected transaction-owned BootNext=Boot$next before candidate cleanup"
            else
                warn "Could not clear unexpected transaction-owned BootNext=Boot$next before candidate cleanup"
                rc=1
            fi
        else
            warn "Unrelated BootNext=Boot$next appeared during the r13 stage; leaving it untouched"
            rc=1
        fi
    fi
    cleanup_uncommitted_limine_candidate_pre_leap16_r04 "$@" || rc=1
    return "$rc"
}

# Leap-specific deep target proof.  It intentionally does not require the
# Arch/CachyOS limine-entry-tool package; it validates the same serialized
# fields and BLAKE2-bound managed payload directly.
validate_limine_boot_chain() {
    local mode=${1:-current} reference_cmdline conf="${ESP_MOUNT:-/boot}/limine.conf"
    local ver kid conf_cmdline path_value initrd_value machine_id expected_prefix running_root failures=0 tmp_conf entry_count
    printf '\nDeep Limine boot-chain validation (%s):\n' "$mode"
    collect_kernels
    have b2sum || { ld_fail 'b2sum is unavailable'; return 1; }
    reference_cmdline=$(cat /proc/cmdline 2>/dev/null || true)
    [[ -n $reference_cmdline ]] && ld_ok 'Reference running cmdline captured from /proc/cmdline' || { ld_fail 'Running kernel command line is empty'; ((failures++)); }
    running_root=$(tr ' ' '\n' </proc/cmdline 2>/dev/null | grep -E '^root=' | head -n1 || true)
    machine_id=$(cat /etc/machine-id 2>/dev/null || true)
    [[ -n $machine_id ]] || { ld_fail 'Machine ID is unavailable'; ((failures++)); }

    if [[ -r /etc/default/limine ]] || sudo -n test -r /etc/default/limine 2>/dev/null; then
        ld_ok '/etc/default/limine exists'
        grep -Fqx "ESP_PATH=\"$ESP_MOUNT\"" /etc/default/limine 2>/dev/null || sudo -n grep -Fqx "ESP_PATH=\"$ESP_MOUNT\"" /etc/default/limine 2>/dev/null || { ld_fail '/etc/default/limine ESP_PATH does not match the detected ESP'; ((failures++)); }
    else
        ld_fail '/etc/default/limine is missing/unreadable'; ((failures++))
    fi

    tmp_conf=$(mktemp) || return 1
    if [[ -r $conf ]]; then cat -- "$conf" >"$tmp_conf"; else sudo -n cat -- "$conf" >"$tmp_conf" 2>/dev/null; fi || { rm -f -- "$tmp_conf"; ld_fail 'Could not read staged limine.conf'; return 1; }

    for ver in "${KERNEL_VERSIONS[@]}"; do
        kid=$(kernel_pkgbase_for_version "$ver" 2>/dev/null || true)
        [[ -n $kid ]] || { ld_fail "Could not resolve Leap kernel id for $ver"; ((failures++)); continue; }
        entry_count=$(limine_conf_kernel_id_count "$kid" "$tmp_conf" 2>/dev/null || printf '0')
        [[ $entry_count == 1 ]] && ld_ok "$kid appears exactly once in limine.conf" || { ld_fail "$kid appears $entry_count time(s) in limine.conf; expected one"; ((failures++)); }

        conf_cmdline=$(limine_conf_field_for_kernel "$kid" cmdline "$tmp_conf" 2>/dev/null || true)
        if [[ -n $conf_cmdline ]] && cmdline_contains_reference_tokens "$reference_cmdline" "$conf_cmdline"; then
            ld_ok "$kid preserves the running kernel cmdline tokens"
        else
            ld_fail "$kid cmdline is empty or missing required token: ${LIMINE_MISSING_CMDLINE_TOKEN:-unknown}"; ((failures++))
        fi
        if [[ -n $running_root ]] && tr ' ' '\n' <<<"$conf_cmdline" | grep -Fxq -- "$running_root"; then
            ld_ok "$kid preserves the running root argument"
        elif [[ -n $running_root ]]; then
            ld_fail "$kid does not preserve the running root argument ($running_root)"; ((failures++))
        fi

        path_value=$(limine_conf_field_for_kernel "$kid" path "$tmp_conf" 2>/dev/null || true)
        initrd_value=$(limine_conf_field_for_kernel "$kid" module_path "$tmp_conf" 2>/dev/null || true)
        expected_prefix="boot():/$machine_id/$kid/"
        [[ $path_value == "$expected_prefix"vmlinuz-"$kid"\#* ]] || { ld_fail "$kid kernel path is outside the expected r47 managed namespace"; ((failures++)); }
        [[ $initrd_value == "$expected_prefix"initrd-"$kid"\#* ]] || { ld_fail "$kid initrd path is outside the expected r47 managed namespace"; ((failures++)); }
        verify_limine_uri_hash "$path_value" && ld_ok "$kid managed kernel BLAKE2 hash verifies" || { ld_fail "$kid managed kernel BLAKE2 hash failed"; ((failures++)); }
        verify_limine_uri_hash "$initrd_value" && ld_ok "$kid managed initrd BLAKE2 hash verifies" || { ld_fail "$kid managed initrd BLAKE2 hash failed"; ((failures++)); }
    done

    if declare -F leap16_validate_limine_recovery_contract >/dev/null 2>&1 && leap16_validate_limine_recovery_contract "$tmp_conf"; then
        ld_ok "${LEAP16_LIMINE_RECOVERY_DETAIL:-Limine recovery/fallback topology matches the active transaction contract}"
    else
        ld_fail 'Limine recovery/fallback topology does not match the active transaction contract'; ((failures++))
    fi
    rm -f -- "$tmp_conf"

    validate_cachyos_limine_theme || ((failures++))
    if path_exists_on_esp_privileged "$(target_expected_efi_path limine)"; then
        ld_ok 'Limine EFI executable exists at the exact r47 target path'
    else
        ld_fail 'Limine EFI executable is missing at the exact r47 target path'; ((failures++))
    fi
    printf '  Limine deep summary: %d failure(s)\n' "$failures"
    ((failures == 0))
}

leap16_verify_fallback_unchanged_now() {
    local actual
    if ((OLD_FALLBACK_EXISTED)); then
        actual=$(sudo -n sha256sum -- "$OLD_FALLBACK_PATH" 2>/dev/null | awk '{print $1}' || true)
        [[ -n $actual && $actual == "$OLD_FALLBACK_HASH" ]] || { fail 'Generic EFI fallback changed during Limine candidate staging'; return 1; }
        POST_STAGE_FALLBACK_HASH=$actual
        ok 'Generic EFI fallback remained byte-identical throughout candidate staging'
    else
        [[ ! -e $OLD_FALLBACK_PATH ]] || { fail 'Generic EFI fallback was created unexpectedly'; return 1; }
        POST_STAGE_FALLBACK_HASH=""
        ok 'No generic EFI fallback was created during candidate staging'
    fi
}

run_switch_preflight() {
    local target=${1:-} current_order first machine_id
    printf '\nLeap 16 GRUB2 -> Limine write preflight:\n'
    [[ $target == limine ]] || { fail 'this Leap transaction only admits the GRUB2 -> Limine target'; return 1; }
    run_validation preflight || { printf '\nPreflight failed. Nothing was modified.\n'; return 1; }
    is_leap16 || { fail 'This port slice requires openSUSE Leap 16.x'; return 1; }
    [[ $BOOTLOADER == grub ]] || { fail 'this transaction requires the proven native openSUSE GRUB2 source'; return 1; }
    case "$(normalize_efi_path "${BOOT_EFI_PATH:-}" | tr '[:upper:]' '[:lower:]')" in
        efi/opensuse/shim.efi|efi/opensuse/grubx64.efi|efi/opensuse/grub.efi) ;;
        *) fail 'BootCurrent is not the canonical native openSUSE GRUB2/shim NVRAM path'; return 1 ;;
    esac
    pending_exists && { fail 'A staged migration is already pending; the Leap adapter will not stack transactions'; return 1; }
    [[ -z ${BOOT_NEXT:-} ]] || { fail "BootNext is already set to Boot${BOOT_NEXT^^}; the Leap adapter refuses to overwrite unrelated one-time intent"; return 1; }
    current_order=$(leap16_current_boot_order)
    [[ -n $current_order ]] || { fail 'Persistent BootOrder could not be read'; return 1; }
    first=${current_order%%,*}
    [[ ${first^^} == ${BOOT_CURRENT^^} ]] || { fail "Canonical source Boot${BOOT_CURRENT^^} is not first in persistent BootOrder ($current_order)"; return 1; }

    have sudo || { fail 'sudo is required for the candidate stage'; return 1; }
    if sudo -n true 2>/dev/null; then :; elif [[ -t 0 ]]; then sudo -v || return 1; else fail 'sudo credentials are unavailable in this non-interactive session'; return 1; fi
    for _cmd in efibootmgr lsblk findmnt sha256sum b2sum tar od cmp stat df; do have "$_cmd" || { fail "Required command is missing: $_cmd"; return 1; }; done
    (have curl || have wget || [[ -n ${BOOTLOADER_SWITCHER_LIMINE_ARCHIVE:-} ]]) || { fail 'curl or wget is required unless BOOTLOADER_SWITCHER_LIMINE_ARCHIVE points to the pinned archive'; return 1; }
    efibootmgr --help 2>&1 | grep -q -- '--create-only' || { fail 'Installed efibootmgr does not support --create-only'; return 1; }

    validate_grub_boot_chain current || { fail 'Native openSUSE GRUB2 deep validation failed; refusing the write boundary'; return 1; }
    find_nvram_entry_for_target limine && { fail "A Limine Boot#### already exists at the exact target path (Boot$TARGET_NVRAM_ID)"; return 1; }
    [[ $(count_nvram_entries_for_target limine) == 0 ]] || { fail 'Pre-existing Limine NVRAM state is ambiguous'; return 1; }
    path_exists_on_esp_privileged "$(target_expected_efi_path limine)" && { fail 'Target Limine EFI executable already exists'; return 1; }
    sudo -n test -d "$ESP_MOUNT/EFI/LIMINE" 2>/dev/null && { fail 'EFI/LIMINE already exists; the Leap adapter requires a clean target namespace'; return 1; }
    sudo -n test -e "$ESP_MOUNT/limine.conf" 2>/dev/null && { fail 'limine.conf already exists; the Leap adapter requires a clean target namespace'; return 1; }
    sudo -n test -e "$ESP_MOUNT/$R23_LIMINE_SPLASH_NAME" 2>/dev/null && { fail "$R23_LIMINE_SPLASH_NAME already exists; the Leap adapter requires a clean target namespace"; return 1; }
    [[ ! -e /etc/default/limine ]] || { fail '/etc/default/limine already exists; the Leap adapter refuses to overwrite it'; return 1; }
    machine_id=$(cat /etc/machine-id 2>/dev/null || true)
    [[ -n $machine_id ]] || { fail 'Machine ID is unavailable'; return 1; }
    sudo -n test -e "$ESP_MOUNT/$machine_id" 2>/dev/null && { fail "r47 managed Limine directory already exists: $ESP_MOUNT/$machine_id"; return 1; }
    sudo -n test -f "$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI" 2>/dev/null || { fail 'Shared EFI/BOOT/BOOTX64.EFI fallback is missing; the Leap adapter requires the existing GRUB2 recovery path'; return 1; }

    collect_kernels
    ((${#KERNEL_VERSIONS[@]} > 0)) || { fail 'No complete Leap kernel/initrd pairs are available for Limine'; return 1; }
    leap16_verify_esp_capacity || return 1
    ok 'GRUB2 -> Limine preflight passed: clean Limine target, exact GRUB2 source, BootNext empty, source first in BootOrder'
}

show_operation_plan() {
    local current=$1 target=$2
    if [[ $current:$target != grub:limine ]]; then
        printf '\nThis operation is not enabled in this Leap release.\n'
        return 0
    fi
    printf '\nExact GRUB2 -> Limine automated candidate plan:\n'
    printf '  1. Re-prove the native openSUSE GRUB2/shim source, ESP, kernels, Secure Boot state, BootCurrent and source-first BootOrder.\n'
    printf '  2. Snapshot source GRUB2 EFI/config/kernel ownership plus the current shared EFI fallback hash.\n'
    printf '  3. Download/verify pinned upstream Limine v%s and fetch the CachyOS r47 Limine splash.\n' "$LEAP16_LIMINE_VERSION"
    printf '  4. Write the CachyOS r47 Limine palette/base, copy every existing Leap kernel+initrd into the r47 managed ESP tree, and bind paths with BLAKE2 hashes.\n'
    printf '  5. Install only %s; do NOT replace EFI/BOOT/BOOTX64.EFI.\n' "$(target_expected_efi_path limine)"
    printf '  6. Deep-validate the on-disk Limine candidate and preserved GRUB2 recovery menu/fallback.\n'
    printf '  7. Create exactly one %s Boot#### with efibootmgr --create-only.\n' "$LEAP16_LIMINE_NVRAM_LABEL"
    printf '  8. Commit the r47 candidate topology: source GRUB2 first, original entries preserved, Limine target appended last; BootNext remains unset.\n'
    printf '  9. Re-prove source artifacts + fallback, record exact candidate ownership, capture a timestamped Leap diagnostic folder, and persist r47 candidate-ready state.\n'
    printf ' 10. Persist candidate-ready, automatically arm BootNext, install the temporary root-owned resume service, then optionally reboot. Runtime proof may promote Limine; GRUB2 retirement remains locked.\n'
}

# r13 exposes only this single write edge.  The eventual reverse direction is
# intentionally left closed until this first target stage is hardware-proven.
operation_supported() {
    [[ $1:$2 == grub:limine ]]
}

leap16_stage_diagnostic() {
    local phase=${1:-stage-snapshot}
    capture_limine_diagnostics "$phase" >/dev/null 2>&1 || true
    [[ -n ${LIMINE_DIAGNOSTIC_DIR:-} ]] && printf 'Diagnostic snapshot: %s\n' "$LIMINE_DIAGNOSTIC_DIR"
}

leap16_abort_uncommitted_candidate() {
    local phase=$1 original_order=$2 old_id=$3
    # Capture before rollback so limine.conf, EFI/LIMINE and the exact firmware
    # state at the failure boundary remain inspectable, matching r47 behavior.
    leap16_stage_diagnostic "$phase"
    cleanup_uncommitted_limine_candidate "$original_order" "$old_id" || true
    return 1
}

execute_grub_to_limine() {
    local old_id=${BOOT_CURRENT^^} original_order target_id=""
    original_order=$(leap16_current_boot_order)
    [[ -n $original_order ]] || { fail 'Persistent BootOrder became unreadable at the write boundary'; leap16_stage_diagnostic bootorder-read-failed; return 1; }
    LEAP16_ORIGINAL_BOOT_ORDER=$original_order
    LIMINE_DEFAULT_CREATED=0
    LIMINE_DEFAULT_HASH=""

    snapshot_grub_fallback_ownership || { leap16_stage_diagnostic source-fallback-snapshot-failed; return 1; }
    snapshot_source_boot_artifacts || {
        leap16_stage_diagnostic source-artifact-snapshot-failed
        [[ -n ${TRANSACTION_SNAPSHOT_DIR:-} ]] && rm -rf -- "$TRANSACTION_SNAPSHOT_DIR" 2>/dev/null || true
        return 1
    }
    leap16_snapshot_firmware_baseline || {
        leap16_stage_diagnostic firmware-baseline-snapshot-failed
        [[ -n ${TRANSACTION_SNAPSHOT_DIR:-} ]] && rm -rf -- "$TRANSACTION_SNAPSHOT_DIR" 2>/dev/null || true
        return 1
    }

    leap16_prepare_limine_assets || { leap16_abort_uncommitted_candidate asset-prepare-failed "$original_order" "$old_id"; return 1; }
    write_limine_candidate_policy || { leap16_abort_uncommitted_candidate candidate-policy-failed "$original_order" "$old_id"; return 1; }
    stage_limine_kernel_entries_from_existing_artifacts || { leap16_abort_uncommitted_candidate candidate-kernel-stage-failed "$original_order" "$old_id"; return 1; }
    leap16_install_limine_efi_payload || { leap16_abort_uncommitted_candidate candidate-efi-stage-failed "$original_order" "$old_id"; return 1; }

    printf '\nOn-disk Limine candidate gate (before any NVRAM creation):\n'
    validate_limine_boot_chain migration || {
        fail 'On-disk Limine candidate failed deep validation. No Limine Boot#### was committed.'
        leap16_abort_uncommitted_candidate candidate-deep-failed "$original_order" "$old_id"
        return 1
    }
    leap16_verify_fallback_unchanged_now || { leap16_abort_uncommitted_candidate fallback-integrity-failed "$original_order" "$old_id"; return 1; }
    verify_source_boot_artifacts_unchanged || { leap16_abort_uncommitted_candidate source-artifact-integrity-failed "$original_order" "$old_id"; return 1; }

    printf '\nCreating isolated Limine firmware candidate:\n'
    LEAP16_CREATED_TARGET_ID=""
    if ! leap16_create_limine_nvram_candidate "$original_order"; then
        leap16_abort_uncommitted_candidate candidate-nvram-stage-failed "$original_order" "$old_id"
        return 1
    fi
    target_id=${LEAP16_CREATED_TARGET_ID:-}
    [[ $target_id =~ ^[0-9A-Fa-f]{4}$ ]] || {
        fail 'Internal target Boot#### identity capture failed'
        leap16_abort_uncommitted_candidate candidate-nvram-identity-failed "$original_order" "$old_id"
        return 1
    }
    target_id=${target_id^^}

    detect_bootloader
    [[ ${BOOT_CURRENT^^} == "$old_id" && $BOOTLOADER == grub ]] || {
        fail 'Source identity changed unexpectedly during candidate staging'
        leap16_abort_uncommitted_candidate source-identity-changed "$original_order" "$old_id"
        return 1
    }
    [[ $(leap16_current_boot_order) == "${LEAP16_CANDIDATE_BOOT_ORDER^^}" ]] || {
        fail 'Persistent source-first/target-last BootOrder changed after candidate creation'
        leap16_abort_uncommitted_candidate candidate-bootorder-changed "$original_order" "$old_id"
        return 1
    }
    [[ -z ${BOOT_NEXT:-} ]] || {
        fail 'BootNext became set during a stage that must not arm it'
        leap16_abort_uncommitted_candidate unexpected-bootnext "$original_order" "$old_id"
        return 1
    }

    printf '\nSource recovery invariants after target generation:\n'
    verify_source_grub_recovery_state "$old_id" || { leap16_abort_uncommitted_candidate source-recovery-failed "$original_order" "$old_id"; return 1; }
    verify_source_boot_artifacts_unchanged || { leap16_abort_uncommitted_candidate source-artifact-poststage-failed "$original_order" "$old_id"; return 1; }
    leap16_verify_fallback_unchanged_now || { leap16_abort_uncommitted_candidate fallback-poststage-failed "$original_order" "$old_id"; return 1; }
    validate_target_state limine || { leap16_abort_uncommitted_candidate candidate-structural-failed "$original_order" "$old_id"; return 1; }
    validate_limine_boot_chain migration || { leap16_abort_uncommitted_candidate candidate-deep-postnvram-failed "$original_order" "$old_id"; return 1; }
    find_nvram_entry_for_target limine || { leap16_abort_uncommitted_candidate candidate-nvram-missing "$original_order" "$old_id"; return 1; }
    [[ ${TARGET_NVRAM_ID^^} == "$target_id" ]] || {
        fail 'Target Boot#### identity changed during validation'
        leap16_abort_uncommitted_candidate candidate-nvram-identity-changed "$original_order" "$old_id"
        return 1
    }
    snapshot_limine_candidate_metadata || { leap16_abort_uncommitted_candidate candidate-metadata-snapshot-failed "$original_order" "$old_id"; return 1; }

    # r23 metadata normally expects Limine to own the generic fallback after its
    # historical --fallback install.  r10 deliberately records the preserved
    # source hash instead.
    POST_STAGE_FALLBACK_HASH=${OLD_FALLBACK_HASH:-}

    # Match r47: capture candidate-pass before the pending state is serialized,
    # so diagnostic_path is persisted in candidate-ready metadata.
    leap16_stage_diagnostic candidate-pass
    if ! write_pending_grub_to_limine "$old_id" "$original_order" "$target_id" candidate-ready; then
        fail 'Could not persist r47 candidate-ready migration metadata'
        leap16_abort_uncommitted_candidate pending-state-write-failed "$original_order" "$old_id"
        return 1
    fi

    printf '\nCANDIDATE-READY Limine stage completed.\n'
    printf '  Source:       GRUB2 Boot%s (still current)\n' "$old_id"
    printf '  Target:       Limine Boot%s\n' "$target_id"
    printf '  BootOrder:    %s (GRUB2 first; Limine appended last)\n' "$LEAP16_CANDIDATE_BOOT_ORDER"
    printf '  BootNext:     unset\n'
    printf '  EFI fallback: preserved byte-for-byte\n'
    [[ -n ${LIMINE_DIAGNOSTIC_DIR:-} ]] && printf '  Diagnostics:  %s\n' "$LIMINE_DIAGNOSTIC_DIR"
    printf '\nPrimary Limine candidate staging completed; automatic arming/resume preparation follows.\n'
    printf 'Do not manually change BootOrder or BootNext; the transaction owns the automated continuation.\n'
}

run_live_operation() {
    local target=${1:-} current
    detect_bootloader
    current=$BOOTLOADER
    if [[ $current:$target != grub:limine ]]; then
        printf '\nThis Leap release enables only the supported GRUB2 <-> Limine write paths.\n'
        printf 'The selected %s -> %s operation remains locked.\n' "$(bootloader_display_name "$current")" "$(bootloader_display_name "$target")"
        return 2
    fi
    run_switch_preflight "$target" || return 1
    show_operation_plan "$current" "$target"
    if ! confirm_operation "$current" "$target"; then
        printf '\nOperation cancelled. No boot state was modified.\n'
        return 0
    fi
    printf '\nRe-running the complete read-only preflight at the write boundary...\n'
    run_switch_preflight "$target" || { printf '\nWrite-boundary revalidation failed. Nothing was modified.\n'; return 1; }
    printf '\nExecuting GRUB2 -> Limine primary candidate stage...\n'
    execute_grub_to_limine
}

# leap16-r10 opens exactly one post-candidate continuation: a one-shot
# BootNext test of the already-staged Limine candidate. Persistent BootOrder
# stays source-first throughout; promotion/source retirement/auto-resume remain
# hard-locked. The runtime gate records exact BootCurrent proof but never turns
# that proof into a persistent firmware-policy change.

leap16_require_sudo_session() {
    have sudo || { fail 'sudo is required for one-shot transaction validation'; return 1; }
    if sudo -n true 2>/dev/null; then
        return 0
    fi
    if [[ -t 0 ]]; then
        sudo -v || return 1
        return 0
    fi
    fail 'sudo credentials are unavailable in this non-interactive session'
    return 1
}

leap16_expected_pending_candidate_order() {
    leap16_expected_candidate_order "$PENDING_OLD_BOOT_ID" "$PENDING_TARGET_BOOT_ID" "$PENDING_ORIGINAL_BOOT_ORDER"
}

# validate_grub_boot_chain() is intentionally a current-boot validator, so it
# cannot be reused verbatim while Limine is BootCurrent. r10 adds a recorded-
# source validator that proves the parked GRUB2 recovery chain without lying to
# the detector about which EFI executable actually booted this session.
leap16_validate_recorded_grub_source_recovery() {
    local failures=0 current_hash order ver line dm em efi_dir fallback_hash
    printf '\nRecorded source GRUB2 recovery validation:\n'

    nvram_id_matches_path "$PENDING_OLD_BOOT_ID" "$PENDING_OLD_BOOT_EFI_PATH" \
        && ok "Recorded source Boot$PENDING_OLD_BOOT_ID still points to $PENDING_OLD_BOOT_EFI_PATH" \
        || { fail 'Recorded source GRUB2 NVRAM path changed'; ((failures++)); }

    order=$(leap16_current_boot_order 2>/dev/null || true)
    if ! leap16_validate_pending_firmware_order 'Recorded source recovery'; then
        ((failures++))
    fi

    current_hash=$(sudo -n sha256sum -- "$PENDING_OLD_GRUB_EFI_RESOLVED" 2>/dev/null | awk '{print $1}' || true)
    [[ -n $current_hash && $current_hash == "$PENDING_OLD_GRUB_HASH" ]] \
        && ok 'Recorded source GRUB2 EFI executable is byte-identical to the candidate snapshot' \
        || { fail 'Recorded source GRUB2 EFI executable changed since candidate creation'; ((failures++)); }

    [[ -f /boot/grub2/grub.cfg ]] && ok '/boot/grub2/grub.cfg exists' || { fail '/boot/grub2/grub.cfg is missing'; ((failures++)); }
    [[ -f /etc/default/grub ]] && ok '/etc/default/grub exists' || { fail '/etc/default/grub is missing'; ((failures++)); }
    if have grub2-script-check; then
        leap16_grub_cfg_script_check >/dev/null 2>&1 \
            && ok 'grub2-script-check still accepts the recorded source grub.cfg' \
            || { fail 'grub2-script-check rejected the recorded source grub.cfg'; ((failures++)); }
    else
        warn 'grub2-script-check is unavailable; source syntax gate skipped'
    fi
    grep -Eq '^[[:space:]]*LOADER_TYPE=.*grub2-efi' /etc/sysconfig/bootloader 2>/dev/null \
        && ok 'openSUSE LOADER_TYPE still reports grub2-efi' \
        || warn 'openSUSE LOADER_TYPE is not grub2-efi or /etc/sysconfig/bootloader is unavailable'

    collect_kernels
    if ((${#KERNEL_VERSIONS[@]} == 0)); then
        fail 'No complete source /boot/vmlinuz-* + /boot/initrd-* pairs remain'
        ((failures++))
    else
        for ver in "${KERNEL_VERSIONS[@]}"; do
            [[ -e /boot/vmlinuz-$ver ]] && ok "Source kernel exists: /boot/vmlinuz-$ver" || { fail "Source kernel missing: /boot/vmlinuz-$ver"; ((failures++)); }
            [[ -e /boot/initrd-$ver ]] && ok "Source initrd exists: /boot/initrd-$ver" || { fail "Source initrd missing: /boot/initrd-$ver"; ((failures++)); }
            line=$(leap16_grub_cfg_grep -F -- "/boot/vmlinuz-$ver" 2>/dev/null | head -n1 || true)
            [[ -n $line ]] && ok "Source grub.cfg still contains kernel $ver" || { fail "Source grub.cfg has no entry for kernel $ver"; ((failures++)); }
        done
    fi
    if [[ -n ${PENDING_ROOT_UUID:-} ]] && leap16_grub_cfg_grep -Fq -- "root=UUID=$PENDING_ROOT_UUID" >/dev/null 2>&1; then
        ok 'Source grub.cfg still carries the transaction root UUID'
    else
        fail 'Source grub.cfg no longer carries the transaction root UUID'
        ((failures++))
    fi
    validate_cachyos_grub_theme || ((failures++))

    dm=$(r23_source_grub_dir_manifest_path)
    em=$(r23_source_grub_efi_dir_manifest_path)
    efi_dir=$(dirname -- "$PENDING_OLD_GRUB_EFI_RESOLVED")
    if [[ -s $dm ]] && pending_verify_tree_manifest /boot/grub2 "$dm"; then
        ok 'Source /boot/grub2 tree still matches the exact pre-stage ownership manifest'
    else
        fail 'Source /boot/grub2 tree changed since candidate creation'
        ((failures++))
    fi
    if [[ -s $em ]] && pending_verify_tree_manifest "$efi_dir" "$em"; then
        ok 'Source openSUSE EFI namespace still matches the exact pre-stage ownership manifest'
    else
        fail 'Source openSUSE EFI namespace changed since candidate creation'
        ((failures++))
    fi

    if [[ ${PENDING_OLD_FALLBACK_EXISTED:-0} == 1 ]]; then
        fallback_hash=$(sudo -n sha256sum -- "$PENDING_OLD_FALLBACK_PATH" 2>/dev/null | awk '{print $1}' || true)
        [[ -n $fallback_hash && $fallback_hash == "$PENDING_OLD_FALLBACK_HASH" ]] \
            && ok 'Shared EFI fallback still matches the exact pre-stage source bytes' \
            || { fail 'Shared EFI fallback changed since candidate creation'; ((failures++)); }
    else
        [[ ! -e $PENDING_OLD_FALLBACK_PATH ]] \
            && ok 'No shared EFI fallback appeared after candidate creation' \
            || { fail 'A shared EFI fallback appeared although none existed at staging time'; ((failures++)); }
    fi

    ((failures == 0))
}

# Preserve the inherited/source-session behavior, but use the recorded-source
# validator when runtime proof is being performed from the Limine target.
eval "$(declare -f verify_pending_source_recovery_unchanged | sed '1s/verify_pending_source_recovery_unchanged/verify_pending_source_recovery_unchanged_pre_leap16_r10/')"
verify_pending_source_recovery_unchanged() {
    if [[ ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == grub:limine && ${BOOTLOADER:-} == limine ]]; then
        leap16_validate_recorded_grub_source_recovery
    else
        verify_pending_source_recovery_unchanged_pre_leap16_r10 "$@"
    fi
}

leap16_capture_required_diagnostic() {
    local phase=$1 out
    out=$(leap16_capture_diagnostics "$phase" 2>/dev/null | tail -n1 || true)
    [[ -n $out && -d $out ]] || return 1
    printf '%s\n' "$out"
}

arm_pending_one_time_boot() {
    validate_pending_compatibility || { fail "Pending migration is not compatible: $PENDING_REASON"; return 1; }
    [[ $PENDING_PHASE == candidate-ready ]] || { fail "One-time boot can only be armed from candidate-ready (current phase: $PENDING_PHASE)"; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == ${PENDING_OLD_BOOT_ID^^} ]] || {
        fail "Arming requires recorded source GRUB2 Boot$PENDING_OLD_BOOT_ID to be running"
        return 1
    }
    leap16_require_sudo_session || return 1

    run_validation preflight || return 1
    validate_pending_compatibility || { fail "Pending migration became incompatible during preflight: $PENDING_REASON"; return 1; }
    verify_pending_source_recovery_unchanged || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    printf '\nRe-validating the Limine candidate immediately before BootNext arming:\n'
    validate_pending_target_deep || { fail 'Candidate deep validation failed; BootNext was NOT set'; return 1; }

    local next before_order after_order answer diag
    next=$(pending_bootnext_id)
    [[ -z $next ]] || { fail "BootNext is already set to Boot$next; refusing to overwrite firmware intent"; return 1; }
    before_order=$(leap16_current_boot_order)
    [[ -n $before_order ]] || { fail 'Persistent BootOrder is unreadable'; return 1; }
    leap16_validate_pending_firmware_order 'Pre-arm candidate' || return 1
    nvram_id_matches_path "$PENDING_TARGET_BOOT_ID" "$PENDING_TARGET_EFI_PATH" || { fail 'Target NVRAM entry no longer has the recorded exact EFI path'; return 1; }
    leap16_nvram_entry_matches_current_esp "$PENDING_TARGET_BOOT_ID" || { fail 'Target NVRAM entry no longer resolves to the detected ESP'; return 1; }

    printf '\nOne-shot Limine firmware test:\n'
    printf '  BootCurrent now:           Boot%s (GRUB2 source)\n' "$PENDING_OLD_BOOT_ID"
    printf '  Persistent BootOrder:      %s\n' "$before_order"
    printf '  One-time BootNext target:  Boot%s (Limine)\n' "$PENDING_TARGET_BOOT_ID"
    printf '  Persistent promotion:      DISABLED\n'
    printf '  Source retirement:         DISABLED\n'
    printf '  Automatic reboot/resume:   DISABLED\n'
    printf '\nType ARM to set BootNext exactly once, or anything else to cancel: '
    read -r answer
    [[ $answer == ARM ]] || { printf 'BootNext arming cancelled.\n'; return 0; }

    if ! sudo efibootmgr -n "$PENDING_TARGET_BOOT_ID" >/dev/null; then
        leap16_stage_diagnostic bootnext-set-failed
        fail 'efibootmgr could not set BootNext'
        return 1
    fi
    next=$(pending_bootnext_id)
    after_order=$(leap16_current_boot_order)
    if [[ $next != "$PENDING_TARGET_BOOT_ID" || ${after_order^^} != ${before_order^^} ]]; then
        leap16_stage_diagnostic bootnext-postwrite-invariant-failed
        if [[ $next == "$PENDING_TARGET_BOOT_ID" ]]; then sudo efibootmgr -N >/dev/null 2>&1 || true; fi
        fail "BootNext arming invariant failed (BootNext=${next:-none}, BootOrder=${after_order:-unknown})"
        return 1
    fi
    if ! pending_set_phase boot-armed; then
        leap16_stage_diagnostic bootnext-phase-write-failed
        sudo efibootmgr -N >/dev/null 2>&1 || true
        fail 'Could not persist boot-armed transaction phase; transaction BootNext was cleared'
        return 1
    fi

    detect_bootloader
    [[ ${BOOT_CURRENT^^} == ${PENDING_OLD_BOOT_ID^^} && $BOOTLOADER == grub ]] || {
        leap16_stage_diagnostic bootnext-source-identity-failed
        sudo efibootmgr -N >/dev/null 2>&1 || true
        pending_set_phase candidate-ready >/dev/null 2>&1 || true
        fail 'Source identity changed immediately after BootNext arming'
        return 1
    }
    [[ ${BOOT_NEXT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || {
        leap16_stage_diagnostic bootnext-refresh-failed
        sudo efibootmgr -N >/dev/null 2>&1 || true
        pending_set_phase candidate-ready >/dev/null 2>&1 || true
        fail 'Refreshed firmware state does not show the exact transaction BootNext'
        return 1
    }
    [[ $(leap16_current_boot_order) == "$before_order" ]] || {
        leap16_stage_diagnostic bootnext-bootorder-drift
        sudo efibootmgr -N >/dev/null 2>&1 || true
        pending_set_phase candidate-ready >/dev/null 2>&1 || true
        fail 'Persistent BootOrder changed after BootNext arming'
        return 1
    }

    diag=$(leap16_capture_required_diagnostic bootnext-armed || true)
    if [[ -z $diag ]]; then
        sudo efibootmgr -N >/dev/null 2>&1 || true
        pending_set_phase candidate-ready >/dev/null 2>&1 || true
        fail 'BootNext was armed but the required diagnostic snapshot could not be created; BootNext was cleared'
        return 1
    fi
    ok "BootNext is armed exactly once for target Boot$PENDING_TARGET_BOOT_ID"
    ok "Persistent BootOrder remains byte-for-byte unchanged ($before_order)"
    printf 'Diagnostic snapshot: %s\n' "$diag"
    printf '\nBOOTNEXT-ARMED. This manual recovery path does not reboot automatically.\n'
    printf 'Reboot normally when ready. If Limine boots, run this tool BEFORE another reboot and choose selector [2].\n'
    printf 'Persistent GRUB2-first BootOrder is still the recovery policy.\n'
}

validate_pending_target_runtime() {
    validate_pending_compatibility || { fail "Pending migration is not compatible: $PENDING_REASON"; return 1; }
    [[ $PENDING_PHASE == boot-armed || $PENDING_PHASE == runtime-validated ]] || {
        fail "Runtime validation requires a tool-armed one-time boot (phase is $PENDING_PHASE)"
        return 1
    }
    detect_bootloader
    [[ $BOOTLOADER == limine ]] || { fail "Current bootloader is $(bootloader_display_name "$BOOTLOADER"), not Limine"; return 1; }
    [[ ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail "Runtime proof requires BootCurrent=Boot$PENDING_TARGET_BOOT_ID (found Boot${BOOT_CURRENT:-unknown})"; return 1; }
    nvram_id_matches_path "$PENDING_TARGET_BOOT_ID" "$PENDING_TARGET_EFI_PATH" || { fail 'BootCurrent Limine NVRAM entry no longer has the recorded exact EFI path'; return 1; }
    leap16_nvram_entry_matches_current_esp "$PENDING_TARGET_BOOT_ID" || { fail 'BootCurrent Limine NVRAM entry is not bound to the detected ESP'; return 1; }
    leap16_require_sudo_session || return 1

    local arrival next current_order diag
    arrival=$(leap16_capture_required_diagnostic runtime-arrival || true)
    [[ -n $arrival ]] && printf 'Runtime-arrival diagnostic snapshot: %s\n' "$arrival" || warn 'Could not capture runtime-arrival diagnostics'

    run_validation preflight || { leap16_stage_diagnostic runtime-generic-validation-failed; return 1; }
    validate_pending_compatibility || { leap16_stage_diagnostic runtime-pending-incompatible; fail "Pending migration became incompatible during runtime preflight: $PENDING_REASON"; return 1; }

    next=$(pending_bootnext_id)
    if [[ -n $next && ${next^^} != ${PENDING_TARGET_BOOT_ID^^} ]]; then
        leap16_stage_diagnostic runtime-unrelated-bootnext
        fail "BootNext belongs to unrelated Boot$next; refusing to alter it or certify this runtime"
        return 1
    elif [[ ${next^^} == ${PENDING_TARGET_BOOT_ID^^} ]]; then
        warn "Firmware still reports transaction BootNext=Boot$next after Limine boot; clearing it to restore one-shot semantics"
        sudo efibootmgr -N >/dev/null || { leap16_stage_diagnostic runtime-bootnext-clear-failed; fail 'Could not clear the consumed transaction BootNext'; return 1; }
        [[ -z $(pending_bootnext_id) ]] || { leap16_stage_diagnostic runtime-bootnext-still-set; fail 'BootNext remained set after explicit clear'; return 1; }
        ok 'Transaction BootNext is now clear; subsequent normal boots follow persistent GRUB2-first BootOrder'
    else
        ok 'BootNext was consumed/cleared by firmware after the one-time Limine boot'
    fi

    current_order=$(leap16_current_boot_order)
    if ! leap16_validate_pending_firmware_order 'Runtime'; then
        leap16_stage_diagnostic runtime-bootorder-drift
        return 1
    fi

    pending_validate_running_kernel || { leap16_stage_diagnostic runtime-kernel-failed; return 1; }
    pending_validate_runtime_cmdline_against_source || { leap16_stage_diagnostic runtime-cmdline-failed; return 1; }
    verify_pending_candidate_ownership_unchanged || { leap16_stage_diagnostic runtime-candidate-ownership-failed; return 1; }
    printf '\nDeep Limine validation from the actually booted target session:\n'
    validate_pending_target_deep || { leap16_stage_diagnostic runtime-target-deep-failed; return 1; }
    printf '\nRe-validating the untouched recorded GRUB2 recovery path from the Limine session:\n'
    verify_pending_source_recovery_unchanged || { leap16_stage_diagnostic runtime-source-recovery-failed; return 1; }

    pending_set_phase runtime-validated || { leap16_stage_diagnostic runtime-phase-write-failed; fail 'Runtime checks passed but runtime-validated phase could not be persisted'; return 1; }
    detect_bootloader
    diag=$(leap16_capture_required_diagnostic runtime-pass || true)
    [[ -n $diag ]] && printf 'Runtime-pass diagnostic snapshot: %s\n' "$diag" || warn 'Runtime proof passed but the final runtime-pass diagnostic folder could not be created'

    printf '\nRUNTIME-VALIDATED GRUB2 -> Limine one-shot boot succeeded.\n'
    printf '  BootCurrent proof:  Boot%s -> %s\n' "$PENDING_TARGET_BOOT_ID" "$PENDING_TARGET_EFI_PATH"
    printf '  BootNext:           clear\n'
    printf '  Persistent order:   %s (GRUB2 still first at the runtime-proof boundary)\n' "$current_order"
    if [[ ${LEAP16_AUTO_RESUME:-0} == 1 ]]; then
        printf '  Automatic resume:   runtime proof accepted; safe persistent promotion follows now\n'
        printf '  GRUB2 retirement:   LOCKED until the separate Limine fallback runtime proof\n'
    else
        printf '  Promotion:          eligible from this exact target session\n'
        printf '  GRUB2 retirement:   LOCKED until the separate Limine fallback runtime proof\n'
    fi
}

leap16_verify_source_return_after_runtime() {
    validate_pending_compatibility || { fail "Pending migration is not compatible: $PENDING_REASON"; return 1; }
    [[ $PENDING_PHASE == runtime-validated ]] || { fail 'Source-return proof requires a recorded runtime-validated one-shot'; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == ${PENDING_OLD_BOOT_ID^^} ]] || {
        fail "Source-return proof requires GRUB2 Boot$PENDING_OLD_BOOT_ID to be BootCurrent"
        return 1
    }
    leap16_require_sudo_session || return 1
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext is set during source-return proof; refusing to certify the return'; return 1; }
    local diag
    leap16_validate_pending_firmware_order 'Source-return' || return 1
    run_validation preflight || return 1
    verify_pending_source_recovery_unchanged || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1
    diag=$(leap16_capture_required_diagnostic source-return-pass || true)
    [[ -n $diag ]] && printf 'Source-return diagnostic snapshot: %s\n' "$diag" || warn 'Source return passed but diagnostics could not be captured'
    printf '\nSOURCE-RETURN-VALIDATED.\n'
    printf 'The one-shot Limine boot succeeded and the following normal boot returned to GRUB2 with the stable EFI-file BootOrder exactly preserved.\n'
    printf 'The transaction owns persistent promotion; GRUB2 retirement remains locked until fallback proof.\n'
}

pending_banner() {
    pending_exists || return 0
    if validate_pending_compatibility >/dev/null 2>&1; then
        detect_bootloader
        printf 'Pending/staged migration: %s -> %s  [%s]' "$(bootloader_display_name "$PENDING_SOURCE")" "$(bootloader_display_name "$PENDING_TARGET")" "$PENDING_PHASE"
        case "$PENDING_PHASE:$BOOTLOADER" in
            candidate-ready:grub) printf '  [PARKED; ONE-SHOT TEST AVAILABLE]\n' ;;
            candidate-ready:limine) printf '  [TARGET BOOTED MANUALLY; NOT CERTIFIED]\n' ;;
            boot-armed:grub)
                if [[ ${BOOT_NEXT^^} == ${PENDING_TARGET_BOOT_ID^^} ]]; then printf '  [BootNext ARMED]\n';
                elif [[ -z ${BOOT_NEXT:-} ]]; then printf '  [ONE-SHOT CONSUMED/CLEARED; SOURCE ACTIVE]\n';
                else printf '  [UNRELATED BootNext=%s]\n' "$BOOT_NEXT"; fi
                ;;
            boot-armed:limine) printf '  [LIMINE ACTIVE; RUNTIME PROOF REQUIRED]\n' ;;
            runtime-validated:limine) printf '  [LIMINE RUNTIME PROVEN; REBOOT TO SOURCE]\n' ;;
            runtime-validated:grub) printf '  [RUNTIME PROOF RECORDED; SOURCE ACTIVE]\n' ;;
            *) printf '  [CURRENT: %s]\n' "$(bootloader_display_name "$BOOTLOADER")" ;;
        esac
    else
        printf 'Pending/staged migration exists but is incompatible: %s\n' "${PENDING_REASON:-unknown}"
    fi
}

manage_pending_migration() {
    pending_exists || { printf '\nNo pending/staged migration exists.\n'; return 0; }
    validate_pending_compatibility || { printf '\nPending migration state is invalid/incompatible: %s\n' "$PENDING_REASON"; return 1; }
    detect_bootloader
    show_pending_details

    local choice next
    if [[ $BOOTLOADER == limine ]]; then
        case "$PENDING_PHASE" in
            boot-armed)
                printf '\nThe transaction-armed Limine one-shot is running now. Persistent promotion is locked.\n'
                printf '[1] Run exact post-boot runtime validation\n'
                printf '[2] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in 1) validate_pending_target_runtime ;; 2|'') return 0 ;; *) printf 'Invalid selection.\n'; return 1 ;; esac
                ;;
            runtime-validated)
                printf '\nThis exact Limine BootCurrent already passed the runtime gate.\n'
                printf '[1] Re-run runtime validation\n'
                printf '[2] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in 1) validate_pending_target_runtime ;; 2|'') return 0 ;; *) printf 'Invalid selection.\n'; return 1 ;; esac
                ;;
            candidate-ready)
                printf '\nLimine was entered without transaction arming. This session is not accepted as runtime proof.\n'
                printf 'Reboot normally to GRUB2, then arm the one-shot test through selector [2].\n'
                return 1
                ;;
        esac
    elif [[ $BOOTLOADER == grub ]]; then
        [[ ${BOOT_CURRENT^^} == ${PENDING_OLD_BOOT_ID^^} ]] || { fail "GRUB2 is active through Boot${BOOT_CURRENT:-unknown}, not recorded source Boot$PENDING_OLD_BOOT_ID"; return 1; }
        case "$PENDING_PHASE" in
            candidate-ready)
                printf '\nGRUB2 source is active and the Limine candidate is parked.\n'
                printf '[1] Re-run source + candidate validation\n'
                printf '[2] Arm one-time Limine test boot (BootNext only)\n'
                printf '[3] Roll back this exact candidate\n'
                printf '[4] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) leap16_require_sudo_session && run_validation preflight && leap16_validate_pending_firmware_order 'Candidate re-check' && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep ;;
                    2) arm_pending_one_time_boot ;;
                    3) rollback_pending_candidate ;;
                    4|'') return 0 ;;
                    *) printf 'Invalid selection.\n'; return 1 ;;
                esac
                ;;
            boot-armed)
                next=$(pending_bootnext_id)
                if [[ ${next^^} == ${PENDING_TARGET_BOOT_ID^^} ]]; then
                    printf '\nOne-time Limine BootNext is armed and waiting for reboot.\n'
                    printf '[1] Re-check source/candidate integrity and leave BootNext armed\n'
                    printf '[2] Cancel transaction BootNext and return to candidate-ready\n'
                    printf '[3] Roll back the staged candidate\n'
                    printf '[4] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in
                        1) leap16_require_sudo_session && run_validation preflight && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged ;;
                        2) cancel_pending_one_time_boot ;;
                        3) rollback_pending_candidate ;;
                        4|'') return 0 ;;
                        *) printf 'Invalid selection.\n'; return 1 ;;
                    esac
                elif [[ -z $next ]]; then
                    printf '\nThe transaction is still marked boot-armed, but BootNext is gone and GRUB2 is active.\n'
                    printf 'No Limine runtime proof was recorded; the one-shot was consumed/cleared or failed before validation.\n'
                    printf '[1] Revalidate and return to candidate-ready\n'
                    printf '[2] Roll back the candidate\n'
                    printf '[3] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in 1) leap16_require_sudo_session && reset_consumed_test_to_candidate_ready ;; 2) rollback_pending_candidate ;; 3|'') return 0 ;; *) printf 'Invalid selection.\n'; return 1 ;; esac
                else
                    fail "BootNext belongs to unrelated Boot$next; the transaction will not touch it"
                    return 1
                fi
                ;;
            runtime-validated)
                printf '\nLimine runtime proof is recorded and GRUB2 is active again.\n'
                printf '[1] Prove/capture the normal GRUB2 source return\n'
                printf '[2] Re-check source + candidate ownership\n'
                printf '[3] Roll back/abandon the Limine candidate\n'
                printf '[4] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) leap16_verify_source_return_after_runtime ;;
                    2) leap16_require_sudo_session && run_validation preflight && leap16_validate_pending_firmware_order 'Runtime-proven candidate re-check' && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged ;;
                    3) rollback_pending_candidate ;;
                    4|'') return 0 ;;
                    *) printf 'Invalid selection.\n'; return 1 ;;
                esac
                ;;
        esac
    else
        fail 'Current bootloader is neither the recorded GRUB2 source nor Limine target'
        return 1
    fi
}

# r12 deliberately permits only BootNext arming/runtime proof. Everything that
# could make Limine persistent or retire GRUB2 remains unreachable, even if an
# inherited helper is invoked directly.
arm_pending_test_boot() { arm_pending_one_time_boot "$@"; }
r23_after_fresh_grub_to_limine_candidate() { printf 'leap16-r12: automatic BootNext/resume is intentionally disabled; use selector [2] explicitly.\n' >&2; return 1; }
r23_finalize_grub_to_limine() { printf 'leap16-r12: persistent promotion/source retirement is intentionally disabled.\n' >&2; return 1; }
r22_resume_transaction_root() { printf 'leap16-r12: automatic resume/finalization is intentionally disabled.\n' >&2; return 1; }



# r12 transaction lifecycle + rollback repair -------------------------------
# r10 exposed a latent r47 ordering problem on the real Leap transaction: the
# inherited r23 rollback wrapper restored/removes the staged splash before the
# older rollback body re-ran candidate ownership validation.  If teardown had
# already started, that validation could fail and strand pending state.  It also
# attempted to restore the literal pre-stage BootOrder, which is unsafe on this
# ASUS after firmware garbage-collects its own BBS placeholders.
#
# The Leap override below makes rollback idempotent and transaction-owned:
# prove source + current/remaining candidate state first, then remove only the
# exact target, preserve whatever firmware-owned BBS churn already occurred, and
# finally clear pending state.  It recognizes only the narrow partial-teardown
# state r10 itself could have produced (pre-stage-absent target/splash already
# absent); unrelated mutations still fail closed.

LEAP16_ROLLBACK_PARTIAL=0

leap16_record_value() {
    local file=$1 key=$2
    awk -F'\t' -v k="$key" '$1==k {print $2; exit}' "$file" 2>/dev/null || true
}

leap16_prestage_limine_efi_was_absent() {
    local rec
    rec=$(r23_prestage_limine_efi_record_path "$PENDING_TRANSACTION_SNAPSHOT_DIR")
    [[ -f $rec && $(leap16_record_value "$rec" existed) == 0 ]]
}

leap16_prestage_limine_splash_was_absent() {
    local rec
    rec=$(r23_prestage_splash_record_path "$PENDING_TRANSACTION_SNAPSHOT_DIR")
    [[ -f $rec && $(leap16_record_value "$rec" existed) == 0 ]]
}

leap16_pending_conf_reference() {
    local current=${PENDING_LIMINE_CONF_PATH:-} diag=${PENDING_DIAGNOSTIC_PATH:-}/limine.conf hash
    if [[ -n $current ]] && (sudo -n test -f "$current" 2>/dev/null || [[ -f $current ]]); then
        hash=$(sudo -n sha256sum -- "$current" 2>/dev/null | awk '{print $1}' || sha256sum -- "$current" 2>/dev/null | awk '{print $1}' || true)
        [[ $hash == "$PENDING_LIMINE_CONF_HASH" ]] || return 1
        printf '%s\n' "$current"
        return 0
    fi
    if [[ -f $diag ]]; then
        hash=$(sha256sum -- "$diag" 2>/dev/null | awk '{print $1}' || true)
        [[ $hash == "$PENDING_LIMINE_CONF_HASH" ]] || return 1
        printf '%s\n' "$diag"
        return 0
    fi
    return 1
}

leap16_verify_pending_managed_dir_for_rollback() {
    local dir=${PENDING_LIMINE_MANAGED_DIR:-} conf value resolved count=0 actual_list expected_list
    [[ -n $dir ]] || { fail 'Pending Limine managed directory identity is missing'; return 1; }
    if ! (sudo -n test -d "$dir" 2>/dev/null || [[ -d $dir ]]); then
        warn 'Transaction-owned Limine managed directory is already absent; accepting partial rollback recovery'
        LEAP16_ROLLBACK_PARTIAL=1
        return 0
    fi
    conf=$(leap16_pending_conf_reference) || { fail 'No hash-proven Limine config remains to verify the managed rollback payloads'; return 1; }
    expected_list=$(mktemp) || return 1
    actual_list=$(mktemp) || { rm -f -- "$expected_list"; return 1; }
    while IFS= read -r value; do
        [[ $value == *'#'* ]] || continue
        verify_limine_uri_hash "$value" || { rm -f -- "$expected_list" "$actual_list"; fail 'A transaction-managed Limine kernel/initrd changed before rollback'; return 1; }
        resolved=$(resolve_limine_boot_uri "$value") || { rm -f -- "$expected_list" "$actual_list"; return 1; }
        case "$(safe_realpath "$resolved")" in
            "$(safe_realpath "$dir")"/*) printf '%s\n' "$(safe_realpath "$resolved")" >>"$expected_list"; count=$((count + 1)) ;;
        esac
    done < <(awk -F':[[:space:]]*' '/^[[:space:]]*(module_path|path):[[:space:]]*boot\(\):/ {sub(/^[^:]*:[[:space:]]*/, ""); print}' "$conf")
    ((count > 0)) || { rm -f -- "$expected_list" "$actual_list"; fail 'No hash-bound managed Limine payloads were found for rollback verification'; return 1; }
    if [[ -r $dir ]]; then
        find "$dir" -type f -print 2>/dev/null | while IFS= read -r resolved; do safe_realpath "$resolved"; done | LC_ALL=C sort -u >"$actual_list"
    else
        sudo -n find "$dir" -type f -print 2>/dev/null | while IFS= read -r resolved; do safe_realpath "$resolved"; done | LC_ALL=C sort -u >"$actual_list"
    fi
    LC_ALL=C sort -u -o "$expected_list" "$expected_list"
    if ! cmp -s "$expected_list" "$actual_list"; then
        rm -f -- "$expected_list" "$actual_list"
        fail 'Limine managed directory contains missing/extra files relative to the hash-bound transaction config'
        return 1
    fi
    rm -f -- "$expected_list" "$actual_list"
    ok 'Transaction-managed Limine kernel/initrd tree is unchanged for rollback'
}

leap16_verify_rollback_candidate_state() {
    local hash dir manifest splash expected actual
    LEAP16_ROLLBACK_PARTIAL=0

    # Exact NVRAM identity is required whenever the target entry still exists.
    if boot_id_exists "$PENDING_TARGET_BOOT_ID"; then
        nvram_id_matches_path "$PENDING_TARGET_BOOT_ID" "$PENDING_TARGET_EFI_PATH" || { fail 'Staged target NVRAM path changed before rollback'; return 1; }
    else
        warn "Transaction target Boot$PENDING_TARGET_BOOT_ID is already absent; accepting partial rollback recovery"
        LEAP16_ROLLBACK_PARTIAL=1
    fi

    dir=$(dirname -- "$PENDING_TARGET_EFI_RESOLVED")
    manifest=$(r23_target_limine_efi_manifest_path)
    if sudo -n test -d "$dir" 2>/dev/null || [[ -d $dir ]]; then
        [[ -s $manifest ]] || { fail 'Target EFI/LIMINE ownership manifest is missing'; return 1; }
        pending_verify_tree_manifest "$dir" "$manifest" || { fail 'Target EFI/LIMINE namespace changed before rollback'; return 1; }
        hash=$(sudo -n sha256sum -- "$PENDING_TARGET_EFI_RESOLVED" 2>/dev/null | awk '{print $1}' || true)
        [[ $hash == "$PENDING_TARGET_EFI_HASH" ]] || { fail 'Staged target EFI executable changed since candidate creation'; return 1; }
        ok 'Target EFI/LIMINE namespace still matches the transaction manifest'
    else
        leap16_prestage_limine_efi_was_absent || { fail 'Target EFI/LIMINE namespace disappeared but pre-stage ownership does not prove it was transaction-created'; return 1; }
        warn 'Transaction-created EFI/LIMINE namespace is already absent; accepting partial rollback recovery'
        LEAP16_ROLLBACK_PARTIAL=1
    fi

    splash="$ESP_MOUNT/$R23_LIMINE_SPLASH_NAME"
    if sudo -n test -f "$splash" 2>/dev/null || [[ -f $splash ]]; then
        expected=$(leap16_record_value "$(r23_limine_theme_manifest_path)" splash_sha256)
        actual=$(sudo -n sha256sum -- "$splash" 2>/dev/null | awk '{print $1}' || sha256sum -- "$splash" 2>/dev/null | awk '{print $1}' || true)
        [[ $expected =~ ^[0-9A-Fa-f]{64}$ && $actual == "$expected" ]] || { fail 'CachyOS Limine splash changed since candidate creation'; return 1; }
        ok 'CachyOS Limine splash still matches the transaction manifest'
    else
        leap16_prestage_limine_splash_was_absent || { fail 'Limine splash disappeared but pre-stage ownership does not prove it was transaction-created'; return 1; }
        warn 'Transaction-created Limine splash is already absent; accepting partial rollback recovery'
        LEAP16_ROLLBACK_PARTIAL=1
    fi

    if sudo -n test -f "$PENDING_LIMINE_CONF_PATH" 2>/dev/null || [[ -f $PENDING_LIMINE_CONF_PATH ]]; then
        hash=$(sudo -n sha256sum -- "$PENDING_LIMINE_CONF_PATH" 2>/dev/null | awk '{print $1}' || sha256sum -- "$PENDING_LIMINE_CONF_PATH" 2>/dev/null | awk '{print $1}' || true)
        [[ $hash == "$PENDING_LIMINE_CONF_HASH" ]] || { fail 'Staged limine.conf changed since candidate creation'; return 1; }
    else
        warn 'Transaction-created limine.conf is already absent; accepting partial rollback recovery'
        LEAP16_ROLLBACK_PARTIAL=1
    fi

    if [[ $PENDING_LIMINE_DEFAULT_CREATED == 1 ]]; then
        if [[ -f /etc/default/limine ]] || sudo -n test -f /etc/default/limine 2>/dev/null; then
            hash=$(sha256sum /etc/default/limine 2>/dev/null | awk '{print $1}' || sudo -n sha256sum /etc/default/limine 2>/dev/null | awk '{print $1}' || true)
            [[ $hash == "$PENDING_LIMINE_DEFAULT_HASH" ]] || { fail '/etc/default/limine changed since candidate creation'; return 1; }
        else
            warn 'Transaction-created /etc/default/limine is already absent; accepting partial rollback recovery'
            LEAP16_ROLLBACK_PARTIAL=1
        fi
    fi

    leap16_verify_pending_managed_dir_for_rollback || return 1
    if ((LEAP16_ROLLBACK_PARTIAL)); then
        ok 'Recognized an idempotent partial rollback state produced by the earlier r10 teardown path'
    else
        ok 'Complete Limine candidate ownership is unchanged before rollback'
    fi
}

leap16_verify_rollback_fallback_state() {
    local fallback=$PENDING_OLD_FALLBACK_PATH current snapshot_hash
    if [[ $PENDING_OLD_FALLBACK_EXISTED == 1 ]]; then
        [[ -f $PENDING_OLD_FALLBACK_SNAPSHOT ]] || { fail 'Recorded pre-stage fallback snapshot is missing; refusing rollback'; return 1; }
        snapshot_hash=$(sha256sum -- "$PENDING_OLD_FALLBACK_SNAPSHOT" 2>/dev/null | awk '{print $1}' || true)
        [[ $snapshot_hash == "$PENDING_OLD_FALLBACK_HASH" ]] || { fail 'Pre-stage fallback snapshot no longer matches its recorded hash'; return 1; }
        current=$(sudo -n sha256sum -- "$fallback" 2>/dev/null | awk '{print $1}' || sha256sum -- "$fallback" 2>/dev/null | awk '{print $1}' || true)
        if [[ $current == "$PENDING_OLD_FALLBACK_HASH" ]]; then
            ok 'Shared EFI fallback already matches the pre-stage source bytes'
            return 0
        fi
        [[ -n $PENDING_POST_STAGE_FALLBACK_HASH && $current == "$PENDING_POST_STAGE_FALLBACK_HASH" ]] || { fail 'Shared EFI fallback changed outside the transaction; refusing rollback'; return 1; }
        ok 'Shared EFI fallback matches the recorded transaction-owned post-stage bytes'
        return 0
    fi
    if sudo -n test -e "$fallback" 2>/dev/null || [[ -e $fallback ]]; then
        current=$(sudo -n sha256sum -- "$fallback" 2>/dev/null | awk '{print $1}' || sha256sum -- "$fallback" 2>/dev/null | awk '{print $1}' || true)
        [[ -n $PENDING_POST_STAGE_FALLBACK_HASH && $current == "$PENDING_POST_STAGE_FALLBACK_HASH" ]] || { fail 'A non-transaction fallback appeared after staging; refusing rollback'; return 1; }
        ok 'Transaction-owned fallback bytes are proven for rollback'
    else
        ok 'Shared EFI fallback remains absent as recorded before staging'
    fi
}

leap16_validate_rollback_firmware_state() {
    local order first
    if boot_id_exists "$PENDING_TARGET_BOOT_ID"; then
        leap16_validate_pending_firmware_order 'Rollback preflight' || return 1
    else
        nvram_id_matches_path "$PENDING_OLD_BOOT_ID" "$PENDING_OLD_BOOT_EFI_PATH" || { fail 'Recorded GRUB2 source NVRAM identity changed before rollback recovery'; return 1; }
        order=$(leap16_current_boot_order)
        first=${order%%,*}
        [[ ${first^^} == ${PENDING_OLD_BOOT_ID^^} ]] || { fail "Source Boot$PENDING_OLD_BOOT_ID is no longer first in persistent BootOrder ($order)"; return 1; }
        warn "Target Boot$PENDING_TARGET_BOOT_ID was already removed; preserving current source-first firmware order instead of resurrecting old BBS entries"
    fi
}

rollback_pending_grub_to_limine() {
    local next answer current_hash keep rc=0 post_order first
    validate_pending_compatibility || return 1
    leap16_require_sudo_session || return 1
    detect_bootloader
    [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == ${PENDING_OLD_BOOT_ID^^} ]] || { fail "Rollback requires recorded GRUB2 source Boot$PENDING_OLD_BOOT_ID"; return 1; }
    run_validation preflight || return 1
    leap16_validate_rollback_firmware_state || return 1
    verify_pending_source_recovery_unchanged || return 1
    leap16_verify_rollback_candidate_state || return 1
    leap16_verify_rollback_fallback_state || return 1

    next=$(pending_bootnext_id)
    [[ -z $next || ${next^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail "BootNext belongs to unrelated Boot$next; refusing rollback"; return 1; }

    printf '\nRollback will remove only the ownership-proven Limine transaction state.\n'
    printf 'Firmware-owned BBS entries that disappeared on this ASUS will NOT be recreated.\n'
    read -r -p 'Type ROLLBACK to abandon the staged Limine candidate: ' answer
    [[ $answer == ROLLBACK ]] || { printf 'Rollback cancelled.\n'; return 0; }

    leap16_stage_diagnostic rollback-before-cleanup
    [[ -n $next ]] && sudo efibootmgr -N >/dev/null 2>&1 || true
    rollback_pending_fallback_state || return 1

    if boot_id_exists "$PENDING_TARGET_BOOT_ID"; then
        nvram_id_matches_path "$PENDING_TARGET_BOOT_ID" "$PENDING_TARGET_EFI_PATH" || { fail 'Target NVRAM path changed at rollback deletion boundary'; return 1; }
        sudo efibootmgr -b "$PENDING_TARGET_BOOT_ID" -B >/dev/null || return 1
        ok "Removed staged Limine NVRAM entry Boot$PENDING_TARGET_BOOT_ID"
    else
        ok "Target Limine Boot$PENDING_TARGET_BOOT_ID was already absent"
    fi

    # Preserve current firmware ordering.  Deleting Boot#### removes only the
    # transaction target from BootOrder; never write the stale original list,
    # because ASUS may already have garbage-collected BBS entries from it.
    post_order=$(leap16_current_boot_order)
    first=${post_order%%,*}
    [[ ${first^^} == ${PENDING_OLD_BOOT_ID^^} ]] || { fail "Source Boot$PENDING_OLD_BOOT_ID is not first after target deletion ($post_order)"; return 1; }
    ! boot_id_exists "$PENDING_TARGET_BOOT_ID" || { fail "Target Boot$PENDING_TARGET_BOOT_ID still exists after deletion"; return 1; }
    ok "Persistent BootOrder remains source-first after removing only the target ($post_order)"

    keep=$(mktemp -d) || return 1
    r23_copy_prestage_limine_efi_snapshot "$PENDING_TRANSACTION_SNAPSHOT_DIR" "$keep" || { rm -rf -- "$keep"; return 1; }

    # All mutable candidate pieces were proven above.  Teardown is now
    # idempotent: already-absent transaction-owned pieces are simply skipped.
    r23_restore_prestage_limine_splash "$PENDING_TRANSACTION_SNAPSHOT_DIR" || rc=1
    r23_restore_prestage_limine_efi_dir "$keep" || rc=1
    rm -rf -- "$keep"
    ((rc == 0)) || return 1

    if sudo -n test -f "$PENDING_LIMINE_CONF_PATH" 2>/dev/null || [[ -f $PENDING_LIMINE_CONF_PATH ]]; then
        current_hash=$(sudo -n sha256sum -- "$PENDING_LIMINE_CONF_PATH" 2>/dev/null | awk '{print $1}' || sha256sum -- "$PENDING_LIMINE_CONF_PATH" 2>/dev/null | awk '{print $1}' || true)
        [[ $current_hash == "$PENDING_LIMINE_CONF_HASH" ]] || { fail 'limine.conf changed at rollback deletion boundary'; return 1; }
        sudo rm -f -- "$PENDING_LIMINE_CONF_PATH" || return 1
        ok 'Removed transaction-created limine.conf'
    fi
    if sudo -n test -d "$PENDING_LIMINE_MANAGED_DIR" 2>/dev/null || [[ -d $PENDING_LIMINE_MANAGED_DIR ]]; then
        sudo rm -rf -- "$PENDING_LIMINE_MANAGED_DIR" || return 1
        ok 'Removed transaction-created Limine managed kernel directory'
    fi
    if [[ $PENDING_LIMINE_DEFAULT_CREATED == 1 ]] && ([[ -f /etc/default/limine ]] || sudo -n test -f /etc/default/limine 2>/dev/null); then
        current_hash=$(sha256sum /etc/default/limine 2>/dev/null | awk '{print $1}' || sudo -n sha256sum /etc/default/limine 2>/dev/null | awk '{print $1}' || true)
        [[ $current_hash == "$PENDING_LIMINE_DEFAULT_HASH" ]] || { fail '/etc/default/limine changed at rollback deletion boundary'; return 1; }
        sudo rm -f -- /etc/default/limine || return 1
        ok 'Removed transaction-created /etc/default/limine'
    fi

    # Retire the user-visible pending record before calling the final checkpoint
    # "rollback-pass". Keep the loaded PENDING_* values in memory only long
    # enough for firmware-order.txt to compare against the recorded baseline.
    # switcher-state.txt deliberately renders the transaction fields empty for
    # rollback-pass, so the diagnostic describes the actual neutral final state.
    rm -f -- "$PENDING_STATE_FILE"
    pending_exists && { fail 'Pending migration state survived rollback cleanup'; return 1; }
    leap16_stage_diagnostic rollback-pass
    remove_pending_transaction_snapshot || warn 'Could not remove private transaction snapshot directory'
    pending_reset
    TRANSACTION_SNAPSHOT_DIR=""
    LEAP16_CREATED_TARGET_ID=""
    LEAP16_ORIGINAL_BOOT_ORDER=""
    ok 'ROLLBACK-COMPLETE. GRUB2 remains authoritative and the Limine transaction is no longer pending.'
}

# r10 presentation cleanup --------------------------------------------------
# On Leap, the CachyOS splash source is intentionally a staging-time download,
# not a persistent runtime dependency.  Once the staged splash has been bound
# into the transaction manifest, absence of that original source is expected
# and must not make a healthy runtime/source-return validation look suspicious.
# Keep the inherited r47 validator intact underneath and suppress only that one
# non-actionable warning.  Missing ESP splash / real source mismatch behavior is
# unchanged.
if declare -F validate_cachyos_limine_theme >/dev/null 2>&1; then
    eval "$(declare -f validate_cachyos_limine_theme | sed '1s/validate_cachyos_limine_theme/validate_cachyos_limine_theme_pre_leap16_r10/')"
fi

validate_cachyos_limine_theme() {
    local rc
    if ! declare -F validate_cachyos_limine_theme_pre_leap16_r10 >/dev/null 2>&1; then
        fail 'Inherited r47 Limine theme validator is unavailable'
        return 1
    fi

    validate_cachyos_limine_theme_pre_leap16_r10 "$@" \
        | sed '/^  \[WARN\] Installed CachyOS wallpaper source is unavailable; validating the ESP splash by transaction\/backup hash only$/d'
    rc=${PIPESTATUS[0]}
    return "$rc"
}

# leap16-r13 automatic resume + promotion -----------------------------------
# Port the r47 r22/r23 root-owned one-shot continuation onto the already
# hardware-proven Leap GRUB2 -> Limine path.  The deliberate Leap safety
# boundary is narrower than CachyOS finalization: after exact runtime proof,
# Limine may become first in persistent BootOrder, but GRUB2/shim/config and
# the stock shared fallback remain untouched as a recovery chain.

R22_SYSTEM_ROOT=/var/lib/opensuse-bootloader-switcher/r13
R22_SERVICE_NAME=opensuse-bootloader-switcher-resume.service
R22_SERVICE_PATH=/etc/systemd/system/$R22_SERVICE_NAME
R22_BUNDLE_MARKER=.leap16-r13-root-owned-resume-bundle
R22_RESULT_FILE_NAME=last-auto-result.txt

# Root-owned resume invocations do not need to bounce through sudo to prove
# that privilege is available.  Normal-user behavior stays unchanged.
eval "$(declare -f leap16_require_sudo_session | sed '1s/leap16_require_sudo_session/leap16_require_sudo_session_pre_r13/')"
leap16_require_sudo_session() {
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        return 0
    fi
    leap16_require_sudo_session_pre_r13 "$@"
}

# candidate-pass is captured before pending-migration.tsv is serialized.  Use
# the live transaction snapshot baseline first so firmware-order.txt does not
# falsely report that its BBS classification baseline is unavailable.
eval "$(declare -f leap16_pending_firmware_baseline_path | sed '1s/leap16_pending_firmware_baseline_path/leap16_pending_firmware_baseline_path_pre_r13/')"
leap16_pending_firmware_baseline_path() {
    if [[ -n ${TRANSACTION_SNAPSHOT_DIR:-} && -f ${TRANSACTION_SNAPSHOT_DIR:-/nonexistent}/prestage-efibootmgr-v.txt ]]; then
        printf '%s\n' "$TRANSACTION_SNAPSHOT_DIR/prestage-efibootmgr-v.txt"
        return 0
    fi
    leap16_pending_firmware_baseline_path_pre_r13 "$@"
}

# Keep the r47 root-owned resume bundle design, but use an openSUSE-specific
# service name/root and carry the normal user's diagnostic destination in the
# root-owned resume.conf.  The destination is fixed below the recorded HOME;
# arbitrary root write destinations are never accepted from user state.
eval "$(declare -f r22_write_resume_conf | sed '1s/r22_write_resume_conf/r22_write_resume_conf_pre_r13/')"
r22_write_resume_conf() {
    local out=$1 bundle=$2 user_state=$3 user_snapshot=$4 uid=$5 gid=$6 user_home=$7
    r22_write_resume_conf_pre_r13 "$@" || return 1
    printf 'user_diagnostic_root\t%s/opensuse-bootloader-diagnostics\n' "$user_home" >>"$out"
}

r22_write_systemd_unit() {
    local out=$1 bundle=$2 state_dir=$3
    cat >"$out" <<EOF_UNIT
[Unit]
Description=openSUSE Bootloader Switcher automatic GRUB2 to Limine resume
After=local-fs.target
ConditionPathExists=$state_dir/pending-migration.tsv

[Service]
Type=oneshot
Environment=BOOTLOADER_SWITCHER_STATE_DIR=$state_dir
Environment=R22_RESUME_BUNDLE=$bundle
Environment=HOME=$bundle/runtime-home
Environment=LEAP16_AUTO_RESUME=1
ExecStart=/usr/bin/bash $bundle/tool/bootloader-switcher.sh --resume-transaction-root
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF_UNIT
}

r13_user_diagnostic_root_is_safe() {
    local conf=$1 home dest home_real dest_real
    home=$(r22_conf_value "$conf" user_home)
    dest=$(r22_conf_value "$conf" user_diagnostic_root)
    [[ -n $home && -n $dest ]] || return 1
    home_real=$(r22_realpath_m "$home")
    dest_real=$(r22_realpath_m "$dest")
    [[ $dest_real == "$home_real/"* && $dest_real != "$home_real" ]] || return 1
    [[ ! -L $dest ]] || return 1
    return 0
}

r13_sync_root_diagnostics_to_user() {
    local conf=$1 bundle=$2 status=${3:-resume} dest uid gid src d base target stamp session
    r13_user_diagnostic_root_is_safe "$conf" || return 1
    dest=$(r22_conf_value "$conf" user_diagnostic_root)
    uid=$(r22_conf_value "$conf" user_uid)
    gid=$(r22_conf_value "$conf" user_gid)
    [[ $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ ]] || return 1

    install -d -o "$uid" -g "$gid" -m 0700 -- "$dest" || return 1
    src="$bundle/diagnostics"
    if [[ -d $src ]]; then
        while IFS= read -r -d '' d; do
            base=$(basename -- "$d")
            target="$dest/$base"
            if [[ -e $target ]]; then
                target="$dest/${base}-root"
            fi
            cp -a -- "$d" "$target" || return 1
            chown -R "$uid:$gid" -- "$target" || return 1
        done < <(find "$src" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    fi

    if [[ -f $bundle/automatic-resume.log ]]; then
        stamp=$(date +%Y%m%d-%H%M%S)
        session="$dest/${stamp}-auto-resume-${status//[^A-Za-z0-9._-]/-}"
        install -d -o "$uid" -g "$gid" -m 0700 -- "$session" || return 1
        install -o "$uid" -g "$gid" -m 0600 -- "$bundle/automatic-resume.log" "$session/operation.log" || return 1
        [[ -f $bundle/resume.conf ]] && install -o "$uid" -g "$gid" -m 0600 -- "$bundle/resume.conf" "$session/resume.conf" || true
    fi
    return 0
}

r13_resume_pointer_bundle() {
    local pointer="$PENDING_STATE_DIR/r22-resume-bundle.path" bundle
    [[ -r $pointer ]] || return 1
    bundle=$(head -n1 -- "$pointer" 2>/dev/null || true)
    r22_safe_bundle_path "$bundle" || return 1
    printf '%s\n' "$bundle"
}

r13_resume_bundle_is_prepared() {
    local bundle
    bundle=$(r13_resume_pointer_bundle 2>/dev/null || true)
    [[ -n $bundle ]] || return 1
    # Display-only check: the unit is root-owned but world-readable.  Do not
    # make the banner depend on a warm sudo credential cache after reboot.
    [[ -f $R22_SERVICE_PATH ]] || return 1
    have systemctl && systemctl is-enabled --quiet "$R22_SERVICE_NAME" 2>/dev/null || return 1
    return 0
}

r13_source_first_order_from_current() {
    local source=${PENDING_OLD_BOOT_ID^^} target=${PENDING_TARGET_BOOT_ID^^} order id joined
    local -a out=() existing=()
    order=$(leap16_current_boot_order) || return 1
    out+=("$source")
    IFS=',' read -ra existing <<<"$order"
    for id in "${existing[@]}"; do
        id=${id^^}
        [[ -n $id && $id != "$source" && $id != "$target" ]] || continue
        out+=("$id")
    done
    out+=("$target")
    joined=$(IFS=,; printf '%s' "${out[*]}")
    printf '%s\n' "$joined"
}

r13_promoted_order_from_current() {
    local source=${PENDING_OLD_BOOT_ID^^} target=${PENDING_TARGET_BOOT_ID^^} order id joined
    local -a out=() existing=()
    order=$(leap16_current_boot_order) || return 1
    out+=("$target" "$source")
    IFS=',' read -ra existing <<<"$order"
    for id in "${existing[@]}"; do
        id=${id^^}
        [[ -n $id && $id != "$source" && $id != "$target" ]] || continue
        out+=("$id")
    done
    joined=$(IFS=,; printf '%s' "${out[*]}")
    printf '%s\n' "$joined"
}

# Promotion has a different stable-order expectation from the candidate gate:
# target first, recorded source second, then every other original non-BBS EFI
# entry in its original relative order.  BBS variables remain firmware-owned
# churn and are reported, never recreated.
leap16_assess_promoted_firmware_order() {
    LEAP16_ORDER_REASON=""
    LEAP16_ORDER_CURRENT_FULL=""
    LEAP16_ORDER_EXPECTED_STABLE=""
    LEAP16_ORDER_CURRENT_STABLE=""
    LEAP16_ORDER_BBS_ORIGINAL=""
    LEAP16_ORDER_BBS_CURRENT=""
    LEAP16_ORDER_BBS_MISSING=""
    LEAP16_ORDER_BBS_ADDED=""

    local source=${PENDING_OLD_BOOT_ID^^} target=${PENDING_TARGET_BOOT_ID^^} original=${PENDING_ORIGINAL_BOOT_ORDER^^}
    local baseline_path baseline current_dump current_order id line current_line base_path current_path
    local expected="$target,$source" current_stable="" orig_bbs="" cur_bbs="" missing="" added=""
    local -a ids=()

    [[ $source =~ ^[0-9A-F]{4}$ && $target =~ ^[0-9A-F]{4}$ && -n $original ]] || {
        LEAP16_ORDER_REASON='pending transaction lacks source/target/original BootOrder identity'
        return 1
    }
    baseline_path=$(leap16_pending_firmware_baseline_path 2>/dev/null || true)
    [[ -n $baseline_path && -r $baseline_path ]] || {
        LEAP16_ORDER_REASON='firmware baseline is unavailable for promoted-order validation'
        return 1
    }
    baseline=$(cat -- "$baseline_path" 2>/dev/null || true)
    current_dump=$(efibootmgr -v 2>/dev/null || true)
    current_order=$(awk -F': ' '/^BootOrder:/ {print toupper($2); exit}' <<<"$current_dump")
    [[ -n $current_order ]] || { LEAP16_ORDER_REASON='current BootOrder is unreadable'; return 1; }
    LEAP16_ORDER_CURRENT_FULL=$current_order

    leap16_boot_entry_is_active "$target" || { LEAP16_ORDER_REASON="target Boot$target is not active after promotion"; return 1; }
    leap16_boot_entry_is_active "$source" || { LEAP16_ORDER_REASON="source recovery Boot$source is not active after promotion"; return 1; }
    nvram_id_matches_path "$target" "$PENDING_TARGET_EFI_PATH" || { LEAP16_ORDER_REASON="target Boot$target changed EFI path after promotion"; return 1; }
    nvram_id_matches_path "$source" "$PENDING_OLD_BOOT_EFI_PATH" || { LEAP16_ORDER_REASON="source Boot$source changed EFI path after promotion"; return 1; }

    IFS=',' read -ra ids <<<"$original"
    for id in "${ids[@]}"; do
        id=${id^^}
        [[ -n $id && $id != "$source" && $id != "$target" ]] || continue
        line=$(leap16_line_for_id_in_dump "$baseline" "$id")
        [[ -n $line ]] || { LEAP16_ORDER_REASON="original Boot$id is missing from the firmware baseline"; return 1; }
        if leap16_line_is_bbs "$line"; then
            orig_bbs=$(leap16_csv_append "$orig_bbs" "$id")
        else
            base_path=$(efi_path_from_efibootmgr_line "$line" 2>/dev/null || true)
            [[ -n $base_path ]] || { LEAP16_ORDER_REASON="original non-BBS Boot$id has no EFI path"; return 1; }
            current_line=$(leap16_line_for_id_in_dump "$current_dump" "$id")
            [[ -n $current_line ]] || { LEAP16_ORDER_REASON="original EFI-file Boot$id disappeared after promotion"; return 1; }
            current_path=$(efi_path_from_efibootmgr_line "$current_line" 2>/dev/null || true)
            [[ -n $current_path && $(normalize_efi_path "$current_path" | tr '[:upper:]' '[:lower:]') == $(normalize_efi_path "$base_path" | tr '[:upper:]' '[:lower:]') ]] || {
                LEAP16_ORDER_REASON="original EFI-file Boot$id changed path after promotion"
                return 1
            }
            expected=$(leap16_csv_append "$expected" "$id")
        fi
    done
    LEAP16_ORDER_EXPECTED_STABLE=$expected
    LEAP16_ORDER_BBS_ORIGINAL=$orig_bbs

    IFS=',' read -ra ids <<<"$current_order"
    for id in "${ids[@]}"; do
        id=${id^^}
        [[ -n $id ]] || continue
        line=$(leap16_line_for_id_in_dump "$current_dump" "$id")
        [[ -n $line ]] || { LEAP16_ORDER_REASON="BootOrder references missing Boot$id"; return 1; }
        if leap16_line_is_bbs "$line"; then
            cur_bbs=$(leap16_csv_append "$cur_bbs" "$id")
        else
            current_stable=$(leap16_csv_append "$current_stable" "$id")
        fi
    done
    LEAP16_ORDER_CURRENT_STABLE=$current_stable
    LEAP16_ORDER_BBS_CURRENT=$cur_bbs

    IFS=',' read -ra ids <<<"$orig_bbs"
    for id in "${ids[@]}"; do
        [[ -n $id ]] || continue
        leap16_order_has_id "$current_order" "$id" || missing=$(leap16_csv_append "$missing" "$id")
    done
    IFS=',' read -ra ids <<<"$cur_bbs"
    for id in "${ids[@]}"; do
        [[ -n $id ]] || continue
        leap16_order_has_id "$orig_bbs" "$id" || added=$(leap16_csv_append "$added" "$id")
    done
    LEAP16_ORDER_BBS_MISSING=$missing
    LEAP16_ORDER_BBS_ADDED=$added

    [[ $current_stable == "$expected" ]] || {
        LEAP16_ORDER_REASON="promoted stable EFI-file BootOrder drifted (expected $expected, got ${current_stable:-empty})"
        return 1
    }
    LEAP16_ORDER_REASON='runtime-proven Limine is first; GRUB2 recovery and other real EFI entries remain exact'
    return 0
}

leap16_validate_promoted_firmware_order() {
    local context=${1:-Promoted}
    if ! leap16_assess_promoted_firmware_order; then
        fail "$context firmware-order gate failed: $LEAP16_ORDER_REASON"
        return 1
    fi
    ok "$context stable EFI-file BootOrder is exact ($LEAP16_ORDER_CURRENT_STABLE)"
    [[ -n $LEAP16_ORDER_BBS_MISSING ]] && warn "Firmware BBS churn after promotion: missing/removed Boot${LEAP16_ORDER_BBS_MISSING//,/ Boot}"
    [[ -n $LEAP16_ORDER_BBS_ADDED ]] && warn "Firmware BBS churn after promotion: new Boot${LEAP16_ORDER_BBS_ADDED//,/ Boot}"
    return 0
}

eval "$(declare -f leap16_write_firmware_order_report | sed '1s/leap16_write_firmware_order_report/leap16_write_firmware_order_report_pre_r13/')"
leap16_write_firmware_order_report() {
    local out=$1 phase=${2:-snapshot} rc=0
    case "$phase" in
        promotion-pass|auto-resume-pass)
            if ! leap16_assess_promoted_firmware_order; then rc=1; fi
            {
                printf 'assessment=%s\n' "$([[ $rc == 0 ]] && printf pass || printf fail)"
                printf 'reason=%s\n' "$LEAP16_ORDER_REASON"
                printf 'full_current_boot_order=%s\n' "$LEAP16_ORDER_CURRENT_FULL"
                printf 'stable_expected_boot_order=%s\n' "$LEAP16_ORDER_EXPECTED_STABLE"
                printf 'stable_current_boot_order=%s\n' "$LEAP16_ORDER_CURRENT_STABLE"
                printf 'original_bbs_ids=%s\n' "$LEAP16_ORDER_BBS_ORIGINAL"
                printf 'current_bbs_ids=%s\n' "$LEAP16_ORDER_BBS_CURRENT"
                printf 'missing_original_bbs_ids=%s\n' "$LEAP16_ORDER_BBS_MISSING"
                printf 'added_bbs_ids=%s\n' "$LEAP16_ORDER_BBS_ADDED"
            } >"$out"
            return 0
            ;;
        *) leap16_write_firmware_order_report_pre_r13 "$@" ;;
    esac
}

leap16_verify_grub_recovery_after_promotion() {
    local failures=0 actual dm em rec efi_dir present expected fallback_hash
    printf '\nGRUB2 recovery validation after Limine promotion:\n'
    nvram_id_matches_path "$PENDING_OLD_BOOT_ID" "$PENDING_OLD_BOOT_EFI_PATH" \
        && ok "Recovery Boot$PENDING_OLD_BOOT_ID still points to $PENDING_OLD_BOOT_EFI_PATH" \
        || { fail 'GRUB2 recovery NVRAM identity changed after promotion'; ((failures++)); }
    leap16_validate_promoted_firmware_order 'Post-promotion' || ((failures++))

    actual=$(sudo -n sha256sum -- "$PENDING_OLD_GRUB_EFI_RESOLVED" 2>/dev/null | awk '{print $1}' || sha256sum -- "$PENDING_OLD_GRUB_EFI_RESOLVED" 2>/dev/null | awk '{print $1}' || true)
    [[ -n $actual && $actual == "$PENDING_OLD_GRUB_HASH" ]] \
        && ok 'Recovery GRUB2/shim EFI executable remains byte-identical' \
        || { fail 'Recovery GRUB2/shim EFI executable changed after promotion'; ((failures++)); }

    dm=$(r23_source_grub_dir_manifest_path)
    em=$(r23_source_grub_efi_dir_manifest_path)
    rec=$(r23_source_grub_default_record_path)
    efi_dir=$(dirname -- "$PENDING_OLD_GRUB_EFI_RESOLVED")
    [[ -s $dm ]] && pending_verify_tree_manifest /boot/grub2 "$dm" \
        && ok 'Recovery /boot/grub2 tree remains byte-identical to the transaction manifest' \
        || { fail 'Recovery /boot/grub2 tree changed after promotion'; ((failures++)); }
    [[ -s $em ]] && pending_verify_tree_manifest "$efi_dir" "$em" \
        && ok 'Recovery openSUSE EFI namespace remains byte-identical to the transaction manifest' \
        || { fail 'Recovery openSUSE EFI namespace changed after promotion'; ((failures++)); }

    present=$(awk -F'\t' '$1=="present"{print $2; exit}' "$rec" 2>/dev/null || true)
    expected=$(awk -F'\t' '$1=="hash"{print $2; exit}' "$rec" 2>/dev/null || true)
    if [[ $present == 1 ]]; then
        actual=$(sha256sum /etc/default/grub 2>/dev/null | awk '{print $1}' || sudo -n sha256sum /etc/default/grub 2>/dev/null | awk '{print $1}' || true)
        [[ -n $actual && $actual == "$expected" ]] \
            && ok 'Recovery /etc/default/grub remains byte-identical' \
            || { fail 'Recovery /etc/default/grub changed after promotion'; ((failures++)); }
    fi

    if [[ ${PENDING_OLD_FALLBACK_EXISTED:-0} == 1 ]]; then
        fallback_hash=$(sudo -n sha256sum -- "$PENDING_OLD_FALLBACK_PATH" 2>/dev/null | awk '{print $1}' || sha256sum -- "$PENDING_OLD_FALLBACK_PATH" 2>/dev/null | awk '{print $1}' || true)
        [[ -n $fallback_hash && $fallback_hash == "$PENDING_OLD_FALLBACK_HASH" ]] \
            && ok 'Shared openSUSE shim fallback remains byte-identical after promotion' \
            || { fail 'Shared openSUSE shim fallback changed after promotion'; ((failures++)); }
    fi
    ((failures == 0))
}

r13_restore_source_first_after_failed_promotion() {
    local restore
    restore=$(r13_source_first_order_from_current 2>/dev/null || true)
    [[ -n $restore ]] || return 1
    sudo efibootmgr -o "$restore" >/dev/null 2>&1 || return 1
    leap16_validate_pending_firmware_order 'Promotion rollback' >/dev/null 2>&1
}

leap16_promote_runtime_proven_limine_core() {
    validate_pending_compatibility || { fail "Pending migration is not compatible: $PENDING_REASON"; return 1; }
    [[ $PENDING_SOURCE == grub && $PENDING_TARGET == limine && $PENDING_PHASE == runtime-validated ]] || {
        fail 'Persistent promotion requires runtime-validated GRUB2 -> Limine state'
        return 1
    }
    detect_bootloader
    [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || {
        fail "Persistent promotion must run from the exact runtime-proven Limine Boot$PENDING_TARGET_BOOT_ID session"
        return 1
    }
    leap16_require_sudo_session || return 1
    run_validation preflight || return 1
    pending_validate_running_kernel || return 1
    pending_validate_runtime_cmdline_against_source || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1
    verify_pending_source_recovery_unchanged || return 1
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext must be clear before persistent promotion'; return 1; }
    leap16_validate_pending_firmware_order 'Pre-promotion' || return 1

    local promoted diag
    promoted=$(r13_promoted_order_from_current) || { fail 'Could not derive safe target-first/source-second BootOrder'; return 1; }
    printf '\nPROMOTE runtime-proven Limine:\n'
    printf '  - set Limine Boot%s first in persistent BootOrder\n' "$PENDING_TARGET_BOOT_ID"
    printf '  - retain GRUB2 recovery Boot%s immediately after the target\n' "$PENDING_OLD_BOOT_ID"
    printf '  - retain /boot/grub2, EFI/opensuse, /etc/default/grub and EFI/BOOT/BOOTX64.EFI byte-for-byte\n'
    printf '  - r21 checkpoint: GRUB2 retirement stays locked until the separate Limine fallback runtime proof\n'

    sudo efibootmgr -o "$promoted" >/dev/null || { fail 'Could not write target-first/source-second persistent BootOrder'; return 1; }
    if ! leap16_validate_promoted_firmware_order 'Post-promotion'; then
        warn 'Promotion ordering failed validation; attempting immediate source-first recovery without deleting any boot state'
        r13_restore_source_first_after_failed_promotion || true
        leap16_stage_diagnostic promotion-order-failed
        return 1
    fi
    verify_pending_candidate_ownership_unchanged || {
        warn 'Target ownership failed after promotion; attempting immediate source-first recovery'
        r13_restore_source_first_after_failed_promotion || true
        leap16_stage_diagnostic promotion-target-ownership-failed
        return 1
    }
    validate_pending_target_deep || {
        warn 'Target deep validation failed after promotion; attempting immediate source-first recovery'
        r13_restore_source_first_after_failed_promotion || true
        leap16_stage_diagnostic promotion-target-deep-failed
        return 1
    }
    leap16_verify_grub_recovery_after_promotion || {
        warn 'GRUB2 recovery validation failed after promotion; attempting immediate source-first recovery'
        r13_restore_source_first_after_failed_promotion || true
        leap16_stage_diagnostic promotion-recovery-failed
        return 1
    }
    [[ -z $(pending_bootnext_id) ]] || {
        warn 'BootNext unexpectedly appeared after promotion; attempting immediate source-first recovery'
        r13_restore_source_first_after_failed_promotion || true
        leap16_stage_diagnostic promotion-unexpected-bootnext
        return 1
    }

    detect_bootloader
    [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || {
        fail 'Running Limine identity changed during promotion'
        r13_restore_source_first_after_failed_promotion || true
        return 1
    }
    diag=$(leap16_capture_required_diagnostic promotion-pass || true)
    [[ -n $diag ]] && printf 'Promotion diagnostic snapshot: %s\n' "$diag" || warn 'Promotion succeeded but promotion-pass diagnostics could not be captured'
    printf '\nPROMOTION-VALIDATED. Limine is now first persistently; GRUB2 recovery remains intact and second.\n'
    return 0
}

leap16_finish_manual_promotion() {
    leap16_promote_runtime_proven_limine_core || return 1
    remove_pending_transaction_snapshot || warn 'Could not remove private transaction snapshot after promotion'
    rm -f -- "$PENDING_STATE_FILE"
    pending_reset
    ok 'AUTOMATED-BOUNDARY COMPLETE. Limine is persistent; GRUB2 recovery was intentionally retained.'
}

r13_prompt_reboot() {
    local answer
    printf '\nThe one-shot Limine test and root-owned automatic resume service are armed.\n'
    printf 'After Limine reaches userspace, the transaction will prove the exact primary target, promote it, then stage the separate Limine fallback proof.\n'
    printf 'GRUB2/shim/config remain intact through the primary proof and fallback staging; they are retired only after the exact Limine fallback runtime proof succeeds.\n'
    read -r -p 'Reboot now? [y/N]: ' answer
    case "$answer" in
        y|Y|yes|YES)
            printf 'Rebooting now. No firmware-menu selection is required.\n'
            sudo systemctl reboot
            ;;
        *)
            printf 'Reboot deferred. BootNext and the temporary resume service remain armed for the next normal reboot.\n'
            ;;
    esac
}

r13_arm_candidate_automatically() {
    validate_pending_compatibility || { fail "Pending migration is not compatible: $PENDING_REASON"; return 1; }
    [[ $PENDING_PHASE == candidate-ready ]] || { fail 'Automatic arming requires candidate-ready state'; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == ${PENDING_OLD_BOOT_ID^^} ]] || {
        fail "Automatic arming requires recorded source GRUB2 Boot$PENDING_OLD_BOOT_ID"
        return 1
    }
    leap16_require_sudo_session || return 1
    run_validation preflight || return 1
    leap16_validate_pending_firmware_order 'Automatic pre-arm' || return 1
    verify_pending_source_recovery_unchanged || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext is already owned by another request'; return 1; }

    local before_order next diag
    before_order=$(leap16_current_boot_order) || return 1
    sudo efibootmgr -n "$PENDING_TARGET_BOOT_ID" >/dev/null || return 1
    next=$(pending_bootnext_id)
    if [[ ${next^^} != ${PENDING_TARGET_BOOT_ID^^} || $(leap16_current_boot_order) != "$before_order" ]]; then
        [[ ${next^^} == ${PENDING_TARGET_BOOT_ID^^} ]] && sudo efibootmgr -N >/dev/null 2>&1 || true
        fail 'Automatic BootNext arming changed persistent BootOrder or failed exact BootNext verification'
        return 1
    fi
    pending_set_phase boot-armed || {
        sudo efibootmgr -N >/dev/null 2>&1 || true
        fail 'Could not persist boot-armed phase; BootNext was cleared'
        return 1
    }
    PENDING_PHASE=boot-armed
    diag=$(leap16_capture_required_diagnostic bootnext-armed || true)
    if [[ -z $diag ]]; then
        sudo efibootmgr -N >/dev/null 2>&1 || true
        pending_set_phase candidate-ready >/dev/null 2>&1 || true
        fail 'BootNext was armed but bootnext-armed diagnostics could not be captured; arming was rolled back'
        return 1
    fi
    ok "Automatically armed one-time Limine BootNext=Boot$PENDING_TARGET_BOOT_ID without changing persistent BootOrder"

    if ! r22_prepare_resume_bundle; then
        fail 'Could not prepare the root-owned automatic resume bundle; clearing transaction BootNext for safety'
        r22_rollback_automation_arm
        r22_disarm_user_resume_bundle || true
        return 1
    fi
    ok "Installed temporary root-owned automatic resume service: $R22_SERVICE_NAME"
    r13_prompt_reboot
}

r13_prepare_resume_for_existing_armed_transaction() {
    validate_pending_compatibility || { fail "Pending migration is not compatible: $PENDING_REASON"; return 1; }
    [[ $PENDING_PHASE == boot-armed ]] || { fail 'Existing-armed automation adoption requires boot-armed state'; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == ${PENDING_OLD_BOOT_ID^^} ]] || {
        fail 'Existing-armed automation adoption must be run from the recorded GRUB2 source session'
        return 1
    }
    leap16_require_sudo_session || return 1
    [[ ${BOOT_NEXT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail "Expected BootNext=Boot$PENDING_TARGET_BOOT_ID, found ${BOOT_NEXT:-none}"; return 1; }
    leap16_validate_pending_firmware_order 'Automation adoption' || return 1
    verify_pending_source_recovery_unchanged || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1
    if r13_resume_bundle_is_prepared; then
        ok 'Root-owned automatic resume bundle/service is already prepared for this BootNext'
        r13_prompt_reboot
        return 0
    fi
    r22_prepare_resume_bundle || { fail 'Could not prepare root-owned automatic resume for the already-armed transaction'; return 1; }
    leap16_stage_diagnostic automation-adopted
    ok 'Adopted the already-armed r12/r13 BootNext into the root-owned automatic resume flow'
    r13_prompt_reboot
}

# Fresh r13 staging no longer stops at candidate-ready.  The user's STAGE
# authorization covers candidate construction plus the same automatic one-shot
# handoff used by CachyOS r47; failure to prepare automation returns safely to a
# parked candidate with GRUB2 still first.
eval "$(declare -f execute_grub_to_limine | sed '1s/execute_grub_to_limine/execute_grub_to_limine_pre_r13/')"
execute_grub_to_limine() {
    execute_grub_to_limine_pre_r13 "$@" || return $?
    pending_exists || return 0
    load_pending_state || return 1
    if [[ $PENDING_SOURCE == grub && $PENDING_TARGET == limine && $PENDING_PHASE == candidate-ready ]]; then
        r13_arm_candidate_automatically
    fi
}

# Expose the automation hook expected by the inherited r23 lineage too.
r23_after_fresh_grub_to_limine_candidate() { r13_arm_candidate_automatically; }
r23_finalize_grub_to_limine() { leap16_finish_manual_promotion; }

# Root-owned automatic continuation.  It uses the copied tool + copied pending
# state/snapshot, never user-writable code for privileged post-boot decisions.
r22_resume_transaction_root() {
    r22_root_bundle_preflight || return 1
    local bundle=$R22_RESUME_BUNDLE conf="$R22_RESUME_BUNDLE/resume.conf" detail rc=0
    mkdir -p -- "$bundle/diagnostics" || return 1
    LEAP16_DIAGNOSTIC_ROOT="$bundle/diagnostics"
    LEAP16_AUTO_RESUME=1
    export LEAP16_DIAGNOSTIC_ROOT LEAP16_AUTO_RESUME
    exec > >(tee -a "$bundle/automatic-resume.log") 2>&1

    printf 'openSUSE Bootloader Switcher automatic transaction resume\n'
    printf 'Bundle: %s\n' "$bundle"
    load_pending_state || {
        printf 'Automatic resume: root-owned pending state is invalid: %s\n' "$PENDING_REASON" >&2
        leap16_capture_diagnostics auto-resume-invalid-state >/dev/null 2>&1 || true
        r22_write_user_result "$conf" failed 'Root-owned automatic resume state failed validation; no persistent promotion was attempted.' || true
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
        r22_remove_resume_service_files
        return 1
    }
    validate_pending_compatibility || {
        leap16_capture_diagnostics auto-resume-incompatible >/dev/null 2>&1 || true
        r22_write_user_result "$conf" failed "Automatic resume transaction is incompatible: $PENDING_REASON" || true
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
        r22_remove_resume_service_files
        return 1
    }

    detect_bootloader
    if [[ $BOOTLOADER == "$PENDING_SOURCE" && ${BOOT_CURRENT^^} == ${PENDING_OLD_BOOT_ID^^} ]]; then
        printf 'Automatic resume: firmware returned to the recorded GRUB2 source; no target proof and no promotion are allowed.\n'
        if r22_resume_source_fallback "$conf"; then
            leap16_capture_diagnostics auto-resume-source-fallback >/dev/null 2>&1 || true
            r13_sync_root_diagnostics_to_user "$conf" "$bundle" safe-fallback || true
            return 0
        fi
        leap16_capture_diagnostics auto-resume-source-fallback-failed >/dev/null 2>&1 || true
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
        return 1
    fi

    if [[ $BOOTLOADER != "$PENDING_TARGET" || ${BOOT_CURRENT^^} != ${PENDING_TARGET_BOOT_ID^^} ]]; then
        printf 'Automatic resume: current EFI boot is neither the exact source nor exact target; refusing writes.\n' >&2
        leap16_capture_diagnostics auto-resume-unexpected-bootcurrent >/dev/null 2>&1 || true
        r22_write_user_result "$conf" failed 'Automatic resume saw an unexpected BootCurrent/bootloader identity; source cleanup and promotion were refused.' || true
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
        r22_remove_resume_service_files
        return 1
    fi

    case "$PENDING_PHASE" in
        boot-armed)
            validate_pending_target_runtime || {
                r22_write_user_result "$conf" failed 'Limine booted but automatic runtime proof failed; persistent promotion was NOT attempted.' || true
                leap16_capture_diagnostics auto-resume-runtime-failed >/dev/null 2>&1 || true
                r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
                r22_remove_resume_service_files
                return 1
            }
            PENDING_PHASE=runtime-validated
            r22_sync_user_phase_from_root "$conf" runtime-validated || true
            ;;
        runtime-validated)
            printf 'Automatic resume: exact Limine runtime proof was already persisted; continuing to promotion.\n'
            ;;
        *)
            r22_write_user_result "$conf" failed "Unexpected automatic-resume phase: $PENDING_PHASE" || true
            leap16_capture_diagnostics auto-resume-unexpected-phase >/dev/null 2>&1 || true
            r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
            r22_remove_resume_service_files
            return 1
            ;;
    esac

    if ! leap16_promote_runtime_proven_limine_core; then
        r22_write_user_result "$conf" failed 'Runtime proof passed, but safe Limine promotion failed. GRUB2 recovery was retained and the transaction remains available for inspection.' || true
        leap16_capture_diagnostics auto-resume-promotion-failed >/dev/null 2>&1 || true
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
        r22_remove_resume_service_files
        return 1
    fi

    leap16_capture_diagnostics auto-resume-pass >/dev/null 2>&1 || true
    r13_sync_root_diagnostics_to_user "$conf" "$bundle" success || true
    detail="GRUB2 -> Limine automated runtime proof and persistent promotion succeeded. Limine Boot$PENDING_TARGET_BOOT_ID is first; GRUB2 Boot$PENDING_OLD_BOOT_ID and the openSUSE shim fallback were retained as recovery."

    remove_pending_transaction_snapshot || true
    rm -f -- "$PENDING_STATE_FILE"
    r22_cleanup_user_shadow_after_success "$conf"
    r22_write_user_result "$conf" success "$detail" || true
    r22_remove_resume_service_files
    rm -rf -- "$bundle" 2>/dev/null || true
    return 0
}

# Make manual runtime proof output truthful when it is being invoked by the
# root-owned automatic continuation: promotion follows immediately, while the
# interactive/manual path still explains that no source retirement occurs.
# (The validator itself remains identical; only its final guidance changed in
# r13's source text above.)

# r13 pending UX ------------------------------------------------------------
pending_banner() {
    pending_exists || return 0
    if validate_pending_compatibility >/dev/null 2>&1; then
        detect_bootloader
        printf 'Pending/staged migration: %s -> %s  [%s]' "$(bootloader_display_name "$PENDING_SOURCE")" "$(bootloader_display_name "$PENDING_TARGET")" "$PENDING_PHASE"
        case "$PENDING_PHASE:$BOOTLOADER" in
            candidate-ready:grub) printf '  [PARKED; AUTO-ARM AVAILABLE]\n' ;;
            boot-armed:grub)
                if [[ ${BOOT_NEXT^^} == ${PENDING_TARGET_BOOT_ID^^} ]]; then
                    if r13_resume_bundle_is_prepared 2>/dev/null; then printf '  [BootNext + AUTO-RESUME ARMED]\n'; else printf '  [BootNext ARMED; AUTO-RESUME NOT YET INSTALLED]\n'; fi
                elif [[ -z ${BOOT_NEXT:-} ]]; then printf '  [ONE-SHOT CONSUMED/CLEARED; SOURCE ACTIVE]\n';
                else printf '  [UNRELATED BootNext=%s]\n' "$BOOT_NEXT"; fi
                ;;
            boot-armed:limine) printf '  [LIMINE ACTIVE; AUTO-RESUME SHOULD VALIDATE]\n' ;;
            runtime-validated:limine) printf '  [LIMINE RUNTIME PROVEN; PROMOTION ELIGIBLE]\n' ;;
            runtime-validated:grub) printf '  [RUNTIME PROOF RECORDED; SOURCE ACTIVE]\n' ;;
            *) printf '  [CURRENT: %s]\n' "$(bootloader_display_name "$BOOTLOADER")" ;;
        esac
    else
        printf 'Pending/staged migration exists but is incompatible: %s\n' "${PENDING_REASON:-unknown}"
    fi
}

manage_pending_migration() {
    pending_exists || { printf '\nNo pending/staged migration exists.\n'; return 0; }
    validate_pending_compatibility || { printf '\nPending migration state is invalid/incompatible: %s\n' "$PENDING_REASON"; return 1; }
    detect_bootloader
    show_pending_details

    local choice next
    if [[ $BOOTLOADER == limine ]]; then
        case "$PENDING_PHASE" in
            boot-armed)
                printf '\nThe transaction-armed Limine one-shot is running. If the temporary service did not run, manual recovery is available here.\n'
                printf '[1] Run exact runtime validation now\n'
                printf '[2] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in 1) validate_pending_target_runtime ;; 2|'') return 0 ;; *) printf 'Invalid selection.\n'; return 1 ;; esac
                ;;
            runtime-validated)
                printf '\nThis exact Limine session has runtime proof. GRUB2 recovery is still intact.\n'
                printf '[1] Re-run runtime validation\n'
                printf '[2] Promote Limine persistently now (keep GRUB2 recovery)\n'
                printf '[3] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in 1) validate_pending_target_runtime ;; 2) leap16_finish_manual_promotion ;; 3|'') return 0 ;; *) printf 'Invalid selection.\n'; return 1 ;; esac
                ;;
            candidate-ready)
                printf '\nLimine was entered without transaction arming; this session is not accepted as runtime proof.\n'
                return 1
                ;;
        esac
    elif [[ $BOOTLOADER == grub ]]; then
        [[ ${BOOT_CURRENT^^} == ${PENDING_OLD_BOOT_ID^^} ]] || { fail "GRUB2 is active through Boot${BOOT_CURRENT:-unknown}, not recorded source Boot$PENDING_OLD_BOOT_ID"; return 1; }
        case "$PENDING_PHASE" in
            candidate-ready)
                printf '\nGRUB2 source is active and the Limine candidate is parked.\n'
                printf '[1] Re-run source + candidate validation\n'
                printf '[2] Arm Limine + install automatic resume\n'
                printf '[3] Roll back this exact candidate\n'
                printf '[4] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) leap16_require_sudo_session && run_validation preflight && leap16_validate_pending_firmware_order 'Candidate re-check' && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep ;;
                    2) r13_arm_candidate_automatically ;;
                    3) rollback_pending_candidate ;;
                    4|'') return 0 ;;
                    *) printf 'Invalid selection.\n'; return 1 ;;
                esac
                ;;
            boot-armed)
                next=$(pending_bootnext_id)
                if [[ ${next^^} == ${PENDING_TARGET_BOOT_ID^^} ]]; then
                    printf '\nOne-time Limine BootNext is armed and waiting for reboot.\n'
                    if r13_resume_bundle_is_prepared 2>/dev/null; then
                        printf 'The root-owned automatic resume service is prepared.\n'
                    else
                        printf 'This looks like an r12/manual arm: automatic resume is NOT installed yet.\n'
                    fi
                    printf '[1] Re-check source/candidate integrity\n'
                    printf '[2] Prepare/verify automatic resume and reboot prompt\n'
                    printf '[3] Cancel transaction BootNext\n'
                    printf '[4] Roll back the staged candidate\n'
                    printf '[5] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in
                        1) leap16_require_sudo_session && run_validation preflight && leap16_validate_pending_firmware_order 'Armed re-check' && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged ;;
                        2) r13_prepare_resume_for_existing_armed_transaction ;;
                        3) cancel_pending_one_time_boot ;;
                        4) rollback_pending_candidate ;;
                        5|'') return 0 ;;
                        *) printf 'Invalid selection.\n'; return 1 ;;
                    esac
                elif [[ -z $next ]]; then
                    printf '\nThe transaction is boot-armed but BootNext is gone and GRUB2 is active; no target runtime proof exists.\n'
                    printf '[1] Revalidate and return to candidate-ready\n[2] Roll back candidate\n[3] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in 1) leap16_require_sudo_session && reset_consumed_test_to_candidate_ready ;; 2) rollback_pending_candidate ;; 3|'') return 0 ;; *) printf 'Invalid selection.\n'; return 1 ;; esac
                else
                    fail "BootNext belongs to unrelated Boot$next; r13 will not touch it"
                    return 1
                fi
                ;;
            runtime-validated)
                printf '\nLimine runtime proof exists but GRUB2 is active again. Promotion is allowed only from the exact Limine target session.\n'
                printf '[1] Prove/capture this GRUB2 source return\n'
                printf '[2] Re-check source + candidate ownership\n'
                printf '[3] Re-arm Limine with automatic resume for promotion\n'
                printf '[4] Roll back/abandon the Limine candidate\n'
                printf '[5] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in
                    1) leap16_verify_source_return_after_runtime ;;
                    2) leap16_require_sudo_session && run_validation preflight && leap16_validate_pending_firmware_order 'Runtime-proven candidate re-check' && verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged ;;
                    3)
                        pending_set_phase candidate-ready || return 1
                        load_pending_state || return 1
                        r13_arm_candidate_automatically
                        ;;
                    4) rollback_pending_candidate ;;
                    5|'') return 0 ;;
                    *) printf 'Invalid selection.\n'; return 1 ;;
                esac
                ;;
        esac
    else
        fail 'Current bootloader is neither the recorded GRUB2 source nor Limine target'
        return 1
    fi
}

# Any successful cancellation/rollback must not leave a root-owned resume unit
# capable of firing later.  The inherited r22 cancellation wrapper already
# disarms its bundle; cover the Leap-specific rollback override as well.
eval "$(declare -f rollback_pending_grub_to_limine | sed '1s/rollback_pending_grub_to_limine/rollback_pending_grub_to_limine_pre_r13/')"
rollback_pending_grub_to_limine() {
    local rc=0
    rollback_pending_grub_to_limine_pre_r13 "$@" || rc=$?
    if ((rc == 0)) || [[ ! -f ${PENDING_STATE_FILE:-/nonexistent} ]]; then
        r22_disarm_user_resume_bundle || true
    fi
    return "$rc"
}

rollback_pending_candidate() {
    rollback_pending_grub_to_limine "$@"
}

# leap16-r15 two-way GRUB2 <-> Limine transaction ---------------------------
# The forward GRUB2 -> Limine path remains the proven r13/r14 implementation.
# r15 adds the reverse path by adopting the native openSUSE GRUB2/shim chain
# that r13 deliberately retained as recovery.  No grub reinstall is performed.
# Source Limine remains first until a one-shot Boot0000 GRUB2 boot obtains exact
# runtime proof.  Only then is GRUB2 promoted and the ownership-proven Limine
# source retired; the shared EFI/BOOT/BOOTX64.EFI shim fallback is preserved.

R22_SYSTEM_ROOT=/var/lib/opensuse-bootloader-switcher/r15
R22_BUNDLE_MARKER=.leap16-r15-root-owned-resume-bundle
R21_GRUB_THEME_DIR=/boot/grub2/themes/openSUSE
R21_GRUB_THEME_PATH=/boot/grub2/themes/openSUSE/theme.txt

# Preserve r14/r13 behavior so the new layer is direction-selective.
eval "$(declare -f target_expected_efi_path | sed '1s/target_expected_efi_path/target_expected_efi_path_pre_r15/')"
eval "$(declare -f operation_supported | sed '1s/operation_supported/operation_supported_pre_r15/')"
eval "$(declare -f validate_pending_owned_paths | sed '1s/validate_pending_owned_paths/validate_pending_owned_paths_pre_r15/')"
eval "$(declare -f validate_pending_target_deep | sed '1s/validate_pending_target_deep/validate_pending_target_deep_pre_r15/')"
eval "$(declare -f validate_pending_target_runtime | sed '1s/validate_pending_target_runtime/validate_pending_target_runtime_pre_r15/')"
eval "$(declare -f run_switch_preflight | sed '1s/run_switch_preflight/run_switch_preflight_pre_r15/')"
eval "$(declare -f run_live_operation | sed '1s/run_live_operation/run_live_operation_pre_r15/')"
eval "$(declare -f pending_banner | sed '1s/pending_banner/pending_banner_pre_r15/')"
eval "$(declare -f manage_pending_migration | sed '1s/manage_pending_migration/manage_pending_migration_pre_r15/')"
eval "$(declare -f rollback_pending_candidate | sed '1s/rollback_pending_candidate/rollback_pending_candidate_pre_r15/')"
eval "$(declare -f r22_resume_transaction_root | sed '1s/r22_resume_transaction_root/r22_resume_transaction_root_pre_r15/')"

target_expected_efi_path() {
    case "$1" in
        grub) printf '\\EFI\\OPENSUSE\\SHIM.EFI\n' ;;
        *) target_expected_efi_path_pre_r15 "$@" ;;
    esac
}

operation_supported() {
    local current=$1 target=$2
    case "$current:$target" in
        grub:limine|limine:grub) return 0 ;;
        *) return 1 ;;
    esac
}

leap16_reverse_pending() {
    [[ ${PENDING_FORMAT:-} == 4 && ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == limine:grub && ${PENDING_GRUB_DEFAULT_CREATED:-} == 0 ]]
}

leap16_hash_file_privileged() {
    local p=$1
    sudo -n sha256sum -- "$p" 2>/dev/null | awk '{print $1}' || sha256sum -- "$p" 2>/dev/null | awk '{print $1}' || true
}

leap16_validate_retained_grub_target() {
    local target_id=${1^^} failures=0 hash ver line fallback target_resolved
    printf '\nRetained native openSUSE GRUB2 target validation:\n'

    leap16_boot_entry_is_active "$target_id" \
        && ok "Retained GRUB2 Boot$target_id is active" \
        || { fail "Retained GRUB2 Boot$target_id is not active"; ((failures++)); }
    nvram_id_matches_path "$target_id" "$(target_expected_efi_path grub)" \
        && ok "Boot$target_id points to $(target_expected_efi_path grub)" \
        || { fail "Boot$target_id does not point to the native openSUSE shim path"; ((failures++)); }
    leap16_nvram_entry_matches_current_esp "$target_id" \
        && ok "Boot$target_id is bound to the detected ESP" \
        || { fail "Boot$target_id is not bound to the detected ESP"; ((failures++)); }

    target_resolved=$(resolve_efi_path_on_esp_privileged "$(target_expected_efi_path grub)" 2>/dev/null || true)
    [[ -n $target_resolved ]] && ok "Native openSUSE shim exists: $target_resolved" \
        || { fail 'Native openSUSE shim is missing'; ((failures++)); }
    [[ -f /boot/grub2/grub.cfg ]] && ok '/boot/grub2/grub.cfg exists' || { fail '/boot/grub2/grub.cfg is missing'; ((failures++)); }
    [[ -f /etc/default/grub ]] && ok '/etc/default/grub exists' || { fail '/etc/default/grub is missing'; ((failures++)); }
    if have grub2-script-check; then
        leap16_grub_cfg_script_check >/dev/null 2>&1 \
            && ok 'grub2-script-check accepts retained grub.cfg' \
            || { fail 'grub2-script-check rejected retained grub.cfg'; ((failures++)); }
    else
        fail 'grub2-script-check is unavailable'; ((failures++))
    fi
    grep -Eq '^[[:space:]]*LOADER_TYPE=.*grub2-efi' /etc/sysconfig/bootloader 2>/dev/null \
        && ok 'openSUSE LOADER_TYPE reports grub2-efi' \
        || { fail 'openSUSE LOADER_TYPE is not grub2-efi'; ((failures++)); }

    collect_kernels
    ((${#KERNEL_VERSIONS[@]} > 0)) || { fail 'No complete /boot/vmlinuz-* + /boot/initrd-* pairs exist'; ((failures++)); }
    for ver in "${KERNEL_VERSIONS[@]}"; do
        [[ -e /boot/vmlinuz-$ver ]] || { fail "Kernel missing: /boot/vmlinuz-$ver"; ((failures++)); continue; }
        [[ -e /boot/initrd-$ver ]] || { fail "Initrd missing: /boot/initrd-$ver"; ((failures++)); continue; }
        line=$(leap16_grub_cfg_grep -F -- "/boot/vmlinuz-$ver" 2>/dev/null | head -n1 || true)
        [[ -n $line ]] && ok "grub.cfg contains kernel $ver" || { fail "grub.cfg has no entry for kernel $ver"; ((failures++)); }
    done
    if [[ -n ${ROOT_UUID:-} ]] && leap16_grub_cfg_grep -Fq -- "root=UUID=$ROOT_UUID" >/dev/null 2>&1; then
        ok 'retained grub.cfg carries the detected root UUID'
    else
        fail 'retained grub.cfg does not carry the detected root UUID'; ((failures++))
    fi
    validate_cachyos_grub_theme || ((failures++))

    fallback="$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"
    if [[ -n $target_resolved ]] && (sudo -n test -f "$fallback" 2>/dev/null || [[ -f $fallback ]]); then
        hash=$(leap16_hash_file_privileged "$target_resolved")
        [[ -n $hash && $(leap16_hash_file_privileged "$fallback") == "$hash" ]] \
            && ok 'Shared EFI fallback is byte-identical to the retained openSUSE shim' \
            || { fail 'Shared EFI fallback is not byte-identical to the retained openSUSE shim'; ((failures++)); }
    else
        fail 'Shared EFI fallback or retained shim is unavailable'; ((failures++))
    fi
    ((failures == 0))
}

leap16_snapshot_source_limine_retirement_ownership() {
    local efi_dir splash hash
    [[ -n ${TRANSACTION_SNAPSHOT_DIR:-} && -d $TRANSACTION_SNAPSHOT_DIR ]] || return 1
    efi_dir=$(dirname -- "$SOURCE_LIMINE_EFI_RESOLVED")
    write_privileged_tree_manifest "$efi_dir" "$TRANSACTION_SNAPSHOT_DIR/source-limine-efi-dir.tsv" \
        || { fail 'Could not snapshot exact source EFI/LIMINE ownership'; return 1; }
    write_privileged_tree_manifest "$SOURCE_LIMINE_MANAGED_DIR" "$TRANSACTION_SNAPSHOT_DIR/source-limine-managed-dir.tsv" \
        || { fail 'Could not snapshot exact source Limine managed kernel tree'; return 1; }
    splash="$ESP_MOUNT/limine-splash.png"
    if sudo -n test -f "$splash" 2>/dev/null || [[ -f $splash ]]; then
        hash=$(leap16_hash_file_privileged "$splash")
        [[ $hash =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
        printf '%s\n' "$hash" >"$TRANSACTION_SNAPSHOT_DIR/source-limine-splash.sha256" || return 1
    else
        : >"$TRANSACTION_SNAPSHOT_DIR/source-limine-splash.absent" || return 1
    fi
    chmod 600 -- "$TRANSACTION_SNAPSHOT_DIR"/source-limine-* 2>/dev/null || true
    ok 'Recorded exact source Limine retirement ownership'
}

leap16_snapshot_retained_grub_target() {
    local target_id=${1^^} i ver h fallback theme_manifest
    [[ -n ${TRANSACTION_SNAPSHOT_DIR:-} && -d $TRANSACTION_SNAPSHOT_DIR ]] || { fail 'Transaction snapshot directory is unavailable'; return 1; }

    TARGET_EFI_RESOLVED=$(resolve_efi_path_on_esp_privileged "$(target_expected_efi_path grub)" 2>/dev/null || true)
    [[ -n $TARGET_EFI_RESOLVED ]] || { fail 'Could not resolve retained openSUSE shim target'; return 1; }
    TARGET_EFI_HASH=$(leap16_hash_file_privileged "$TARGET_EFI_RESOLVED")
    [[ $TARGET_EFI_HASH =~ ^[0-9A-Fa-f]{64}$ ]] || { fail 'Could not hash retained openSUSE shim target'; return 1; }

    TARGET_GRUB_DIR=/boot/grub2
    TARGET_GRUB_CFG_PATH=/boot/grub2/grub.cfg
    TARGET_GRUB_CFG_HASH=$(leap16_hash_file_privileged "$TARGET_GRUB_CFG_PATH")
    [[ $TARGET_GRUB_CFG_HASH =~ ^[0-9A-Fa-f]{64}$ ]] || { fail 'Could not hash retained grub.cfg'; return 1; }
    GRUB_DEFAULT_CREATED=0
    GRUB_DEFAULT_HASH=$(leap16_hash_file_privileged /etc/default/grub)
    [[ $GRUB_DEFAULT_HASH =~ ^[0-9A-Fa-f]{64}$ ]] || { fail 'Could not hash retained /etc/default/grub'; return 1; }

    GRUB_ARTIFACT_MANIFEST="$TRANSACTION_SNAPSHOT_DIR/grub-artifacts.tsv"
    : >"$GRUB_ARTIFACT_MANIFEST" || return 1
    collect_kernels
    for ver in "${KERNEL_VERSIONS[@]}"; do
        for p in "/boot/vmlinuz-$ver" "/boot/initrd-$ver"; do
            h=$(leap16_hash_file_privileged "$p")
            [[ $h =~ ^[0-9A-Fa-f]{64}$ ]] || { fail "Could not hash retained GRUB2 boot artifact: $p"; return 1; }
            printf 'shared\t%s\t%s\n' "$h" "$p" >>"$GRUB_ARTIFACT_MANIFEST" || return 1
        done
    done
    [[ -s $GRUB_ARTIFACT_MANIFEST ]] || { fail 'Retained GRUB2 artifact manifest is empty'; return 1; }

    GRUB_DIR_MANIFEST="$TRANSACTION_SNAPSHOT_DIR/grub-dir.tsv"
    write_privileged_tree_manifest "$TARGET_GRUB_DIR" "$GRUB_DIR_MANIFEST" || { fail 'Could not snapshot retained /boot/grub2 tree'; return 1; }
    TARGET_GRUB_EFI_DIR=$(dirname -- "$TARGET_EFI_RESOLVED")
    GRUB_EFI_DIR_MANIFEST="$TRANSACTION_SNAPSHOT_DIR/grub-efi-dir.tsv"
    write_privileged_tree_manifest "$TARGET_GRUB_EFI_DIR" "$GRUB_EFI_DIR_MANIFEST" || { fail 'Could not snapshot retained openSUSE EFI namespace'; return 1; }

    theme_manifest="$TRANSACTION_SNAPSHOT_DIR/grub-theme-dir.tsv"
    write_privileged_tree_manifest "$R21_GRUB_THEME_DIR" "$theme_manifest" || { fail 'Could not snapshot native openSUSE GRUB theme'; return 1; }
    printf 'required\n' >"$TRANSACTION_SNAPSHOT_DIR/grub-theme-required" || return 1
    chmod 600 -- "$GRUB_ARTIFACT_MANIFEST" "$GRUB_DIR_MANIFEST" "$GRUB_EFI_DIR_MANIFEST" "$theme_manifest" "$TRANSACTION_SNAPSHOT_DIR/grub-theme-required" 2>/dev/null || true

    fallback="$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"
    POST_STAGE_FALLBACK_HASH=$(leap16_hash_file_privileged "$fallback")
    [[ $POST_STAGE_FALLBACK_HASH == "$OLD_FALLBACK_HASH" ]] || { fail 'Shared EFI fallback changed while adopting retained GRUB2 target'; return 1; }
    ok "Recorded exact retained GRUB2 target ownership for Boot$target_id"
}

validate_pending_owned_paths() {
    if ! leap16_reverse_pending; then
        validate_pending_owned_paths_pre_r15 "$@"
        return $?
    fi
    local machine_id expected_target expected_old actual_target actual_old manifest
    machine_id=$(cat /etc/machine-id 2>/dev/null || true)
    expected_target=$(safe_realpath "$ESP_MOUNT/$(normalize_efi_path "$(target_expected_efi_path grub)")")
    expected_old=$(safe_realpath "$ESP_MOUNT/$(normalize_efi_path "$PENDING_OLD_BOOT_EFI_PATH")")
    actual_target=$(safe_realpath "$PENDING_TARGET_EFI_RESOLVED")
    actual_old=$(safe_realpath "$PENDING_SOURCE_LIMINE_EFI_RESOLVED")

    [[ ${actual_target,,} == ${expected_target,,} ]] || { PENDING_REASON='pending retained GRUB2 target EFI path is unexpected'; return 1; }
    [[ ${actual_old,,} == ${expected_old,,} ]] || { PENDING_REASON='pending source Limine EFI path is unexpected'; return 1; }
    pending_hash_is_sha256 "$PENDING_TARGET_EFI_HASH" || { PENDING_REASON='invalid retained GRUB2 target EFI hash'; return 1; }
    pending_hash_is_sha256 "$PENDING_SOURCE_LIMINE_EFI_HASH" || { PENDING_REASON='invalid source Limine EFI hash'; return 1; }
    pending_validate_snapshot_dir || return 1
    pending_validate_fallback_metadata || return 1

    [[ $(safe_realpath "$PENDING_SOURCE_LIMINE_CONF_PATH") == $(safe_realpath "$ESP_MOUNT/limine.conf") ]] || { PENDING_REASON='pending source limine.conf path is unexpected'; return 1; }
    [[ $(safe_realpath "$PENDING_SOURCE_LIMINE_MANAGED_DIR") == $(safe_realpath "$ESP_MOUNT/$machine_id") ]] || { PENDING_REASON='pending source Limine managed directory is unexpected'; return 1; }
    pending_hash_is_sha256 "$PENDING_SOURCE_LIMINE_CONF_HASH" || { PENDING_REASON='invalid source limine.conf hash'; return 1; }
    pending_hash_is_sha256 "$PENDING_SOURCE_LIMINE_DEFAULT_HASH" || { PENDING_REASON='invalid source /etc/default/limine hash'; return 1; }
    pending_hash_is_sha256 "$PENDING_SOURCE_LIMINE_MANAGED_HASH" || { PENDING_REASON='invalid source Limine managed-tree hash'; return 1; }

    [[ $(safe_realpath "$PENDING_GRUB_CFG_PATH") == $(safe_realpath /boot/grub2/grub.cfg) ]] || { PENDING_REASON='pending retained grub.cfg path is unexpected'; return 1; }
    [[ $(safe_realpath "$PENDING_GRUB_DIR") == $(safe_realpath /boot/grub2) ]] || { PENDING_REASON='pending retained GRUB2 directory is unexpected'; return 1; }
    [[ ${PENDING_GRUB_EFI_DIR,,} == ${ESP_MOUNT,,}/efi/opensuse || ${PENDING_GRUB_EFI_DIR,,} == ${ESP_MOUNT,,}/efi/opensuse/ ]] || {
        # resolve/case-fold a VFAT path rather than requiring one spelling
        [[ $(safe_realpath "$PENDING_GRUB_EFI_DIR" | tr '[:upper:]' '[:lower:]') == $(safe_realpath "$ESP_MOUNT/EFI/opensuse" | tr '[:upper:]' '[:lower:]') ]] \
            || { PENDING_REASON='pending retained openSUSE EFI directory is unexpected'; return 1; }
    }
    pending_hash_is_sha256 "$PENDING_GRUB_CFG_HASH" || { PENDING_REASON='invalid retained grub.cfg hash'; return 1; }
    pending_hash_is_sha256 "$PENDING_GRUB_DEFAULT_HASH" || { PENDING_REASON='invalid retained /etc/default/grub hash'; return 1; }
    [[ $PENDING_GRUB_DEFAULT_CREATED == 0 ]] || { PENDING_REASON='retained GRUB2 target must not be marked transaction-created'; return 1; }
    for manifest in "$PENDING_GRUB_ARTIFACT_MANIFEST" "$PENDING_GRUB_DIR_MANIFEST" "$PENDING_GRUB_EFI_DIR_MANIFEST"; do
        [[ -n $manifest ]] || { PENDING_REASON='retained GRUB2 ownership manifest metadata is missing'; return 1; }
        pending_path_under "$manifest" "$PENDING_TRANSACTION_SNAPSHOT_DIR" || { PENDING_REASON='retained GRUB2 manifest is outside transaction snapshot'; return 1; }
        [[ -s $manifest ]] || { PENDING_REASON='retained GRUB2 manifest is missing/empty'; return 1; }
    done
    [[ -s $PENDING_TRANSACTION_SNAPSHOT_DIR/source-limine-efi-dir.tsv ]] || { PENDING_REASON='source Limine EFI retirement manifest is missing'; return 1; }
    [[ -s $PENDING_TRANSACTION_SNAPSHOT_DIR/source-limine-managed-dir.tsv ]] || { PENDING_REASON='source Limine managed-tree retirement manifest is missing'; return 1; }
    return 0
}

validate_pending_target_deep() {
    if ! leap16_reverse_pending; then
        validate_pending_target_deep_pre_r15 "$@"
        return $?
    fi
    validate_target_state grub || return 1
    if [[ ${BOOTLOADER:-} == grub && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]]; then
        validate_grub_boot_chain current || return 1
    else
        leap16_validate_retained_grub_target "$PENDING_TARGET_BOOT_ID" || return 1
    fi
    verify_pending_candidate_ownership_unchanged || return 1
    validate_cachyos_grub_theme
}

leap16_reverse_preflight() {
    printf '\nLeap 16 r15 Limine -> GRUB2 return preflight:\n'
    run_validation preflight || return 1
    [[ $BOOTLOADER == limine ]] || { fail 'Reverse transaction requires Limine as the currently booted source'; return 1; }
    [[ -n $BOOT_CURRENT && ${BOOT_CURRENT^^} == ${BOOT_CURRENT^^} ]] || return 1
    pending_exists && { fail 'A staged migration is already pending; r15 will not stack transactions'; return 1; }
    [[ -z ${BOOT_NEXT:-} ]] || { fail "BootNext is already set to Boot${BOOT_NEXT^^}"; return 1; }
    leap16_require_sudo_session || return 1
    [[ $(leap16_current_boot_order | cut -d, -f1) == ${BOOT_CURRENT^^} ]] || { fail 'Current Limine source is not first in persistent BootOrder'; return 1; }
    validate_limine_boot_chain current || return 1
    validate_cachyos_limine_theme || return 1

    local count
    count=$(count_nvram_entries_for_target grub)
    [[ $count == 1 ]] || { fail "Expected exactly one retained native openSUSE GRUB2/shim NVRAM entry, found $count"; return 1; }
    find_nvram_entry_for_target grub || { fail 'Could not resolve retained native openSUSE GRUB2/shim NVRAM entry'; return 1; }
    [[ ${TARGET_NVRAM_ID^^} != ${BOOT_CURRENT^^} ]] || { fail 'Retained GRUB2 target unexpectedly aliases the Limine source Boot####'; return 1; }
    leap16_validate_retained_grub_target "$TARGET_NVRAM_ID" || return 1
    ok "r15 preflight passed: Limine source Boot${BOOT_CURRENT^^}; retained GRUB2 target Boot${TARGET_NVRAM_ID^^}; BootNext empty"
}

run_switch_preflight() {
    local target=${1:-}
    detect_bootloader
    if [[ $BOOTLOADER:$target == limine:grub ]]; then
        leap16_reverse_preflight
    else
        run_switch_preflight_pre_r15 "$@"
    fi
}

leap16_reverse_plan() {
    local source_id=${BOOT_CURRENT^^} target_id=${TARGET_NVRAM_ID^^}
    printf '\nExact leap16-r15 Limine -> GRUB2 return plan:\n'
    printf '  1. Re-prove current Limine source Boot%s, kernels/cmdline, ESP, fallback and persistent source-first order.\n' "$source_id"
    printf '  2. Adopt and hash the already-retained native openSUSE GRUB2/shim recovery chain at Boot%s; no GRUB reinstall.\n' "$target_id"
    printf '  3. Snapshot exact Limine source retirement ownership plus exact GRUB2 target ownership.\n'
    printf '  4. Normalize candidate ordering with Limine still first and the retained GRUB2 target last; unrelated live firmware entries are preserved.\n'
    printf '  5. Persist candidate-ready state, arm BootNext=Boot%s once, and install the root-owned automatic resume service.\n' "$target_id"
    printf '  6. Reboot normally into GRUB2, prove exact BootCurrent/cmdline/root/kernel/ownership/fallback state, then promote GRUB2 first persistently.\n'
    printf '  7. Re-prove GRUB2 after promotion and re-prove the exact Limine source ownership before retirement.\n'
    printf '  8. Retire only Boot%s + ownership-proven Limine EFI/config/splash/managed kernel state.\n' "$source_id"
    printf '  9. Preserve Boot0001/direct GRUB, the openSUSE EFI namespace, and EFI/BOOT/BOOTX64.EFI shim fallback.\n'
    printf ' 10. Final deep GRUB2 validation, capture diagnostics, clear the transaction and temporary resume service.\n'
}

leap16_execute_limine_to_retained_grub() {
    local old_id=${BOOT_CURRENT^^} original_order target_id candidate_order
    original_order=$(leap16_current_boot_order) || return 1
    find_nvram_entry_for_target grub || { fail 'Retained GRUB2 target disappeared at the write boundary'; return 1; }
    target_id=${TARGET_NVRAM_ID^^}

    printf '\nExecuting %s Limine -> retained GRUB2 transaction...\n' "${SWITCHER_RELEASE:-Leap 16}"
    snapshot_limine_source_ownership || return 1
    leap16_snapshot_firmware_baseline || { r15_abandon_uncommitted_reverse_candidate "$original_order" firmware-baseline-snapshot-failed; return 1; }
    leap16_snapshot_source_limine_retirement_ownership || { r15_abandon_uncommitted_reverse_candidate "$original_order" source-ownership-snapshot-failed; return 1; }
    leap16_validate_retained_grub_target "$target_id" || { r15_abandon_uncommitted_reverse_candidate "$original_order" retained-grub-validation-failed; return 1; }
    leap16_snapshot_retained_grub_target "$target_id" || { r15_abandon_uncommitted_reverse_candidate "$original_order" retained-grub-snapshot-failed; return 1; }

    # The target is pre-existing recovery state. r47 candidate semantics still
    # require source first + target last before BootNext, so normalize only that
    # relationship while preserving currently live unrelated entries.
    set_source_first_boot_order "$old_id" "$target_id" "$original_order" || { r15_abandon_uncommitted_reverse_candidate "$original_order" candidate-order-failed; return 1; }
    candidate_order=$(leap16_current_boot_order)
    [[ ${candidate_order%%,*} == "$old_id" ]] || { fail 'Limine source is not first after candidate-order normalization'; r15_abandon_uncommitted_reverse_candidate "$original_order" candidate-order-verify-failed; return 1; }
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext appeared during candidate adoption'; r15_abandon_uncommitted_reverse_candidate "$original_order" candidate-bootnext-appeared; return 1; }

    POST_STAGE_FALLBACK_HASH=$OLD_FALLBACK_HASH
    GRUB_DIAGNOSTIC_DIR=""
    if ! write_pending_limine_to_grub "$old_id" "$original_order" "$target_id" candidate-ready; then
        fail 'Could not persist Limine -> retained GRUB2 candidate-ready metadata'
        r15_abandon_uncommitted_reverse_candidate "$original_order" pending-state-write-failed
        return 1
    fi
    load_pending_state || { r15_abandon_uncommitted_reverse_candidate "$original_order" pending-state-reload-failed; return 1; }
    validate_pending_compatibility || { fail "Fresh reverse pending state failed compatibility: $PENDING_REASON"; r15_abandon_uncommitted_reverse_candidate "$original_order" pending-compatibility-failed; return 1; }
    leap16_validate_pending_firmware_order 'Reverse candidate' || { r15_abandon_uncommitted_reverse_candidate "$original_order" candidate-firmware-order-failed; return 1; }
    verify_pending_source_recovery_unchanged || { r15_abandon_uncommitted_reverse_candidate "$original_order" candidate-source-proof-failed; return 1; }
    verify_pending_candidate_ownership_unchanged || { r15_abandon_uncommitted_reverse_candidate "$original_order" candidate-target-ownership-failed; return 1; }
    validate_pending_target_deep || { r15_abandon_uncommitted_reverse_candidate "$original_order" candidate-target-deep-failed; return 1; }
    leap16_stage_diagnostic candidate-pass
    if [[ -n ${LIMINE_DIAGNOSTIC_DIR:-} ]]; then
        GRUB_DIAGNOSTIC_DIR=$LIMINE_DIAGNOSTIC_DIR
        r21_pending_set_key diagnostic_path "$GRUB_DIAGNOSTIC_DIR" >/dev/null 2>&1 || true
        PENDING_DIAGNOSTIC_PATH=$GRUB_DIAGNOSTIC_DIR
        printf 'Diagnostic snapshot: %s\n' "$GRUB_DIAGNOSTIC_DIR"
    fi

    printf '\nCANDIDATE-READY Limine -> GRUB2 return staged.\n'
    printf '  Source:    Limine Boot%s (still persistent first)\n' "$old_id"
    printf '  Target:    native openSUSE GRUB2 Boot%s (retained, not reinstalled)\n' "$target_id"
    printf '  BootOrder: %s\n' "$(leap16_current_boot_order)"
    printf '  BootNext:  unset\n'
    r15_arm_reverse_automatically
}

r15_strict_resume_bundle_ready() {
    local bundle unit_exec
    bundle=$(r13_resume_pointer_bundle 2>/dev/null || true)
    [[ -n $bundle ]] || return 1
    sudo -n test -d "$bundle" 2>/dev/null || return 1
    sudo -n test -f "$bundle/$R22_BUNDLE_MARKER" 2>/dev/null || return 1
    sudo -n test -f "$bundle/state/pending-migration.tsv" 2>/dev/null || return 1
    [[ -f $R22_SERVICE_PATH ]] || return 1
    have systemctl && systemctl is-enabled --quiet "$R22_SERVICE_NAME" 2>/dev/null || return 1
    grep -Fq -- "ExecStart=/usr/bin/bash $bundle/tool/bootloader-switcher.sh --resume-transaction-root" "$R22_SERVICE_PATH" 2>/dev/null || return 1
    return 0
}

r15_prompt_reboot_reverse() {
    local answer
    printf '\nThe one-time native GRUB2 return is armed and the root-owned resume service is fully verified.\n'
    printf 'If runtime proof passes, r15 will promote GRUB2, retire only the exact Limine source state, and preserve the shim fallback.\n'
    read -r -p 'Reboot now? [y/N]: ' answer
    case "$answer" in
        y|Y|yes|YES) printf 'Rebooting now; no firmware-menu selection is required.\n'; sudo systemctl reboot ;;
        *) printf 'Reboot deferred. BootNext and the verified temporary resume service remain armed for the next normal reboot.\n' ;;
    esac
}

r15_arm_reverse_automatically() {
    validate_pending_compatibility || { fail "Pending reverse migration is incompatible: $PENDING_REASON"; return 1; }
    leap16_reverse_pending || { fail 'r15 reverse arming received a non-reverse transaction'; return 1; }
    [[ $PENDING_PHASE == candidate-ready ]] || { fail 'Reverse automatic arming requires candidate-ready state'; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == ${PENDING_OLD_BOOT_ID^^} ]] || { fail 'Reverse arming requires the recorded Limine source session'; return 1; }
    leap16_require_sudo_session || return 1
    leap16_validate_pending_firmware_order 'Reverse arm' || return 1
    verify_pending_source_recovery_unchanged || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext is already owned by another request'; return 1; }

    sudo efibootmgr -n "$PENDING_TARGET_BOOT_ID" >/dev/null || return 1
    [[ $(pending_bootnext_id) == "$PENDING_TARGET_BOOT_ID" ]] || { sudo efibootmgr -N >/dev/null 2>&1 || true; fail 'Reverse BootNext verification failed'; return 1; }
    pending_set_phase boot-armed || { sudo efibootmgr -N >/dev/null 2>&1 || true; fail 'Could not persist reverse boot-armed phase'; return 1; }
    PENDING_PHASE=boot-armed

    if ! r22_prepare_resume_bundle; then
        fail 'Could not prepare root-owned reverse resume bundle; clearing transaction BootNext for safety'
        sudo efibootmgr -N >/dev/null 2>&1 || true
        pending_set_phase candidate-ready >/dev/null 2>&1 || true
        PENDING_PHASE=candidate-ready
        r22_disarm_user_resume_bundle || true
        return 1
    fi
    if ! r15_strict_resume_bundle_ready; then
        fail 'Automatic reverse resume did not pass its own pre-reboot installation proof; refusing reboot'
        sudo efibootmgr -N >/dev/null 2>&1 || true
        pending_set_phase candidate-ready >/dev/null 2>&1 || true
        PENDING_PHASE=candidate-ready
        r22_disarm_user_resume_bundle || true
        return 1
    fi
    leap16_stage_diagnostic automation-ready
    ok "Armed BootNext=Boot$PENDING_TARGET_BOOT_ID while Limine remains persistent first"
    ok "Verified root-owned resume bundle, exact ExecStart and enabled $R22_SERVICE_NAME"
    r15_prompt_reboot_reverse
}

run_live_operation() {
    local target=${1:-} current
    detect_bootloader
    current=$BOOTLOADER
    if [[ $current:$target == limine:grub ]]; then
        run_switch_preflight "$target" || return 1
        find_nvram_entry_for_target grub || return 1
        leap16_reverse_plan
        printf '\nNo GRUB reinstall is performed: r15 adopts the already-proven native openSUSE GRUB2/shim recovery chain.\n'
        if ! confirm_operation "$current" "$target"; then
            printf '\nOperation cancelled. No boot state was modified.\n'
            return 0
        fi
        printf '\nRe-running the complete reverse preflight at the write boundary...\n'
        run_switch_preflight "$target" || { printf '\nWrite-boundary revalidation failed. Nothing was modified.\n'; return 1; }
        leap16_execute_limine_to_retained_grub
    else
        run_live_operation_pre_r15 "$@"
    fi
}

leap16_verify_source_limine_after_promotion() {
    local h fallback_hash efi_dir splash expected
    nvram_id_matches_path "$PENDING_OLD_BOOT_ID" "$PENDING_OLD_BOOT_EFI_PATH" || { fail 'Source Limine NVRAM identity changed after GRUB2 promotion'; return 1; }
    h=$(leap16_hash_file_privileged "$PENDING_SOURCE_LIMINE_EFI_RESOLVED"); [[ $h == "$PENDING_SOURCE_LIMINE_EFI_HASH" ]] || { fail 'Source Limine EFI changed after GRUB2 promotion'; return 1; }
    h=$(leap16_hash_file_privileged "$PENDING_SOURCE_LIMINE_CONF_PATH"); [[ $h == "$PENDING_SOURCE_LIMINE_CONF_HASH" ]] || { fail 'Source limine.conf changed after GRUB2 promotion'; return 1; }
    h=$(leap16_hash_file_privileged /etc/default/limine); [[ $h == "$PENDING_SOURCE_LIMINE_DEFAULT_HASH" ]] || { fail 'Source /etc/default/limine changed after GRUB2 promotion'; return 1; }
    h=$(hash_directory_tree_privileged "$PENDING_SOURCE_LIMINE_MANAGED_DIR" 2>/dev/null || true); [[ $h == "$PENDING_SOURCE_LIMINE_MANAGED_HASH" ]] || { fail 'Source Limine managed kernel tree changed after GRUB2 promotion'; return 1; }
    efi_dir=$(dirname -- "$PENDING_SOURCE_LIMINE_EFI_RESOLVED")
    pending_verify_tree_manifest "$efi_dir" "$PENDING_TRANSACTION_SNAPSHOT_DIR/source-limine-efi-dir.tsv" || { fail 'Source EFI/LIMINE namespace changed after GRUB2 promotion'; return 1; }
    pending_verify_tree_manifest "$PENDING_SOURCE_LIMINE_MANAGED_DIR" "$PENDING_TRANSACTION_SNAPSHOT_DIR/source-limine-managed-dir.tsv" || { fail 'Source Limine managed tree changed after GRUB2 promotion'; return 1; }
    splash="$ESP_MOUNT/limine-splash.png"
    if [[ -s $PENDING_TRANSACTION_SNAPSHOT_DIR/source-limine-splash.sha256 ]]; then
        expected=$(cat "$PENDING_TRANSACTION_SNAPSHOT_DIR/source-limine-splash.sha256")
        h=$(leap16_hash_file_privileged "$splash")
        [[ $h == "$expected" ]] || { fail 'Source Limine splash changed after GRUB2 promotion'; return 1; }
    else
        (sudo -n test ! -e "$splash" 2>/dev/null && [[ ! -e $splash ]]) || { fail 'A source Limine splash appeared after the snapshot'; return 1; }
    fi
    fallback_hash=$(leap16_hash_file_privileged "$PENDING_OLD_FALLBACK_PATH")
    [[ $fallback_hash == "$PENDING_OLD_FALLBACK_HASH" ]] || { fail 'Shared EFI fallback changed after GRUB2 promotion'; return 1; }
    validate_limine_boot_chain migration || { fail 'Source Limine deep validation failed before retirement'; return 1; }
    ok 'Source Limine ownership remains exact after GRUB2 promotion and is eligible for retirement'
}

r15_validate_grub_target_runtime() {
    validate_pending_compatibility || { fail "Pending reverse migration is incompatible: $PENDING_REASON"; return 1; }
    leap16_reverse_pending || return 1
    [[ $PENDING_PHASE == boot-armed || $PENDING_PHASE == runtime-validated ]] || { fail "Runtime proof is not allowed from phase $PENDING_PHASE"; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail "Runtime proof requires retained GRUB2 Boot$PENDING_TARGET_BOOT_ID as BootCurrent"; return 1; }
    leap16_require_sudo_session || return 1
    leap16_stage_diagnostic runtime-arrival
    run_validation preflight || return 1
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext was not consumed/cleared by firmware'; return 1; }
    pending_validate_running_kernel || return 1
    leap16_validate_pending_firmware_order 'Reverse runtime' || return 1
    pending_validate_runtime_cmdline_against_source || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1
    verify_pending_source_recovery_unchanged || return 1
    pending_set_phase runtime-validated || return 1
    PENDING_PHASE=runtime-validated
    leap16_stage_diagnostic runtime-pass
    printf '\nRUNTIME-VALIDATED Limine -> GRUB2 one-shot boot succeeded.\n'
    printf '  BootCurrent proof: Boot%s -> %s\n' "$PENDING_TARGET_BOOT_ID" "$PENDING_TARGET_EFI_PATH"
    printf '  BootNext: clear\n'
    printf '  Persistent order remains Limine-first until promotion.\n'
}

validate_pending_target_runtime() {
    if leap16_reverse_pending; then
        r15_validate_grub_target_runtime
    else
        validate_pending_target_runtime_pre_r15 "$@"
    fi
}

r15_recover_source_first_after_failed_reverse_promotion() {
    local source=${PENDING_OLD_BOOT_ID^^} target=${PENDING_TARGET_BOOT_ID^^} order id joined
    local -a out=() ids=()
    boot_id_exists "$source" || return 1
    order=$(leap16_current_boot_order 2>/dev/null || true)
    out+=("$source")
    IFS=',' read -ra ids <<<"$order"
    for id in "${ids[@]}"; do
        id=${id^^}; [[ -n $id && $id != "$source" ]] || continue; out+=("$id")
    done
    joined=$(IFS=,; printf '%s' "${out[*]}")
    sudo efibootmgr -o "$joined" >/dev/null || return 1
    [[ $(leap16_current_boot_order | cut -d, -f1) == "$source" ]]
}

r15_retire_proven_limine_source() {
    local source=${PENDING_OLD_BOOT_ID^^} h efi_dir splash order first
    leap16_verify_source_limine_after_promotion || return 1

    if boot_id_exists "$source"; then
        nvram_id_matches_path "$source" "$PENDING_OLD_BOOT_EFI_PATH" || { fail 'Source Limine Boot#### path changed at retirement boundary'; return 1; }
        sudo efibootmgr -b "$source" -B >/dev/null || return 1
        ok "Retired source Limine NVRAM entry Boot$source"
    fi

    efi_dir=$(dirname -- "$PENDING_SOURCE_LIMINE_EFI_RESOLVED")
    pending_verify_tree_manifest "$efi_dir" "$PENDING_TRANSACTION_SNAPSHOT_DIR/source-limine-efi-dir.tsv" || { fail 'EFI/LIMINE changed at retirement boundary'; return 1; }
    sudo rm -rf -- "$efi_dir" || return 1
    ok 'Removed ownership-proven source EFI/LIMINE namespace'

    h=$(leap16_hash_file_privileged "$PENDING_SOURCE_LIMINE_CONF_PATH")
    [[ $h == "$PENDING_SOURCE_LIMINE_CONF_HASH" ]] || { fail 'limine.conf changed at retirement boundary'; return 1; }
    sudo rm -f -- "$PENDING_SOURCE_LIMINE_CONF_PATH" || return 1
    ok 'Removed ownership-proven source limine.conf'

    splash="$ESP_MOUNT/limine-splash.png"
    if [[ -s $PENDING_TRANSACTION_SNAPSHOT_DIR/source-limine-splash.sha256 ]]; then
        h=$(leap16_hash_file_privileged "$splash")
        [[ $h == $(cat "$PENDING_TRANSACTION_SNAPSHOT_DIR/source-limine-splash.sha256") ]] || { fail 'Limine splash changed at retirement boundary'; return 1; }
        sudo rm -f -- "$splash" || return 1
        ok 'Removed ownership-proven Limine splash'
    fi

    h=$(leap16_hash_file_privileged /etc/default/limine)
    [[ $h == "$PENDING_SOURCE_LIMINE_DEFAULT_HASH" ]] || { fail '/etc/default/limine changed at retirement boundary'; return 1; }
    sudo rm -f -- /etc/default/limine || return 1
    ok 'Removed ownership-proven /etc/default/limine'

    pending_verify_tree_manifest "$PENDING_SOURCE_LIMINE_MANAGED_DIR" "$PENDING_TRANSACTION_SNAPSHOT_DIR/source-limine-managed-dir.tsv" || { fail 'Limine managed tree changed at retirement boundary'; return 1; }
    sudo rm -rf -- "$PENDING_SOURCE_LIMINE_MANAGED_DIR" || return 1
    ok 'Removed ownership-proven Limine managed kernel directory'

    # Never touch the shared fallback: on Leap it is the retained shim recovery.
    [[ $(leap16_hash_file_privileged "$PENDING_OLD_FALLBACK_PATH") == "$PENDING_OLD_FALLBACK_HASH" ]] || { fail 'Shared EFI fallback changed during Limine retirement'; return 1; }
    ok 'Preserved shared openSUSE EFI/BOOT/BOOTX64.EFI fallback byte-for-byte'

    order=$(leap16_current_boot_order)
    first=${order%%,*}
    [[ ${first^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail "GRUB2 target is not first after Limine retirement ($order)"; return 1; }
    ! boot_id_exists "$source" || { fail "Source Limine Boot$source still exists after retirement"; return 1; }
}

r15_promote_and_finalize_grub() {
    validate_pending_compatibility || { fail "Pending reverse migration is incompatible: $PENDING_REASON"; return 1; }
    leap16_reverse_pending || return 1
    [[ $PENDING_PHASE == runtime-validated ]] || { fail 'GRUB2 promotion requires runtime-validated state'; return 1; }
    detect_bootloader
    [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail 'GRUB2 promotion is allowed only from the exact runtime-proven target session'; return 1; }
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext is set; refusing persistent promotion'; return 1; }
    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1
    verify_pending_source_recovery_unchanged || return 1
    leap16_validate_pending_firmware_order 'Pre-promotion reverse' || return 1

    local promoted
    promoted=$(r13_promoted_order_from_current) || return 1
    sudo efibootmgr -o "$promoted" >/dev/null || return 1
    if ! leap16_validate_promoted_firmware_order 'GRUB2 promotion'; then
        fail 'Post-promotion firmware gate failed; attempting to restore Limine source first'
        r15_recover_source_first_after_failed_reverse_promotion || warn 'Could not automatically restore source-first order'
        return 1
    fi
    detect_bootloader
    [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail 'BootCurrent identity changed after GRUB2 promotion'; return 1; }
    validate_grub_boot_chain current || { r15_recover_source_first_after_failed_reverse_promotion || true; return 1; }
    verify_pending_candidate_ownership_unchanged || { r15_recover_source_first_after_failed_reverse_promotion || true; return 1; }
    leap16_verify_source_limine_after_promotion || { r15_recover_source_first_after_failed_reverse_promotion || true; return 1; }
    leap16_stage_diagnostic promotion-pass

    r15_retire_proven_limine_source || return 1
    detect_bootloader
    [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail 'Final GRUB2 identity changed after Limine retirement'; return 1; }
    validate_grub_boot_chain current || return 1
    validate_cachyos_grub_theme || return 1
    validate_target_state grub || return 1
    [[ -z $(pending_bootnext_id) ]] || { fail 'BootNext unexpectedly exists after finalization'; return 1; }
    leap16_stage_diagnostic finalization-pass
    printf '\nFINALIZED Limine -> GRUB2 successfully.\n'
    printf '  GRUB2 Boot%s is persistent first.\n' "$PENDING_TARGET_BOOT_ID"
    printf '  Source Limine Boot%s and ownership-proven Limine files are retired.\n' "$PENDING_OLD_BOOT_ID"
    printf '  openSUSE shim fallback is preserved.\n'
    return 0
}

r15_rollback_reverse_candidate() {
    validate_pending_compatibility || return 1
    leap16_reverse_pending || return 1
    detect_bootloader
    [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == ${PENDING_OLD_BOOT_ID^^} ]] || { fail 'Reverse rollback is allowed only from the recorded Limine source session'; return 1; }
    leap16_require_sudo_session || return 1
    verify_pending_source_recovery_unchanged || return 1
    verify_pending_candidate_ownership_unchanged || return 1
    validate_pending_target_deep || return 1
    local next answer order id joined
    local -a out=() orig=() current=()
    next=$(pending_bootnext_id)
    [[ -z $next || ${next^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || { fail "Unrelated BootNext=Boot$next exists; refusing reverse rollback"; return 1; }
    printf '\nReverse rollback keeps the pre-existing native GRUB2 recovery chain and abandons only this transaction.\n'
    read -r -p 'Type ROLLBACK to abandon the Limine -> GRUB2 return transaction: ' answer
    [[ $answer == ROLLBACK ]] || { printf 'Rollback cancelled.\n'; return 0; }
    leap16_stage_diagnostic rollback-before-cleanup
    [[ -n $next ]] && sudo efibootmgr -N >/dev/null 2>&1 || true
    r22_disarm_user_resume_bundle || true

    # Restore the recorded relative order only for IDs that currently exist;
    # never resurrect firmware-garbage-collected BBS identifiers.
    IFS=',' read -ra orig <<<"$PENDING_ORIGINAL_BOOT_ORDER"
    for id in "${orig[@]}"; do id=${id^^}; [[ -n $id ]] && boot_id_exists "$id" && out+=("$id"); done
    IFS=',' read -ra current <<<"$(leap16_current_boot_order)"
    for id in "${current[@]}"; do
        id=${id^^}; [[ -n $id ]] || continue
        local seen=0 x
        for x in "${out[@]}"; do [[ $x == "$id" ]] && { seen=1; break; }; done
        ((seen)) || out+=("$id")
    done
    joined=$(IFS=,; printf '%s' "${out[*]}")
    sudo efibootmgr -o "$joined" >/dev/null || return 1
    [[ $(leap16_current_boot_order | cut -d, -f1) == ${PENDING_OLD_BOOT_ID^^} ]] || { fail 'Limine source was not restored first during reverse rollback'; return 1; }

    rm -f -- "$PENDING_STATE_FILE"
    leap16_stage_diagnostic rollback-pass
    remove_pending_transaction_snapshot || warn 'Could not remove private transaction snapshot directory'
    pending_reset
    ok 'ROLLBACK-COMPLETE. Limine remains authoritative; retained native GRUB2 recovery was left untouched.'
}

rollback_pending_candidate() {
    if leap16_reverse_pending; then
        r15_rollback_reverse_candidate
    else
        rollback_pending_candidate_pre_r15 "$@"
    fi
}

pending_banner() {
    if pending_exists && validate_pending_compatibility >/dev/null 2>&1 && leap16_reverse_pending; then
        detect_bootloader
        printf 'Pending/staged migration: Limine -> GRUB2  [%s]' "$PENDING_PHASE"
        case "$PENDING_PHASE:$BOOTLOADER" in
            candidate-ready:limine) printf '  [RETAINED GRUB2 TARGET PARKED]\n' ;;
            boot-armed:limine) printf '  [GRUB2 BootNext + AUTO-RESUME ARMED]\n' ;;
            boot-armed:grub) printf '  [GRUB2 ACTIVE; AUTO-RESUME SHOULD VALIDATE]\n' ;;
            runtime-validated:grub) printf '  [GRUB2 RUNTIME PROVEN; FINALIZATION ELIGIBLE]\n' ;;
            runtime-validated:limine) printf '  [RUNTIME PROOF RECORDED; LIMINE SOURCE ACTIVE]\n' ;;
            *) printf '  [CURRENT: %s]\n' "$(bootloader_display_name "$BOOTLOADER")" ;;
        esac
        return 0
    fi
    pending_banner_pre_r15 "$@"
}

manage_pending_migration() {
    pending_exists || { printf '\nNo pending/staged migration exists.\n'; return 0; }
    validate_pending_compatibility || { printf '\nPending migration state is invalid/incompatible: %s\n' "$PENDING_REASON"; return 1; }
    if ! leap16_reverse_pending; then
        manage_pending_migration_pre_r15 "$@"
        return $?
    fi
    detect_bootloader
    show_pending_details
    local choice next
    if [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == ${PENDING_OLD_BOOT_ID^^} ]]; then
        case "$PENDING_PHASE" in
            candidate-ready)
                printf '\nLimine source is active; native GRUB2 target is parked.\n[1] Revalidate source + retained target\n[2] Arm GRUB2 + install automatic resume\n[3] Roll back transaction\n[4] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in 1) verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep ;; 2) r15_arm_reverse_automatically ;; 3) r15_rollback_reverse_candidate ;; 4|'') return 0 ;; *) return 1 ;; esac
                ;;
            boot-armed)
                next=$(pending_bootnext_id)
                if [[ ${next^^} == ${PENDING_TARGET_BOOT_ID^^} ]]; then
                    printf '\nOne-time native GRUB2 BootNext is armed.\n[1] Re-check integrity\n[2] Re-verify automatic resume and reboot prompt\n[3] Cancel BootNext back to candidate-ready\n[4] Roll back transaction\n[5] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in
                        1) verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged && validate_pending_target_deep ;;
                        2) r15_strict_resume_bundle_ready && r15_prompt_reboot_reverse ;;
                        3) sudo efibootmgr -N >/dev/null && pending_set_phase candidate-ready && r22_disarm_user_resume_bundle ;;
                        4) r15_rollback_reverse_candidate ;;
                        5|'') return 0 ;;
                        *) return 1 ;;
                    esac
                elif [[ -z $next ]]; then
                    printf '\nBootNext was consumed/cleared without accepted GRUB2 runtime proof.\n[1] Return to candidate-ready\n[2] Roll back transaction\n[3] Back\n\n'
                    read -r -p 'Select an option: ' choice
                    case "$choice" in 1) pending_set_phase candidate-ready; r22_disarm_user_resume_bundle ;; 2) r15_rollback_reverse_candidate ;; 3|'') return 0 ;; *) return 1 ;; esac
                else
                    fail "Unrelated BootNext=Boot$next exists"; return 1
                fi
                ;;
            runtime-validated)
                printf '\nGRUB2 runtime proof exists, but Limine is active again. Re-arm the proven target for finalization or roll back.\n[1] Re-arm GRUB2 + automatic resume\n[2] Re-check ownership\n[3] Roll back transaction\n[4] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in 1) pending_set_phase candidate-ready && load_pending_state && r15_arm_reverse_automatically ;; 2) verify_pending_source_recovery_unchanged && verify_pending_candidate_ownership_unchanged ;; 3) r15_rollback_reverse_candidate ;; 4|'') return 0 ;; *) return 1 ;; esac
                ;;
        esac
    elif [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]]; then
        case "$PENDING_PHASE" in
            boot-armed)
                printf '\nThe one-time native GRUB2 target is running. If automatic resume did not run, manual recovery is available.\n[1] Run exact runtime validation now\n[2] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in 1) r15_validate_grub_target_runtime ;; 2|'') return 0 ;; *) return 1 ;; esac
                ;;
            runtime-validated)
                printf '\nThis exact native GRUB2 session has runtime proof.\n[1] Re-run runtime validation\n[2] Promote GRUB2 and retire exact Limine source now\n[3] Back\n\n'
                read -r -p 'Select an option: ' choice
                case "$choice" in 1) r15_validate_grub_target_runtime ;; 2) r15_manual_finalize_grub ;; 3|'') return 0 ;; *) return 1 ;; esac
                ;;
            *) fail 'Current GRUB2 target session is not in a runtime-validatable phase'; return 1 ;;
        esac
    else
        fail 'Current bootloader is neither the exact recorded Limine source nor retained GRUB2 target'
        return 1
    fi
}


r15_restore_existing_original_order() {
    local original=${1:-${PENDING_ORIGINAL_BOOT_ORDER:-}} id joined
    local -a out=() ids=() current=()
    [[ -n $original ]] || return 1
    IFS=',' read -ra ids <<<"$original"
    for id in "${ids[@]}"; do id=${id^^}; [[ -n $id ]] && boot_id_exists "$id" && out+=("$id"); done
    IFS=',' read -ra current <<<"$(leap16_current_boot_order 2>/dev/null || true)"
    for id in "${current[@]}"; do
        id=${id^^}; [[ -n $id ]] || continue
        local seen=0 x
        for x in "${out[@]}"; do [[ $x == "$id" ]] && { seen=1; break; }; done
        ((seen)) || out+=("$id")
    done
    ((${#out[@]})) || return 1
    joined=$(IFS=,; printf '%s' "${out[*]}")
    sudo efibootmgr -o "$joined" >/dev/null
}

r15_abandon_uncommitted_reverse_candidate() {
    local original=$1 phase=${2:-reverse-stage-failed} next
    leap16_stage_diagnostic "$phase"
    next=$(pending_bootnext_id 2>/dev/null || true)
    if [[ -n $next && ${next^^} == ${PENDING_TARGET_BOOT_ID:-${TARGET_NVRAM_ID:-}} ]]; then sudo efibootmgr -N >/dev/null 2>&1 || true; fi
    r22_disarm_user_resume_bundle || true
    r15_restore_existing_original_order "$original" || true
    rm -f -- "$PENDING_STATE_FILE" 2>/dev/null || true
    if [[ -n ${TRANSACTION_SNAPSHOT_DIR:-} && -d $TRANSACTION_SNAPSHOT_DIR ]]; then rm -rf -- "$TRANSACTION_SNAPSHOT_DIR" 2>/dev/null || true; fi
    pending_reset 2>/dev/null || true
}

r15_manual_finalize_grub() {
    local source_id target_id snapshot
    validate_pending_compatibility || return 1
    source_id=$PENDING_OLD_BOOT_ID target_id=$PENDING_TARGET_BOOT_ID snapshot=$PENDING_TRANSACTION_SNAPSHOT_DIR
    r15_promote_and_finalize_grub || return 1
    rm -f -- "$PENDING_STATE_FILE"
    if [[ -n $snapshot ]]; then PENDING_TRANSACTION_SNAPSHOT_DIR=$snapshot; remove_pending_transaction_snapshot || warn 'Could not remove reverse transaction snapshot'; fi
    r22_disarm_user_resume_bundle || true
    pending_reset
    printf 'Reverse transaction state cleared. GRUB2 Boot%s is authoritative; Limine Boot%s is retired.\n' "$target_id" "$source_id"
}

r22_write_systemd_unit() {
    local out=$1 bundle=$2 state_dir=$3
    cat >"$out" <<EOF_UNIT
[Unit]
Description=openSUSE Bootloader Switcher automatic transaction resume
After=local-fs.target
ConditionPathExists=$state_dir/pending-migration.tsv

[Service]
Type=oneshot
Environment=BOOTLOADER_SWITCHER_STATE_DIR=$state_dir
Environment=R22_RESUME_BUNDLE=$bundle
Environment=HOME=$bundle/runtime-home
Environment=LEAP16_AUTO_RESUME=1
ExecStart=/usr/bin/bash $bundle/tool/bootloader-switcher.sh --resume-transaction-root
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF_UNIT
}

r15_resume_reverse_root() {
    r22_root_bundle_preflight || return 1
    local bundle=$R22_RESUME_BUNDLE conf="$R22_RESUME_BUNDLE/resume.conf" detail
    mkdir -p -- "$bundle/diagnostics" || return 1
    LEAP16_DIAGNOSTIC_ROOT="$bundle/diagnostics"
    LEAP16_AUTO_RESUME=1
    export LEAP16_DIAGNOSTIC_ROOT LEAP16_AUTO_RESUME
    exec > >(tee -a "$bundle/automatic-resume.log") 2>&1
    printf 'openSUSE Bootloader Switcher leap16-r15 automatic Limine -> GRUB2 resume\nBundle: %s\n' "$bundle"

    load_pending_state || { r22_write_user_result "$conf" failed "Invalid root-owned reverse pending state: $PENDING_REASON" || true; r22_remove_resume_service_files; return 1; }
    validate_pending_compatibility || { r22_write_user_result "$conf" failed "Reverse resume transaction is incompatible: $PENDING_REASON" || true; r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true; r22_remove_resume_service_files; return 1; }
    detect_bootloader
    if [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == ${PENDING_OLD_BOOT_ID^^} ]]; then
        printf 'Automatic reverse resume: firmware returned to Limine source; no target proof/finalization allowed.\n'
        r22_resume_source_fallback "$conf" || return 1
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" safe-fallback || true
        return 0
    fi
    [[ $BOOTLOADER == grub && ${BOOT_CURRENT^^} == ${PENDING_TARGET_BOOT_ID^^} ]] || {
        leap16_capture_diagnostics auto-resume-unexpected-bootcurrent >/dev/null 2>&1 || true
        r22_write_user_result "$conf" failed 'Reverse automatic resume saw an unexpected BootCurrent; no promotion/retirement occurred.' || true
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
        r22_remove_resume_service_files
        return 1
    }

    case "$PENDING_PHASE" in
        boot-armed)
            r15_validate_grub_target_runtime || {
                r22_write_user_result "$conf" failed 'Native GRUB2 booted but reverse automatic runtime proof failed; no persistent promotion/retirement occurred.' || true
                leap16_capture_diagnostics auto-resume-runtime-failed >/dev/null 2>&1 || true
                r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
                r22_remove_resume_service_files
                return 1
            }
            PENDING_PHASE=runtime-validated
            r22_sync_user_phase_from_root "$conf" runtime-validated || true
            ;;
        runtime-validated) printf 'Automatic reverse resume: runtime proof already persisted; continuing to finalization.\n' ;;
        *) r22_write_user_result "$conf" failed "Unexpected reverse automatic-resume phase: $PENDING_PHASE" || true; r22_remove_resume_service_files; return 1 ;;
    esac

    if ! r15_promote_and_finalize_grub; then
        r22_write_user_result "$conf" failed 'GRUB2 runtime proof passed, but safe reverse promotion/finalization failed. Ownership gates prevented unproven source cleanup.' || true
        leap16_capture_diagnostics auto-resume-finalization-failed >/dev/null 2>&1 || true
        r13_sync_root_diagnostics_to_user "$conf" "$bundle" failed || true
        r22_remove_resume_service_files
        return 1
    fi

    leap16_capture_diagnostics auto-resume-pass >/dev/null 2>&1 || true
    r13_sync_root_diagnostics_to_user "$conf" "$bundle" success || true
    detail="Limine -> GRUB2 automated runtime proof and finalization succeeded. Native openSUSE GRUB2 Boot$PENDING_TARGET_BOOT_ID is first; source Limine Boot$PENDING_OLD_BOOT_ID and ownership-proven Limine files were retired; shim fallback was preserved."
    remove_pending_transaction_snapshot || true
    rm -f -- "$PENDING_STATE_FILE"
    r22_cleanup_user_shadow_after_success "$conf"
    r22_write_user_result "$conf" success "$detail" || true
    r22_remove_resume_service_files
    rm -rf -- "$bundle" 2>/dev/null || true
    return 0
}

r22_resume_transaction_root() {
    # Direction dispatch must happen before the r13 forward root function runs.
    # In a root-owned bundle PENDING_STATE_FILE already resolves inside the
    # copied state directory through BOOTLOADER_SWITCHER_STATE_DIR.
    local src="" tgt=""
    if [[ -f ${PENDING_STATE_FILE:-/nonexistent} ]]; then
        src=$(awk -F'\t' '$1=="source"{print $2;exit}' "$PENDING_STATE_FILE" 2>/dev/null || true)
        tgt=$(awk -F'\t' '$1=="target"{print $2;exit}' "$PENDING_STATE_FILE" 2>/dev/null || true)
    fi
    if [[ $src:$tgt == limine:grub ]]; then
        r15_resume_reverse_root
    else
        r22_resume_transaction_root_pre_r15 "$@"
    fi
}

# r19: Leap's retained native GRUB target is adopted, not transaction-created.
# On openSUSE systems where /boot is part of /, versioned /boot/vmlinuz-* files
# may be symlinks into /usr/lib/modules/<kver>/vmlinuz.  The inherited r47
# format-4 artifact verifier intentionally realpath-confines transaction-created
# GRUB artifacts to /boot; that policy produces a false ownership failure for
# these distro-owned shared symlinks even when their bytes are unchanged.
#
# Keep the inherited verifier untouched for every other direction.  For the
# Leap limine -> grub adoption only, require the recorded logical path to remain
# lexically inside /boot, require every artifact to be marked shared, and prove
# its exact SHA256.  The /boot/grub2 tree, EFI/OPENSUSE tree, openSUSE theme,
# NVRAM path/ESP binding, grub.cfg, /etc/default/grub and shim are still checked
# byte-for-byte by the surrounding reverse ownership verifier.

leap16_path_lexically_under() {
    local child=$1 parent=$2
    [[ -n $child && -n $parent ]] || return 1
    [[ $child == /* && $parent == /* ]] || return 1
    [[ $child != *$'\n'* && $child != *$'\r'* && $child != *$'\t'* ]] || return 1
    [[ $parent != *$'\n'* && $parent != *$'\r'* && $parent != *$'\t'* ]] || return 1
    # Reject traversal spellings rather than canonicalizing through symlinks.
    [[ $child != *'/../'* && $child != */.. && $child != *'/./'* && $child != */. ]] || return 1
    [[ $child == "$parent" || $child == "$parent/"* ]]
}

leap16_verify_retained_grub_artifact_manifest() {
    local manifest=$1 expected_root=${2:-/boot}
    local ownership hash path actual count=0
    [[ -s $manifest ]] || { fail 'Retained GRUB2 shared-artifact manifest is missing/empty'; return 1; }

    while IFS=$'\t' read -r ownership hash path; do
        [[ $ownership == shared ]] || {
            fail "Retained native GRUB2 artifact is not marked shared: ${path:-unknown}"
            return 1
        }
        pending_hash_is_sha256 "$hash" || {
            fail "Retained GRUB2 artifact has an invalid recorded SHA256: ${path:-unknown}"
            return 1
        }
        leap16_path_lexically_under "$path" "$expected_root" || {
            fail "Retained GRUB2 artifact logical path escaped $expected_root: $path"
            return 1
        }
        actual=$(sudo -n sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || sha256sum -- "$path" 2>/dev/null | awk '{print $1}' || true)
        [[ -n $actual && $actual == "$hash" ]] || {
            fail "Retained GRUB2 shared artifact changed: $path"
            return 1
        }
        count=$((count + 1))
    done <"$manifest"

    ((count > 0)) || { fail 'Retained GRUB2 shared-artifact manifest contains no artifacts'; return 1; }
    ok 'Retained openSUSE kernel/initrd logical boot artifacts still match their exact recorded hashes'
}

leap16_verify_reverse_candidate_ownership() {
    local current_hash theme_manifest

    [[ -f $PENDING_STATE_FILE ]] || { fail 'Reverse pending-state file disappeared'; return 1; }
    nvram_id_matches_path "$PENDING_TARGET_BOOT_ID" "$PENDING_TARGET_EFI_PATH" || {
        fail 'Retained GRUB2 target NVRAM path changed since candidate adoption'
        return 1
    }
    leap16_nvram_entry_matches_current_esp "$PENDING_TARGET_BOOT_ID" || {
        fail 'Retained GRUB2 target NVRAM entry is no longer bound to the detected ESP'
        return 1
    }

    current_hash=$(leap16_hash_file_privileged "$PENDING_TARGET_EFI_RESOLVED")
    [[ -n $current_hash && $current_hash == "$PENDING_TARGET_EFI_HASH" ]] || {
        fail 'Retained openSUSE shim changed since candidate adoption'
        return 1
    }
    current_hash=$(leap16_hash_file_privileged "$PENDING_GRUB_CFG_PATH")
    [[ -n $current_hash && $current_hash == "$PENDING_GRUB_CFG_HASH" ]] || {
        fail 'Retained /boot/grub2/grub.cfg changed since candidate adoption'
        return 1
    }
    current_hash=$(leap16_hash_file_privileged /etc/default/grub)
    [[ -n $current_hash && $current_hash == "$PENDING_GRUB_DEFAULT_HASH" ]] || {
        fail 'Retained /etc/default/grub changed since candidate adoption'
        return 1
    }

    leap16_verify_retained_grub_artifact_manifest "$PENDING_GRUB_ARTIFACT_MANIFEST" /boot || return 1
    pending_verify_tree_manifest "$PENDING_GRUB_DIR" "$PENDING_GRUB_DIR_MANIFEST" || {
        fail 'Retained /boot/grub2 tree differs from the exact candidate manifest'
        return 1
    }
    pending_verify_tree_manifest "$PENDING_GRUB_EFI_DIR" "$PENDING_GRUB_EFI_DIR_MANIFEST" || {
        fail 'Retained openSUSE GRUB2 EFI namespace differs from the exact candidate manifest'
        return 1
    }

    if r21_theme_required; then
        theme_manifest=$(r21_theme_manifest_path)
        pending_verify_tree_manifest "$R21_GRUB_THEME_DIR" "$theme_manifest" || {
            fail 'Retained openSUSE GRUB2 theme differs from the exact candidate manifest'
            return 1
        }
    fi

    ok 'Leap retained-GRUB2 candidate ownership matches the adopted native target state'
    return 0
}

# Direction-selective override loaded after the entire r47 lineage.  Do not
# weaken or duplicate the inherited verifier for any non-Leap-adopted target.
eval "$(declare -f verify_pending_candidate_ownership_unchanged | sed '1s/verify_pending_candidate_ownership_unchanged/verify_pending_candidate_ownership_unchanged_pre_r19/')"
verify_pending_candidate_ownership_unchanged() {
    if leap16_reverse_pending; then
        leap16_verify_reverse_candidate_ownership
    else
        verify_pending_candidate_ownership_unchanged_pre_r19 "$@"
    fi
}

# r20: diagnostics must describe the topology that is correct for the current
# reverse-transaction phase.  r19's write path is hardware-proven; this layer
# changes reporting only.  Before retirement, promoted reverse state is
# target-first/source-second.  After ownership-gated Limine retirement, the
# source Boot#### must be absent and the stable order is target-first followed
# by the remaining original non-BBS EFI-file entries.

leap16_assess_reverse_finalized_firmware_order() {
    LEAP16_ORDER_REASON=""
    LEAP16_ORDER_CURRENT_FULL=""
    LEAP16_ORDER_EXPECTED_STABLE=""
    LEAP16_ORDER_CURRENT_STABLE=""
    LEAP16_ORDER_BBS_ORIGINAL=""
    LEAP16_ORDER_BBS_CURRENT=""
    LEAP16_ORDER_BBS_MISSING=""
    LEAP16_ORDER_BBS_ADDED=""

    local source=${PENDING_OLD_BOOT_ID:-} target=${PENDING_TARGET_BOOT_ID:-} original=${PENDING_ORIGINAL_BOOT_ORDER:-}
    local baseline_path baseline current_dump current_order id line current_line base_path current_path
    local expected current_stable="" orig_bbs="" cur_bbs="" missing="" added=""
    local -a ids=()

    source=${source^^}
    target=${target^^}
    original=${original^^}
    [[ $source =~ ^[0-9A-F]{4}$ && $target =~ ^[0-9A-F]{4}$ && -n $original ]] || {
        LEAP16_ORDER_REASON='pending reverse transaction lacks source/target/original BootOrder identity'
        return 1
    }
    baseline_path=$(leap16_pending_firmware_baseline_path 2>/dev/null || true)
    [[ -n $baseline_path && -r $baseline_path ]] || {
        LEAP16_ORDER_REASON='firmware baseline is unavailable for reverse post-retirement validation'
        return 1
    }
    baseline=$(cat -- "$baseline_path" 2>/dev/null || true)
    current_dump=$(efibootmgr -v 2>/dev/null || true)
    current_order=$(awk -F': ' '/^BootOrder:/ {print toupper($2); exit}' <<<"$current_dump")
    [[ -n $current_order ]] || { LEAP16_ORDER_REASON='current BootOrder is unreadable'; return 1; }
    LEAP16_ORDER_CURRENT_FULL=$current_order

    leap16_boot_entry_is_active "$target" || { LEAP16_ORDER_REASON="target Boot$target is not active after reverse finalization"; return 1; }
    nvram_id_matches_path "$target" "$PENDING_TARGET_EFI_PATH" || { LEAP16_ORDER_REASON="target Boot$target changed EFI path after reverse finalization"; return 1; }
    leap16_nvram_entry_matches_current_esp "$target" || { LEAP16_ORDER_REASON="target Boot$target is no longer bound to the detected ESP after reverse finalization"; return 1; }
    ! boot_id_exists "$source" || { LEAP16_ORDER_REASON="retired source Limine Boot$source still exists after reverse finalization"; return 1; }

    expected=$target
    IFS=',' read -ra ids <<<"$original"
    for id in "${ids[@]}"; do
        id=${id^^}
        [[ -n $id && $id != "$source" && $id != "$target" ]] || continue
        line=$(leap16_line_for_id_in_dump "$baseline" "$id")
        [[ -n $line ]] || { LEAP16_ORDER_REASON="original Boot$id is missing from the firmware baseline"; return 1; }
        if leap16_line_is_bbs "$line"; then
            orig_bbs=$(leap16_csv_append "$orig_bbs" "$id")
        else
            base_path=$(efi_path_from_efibootmgr_line "$line" 2>/dev/null || true)
            [[ -n $base_path ]] || { LEAP16_ORDER_REASON="original non-BBS Boot$id has no EFI path"; return 1; }
            current_line=$(leap16_line_for_id_in_dump "$current_dump" "$id")
            [[ -n $current_line ]] || { LEAP16_ORDER_REASON="original EFI-file Boot$id disappeared after reverse finalization"; return 1; }
            current_path=$(efi_path_from_efibootmgr_line "$current_line" 2>/dev/null || true)
            [[ -n $current_path && $(normalize_efi_path "$current_path" | tr '[:upper:]' '[:lower:]') == $(normalize_efi_path "$base_path" | tr '[:upper:]' '[:lower:]') ]] || {
                LEAP16_ORDER_REASON="original EFI-file Boot$id changed path after reverse finalization"
                return 1
            }
            expected=$(leap16_csv_append "$expected" "$id")
        fi
    done
    LEAP16_ORDER_EXPECTED_STABLE=$expected
    LEAP16_ORDER_BBS_ORIGINAL=$orig_bbs

    IFS=',' read -ra ids <<<"$current_order"
    for id in "${ids[@]}"; do
        id=${id^^}
        [[ -n $id ]] || continue
        line=$(leap16_line_for_id_in_dump "$current_dump" "$id")
        [[ -n $line ]] || { LEAP16_ORDER_REASON="BootOrder references missing Boot$id"; return 1; }
        if leap16_line_is_bbs "$line"; then
            cur_bbs=$(leap16_csv_append "$cur_bbs" "$id")
        else
            current_stable=$(leap16_csv_append "$current_stable" "$id")
        fi
    done
    LEAP16_ORDER_CURRENT_STABLE=$current_stable
    LEAP16_ORDER_BBS_CURRENT=$cur_bbs

    IFS=',' read -ra ids <<<"$orig_bbs"
    for id in "${ids[@]}"; do
        [[ -n $id ]] || continue
        leap16_order_has_id "$current_order" "$id" || missing=$(leap16_csv_append "$missing" "$id")
    done
    IFS=',' read -ra ids <<<"$cur_bbs"
    for id in "${ids[@]}"; do
        [[ -n $id ]] || continue
        leap16_order_has_id "$orig_bbs" "$id" || added=$(leap16_csv_append "$added" "$id")
    done
    LEAP16_ORDER_BBS_MISSING=$missing
    LEAP16_ORDER_BBS_ADDED=$added

    [[ $current_stable == "$expected" ]] || {
        LEAP16_ORDER_REASON="finalized reverse stable EFI-file BootOrder drifted (expected $expected, got ${current_stable:-empty})"
        return 1
    }
    LEAP16_ORDER_REASON='native openSUSE GRUB2 target is first; retired Limine source is absent; other real EFI entries remain exact'
    return 0
}

leap16_emit_firmware_order_report() {
    local out=$1 rc=${2:-0}
    {
        printf 'assessment=%s\n' "$([[ $rc == 0 ]] && printf pass || printf fail)"
        printf 'reason=%s\n' "$LEAP16_ORDER_REASON"
        printf 'full_current_boot_order=%s\n' "$LEAP16_ORDER_CURRENT_FULL"
        printf 'stable_expected_boot_order=%s\n' "$LEAP16_ORDER_EXPECTED_STABLE"
        printf 'stable_current_boot_order=%s\n' "$LEAP16_ORDER_CURRENT_STABLE"
        printf 'original_bbs_ids=%s\n' "$LEAP16_ORDER_BBS_ORIGINAL"
        printf 'current_bbs_ids=%s\n' "$LEAP16_ORDER_BBS_CURRENT"
        printf 'missing_original_bbs_ids=%s\n' "$LEAP16_ORDER_BBS_MISSING"
        printf 'added_bbs_ids=%s\n' "$LEAP16_ORDER_BBS_ADDED"
    } >"$out"
}

eval "$(declare -f leap16_write_firmware_order_report | sed '1s/leap16_write_firmware_order_report/leap16_write_firmware_order_report_pre_r20/')"
leap16_write_firmware_order_report() {
    local out=$1 phase=${2:-snapshot} rc=0
    if [[ ${PENDING_SOURCE:-}:${PENDING_TARGET:-} == limine:grub ]]; then
        case "$phase" in
            promotion-pass)
                if ! leap16_assess_promoted_firmware_order; then
                    rc=1
                else
                    LEAP16_ORDER_REASON='runtime-proven native GRUB2 target is first; Limine source recovery and other real EFI entries remain exact'
                fi
                leap16_emit_firmware_order_report "$out" "$rc"
                return 0
                ;;
            finalization-pass|auto-resume-pass)
                if ! leap16_assess_reverse_finalized_firmware_order; then rc=1; fi
                leap16_emit_firmware_order_report "$out" "$rc"
                return 0
                ;;
        esac
    fi
    leap16_write_firmware_order_report_pre_r20 "$@"
}
