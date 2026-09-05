# leap16-r68 rEFInd matrix / hardware ledger

The previously hardware-proven three-loader matrix is unchanged: all 6/6 directed live edges and all 6/6 directed cross-loader restore edges among GRUB2, Limine, and systemd-boot remain HW-PROVEN.

All six live and six restore edges involving rEFInd remain IMPLEMENTED / HW-PENDING until ownership-gated finalization completes on real hardware.

## rEFInd hardware attempts

- r64 GRUB2 -> rEFInd: SAFE-FAIL before candidate commit — malformed zypper option scope.
- r65 GRUB2 -> rEFInd: SAFE-FAIL before candidate commit — configured Leap repositories expose no `refind` provider.
- r66 GRUB2 -> rEFInd: SAFE-FAIL before candidate commit — controlled upstream 0.14.2 staging succeeded; stale mkinitcpio validator rejected Leap dracut initrds.
- r67 GRUB2 -> rEFInd: DIRECT BOOT TO USERSPACE PROVEN; automatic resume SAFE-FAILED before runtime certification/source cleanup because inbound rEFInd was dispatched into the historical Limine-only runtime validator.
- r68 GRUB2 -> rEFInd: continuation/runtime-finalization HW-PENDING.

## r68 proof corrections

1. Inbound `GRUB2|Limine|systemd-boot -> rEFInd` gets a dedicated Leap-native runtime validator.
2. `PreviousBoot` accepts exact `vmlinuz-$(uname -r)` or the observed `\\boot\\vmlinuz` menu path only if `/boot/vmlinuz` resolves to the exact running versioned payload.
3. Protected source EFI chainload evidence remains an unconditional reject.
4. Source recovery is passive under rEFInd BootCurrent: exact source Boot#### path/ESP, EFI hash, ownership manifest, fallback state, and baseline source-path representation are required; no active-source validator is called.
5. Post-stage duplicate canonical rEFInd target aliases are removable only after direct-kernel proof, only when exact same-path/same-ESP, and only when their numeric IDs were absent from the pre-stage firmware baseline.
6. The duplicate-target gate is run again after final target promotion before source retirement, covering firmware churn induced by the BootOrder write itself.

## Matrix status

| Source \\ Target | GRUB2 | Limine | systemd-boot | rEFInd |
|---|---|---|---|---|
| GRUB2 | — | HW-PROVEN | HW-PROVEN | HW-PENDING (r67 direct boot to userspace proven) |
| Limine | HW-PROVEN | — | HW-PROVEN | HW-PENDING |
| systemd-boot | HW-PROVEN | HW-PROVEN | — | HW-PENDING |
| rEFInd | HW-PENDING | HW-PENDING | HW-PENDING | — |

Restore status has the same shape. rEFInd backup remains HW-PENDING until the first finalized rEFInd source is backed up and restored on hardware.
