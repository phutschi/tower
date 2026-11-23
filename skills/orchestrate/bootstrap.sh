#!/usr/bin/env bash
# Open a run: the record, the layout, and lane A's executor.
#
#   bootstrap.sh <run-dir> "<title>" <branch> [plan.md | tasks.tsv]
#
# Run it FROM the orchestrator's pane, inside the repo checkout on the
# integration branch (the feature branch), with HERDR_ENV=1.
#
# With a plan or task file (the planned opening) the task list is loaded and
# every task goes to lane A unless LANES="A=1-4 B=5,6" is set (<lane>=all
# gives that lane every task, and is then the only spec). Without one
# (the empty opening) the run has no tasks yet: the orchestrator derives them
# from the user's message and writes them with  tower add "<title>" --lane A
# before briefing anyone. LANES without a source is an error.
#
# tower is the record and the console. When tower does not run, bootstrap
# refuses before it creates anything and says how to install it.
#
# The layout, two tabs in the orchestrator pane's workspace (the lane grid
# grows with add-lane.sh):
#
#   the orchestrator's tab             lanes  (opened with --no-focus)
#   ┌──────────────┬──────────────┐    ┌──────────┬──────────┬──────────┐
#   │ orchestrator │ console      │    │ lane A   │ lane B   │ R1       │
#   │              ├───────┬──────┤    ├──────────┼──────────┼──────────┤
#   │              │ dev   │ shell│    │ lane C   │ lane D   │ R2       │
#   └──────────────┴───────┴──────┘    └──────────┴──────────┴──────────┘
#
# dev only when the repo declares it; without it the shell takes the space
# under the console. The console has half the tab, for its 60 columns. Lane
# A is the lanes tab's root. The R1/R2 column, a third of the tab, held for
# the Reviewer slots, is there only when LANE_REVIEW or PREFLIGHT is on.
# With session roles on and lane A's tasks in a role other than code or review
# (data, research, …; layout.sh lane_tab), lane A is the root of a  research
# tab instead, its pane map line  research tab: <tab-id> , and the lanes tab
# opens with the first code or review lane (add-lane.sh) or Reviewer
# (add-reviewer.sh).
#
# dev comes from .orchestrate (see example.orchestrate) and runs in lane A's
# checkout; only its command is shell code: a checkout path with an
# apostrophe or a space stays one directory. The shell is an empty one in the
# same checkout, for the human. There is no checks pane: each lane runs the
# check gate itself, and a  pane checks  line in .orchestrate is ignored with
# one info: line on stderr (detect-stack.sh). Lane A is EXECUTOR_KIND
# (claude | codex | cursor) on EXECUTOR_MODEL: .orchestrate sets the run's default,
# the environment of this call overrides it (executor.sh).
#
# Writes <run-dir>/panes.txt, the pane map for the whole run, then prints it
# with the next step. Its  lanes tab:  line holds the tab's id and the R1 and
# R2 panes, or  (no Reviewer column) ; or, with lane A in research, its
#  research tab:  line holds that tab's id. Lane A's line ends with its tab.
# The pane map's  switches:  line holds every run switch and the value this
# run uses (detect-stack.sh). Its  contract:  line names
# the pin: the .orchestrate read here, written read-only outside the run dir
# and the repo (detect-stack.sh), is what add-lane and add-reviewer read for
# the whole run; for them this line is only a pointer, never read. The
# switches: line goes to the record as a  tower note . So does the
#  reviewer:  line: the kind and model that review lane A (executor.sh
# reviewer_for; in a codex-only run add-reviewer.sh reviews a codex lane on
# that lane's model when the call names the lane), with the fallback note when
# one applied, or none
# when LANE_REVIEW and PREFLIGHT are both off. A forced REVIEWER_KIND that is
# not installed is refused before anything is written. The console pane
# stays open after the run: it is the record, and the human quits it with q.
# Nothing is torn down until the user says so.
#
# Session roles (roles.sh): with a Claude launcher (CLAUDE_ROUTER_ROLE set, or
# claude listing --role), bootstrap refuses to open a run anywhere but in an
# orchestrator session (CLAUDE_ROUTER_ROLE=orchestrator), before it creates
# anything, and says how to start one. A claude lane A then starts with
# --role (the role its plan tasks name in  Role: <role>  lines, code when
# none does) and --topic a-<its first task's title as a slug>; a LANES spec
# whose tasks name different roles is refused before the run exists. The plan's
# roles go to <run-dir>/roles.tsv for add-lane. Without the launcher none of
# this happens. Either way the pane map's  roles:  line says on, or off and
# why, and goes to the record as a  tower note .
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
. "$KIT/layout.sh"
need_runner; need git python3 node
[ $# -ge 3 ] || die 'usage: bootstrap.sh <run-dir> "<title>" <branch> [plan.md | tasks.tsv]'
RUN_DIR="$1"; TITLE="$2"; BRANCH="$3"; SOURCE="${4:-}"
[ -z "$SOURCE" ] || [ -f "$SOURCE" ] || die "no such plan or task file: $SOURCE"
# Session roles (roles.sh): with a Claude launcher, only an orchestrator
# session opens a run, refused here before anything exists.
. "$KIT/roles.sh"
roles_gate
[ -z "${LANES:-}" ] || [ -n "$SOURCE" ] || die 'LANES needs a plan or task file; in the empty opening assign lanes with  tower add "<title>" --lane <X>'
# LANES: specs <lane>=<ids> for lanes A-D, or one <lane>=all (every task, and
# then the whole of LANES). With a source and no LANES, it is A=all. Split
# without globbing and checked here; the <lane>=<ids> specs go to tower init,
# which checks the ids before the run exists. A run is all or nothing.
LANE_SPECS=(); LANE_ALL=""; LANE_INIT=()
if [ -n "${LANES+set}" ]; then
  read -r -a LANE_SPECS <<< "$LANES"
  [ "${#LANE_SPECS[@]}" -gt 0 ] || die "LANES is empty: give <lane>=<ids> specs (e.g. A=1-4,6 B=5) or <lane>=all"
elif [ -n "$SOURCE" ]; then
  LANE_SPECS=(A=all)
fi
_seen=" "
for _spec in ${LANE_SPECS[@]+"${LANE_SPECS[@]}"}; do
  case "$_spec" in
    [A-D]=*=*|[A-D]=) die "LANES '$_spec' is not <lane>=<ids> (e.g. A=1-4,6) or <lane>=all" ;;
    [A-D]=*) ;;
    *) die "LANES '$_spec' is not <lane>=<ids> or <lane>=all for a lane A to D" ;;
  esac
  case "$_seen" in
    *" ${_spec%%=*} "*) die "LANES names lane ${_spec%%=*} twice (LANES=\"$LANES\")" ;;
  esac
  _seen="$_seen${_spec%%=*} "
  if [ "${_spec#*=}" = all ]; then
    [ "${#LANE_SPECS[@]}" = 1 ] || die "LANES: <lane>=all must be the whole of LANES (got \"$LANES\")"
    LANE_ALL=${_spec%%=*}
  else
    LANE_INIT+=(--lane "$_spec")
  fi
