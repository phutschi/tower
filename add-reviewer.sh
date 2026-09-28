#!/usr/bin/env bash
# Start a review: a fresh Reviewer in a slot of the review tab, and the review
# on the board as a task owned by that slot.
#
#   add-reviewer.sh <run-dir> <R1|R2> <lane-kind> "<review title>" <findings-file>
#
# Run it from the orchestrator's pane, in the repo checkout, after bootstrap.sh.
# lane-kind is the kind (claude | codex) of the lane under review; for a
# preflight slot, the kind whose other kind should review. The Reviewer's kind
# and model come from executor.sh reviewer_for (REVIEWER_KIND, REVIEWER_MODEL
# from .herdr-orchestrate or this call's environment).
#
# The first call opens the review tab with two panes, slots R1 and R2:
#
#        │ R1       │ R2       │
#
# Later calls reuse the tab and its slots. Every call starts a new agent, even
# when the slot had one: the previous Reviewer is sent /exit first, so the
# next review starts with a fresh context. Its name is <repo>-r1-<n>, n
# counting the reviews in that slot.
#
# Writes to <run-dir>/panes.txt (the pane map):
#   review tab:     <tab-id>   (R1 <pane-id>, R2 <pane-id>)       once, on the first call
#   reviewer R1:    <pane-id>   (agent "<name>", kind <kind>, model <model>, review "<title>", findings <file>)
# one reviewer line per slot, replaced by each new review in that slot.
# With tower the review becomes a board task:  tower add "<title>" --lane R1.
# Without tower it is appended to <run-dir>/tasks.tsv (id R1-<n>, area review)
# and to <run-dir>/lanes.txt (R1=R1-<n>).
#
# The Reviewer ends its report with  FINDINGS WRITTEN <findings-file>;
# watch-lanes.sh then reads it as idle-after-final-report. The review tab and
# its panes stay open after the run, like every pane.
#
# Prints the slot ids (on the first call) and the next step: brief the Reviewer
# (brief-template.md) and watch its agent.
#
# Never run this for real to see what it does; use DRY_RUN=1, which answers
# every herdr and tower call from tests/stub and touches nothing.
set -euo pipefail
KIT="$(cd "$(dirname "$0")" && pwd)"
. "$KIT/common.sh"
in_herdr; need git python3 node
[ $# -eq 5 ] || die 'usage: add-reviewer.sh <run-dir> <R1|R2> <lane-kind> "<review title>" <findings-file>'
RUN_DIR="$1"; SLOT="$2"; LANE_KIND="$3"; TITLE="$4"; FINDINGS="$5"
MAP="$RUN_DIR/panes.txt"
[ -f "$MAP" ] || die "no pane map at $MAP: run bootstrap.sh first"
case "$SLOT" in R1|R2) ;; *) die "slot must be R1 or R2 (got '$SLOT')" ;; esac
case "$LANE_KIND" in claude|codex) ;; *) die "lane kind must be claude or codex (got '$LANE_KIND')" ;; esac
REPO="$PWD"

. "$KIT/detect-stack.sh"   # REVIEWER_KIND, REVIEWER_MODEL (the environment wins)
. "$KIT/executor.sh"       # reviewer_for, agent_name, start_agent*
_rev=$(reviewer_for "$LANE_KIND")
IFS=$'\t' read -r R_KIND R_MODEL R_NOTE <<< "$_rev"; unset _rev
# start_agent starts EXECUTOR_KIND on EXECUTOR_MODEL: here, the Reviewer.
EXECUTOR_KIND=$R_KIND; EXECUTOR_MODEL=$R_MODEL

# --- the review tab, on the first call ----------------------------------------
TAB_LINE=$(sed -nE 's/^review tab: +(.*)$/\1/p' "$MAP")
if [ -z "$TAB_LINE" ]; then
  out=$(herdr tab create --cwd "$REPO" --label reviews --no-focus)
  TAB=$(echo "$out" | jsonq 'd["result"]["tab"]["tab_id"]')
  R1_PANE=$(echo "$out" | jsonq 'd["result"]["root_pane"]["pane_id"]')
  R2_PANE=$(herdr pane split --pane "$R1_PANE" --direction right --ratio 0.5 --cwd "$REPO" --no-focus | pane_id)
  echo "review tab:     $TAB   (R1 $R1_PANE, R2 $R2_PANE)" >> "$MAP"
  echo "review tab: $TAB — slots R1 $R1_PANE, R2 $R2_PANE"
else
  R1_PANE=$(echo "$TAB_LINE" | sed -nE 's/.*\(R1 ([^,]+), R2 ([^)]+)\).*/\1/p')
  R2_PANE=$(echo "$TAB_LINE" | sed -nE 's/.*\(R1 ([^,]+), R2 ([^)]+)\).*/\2/p')
fi
PANE=$([ "$SLOT" = R1 ] && echo "$R1_PANE" || echo "$R2_PANE")

# --- a fresh Reviewer in the slot ---------------------------------------------
slot_lc=$(echo "$SLOT" | tr 'A-Z' 'a-z')
PREV=$(sed -nE "s/^reviewer $SLOT: +[^ ]+ +\\(agent \"([^\"]+)\".*/\\1/p" "$MAP")
N=1
if [ -n "$PREV" ]; then
  N=$(( ${PREV##*-} + 1 ))
  # End the previous Reviewer so the pane is back at its shell prompt.
  herdr pane send-text "$PANE" "/exit" >/dev/null
  herdr pane send-keys "$PANE" Enter >/dev/null
  [ "${DRY_RUN:-0}" = 1 ] || sleep 3
fi
NAME="$(agent_name "-$slot_lc-$N")"
mkdir -p "$(dirname "$FINDINGS")"
start_agent_with_trust_retry "$NAME" "$PANE"

LINE=$(printf 'reviewer %s:    %s   (agent "%s", kind %s, model %s, review "%s", findings %s)' \
  "$SLOT" "$PANE" "$NAME" "$R_KIND" "$R_MODEL" "$TITLE" "$FINDINGS")
grep -v "^reviewer $SLOT:" "$MAP" > "$MAP.tmp" || true
echo "$LINE" >> "$MAP.tmp"; mv "$MAP.tmp" "$MAP"

# --- the review on the board -------------------------------------------------
if tower_ok; then
  tower add "$TITLE" --lane "$SLOT" >/dev/null
else
  [ -f "$RUN_DIR/tasks.tsv" ] || printf '# id\ttitle\tarea\tlane\n' > "$RUN_DIR/tasks.tsv"
  printf '%s-%s\t%s\treview\t%s\n' "$SLOT" "$N" "$TITLE" "$SLOT" >> "$RUN_DIR/tasks.tsv"
  echo "$SLOT=$SLOT-$N" >> "$RUN_DIR/lanes.txt"
fi

[ -z "$R_NOTE" ] || echo "reviewer: $R_NOTE"
echo "reviewer $SLOT ready: agent $NAME ($R_KIND, $R_MODEL) in $PANE — next: write $RUN_DIR/brief-$SLOT-$N.md from brief-template.md (a Reviewer brief; findings to $FINDINGS), then  herdr agent prompt $NAME \"\$(cat $RUN_DIR/brief-$SLOT-$N.md)\"  and add $NAME to both watchers"
