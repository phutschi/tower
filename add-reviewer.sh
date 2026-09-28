#!/usr/bin/env bash
# Start a review: a fresh Reviewer in a slot of the review tab, and the review
# on the board as a task owned by that slot.
#
#   [REVIEWER_KIND=other|claude|codex] [REVIEWER_MODEL=<model>] \
#     add-reviewer.sh <run-dir> <R1|R2> <lane-kind> "<review title>" <findings-file> [lane]
#
# Run it from the orchestrator's pane after bootstrap.sh. lane-kind is the kind
# (claude | codex) of the lane under review; for a preflight slot, the kind
# whose other kind should review. [lane] (A-D) names the lane under review; its
# pane map line must be of lane-kind, and its model is the one a codex Reviewer
# of a codex lane runs on when claude is not installed or REVIEWER_KIND=codex.
# Without it, the first lane of lane-kind in the pane map stands in; with none,
# executor.sh's default. The Reviewer's kind and model
# come from executor.sh reviewer_for (REVIEWER_KIND and REVIEWER_MODEL from the
# pane map's switches: line, the run's values from bootstrap; this call's
# environment wins over them). It works in lane A's checkout, read from the
# pane map. <run-dir> and <findings-file> may be relative to where it is
# called. The title must not hold a tab or a newline.
#
# The first call opens the review tab with two panes, slots R1 and R2, in the
# run's workspace (the orchestrator pane's, from the pane map; an orchestrator
# pane herdr no longer knows is refused before anything is written):
#
#        │ R1       │ R2       │
#
# Later calls reuse the tab and its slots. Every call starts a new agent,
# <repo>-r1-<n> with n counting the reviews in that slot, so each review starts
# with a fresh context. The slot's previous Reviewer is refused while it is
# still working, sent /exit and Enter when idle (Enter again every 3 seconds
# while it is still there), and waited for (EXIT_WAIT_SECONDS, default 15)
# until herdr no longer knows it.
#
# In order, it writes:
#   the board task, before anything opens: with tower
#     tower add "<title>" --id R1-<n> --area review --lane R1
#   without tower a line in <run-dir>/tasks.tsv (id R1-<n>, area review; the
#   file is created with its header if the run has none) and R1=R1-<n> in
#   <run-dir>/lanes.txt. When that id is already there (an earlier call for the
#   slot added it, then its Reviewer did not start), the task is reused under
#   this call's title and "reusing task <id>: ..." is printed: a failed call can
#   simply be run again. A task someone worked on (not pending on the board;
#   without tower, no R1=R1-<n> line) is refused instead;
#   the pane map (<run-dir>/panes.txt):
#     review tab:     <tab-id>   (R1 <pane-id>, R2 <pane-id>)   once, on the first call
#     reviewer R1:    <pane-id>   (agent "<name>", kind <kind>, model <model>, review "<title>", findings <file>)
#   one reviewer line per slot, replaced by each new review in that slot;
#   the directory of <findings-file>.
#
# The Reviewer ends its report with  [[FINDINGS WRITTEN]] <findings-file>;
# watch-lanes.sh then reads it as idle-after-final-report. The review tab and
# its panes stay open after the run, like every pane.
#
# Prints the slot ids (on the first call), the fallback note when reviewer_for
# fell back ("reviewer: fallback: ..."), and the task id with the next step:
# brief the Reviewer (brief-template.md) and add its agent to watch-lanes.sh.
#
# START_TRIES (environment, default 10): how often an agent start is tried,
# a second apart, while its new pane's shell is not ready yet (executor.sh).
#
# Never run this for real to see what it does; use DRY_RUN=1, which answers
# every herdr and tower call from tests/stub and touches nothing.
set -euo pipefail
KIT="$(cd "$(dirname "$0")" && pwd)"
. "$KIT/common.sh"
in_herdr; need git python3 node
[ $# -eq 5 ] || [ $# -eq 6 ] || die 'usage: add-reviewer.sh <run-dir> <R1|R2> <lane-kind> "<review title>" <findings-file> [lane]'
RUN_DIR="$1"; SLOT="$2"; LANE_KIND="$3"; TITLE="$4"; FINDINGS="$5"; LANE="${6:-}"
MAP="$RUN_DIR/panes.txt"
[ -f "$MAP" ] || die "no pane map at $MAP: run bootstrap.sh first"
case "$SLOT" in R1|R2) ;; *) die "slot must be R1 or R2 (got '$SLOT')" ;; esac
# Absolute, since the rest runs from lane A's checkout.
RUN_DIR="$(cd "$RUN_DIR" && pwd)"; MAP="$RUN_DIR/panes.txt"
case "$FINDINGS" in /*) ;; *) FINDINGS="$PWD/$FINDINGS" ;; esac
# The run's switches, as bootstrap resolved them, unless this call sets one.
# The line is shell-quoted (detect-stack.sh switches_line); python3 splits it
# into NAME=value words, one per line, so a value keeps its spaces and is never
# globbed.
_words=$(sed -nE 's/^switches: +//p' "$MAP" \
  | python3 -c 'import shlex,sys; print("\n".join(shlex.split(sys.stdin.read())))' 2>/dev/null) \
  || die "the switches: line in $MAP cannot be read back"
while IFS= read -r _kv; do
  [ -n "$_kv" ] || continue
  _k=${_kv%%=*}
  case " $SWITCHES " in *" $_k "*) ;; *) die "the switches: line in $MAP holds '$_kv', not a run switch" ;; esac
  [ -n "${!_k+set}" ] || export "$_kv"
done <<< "$_words"
unset _words _kv _k
case "$LANE_KIND" in claude|codex) ;; *) die "lane kind must be claude or codex (got '$LANE_KIND')" ;; esac
# The Reviewer works in lane A's checkout (the integration branch), where the
# repo contract lives too.
REPO=$(sed -nE 's/^lane A: .* checkout (.*), model .*/\1/p' "$MAP")
[ -n "$REPO" ] || die "no lane A in $MAP: run bootstrap.sh first"
# The lane under review, for its model: the one named, else the first of lane-kind.
if [ -n "$LANE" ]; then
  case "$LANE" in A|B|C|D) ;; *) die "lane must be A, B, C or D (got '$LANE')" ;; esac
  _line=$(grep -E "^lane $LANE: " "$MAP" || true)
  [ -n "$_line" ] || die "no lane $LANE in $MAP"
  _kind=$(echo "$_line" | sed -nE 's/^lane [A-D]: +[^ ]+ +\(agent "[^"]*", kind ([a-z]+), .*/\1/p')
  [ "$_kind" = "$LANE_KIND" ] || die "lane $LANE is $_kind, not $LANE_KIND: pass the lane's own kind"
