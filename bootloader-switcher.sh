#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SWITCHER_RELEASE="leap16-r86"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/storage.sh"
source "$SCRIPT_DIR/lib/detect.sh"
source "$SCRIPT_DIR/lib/kernels.sh"
source "$SCRIPT_DIR/lib/validate.sh"
source "$SCRIPT_DIR/lib/limine_validate.sh"
source "$SCRIPT_DIR/lib/grub_validate.sh"
source "$SCRIPT_DIR/lib/systemd_boot_validate.sh"
source "$SCRIPT_DIR/lib/refind_validate.sh"
source "$SCRIPT_DIR/lib/backup.sh"

bootloader_display_name() {
    case "$1" in
        grub) printf 'GRUB2' ;;
        limine) printf 'Limine' ;;
        refind) printf 'rEFInd' ;;
        systemd-boot) printf 'systemd-boot' ;;
        *) printf '%s' "$1" ;;
    esac
}

source "$SCRIPT_DIR/lib/operations.sh"
source "$SCRIPT_DIR/lib/staged.sh"
source "$SCRIPT_DIR/lib/r21.sh"
source "$SCRIPT_DIR/lib/r22.sh"
source "$SCRIPT_DIR/lib/r23.sh"
source "$SCRIPT_DIR/lib/restore.sh"
source "$SCRIPT_DIR/lib/r25.sh"
source "$SCRIPT_DIR/lib/r26.sh"
source "$SCRIPT_DIR/lib/r27.sh"
source "$SCRIPT_DIR/lib/r28.sh"
source "$SCRIPT_DIR/lib/r29.sh"
source "$SCRIPT_DIR/lib/r30.sh"
source "$SCRIPT_DIR/lib/r31.sh"
source "$SCRIPT_DIR/lib/r32.sh"
source "$SCRIPT_DIR/lib/r33.sh"
source "$SCRIPT_DIR/lib/r34.sh"
source "$SCRIPT_DIR/lib/r35.sh"
source "$SCRIPT_DIR/lib/r36.sh"
source "$SCRIPT_DIR/lib/r37.sh"
source "$SCRIPT_DIR/lib/r38.sh"
source "$SCRIPT_DIR/lib/r39.sh"
source "$SCRIPT_DIR/lib/r40.sh"
source "$SCRIPT_DIR/lib/r41.sh"
source "$SCRIPT_DIR/lib/r42.sh"
source "$SCRIPT_DIR/lib/r43.sh"
source "$SCRIPT_DIR/lib/r44.sh"
source "$SCRIPT_DIR/lib/r45.sh"
source "$SCRIPT_DIR/lib/r46.sh"
source "$SCRIPT_DIR/lib/r47.sh"
source "$SCRIPT_DIR/lib/opensuse_leap16.sh"
source "$SCRIPT_DIR/lib/leap16_r21.sh"
source "$SCRIPT_DIR/lib/leap16_r22.sh"
source "$SCRIPT_DIR/lib/leap16_r23.sh"
source "$SCRIPT_DIR/lib/leap16_r24.sh"
source "$SCRIPT_DIR/lib/leap16_r25.sh"
source "$SCRIPT_DIR/lib/leap16_r26.sh"
source "$SCRIPT_DIR/lib/leap16_r27.sh"
source "$SCRIPT_DIR/lib/leap16_r28.sh"
source "$SCRIPT_DIR/lib/leap16_r29.sh"
source "$SCRIPT_DIR/lib/leap16_r30.sh"
source "$SCRIPT_DIR/lib/leap16_r31.sh"
source "$SCRIPT_DIR/lib/leap16_r32.sh"
source "$SCRIPT_DIR/lib/leap16_r33.sh"
source "$SCRIPT_DIR/lib/leap16_r34.sh"
source "$SCRIPT_DIR/lib/leap16_r35.sh"
source "$SCRIPT_DIR/lib/leap16_r36.sh"
source "$SCRIPT_DIR/lib/leap16_r37.sh"
source "$SCRIPT_DIR/lib/leap16_r38.sh"
source "$SCRIPT_DIR/lib/leap16_r39.sh"
source "$SCRIPT_DIR/lib/leap16_r40.sh"
source "$SCRIPT_DIR/lib/leap16_r41.sh"
source "$SCRIPT_DIR/lib/leap16_r42.sh"
source "$SCRIPT_DIR/lib/leap16_r43.sh"
source "$SCRIPT_DIR/lib/leap16_r44.sh"
source "$SCRIPT_DIR/lib/leap16_r45.sh"
source "$SCRIPT_DIR/lib/leap16_r46.sh"
source "$SCRIPT_DIR/lib/leap16_r47.sh"
source "$SCRIPT_DIR/lib/leap16_r48.sh"
source "$SCRIPT_DIR/lib/leap16_r49.sh"
source "$SCRIPT_DIR/lib/leap16_r50.sh"
source "$SCRIPT_DIR/lib/leap16_r51.sh"
source "$SCRIPT_DIR/lib/leap16_r52.sh"
source "$SCRIPT_DIR/lib/leap16_r53.sh"
source "$SCRIPT_DIR/lib/leap16_r54.sh"
source "$SCRIPT_DIR/lib/leap16_r55.sh"
source "$SCRIPT_DIR/lib/leap16_r56.sh"
source "$SCRIPT_DIR/lib/leap16_r57.sh"
source "$SCRIPT_DIR/lib/leap16_r58.sh"
source "$SCRIPT_DIR/lib/leap16_r59.sh"
source "$SCRIPT_DIR/lib/leap16_r60.sh"
source "$SCRIPT_DIR/lib/leap16_r61.sh"
source "$SCRIPT_DIR/lib/leap16_r62.sh"
source "$SCRIPT_DIR/lib/leap16_r63.sh"
source "$SCRIPT_DIR/lib/leap16_r64.sh"
source "$SCRIPT_DIR/lib/leap16_r65.sh"
source "$SCRIPT_DIR/lib/leap16_r66.sh"
source "$SCRIPT_DIR/lib/leap16_r67.sh"
source "$SCRIPT_DIR/lib/leap16_r68.sh"
source "$SCRIPT_DIR/lib/leap16_r69.sh"
source "$SCRIPT_DIR/lib/leap16_r70.sh"
source "$SCRIPT_DIR/lib/leap16_r71.sh"
source "$SCRIPT_DIR/lib/leap16_r72.sh"
source "$SCRIPT_DIR/lib/leap16_r73.sh"
source "$SCRIPT_DIR/lib/leap16_r74.sh"
source "$SCRIPT_DIR/lib/leap16_r75.sh"
source "$SCRIPT_DIR/lib/leap16_r76.sh"
source "$SCRIPT_DIR/lib/leap16_r77.sh"
source "$SCRIPT_DIR/lib/leap16_r78.sh"
source "$SCRIPT_DIR/lib/leap16_r79.sh"
source "$SCRIPT_DIR/lib/leap16_r80.sh"
source "$SCRIPT_DIR/lib/leap16_r81.sh"
source "$SCRIPT_DIR/lib/leap16_r82.sh"
source "$SCRIPT_DIR/lib/leap16_r83.sh"
source "$SCRIPT_DIR/lib/leap16_r84.sh"
source "$SCRIPT_DIR/lib/leap16_r85.sh"
source "$SCRIPT_DIR/lib/leap16_r86.sh"

