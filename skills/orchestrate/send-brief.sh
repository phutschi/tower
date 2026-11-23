#!/usr/bin/env bash
# Sends a brief or a fix prompt to a lane or Reviewer agent through the runner.
#
#   send-brief.sh <run-dir> <agent> <brief-file>
#
# The agent's pane is its one lane or Reviewer line in <run-dir>/panes.txt
# (common.sh agent_pane); nothing else in the map is read, and nothing in it
# is run: a lane can write the run dir. The pane must be open; the runner then
# sends the file's text as one prompt (runner_send_message), Orca only to an
# agent it lists as ready. Otherwise nothing is sent: exit 1, saying why.
#
# Never run this for real to see what it does; use DRY_RUN=1, which answers
# every herdr and orca call from tests/stub and sends nothing.
set -euo pipefail
KIT="$(cd "$(dirname "$0")" && pwd)"
. "$KIT/common.sh"
need_runner
[ $# -eq 3 ] || die 'usage: send-brief.sh <run-dir> <agent> <brief-file>'
RUN_DIR="$1"; NAME="$2"; BRIEF="$3"; MAP="$RUN_DIR/panes.txt"
[ -f "$MAP" ] || die "send-brief: no pane map at $MAP"
[ -s "$BRIEF" ] || die "send-brief: no brief, or an empty one, at $BRIEF"
PANE=$(agent_pane "$MAP" "$NAME" 2>&1) || die "send-brief: $PANE"
# The kit's launch record binds the agent to its pane (common.sh launched): a
# lane can rewrite the pane map. herdr, which prompts by name, needs no record.
read -r _ LAUNCHED _ <<< "$(launched "$RUN_DIR" "$NAME")"
if [ -n "$LAUNCHED" ]; then
  [ "$LAUNCHED" = "$PANE" ] || die "send-brief: the pane map gives $NAME pane $PANE, but the kit launched it in $LAUNCHED: nothing sent; check its line in $MAP"
else
  runner_names_agents || die "send-brief: the kit has no record of launching $NAME ($(launch_record "$RUN_DIR")): nothing sent"
fi
rc=0; err=$(runner_pane_exists "$PANE" 2>&1) || rc=$?
case $rc in
  0) ;;
  1) die "send-brief: $NAME's pane $PANE is gone ($(runner_pane_check)): nothing sent" ;;
  3) stale_handle "$NAME" "$PANE" "its line"; exit 1 ;;
  *) die "send-brief: $(runner_name) cannot say whether $NAME's pane $PANE is open; nothing sent, send again once it answers ($(runner_name): ${err:-no output})" ;;
esac
err=$(runner_send_message "$NAME" "$PANE" "$(cat "$BRIEF")" 2>&1) \
  || die "send-brief: $(runner_name) did not take the brief for $NAME in $PANE; nothing was sent, send again${err:+ ($err)}"
echo "brief $BRIEF sent to $NAME in $PANE"
