#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ok() { :; }
fail() { printf 'FAIL: %s\n' "$*" >&2; return 1; }
warn() { :; }

# Minimal originals required by the r47 overlay's function wrapping.
run_switch_preflight() { return 0; }
r26_remove_owned_manifest_paths() {
    local record=$1 kind path identity
    while IFS=$'\t' read -r kind path identity; do
        case "$kind" in
            tree) rm -rf -- "$path" ;;
            file) rm -f -- "$path" ;;
        esac
    done <"$record"
}
leap16_r36_remove_target_manifest_paths() { return 0; }
leap16_r33_remove_recoverable_systemd_residue() { return 0; }

sudo() {
    if [[ ${1:-} == -n ]]; then shift; fi
    command "$@"
}

ESP_MOUNT="$TMP/esp"
mkdir -p "$ESP_MOUNT"
mid=$(cat /etc/machine-id)
leap16_r32_sdboot_payload_root() { printf '%s/%s/opensuse-bootloader-switcher\n' "$ESP_MOUNT" "$mid"; }

# shellcheck source=/dev/null
source "$ROOT/lib/leap16_r47.sh"

parent="$ESP_MOUNT/$mid"
mkdir -p "$parent"
leap16_r47_machine_id_parent_is_empty_dir "$parent"
! leap16_r47_limine_machine_namespace_conflicts "$parent"

touch "$parent/foreign"
! leap16_r47_machine_id_parent_is_empty_dir "$parent"
leap16_r47_limine_machine_namespace_conflicts "$parent"
rm -f "$parent/foreign"

# Retirement of the exact systemd payload tree must collapse only the now-empty
# shared parent, never recursively delete it.
payload="$parent/opensuse-bootloader-switcher"
mkdir -p "$payload"
touch "$payload/kernel"
manifest="$TMP/manifest.tsv"
printf 'tree\t%s\tid\n' "$payload" >"$manifest"
r26_remove_owned_manifest_paths "$manifest"
[[ ! -e $payload ]]
[[ ! -e $parent ]]

# A foreign sibling must prevent parent cleanup.
mkdir -p "$payload" "$parent/foreign-dir"
touch "$payload/kernel" "$parent/foreign-dir/keep"
printf 'tree\t%s\tid\n' "$payload" >"$manifest"
r26_remove_owned_manifest_paths "$manifest"
[[ ! -e $payload ]]
[[ -f $parent/foreign-dir/keep ]]
[[ -d $parent ]]

printf 'leap16-r47 selftest: PASS\n'
