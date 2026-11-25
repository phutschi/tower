#!/usr/bin/env bash
# Prints the last lines of a lane or Reviewer agent's pane, or of the run's
# dev pane, through the runner.
#
#   read-pane.sh <run-dir> <agent> [<lines>]
#   read-pane.sh <run-dir> --dev [<lines>]      lines: default 60, at most 120
#
# An agent's pane is found as send-brief.sh finds it (common.sh bound_pane):
# its one lane or Reviewer line, bound to the kit's launch record. The dev
# pane is the one bootstrap.sh put in that record: lanes read it with --dev.
# Nothing in the pane map is run: a lane can write it, and its read a pane:
# line is for people. More than 120 lines are refused on every runner (Orca
# keeps no more in a read). Exit 1, saying why, when the pane cannot be read.
#
# Never run this for real to see what it does; use DRY_RUN=1, which answers
# every herdr and orca call from tests/stub.
set -euo pipefail
KIT="$(cd "$(dirname "$0")" && pwd)"
. "$KIT/common.sh"
need_runner; need python3
USAGE='usage: read-pane.sh <run-dir> <agent>|--dev [<lines>]'
[ $# -eq 2 ] || [ $# -eq 3 ] || die "$USAGE"
RUN_DIR="$1"; NAME="$2"; LINES="${3:-60}"
[[ "$LINES" =~ ^[1-9][0-9]*$ ]] || die "$USAGE"
[ "$LINES" -le 120 ] || die "read-pane: at most 120 lines (asked for $LINES)"
[ -f "$RUN_DIR/panes.txt" ] || die "read-pane: no pane map at $RUN_DIR/panes.txt"
if [ "$NAME" = --dev ]; then
  read -r _ PANE <<< "$(launched "$RUN_DIR" @dev)"
  [ -n "$PANE" ] || die "read-pane: the kit has no dev pane on record for $RUN_DIR"
  runner_pane_tail "$PANE" "$LINES" && exit 0
  die "read-pane: $(runner_name) could not read the dev pane $PANE"
fi
PANE=$(bound_pane "$RUN_DIR" "$NAME" 2>&1) || die "read-pane: $PANE"
runner_agent_tail "$NAME" "$PANE" "$LINES" && exit 0
rc=0; runner_pane_exists "$PANE" 2>/dev/null || rc=$?
[ "$rc" != 3 ] || { stale_handle "$NAME" "$PANE" "its line" "" "$NAME"; exit 1; }
die "read-pane: $(runner_name) could not read $NAME's pane $PANE"
