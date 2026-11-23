#!/usr/bin/env bash
# Add a lane: a git worktree with its own executor, placed in the lane grid,
# owning the given task ids.
#
#   [EXECUTOR_KIND=claude|codex|cursor] add-lane.sh <run-dir> <B|C|D> <branch> <base-branch> <task-ids>
#
# Four lanes at most. Lane A is started by bootstrap.sh in the main checkout.
# The new lane goes into the lanes tab (the pane map's  lanes tab:  line;
# layout.sh), left of its Reviewer column, by its place among the lanes
# already there, whatever their letters: the second right of the first, the
# third under the first, the fourth under the second.
#
#        │ 1st      │ 2nd      │ R1
#        ├──────────┼──────────┤
#        │ 3rd      │ 4th      │ R2
#
# With session roles on, a lane of any kind whose tasks name a role other than
# code or review goes to the  research  tab instead, its grid of its own. A
# tab not open yet opens with the lane: its pane moves into a new tab in the
# orchestrator pane's workspace, unfocused, and the pane map gets its
# research tab:  or  lanes tab:  line (the lanes tab with its Reviewer column
# when anything reviews). The lane's line ends with its tab ( tab lanes  or
# tab research ). A pane map from before the lanes tab (no  lanes tab:  or
# research tab:  line) has its lanes in the orchestrator's tab: the new lane
# goes there, and its line has no tab, as the others.
#
# The kind is per lane (executor.sh). Worktrees live at
# <repo>/.worktrees/<branch> (in Orca, a child worktree of the orchestrator's
# workspace, where Orca puts it, with no grid and no move); INSTALL_CMD installs (from here, log in
# <run-dir>/install-<lane>.log): the repo contract's, else the package manager's
# when there is a package.json, else nothing, said in one line. .env
# (gitignored) is copied once the agent owns the pane. The worktree shares the
# repo's common git dir, so `tower` inside it finds the run with no flags.
# Without a runnable tower it refuses before anything is created. A run
# switch with a value outside its list (see detect-stack.sh) is refused here
# as in bootstrap.sh; the run's values are the pane map's  switches:  line.
#
# In a run with session roles (the pane map's  roles: on , roles.sh), a claude
# lane starts with --role, the one role its tasks name (code when none does),
# and --topic <lane letter>-<its first task's title as a slug> (a rerun keeps
# the topic in the lane's pane map line); tasks that
# name different roles are refused before anything is created. The pane map's
# lane line then holds  role <role>, topic <topic>,  after its kind.
#
# START_TRIES (environment, default 10): how often an agent start is tried,
# a second apart, while its new pane's shell is not ready yet (executor.sh).
# The agent is reported ready only once it accepts input (herdr's
# interactive_ready), read about a second apart READY_WAIT_SECONDS times
# (default 30) after START_SETTLE_SECONDS (default 3); one that exits right
# after its start is started once more, and one that never accepts input
# fails the call and is left running in its pane (executor.sh).
#
# The new pane goes into the pane map as  unplaced lane <X>:  before it is
# moved into the grid, and becomes the lane's line before its agent starts,
# ending in " starting" until the agent accepts input. When the move or the
# start fails, rerun the same call: an unplaced lane's pane is moved again; a
# lane whose agent herdr does not find is started again in the lane's pane and
# worktree; and a starting lane's agent left running is taken ("resumed") once
# it accepts input, or refused, saying to answer or end it, while it does not.
# A launch the runner proves it never sent ends the line in " unsent"
# instead, and the rerun starts the agent once in that pane, while its screen
# shows a shell (Orca: its terminal stays open). One sent without a receipt
# stays " starting": look at the terminal before anything is typed again.
# Nothing else is redone (the worktree exists and the task ids are assigned).
# Refused before anything is created: a kind whose CLI is not installed
# (executor.sh need_kind, which names it), on a rerun too.
# Refused: a started lane whose agent runs, any answer from herdr other than
# agent_not_found, a rerun with another branch, kind, model or task ids than
# the first call's (ids expanded by `tower ids`, so an id tower refuses is
# refused in its words), and a lane whose pane (herdr's pane_not_found) or
# worktree is gone: the message says what to remove. So is a checkout on the
# lane's line that git does not name as this repo's worktree on its branch.
# A pane herdr cannot be asked about is refused with nothing to remove; rerun
# once herdr answers.
# Not resumed, but said: a worktree create that fails or answers with no pane
# (remove what it made, then rerun), and a move whose answer names no pane
# (the moved pane's id goes into the map by hand; the install ran before the
# move).
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
need_tower
[ $# -eq 5 ] || die 'usage: add-lane.sh <run-dir> <B|C|D> <branch> <base-branch> <task-ids>'
RUN_DIR="$1"; LANE="$2"; BRANCH="$3"; BASE="$4"; TASKS="$5"
MAP="$RUN_DIR/panes.txt"
[ -f "$MAP" ] || die "no pane map at $MAP: run bootstrap.sh first"
# Every tower call is about this run, wherever it is called from.
RUN_DIR="$(cd "$RUN_DIR" && pwd)"; MAP="$RUN_DIR/panes.txt"; export TOWER_RUN="$RUN_DIR"
lane_pane() { sed -nE "s/^lane $1: +([^ ]+).*/\1/p" "$MAP"; }

case "$LANE" in
  B|C|D) ;;
  A) die "lane A is started by bootstrap.sh" ;;
  *) die "lane must be B, C or D (four lanes at most)" ;;
