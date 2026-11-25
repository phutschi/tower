#!/usr/bin/env bash
# Records an agent's terminal in the kit's launch record, by hand.
#
#   bind-pane.sh <run-dir> <agent> <pane>
#
# For the operator: after rebinding a lane or Reviewer whose handle went stale
# (Orca restarted; the kit's message says so), or when a start could not
# write its record. Run it once you have seen <agent> in <pane>: send-brief.sh
# and read-pane.sh trust the record, which lives outside the run dir, where
# a lane cannot write it (common.sh launch_record). The agent's one lane or
# Reviewer line in <run-dir>/panes.txt must name the same pane, and the
# runner must say it is open. It starts nothing and sends nothing.
#
# Never run this for real to see what it does; use DRY_RUN=1, which answers
# every herdr and orca call from tests/stub.
set -euo pipefail
KIT="$(cd "$(dirname "$0")" && pwd)"
. "$KIT/common.sh"
need_runner; need python3
[ $# -eq 3 ] || die 'usage: bind-pane.sh <run-dir> <agent> <pane>'
RUN_DIR="$1"; NAME="$2"; PANE="$3"; MAP="$RUN_DIR/panes.txt"
[ -f "$MAP" ] || die "bind-pane: no pane map at $MAP"
mapped=$(agent_pane "$MAP" "$NAME" 2>&1) || die "bind-pane: $mapped"
[ "$mapped" = "$PANE" ] || die "bind-pane: the pane map gives $NAME pane $mapped, not $PANE: put $PANE on its line in $MAP first; nothing recorded"
rc=0; runner_pane_exists "$PANE" 2>/dev/null || rc=$?
[ "$rc" = 0 ] || die "bind-pane: $(runner_name) does not say $PANE is open; nothing recorded"
err=$(launch_append "$RUN_DIR" "$NAME" "$PANE" 2>&1) || die "bind-pane: $err"
echo "recorded $NAME in $PANE: send-brief.sh and read-pane.sh reach it there"
