#!/usr/bin/env bash
# Add a lane: a git worktree with its own executor, placed in the lane grid,
# owning the given task ids.
#
#   [EXECUTOR_KIND=claude|codex|cursor] add-lane.sh <run-dir> <B|C|D> <branch> <base-branch> <task-ids>
#
# Four lanes at most. Lane A is started by bootstrap.sh in the main checkout;
# B goes right of A, C under A, D under B:
#
#        │ lane A   │ lane B   │
#        ├──────────┼──────────┤
#        │ lane C   │ lane D   │
#
# The kind is per lane (executor.sh). Worktrees live at
# <repo>/.worktrees/<branch>; INSTALL_CMD installs (from here, log in
# <run-dir>/install-<lane>.log): the repo contract's, else the package manager's
# when there is a package.json, else nothing, said in one line. .env
# (gitignored) is copied once the agent owns the pane. The worktree shares the
# repo's common git dir, so `tower` inside it finds the run with no flags.
# Without a runnable tower it refuses before anything is created. A run
# switch with a value outside its list (see detect-stack.sh) is refused here
# as in bootstrap.sh; the run's values are the pane map's  switches:  line.
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
# Nothing else is redone (the worktree exists and the task ids are assigned).
# Refused: a started lane whose agent runs, any answer from herdr other than
# agent_not_found, a rerun with another branch, kind, model or task ids than
# the first call's (ids expanded by `tower ids`, so an id tower refuses is
# refused in its words), and a lane whose pane (herdr's pane_not_found) or
# worktree is gone: the message says what to remove. A pane herdr cannot be
# asked about is refused with nothing to remove; rerun once herdr answers.
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
in_herdr; need git python3 node
need_tower
[ $# -eq 5 ] || die 'usage: add-lane.sh <run-dir> <B|C|D> <branch> <base-branch> <task-ids>'
RUN_DIR="$1"; LANE="$2"; BRANCH="$3"; BASE="$4"; TASKS="$5"
MAP="$RUN_DIR/panes.txt"
[ -f "$MAP" ] || die "no pane map at $MAP: run bootstrap.sh first"
# Every tower call is about this run, wherever it is called from.
RUN_DIR="$(cd "$RUN_DIR" && pwd)"; MAP="$RUN_DIR/panes.txt"; export TOWER_RUN="$RUN_DIR"
lane_pane() { sed -nE "s/^lane $1: +([^ ]+).*/\1/p" "$MAP"; }

case "$LANE" in
  B) ANCHOR=A; SPLIT=right ;;
  C) ANCHOR=A; SPLIT=down ;;
  D) ANCHOR=B; SPLIT=down ;;
  A) die "lane A is started by bootstrap.sh" ;;
  *) die "lane must be B, C or D (four lanes at most)" ;;
esac
PANE=$(lane_pane "$LANE")   # set: a rerun, the lane is already in the map
UNPLACED=$(sed -nE "s/^unplaced lane $LANE: +([^ ]+).*/\1/p" "$MAP")   # set: a rerun after a failed move
TARGET=$(lane_pane "$ANCHOR")
[ -n "$TARGET" ] || die "lane $LANE goes under lane $ANCHOR, which does not exist yet"

