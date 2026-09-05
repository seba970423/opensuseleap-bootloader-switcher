#!/usr/bin/env bash
# openSUSE Leap 16 r26
#
# Fix privileged hash reads used by the finalized-Limine in-place upgrade.
# The inherited helper used `sudo -n sha256sum | awk ... || sha256sum ...`.
# Without pipefail, a failed sudo -n still left awk returning success, so the
# ordinary-user fallback never ran and callers received an empty hash.

r26_hash_file_privileged() {
    local path=$1 out hash

    # Prefer an ordinary read first.  The ESP is normally readable by the
    # logged-in user, and read-only validation should not require a sudo ticket.
    if out=$(sha256sum -- "$path" 2>/dev/null); then
        hash=${out%%[[:space:]]*}
        [[ $hash =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
        printf '%s\n' "$hash"
        return 0
    fi

    # Fall back only to already-authorized sudo.  Never let a downstream awk
    # mask sudo's failure status.
    if out=$(sudo -n sha256sum -- "$path" 2>/dev/null); then
        hash=${out%%[[:space:]]*}
        [[ $hash =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
        printf '%s\n' "$hash"
        return 0
    fi

    return 1
}

# Override both Leap helpers used by the r21-r25 transaction layers.
r21_hash_privileged() {
    r26_hash_file_privileged "$1"
}

leap16_hash_file_privileged() {
    r26_hash_file_privileged "$1"
}
