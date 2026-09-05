#!/usr/bin/env bash
# leap16-r82: repair rEFInd -> Limine promotion ordering exposed by the
# 2026-09-05 r81 hardware run. The generic adapter promotion helper removes
# the source from BootOrder, but this two-proof edge must keep exact rEFInd
# recovery second until the independent EFI/BOOT Limine proof succeeds.

# r81's hardware run reached a runtime-validated canonical Limine session with
# intact passive rEFInd recovery, then stopped before EFI/BOOT transfer because
# leap16_r64_promote_and_stage_limine_fallback() called adapter_target_promote().
# Reproduce that function with one semantic change: establish the dedicated
# primary+source recovery order used by the already-proven two-proof Limine
# paths. This also self-heals the exact r81 stranded state (e.g. BootOrder only
# containing the target) after all existing runtime/source ownership gates pass.
leap16_r64_promote_and_stage_limine_fallback() {
    local source=${PENDING_OLD_BOOT_ID^^} target=${PENDING_TARGET_BOOT_ID^^} order conf_hash fallback_hash fallback_id before next pm
    validate_pending_compatibility || return 1
    [[ $PENDING_PHASE == runtime-validated ]] || return 1
    detect_bootloader; [[ $BOOTLOADER == limine && ${BOOT_CURRENT^^} == "$target" ]] || return 1
    leap16_r64_validate_limine_primary_runtime || return 1

    r21_order_primary_then_source_recovery \
        || { fail 'Could not establish canonical Limine + rEFInd recovery ordering before fallback transfer'; return 1; }
    [[ $(leap16_current_boot_order | cut -d, -f1,2) == "$target,$source" ]] \
        || { fail 'Canonical Limine/rEFInd promoted recovery topology is not exact'; return 1; }
    ok "Canonical Limine Boot$target is first and exact rEFInd recovery Boot$source remains second"

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

leap16_r64_print_matrix() {
    cat <<'MATRIX'
openSUSE Leap 16 bootloader matrix — leap16-r82

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

r82 evidence scope:
  - The Sep 5 r81 hardware run proves the canonical rEFInd -> Limine primary
    BootNext/runtime proof, with exact passive rEFInd recovery still intact.
  - r81 then failed before EFI/BOOT transfer because the generic promotion
    helper dropped the source from the required two-entry recovery ordering.
  - r82 replaces only that promotion step with the dedicated
    primary+source-recovery ordering helper; the second proof and retirement
    gates are unchanged and still require fresh hardware evidence.
  - Limine -> rEFInd live remains HW-PROVEN from the earlier Sep 5 run.
  - Neither Limine/rEFInd restore direction is promoted by local tests.
  - GRUB2 <-> rEFInd live and both restores remain HW-PROVEN per the handoff.
MATRIX
}