REPO_ROOT="$(repo_root)"
WT="$REPO_ROOT/.worktrees/$BRANCH"
AGENT_CHECKOUT="$WT"   # executor.sh: a codex lane's sandbox grant follows its worktree
unset AGENT_LOOK       # executor.sh: look's worktree dir is a codex Reviewer's alone
_here="$PWD"; cd "$REPO_ROOT"
CONTRACT_RUN="$RUN_DIR" . "$KIT/detect-stack.sh"   # the run's pinned contract: INSTALL_CMD, .orchestrate's EXECUTOR_* (the environment wins); refuses a bad run switch
cd "$_here"; unset _here
. "$KIT/executor.sh"       # EXECUTOR_KIND, EXECUTOR_MODEL, agent_name, start_agent*
NAME="$(agent_name "-lane-$(echo "$LANE" | tr 'A-Z' 'a-z')")"
lane_line() { printf 'lane %s:         %s   (agent "%s", kind %s, branch %s, checkout %s, model %s)\n' \
  "$LANE" "$1" "$NAME" "$EXECUTOR_KIND" "$BRANCH" "$WT" "$EXECUTOR_MODEL"; }

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
  # Only herdr's pane_not_found is a closed pane; any other failure says
  # nothing about it, and the map and the worktree stay.
  if ! err=$(herdr pane get "$2" 2>&1 >/dev/null); then
    case "$err" in
      *'"pane_not_found"'*)
        # herdr gives a moved pane a new id: an unplaced pane that is gone may
        # be in the grid already, its move done but not recorded.
        [ "$3" != "unplaced line" ] \
          || die "lane $LANE's pane $2 is gone (herdr pane get), or was moved without its new id recorded: look for $WT in the grid; if a pane has it, turn  unplaced lane $LANE: $2  in $MAP into  lane $LANE: <that pane's id>  (the rest as it is) and rerun, else remove the unplaced line from $MAP and the worktree $WT, then add the lane again"
        die "lane $LANE's pane $2 is gone (herdr pane get): remove its $3 from $MAP and the worktree $WT, then add the lane again" ;;
      *) die "herdr cannot say whether lane $LANE's pane $2 is open; rerun once herdr answers (herdr: ${err:-no output})" ;;
    esac
  fi
  [ -d "$WT" ] || die "lane $LANE's checkout $WT is gone: close its pane $2 and remove its $3 from $MAP, then add the lane again"
}

# Replaces the pane map's line matching $1 (a grep pattern) with $2, through a
# scratch file of this call's own; on failure the map is kept whole and the
# call dies with $3.
replace_map_line() {
  local tmp rc=0
  tmp=$(mktemp "$MAP.XXXXXX") || die "$3"
  grep -v "$1" "$MAP" > "$tmp" || rc=$?
  { [ "$rc" -le 1 ] && echo "$2" >> "$tmp"; } || { rm -f "$tmp"; die "$3"; }
  mv "$tmp" "$MAP"
}
set_lane_line() { replace_map_line "^lane $LANE:" "$1" "add-lane: could not rewrite $MAP; set lane $LANE's line to  $1  and rerun"; }
RERUN="$KIT/add-lane.sh $RUN_DIR $LANE $BRANCH $BASE $TASKS"
STARTED_AGAIN="started again"

