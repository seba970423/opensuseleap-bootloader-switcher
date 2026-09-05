#!/usr/bin/env bash
# r46: align the cross-backend restore support predicate with the actual
# interactive restore dispatcher.
#
# Sequential matrix auditing exposed that GRUB -> restored rEFInd had been
# functionally implemented and hardware-proven since r35, and continued to be
# dispatched through r38_restore_refind_backup(), but the auxiliary
# r30_cross_restore_supported() predicate never learned grub:refind.  Later
# layers added the other rEFInd restore pairs and r44 added refind:grub, leaving
# the predicate at 11/12 even though the dispatcher itself covered all 12.
#
# This is a consistency repair only.  It does not add a new restore backend,
# dispatcher route, pending-state direction, payload format, write path, or
# finalization engine.  The strict r35/r38 rEFInd target preflight remains the
# authority for GRUB -> restored rEFInd.

eval "$(declare -f r30_cross_restore_supported | sed '1s/r30_cross_restore_supported/r30_cross_restore_supported_pre_r46/')"
r30_cross_restore_supported() {
    case "$1:$2" in
        grub:refind) return 0 ;;
        *) r30_cross_restore_supported_pre_r46 "$@" ;;
    esac
}