done
unset _seen _spec
# With roles, each lane's tasks name one role at most: a plan whose lane mixes
# them is refused here, before the run exists. Lane A's role is its tasks'
# (code without a plan, with a task file, or with tasks that name none).
PLAN_ROLES=""; LANE_A_ROLE=code
if [ "$ROLES" = on ] && [ "${SOURCE##*.}" = md ]; then
  PLAN_ROLES=$(plan_roles "$SOURCE") || exit 1
  for _spec in ${LANE_SPECS[@]+"${LANE_SPECS[@]}"}; do
    _role=$(lane_role "${_spec#*=}" "$PLAN_ROLES" 2>&1) || die "LANES: lane ${_spec%%=*}'s $_role"
    [ "${_spec%%=*}" != A ] || LANE_A_ROLE=$_role
  done
  unset _spec _role
fi
# Lane A, dev and the shell all belong in the directory bootstrap runs in, which
# is often a herdr worktree of the checkout, not repo_root() (that resolves to
# the main checkout — the same resolution agent_name inlines for naming, and
# what add-lane.sh uses for the worktree location of lanes B-D).
REPO="$PWD"
AGENT_CHECKOUT="$REPO"   # executor.sh: lane A's sandbox grant follows its checkout
unset AGENT_LOOK         # executor.sh: look's worktree dir is a codex Reviewer's alone
unset CONTRACT_RUN  # bootstrap reads the checkout's contract, and pins it

need_tower

