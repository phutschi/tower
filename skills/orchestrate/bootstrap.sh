#!/usr/bin/env bash
# Open a run: the record, the layout, and lane A's executor.
#
#   bootstrap.sh <run-dir> "<title>" <branch> [plan.md | tasks.tsv]
#
# Run it FROM the orchestrator's pane, inside the repo checkout on the
# integration branch (the feature branch), with HERDR_ENV=1.
#
# With a plan or task file (the planned opening) the task list is loaded and
# every task goes to lane A unless LANES="A=1-4 B=5,6" is set. Without one
# (the empty opening) the run has no tasks yet: the orchestrator derives them
# from the user's message and writes them with  tower add "<title>" --lane A
# before briefing anyone. LANES without a source is an error.
#
# tower is the record and the console. When tower does not run, bootstrap
# refuses before it creates anything and says how to install it.
#
# The layout, one tab (the lane grid grows with add-lane.sh):
#
#        ┌──────────────┬──────────┬──────────┐
#        │ orchestrator │ lane A   │ lane B   │
#        │              ├──────────┼──────────┤
#        │              │ lane C   │ lane D   │
#        ├──────┬───────┴──┬───────┴──────────┤
#        │ dev  │ checks   │ console          │   ← dev only when the repo declares it
#        └──────┴──────────┴──────────────────┘
#
# checks and dev come from .orchestrate (see example.orchestrate)
# or the JS default (detect-stack.sh); both run in lane A's checkout. With no
# checks pane declared and no test runner detected, one info: line on stderr
# says so. Lane A is EXECUTOR_KIND (claude | codex) on EXECUTOR_MODEL:
# .orchestrate sets the run's default, the environment of this call
# overrides it (executor.sh).
#
# Writes <run-dir>/panes.txt, the pane map for the whole run, then prints it
# with the next step. The pane map's  switches:  line holds every run switch
# and the value this run uses (detect-stack.sh); the same line goes to the
# record as a  tower note . So does the
#  reviewer:  line: the kind and model that review lane A (executor.sh
# reviewer_for; in a codex-only run add-reviewer.sh reviews a codex lane on
# that lane's model when the call names the lane), with the fallback note when
# one applied, or none
# when LANE_REVIEW and PREFLIGHT are both off. A forced REVIEWER_KIND that is
# not installed is refused before anything is written. The console pane
# stays open after the run: it is the record, and the human quits it with q.
# Nothing is torn down until the user says so.
#
# START_TRIES (environment, default 10): how often an agent start is tried,
# a second apart, while its new pane's shell is not ready yet (executor.sh).
#
# Never run this for real to see what it does; use DRY_RUN=1, which answers
# every herdr, claude and codex call from tests/stub and opens nothing; tower
# is the real CLI from this checkout and records the run in the run dir.
set -euo pipefail
KIT="$(cd "$(dirname "$0")" && pwd)"
. "$KIT/common.sh"
in_herdr; need git python3 node
[ $# -ge 3 ] || die 'usage: bootstrap.sh <run-dir> "<title>" <branch> [plan.md | tasks.tsv]'
RUN_DIR="$1"; TITLE="$2"; BRANCH="$3"; SOURCE="${4:-}"
[ -z "$SOURCE" ] || [ -f "$SOURCE" ] || die "no such plan or task file: $SOURCE"
[ -z "${LANES:-}" ] || [ -n "$SOURCE" ] || die 'LANES needs a plan or task file; in the empty opening assign lanes with  tower add "<title>" --lane <X>'
# Lane A, checks, and dev all belong in the directory bootstrap runs in, which
# is often a herdr worktree of the checkout, not repo_root() (that resolves to
# the main checkout — the same resolution agent_name inlines for naming, and
# what add-lane.sh uses for the worktree location of lanes B-D).
REPO="$PWD"

need_tower

. "$KIT/detect-stack.sh"  # PM, CHECK_CMD, PANE_*, INSTALL_CMD, and .orchestrate's EXECUTOR_*/reviewer models
. "$KIT/executor.sh"      # EXECUTOR_KIND, EXECUTOR_MODEL, agent_name, start_agent*
SPEC_REVIEWER_MODEL="${SPEC_REVIEWER_MODEL:-sonnet}"
QUALITY_REVIEWER_MODEL="${QUALITY_REVIEWER_MODEL:-opus}"
STALE="${STALE:-30}"
LANE_A="$(agent_name -lane-a)"
# Who reviews lane A (and every lane of its kind); refused here, before the run
# dir exists, when a forced REVIEWER_KIND is not installed.
if [ "$LANE_REVIEW" = off ] && [ "$PREFLIGHT" = off ]; then
  REVIEWER="none (LANE_REVIEW=off, PREFLIGHT=off)"
else
  _rev=$(reviewer_for "$EXECUTOR_KIND")
  IFS=$'\t' read -r R_KIND R_MODEL R_NOTE <<< "$_rev"
  REVIEWER="kind $R_KIND, model $R_MODEL${R_NOTE:+ ($R_NOTE)}"
  unset _rev
fi

# --- the record --------------------------------------------------------------
mkdir -p "$RUN_DIR"
MODELS=(--model "implementer=$EXECUTOR_MODEL" --model "spec-reviewer=$SPEC_REVIEWER_MODEL" --model "quality-reviewer=$QUALITY_REVIEWER_MODEL")
case "$SOURCE" in
  # No source: an empty stdin, or tower init reads a task list from ours.
  "")   tower init --title "$TITLE" --run "$RUN_DIR" "${MODELS[@]}" </dev/null ;;
  *.md) tower init --plan "$SOURCE" --title "$TITLE" --run "$RUN_DIR" "${MODELS[@]}" ;;
  *)    tower init --tasks "$SOURCE" --title "$TITLE" --run "$RUN_DIR" "${MODELS[@]}" ;;
