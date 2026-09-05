#!/usr/bin/env bash

KERNEL_VERSIONS=()
KERNEL_IMAGES=()
KERNEL_PKGBASES=()
KERNEL_SUMMARY=""

kernel_pkgbase_from_modules() {
    local ver=$1 f
    f="/usr/lib/modules/$ver/pkgbase"
    [[ -r $f ]] || return 1
    local v
    v=$(<"$f")
    v=${v//$'\r'/}
    v=${v//$'\n'/}
    [[ -n $v ]] || return 1
    printf '%s\n' "$v"
}

# Passive/report ordering should reflect the distro's normal kernel priority,
# not lexical version ordering (which incorrectly puts 6.x LTS before 7.x).
# The ordinary CachyOS kernel is the default; LTS is intentionally later.
# Other variants remain between those two classes. This is only an ordering
# policy; every discovered kernel is still retained and validated.
kernel_priority_for_pkgbase() {
    local pkgbase=${1:-}
    case "$pkgbase" in
        linux-cachyos|linux) printf '000\n' ;;
        *-lts|linux-lts)     printf '900\n' ;;
        '')                  printf '700\n' ;;
        *)                   printf '500\n' ;;
    esac
}

# If an active Limine config happens to be readable without privilege, prefer
# its actual generated kernel-entry order. Normal startup must never sudo just
# to build the report, so protected ESPs use the deterministic package-priority
# fallback above.
reorder_kernels_from_readable_limine_conf() {
    local conf="${ESP_MOUNT:-/boot}/limine.conf"
    [[ ${BOOTLOADER:-unknown} == limine && -r $conf ]] || return 0

    local ordered_versions=() ordered_images=() ordered_pkgbases=()
    local kid i seen="|"
    while IFS= read -r kid; do
        [[ -n $kid ]] || continue
        for i in "${!KERNEL_PKGBASES[@]}"; do
            [[ ${KERNEL_PKGBASES[$i]} == "$kid" ]] || continue
            [[ $seen == *"|$i|"* ]] && continue
            ordered_versions+=("${KERNEL_VERSIONS[$i]}")
            ordered_images+=("${KERNEL_IMAGES[$i]}")
            ordered_pkgbases+=("${KERNEL_PKGBASES[$i]}")
            seen+="$i|"
            break
        done
    done < <(
        awk '
            /^[[:space:]]*comment:[[:space:]]*kernel-id=/ {
                line=$0
                sub(/^[[:space:]]*comment:[[:space:]]*kernel-id=/, "", line)
                gsub(/[[:space:]]+$/, "", line)
                print line
            }
        ' "$conf" 2>/dev/null
    )

    # Preserve any installed kernel that is not represented in limine.conf so
    # detection never hides a kernel merely because generated config is stale.
    for i in "${!KERNEL_VERSIONS[@]}"; do
        [[ $seen == *"|$i|"* ]] && continue
        ordered_versions+=("${KERNEL_VERSIONS[$i]}")
        ordered_images+=("${KERNEL_IMAGES[$i]}")
        ordered_pkgbases+=("${KERNEL_PKGBASES[$i]}")
    done

    KERNEL_VERSIONS=("${ordered_versions[@]}")
    KERNEL_IMAGES=("${ordered_images[@]}")
    KERNEL_PKGBASES=("${ordered_pkgbases[@]}")
}

collect_kernels() {
    KERNEL_VERSIONS=()
    KERNEL_IMAGES=()
    KERNEL_PKGBASES=()
    KERNEL_SUMMARY=""

    local moddir ver image pkgbase priority
    local records=()
    if [[ -d /usr/lib/modules ]]; then
        while IFS= read -r -d '' moddir; do
            ver=${moddir##*/}
            image="$moddir/vmlinuz"
            [[ -f $image ]] || continue
            pkgbase=$(kernel_pkgbase_from_modules "$ver" 2>/dev/null || true)
            priority=$(kernel_priority_for_pkgbase "$pkgbase")
            records+=("$priority"$'\t'"$pkgbase"$'\t'"$ver"$'\t'"$image")
        done < <(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    fi

    if ((${#records[@]})); then
        local record
        while IFS=$'\t' read -r priority pkgbase ver image; do
            KERNEL_VERSIONS+=("$ver")
            KERNEL_IMAGES+=("$image")
            KERNEL_PKGBASES+=("$pkgbase")
        done < <(printf '%s\n' "${records[@]}" | LC_ALL=C sort -t $'\t' -k1,1n -k2,2 -k3,3V)

        reorder_kernels_from_readable_limine_conf
        KERNEL_SUMMARY=$(IFS=,; printf '%s' "${KERNEL_VERSIONS[*]}")
    fi
}
