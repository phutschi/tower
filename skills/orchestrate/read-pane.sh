#!/usr/bin/env bash
# Prints the last lines of a lane or Reviewer agent's pane, through the runner.
#
#   read-pane.sh <run-dir> <agent> [<lines>]   lines: default 60
#
# The pane is found as send-brief.sh finds it (common.sh bound_pane): the
# agent's one lane or Reviewer line, bound to the kit's launch record.
# Nothing in the pane map is run: a lane can write it, and its read a pane:
# line is for people. Exit 1, saying why, when the agent cannot be read.
#
# Never run this for real to see what it does; use DRY_RUN=1, which answers
# every herdr and orca call from tests/stub.
set -euo pipefail
KIT="$(cd "$(dirname "$0")" && pwd)"
. "$KIT/common.sh"
need_runner; need python3
USAGE='usage: read-pane.sh <run-dir> <agent> [<lines>]'
[ $# -eq 2 ] || [ $# -eq 3 ] || die "$USAGE"
RUN_DIR="$1"; NAME="$2"; LINES="${3:-60}"
[[ "$LINES" =~ ^[1-9][0-9]*$ ]] || die "$USAGE"
[ -f "$RUN_DIR/panes.txt" ] || die "read-pane: no pane map at $RUN_DIR/panes.txt"
PANE=$(bound_pane "$RUN_DIR" "$NAME" 2>&1) || die "read-pane: $PANE"
runner_agent_tail "$NAME" "$PANE" "$LINES" && exit 0
rc=0; runner_pane_exists "$PANE" 2>/dev/null || rc=$?
[ "$rc" != 3 ] || { stale_handle "$NAME" "$PANE" "its line"; exit 1; }
die "read-pane: $(runner_name) could not read $NAME's pane $PANE"
