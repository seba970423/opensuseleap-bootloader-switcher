#!/usr/bin/env bash

# leap16-r65
# Hardware-discovered zypper command-option scoping hotfix.
#
# Leap 16's zypper accepts --non-interactive as a global option, while
# --no-recommends is an install-command option.  r64 (and older fresh-package
# paths inherited by r64) placed both before `install`, so a machine that
# actually needed package acquisition failed before candidate commit.
#
# Keep historical layers immutable and override only the effective installers.

leap16_r65_zypper_install_no_recommends() {
    have zypper || { fail 'zypper is required for native openSUSE package installation'; return 1; }

    # Probe the command-specific interface rather than assuming every zypper
    # build exposes the same solver flags.  Do not silently install weak
    # dependencies if the safety contract cannot be requested.
    if ! zypper install --help 2>&1 | grep -q -- '--no-recommends'; then
        fail 'This zypper build does not expose install --no-recommends; refusing to weaken the package-staging contract'
        return 1
    fi

    # --non-interactive is global; --no-recommends is scoped to `install`.
    sudo zypper --non-interactive install --no-recommends "$@"
}

# Fresh systemd-boot acquisition used by the already-proven Leap adapter.
# Preserve r33 bookkeeping while correcting only the zypper invocation.
leap16_r32_install_systemd_boot_package() {
    have zypper || { fail 'zypper is required'; return 1; }
    LEAP16_R33_SDBOOT_PACKAGE_INSTALLED_BY_STAGE=0
    if leap16_r32_find_systemd_boot_binary >/dev/null 2>&1; then
        return 0
    fi
    printf 'Installing native openSUSE systemd-boot package with weak dependencies disabled...\n'
    leap16_r65_zypper_install_no_recommends systemd-boot || return 1
    leap16_r32_find_systemd_boot_binary >/dev/null 2>&1 || {
        fail 'systemd-boot RPM installed but no x86_64 EFI binary was found'
        return 1
    }
    LEAP16_R33_SDBOOT_PACKAGE_INSTALLED_BY_STAGE=1
    ok 'Installed the systemd-boot RPM without optional sdbootutil/PCR/TPM weak-dependency expansion'
}

# Native GRUB/shim reconstruction package acquisition.  Existing hardware
# proofs remain valid; this only fixes the previously unexercised missing-RPM
# branch.
leap16_r38_install_grub_packages_if_needed() {
    if rpm -q grub2-common grub2-x86_64-efi shim >/dev/null 2>&1 && leap16_r38_grub_tools_ready; then
        ok 'Native openSUSE GRUB2/shim package/tool set is already installed'
        return 0
    fi
    have zypper || { fail 'zypper is required to install the native openSUSE GRUB2/shim package set'; return 1; }
    printf 'Installing native openSUSE GRUB2/shim packages without weak dependencies...\n'
    leap16_r65_zypper_install_no_recommends grub2-common grub2-x86_64-efi shim || return 1
    rpm -q grub2-common grub2-x86_64-efi shim >/dev/null 2>&1 || { fail 'Native GRUB2/shim RPM set is incomplete after installation'; return 1; }
    leap16_r38_grub_tools_ready || { fail 'Native GRUB2 reconstruction tools are incomplete after package installation'; return 1; }
    ok 'Native openSUSE GRUB2/shim package/tool set is ready'
}

# rEFInd package acquisition, including the trusted local-RPM escape hatch
# introduced by r64.  Mutable rEFInd state and all transaction semantics stay
# owned by r64; only package-manager argument ordering changes here.
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
        leap16_r65_zypper_install_no_recommends "$rpm_path" || return 1
    else
        printf 'Installing native openSUSE rEFInd package without weak dependencies...\n'
        if ! leap16_r65_zypper_install_no_recommends refind; then
            fail 'zypper could not install package "refind" with recommendations disabled. If it is unavailable in the configured Leap repositories, provide a trusted local RPM with BOOTLOADER_SWITCHER_REFIND_RPM=/absolute/path/to/refind.rpm and retry.'
            return 1
        fi
    fi
    rpm -q refind >/dev/null 2>&1 || { fail 'rEFInd RPM is not installed after zypper returned'; return 1; }
    have refind-install || { fail 'refind-install is unavailable after package installation'; return 1; }
    ok 'Native openSUSE rEFInd package/tool set is ready'
}

# Keep the matrix ledger release-accurate after the package-manager hotfix.
leap16_r64_print_matrix() {
    cat <<'MATRIX'
openSUSE Leap 16 bootloader matrix — leap16-r65

Legend:
  HW-PROVEN       completed on real hardware before r64/r65
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

HARDWARE ATTEMPTS INVOLVING rEFInd
  GRUB2 -> rEFInd  r64 package-stage attempt: SAFE-FAIL before candidate commit (zypper option-scope bug); not a boot proof
MATRIX
}
