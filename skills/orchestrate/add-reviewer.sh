#!/usr/bin/env bash
# Start a review: a fresh Reviewer in a Reviewer slot, and the review
# on the board as a task owned by that slot.
#
#   [REVIEW_STAGE=lane|preflight] [REVIEWER_KIND=other|claude|codex|cursor] \
#     [REVIEWER_MODEL=<model>] add-reviewer.sh <run-dir> <R1|R2> <lane-kind> "<review title>" <findings-file> [lane]
#
# Run it from the orchestrator's pane after bootstrap.sh. lane-kind is the kind
# (claude | codex | cursor) of the lane under review; for a preflight slot,
# the kind whose Reviewer is wanted (its candidates: executor.sh
# reviewer_candidates). [lane] (A-D) names the lane under review; its pane map
# line must be of lane-kind, and its model is the one a codex Reviewer of a
# codex lane runs on when claude is not installed or REVIEWER_KIND=codex (a
# cursor Reviewer of a cursor lane runs on REVIEWER_MODEL_CURSOR instead).
# Without it, the first lane of lane-kind in the pane map stands in; with none,
# executor.sh's default. The Reviewer's kind and model
# come from executor.sh reviewer_for, or with REVIEW_STAGE=preflight (a
# preflight slot) from preflight_reviewer: claude on PREFLIGHT_MODEL_CLAUDE,
# and below REVIEWER_CREDITS_MIN % claude credits another kind, else claude on
# REVIEWER_MODEL_CLAUDE. REVIEWER_KIND and REVIEWER_MODEL come from the
# pane map's switches: line (the run's values from bootstrap; this call's
# environment wins over them). It works in lane A's checkout, read from the
# pane map. <run-dir> and <findings-file> may be relative to where it is
# called. The title must not hold a tab, a newline or another control
# character: one that does is refused before anything is written.
#
# The slots R1 and R2 are the lanes tab's right column, from its  lanes tab:
# line (bootstrap.sh); a run opened before the lanes tab has its own  review
# tab:  line, and its slots are there:
#
#        │ lane A   │ lane B   │ R1       │
#        ├──────────┼──────────┼──────────┤
#        │ lane C   │ lane D   │ R2       │
#
# With no  lanes tab:  line and lane A in another tab (its line names one) the
# first call opens the lanes tab, the column alone, R1 its root and R2 under
# it; a code lane added later goes under R2 (layout.sh). With a lanes tab but
# no column (LANE_REVIEW and PREFLIGHT off at bootstrap), or a pane map from
# before the lanes tab, the first call opens a  reviews  tab, R2 right of R1. Either opens in the run's workspace (the orchestrator pane's,
# from the pane map; an orchestrator pane herdr no longer knows is refused
# before anything is written). Later calls reuse the slots. Every call starts a new agent,
# <repo>-r1-<n> with n counting the reviews in that slot, so each review starts
# with a fresh context. The slot's previous Reviewer is refused while it is
# still working, sent /exit and Enter when idle (Enter again about every 3
# seconds while it is still there), and waited for (EXIT_WAIT_SECONDS, default 15)
# until herdr answers agent_not_found for it (in Orca its terminal is closed
# after the /exit, and the next Reviewer gets a tab of its own). herdr failing otherwise is not an
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
#     lanes tab:      <tab-id>   (R1 <pane-id>, R2 <pane-id>)   once, when the call opened
#                                                                 the lanes tab (review tab:
#                                                                 for a reviews tab)
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
#   sandbox writes only the checkout and the run dir (executor.sh AGENT_TMP);
#   for a codex Reviewer, $XDG_STATE_HOME/tower/look (mode 700), which its
#   sandbox may write so preflight's look.sh can make its temp worktree and
#   keep its verdict files there (executor.sh AGENT_LOOK); no lane is granted
#   it, and it is granted only where look.sh --dir accepts it (a refusal
#   fails the call before anything is written);
#   once the Reviewer is ready, each credit guard note (executor.sh
#   reviewer_for) as a tower note:  reviewer: skipped <kind>, <n>% credits left
#   or  reviewer: <kind> credits unreadable, counted as enough
#
# The Reviewer ends its report with  [[FINDINGS WRITTEN]] <findings-file>;
# watch-lanes.sh then reads it as idle-after-final-report. The slots stay open
# after the run, like every pane.
#
# Prints the slot ids (when it opened their tab), the fallback note when reviewer_for
# fell back ("reviewer: fallback: ..."), and the task id with the next step:
# brief the Reviewer (brief-template.md) and add its agent to watch-lanes.sh.
#
# In a run with session roles (the pane map's  roles: on , roles.sh), a claude
# Reviewer starts with --role review and --topic r1 or r2 (its slot).
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
# every herdr, claude, codex and cursor-agent call from tests/stub and opens nothing. tower
# is the real CLI from this checkout (it needs bun): it records the run in the
# run dir, and bootstrap points the repo at that run. Use a scratch repo and
# run dir, never a live run's.
set -euo pipefail
KIT="$(cd "$(dirname "$0")" && pwd)"
. "$KIT/common.sh"
need_runner; need git python3 node
need_tower
[ $# -eq 5 ] || [ $# -eq 6 ] || die 'usage: add-reviewer.sh <run-dir> <R1|R2> <lane-kind> "<review title>" <findings-file> [lane]'
RUN_DIR="$1"; SLOT="$2"; LANE_KIND="$3"; TITLE="$4"; FINDINGS="$5"; LANE="${6:-}"
MAP="$RUN_DIR/panes.txt"
[ -f "$MAP" ] || die "no pane map at $MAP: run bootstrap.sh first"
case "$SLOT" in
  R1|R2) ;;
  *) die "slot must be R1 or R2 (got '$SLOT')" ;;
