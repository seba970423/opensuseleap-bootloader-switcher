#!/usr/bin/env bash
# r27: backup metadata parser hardening/fix.
#
# r26 writes metadata values with Bash printf %q.  Values such as the canonical
# systemd-boot label "Linux Boot Manager" are therefore serialized as
# Linux\ Boot\ Manager.  The pre-r27 loader rejected that valid %q form before
# sourcing metadata.conf, so a correctly-created systemd-boot backup failed its
# immediate validation step.
#
# r27 fixes the serializer/parser contract without weakening the trust boundary:
# metadata.conf is no longer sourced at all.  Only the known schema keys are
# accepted and %q-style values are decoded as data, never as shell code.  This
# also keeps older v2/v3/v4 backups readable.

BACKUP_METADATA_DECODED=""

r27_backup_metadata_key_allowed() {
    case "$1" in
        format_version|bootloader|payload_policy|created_epoch|created_iso|hostname|machine_id|\
        esp_source|esp_mount|esp_uuid|root_source|root_uuid|boot_current|boot_label|boot_efi_path)
            return 0
            ;;
        *) return 1 ;;
    esac
}

# Decode the forms emitted by `printf %q` without eval/source:
#   plain-token              -> plain-token
#   Linux\ Boot\ Manager     -> Linux Boot Manager
#   \\EFI\\systemd\\...       -> \EFI\systemd\...
#   ''                       -> empty string
#   $'...ANSI-C escapes...'  -> decoded with printf %b
#
# Legacy metadata accepted a simple single-quoted value as well, so preserve
# that read compatibility.  Unquoted backslashes escape exactly the next
# character, matching the %q representation used by all existing releases.
r27_decode_backup_metadata_value() {
    local encoded=$1 body out="" ch next i len escaped
    BACKUP_METADATA_DECODED=""

    if [[ -z $encoded || $encoded == "''" ]]; then
        return 0
    fi

    if [[ $encoded == \$\'* && $encoded == *\' && ${#encoded} -ge 3 ]]; then
        body=${encoded:2:${#encoded}-3}
        escaped=0
        len=${#body}
        for ((i=0; i<len; i++)); do
            ch=${body:i:1}
            if ((escaped)); then
                escaped=0
                continue
            fi
            if [[ $ch == \\ ]]; then
                escaped=1
            elif [[ $ch == "'" ]]; then
                # An unescaped quote would terminate the ANSI-C shell literal;
                # it is never produced inside a valid printf-%q value.
                return 1
            fi
        done
        ((escaped == 0)) || return 1
        printf -v BACKUP_METADATA_DECODED '%b' "$body"
        return 0
    fi

    # Read compatibility with the pre-r27 validator's accepted 'literal' form.
    if [[ $encoded == \'*\' && ${#encoded} -ge 2 ]]; then
        body=${encoded:1:${#encoded}-2}
        [[ $body != *"'"* ]] || return 1
        BACKUP_METADATA_DECODED=$body
        return 0
    fi

    len=${#encoded}
    for ((i=0; i<len; i++)); do
        ch=${encoded:i:1}
        if [[ $ch == \\ ]]; then
            ((i++))
            ((i < len)) || return 1
            next=${encoded:i:1}
            out+=$next
        else
            out+=$ch
        fi
    done
    BACKUP_METADATA_DECODED=$out
    return 0
}

# Override the pre-r27 source-based metadata loader.  Keep the public function
# name so every existing backup/list/restore caller automatically gets the fix.
load_backup_metadata() {
    local dir=$1 line key encoded
    local -A seen=()

    [[ -f $dir/metadata.conf ]] || return 1

    # Never let a missing key inherit a value from a previously-loaded backup.
    unset format_version bootloader payload_policy created_epoch created_iso hostname machine_id \
        esp_source esp_mount esp_uuid root_source root_uuid boot_current boot_label boot_efi_path

    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == *=* ]] || return 1
        key=${line%%=*}
        encoded=${line#*=}
        [[ $key =~ ^[a-z_][a-z0-9_]*$ ]] || return 1
        r27_backup_metadata_key_allowed "$key" || return 1
        [[ -z ${seen[$key]+x} ]] || return 1
        seen[$key]=1
        r27_decode_backup_metadata_value "$encoded" || return 1
        printf -v "$key" '%s' "$BACKUP_METADATA_DECODED"
    done <"$dir/metadata.conf"

    return 0
}