else
  _line=$(grep -E "^lane [A-D]: +[^ ]+ +\(agent \"[^\"]*\", kind $LANE_KIND, " "$MAP" | head -1 || true)
fi
LANE_MODEL=$(echo "$_line" | sed -nE 's/.*, model (.*)\)$/\1/p'); unset _line _kind

_here="$PWD"; cd "$REPO"
. "$KIT/detect-stack.sh"   # REVIEWER_KIND, REVIEWER_MODEL (the environment wins)
. "$KIT/executor.sh"       # reviewer_for, agent_name, start_agent*
cd "$_here"; unset _here
_rev=$(reviewer_for "$LANE_KIND" "$LANE_MODEL")
IFS=$'\t' read -r R_KIND R_MODEL R_NOTE <<< "$_rev"; unset _rev
# start_agent starts EXECUTOR_KIND on EXECUTOR_MODEL: here, the Reviewer.
EXECUTOR_KIND=$R_KIND; EXECUTOR_MODEL=$R_MODEL

TAB_LINE=$(sed -nE 's/^review tab: +(.*)$/\1/p' "$MAP")
slot_pane() { echo "$TAB_LINE" | sed -nE "s/.*[(, ]$1 ([^,)]+).*/\\1/p"; }

# --- end the slot's previous Reviewer ----------------------------------------
# agent start needs the pane back at its shell prompt. A Reviewer still working
# is refused; an idle one is sent /exit, then we wait (EXIT_WAIT_SECONDS,
# default 15) until herdr no longer knows it. codex can swallow the Enter after
# /exit (its slash-command popup takes it, or it lands before the text): so a
# second's pause before it, and Enter again every 3 seconds while the Reviewer
# is still there. An extra Enter at a shell prompt does nothing.
state_of() { herdr agent get "$1" 2>/dev/null | jsonq 'd["result"]["agent"]["agent_status"]' 2>/dev/null || echo gone; }
PREV=$(sed -nE "s/^reviewer $SLOT: +[^ ]+ +\\(agent \"([^\"]+)\".*/\\1/p" "$MAP")
N=1
if [ -n "$PREV" ]; then
  N=$(( ${PREV##*-} + 1 ))
  case "$(state_of "$PREV")" in
    gone) ;;
    working) die "Reviewer $PREV is still working in $SLOT: wait until the slot is free, or use the other slot" ;;
    *)
      PANE=$(slot_pane "$SLOT")
      herdr pane send-text "$PANE" "/exit" >/dev/null
      [ "${DRY_RUN:-0}" = 1 ] || sleep 1
      herdr pane send-keys "$PANE" Enter >/dev/null
      waited=0
      until [ "$(state_of "$PREV")" = gone ]; do
        [ "$waited" -lt "${EXIT_WAIT_SECONDS:-15}" ] || die "Reviewer $PREV did not exit; end it in $PANE and rerun"
        [ "${DRY_RUN:-0}" = 1 ] || sleep 1
        waited=$((waited+1))
        [ $((waited % 3)) -ne 0 ] || herdr pane send-keys "$PANE" Enter >/dev/null
      done ;;
  esac
fi
ID="$SLOT-$N"