esac
# The title is one field of the slot's pane map line (and of the board).
case "$TITLE" in
  *[[:cntrl:]]*) die "the review title must not hold a tab, a newline or another control character" ;;
esac
# Absolute, since the rest runs from lane A's checkout.
RUN_DIR="$(cd "$RUN_DIR" && pwd)"; MAP="$RUN_DIR/panes.txt"
# Every tower call is about this run, wherever it is called from.
export TOWER_RUN="$RUN_DIR"
case "$FINDINGS" in
  /*) ;;
  *) FINDINGS="$PWD/$FINDINGS" ;;
esac
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
  case " $SWITCHES " in
    *" $_k "*) ;;
    *) die "the switches: line in $MAP holds '$_kv', not a run switch" ;;
  esac
  [ -n "${!_k+set}" ] || export "$_kv"
done <<< "$_words"
unset _words _kv _k
kind_known "$LANE_KIND" || die "lane kind must be $(kinds_say) (got '$LANE_KIND')"
case "${REVIEW_STAGE:-lane}" in
  lane|preflight) ;;
  *) die "REVIEW_STAGE must be lane or preflight (got '$REVIEW_STAGE')" ;;
esac
# The Reviewer works in lane A's checkout (the integration branch), where the
# repo contract lives too.
REPO=$(sed -nE 's/^lane A: .* checkout (.*), model .*/\1/p' "$MAP")
[ -n "$REPO" ] || die "no lane A in $MAP: run bootstrap.sh first"
# The lane under review, for its model: the one named, else the first of lane-kind.
if [ -n "$LANE" ]; then
  case "$LANE" in
    A|B|C|D) ;;
    *) die "lane must be A, B, C or D (got '$LANE')" ;;
  esac
  _line=$(grep -E "^lane $LANE: " "$MAP" || true)
  [ -n "$_line" ] || die "no lane $LANE in $MAP"
  _kind=$(echo "$_line" | sed -nE 's/^lane [A-D]: +[^ ]+ +\(agent "[^"]*", kind ([a-z]+), .*/\1/p')
  [ "$_kind" = "$LANE_KIND" ] || die "lane $LANE is $_kind, not $LANE_KIND: pass the lane's own kind"
else
  _line=$(grep -E "^lane [A-D]: +[^ ]+ +\(agent \"[^\"]*\", kind $LANE_KIND, " "$MAP" | head -1 || true)