. "$KIT/detect-stack.sh"  # PM, CHECK_CMD, PANE_*, INSTALL_CMD, and .orchestrate's EXECUTOR_*/reviewer models
. "$KIT/executor.sh"      # EXECUTOR_KIND, EXECUTOR_MODEL, agent_name, start_agent*
[ -n "${SPEC_REVIEWER_MODEL:-}" ] || SPEC_REVIEWER_MODEL=$(kind_default SPEC_REVIEWER_MODEL "$EXECUTOR_KIND")
[ -n "${QUALITY_REVIEWER_MODEL:-}" ] || QUALITY_REVIEWER_MODEL=$(kind_default QUALITY_REVIEWER_MODEL "$EXECUTOR_KIND")
STALE="${STALE:-30}"
LANE_A="$(agent_name -lane-a)"
# Who reviews lane A (and every lane of its kind); refused here, before the run
# dir exists, when a forced REVIEWER_KIND is not installed. A forecast without
# the credit guard's probes: with the guard on, each review (add-reviewer.sh)
# probes then, and notes its skips.
if [ "$LANE_REVIEW" = off ] && [ "$PREFLIGHT" = off ]; then
  REVIEWER="none (LANE_REVIEW=off, PREFLIGHT=off)"
else
  _rev=$(REVIEWER_BY_CREDITS=off reviewer_for "$EXECUTOR_KIND")
  IFS=$'\t' read -r R_KIND R_MODEL R_NOTE <<< "$_rev"
  if [ "$REVIEWER_BY_CREDITS" = on ] && [ "$REVIEWER_KIND" = other ]; then
    [ -z "$R_NOTE" ] || R_NOTE="$R_NOTE; "
    R_NOTE="${R_NOTE}credit guard on: each review skips a kind below $REVIEWER_CREDITS_MIN% credits left"
  fi
  REVIEWER="kind $R_KIND, model $R_MODEL"
  [ -z "$R_NOTE" ] || REVIEWER="$REVIEWER ($R_NOTE)"
  unset _rev
fi

# --- the record --------------------------------------------------------------
# tower init makes the run dir, and only once everything it checks is right.
MODELS=(--model "implementer=$EXECUTOR_MODEL" --model "spec-reviewer=$SPEC_REVIEWER_MODEL" --model "quality-reviewer=$QUALITY_REVIEWER_MODEL")
case "$SOURCE" in
  # No source: an empty stdin, or tower init reads a task list from ours.
  "")   tower init --title "$TITLE" --run "$RUN_DIR" "${MODELS[@]}" </dev/null ;;
  *.md) tower init --plan "$SOURCE" --title "$TITLE" --run "$RUN_DIR" "${MODELS[@]}" ${LANE_INIT[@]+"${LANE_INIT[@]}"} ;;
  *)    tower init --tasks "$SOURCE" --title "$TITLE" --run "$RUN_DIR" "${MODELS[@]}" ${LANE_INIT[@]+"${LANE_INIT[@]}"} ;;
esac
export TOWER_RUN="$RUN_DIR"  # the calls below are about this run
# The contract as read here, pinned read-only for add-lane and add-reviewer
# (detect-stack.sh); empty but for its comment when the repo has none.
PIN=$(contract_pin "$RUN_DIR"); mkdir -p "$(dirname "$PIN")"
{ echo "# the repo contract bootstrap.sh read for the run $RUN_DIR"; [ ! -f "$CONTRACT_FILE" ] || cat "$CONTRACT_FILE"; } > "$PIN.$$"
chmod 444 "$PIN.$$"; mv -f "$PIN.$$" "$PIN"
# <lane>=all: every task on the board, known once the run exists.
[ -z "$LANE_ALL" ] || tower assign "$LANE_ALL" "$(tower state --json | jsonq '",".join(t["id"] for t in d["tasks"])')"
tower note "switches: $(switches_line)"
tower note "reviewer: $REVIEWER"
# Roles: the plan's for add-lane, and lane A's role and topic (a claude lane
# only; roles.sh). Without the launcher, one note says roles are skipped.
SESSION_ROLE=""; SESSION_TOPIC=""
if [ "$ROLES" = on ]; then
  printf '%s\n' "$PLAN_ROLES" | sed '/^$/d' > "$RUN_DIR/roles.tsv"
  ROLES_LINE=on
  if [ "$EXECUTOR_KIND" = claude ]; then
    SESSION_ROLE=$LANE_A_ROLE; SESSION_TOPIC=$(lane_topic A "$(lane_first_title A)")
  fi
else
  ROLES_LINE="off ($ROLES_WHY)"
fi
tower note "roles: $ROLES_LINE"
LANE_A_SESSION=""; [ -z "$SESSION_ROLE" ] || LANE_A_SESSION="role $SESSION_ROLE, topic $SESSION_TOPIC, "

# --- the layout --------------------------------------------------------------
SELF=$(runner_self) || die "bootstrap: $(runner_name) cannot say where the orchestrator runs"
WS=$(runner_workspace "$SELF") \
  || die "bootstrap: no workspace for the orchestrator pane $SELF ($(runner_name) cannot say)"