esac
export TOWER_RUN="$RUN_DIR"  # the calls below are about this run
if [ -n "${LANES:-}" ]; then
  for spec in $LANES; do tower assign "${spec%%=*}" "${spec#*=}"; done
elif [ -n "$SOURCE" ]; then
  tower assign A "$(tower state --json | jsonq '",".join(t["id"] for t in d["tasks"])')"
fi
tower note "switches: $(switches_line)"
tower note "reviewer: $REVIEWER"

# --- the layout --------------------------------------------------------------
split() { herdr pane split "$@" --cwd "$REPO" --no-focus | pane_id; }
run_in() { herdr pane run "$1" "cd '$REPO/$2' && $3" >/dev/null; }
BOTTOM=$(split --current --direction down --ratio 0.7)
LANE_A_PANE=$(split --current --direction right --ratio 0.3)
CHECKS_I=$(pane_index checks); DEV_I=$(pane_index dev)
if [ -n "$DEV_I" ]; then
  DEV_PANE=$BOTTOM
  CHECKS_PANE=$(split --pane "$BOTTOM" --direction right --ratio 0.34)
  CONSOLE_PANE=$(split --pane "$CHECKS_PANE" --direction right --ratio 0.5)
  run_in "$DEV_PANE" "${PANE_DIRS[$DEV_I]}" "${PANE_CMDS[$DEV_I]}"
else
  DEV_PANE=""
  CHECKS_PANE=$BOTTOM
  CONSOLE_PANE=$(split --pane "$BOTTOM" --direction right --ratio 0.5)
fi
run_in "$CHECKS_PANE" "${PANE_DIRS[$CHECKS_I]}" "${PANE_CMDS[$CHECKS_I]}"
[ "$NO_RUNNER" = 0 ] || echo 'info: no test runner detected: the checks pane has nothing to run; declare  pane checks "<cmd>"  in .orchestrate' >&2
herdr pane run "$CONSOLE_PANE" "tower --stale $STALE" >/dev/null

# --- the pane map, before the agent start so add-lane and the brief have it even if that fails
{
  echo "run dir:        $RUN_DIR"
  echo "orchestrator:   $HERDR_PANE_ID"
  echo "lane A:         $LANE_A_PANE   (agent \"$LANE_A\", kind $EXECUTOR_KIND, branch $BRANCH, checkout $REPO, model $EXECUTOR_MODEL)"
  echo "checks:         $CHECKS_PANE   (${PANE_CMDS[$CHECKS_I]} in ${PANE_DIRS[$CHECKS_I]})"
  [ -z "$DEV_PANE" ] || echo "dev:            $DEV_PANE   (${PANE_CMDS[$DEV_I]} in ${PANE_DIRS[$DEV_I]})"
  echo "console:        $CONSOLE_PANE   (tower; the record — stays open, the human quits it with q)"
  echo "check gate:     $CHECK_CMD"
  echo "switches:       $(switches_line)"
  echo "reviewer:       $REVIEWER"
  echo "toolchain:      $PM"
  echo "read a pane:    herdr pane read <id> --source recent-unwrapped --lines 60"
} > "$RUN_DIR/panes.txt"

start_agent_with_trust_retry "$LANE_A" "$LANE_A_PANE"

cat "$RUN_DIR/panes.txt"
echo
if [ -n "$SOURCE" ]; then
  echo "next:  brief lane A (tower brief A > $RUN_DIR/brief-A.md, then brief-template.md), then"
else
  echo "next:  the task list — derive it from the user's message, then"
  echo "       tower add \"<title>\" --area <area> --lane A   per task (lanes B-D: add-lane.sh, then --lane B …)"
  echo "       brief lane A (brief-template.md), then"
fi
echo "       herdr agent prompt $LANE_A \"\$(cat $RUN_DIR/brief-A.md)\""
echo "more lanes:  $KIT/add-lane.sh $RUN_DIR B <branch> $BRANCH <ids>"
echo "watch:       tower wait --timeout 540 --stale $STALE   and   $KIT/watch-lanes.sh $RUN_DIR $LANE_A   (both in the background)"