fi
LANE_MODEL=$(echo "$_line" | sed -nE -e 's/, tab [a-z]+\)/)/' -e 's/.*, model (.*)\)( starting| unsent)?$/\1/p')   # a lane still starting too, its tab dropped; unset _line _kind

_here="$PWD"; cd "$REPO"
CONTRACT_RUN="$RUN_DIR" . "$KIT/detect-stack.sh"   # the run's pinned contract: REVIEWER_KIND, REVIEWER_MODEL (the environment wins)
. "$KIT/executor.sh"       # reviewer_for, agent_name, start_agent*
cd "$_here"; unset _here
case "${REVIEW_STAGE:-lane}" in
  lane)      _rev=$(reviewer_for "$LANE_KIND" "$LANE_MODEL") ;;
  preflight) _rev=$(preflight_reviewer "$LANE_KIND" "$LANE_MODEL") ;;
esac
IFS=$'\t' read -r R_KIND R_MODEL R_NOTE <<< "$_rev"; unset _rev
# start_agent starts EXECUTOR_KIND on EXECUTOR_MODEL: here, the Reviewer.
EXECUTOR_KIND=$R_KIND; EXECUTOR_MODEL=$R_MODEL
# In a run with session roles (roles.sh), a claude Reviewer starts in the
# review role, its topic the slot (r1, r2), in a lane review and a preflight
# slot alike.
. "$KIT/roles.sh"
SESSION_ROLE=""; SESSION_TOPIC=""
if roles_on "$MAP" && [ "$R_KIND" = claude ]; then
  SESSION_ROLE=review; SESSION_TOPIC=$(echo "$SLOT" | tr 'A-Z' 'a-z')
fi
# A codex Reviewer is handed <run-dir>/tmp as a TOML string, which cannot
# hold a control character: refused before anything is written.
case "$R_KIND:$RUN_DIR" in
  codex:*[[:cntrl:]]*) die "the run dir $RUN_DIR holds a control character; a codex Reviewer cannot be given its tmp: use a run dir without one" ;;
esac
# A codex Reviewer may also write where look.sh makes its temp worktree and
# keeps its verdict files, which no lane may write: it alone is granted it
# (executor.sh AGENT_LOOK), after look's own check of that dir (look.sh --dir:
# never a symlink, a dir not the user's, or one under the git dir, the run
# dir, a worktree of the repo, TMPDIR or /tmp), so the two refuse the same.
AGENT_LOOK=""
if [ "$R_KIND" = codex ]; then
  AGENT_LOOK=$(cd "$REPO" && TOWER_RUN="$RUN_DIR" "$(dirname "$KIT")/preflight/look.sh" --dir) \
    || die "add-reviewer: a codex Reviewer is not granted look's worktree dir (see above); fix it, then rerun"
fi

# The slots: the lanes tab's Reviewer column, or the reviews tab of a run
# opened before the lanes tab (or of one whose lanes tab has no column).
LANES_LINE=$(sed -nE 's/^lanes tab: +(.*)$/\1/p' "$MAP")
TAB_LINE=$(sed -nE 's/^review tab: +(.*)$/\1/p' "$MAP")
case "$TAB_LINE$LANES_LINE" in
  *"(R1 "*) [ -n "$TAB_LINE" ] || TAB_LINE=$LANES_LINE ;;
esac
slot_pane() { echo "$TAB_LINE" | sed -nE "s/.*[(, ]$1 ([^,)]+).*/\\1/p"; }

