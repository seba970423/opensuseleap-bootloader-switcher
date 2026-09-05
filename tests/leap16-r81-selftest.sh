#!/usr/bin/env bash
set -euo pipefail
ROOT=${R81_TEST_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
fail_test(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
source_effective_stack(){
    local prelude
    prelude=$(awk '/^select_target_bootloader\(\)/{exit} {print}' "$ROOT/bootloader-switcher.sh" | sed '/^SCRIPT_DIR=/d')
    SCRIPT_DIR=$ROOT
    eval "$prelude"
}

(
    source_effective_stack
    [[ $SWITCHER_RELEASE == leap16-r81 ]] || fail_test 'r81 release not loaded'
    matrix=$(leap16_r64_print_matrix)
    [[ $matrix == *'matrix — leap16-r81'* ]] || fail_test 'matrix heading is stale'
    [[ $matrix == *'Limine         HW-PROVEN    —            HW-PROVEN     HW-PROVEN'* ]] \
        || fail_test 'observed forward live proof is missing'
    [[ $matrix == *'Limine         HW-PROVEN    —            HW-PROVEN     HW-PENDING'* ]] \
        || fail_test 'restore inherited the live proof without its own evidence'
)

# Real generated menu, real hashes and the effective validator. A finalized
# rEFInd source has no generic fallback. Staging must create a usable direct
# recovery item without manufacturing EFI/BOOT or changing the source bytes.
(
    source_effective_stack
    td=$(mktemp -d); trap 'rm -rf -- "$td"' EXIT
    ESP_MOUNT="$td/esp"; PENDING_ESP_MOUNT=$ESP_MOUNT
    mkdir -p "$ESP_MOUNT/EFI/refind" "$ESP_MOUNT/EFI/LIMINE"
    printf MZrefind >"$ESP_MOUNT/EFI/refind/refind_x64.efi"
    printf MZlimine >"$ESP_MOUNT/EFI/LIMINE/LIMINE_X64.EFI"
    sudo(){ [[ ${1:-} != -n ]] || shift; command "$@"; }
    ok(){ :; }; fail(){ printf '%s\n' "$*" >&2; }
    BOOTLOADER=refind; LEAP16_R64_STAGING=1
    OLD_FALLBACK_EXISTED=0; OLD_FALLBACK_HASH=''
    R26_SOURCE_EFI_HASH=$(r21_hash_privileged "$ESP_MOUNT/EFI/refind/refind_x64.efi")
    cat >"$td/generated.conf" <<'CONF'
timeout: 5
/+openSUSE Linux
  //kernel
  protocol: linux
  cmdline: root=UUID=test quiet
/EFI fallback
### Shared pre-transfer recovery entry; EFI/BOOT remains native openSUSE until primary Limine proof
comment: Preserved openSUSE generic fallback / GRUB2 recovery path
protocol: efi
path: boot():/EFI/BOOT/BOOTX64.EFI
CONF
    cp -- "$td/generated.conf" "$ESP_MOUNT/limine.conf"
    leap16_r64_patch_limine_pretransfer_comment || fail_test 'pre-transfer menu conversion failed'
    grep -Fqx 'path: boot():/EFI/refind/refind_x64.efi' "$ESP_MOUNT/limine.conf" \
        || fail_test 'staged menu still points to the nonexistent EFI/BOOT recovery path'
    leap16_validate_limine_recovery_contract "$ESP_MOUNT/limine.conf" \
        || fail_test 'valid direct rEFInd recovery was rejected before candidate commit'
    [[ ! -e $ESP_MOUNT/EFI/BOOT/BOOTX64.EFI ]] || fail_test 'staging fabricated a generic fallback'
    [[ $(r21_hash_privileged "$ESP_MOUNT/EFI/refind/refind_x64.efi") == "$R26_SOURCE_EFI_HASH" ]] \
        || fail_test 'staging changed rEFInd source bytes'

    # Backup restore substitutes a finalized config through this same hook.
    # The original backup must remain immutable while its staged copy changes.
    leap16_r81_render_recovery "$td/generated.conf" '/EFI fallback' \
        'path: boot():/EFI/BOOT/BOOTX64.EFI' fallback "$td/backup.conf"
    backup_hash=$(sha256sum "$td/backup.conf")
    cp -- "$td/backup.conf" "$ESP_MOUNT/limine.conf"
    LEAP16_R31_RESTORE_DIR="$td/backup"
    leap16_r64_patch_limine_pretransfer_comment || fail_test 'restored menu did not gain direct recovery'
    leap16_validate_limine_recovery_contract "$ESP_MOUNT/limine.conf" || fail_test 'restored direct recovery failed validation'
    [[ $(sha256sum "$td/backup.conf") == "$backup_hash" ]] || fail_test 'original backup bytes were edited'

    cp -- "$ESP_MOUNT/limine.conf" "$td/direct.conf"
    cat "$td/direct.conf" >>"$ESP_MOUNT/limine.conf"
    ! leap16_validate_limine_recovery_contract "$ESP_MOUNT/limine.conf" || fail_test 'duplicate recovery stanzas passed'
    cp -- "$td/direct.conf" "$ESP_MOUNT/limine.conf"
    printf tampered >"$ESP_MOUNT/EFI/refind/refind_x64.efi"
    ! leap16_validate_limine_recovery_contract "$ESP_MOUNT/limine.conf" || fail_test 'changed rEFInd source bytes passed'
    printf MZrefind >"$ESP_MOUNT/EFI/refind/refind_x64.efi"

    # An unrelated pre-stage fallback is preserved byte-for-byte before transfer.
    mkdir -p "$ESP_MOUNT/EFI/BOOT"
    printf foreign >"$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"
    ! leap16_validate_limine_recovery_contract "$ESP_MOUNT/limine.conf" || fail_test 'unexpected fallback appearance passed'
    OLD_FALLBACK_EXISTED=1; OLD_FALLBACK_HASH=$(r21_hash_privileged "$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI")
    leap16_validate_limine_recovery_contract "$ESP_MOUNT/limine.conf" || fail_test 'unchanged pre-stage fallback was rejected'
    printf changed >"$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"
    ! leap16_validate_limine_recovery_contract "$ESP_MOUNT/limine.conf" || fail_test 'changed pre-stage fallback passed'
    rm -- "$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"

    # A fresh process reconstructs primary/transfer state from the pending
    # record and metadata, without the staging flag or inherited proof history.
    LEAP16_R64_STAGING=0; PENDING_FORMAT=$R26_PENDING_FORMAT
    PENDING_SOURCE=refind; PENDING_TARGET=limine; PENDING_PHASE=boot-armed
    PENDING_SOURCE_EFI_HASH=$R26_SOURCE_EFI_HASH
    PENDING_TARGET_EFI_HASH=$(r21_hash_privileged "$ESP_MOUNT/EFI/LIMINE/LIMINE_X64.EFI")
    PENDING_TARGET_BOOT_ID=0000; PENDING_OLD_BOOT_ID=0001
    PENDING_OLD_FALLBACK_EXISTED=0; PENDING_OLD_FALLBACK_HASH=''
    PENDING_TRANSACTION_SNAPSHOT_DIR="$td/snapshot"; mkdir -p "$PENDING_TRANSACTION_SNAPSHOT_DIR"
    primary_hash=$(r21_hash_privileged "$ESP_MOUNT/limine.conf")
    leap16_r64_write_meta refind:limine '' "$primary_hash"
    leap16_validate_limine_recovery_contract "$ESP_MOUNT/limine.conf" || fail_test 'pending primary recovery contract failed'
    transferred=$(leap16_r64_rewrite_limine_recovery_to_refind)
    [[ $transferred == "$primary_hash" ]] || fail_test 'transfer unnecessarily changed direct recovery bytes'
    cmp -s "$(leap16_r64_limine_preconf_path)" "$ESP_MOUNT/limine.conf" || fail_test 'primary rollback copy is not exact'
    cp -- "$ESP_MOUNT/EFI/LIMINE/LIMINE_X64.EFI" "$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"
    leap16_r64_update_limine_fallback_meta 0002 "$PENDING_TARGET_EFI_HASH" "$transferred"
    PENDING_PHASE=runtime-validated; BOOT_CURRENT=0000
    leap16_validate_limine_recovery_contract "$ESP_MOUNT/limine.conf" || fail_test 'valid transferred recovery contract failed'
    ! leap16_r64_remove_limine_refind_recovery_block || fail_test 'menu finalized outside the two-proof finalizer'
    LEAP16_R81_FINAL_MENU_AUTHORIZED=1
    final_hash=$(leap16_r64_remove_limine_refind_recovery_block)
    ! leap16_validate_limine_recovery_contract "$ESP_MOUNT/limine.conf" || fail_test 'primary BootCurrent earned final fallback acceptance'
    BOOT_CURRENT=0002
    leap16_validate_limine_recovery_contract "$ESP_MOUNT/limine.conf" || fail_test 'valid second-proof final menu failed'
    leap16_r81_recovery_block_present "$ESP_MOUNT/limine.conf" fallback || fail_test 'visible finalized fallback is missing'
    [[ $(r21_hash_privileged "$ESP_MOUNT/limine.conf") == "$final_hash" ]] || fail_test 'final hash stdout was contaminated'
    ! grep -Fq '/openSUSE rEFInd recovery' "$ESP_MOUNT/limine.conf" || fail_test 'temporary rEFInd recovery survived final rendering'
    LEAP16_R81_FINAL_MENU_AUTHORIZED=0
    ! leap16_validate_limine_recovery_contract "$ESP_MOUNT/limine.conf" || fail_test 'final config self-authorized outside finalization'
)

# The actual r80 finalizer must stop before any alias/config/source mutation
# when the independent fallback proof fails, for both live and restored targets.
for provenance in '' /validated/limine-backup; do
    (
        source_effective_stack
        PENDING_SOURCE=refind; PENDING_TARGET=limine; PENDING_TARGET_BOOT_ID=0000
        PENDING_BACKUP_PATH=$provenance; trace=''
        leap16_r64_validate_limine_fallback_runtime(){ trace+=' proof-failed'; return 1; }
        leap16_r80_normalize_limine_aliases_after_fallback_proof(){ trace+=' MUTATION'; }
        leap16_r64_remove_limine_refind_recovery_block(){ trace+=' MUTATION'; }
        leap16_r64_delete_refind_source(){ trace+=' MUTATION'; }
        ! leap16_r64_retire_refind_after_limine_fallback_proof || fail_test 'failed proof was accepted'
        [[ $trace == ' proof-failed' ]] || fail_test "mutation preceded independent fallback proof ($trace)"
    )
done

# Replay the provided before/staged/final firmware dumps, then remove private
# state exactly as finalization does. The report cache must survive that removal
# but must never cross transaction boundaries or hide real source/ESP drift.
(
    source_effective_stack
    td=$(mktemp -d); trap 'rm -rf -- "$td"' EXIT
    PENDING_SOURCE=limine; PENDING_TARGET=refind; PENDING_FORMAT=$R26_PENDING_FORMAT
    PENDING_TARGET_BOOT_ID=0001; PENDING_OLD_BOOT_ID=0000; PENDING_PHASE=boot-armed
    PENDING_ORIGINAL_BOOT_ORDER=0000,0003
    PENDING_TRANSACTION_SNAPSHOT_DIR="$td/snapshot"; LEAP16_DIAGNOSTIC_ROOT="$td/diagnostics"
    mkdir -p "$PENDING_TRANSACTION_SNAPSHOT_DIR" "$LEAP16_DIAGNOSTIC_ROOT"
    cp "$ROOT/tests/fixtures/r81-limine-to-refind-before.txt" "$PENDING_TRANSACTION_SNAPSHOT_DIR/$LEAP16_R64_FIRMWARE_BASELINE"
    leap16_r80_transaction_partuuid(){ printf '81720d70-39ac-4515-a24e-7e00d3b3d438\n'; }
    efibootmgr(){ cat -- "$td/current"; }
    cp "$ROOT/tests/fixtures/r81-limine-to-refind-staged.txt" "$td/current"
    leap16_r81_cache_report_context || fail_test 'report context could not be cached'
    leap16_write_firmware_order_report "$td/report" runtime
    grep -Fxq 'assessment=pass' "$td/report" || fail_test "valid staged firmware report failed: $(cat "$td/report")"
    PENDING_PHASE=runtime-validated
    cp "$ROOT/tests/fixtures/r81-limine-to-refind-final.txt" "$td/current"
    leap16_write_firmware_order_report "$td/report" finalized-refind-from-limine
    grep -Fxq 'assessment=pass' "$td/report" || fail_test "real finalized rEFInd firmware report failed: $(cat "$td/report")"
    rm -rf -- "$PENDING_TRANSACTION_SNAPSHOT_DIR"
    leap16_write_firmware_order_report "$td/report" auto-resume-pass
    grep -Fxq 'assessment=pass' "$td/report" || fail_test 'final report lost its baseline after snapshot removal'
    cp "$ROOT/tests/fixtures/r81-limine-to-refind-staged.txt" "$td/current"
    leap16_write_firmware_order_report "$td/report" auto-resume-pass
    grep -Fxq 'assessment=fail' "$td/report" || fail_test 'remaining source aliases passed as finalized'
    cp "$ROOT/tests/fixtures/r81-limine-to-refind-final.txt" "$td/current"
    sed -i 's/81720d70-39ac-4515-a24e-7e00d3b3d438/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/g' "$td/current"
    leap16_write_firmware_order_report "$td/report" auto-resume-pass
    grep -Fxq 'assessment=fail' "$td/report" || fail_test 'target on wrong ESP passed'
    cp "$ROOT/tests/fixtures/r81-limine-to-refind-final.txt" "$td/current"
    PENDING_TRANSACTION_SNAPSHOT_DIR="$td/another-transaction"
    leap16_write_firmware_order_report "$td/report" auto-resume-pass
    grep -Fxq 'assessment=fail' "$td/report" || fail_test 'cache from another transaction was accepted'
)

# Every rEFInd-target checkpoint must use the Leap collector instead of the
# historical generic CachyOS fallback directory, and return its usable path.
(
    source_effective_stack
    td=$(mktemp -d); trap 'rm -rf -- "$td"' EXIT
    PENDING_SOURCE=limine; PENDING_TARGET=refind; PENDING_SOURCE_CMDLINE='root=UUID=test quiet'
    leap16_capture_diagnostics(){ mkdir -p "$td/leap/$1"; printf '%s/leap/%s\n' "$td" "$1"; }
    pending_capture_runtime_diagnostics_pre_leap16_r81(){ fail_test 'rEFInd checkpoint used the legacy capture fallback'; }
    efibootmgr(){ printf 'BootCurrent: 0001\n'; }
    out=$(pending_capture_runtime_diagnostics runtime)
    [[ $out == "$td/leap/runtime" && -s $out/recorded-source-cmdline.txt && -s $out/efibootmgr-runtime-v.txt ]] \
        || fail_test 'rEFInd checkpoint was not exported with its runtime evidence'
)
# Reverse reports distinguish candidate, transferred and fallback-proven final
# topology. A primary boot or duplicate fallback cannot pass the final report.
(
    source_effective_stack
    td=$(mktemp -d); trap 'rm -rf -- "$td"' EXIT
    PENDING_SOURCE=refind; PENDING_TARGET=limine; PENDING_FORMAT=$R26_PENDING_FORMAT
    PENDING_TARGET_BOOT_ID=0000; PENDING_OLD_BOOT_ID=0001; PENDING_PHASE=boot-armed
    PENDING_ORIGINAL_BOOT_ORDER=0001
    PENDING_TRANSACTION_SNAPSHOT_DIR="$td/snapshot"; LEAP16_DIAGNOSTIC_ROOT="$td/diagnostics"
    mkdir -p "$PENDING_TRANSACTION_SNAPSHOT_DIR" "$LEAP16_DIAGNOSTIC_ROOT"
    cp "$ROOT/tests/fixtures/r81-limine-to-refind-final.txt" "$PENDING_TRANSACTION_SNAPSHOT_DIR/$LEAP16_R64_FIRMWARE_BASELINE"
    TEST_PARTUUID=81720d70-39ac-4515-a24e-7e00d3b3d438
    leap16_r80_transaction_partuuid(){ printf '%s\n' "$TEST_PARTUUID"; }
    efibootmgr(){ cat -- "$td/current"; }
    write_current(){
        printf 'BootCurrent: %s\nBootOrder: %s\n' "$1" "$2" >"$td/current"
        printf 'Boot0000* Limine HD(1,GPT,%s,0x800,0xff000)/File(\\EFI\\LIMINE\\LIMINE_X64.EFI)\n' "$TEST_PARTUUID" >>"$td/current"
        if [[ $3 == source ]]; then
            printf 'Boot0001* rEFInd HD(1,GPT,%s,0x800,0xff000)/File(\\EFI\\refind\\refind_x64.efi)\n' "$TEST_PARTUUID" >>"$td/current"
        fi
        if [[ $4 == fallback ]]; then
            printf 'Boot0002* UEFI OS HD(1,GPT,%s,0x800,0xff000)/File(\\EFI\\BOOT\\BOOTX64.EFI)\n' "$TEST_PARTUUID" >>"$td/current"
        fi
        return 0
    }
    write_current 0000 0001,0000 source none
    leap16_r81_cache_report_context
    leap16_write_firmware_order_report "$td/report" runtime-pass-limine-from-refind
    grep -Fxq 'assessment=pass' "$td/report" || fail_test "reverse candidate report failed: $(cat "$td/report")"
    leap16_r64_write_meta refind:limine '' "$(printf '%064d' 1)" 0002 "$(printf '%064d' 2)" "$(printf '%064d' 1)"
    PENDING_PHASE=runtime-validated
    write_current 0000 0000,0002,0001 source fallback
    leap16_r81_cache_report_context
    leap16_write_firmware_order_report "$td/report" fallback-armed-limine-from-refind
    grep -Fxq 'assessment=pass' "$td/report" || fail_test 'transferred reverse report failed'
    write_current 0002 0000,0002 retired fallback
    leap16_write_firmware_order_report "$td/report" finalized-limine-from-refind
    grep -Fxq 'assessment=pass' "$td/report" || fail_test "reverse final report failed: $(cat "$td/report")"
    write_current 0000 0000,0002 retired fallback
    leap16_write_firmware_order_report "$td/report" finalized-limine-from-refind
    grep -Fxq 'assessment=fail' "$td/report" || fail_test 'primary BootCurrent passed reverse final report'
    write_current 0002 0000,0002 retired fallback
    printf 'Boot0003* duplicate HD(1,GPT,%s,0x800,0xff000)/File(\\EFI\\BOOT\\BOOTX64.EFI)\n' "$TEST_PARTUUID" >>"$td/current"
    leap16_write_firmware_order_report "$td/report" finalized-limine-from-refind
    grep -Fxq 'assessment=fail' "$td/report" || fail_test 'parked duplicate fallback passed final report'
    write_current 0002 0000,0002 retired fallback
    : >"$(leap16_r81_report_cache_dir)/baseline.txt"
    leap16_write_firmware_order_report "$td/report" auto-resume-pass
    grep -Fxq 'assessment=fail' "$td/report" || fail_test 'empty cached baseline passed final report'
)

# Firmware can re-synthesize one wave of the same numeric alias after a
# successful deletion. Unlimited churn, failed deletion and baseline-ID reuse
# must stop with the source untouched and a bounded number of firmware writes.
for scenario in once forever delete_error collision changed_after_order enum_error; do
    (
        source_effective_stack
        PENDING_SOURCE=refind; PENDING_TARGET=limine; PENDING_PHASE=runtime-validated
        PENDING_TARGET_BOOT_ID=0002; PENDING_OLD_BOOT_ID=0000; BOOT_CURRENT=0004
        MOCK_PRIMARY='0002 0005'; MOCK_FALLBACK='0004'; MOCK_ORDER='0002,0004,0000,0005,0007'
        deletes=0; writes=0; identity_changed=0
        leap16_r80_require_baseline(){ return 0; }
        leap16_r64_limine_fallback_staged(){ return 0; }
        leap16_r64_limine_fallback_id(){ printf '0004\n'; }
        leap16_r80_id_existed_in_baseline(){ [[ $scenario == collision && $1 == 0005 ]]; }
        leap16_nvram_entry_matches_current_esp(){ [[ $identity_changed == 0 || $1 != 0005 ]]; }
        nvram_id_matches_path(){ [[ $identity_changed == 0 || $1 != 0005 ]]; }
        leap16_r80_current_ids_for_path(){
            [[ $scenario != enum_error ]] || return 1
            if [[ $1 == "$LEAP16_R80_LIMINE_PRIMARY_PATH" ]]; then printf '%s\n' $MOCK_PRIMARY; else printf '%s\n' $MOCK_FALLBACK; fi
        }
        boot_id_exists(){ case " $MOCK_PRIMARY $MOCK_FALLBACK 0000 0007 " in *" $1 "*) return 0;; *) return 1;; esac; }
        leap16_current_boot_order(){ printf '%s\n' "$MOCK_ORDER"; }
        sudo(){
            [[ $1 == efibootmgr ]] || fail_test 'unexpected external mutation'
            shift
            if [[ $1 == -o ]]; then
                MOCK_ORDER=$2; writes=$((writes+1))
                [[ $scenario != changed_after_order ]] || identity_changed=1
                return 0
            fi
            [[ $1 == -b && $2 == 0005 && $3 == -B ]] || fail_test 'deleted an unowned firmware identity'
            ! leap16_order_has_id "$MOCK_ORDER" 0005 || fail_test 'deleted alias before removing it from BootOrder'
            deletes=$((deletes+1))
            [[ $scenario != delete_error ]] || return 1
            MOCK_PRIMARY=0002
            if [[ $scenario == forever || ( $scenario == once && $deletes == 1 ) ]]; then
                MOCK_PRIMARY='0002 0005'; MOCK_ORDER="$MOCK_ORDER,0005"
            fi
            return 0
        }
        ok(){ :; }; fail(){ :; }
        if [[ $scenario == once ]]; then
            leap16_r80_normalize_limine_aliases_after_fallback_proof || fail_test 'one alias re-synthesis wave did not converge'
            [[ $deletes == 2 && $MOCK_PRIMARY == 0002 && $MOCK_ORDER == 0002,0004,0000,0007 ]] \
                || fail_test 'bounded normalization lost recovery or unrelated entries'
        else
            ! leap16_r80_normalize_limine_aliases_after_fallback_proof || fail_test "unsafe alias scenario passed: $scenario"
            ((deletes<=2 && writes<=2)) || fail_test 'alias cleanup exceeded its fixed pass budget'
            if [[ $scenario == collision || $scenario == enum_error ]]; then
                [[ $deletes == 0 && $writes == 0 ]] || fail_test 'mutation preceded complete ownership classification'
            fi
            [[ $scenario != changed_after_order || $deletes == 0 ]] || fail_test 'alias was deleted after its identity changed'
        fi
    )
done
printf 'leap16-r81 selftest: PASS\n'