esac
PANE=$(lane_pane "$LANE")   # set: a rerun, the lane is already in the map
UNPLACED=$(sed -nE "s/^unplaced lane $LANE: +([^ ]+).*/\1/p" "$MAP")   # set: a rerun after a failed move

REPO_ROOT="$(repo_root)"
# The lane's checkout: its pane map line's on a rerun (a runner may have
# named its own), else under the repo's .worktrees.
WT=$(grep -E "^(unplaced )?lane $LANE: " "$MAP" | sed -nE 's/.*, checkout (.*), model .*/\1/p' | head -1 || true)
[ -n "$WT" ] || WT="$REPO_ROOT/.worktrees/$BRANCH"
AGENT_CHECKOUT="$WT"   # executor.sh: a codex lane's sandbox grant follows its worktree
unset AGENT_LOOK       # executor.sh: look's worktree dir is a codex Reviewer's alone
_here="$PWD"; cd "$REPO_ROOT"
CONTRACT_RUN="$RUN_DIR" . "$KIT/detect-stack.sh"   # the run's pinned contract: INSTALL_CMD, .orchestrate's EXECUTOR_* (the environment wins); refuses a bad run switch
cd "$_here"; unset _here
. "$KIT/executor.sh"       # EXECUTOR_KIND, EXECUTOR_MODEL, agent_name, start_agent*
# A rerun keeps the lane's kind: installing it is the only way on.
grep -qE "^(unplaced )?lane $LANE: " "$MAP" && _hint=", then rerun"
need_kind "add-lane: lane $LANE" "$EXECUTOR_KIND" "${_hint:-}"; unset _hint
NAME="$(agent_name "-lane-$(echo "$LANE" | tr 'A-Z' 'a-z')")"
# Session roles (roles.sh), when the pane map says the run has them: the role
# the lane's tasks name (<run-dir>/roles.tsv), code when none does, refused
# before anything is created when they name more than one; the topic is the
# lane's letter and its first task's title. Only a claude lane starts with them;
# the role picks the tab of a lane of any kind (layout.sh lane_tab).
. "$KIT/roles.sh"
SESSION_ROLE=""; SESSION_TOPIC=""; LANE_SESSION=""; LANE_ROLE=""
if roles_on "$MAP"; then
  _ids=$(tower ids -- "$TASKS" 2>/dev/null) \
    || die "add-lane: $(tower ids -- "$TASKS" 2>&1 >/dev/null | sed -e '1s/^tower: //' -e '2,$s/^/   /')"
  LANE_ROLE=$(lane_role "$TASKS" "$(cat "$RUN_DIR/roles.tsv" 2>/dev/null || true)" 2>&1) || die "add-lane: lane $LANE's $LANE_ROLE"
  if [ "$EXECUTOR_KIND" = claude ]; then
    SESSION_ROLE=$LANE_ROLE
    # A rerun keeps the topic the lane's line already has: its first task may
    # have been renamed since (tower change).
    SESSION_TOPIC=$(grep -E "^(unplaced )?lane $LANE: " "$MAP" | sed -nE 's/.*, topic ([^,]+), branch .*/\1/p' | head -1 || true)
    [ -n "$SESSION_TOPIC" ] || SESSION_TOPIC=$(lane_topic "$LANE" "$(tasks_first_title "$_ids")")
    LANE_SESSION="role $SESSION_ROLE, topic $SESSION_TOPIC, "
  fi
  unset _ids
