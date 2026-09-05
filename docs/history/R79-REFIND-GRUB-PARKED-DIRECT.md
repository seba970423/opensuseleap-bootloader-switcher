# leap16-r79 — rEFInd -> GRUB parked direct-alias finalization fix

Hardware evidence from the r78 automatic run showed a valid runtime-proven native GRUB shim target with:

- source rEFInd: Boot0000
- runtime-proven shim target: Boot0002
- transaction-recorded direct GRUB recovery: Boot0001, deliberately parked outside BootOrder until final normalization
- firmware-synthesized same-path direct GRUB alias: Boot0003
- runtime BootOrder: `0000,0002,0003`; after target promotion: `0002,0000,0003`

r77/r78 correctly bounded Boot0003 by exact path + ESP + absence from the complete pre-stage firmware baseline, but then incorrectly required Boot0001 to already be represented in BootOrder before calling the final-order function. That contradicts the transaction contract: Boot0001 is intentionally parked until finalization itself installs the canonical `shim,direct` prefix.

r79 keeps every ownership gate but permits the recorded exact direct-GRUB alias to remain parked outside BootOrder during duplicate removal. It removes ownership-bounded post-stage duplicates from BootOrder first, deletes them, proves the remaining alias set is exactly the recorded direct alias, then lets the inherited final-order function install `shim,direct` and retire rEFInd from persistent order.

The r78 failed finalization remains recoverable in `runtime-validated` state. r79 is intended to continue that existing transaction without another reboot and without manual `efibootmgr` cleanup.

Hardware status:

- GRUB2 -> rEFInd: automatic end-to-end runtime proof and finalization succeeded under r78; HW-PROVEN.
- rEFInd -> GRUB2: runtime proof succeeded automatically under r78; finalization stopped fail-closed at the parked-direct assertion. Fresh automatic end-to-end rerun remains required after r79 before marking the edge HW-PROVEN.