# --- end the slot's previous Reviewer ----------------------------------------
# agent start needs the pane back at its shell prompt. A Reviewer still working
# is refused, and so is one herdr cannot be asked about (unreadable); any other
# is sent /exit, then we wait (EXIT_WAIT_SECONDS, default 15) until herdr
# answers agent_not_found for it. codex can swallow the Enter after
# /exit (its slash-command popup takes it, or it lands before the text): so a
# second's pause before it, and Enter again about every 3 seconds while the
# Reviewer is still there. An extra Enter at a shell prompt does nothing.
# EXIT_WAIT_SECONDS counts checks about a second apart. In Orca the Reviewer's
# terminal is closed after its /exit, and the next Reviewer gets a terminal
# tab of its own (runner-orca.sh runner_end_agent, runner_reviewer_pane).
# The reviewer line is written before its agent starts, ending in " starting"
# until the agent accepts input. A line still ending so, whose task nobody has
# worked on (pending on the board, or not there), is a start that failed: a
# rerun resumes that review, under the same agent name and task. Its agent,
# still in the slot and of this call's kind and model, is kept once it accepts
# input (executor.sh ready_of), waited for while it does not yet; otherwise it
# is ended as above, then started again. A starting line whose task was
# worked on is a review that happened: the next one starts fresh. A start
# whose launch the runner proves it never sent (executor.sh's 3) ends the line
# in " unsent": the rerun starts that review in the same pane, once its
# screen shows a shell. A launch sent without a receipt (4) stays starting,
# and so does a Reviewer's terminal that shows a bare shell: someone looks
# before anything is typed there again, and marks it unsent.
RERUN_ARGS=$(printf ' %q' "$RUN_DIR" "$SLOT" "$LANE_KIND" "$TITLE" "$FINDINGS" ${LANE:+"$LANE"})
# The map is rewritten through a temp file of this call's own: the other
# slot's add-reviewer may be rewriting it too.
slot_line() {
  local tmp; tmp=$(mktemp "$MAP.XXXXXX")
  { grep -v "^reviewer $SLOT:" "$MAP" || [ $? -eq 1 ]; } > "$tmp"
  echo "$1" >> "$tmp"; mv "$tmp" "$MAP"
}
PREV_LINE=$(grep -E "^reviewer $SLOT: " "$MAP" || true)
PREV=$(echo "$PREV_LINE" | sed -nE "s/^reviewer $SLOT: +[^ ]+ +\\(agent \"([^\"]+)\".*/\\1/p")
N=1; RESUME=0; KEEP=0; ENDED=0; UNSENT=0
if [ -n "$PREV" ]; then
  # The previous Reviewer's pane: its line's (a runner may give each Reviewer
  # a pane of its own), else the slot's.
  PANE=$(echo "$PREV_LINE" | sed -nE "s/^reviewer $SLOT: +([^ ]+) .*/\\1/p")
  [ -n "$PANE" ] || PANE=$(slot_pane "$SLOT")
  N=$(( ${PREV##*-} + 1 ))
  # " ended": this script closed its terminal (runner_end_agent), then failed.
  [[ "$PREV_LINE" != *" ended" ]] || ENDED=1
  case "$PREV_LINE" in
    *" starting"|*" starting ended"|*" unsent")
      prev_status=$(tower state --json | jsonq "next((t.get('status', '?') for t in d['tasks'] if t['id'] == '$SLOT-${PREV##*-}'), 'missing')") \
        || die "add-reviewer: tower state failed; rerun once tower answers"
      case "$prev_status" in
        pending|missing) RESUME=1; N=${PREV##*-} ;;
      esac ;;
  esac
  if [ "$RESUME" = 1 ] && [[ "$PREV_LINE" == *" unsent" ]]; then
    # A launch is typed only where the screen shows a shell, nothing else.
    UNSENT=1
    [ "$(state_of "$PREV" "$PANE")" != working ] && runner_pane_at_shell "$PANE" \
      || die "Reviewer $PREV's launch was never sent, but terminal $PANE's screen does not show a shell: check it there, then rerun  $KIT/add-reviewer.sh$RERUN_ARGS"
  fi
  # A resumed review's agent of this call's kind and model is kept once it
  # accepts input, working or not; one that does not yet is still starting,
  # and is waited for as its start waits (executor.sh until_ready, whose own
  # next step is for a fresh start, so not printed here). After a wait that
  # ran out, one more read decides: still starting fails, saying a rerun
  # resumes it; gone, unreadable or any other state goes on below. Unknown
  # or blocked at any read stops at once (pending_stop): a later idle read
  # does not say that review should end.
  # The pending Reviewer is kept as it is, for the next rerun: nothing typed,
  # nothing closed.
  pending_stop() { die "Reviewer $PREV's review is still pending, and $(runner_name) reads its terminal $PANE as $1: nothing was typed into it or closed. Look at it there: answer a prompt it shows, or wait until it accepts input, then rerun  $KIT/add-reviewer.sh$RERUN_ARGS  to resume it"; }
  if [ "$RESUME" = 1 ] && [ "$ENDED" = 0 ] && [ "$UNSENT" = 0 ] && [[ "$PREV_LINE" == *", kind $R_KIND, model $R_MODEL, review "* ]]; then
    ready=$(ready_of "$PREV" "$PANE")
    case "$ready" in
      unknown|blocked) pending_stop "$ready" ;;
      ready) KEEP=1 ;;
      *", not ready for input")
        rc=0; until_ready "$PREV" "$PANE" 2>/dev/null || rc=$?
        [ "$rc" != 0 ] || KEEP=1
        if [ "$rc" = 2 ]; then
          ready=$(ready_of "$PREV" "$PANE")
          case "$ready" in
            unknown|blocked) pending_stop "$ready" ;;
            ready) KEEP=1 ;;
            *", not ready for input")
              die "Reviewer $PREV is still starting in $PANE: rerun  $KIT/add-reviewer.sh$RERUN_ARGS  to resume it once it accepts input" ;;
          esac
        fi ;;
    esac
  fi
  prev_state=""; [ "$KEEP" = 1 ] || [ "$ENDED" = 1 ] || [ "$UNSENT" = 1 ] || prev_state=$(state_of "$PREV" "$PANE")
  [ -z "$prev_state" ] || case "$prev_state" in
    gone) ;;
    shell)
      # Not a Reviewer: a refused launch, or one that exited, at its shell.
      [[ "$PREV_LINE" != *" starting" ]] || die "Reviewer $PREV's terminal $PANE shows a shell, not the Reviewer: its launch may not have run. Look at it there; with no Reviewer running, end reviewer $SLOT's line in $MAP with \" unsent\" instead of \" starting\", then rerun  $KIT/add-reviewer.sh$RERUN_ARGS"
      UNSENT=1 ;;
    working) die "Reviewer $PREV is still working in $SLOT: wait until the slot is free, or use the other slot" ;;
    unreadable)
      rc=0; runner_pane_exists "$PANE" 2>/dev/null || rc=$?
      [ "$rc" != 3 ] || { stale_handle "Reviewer $PREV" "$PANE" "reviewer $SLOT's line" "" "$PREV"; exit 1; }
      die "$(runner_name) cannot say whether Reviewer $PREV is still there; rerun once $(runner_name) answers" ;;
    *)
      # A pending review whose Reviewer is not known to run (unknown: still
      # loading, or a screen the runner cannot read; blocked on a prompt) is
      # kept as it is: nothing says that review should end. An idle one of
      # another kind or model is replaced, as asked.
      [ "$RESUME" = 0 ] || [ "$prev_state" = idle ] || pending_stop "$prev_state"
      runner_send_text "$PANE" "/exit"
      [ "${DRY_RUN:-0}" = 1 ] || sleep 1
      runner_send_keys "$PANE" Enter
      # A runner that ends the agent for sure (Orca closes its terminal) leaves
      # no pane: the next Reviewer gets a new one (runner_reviewer_pane).
      # Its line says so at once: a rerun after a later failure must not read
      # the closed terminal's stale handle as one to rebind.
      if runner_end_agent "$PANE" 2>/dev/null; then ENDED=1; slot_line "$PREV_LINE ended"; fi
      waited=0
      until [ "$ENDED" = 1 ] || { state=$(state_of "$PREV" "$PANE"); [ "$state" = gone ]; }; do
        if [ "$waited" -ge "${EXIT_WAIT_SECONDS:-15}" ]; then
          [ "$state" != unreadable ] || die "$(runner_name) cannot say whether Reviewer $PREV exited; check $PANE, and rerun once $(runner_name) answers"
          die "Reviewer $PREV did not exit; end it in $PANE and rerun"
        fi
        if [ "$waited" -gt 0 ] && [ $((waited % 3)) -eq 0 ]; then
          runner_send_keys "$PANE" Enter 2>/dev/null || true   # best effort; the gone check decides
        fi
        [ "${DRY_RUN:-0}" = 1 ] || sleep 1
        waited=$((waited+1))
      done ;;
  esac
