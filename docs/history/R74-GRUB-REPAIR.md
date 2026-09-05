# leap16-r74 — GRUB repair PTY child dispatch fix

The first r73 hardware attempt reached the `repair-grub-to-grub` transcript
wrapper but stopped before preflight with exit 2:

`Refusing unknown r46 transcript child command: leap16_r73_run_repair_inner`

r46 deliberately launches modifying operations in a fresh process under a PTY
and accepts only named transaction executors. r73 added the parent repair route
but did not extend that fresh-child allowlist. r74 adds exactly
`leap16_r73_run_repair_inner`, additionally requiring the fixed contract
`grub -> grub`, kind `repair`, and zero executor arguments. Every arbitrary or
malformed child command remains rejected.

No r73 reconstruction, validation, rollback, EFI, or NVRAM behavior changes.
The failed r73 attempt made no boot-state modification.
