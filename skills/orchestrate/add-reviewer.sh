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
# called. The title must not hold a tab or a newline: one that does is
# refused before anything is written.
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
# still working, sent /exit and Enter when idle (Enter again about every 3
# seconds while it is still there), and waited for (EXIT_WAIT_SECONDS, default 15)
# until herdr answers agent_not_found for it. herdr failing otherwise is not an
# exit: before the /exit it refuses the call, after it the wait goes on
# (common.sh state_of, unreadable). herdr's own unknown status is an agent it
# cannot classify, and is sent /exit like an idle one.
#
# In order, it writes:
#   the board task, before anything opens:
#     tower add "<title>" --id R1-<n> --area review --lane R1
#   When that id is already there (an earlier call for the
#   slot added it, then its Reviewer did not start), the task is reused under
#   this call's title and "reusing task <id>: ..." is printed: a failed call can
#   simply be run again. A task someone worked on (not pending on the board)
#   is refused instead;
#   the pane map (<run-dir>/panes.txt):
#     review tab:     <tab-id>   (R1 <pane-id>, R2 <pane-id>)   once, on the first call
#     reviewer R1:    <pane-id>   (agent "<name>", kind <kind>, model <model>, review "<title>", findings <file>)
#   one reviewer line per slot, replaced by each new review in that slot. It
#   is written before the agent starts, ending in " starting" until the agent
#   accepts input: a start that fails leaves it so, says to rerun, and a rerun
#   for the slot resumes that review under the same agent and task while
#   nobody has worked on the task. The agent left in the slot, when it is of
#   this call's kind and model, is kept once it accepts input ("resuming
#   ..."): one herdr says does not accept input yet is waited for as a start
#   is (READY_WAIT_SECONDS), and when it still does not, the call fails,
#   saying it is still starting and that a rerun resumes it. Any other agent
#   left there is ended as a previous Reviewer is, then started again;
#   the directory of <findings-file>;
#   for a codex Reviewer, <run-dir>/tmp: the commands it runs get it as
#   TMPDIR, BUN_TMPDIR, BUN_INSTALL_CACHE_DIR and npm_config_cache, since its
#   sandbox writes only the checkout and the run dir (executor.sh AGENT_TMP).
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
# The agent is reported ready only once it accepts input (herdr's
# interactive_ready), read about a second apart READY_WAIT_SECONDS times
# (default 30) after START_SETTLE_SECONDS (default 3); one that exits right
# after its start is started once more, and one that never accepts input
# fails the call and is left running in its pane (executor.sh).
#
# Never run this for real to see what it does; use DRY_RUN=1, which answers
# every herdr, claude and codex call from tests/stub and opens nothing. tower
# is the real CLI from this checkout (it needs bun): it records the run in the
# run dir, and bootstrap points the repo at that run. Use a scratch repo and
# run dir, never a live run's.
set -euo pipefail
KIT="$(cd "$(dirname "$0")" && pwd)"
. "$KIT/common.sh"
in_herdr; need git python3 node
need_tower
[ $# -eq 5 ] || [ $# -eq 6 ] || die 'usage: add-reviewer.sh <run-dir> <R1|R2> <lane-kind> "<review title>" <findings-file> [lane]'
RUN_DIR="$1"; SLOT="$2"; LANE_KIND="$3"; TITLE="$4"; FINDINGS="$5"; LANE="${6:-}"
MAP="$RUN_DIR/panes.txt"
[ -f "$MAP" ] || die "no pane map at $MAP: run bootstrap.sh first"
case "$SLOT" in R1|R2) ;; *) die "slot must be R1 or R2 (got '$SLOT')" ;; esac
# The title is one field of the slot's pane map line (and of the board).
case "$TITLE" in *$'\t'*|*$'\n'*) die "the review title must not hold a tab or a newline" ;; esac
# Absolute, since the rest runs from lane A's checkout.
RUN_DIR="$(cd "$RUN_DIR" && pwd)"; MAP="$RUN_DIR/panes.txt"
# Every tower call is about this run, wherever it is called from.
export TOWER_RUN="$RUN_DIR"
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
LANE_MODEL=$(echo "$_line" | sed -nE 's/.*, model (.*)\)( starting)?$/\1/p')   # a lane still starting too; unset _line _kind