fi
ID="$SLOT-$N"

# A tab for the slots opens in the run's workspace, the orchestrator pane's;
# not whichever workspace the human is looking at. A tab line with R1 alone is
# a call that opened R1, then failed: R2 is still to open.
SLOTS_OPEN=1; [ -n "$TAB_LINE" ] && [ -n "$(slot_pane R2)" ] || SLOTS_OPEN=0
if [ "$SLOTS_OPEN" = 0 ]; then
  ORCH=$(orchestrator_of "$MAP")
  [ -n "$ORCH" ] || die "no orchestrator line in $MAP: run bootstrap.sh first"
  WS=$(runner_workspace "$ORCH" 2>/dev/null) \
    || die "no workspace for the orchestrator pane $ORCH (herdr pane get): is it still open?"
fi

# --- the review on the board: a refusal stops before anything opens ----------
# The id can already be there: an earlier call for this slot added it, then its
# Reviewer did not start, so no reviewer line counted it. That task is reused,
# under this call's title, while nobody has worked on it: pending on the board.
REUSED=0
if ! out=$(tower add "$TITLE" --id "$ID" --area review --lane "$SLOT" 2>&1); then
  case "$out" in
    *"task \"$ID\" already exists"*) ;;
    *) die "$out" ;;
  esac
  status=$(tower state --json | jsonq "next((t.get('status', '?') for t in d['tasks'] if t['id'] == '$ID'), 'missing')")
  [ "$status" = pending ] || die "task $ID is $status on the board, so not a failed start: check it, or  tower remove $ID  and rerun"
  tower change "$ID" --title "$TITLE" >/dev/null
  REUSED=1
