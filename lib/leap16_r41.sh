#!/usr/bin/env bash
# leap16-r41: resumable systemd-boot -> GRUB2 finalization after the r40
# hardware run reached fallback transfer and then tripped `set -u` in r39's
# BootOrder helper.
#
# r39 declared `direct` and immediately expanded it inside an array initializer
# on the next line, before assigning the recorded direct-GRUB Boot#### ID.  With
# the switcher's global `set -u`, that is a hard abort.  The failure happens
# after target-first promotion and after the transaction-persisted fallback
# transfer checkpoint, but before source/churn removal from BootOrder.
#
# Keep every proven layer untouched.  Override only that helper, assign the
# direct ID before constructing the final order, and preserve the r39
# baseline/churn ownership gates.  The helper is intentionally idempotent so a
# runtime-validated r40 transaction that already transferred EFI/BOOT can be
# finalized in-place from the same GRUB target session.

eval "$(declare -f leap16_r38_final_grub_order_without_systemd | sed '1s/leap16_r38_final_grub_order_without_systemd/leap16_r38_final_grub_order_without_systemd_pre_leap16_r41/')"
leap16_r38_final_grub_order_without_systemd() {
    local target source direct order id joined retired
    local -a ids=() out=() churn=()

    if ! leap16_r38_pending; then
        leap16_r38_final_grub_order_without_systemd_pre_leap16_r41 "$@"
        return $?
    fi

    target=${PENDING_TARGET_BOOT_ID^^}
    source=${PENDING_OLD_BOOT_ID^^}
    direct=$(leap16_r38_direct_id) || return 1
    [[ $direct =~ ^[0-9A-Fa-f]{4}$ ]] || {
        fail 'Recorded direct-GRUB firmware identity is unavailable during finalization'
        return 1
    }
    direct=${direct^^}
    out=("$target" "$direct")

    retired=$(leap16_r39_churn_retired_path) || return 1
    mapfile -t churn < <(leap16_r39_recorded_churn_ids)
    if [[ ! -e $retired ]]; then
        leap16_r39_verify_recorded_churn || return 1
    fi

    order=$(leap16_current_boot_order) || return 1
    IFS=',' read -ra ids <<<"$order"
    for id in "${ids[@]}"; do
        id=${id^^}
        [[ -n $id && $id != "$target" && $id != "$direct" && $id != "$source" ]] || continue
        local owned=0 c
        for c in "${churn[@]}"; do
            [[ $id == "$c" ]] && { owned=1; break; }
        done
        ((owned)) && continue
        boot_id_exists "$id" && out+=("$id")
    done

    joined=$(IFS=,; printf '%s' "${out[*]}")
    sudo efibootmgr -o "$joined" >/dev/null || return 1
    order=$(leap16_current_boot_order)
    [[ $order == "$target,$direct"* ]] || {
        fail "Final GRUB BootOrder does not begin shim/direct ($order)"
        return 1
    }
    ! leap16_order_has_id "$order" "$source" || {
        fail "Source systemd-boot Boot$source remains in persistent BootOrder"
        return 1
    }
    for id in "${churn[@]}"; do
        leap16_order_has_id "$order" "$id" && {
            fail "Firmware-churn Boot$id remains in persistent BootOrder"
            return 1
        }
    done
    ok "Removed source systemd-boot Boot$source and recorded firmware churn from BootOrder while every referenced EFI file still exists"

    if [[ ! -e $retired ]]; then
        for id in "${churn[@]}"; do
            [[ -n $id ]] || continue
            if boot_id_exists "$id"; then
                sudo efibootmgr -b "$id" -B >/dev/null || {
                    fail "Could not delete ownership-recorded firmware-churn Boot$id"
                    return 1
                }
                ok "Deleted ownership-recorded post-stage firmware-churn Boot$id after removing it from BootOrder"
            fi
        done
        : >"$retired" || return 1
        chmod 600 -- "$retired" 2>/dev/null || true
    fi
    leap16_r39_verify_recorded_churn || return 1
}