select_target_bootloader() {
    local choice target current_name
    detect_bootloader
    current_name=$(bootloader_display_name "$BOOTLOADER")

    while true; do
        printf '\nCurrent bootloader: %s\n\n' "$current_name"
        printf 'Select target bootloader:\n\n'
        printf '[1] GRUB2%s\n' "$([[ $BOOTLOADER == grub ]] && printf ' (repair/reinstall)' || true)"
        printf '[2] Limine%s\n' "$([[ $BOOTLOADER == limine ]] && printf ' (current)' || true)"
        printf '[3] systemd-boot%s\n' "$([[ $BOOTLOADER == systemd-boot ]] && printf ' (current)' || true)"
        printf '[4] rEFInd%s\n' "$([[ $BOOTLOADER == refind ]] && printf ' (current)' || true)"
        printf '[5] Back\n\n'
        read -r -p 'Select a bootloader: ' choice
        [[ -n $choice ]] || { printf '\nPlease select an option.\n'; continue; }

        case "$choice" in
            1) target=grub ;;
            2) target=limine ;;
            3) target=systemd-boot ;;
            4) target=refind ;;
            5) return 0 ;;
            *) printf '\nInvalid selection.\n'; continue ;;
        esac

        printf '\nSelected target: %s\n' "$(bootloader_display_name "$target")"
        if [[ $target == "$BOOTLOADER" ]]; then
            if [[ $target == grub ]]; then
                printf 'Planned operation: repair/reinstall current bootloader\n'
            elif [[ $target == limine ]]; then
                printf 'Planned operation: validate/expose finalized Limine EFI fallback menu entry\n'
            else
                printf 'Planned operation: current-bootloader repair is not enabled for %s yet\n' "$(bootloader_display_name "$target")"
            fi
        else
            printf 'Planned operation: staged switch %s -> %s\n' "$current_name" "$(bootloader_display_name "$target")"
        fi
        run_live_operation "$target"
        return $?
    done
}