fi
if [ "$REUSED" = 1 ] && [ "$KEEP" = 1 ]; then echo "reusing task $ID: the review resumed below"
elif [ "$REUSED" = 1 ]; then echo "reusing task $ID: an earlier call for $SLOT added it, but its Reviewer did not start"; fi

# --- the slots' tab, on the first call that has none ---------------------------
# No lanes tab yet, lane A in another tab (its line names one): it opens here,
# the column alone, R2 under R1; a code lane added later goes under R2
# (layout.sh). Else a reviews tab, R2 right of R1: a lanes tab without a
# column (nothing reviewed at bootstrap), or a pane map from before the lanes
# tab (lane lines without a tab), whose lanes are in the orchestrator's tab.
# Each tab is recorded as soon as it opens, before the next is asked for: the
# runner opens what it can at once (herdr: both; Orca: one a call), and a call
# that fails after R1 leaves R1 on the line, for the rerun to open R2 alone.
if [ "$SLOTS_OPEN" = 0 ]; then
  # A rerun keeps the key of the line that holds R1.
  LABEL=reviews; KEY="review tab:    "
  if { [ -n "$TAB_LINE" ] && [ "$TAB_LINE" = "$LANES_LINE" ]; } \
    || { [ -z "$LANES_LINE" ] && grep -qE '^lane A: .*, tab [a-z]+\)( starting| unsent)?$' "$MAP"; }; then
    LABEL=lanes; KEY="lanes tab:     "
  fi
  for _pass in 1 2; do   # two calls at most: R1, then R2
    [ -z "$(slot_pane R2)" ] || break
    R1_PANE=$(slot_pane R1); TAB=${TAB_LINE%% *}
    out=$(runner_open_reviewer_slots "$WS" "$REPO" "$LABEL" ${R1_PANE:+"$R1_PANE" "$TAB"}) || {
      [ -z "$R1_PANE" ] || die "add-reviewer: $(runner_name) opened R1's tab but not R2's: rerun  $KIT/add-reviewer.sh$RERUN_ARGS  to open it"
      exit 1; }   # nothing to record; the runner said why
    read -r TAB R1_PANE R2_PANE <<< "$out"
    TAB_LINE="$TAB   (R1 $R1_PANE${R2_PANE:+, R2 $R2_PANE})"
    tmp=$(mktemp "$MAP.XXXXXX"); { grep -v "^${KEY%%:*}:" "$MAP" || [ $? -eq 1 ]; } > "$tmp"
    echo "$KEY $TAB_LINE" >> "$tmp"; mv "$tmp" "$MAP"
  done
  [ -n "$(slot_pane R2)" ] || die "add-reviewer: $(runner_name) answered without R2's tab: check $MAP's tab line, then rerun  $KIT/add-reviewer.sh$RERUN_ARGS"
  echo "$LABEL tab: $TAB — slots R1 $R1_PANE, R2 $R2_PANE"
