#!/usr/bin/env bash

BACKUP_ROOT="${BOOTLOADER_SWITCHER_BACKUP_ROOT:-$HOME/cachyos-bootloader-backups}"

have() { command -v "$1" >/dev/null 2>&1; }

trim() {
    local s=$1
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

ok()   { printf '  [OK]   %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; }
info() { printf '  [INFO] %s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

pause() {
    printf '\n'
    read -r -p 'Press Enter to continue...' _
}

safe_realpath() {
    if have realpath; then realpath -m -- "$1" 2>/dev/null || printf '%s' "$1"; else printf '%s' "$1"; fi
}

sha256_of_file() {
    sha256sum -- "$1" | awk '{print $1}'
}

is_cachyos() {
    [[ -r /etc/os-release ]] || return 1
    grep -Eqi '(^ID=cachyos$|^ID_LIKE=.*arch)' /etc/os-release
}