main_menu() {
    local choice

    while true; do
        clear 2>/dev/null || true
        printf 'openSUSE Bootloader Switcher — %s\n\n' "$SWITCHER_RELEASE"
        print_system_report
        printf '\n'
        pending_banner
        pending_exists && printf '\n'
        r22_show_last_auto_result
        discover_backups_quiet
        if ((${#DISCOVERED_BACKUPS[@]} > 0)); then
            printf 'Detected backups: %d\n' "${#DISCOVERED_BACKUPS[@]}"
        else
            printf 'Detected backups: none\n'
        fi
        printf '\n'
        printf '[1] Select bootloader to switch/repair\n'
        printf '[2] Manage pending/staged migration\n'
        printf '[3] Create backup of currently booted bootloader\n'
        printf '[4] List and validate backups\n'
        printf '[5] Restore a validated backup\n'
        printf '[6] Show restore plan for a backup (read-only)\n'
        printf '[7] Deep-validate current boot chain (read-only)\n'
        printf '[8] Refresh detection\n'
        printf '[9] Exit\n\n'
        read -r -p 'Select an option: ' choice
        [[ -n $choice ]] || continue

        case "$choice" in
            1) select_target_bootloader; pause ;;
            2) manage_pending_migration; pause ;;
            3) create_current_bootloader_backup_interactive; pause ;;
            4) list_backups_interactive; pause ;;
            5) restore_backup_interactive; pause ;;
            6) restore_plan_interactive; pause ;;
            7)
                detect_bootloader
                case "$BOOTLOADER" in
                    limine) run_validation preflight && validate_limine_boot_chain current && { if grep -Fqx "# CachyOS Limine theme" "${ESP_MOUNT:-/boot}/limine.conf" 2>/dev/null; then validate_cachyos_limine_theme; else true; fi; } ;;
                    grub) run_validation preflight && validate_grub_boot_chain current ;;
                    systemd-boot) run_validation preflight && leap16_r34_validate_systemd_boot_chain current ;;
                    refind) run_validation preflight && validate_refind_boot_chain current ;;
                    *) printf '\nA deep boot-chain validator is not implemented for %s yet.\n' "$(bootloader_display_name "$BOOTLOADER")" ;;
                esac
                pause
                ;;
            8) : ;;
            9) exit 0 ;;
            *) printf '\nInvalid selection.\n'; pause ;;
        esac
    done
}

if [[ ${1:-} != --help && ${1:-} != -h ]] && ! is_leap16; then
    die 'This port targets openSUSE Leap 16.x only.'
fi

if [[ ${EUID:-$(id -u)} -eq 0 && ${1:-} != --resume-transaction-root ]]; then
    printf 'Do not run the whole tool as root. Run it as your normal user.\n' >&2
    printf 'Modifying operations elevate only the commands that need it.\n' >&2
    exit 1
fi

case "${1:-}" in
    --r46-transcript-child)
        shift
        leap16_r46_transcript_child "$@"
        ;;
    --resume-transaction-root)
        [[ ${EUID:-$(id -u)} -eq 0 ]] || die '--resume-transaction-root is an internal root-only automatic-resume action'
        r22_resume_transaction_root
        ;;
    --report) print_system_report ;;
    --validate) run_validation passive ;;
    --list-backups) list_backups ;;
    --validate-limine)
        detect_bootloader
        run_validation preflight && validate_limine_boot_chain current
        ;;
    --validate-grub)
        detect_bootloader
        run_validation preflight && validate_grub_boot_chain current
        ;;
    --validate-systemd-boot)
        detect_bootloader
        run_validation preflight && leap16_r34_validate_systemd_boot_chain current
        ;;
    --validate-refind)
        detect_bootloader
        run_validation preflight && validate_refind_boot_chain current
        ;;
    --manage-staged) manage_pending_migration ;;
    --matrix) leap16_r64_print_matrix ;;
    --help|-h)
        cat <<'HELP'
Usage: ./bootloader-switcher.sh [OPTION]

Transactional bootloader migration and backup restoration for openSUSE Leap 16.x.
Supported bootloaders: GRUB2, Limine, systemd-boot, rEFInd.

Without options, opens the interactive menu.

  --report                 print passive system/bootloader detection
  --validate               run passive validation checks
  --validate-grub          deep-validate native openSUSE GRUB2
  --validate-limine        deep-validate current/staged Limine
  --validate-systemd-boot  deep-validate native openSUSE systemd-boot
  --validate-refind        deep-validate Leap-native rEFInd direct-kernel policy
  --manage-staged          manage/resume the active staged transaction
  --list-backups           list and validate user backups
  --matrix                 print the current hardware-proven live/restore matrix
  --help                   show this help

Safety contract:
  - run the tool as a normal user; privileged writes are elevated individually
  - the working source remains recovery until the target earns runtime proof
  - source retirement is ownership-gated and happens only after target finalization
  - restore targets must earn fresh runtime proof; old backup evidence is not reused
  - Limine requires canonical + independent EFI/BOOT hardware proofs
  - rEFInd requires fresh PreviousBoot direct-kernel evidence and does not claim EFI/BOOT
  - firmware alias cleanup is bounded by the complete pre-stage firmware baseline
  - failed gates stop closed; manual NVRAM/ESP cleanup is not an accepted success path

Do not manually modify BootOrder, BootNext, or source EFI state during a staged transaction.
See README.md and docs/ for the full architecture, matrix, restore and troubleshooting guides.
HELP
        ;;
    '') main_menu ;;
    *) die "Unknown option: $1" ;;
esac