if [ -n "$PANE" ]; then
  # A rerun. A line still ending in " starting" is a start that failed: its
  # agent is taken when it accepts input, started again when herdr does not
  # find it, and otherwise left to the human. On a started lane, its agent
  # running means the lane exists, and herdr not finding it means it is
  # started again. Any other answer from herdr decides nothing.
  STARTING=""
  case "$(grep -E "^lane $LANE:" "$MAP")" in
    *" starting") STARTING=" starting" ;;
  esac
  state=$(state_of "$NAME")
  case "$state" in
    gone) ;;
    unreadable) die "lane $LANE: herdr cannot say whether agent $NAME runs; rerun once herdr answers" ;;
    *) [ -n "$STARTING" ] || die "lane $LANE already exists (see $MAP)" ;;
  esac
  check_rerun "$(lane_line "$PANE")$STARTING" "$PANE" line
  if [ "$state" = gone ]; then
    set_lane_line "$(lane_line "$PANE") starting"
    start_agent_with_trust_retry "$NAME" "$PANE" \
      || die "add-lane: agent $NAME is not ready in $PANE; lane $LANE is in the pane map, starting: rerun  $RERUN  to resume it"
  else
    ready=$(ready_of "$NAME")
    [ "$ready" = ready ] || die "add-lane: agent $NAME is in $PANE but does not accept input ($ready): answer or end it there, then rerun  $RERUN"
    STARTED_AGAIN="resumed"
  fi
  set_lane_line "$(lane_line "$PANE")"
  [ -f "$WT/.env" ] || cp "$REPO_ROOT/.env" "$WT/.env" 2>/dev/null || true
  echo "lane $LANE ready: agent $NAME in $PANE ($STARTED_AGAIN) — next:  tower brief $LANE > $RUN_DIR/brief-$LANE.md, add the judgement (brief-template.md, with merge points in both briefs), then  herdr agent prompt $NAME \"\$(cat $RUN_DIR/brief-$LANE.md)\""
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
  out=$(herdr worktree create --cwd "$REPO_ROOT" --branch "$BRANCH" --base "$BASE" --path "$WT" --label "$NAME" --no-focus) \
    || die "add-lane: herdr worktree create failed: remove $WT and branch $BRANCH if they exist, then rerun  $KIT/add-lane.sh $RUN_DIR $LANE $BRANCH $BASE $TASKS"
  WT_PANE=$(echo "$out" | jsonq 'd["result"]["root_pane"]["pane_id"]' 2>/dev/null) \
    || die "add-lane: herdr created $WT but its answer names no pane: close the pane labelled $NAME, remove $WT and branch $BRANCH, then rerun  $KIT/add-lane.sh $RUN_DIR $LANE $BRANCH $BASE $TASKS"
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

moved=$(herdr pane move "$WT_PANE" --tab "$HERDR_TAB_ID" --split "$SPLIT" --target-pane "$TARGET" --ratio 0.5 --no-focus) \
  || die "add-lane: herdr could not move lane $LANE's pane $WT_PANE into the grid; it is in the pane map as unplaced: rerun  $KIT/add-lane.sh $RUN_DIR $LANE $BRANCH $BASE $TASKS  to place it"
PANE=$(echo "$moved" | jsonq 'd["result"].get("move_result", d["result"])["pane"]["pane_id"]' 2>/dev/null) \
  || die "add-lane: herdr moved lane $LANE's pane $WT_PANE but its answer names no pane: find the lane's pane in the grid (checkout $WT), turn  unplaced lane $LANE: $WT_PANE  in $MAP into  lane $LANE: <that pane's id>  (the rest as it is), and rerun  $KIT/add-lane.sh $RUN_DIR $LANE $BRANCH $BASE $TASKS"

# The lane goes into the map, in place of its unplaced line, before its agent
# starts, as bootstrap's does: a start that fails leaves a lane a rerun can
# resume.
# The read is checked on its own: grep's 1 is no line left, anything else a
# failed read, which stops here with the map as it was.
rewrite_failed="add-lane: could not rewrite $MAP; lane $LANE's pane is $PANE: turn its unplaced line into  lane $LANE: $PANE  (the rest as it is) and rerun"
replace_map_line "^unplaced lane $LANE:" "$(lane_line "$PANE") starting" "$rewrite_failed"
start_agent_with_trust_retry "$NAME" "$PANE" \
  || die "add-lane: agent $NAME is not ready in $PANE; lane $LANE is in the pane map, starting: rerun  $RERUN  to resume it"
set_lane_line "$(lane_line "$PANE")"

# .env (gitignored) only after the agent owns the pane: the pane's shell must
# never see a .env at startup or on a cd, or a dotenv-style plugin prompts and
# eats whatever is typed next. The brief arrives later, so the lane has it in time.
[ -f "$WT/.env" ] || cp "$REPO_ROOT/.env" "$WT/.env" 2>/dev/null || true

echo "lane $LANE ready: agent $NAME in $PANE — next:  tower brief $LANE > $RUN_DIR/brief-$LANE.md, add the judgement (brief-template.md, with merge points in both briefs), then  herdr agent prompt $NAME \"\$(cat $RUN_DIR/brief-$LANE.md)\""