fi
# The lane's tab ends its line; a pane map from before the lanes tab (no
# lanes or research tab: line) keeps its lanes in the orchestrator's tab and
# its lines without a tab, so its reruns still match.
TAB_LABEL=$(lane_tab "$LANE_ROLE"); TAB_FIELD=", tab $TAB_LABEL"
grep -qE '^(lanes|research) tab:' "$MAP" || { TAB_LABEL=lanes; TAB_FIELD=""; }
lane_line() { printf 'lane %s:         %s   (agent "%s", kind %s, %sbranch %s, checkout %s, model %s%s)\n' \
  "$LANE" "$1" "$NAME" "$EXECUTOR_KIND" "$LANE_SESSION" "$BRANCH" "$WT" "$EXECUTOR_MODEL" "$TAB_FIELD"; }

# A rerun's checks. $1 is the lane's line in the pane map as the first call
# wrote it, $2 its pane, $3 what that line is called in a message.
check_rerun() {
  [ "$(grep -E "^(unplaced )?lane $LANE:" "$MAP")" = "$1" ] \
    || die "lane $LANE is in the pane map with another branch, kind or model; rerun with the ones it has (see $MAP)"
  # The ids against what the lane owns on the board, expanded by tower itself
  # (tower ids, which records nothing). An id tower refuses is refused with
  # tower's words.
  local board want owned err
  board=$(tower state --json) || die "add-lane: tower state failed; rerun once tower answers"
  # stdout alone is the ids; tower's refusal is asked for again, on failure only.
  want=$(tower ids -- "$TASKS" 2>/dev/null) \
    || die "add-lane: $(tower ids -- "$TASKS" 2>&1 >/dev/null | sed -e '1s/^tower: //' -e '2,$s/^/   /')"
  owned=$(printf '%s' "$board" | jsonq "','.join(d['lanes'].get('$LANE', []))")
  [ "$(printf '%s\n' "$want" | sort)" = "$(printf '%s\n' "$owned" | tr , '\n' | sort)" ] \
    || die "lane $LANE owns ${owned:-nothing} on the board, not $TASKS; rerun with those ids"
  # Only a pane the runner says is gone is closed; any other failure says
  # nothing about it, and the map and the worktree stay.
  local rc=0
  err=$(runner_pane_exists "$2" 2>&1) || rc=$?
  if [ "$rc" != 0 ]; then
    case "$rc" in
      1)
        # herdr gives a moved pane a new id: an unplaced pane that is gone may
        # be in the grid already, its move done but not recorded.
        [ "$3" != "unplaced line" ] \
          || die "lane $LANE's pane $2 is gone ($(runner_pane_check)), or was moved without its new id recorded: look for $WT in the grid; if a pane has it, turn  unplaced lane $LANE: $2  in $MAP into  lane $LANE: <that pane's id>  (the rest as it is) and rerun, else remove the unplaced line from $MAP and the worktree $WT, then add the lane again"
        die "lane $LANE's pane $2 is gone ($(runner_pane_check)): remove its $3 from $MAP and the worktree $WT, then add the lane again" ;;
      3) [ "$3" = line ] || { stale_handle "lane $LANE" "$2" "its $3"; exit 1; }
         stale_handle "lane $LANE" "$2" "its $3" "$(restart_by_hand)"; exit 1 ;;
      *) die "$(runner_name) cannot say whether lane $LANE's pane $2 is open; rerun once $(runner_name) answers ($(runner_name): ${err:-no output})" ;;
    esac
  fi
  [ -d "$WT" ] || die "lane $LANE's checkout $WT is gone: close its pane $2 and remove its $3 from $MAP, then add the lane again"
  # A lane can write the pane map (docs/orchestrate.md): its checkout is used
  # only when git names it as this repo's worktree on the lane's branch.
  # Everything after uses git's path, not the map's spelling (a link in the
  # run dir could be swapped after this check).
  local bw; bw=$(branch_worktree)
  [ "$bw" = "$(cd "$WT" && pwd -P)" ] \
    || die "lane $LANE's checkout $WT in $MAP is not this repo's worktree on branch $BRANCH: git has ${bw:-none} on it (git worktree list); set its checkout to that, then rerun  $RERUN"
  WT=$bw; AGENT_CHECKOUT=$bw
}
# The checkout git has on $BRANCH among this repo's worktrees, its real path;
# empty when there is none.
branch_worktree() {
  local p
  p=$(git -C "$REPO_ROOT" worktree list --porcelain | awk -v b="branch refs/heads/$BRANCH" '/^worktree /{p=substr($0,10)} $0==b{print p; exit}')
  [ -z "$p" ] || (cd "$p" 2>/dev/null && pwd -P)
}