# The console, the shell, and dev when declared (runner_open_run_panes).
DEV_I=$(pane_index dev); DEV_PANE=""
if [ -n "$DEV_I" ]; then
  out=$(runner_open_run_panes "$WS" "$REPO" "tower --stale $STALE" "${PANE_DIRS[$DEV_I]}" "${PANE_CMDS[$DEV_I]}")
else
  out=$(runner_open_run_panes "$WS" "$REPO" "tower --stale $STALE")
fi
read -r CONSOLE_PANE SHELL_PANE DEV_PANE <<< "${out%%$'\n'*}"
RUN_PANES_LINES=$(sed 1d <<< "$out")
# Lane A's tab, lane A its root: the lanes tab, with the Reviewer column when
# anything reviews; with roles, the research tab for a lane A of a role other
# than code or review (layout.sh lane_tab), and the lanes tab waits for its
# first pane.
LANE_A_TAB=lanes; [ "$ROLES" != on ] || LANE_A_TAB=$(lane_tab "$LANE_A_ROLE")
out=$(runner_open_lane_a "$WS" "$REPO" "$LANE_A_TAB")
read -r LANE_A_PANE TAB_REST <<< "$out"

# --- the pane map, before the agent start so add-lane and the brief have it even if that fails
{
  echo "run dir:        $RUN_DIR"
  echo "orchestrator:   $SELF"
  printf '%-16s%s\n' "$LANE_A_TAB tab:" "$TAB_REST"
  echo "lane A:         $LANE_A_PANE   (agent \"$LANE_A\", kind $EXECUTOR_KIND, ${LANE_A_SESSION}branch $BRANCH, checkout $REPO, model $EXECUTOR_MODEL, tab $LANE_A_TAB)"
  [ -z "$DEV_PANE" ] || echo "dev:            $DEV_PANE   (${PANE_CMDS[$DEV_I]} in ${PANE_DIRS[$DEV_I]})"
  echo "shell:          $SHELL_PANE   (a shell in $REPO, for the human)"
  echo "console:        $CONSOLE_PANE   (tower; the record — stays open, the human quits it with q)"
  [ -z "$RUN_PANES_LINES" ] || echo "$RUN_PANES_LINES"
  echo "check gate:     $CHECK_CMD"
  echo "contract:       $PIN"
  echo "switches:       $(switches_line)"
  echo "reviewer:       $REVIEWER"
  echo "roles:          $ROLES_LINE"
  echo "toolchain:      $PM"
  echo "read a pane:    $(runner_read_cmd)"
  echo "message a pane: $(runner_message_cmd)"
} > "$RUN_DIR/panes.txt"

# bootstrap has no rerun: an agent left running is briefed once it accepts
# input; with none there, the run starts over; when herdr cannot answer, a
# look at the pane tells which it is.
if ! start_agent_with_trust_retry "$LANE_A" "$LANE_A_PANE"; then
  case "$(state_of "$LANE_A" "$LANE_A_PANE")" in
    gone) die "bootstrap: lane A's agent $LANE_A is not running in $LANE_A_PANE: see above for why, then rerun bootstrap.sh with a new run dir" ;;
    unreadable) die "bootstrap: herdr cannot say whether lane A's agent $LANE_A runs in $LANE_A_PANE; the run and its pane map ($RUN_DIR/panes.txt) are set up: check that pane, and with the agent there brief it once  herdr agent get $LANE_A  shows interactive_ready true; with none, rerun bootstrap.sh with a new run dir" ;;
  esac
  die "bootstrap: lane A's agent $LANE_A is not ready in $LANE_A_PANE; the run and its pane map ($RUN_DIR/panes.txt) are set up: see above for the agent, and brief it once it accepts input"
fi

cat "$RUN_DIR/panes.txt"
echo
if [ -n "$SOURCE" ]; then
  echo "next:  brief lane A (tower brief A > $RUN_DIR/brief-A.md, then brief-template.md), then"
else
  echo "next:  the task list — derive it from the user's message, then"
  echo "       tower add \"<title>\" --area <area> --lane A   per task (lanes B-D: add-lane.sh, then --lane B …)"
  echo "       brief lane A (brief-template.md), then"
fi
echo "       $(runner_message_cmd "$LANE_A" "$LANE_A_PANE" "\$(cat $RUN_DIR/brief-A.md)")"
echo "more lanes:  $KIT/add-lane.sh $RUN_DIR B <branch> $BRANCH <ids>"
echo "watch:       tower wait --stale $STALE   and   $KIT/watch-lanes.sh $RUN_DIR $LANE_A   (both in the background)"