# The review tab opens in the run's workspace, the orchestrator pane's; not
# whichever workspace the human is looking at.
if [ -z "$TAB_LINE" ]; then
  ORCH=$(sed -nE 's/^orchestrator: +([^ ]+).*/\1/p' "$MAP")
  [ -n "$ORCH" ] || die "no orchestrator line in $MAP: run bootstrap.sh first"
  WS=$(herdr pane get "$ORCH" 2>/dev/null | jsonq 'd["result"]["pane"]["workspace_id"]' 2>/dev/null) \
    || die "no workspace for the orchestrator pane $ORCH (herdr pane get): is it still open?"
fi

# --- the review on the board: a refusal stops before anything opens ----------
# The id can already be there: an earlier call for this slot added it, then its
# Reviewer did not start, so no reviewer line counted it. That task is reused,
# under this call's title, while nobody has worked on it: pending on the board,
# or without tower a tasks.tsv line with this slot's lanes.txt line.
REUSED=0
if tower_ok; then
  if ! out=$(tower add "$TITLE" --id "$ID" --area review --lane "$SLOT" 2>&1); then
    case "$out" in *"task \"$ID\" already exists"*) ;; *) die "$out" ;; esac
    status=$(tower state --json | jsonq "next((t.get('status', '?') for t in d['tasks'] if t['id'] == '$ID'), 'missing')")
    [ "$status" = pending ] || die "task $ID is $status on the board, so not a failed start: check it, or  tower remove $ID  and rerun"
    tower change "$ID" --title "$TITLE" >/dev/null
    REUSED=1
  fi
else
  [ -f "$RUN_DIR/tasks.tsv" ] || printf '# id\ttitle\tarea\tlane\n' > "$RUN_DIR/tasks.tsv"
  if grep -q "^$ID	" "$RUN_DIR/tasks.tsv"; then
    grep -qx "$SLOT=$ID" "$RUN_DIR/lanes.txt" 2>/dev/null \
      || die "$ID is in $RUN_DIR/tasks.tsv, but not as $SLOT=$ID in $RUN_DIR/lanes.txt: not this slot's; check it and rerun"
    { grep -v "^$ID	" "$RUN_DIR/tasks.tsv" || [ $? -eq 1 ]; } > "$RUN_DIR/tasks.tsv.tmp"
    mv "$RUN_DIR/tasks.tsv.tmp" "$RUN_DIR/tasks.tsv"
    REUSED=1
  fi
  printf '%s\t%s\treview\t%s\n' "$ID" "$TITLE" "$SLOT" >> "$RUN_DIR/tasks.tsv"
  grep -qx "$SLOT=$ID" "$RUN_DIR/lanes.txt" 2>/dev/null || echo "$SLOT=$ID" >> "$RUN_DIR/lanes.txt"
fi
[ "$REUSED" = 0 ] || echo "reusing task $ID: an earlier call for $SLOT added it, but its Reviewer did not start"

# --- the review tab, on the first call ----------------------------------------
if [ -z "$TAB_LINE" ]; then
  out=$(herdr tab create --workspace "$WS" --cwd "$REPO" --label reviews --no-focus)
  TAB=$(echo "$out" | jsonq 'd["result"]["tab"]["tab_id"]')
  R1_PANE=$(echo "$out" | jsonq 'd["result"]["root_pane"]["pane_id"]')
  R2_PANE=$(herdr pane split --pane "$R1_PANE" --direction right --ratio 0.5 --cwd "$REPO" --no-focus | pane_id)
  TAB_LINE="$TAB   (R1 $R1_PANE, R2 $R2_PANE)"
  echo "review tab:     $TAB_LINE" >> "$MAP"
  echo "review tab: $TAB — slots R1 $R1_PANE, R2 $R2_PANE"
fi
PANE=$(slot_pane "$SLOT")

# --- a fresh Reviewer in the slot ---------------------------------------------
NAME="$(cd "$REPO" && agent_name "-$(echo "$SLOT" | tr 'A-Z' 'a-z')-$N")"
mkdir -p "$(dirname "$FINDINGS")"
( cd "$REPO" && start_agent_with_trust_retry "$NAME" "$PANE" )

LINE=$(printf 'reviewer %s:    %s   (agent "%s", kind %s, model %s, review "%s", findings %s)' \
  "$SLOT" "$PANE" "$NAME" "$R_KIND" "$R_MODEL" "$TITLE" "$FINDINGS")
{ grep -v "^reviewer $SLOT:" "$MAP" || [ $? -eq 1 ]; } > "$MAP.tmp"
echo "$LINE" >> "$MAP.tmp"; mv "$MAP.tmp" "$MAP"

[ -z "$R_NOTE" ] || echo "reviewer: $R_NOTE"
echo "reviewer $SLOT ready (task $ID): agent $NAME ($R_KIND, $R_MODEL) in $PANE — next: write $RUN_DIR/brief-$ID.md from brief-template.md (a Reviewer brief; findings to $FINDINGS), then  herdr agent prompt $NAME \"\$(cat $RUN_DIR/brief-$ID.md)\"  and add $NAME to watch-lanes.sh"
