# leap16-r80 — Limine ↔ rEFInd live + restore pre-hardware hardening

## Scope

The r64 adapter already enabled all four requested paths:

- Limine → rEFInd live switch
- rEFInd → Limine live switch
- Limine → restored rEFInd backup
- rEFInd → restored Limine backup

r80 keeps those transaction engines and hardens the firmware-ownership boundaries before the first complete hardware campaign for this pair. Current alias enumeration is also fail-closed: an enumeration error is never reinterpreted as an empty alias set.

## Why another revision before hardware

The GRUB ↔ rEFInd campaign proved that the ASUS firmware can synthesize or renumber equivalent Boot#### aliases during a real one-shot boot/fallback transition. Two lessons are applied here before Limine testing:

1. path+ESP equality is not enough to claim a Boot#### if that numeric ID existed in the pre-stage table for an unrelated path;
2. finalization must require the *complete* final alias topology, not merely a correct BootOrder prefix.

## r80 changes

### Limine → rEFInd

At source retirement, every current same-ESP alias for canonical Limine or Limine EFI/BOOT must be either:

- a source-owned alias from the pre-stage firmware table, or
- a Boot#### ID that did not exist before staging.

If a current source-path alias reuses a pre-stage ID that belonged to an unrelated path, retirement fails closed. The existing direct-kernel rEFInd runtime proof and immutable source manifest gates remain unchanged.

### rEFInd → Limine

The established two-proof contract remains unchanged:

1. canonical Limine BootCurrent proof;
2. byte-identical `EFI/BOOT/BOOTX64.EFI` Limine fallback BootCurrent proof.

After proof #2, r80 additionally:

- ownership-bounds duplicate canonical-Limine and generic-fallback aliases against the complete pre-stage firmware table;
- removes those duplicates from BootOrder before deleting them;
- requires every deletion to succeed;
- requires exactly one canonical Limine alias and exactly one recorded fallback alias before rEFInd source retirement;
- repeats bounded normalization after source retirement and re-proves the exact final topology before recording success.

### Fallback-transfer rollback

If proof #2 is not obtained, rollback now strictly removes only fallback aliases whose Boot#### IDs were absent before staging, refuses baseline-ID collisions, restores the original fallback bytes/absence, and requires the final fallback alias set to equal the pre-stage set.

### Backup restore

No separate weaker restore code was added. The existing r64 restore dispatchers feed the selected validated backup into the same target staging/runtime/finalization engines, so all r80 ownership gates apply to both live and restore directions.

## Hardware status entering r80

- GRUB2 → rEFInd live: **HW-PROVEN**
- rEFInd → GRUB2 live: **HW-PROVEN**
- GRUB2 → restored rEFInd: **HW-PROVEN**
- rEFInd → restored GRUB2: **HW-PROVEN**
- Limine ↔ rEFInd live: **HW-PENDING**
- Limine ↔ rEFInd restore: **HW-PENDING**

No Limine/rEFInd edge is advanced to HW-PROVEN by code or selftests alone.
