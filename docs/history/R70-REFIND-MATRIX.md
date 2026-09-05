# leap16-r70 rEFInd backup audit

## Hardware state entering r70

- GRUB2 -> rEFInd direct-kernel runtime proof: hardware-observed.
- GRUB2 -> rEFInd ownership-gated finalization: hardware-observed successful under r69.
- First finalized-rEFInd backup attempt: SAFE-FAIL before any rEFInd -> GRUB2 staging.
- Firmware at the failed backup boundary remained finalized rEFInd only (`BootCurrent=Boot0005`, `BootOrder=0005`).

## r69 backup failure root cause

The r64 rEFInd backup validator used:

```bash
[[ ${boot_efi_path,,} == ${LEAP16_R64_REFIND_EFI,,} ]]
```

Inside `[[ ... == ... ]]`, an unquoted RHS is a Bash pattern. Raw UEFI path backslashes therefore acted as pattern escapes. The decoded metadata and the canonical constant were byte-identical (`\\EFI\\refind\\refind_x64.efi`) but the comparison returned false.

The backup payload was not the problem; the equality expression was.

## r70 correction

- Introduces a literal case-insensitive EFI-path comparator with a quoted RHS.
- Re-states only the effective rEFInd `validate_backup()` branch; non-rEFInd backups delegate unchanged to r69.
- Keeps the r64 schema, r66 controlled-binary identity marker, r67 `follow_symlinks` requirement, immutable-tree rules, and `vars/PreviousBoot` exclusion unchanged.
- Adds an exact regression reproducing the Bash backslash-pattern failure and proving metadata serialization -> decoding -> rEFInd self-validation succeeds.

## Safety result of the failed attempt

The diagnostic transcript recorded `stage_exit=1`. Backup failure cancelled the operation before target GRUB staging, and no bootloader state was modified.
