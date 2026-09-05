#!/usr/bin/env bash
# leap16-r83: repair rEFInd -> Limine fallback-alias ID capture exposed by the
# first r82 hardware retry.  The create-only helper emits a success message on
# stdout, but r64 consumes the wrapper through command substitution and requires
# stdout to contain only the four-hex-digit Boot#### ID.

# Keep the r64 ownership/alias semantics unchanged.  The only behavioral change
# is the output contract: status text from r28 is redirected to stderr so the
# caller receives exactly one Boot#### ID on stdout.  This prevents a valid
# newly-created fallback alias from being rejected by the following metadata
# gate and then correctly-but-confusingly rolled back to the proof-#1 checkpoint.
leap16_r64_create_or_adopt_limine_fallback_alias() {
    local id
    local -a ids=()
    mapfile -t ids < <(r21_fallback_ids_now | LC_ALL=C sort -u)
    ((${#ids[@]} <= 1)) || { fail "Fallback alias set is ambiguous (${#ids[@]})"; return 1; }

    if ((${#ids[@]} == 1)); then
        id=${ids[0]^^}
        leap16_nvram_entry_matches_current_esp "$id" \
            && nvram_id_matches_path "$id" "$LEAP16_R21_FALLBACK_EFI_PATH" \
            || return 1
        printf '%s\n' "$id"
        return 0
    fi

    # r28_create_alias_create_only() intentionally emits an [OK] status line.
    # This wrapper is used inside $(...), so status output must not contaminate
    # the machine-readable Boot#### ID returned on stdout.
    r28_create_alias_create_only 'UEFI OS' "$LEAP16_R21_FALLBACK_EFI_PATH" >&2 || return 1
    id=${R28_CREATED_ALIAS_ID^^}
    [[ $id =~ ^[0-9A-F]{4}$ ]] || { fail 'Create-only fallback helper returned an invalid Boot#### ID'; return 1; }
    printf '%s\n' "$id"
}

leap16_r64_print_matrix() {
    cat <<'MATRIX'
openSUSE Leap 16 bootloader matrix — leap16-r83

Legend:
  HW-PROVEN       completed automatically on real hardware with exact final topology
  HW-PENDING      implemented; complete hardware evidence still required
  —               same-backend; not a cross-loader edge

LIVE SWITCH MATRIX (source rows -> target columns)
                 GRUB2        Limine       systemd-boot  rEFInd
  GRUB2          —            HW-PROVEN    HW-PROVEN     HW-PROVEN
  Limine         HW-PROVEN    —            HW-PROVEN     HW-PROVEN
  systemd-boot   HW-PROVEN    HW-PROVEN    —             HW-PENDING
  rEFInd         HW-PROVEN    HW-PENDING   HW-PENDING    —

CROSS-LOADER RESTORE MATRIX (active source -> restored backup target)
                 GRUB2        Limine       systemd-boot  rEFInd
  GRUB2          —            HW-PROVEN    HW-PROVEN     HW-PROVEN
  Limine         HW-PROVEN    —            HW-PROVEN     HW-PENDING
  systemd-boot   HW-PROVEN    HW-PROVEN    —             HW-PENDING
  rEFInd         HW-PROVEN    HW-PENDING   HW-PENDING    —

BACKUP BACKENDS
  GRUB2          HW-PROVEN
  Limine         HW-PROVEN
  systemd-boot   HW-PROVEN
  rEFInd         HW-PROVEN

r83 evidence scope:
  - The Sep 5 r81 hardware run proved canonical rEFInd -> Limine proof #1.
  - r82 repaired the source-dropping promotion order, but the first r82 retry
    exposed stdout contamination in the fallback alias ID wrapper.
  - That contamination caused the post-create metadata gate to reject the valid
    alias and the existing fail-closed rollback to restore BootOrder=Limine,rEFInd,
    remove the new fallback alias and restore pre-transfer EFI/BOOT/config state.
  - r83 preserves all proof/ownership/retirement gates and changes only the
    machine-readable output contract of fallback alias creation.
  - rEFInd -> Limine proof #2 and retirement remain HW-PENDING.
  - Neither Limine/rEFInd restore direction is promoted by local tests.
MATRIX
}