fi
# --- a fresh Reviewer in the slot ---------------------------------------------
# What can fail is done before a new tab opens; the tab's line is written
# right after it does.
NAME="$(cd "$REPO" && agent_name "-$(echo "$SLOT" | tr 'A-Z' 'a-z')-$N")"
mkdir -p "$(dirname "$FINDINGS")"
# A codex Reviewer's sandbox writes only the checkout and the run dir: its
# temp files and package caches (bunx, npm) go to the run dir's tmp.
if [ "$R_KIND" = codex ]; then AGENT_TMP="$RUN_DIR/tmp"; mkdir -p "$AGENT_TMP"; fi
# The kept Reviewer's pane stays; a fresh one gets the slot's pane, or a new
# one where the runner closed the last (runner_reviewer_pane).
# An unsent launch, or a bare shell, keeps its pane: the start goes there.
if [ "$KEEP" != 1 ] && [ "$UNSENT" != 1 ]; then
  PANE=$(slot_pane "$SLOT"); [ "$ENDED" != 1 ] || PANE=""
  PANE=$(runner_reviewer_pane "$SLOT" "$PANE" "$REPO")
fi
LINE=$(printf 'reviewer %s:    %s   (agent "%s", kind %s, model %s, review "%s", findings %s)' \
  "$SLOT" "$PANE" "$NAME" "$R_KIND" "$R_MODEL" "$TITLE" "$FINDINGS")
slot_line "$LINE starting"
if [ "$KEEP" = 1 ]; then echo "resuming $NAME in $PANE: its start failed earlier, and it now accepts input"
else
  rc=0; ( cd "$REPO" && start_agent_with_trust_retry "$NAME" "$PANE" ) || rc=$?
  case $rc in
    0) ;;
    3) slot_line "$LINE unsent"
       die "add-reviewer: Reviewer $NAME's launch was never sent: rerun  $KIT/add-reviewer.sh$RERUN_ARGS  to start it in $PANE" ;;
    4) die "add-reviewer: $(runner_name) cannot say whether Reviewer $NAME's launch reached $PANE (no receipt): look at that terminal before anything is sent again. A Reviewer there: rerun  $KIT/add-reviewer.sh$RERUN_ARGS  to resume it once it accepts input. No Reviewer, a shell: end reviewer $SLOT's line in $MAP with \" unsent\" instead of \" starting\", then rerun" ;;
    *) die "add-reviewer: Reviewer $NAME is not ready in $PANE; its review is in the pane map, starting: rerun  $KIT/add-reviewer.sh$RERUN_ARGS  to resume it" ;;
  esac
fi
slot_line "$LINE"

# The notes reviewer_for gave, "; "-separated: a credit guard's note (a skip
# or an unreadable candidate), already "reviewer: …", goes to the record too
# (ADR 0013); a fallback is printed.
if [ -n "$R_NOTE" ]; then
  while IFS= read -r _n; do
    case "$_n" in
      "reviewer: "*) echo "$_n"
                     tower note "$_n" >/dev/null </dev/null || echo "note: could not record '$_n' in tower" >&2 ;;
      *) echo "reviewer: $_n" ;;
    esac
  done <<< "${R_NOTE//; /$'\n'}"
  unset _n
fi
echo "reviewer $SLOT ready (task $ID): agent $NAME ($R_KIND, $R_MODEL) in $PANE — next: write $RUN_DIR/brief-$ID.md from brief-template.md (a Reviewer brief; findings to $FINDINGS), then  $KIT/send-brief.sh $RUN_DIR $NAME $RUN_DIR/brief-$ID.md  and add $NAME to watch-lanes.sh"
