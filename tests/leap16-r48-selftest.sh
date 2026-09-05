#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ok(){ :; }; fail(){ printf 'FAIL: %s\n' "$*" >&2; return 1; }; warn(){ :; }; info(){ :; }

# Minimal wrapped function surface.
load_pending_state(){ PENDING_REASON='unsupported r26 adapter migration direction'; return 1; }
validate_pending_compatibility(){ return 0; }
r26_adapter_paths(){ :; }
adapter_source_snapshot(){ TRANSACTION_SNAPSHOT_DIR="$TMP/snap"; mkdir -p "$TRANSACTION_SNAPSHOT_DIR"; return 0; }
verify_pending_source_recovery_unchanged(){ return 0; }
r26_remove_uncommitted_target_namespaces(){ return 0; }
r26_stage_systemd_boot_target(){ return 0; }
r26_target_namespace_clean(){ return 0; }
validate_pending_target_runtime(){ return 0; }
r26_finalize_adapter_transaction(){ return 0; }
operation_supported(){ return 1; }
leap16_r44_run_systemd_edge_inner(){ return 2; }
run_live_operation(){ return 2; }
r22_resume_transaction_root(){ return 2; }

R26_PENDING_FORMAT=5; R26_ADAPTER_REVISION=1
PENDING_FORMAT=5; PENDING_ADAPTER_REVISION=1; PENDING_PHASE=boot-armed; PENDING_SOURCE=limine; PENDING_TARGET=systemd-boot
PENDING_REASON='unsupported r26 adapter migration direction'; PENDING_MACHINE_ID=x; PENDING_OLD_BOOT_ID=0001; PENDING_TARGET_BOOT_ID=0002
PENDING_SOURCE_CMDLINE='root=UUID=x quiet'; PENDING_SOURCE_MANIFEST="$TMP/source"; PENDING_TARGET_MANIFEST="$TMP/target"
touch "$PENDING_SOURCE_MANIFEST" "$PENDING_TARGET_MANIFEST"
r26_state_format(){ printf '5\n'; }
pending_path_under(){ [[ $1 == "$2"/* ]]; }

ESP_MOUNT="$TMP/esp"; ESP_SOURCE=/dev/test1; mkdir -p "$ESP_MOUNT/EFI/LIMINE" "$ESP_MOUNT/loader/entries"
mid=$(cat /etc/machine-id); mkdir -p "$ESP_MOUNT/$mid/linux-a" "$ESP_MOUNT/$mid/linux-b"
touch "$ESP_MOUNT/$mid/linux-a/kernel" "$ESP_MOUNT/$mid/linux-b/kernel"
sudo(){ if [[ ${1:-} == -n ]]; then shift; fi; command "$@"; }
r21_fallback_ids_now(){ printf '0003\n'; }
LEAP16_R21_FALLBACK_EFI_PATH='\EFI\BOOT\BOOTX64.EFI'
LEAP16_R32_SDBOOT_EFI='\EFI\systemd\systemd-bootx64.efi'
LEAP16_R32_SDBOOT_LABEL='openSUSE systemd-boot'
KERNEL_VERSIONS=(a b)
collect_kernels(){ KERNEL_VERSIONS=(a b); }
kernel_pkgbase_for_version(){ printf 'linux-%s\n' "$1"; }

# shellcheck source=/dev/null
source "$ROOT/lib/leap16_r48.sh"

# New direction is admitted, reverse remains locked.
operation_supported limine systemd-boot
! operation_supported systemd-boot limine

# Shared parent ownership is disjoint and exact: arbitrary children are never
# claimed, and the shared parent itself is never owned.
paths=$(r26_adapter_paths limine)
grep -Fqx "$ESP_MOUNT/$mid/linux-a" <<<"$paths"
grep -Fqx "$ESP_MOUNT/$mid/linux-b" <<<"$paths"
! grep -Fqx "$ESP_MOUNT/$mid" <<<"$paths"
mkdir -p "$ESP_MOUNT/$mid/foreign"
_saved_fail=$(declare -f fail)
fail(){ return 1; }
if leap16_r48_verify_limine_machine_children_exact; then
    printf 'FAIL: foreign machine-id child was accepted as Limine ownership\n' >&2
    exit 1
fi
eval "$_saved_fail"
rmdir "$ESP_MOUNT/$mid/foreign"
leap16_r48_verify_limine_machine_children_exact

# Pending parser tail accepts only the new forward direction.
load_pending_state
[[ $PENDING_REASON == valid ]]

# Fallback metadata + firmware baseline are exact and snapshot-bounded.
PENDING_TRANSACTION_SNAPSHOT_DIR="$TMP/snap"; mkdir -p "$PENDING_TRANSACTION_SNAPSHOT_DIR"
TRANSACTION_SNAPSHOT_DIR="$PENDING_TRANSACTION_SNAPSHOT_DIR"
leap16_r48_write_meta 0003
cat >"$PENDING_TRANSACTION_SNAPSHOT_DIR/$LEAP16_R48_FIRMWARE_BASELINE" <<BASE
BootCurrent: 0001
BootOrder: 0001,0003
Boot0001* Limine HD(...)/File(\\EFI\\LIMINE\\LIMINE_X64.EFI)
Boot0003* UEFI OS HD(...)/File(\\EFI\\BOOT\\BOOTX64.EFI)
BASE
leap16_r48_validate_meta
validate_pending_compatibility
[[ $(leap16_r48_fallback_id) == 0003 ]]
leap16_r48_baseline_has_id 0003
! leap16_r48_baseline_has_id 0005

# A new same-ESP fallback alias is classified as post-baseline churn, while the
# recorded Limine fallback is not.
leap16_r48_current_fallback_ids(){ printf '0003\n0005\n'; }
leap16_nvram_entry_matches_current_esp(){ return 0; }
nvram_id_matches_path(){ return 0; }
boot_id_exists(){ return 0; }
raw=$(leap16_r48_collect_fallback_churn)
[[ $raw == 0005 ]]
leap16_r48_record_fallback_churn
[[ $(leap16_r48_recorded_fallback_churn_ids) == 0005 ]]
leap16_r48_verify_recorded_fallback_churn

printf 'leap16-r48 selftest: PASS\n'