_here="$PWD"; cd "$REPO"
CONTRACT_RUN="$RUN_DIR" . "$KIT/detect-stack.sh"   # the run's pinned contract: REVIEWER_KIND, REVIEWER_MODEL (the environment wins)
. "$KIT/executor.sh"       # reviewer_for, agent_name, start_agent*
cd "$_here"; unset _here
_rev=$(reviewer_for "$LANE_KIND" "$LANE_MODEL")
IFS=$'\t' read -r R_KIND R_MODEL R_NOTE <<< "$_rev"; unset _rev
# start_agent starts EXECUTOR_KIND on EXECUTOR_MODEL: here, the Reviewer.
EXECUTOR_KIND=$R_KIND; EXECUTOR_MODEL=$R_MODEL
# A codex Reviewer is handed <run-dir>/tmp as a TOML string, which cannot
# hold a control character: refused before anything is written.
case "$R_KIND:$RUN_DIR" in
  codex:*[[:cntrl:]]*) die "the run dir $RUN_DIR holds a control character; a codex Reviewer cannot be given its tmp: use a run dir without one" ;;
esac

TAB_LINE=$(sed -nE 's/^review tab: +(.*)$/\1/p' "$MAP")
slot_pane() { echo "$TAB_LINE" | sed -nE "s/.*[(, ]$1 ([^,)]+).*/\\1/p"; }

# --- end the slot's previous Reviewer ----------------------------------------
# agent start needs the pane back at its shell prompt. A Reviewer still working
# is refused, and so is one herdr cannot be asked about (unreadable); any other
# is sent /exit, then we wait (EXIT_WAIT_SECONDS, default 15) until herdr
# answers agent_not_found for it. codex can swallow the Enter after
# /exit (its slash-command popup takes it, or it lands before the text): so a
# second's pause before it, and Enter again about every 3 seconds while the
# Reviewer is still there. An extra Enter at a shell prompt does nothing.
# EXIT_WAIT_SECONDS counts checks about a second apart.
# The reviewer line is written before its agent starts, ending in " starting"
# until the agent accepts input. A line still ending so, whose task nobody has
# worked on (pending on the board, or not there), is a start that failed: a
# rerun resumes that review, under the same agent name and task. Its agent,
# still in the slot and of this call's kind and model, is kept once it accepts
# input (executor.sh ready_of), waited for while it does not yet; otherwise it
# is ended as above, then started again. A starting line whose task was
# worked on is a review that happened: the next one starts fresh.
RERUN_ARGS=$(printf ' %q' "$RUN_DIR" "$SLOT" "$LANE_KIND" "$TITLE" "$FINDINGS" ${LANE:+"$LANE"})
PREV_LINE=$(grep -E "^reviewer $SLOT: " "$MAP" || true)
PREV=$(echo "$PREV_LINE" | sed -nE "s/^reviewer $SLOT: +[^ ]+ +\\(agent \"([^\"]+)\".*/\\1/p")
N=1; RESUME=0; KEEP=0
if [ -n "$PREV" ]; then
  N=$(( ${PREV##*-} + 1 ))
  case "$PREV_LINE" in
    *" starting")
      prev_status=$(tower state --json | jsonq "next((t.get('status', '?') for t in d['tasks'] if t['id'] == '$SLOT-${PREV##*-}'), 'missing')") \
        || die "add-reviewer: tower state failed; rerun once tower answers"
      case "$prev_status" in pending|missing) RESUME=1; N=${PREV##*-} ;; esac ;;
  esac
  # A resumed review's agent of this call's kind and model is kept once it
  # accepts input, working or not; one that does not yet is still starting,
  # and is waited for as its start waits (executor.sh until_ready, whose own
  # next step is for a fresh start, so not printed here). After a wait that
  # ran out, one more read decides: still starting fails, saying a rerun
  # resumes it; gone, unreadable or any other state goes on below.
  if [ "$RESUME" = 1 ] && [[ "$PREV_LINE" == *", kind $R_KIND, model $R_MODEL, review "* ]]; then
    case "$(ready_of "$PREV")" in
      ready) KEEP=1 ;;
      *", not ready for input")
        rc=0; until_ready "$PREV" "$(slot_pane "$SLOT")" 2>/dev/null || rc=$?
        [ "$rc" != 0 ] || KEEP=1
        if [ "$rc" = 2 ]; then
          case "$(ready_of "$PREV")" in
            ready) KEEP=1 ;;
            *", not ready for input")
              die "Reviewer $PREV is still starting in $(slot_pane "$SLOT"): rerun  $KIT/add-reviewer.sh$RERUN_ARGS  to resume it once it accepts input" ;;
          esac
        fi ;;
    esac
  fi
  [ "$KEEP" = 1 ] || case "$(state_of "$PREV")" in
    gone) ;;
    working) die "Reviewer $PREV is still working in $SLOT: wait until the slot is free, or use the other slot" ;;
    unreadable) die "herdr cannot say whether Reviewer $PREV is still there (herdr agent get $PREV fails); rerun once herdr answers" ;;
    *)
      PANE=$(slot_pane "$SLOT")
      herdr pane send-text "$PANE" "/exit" >/dev/null
      [ "${DRY_RUN:-0}" = 1 ] || sleep 1
      herdr pane send-keys "$PANE" Enter >/dev/null
      waited=0
      until state=$(state_of "$PREV"); [ "$state" = gone ]; do
        if [ "$waited" -ge "${EXIT_WAIT_SECONDS:-15}" ]; then
          [ "$state" != unreadable ] || die "herdr cannot say whether Reviewer $PREV exited; check $PANE, and rerun once herdr answers"
          die "Reviewer $PREV did not exit; end it in $PANE and rerun"
        fi
        if [ "$waited" -gt 0 ] && [ $((waited % 3)) -eq 0 ]; then
          herdr pane send-keys "$PANE" Enter >/dev/null 2>&1 || true   # best effort; the gone check decides
        fi
        [ "${DRY_RUN:-0}" = 1 ] || sleep 1
        waited=$((waited+1))
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
# under this call's title, while nobody has worked on it: pending on the board.
REUSED=0
if ! out=$(tower add "$TITLE" --id "$ID" --area review --lane "$SLOT" 2>&1); then
  case "$out" in *"task \"$ID\" already exists"*) ;; *) die "$out" ;; esac
  status=$(tower state --json | jsonq "next((t.get('status', '?') for t in d['tasks'] if t['id'] == '$ID'), 'missing')")
  [ "$status" = pending ] || die "task $ID is $status on the board, so not a failed start: check it, or  tower remove $ID  and rerun"
  tower change "$ID" --title "$TITLE" >/dev/null
  REUSED=1