# Replaces the pane map's line matching $1 (a grep pattern) with $2 at the
# end of the map, through a scratch file of this call's own; on failure the
# map is kept whole and the call dies with $3.
replace_map_line() {
  local tmp rc=0
  tmp=$(mktemp "$MAP.XXXXXX") || die "$3"
  grep -v "$1" "$MAP" > "$tmp" || rc=$?
  { [ "$rc" -le 1 ] && echo "$2" >> "$tmp"; } || { rm -f "$tmp"; die "$3"; }
  mv "$tmp" "$MAP"
}
# Rewrites lane $LANE's line as $1 where it is: its place is its place in the
# grid (layout.sh).
set_lane_line() {
  local tmp failed="add-lane: could not rewrite $MAP; set lane $LANE's line to  $1  and rerun"
  tmp=$(mktemp "$MAP.XXXXXX") || die "$failed"
  NEW="$1" awk -v pat="^lane $LANE:" '$0 ~ pat { print ENVIRON["NEW"]; next } { print }' "$MAP" > "$tmp" \
    || { rm -f "$tmp"; die "$failed"; }
  mv "$tmp" "$MAP"
}
RERUN="$KIT/add-lane.sh $RUN_DIR $LANE $BRANCH $BASE $TASKS"
# For a placed lane whose terminal was closed: how to start its agent again
# by hand, with the model and grants a start gives it (executor.sh
# launch_line). Only when the lane's line is this call's (kind, model) and
# git names its checkout: the map is lane-writable. Otherwise nothing, and
# stale_handle says its default.
restart_by_hand() {
  local line
  [ "$(grep -E "^lane $LANE: " "$MAP")" = "$(lane_line "$PANE")${STARTING:-}" ] || return 0
  [ -d "$WT" ] && [ "$(branch_worktree)" = "$(cd "$WT" && pwd -P)" ] || return 0
  line=$(launch_line 2>/dev/null) || return 0
  echo "open a terminal in $WT, start the agent there with  cd $(printf %q "$WT") && $line, put that terminal's handle on lane $LANE's line in $MAP, and brief it with send-brief.sh (no rerun)"
}
STARTED_AGAIN="started again"
# Starts the lane's agent in $PANE, or dies saying how to resume. A launch the
# runner proves it never sent (executor.sh's 3) is recorded as unsent: the
# rerun starts it once, in the same pane. One sent without a receipt (4) stays
# starting: someone looks at the terminal before anything is typed again.
start_lane() {
  local rc=0
  start_agent_with_trust_retry "$NAME" "$PANE" || rc=$?
  case $rc in
    0) ;;
    3) set_lane_line "$(lane_line "$PANE") unsent"
       die "add-lane: lane $LANE's launch was never sent: rerun  $RERUN  to start it in $PANE" ;;
    4) die "add-lane: $(runner_name) cannot say whether lane $LANE's launch reached $PANE (no receipt): look at that terminal before anything is sent again. An agent there: rerun  $RERUN  to take it once it accepts input. No agent, a shell: end lane $LANE's line in $MAP with \" unsent\" instead of \" starting\", then rerun" ;;
    *) die "add-lane: agent $NAME is not ready in $PANE; lane $LANE is in the pane map, starting: rerun  $RERUN  to resume it" ;;
  esac
}

if [ -n "$PANE" ]; then
  # A rerun. A line still ending in " starting" is a start that failed: its
  # agent is taken when it accepts input, started again when herdr does not
  # find it, and otherwise left to the human; one ending in " unsent" is a
  # launch never sent, started once now. On a started lane, its agent
  # running means the lane exists, and herdr not finding it means it is
  # started again. Any other answer from herdr decides nothing.
  STARTING=""
  case "$(grep -E "^lane $LANE:" "$MAP")" in
    *" starting") STARTING=" starting" ;;
    *" unsent")   STARTING=" unsent" ;;
  esac
  state=$(state_of "$NAME" "$PANE")
  case "$state" in
    gone) ;;
    unreadable)
      rc=0; runner_pane_exists "$PANE" 2>/dev/null || rc=$?
      [ "$rc" != 3 ] || { stale_handle "lane $LANE" "$PANE" "lane $LANE's line" "$(restart_by_hand)"; exit 1; }
      die "lane $LANE: $(runner_name) cannot say whether agent $NAME runs; rerun once $(runner_name) answers" ;;
    *) [ -n "$STARTING" ] || die "lane $LANE already exists (see $MAP)" ;;
  esac
  check_rerun "$(lane_line "$PANE")$STARTING" "$PANE" line
  [ "$STARTING" != " unsent" ] || [ "$state" != working ] \
    || die "lane $LANE: an agent is working in $PANE although its launch was never sent; check it there, and end it before you rerun"
  # A launch is typed only where the screen shows a shell, nothing else.
  [ "$STARTING" != " unsent" ] || runner_pane_at_shell "$PANE" \
    || die "lane $LANE's launch was never sent, but terminal $PANE's screen does not show a shell: check it there (an agent started by hand?), then rerun  $RERUN"
  if [ "$state" = gone ] || [ "$STARTING" = " unsent" ]; then
    set_lane_line "$(lane_line "$PANE") starting"
    start_lane
  else
    ready=$(ready_of "$NAME" "$PANE")
    [ "$ready" = ready ] || die "add-lane: agent $NAME is in $PANE but does not accept input ($ready): answer or end it there, then rerun  $RERUN"
    STARTED_AGAIN="resumed"
  fi
  set_lane_line "$(lane_line "$PANE")"
  [ -f "$WT/.env" ] || cp "$REPO_ROOT/.env" "$WT/.env" 2>/dev/null || true
  echo "lane $LANE ready: agent $NAME in $PANE ($STARTED_AGAIN) — next:  tower brief $LANE > $RUN_DIR/brief-$LANE.md, add the judgement (brief-template.md, with merge points in both briefs), then  $KIT/send-brief.sh $RUN_DIR $NAME $RUN_DIR/brief-$LANE.md"
  exit 0
