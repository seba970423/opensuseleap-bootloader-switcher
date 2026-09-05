#!/usr/bin/env bash
# leap16-r84: repair the r80 pre-stage Boot#### existence predicate exposed by
# the first successful rEFInd -> Limine fallback hardware proof.
#
# r80 used `grep ... | head -n1` and relied on the pipeline status to answer
# whether a numeric Boot#### existed in the immutable pre-stage firmware table.
# The switcher intentionally runs with `set -u`, not global `pipefail`; when grep
# found no line, head still returned success.  Consequently every queried ID was
# classified as pre-existing.  After fallback proof #2, the genuinely post-stage
# canonical Limine Boot#### was therefore rejected as a recycled baseline ID.
#
# Preserve the r80 ownership policy exactly.  Only make the predicate's return
# status independent of shell pipefail state by using grep's native -m1 limit.
leap16_r80_baseline_line_for_id() {
    local id=${1^^} baseline
    [[ $id =~ ^[0-9A-F]{4}$ ]] || return 1
    baseline=$(leap16_r64_baseline_path 2>/dev/null || true)
    [[ -n $baseline && -s $baseline ]] || return 1
    grep -Eim1 "^Boot${id}\\*?[[:space:]]" "$baseline"
}

leap16_r64_print_matrix() {
    cat <<'MATRIX'
openSUSE Leap 16 bootloader matrix — leap16-r84

Legend:
  HW-PROVEN       completed automatically on real hardware with exact final topology
  HW-PENDING      implemented; complete hardware evidence still required
  —               same-backend; not a cross-loader edge

LIVE SWITCH MATRIX (source rows -> target columns)
                 GRUB2        Limine       systemd-boot  rEFInd
  GRUB2          —            HW-PROVEN    HW-PROVEN     HW-PROVEN
  Limine         HW-PROVEN    —            HW-PROVEN     HW-PROVEN
  systemd-boot   HW-PROVEN    HW-PROVEN    —             HW-PENDING
  rEFInd         HW-PROVEN    HW-PENDING   HW-PENDING    —

CROSS-LOADER RESTORE MATRIX (active source -> restored backup target)
                 GRUB2        Limine       systemd-boot  rEFInd
  GRUB2          —            HW-PROVEN    HW-PROVEN     HW-PROVEN
  Limine         HW-PROVEN    —            HW-PROVEN     HW-PENDING
  systemd-boot   HW-PROVEN    HW-PROVEN    —             HW-PENDING
  rEFInd         HW-PROVEN    HW-PENDING   HW-PENDING    —

BACKUP BACKENDS
  GRUB2          HW-PROVEN
  Limine         HW-PROVEN
  systemd-boot   HW-PROVEN
  rEFInd         HW-PROVEN

r84 evidence scope:
  - Sep 5 r83 hardware reached exact fallback BootCurrent=Boot0002 and passed the
    complete second Limine runtime proof while canonical rEFInd recovery remained intact.
  - Finalization then failed before source retirement because r80's baseline-ID
    predicate returned success for a missing Boot0000 when pipefail was disabled.
  - r84 fixes only that predicate's shell-status contract; baseline identity,
    duplicate ownership, exact topology and source-retirement gates are unchanged.
  - rEFInd -> Limine now has two hardware-proven boot identities, but the live
    edge remains HW-PENDING until r84 completes ownership-gated rEFInd retirement.
  - Neither Limine/rEFInd restore direction is promoted by this evidence.
MATRIX
}