fi
if [ "$REUSED" = 1 ] && [ "$KEEP" = 1 ]; then echo "reusing task $ID: the review resumed below"
elif [ "$REUSED" = 1 ]; then echo "reusing task $ID: an earlier call for $SLOT added it, but its Reviewer did not start"; fi

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
# A codex Reviewer's sandbox writes only the checkout and the run dir: its
# temp files and package caches (bunx, npm) go to the run dir's tmp.
if [ "$R_KIND" = codex ]; then AGENT_TMP="$RUN_DIR/tmp"; mkdir -p "$AGENT_TMP"; fi
LINE=$(printf 'reviewer %s:    %s   (agent "%s", kind %s, model %s, review "%s", findings %s)' \
  "$SLOT" "$PANE" "$NAME" "$R_KIND" "$R_MODEL" "$TITLE" "$FINDINGS")
# The map is rewritten through a temp file of this call's own: the other
# slot's add-reviewer may be rewriting it too.
slot_line() {
  local tmp; tmp=$(mktemp "$MAP.XXXXXX")
  { grep -v "^reviewer $SLOT:" "$MAP" || [ $? -eq 1 ]; } > "$tmp"
  echo "$1" >> "$tmp"; mv "$tmp" "$MAP"
}
slot_line "$LINE starting"
if [ "$KEEP" = 1 ]; then echo "resuming $NAME in $PANE: its start failed earlier, and it now accepts input"
else
  ( cd "$REPO" && start_agent_with_trust_retry "$NAME" "$PANE" ) \
    || die "add-reviewer: Reviewer $NAME is not ready in $PANE; its review is in the pane map, starting: rerun  $KIT/add-reviewer.sh$RERUN_ARGS  to resume it"
fi
slot_line "$LINE"

[ -z "$R_NOTE" ] || echo "reviewer: $R_NOTE"
echo "reviewer $SLOT ready (task $ID): agent $NAME ($R_KIND, $R_MODEL) in $PANE — next: write $RUN_DIR/brief-$ID.md from brief-template.md (a Reviewer brief; findings to $FINDINGS), then  herdr agent prompt $NAME \"\$(cat $RUN_DIR/brief-$ID.md)\"  and add $NAME to watch-lanes.sh"
