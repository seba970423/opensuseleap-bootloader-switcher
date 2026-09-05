#!/usr/bin/env bash
# r45: fix the GRUB -> restored-Limine v4 path exposed by the sequential
# restore finisher loop.
#
# The historical GRUB -> Limine restore tunnel predates r30 and still stages its
# v4 managed kernel/initramfs tree through r23_stage_limine_from_v4_backup().
# That function used `cp -a` directly on the VFAT ESP.  Archive mode attempts to
# preserve Unix uid/gid/mode/xattr metadata that FAT cannot represent, so real
# hardware failed with "failed to preserve ownership: Operation not permitted".
#
# This is not a transaction-engine failure.  The uncommitted-stage cleanup did
# exactly what it should: removed the partial Limine payload/policy/EFI namespace
# and restored the original source-first BootOrder.  r25 already introduced a
# VFAT-aware restore_copy_from_backup() helper that keeps recursive/no-dereference
# copy semantics while using --no-preserve=all and refusing symlinks on the ESP.
#
# Keep the hardware-proven historical GRUB -> Limine transaction choreography
# unchanged and override only the v4 payload copier to reuse that existing helper.
# r30's generic Limine restore path already has equivalent VFAT-safe semantics.

r23_stage_limine_from_v4_backup() {
    local dir=$1 backup_mount=$2 machine=$3 conf splash managed dst_managed managed_rel
    conf=$(r23_backup_limine_conf_path "$dir" "$backup_mount")
    splash=$(r23_backup_limine_splash_path "$dir" "$backup_mount")
    managed=$(r23_backup_limine_managed_path "$dir" "$backup_mount" "$machine")
    [[ -f $conf && -f $splash && -d $managed ]] || { fail 'Limine v4 backup payload is incomplete'; return 1; }

    # Apply the same unsafe-object gate used by the generic r30 Limine-v4
    # restore path before anything from the managed tree is written to VFAT.
    r30_limine_v4_payload_shape_safe "$dir" "$backup_mount" "$machine" || {
        fail 'Limine v4 backup managed tree contains unsafe objects'
        return 1
    }

    r23_install_limine_policy_from_backup "$dir" || return 1
    [[ ! -e "$ESP_MOUNT/limine.conf" ]] || { fail 'limine.conf appeared after preflight'; return 1; }
    dst_managed="$ESP_MOUNT/$machine"
    [[ ! -e $dst_managed ]] || { fail 'Limine managed payload directory appeared after preflight'; return 1; }

    # install(1) is retained for the two regular files because this historical
    # path already proved those writes on the mounted ESP.  The recursive tree
    # is delegated to r25's VFAT-aware exact-path restore helper instead of
    # direct `cp -a` archive-metadata restoration.
    sudo install -o root -g root -m 0644 -- "$conf" "$ESP_MOUNT/limine.conf" || return 1
    sudo install -o root -g root -m 0644 -- "$splash" "$ESP_MOUNT/$R23_LIMINE_SPLASH_NAME" || return 1
    managed_rel="${backup_mount#/}/$machine"
    restore_copy_from_backup "$dir" "$managed_rel" || return 1
    ok 'Restored self-contained v4 Limine config, CachyOS splash and VFAT-safe managed kernel/initramfs payload tree'
}
