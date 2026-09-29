#!/usr/bin/env bash
# Add a lane: a git worktree with its own executor, placed in the lane grid,
# owning the given task ids.
#
#   [EXECUTOR_KIND=claude|codex] add-lane.sh <run-dir> <B|C|D> <branch> <base-branch> <task-ids>
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
#
# The lane's line goes into the pane map before its agent starts. When the
# start fails, rerun the same call: when herdr does not find the lane's agent,
# it is started again in the lane's pane and worktree, and nothing else is
# redone (the task ids are already assigned). Refused: a lane whose agent
# runs, any answer from herdr other than agent_not_found, a rerun with another
# branch, kind, model or task ids than the first call's (ids read as tower
# reads them), and a lane whose pane
# or worktree is gone (the message says what to remove).
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
TARGET=$(lane_pane "$ANCHOR")
[ -n "$TARGET" ] || die "lane $LANE goes under lane $ANCHOR, which does not exist yet"

REPO_ROOT="$(repo_root)"
WT="$REPO_ROOT/.worktrees/$BRANCH"
_here="$PWD"; cd "$REPO_ROOT"
. "$KIT/detect-stack.sh"   # INSTALL_CMD, .orchestrate's EXECUTOR_* (the environment wins); refuses a bad run switch
cd "$_here"; unset _here
. "$KIT/executor.sh"       # EXECUTOR_KIND, EXECUTOR_MODEL, agent_name, start_agent*
NAME="$(agent_name "-lane-$(echo "$LANE" | tr 'A-Z' 'a-z')")"
lane_line() { printf 'lane %s:         %s   (agent "%s", kind %s, branch %s, checkout %s, model %s)\n' \
  "$LANE" "$1" "$NAME" "$EXECUTOR_KIND" "$BRANCH" "$WT" "$EXECUTOR_MODEL"; }

if [ -n "$PANE" ]; then
  # A rerun. The lane's agent running means the lane exists. herdr not finding
  # it means its start failed: start it again, in the lane's pane and worktree.
  # Any other answer from herdr decides nothing.
  case "$(state_of "$NAME")" in
    gone) ;;
    unreadable) die "lane $LANE: herdr cannot say whether agent $NAME runs; rerun once herdr answers" ;;
    *) die "lane $LANE already exists (see $MAP)" ;;
  esac
  [ "$(grep "^lane $LANE:" "$MAP")" = "$(lane_line "$PANE")" ] \
    || die "lane $LANE is in the pane map with another branch, kind or model; rerun with the ones it has (see $MAP)"
  # The ids against what the lane owns on the board, read as tower reads them
  # (src/ids.ts expandIds; tower has no command that expands without
  # recording): tokens trimmed, empty ones dropped, an integer range expanded,
  # zero-padded when both ends are written at the same width (07-09).
  owned=$(tower state --json | python3 -c 'import json,re,sys
d=json.load(sys.stdin); want=set()
for t in map(str.strip, sys.argv[2].split(",")):
    m = re.fullmatch(r"([0-9]+)-([0-9]+)", t)
    if m:
        lo, hi = m.groups()
        w = len(lo) if len(lo) == len(hi) else 0
        want |= {str(n).zfill(w) for n in range(int(lo), int(hi) + 1)}
    elif t:
        want.add(t)
have=d["lanes"].get(sys.argv[1], [])
print(",".join(have)); sys.exit(0 if want == set(have) else 1)' "$LANE" "$TASKS") \
    || die "lane $LANE owns $owned on the board, not $TASKS; rerun with those ids"
  herdr pane get "$PANE" >/dev/null 2>&1 \
    || die "lane $LANE's pane $PANE is gone (herdr pane get): remove its line from $MAP and the worktree $WT, then add the lane again"
  [ -d "$WT" ] || die "lane $LANE's checkout $WT is gone: close its pane $PANE and remove its line from $MAP, then add the lane again"
  start_agent_with_trust_retry "$NAME" "$PANE" \
    || die "add-lane: agent $NAME did not start in $PANE again; rerun  $KIT/add-lane.sh $RUN_DIR $LANE $BRANCH $BASE $TASKS  once it can"
  [ -f "$WT/.env" ] || cp "$REPO_ROOT/.env" "$WT/.env" 2>/dev/null || true
  echo "lane $LANE ready: agent $NAME in $PANE (started again) — next:  tower brief $LANE > $RUN_DIR/brief-$LANE.md, add the judgement (brief-template.md, with merge points in both briefs), then  herdr agent prompt $NAME \"\$(cat $RUN_DIR/brief-$LANE.md)\""
  exit 0
fi

# Ownership first: tower refuses an unknown id, so a typo stops here, before a
# worktree exists.
tower assign "$LANE" "$TASKS"

out=$(herdr worktree create --cwd "$REPO_ROOT" --branch "$BRANCH" --base "$BASE" --path "$WT" --label "$NAME" --no-focus)
WT_PANE=$(echo "$out" | jsonq 'd["result"]["root_pane"]["pane_id"]')
PANE=$(herdr pane move "$WT_PANE" --tab "$HERDR_TAB_ID" --split "$SPLIT" --target-pane "$TARGET" --ratio 0.5 --no-focus \
  | jsonq 'd["result"].get("move_result", d["result"])["pane"]["pane_id"]')

# The install runs here, not typed into the pane: text sent to a shell that is
# still starting up can be swallowed by a startup hook reading the tty (the
# oh-my-zsh dotenv plugin does exactly that when it finds a .env). Same wait
# as before, from a subshell, with the output kept in the run dir.
INSTALL_LOG="$RUN_DIR/install-$LANE.log"
if [ -z "$INSTALL_CMD" ]; then echo "add-lane: no install: $INSTALL_WHY"
elif [ "${DRY_RUN:-0}" = 1 ]; then echo "[dry-run] (cd $WT && $INSTALL_CMD) > $INSTALL_LOG"
elif ! ( cd "$WT" && eval "$INSTALL_CMD" ) >"$INSTALL_LOG" 2>&1; then
  echo "add-lane: install failed (see $INSTALL_LOG); starting the agent anyway" >&2
  tail -n 5 "$INSTALL_LOG" >&2
fi

# The lane goes into the map before its agent starts, as bootstrap's does: a
# start that fails leaves a lane a rerun can resume.
lane_line "$PANE" >> "$MAP"
start_agent_with_trust_retry "$NAME" "$PANE" \
  || die "add-lane: agent $NAME did not start in $PANE; lane $LANE is in the pane map: rerun  $KIT/add-lane.sh $RUN_DIR $LANE $BRANCH $BASE $TASKS  to start it again"

# .env (gitignored) only after the agent owns the pane: the pane's shell must
# never see a .env at startup or on a cd, or a dotenv-style plugin prompts and
# eats whatever is typed next. The brief arrives later, so the lane has it in time.
[ -f "$WT/.env" ] || cp "$REPO_ROOT/.env" "$WT/.env" 2>/dev/null || true

echo "lane $LANE ready: agent $NAME in $PANE — next:  tower brief $LANE > $RUN_DIR/brief-$LANE.md, add the judgement (brief-template.md, with merge points in both briefs), then  herdr agent prompt $NAME \"\$(cat $RUN_DIR/brief-$LANE.md)\""
