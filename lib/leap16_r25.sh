#!/usr/bin/env bash
# openSUSE Leap 16 r25
#
# Fix the finalized-Limine in-place menu upgrade introduced in r24.  r24 used
# a doubly escaped canonical Limine EFI path when discovering NVRAM aliases,
# so the literal efibootmgr path never matched and the upgrade failed before
# writing limine.conf.

r24_current_final_ids() {
    local primary_count fallback_count primary_id fallback_id order
    mapfile -t r24_primary_ids < <(r21_nvram_ids_for_esp_path '\EFI\LIMINE\LIMINE_X64.EFI')
    mapfile -t r24_fallback_ids < <(r21_nvram_ids_for_esp_path "$LEAP16_R21_FALLBACK_EFI_PATH")
    primary_count=${#r24_primary_ids[@]}; fallback_count=${#r24_fallback_ids[@]}
    ((primary_count == 1 && fallback_count == 1)) || { fail "Expected exactly one primary Limine alias and one EFI fallback alias (found $primary_count/$fallback_count)"; return 1; }
    primary_id=${r24_primary_ids[0]^^}; fallback_id=${r24_fallback_ids[0]^^}
    leap16_nvram_entry_matches_current_esp "$primary_id" || { fail "Primary Limine Boot$primary_id is not bound to the current ESP"; return 1; }
    leap16_nvram_entry_matches_current_esp "$fallback_id" || { fail "EFI fallback Boot$fallback_id is not bound to the current ESP"; return 1; }
    order=$(leap16_current_boot_order)
    [[ $order == "$primary_id,$fallback_id"* ]] || { fail "Final BootOrder does not begin primary/fallback ($order)"; return 1; }
    printf '%s\t%s\n' "$primary_id" "$fallback_id"
}