fi

if [ -n "$UNPLACED" ]; then
  # A rerun after a failed move: the worktree and its pane exist and the ids
  # are assigned. Only the move and what follows it are left.
  check_rerun "unplaced $(lane_line "$UNPLACED")" "$UNPLACED" "unplaced line"
  WT_PANE="$UNPLACED"
else
  # Ownership first: tower refuses an unknown id, so a typo stops here, before
  # a worktree exists.
  tower assign -- "$LANE" "$TASKS"
  out=$(runner_open_lane "$REPO_ROOT" "$BRANCH" "$BASE" "$WT" "$NAME")
  read -r WT_PANE _wt <<< "$out"; WT=${_wt:-$WT}; AGENT_CHECKOUT=$WT; unset _wt
  # The new pane goes into the map before it is moved: a move that fails
  # leaves a lane a rerun can place.
  echo "unplaced $(lane_line "$WT_PANE")" >> "$MAP"
fi
# The install runs here, not typed into the pane: text sent to a shell that is
# still starting up can be swallowed by a startup hook reading the tty (the
# oh-my-zsh dotenv plugin does exactly that when it finds a .env). Same wait
# as before, from a subshell, with the output kept in the run dir. It runs
# before the move, so a lane placed by hand after a failed move is installed.
INSTALL_LOG="$RUN_DIR/install-$LANE.log"
if [ -z "$INSTALL_CMD" ]; then echo "add-lane: no install: $INSTALL_WHY"
elif [ "${DRY_RUN:-0}" = 1 ]; then echo "[dry-run] (cd $WT && $INSTALL_CMD) > $INSTALL_LOG"
elif ! ( cd "$WT" && eval "$INSTALL_CMD" ) >"$INSTALL_LOG" 2>&1; then
  echo "add-lane: install failed (see $INSTALL_LOG); starting the agent anyway" >&2
  tail -n 5 "$INSTALL_LOG" >&2
fi

# Into the lane's tab, by its place among the lanes already there; a tab not
# open yet opens with this lane as its root (runner_place_lane). A pane
# map from before the lanes tab has its lanes in the orchestrator's tab.
PANE=$(runner_place_lane "$MAP" "$TAB_LABEL" "$WT_PANE")

# The lane goes into the map, in place of its unplaced line, before its agent
# starts, as bootstrap's does: a start that fails leaves a lane a rerun can
# resume.
# The read is checked on its own: grep's 1 is no line left, anything else a
# failed read, which stops here with the map as it was.
rewrite_failed="add-lane: could not rewrite $MAP; lane $LANE's pane is $PANE: turn its unplaced line into  lane $LANE: $PANE  (the rest as it is) and rerun"
replace_map_line "^unplaced lane $LANE:" "$(lane_line "$PANE") starting" "$rewrite_failed"
start_lane
set_lane_line "$(lane_line "$PANE")"

# .env (gitignored) only after the agent owns the pane: the pane's shell must
# never see a .env at startup or on a cd, or a dotenv-style plugin prompts and
# eats whatever is typed next. The brief arrives later, so the lane has it in time.
[ -f "$WT/.env" ] || cp "$REPO_ROOT/.env" "$WT/.env" 2>/dev/null || true

echo "lane $LANE ready: agent $NAME in $PANE — next:  tower brief $LANE > $RUN_DIR/brief-$LANE.md, add the judgement (brief-template.md, with merge points in both briefs), then  $KIT/send-brief.sh $RUN_DIR $NAME $RUN_DIR/brief-$LANE.md"
