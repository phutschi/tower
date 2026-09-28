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
# repo's common git dir, so `tower` inside it finds the run with no flags. Without tower, ownership goes to
# <run-dir>/lanes.txt. A run switch with a value outside its list (see
# detect-stack.sh) is refused here as in bootstrap.sh; the run's values are the
# pane map's  switches:  line.
#
# Never run this for real to see what it does; use DRY_RUN=1, which answers
# every herdr and tower call from tests/stub and touches nothing.
set -euo pipefail
KIT="$(cd "$(dirname "$0")" && pwd)"
. "$KIT/common.sh"
in_herdr; need git python3 node
[ $# -eq 5 ] || die 'usage: add-lane.sh <run-dir> <B|C|D> <branch> <base-branch> <task-ids>'
RUN_DIR="$1"; LANE="$2"; BRANCH="$3"; BASE="$4"; TASKS="$5"
MAP="$RUN_DIR/panes.txt"
[ -f "$MAP" ] || die "no pane map at $MAP: run bootstrap.sh first"
lane_pane() { sed -nE "s/^lane $1: +([^ ]+).*/\1/p" "$MAP"; }

case "$LANE" in
  B) ANCHOR=A; SPLIT=right ;;
  C) ANCHOR=A; SPLIT=down ;;
  D) ANCHOR=B; SPLIT=down ;;
  A) die "lane A is started by bootstrap.sh" ;;
  *) die "lane must be B, C or D (four lanes at most)" ;;
esac
[ -z "$(lane_pane "$LANE")" ] || die "lane $LANE already exists (see $MAP)"
TARGET=$(lane_pane "$ANCHOR")
[ -n "$TARGET" ] || die "lane $LANE goes under lane $ANCHOR, which does not exist yet"

REPO_ROOT="$(repo_root)"
WT="$REPO_ROOT/.worktrees/$BRANCH"
_here="$PWD"; cd "$REPO_ROOT"
. "$KIT/detect-stack.sh"   # INSTALL_CMD, .herdr-orchestrate's EXECUTOR_* (the environment wins); refuses a bad run switch
cd "$_here"; unset _here
. "$KIT/executor.sh"       # EXECUTOR_KIND, EXECUTOR_MODEL, agent_name, start_agent*
NAME="$(agent_name "-lane-$(echo "$LANE" | tr 'A-Z' 'a-z')")"

# Ownership first: tower refuses an unknown id, so a typo stops here, before a
# worktree exists. Without tower, ownership is a line in <run-dir>/lanes.txt.
if tower_ok; then HAVE_TOWER=1; tower assign "$LANE" "$TASKS"
else HAVE_TOWER=0; echo "$LANE=$TASKS" >> "$RUN_DIR/lanes.txt"; fi

out=$(herdr worktree create --cwd "$REPO_ROOT" --branch "$BRANCH" --base "$BASE" --path "$WT" --label "$NAME" --no-focus)
WT_PANE=$(echo "$out" | jsonq 'd["result"]["root_pane"]["pane_id"]')
PANE=$(herdr pane move "$WT_PANE" --tab "$HERDR_TAB_ID" --split "$SPLIT" --target-pane "$TARGET" --ratio 0.5 --no-focus \
  | jsonq 'd["result"].get("move_result", d["result"])["pane"]["pane_id"]')

# The install runs here, not typed into the pane: text sent to a shell that is
# still starting up can be swallowed by a startup hook reading the tty (the
# oh-my-zsh dotenv plugin does exactly that when it finds a .env). Same wait
# as before, from a subshell, with the output kept in the run dir.
INSTALL_LOG="$RUN_DIR/install-$LANE.log"
if [ -z "$INSTALL_CMD" ]; then
  if [ -f "$REPO_ROOT/package.json" ]; then echo "add-lane: no install: INSTALL_CMD is empty"
  else echo "add-lane: no install: no package.json and no INSTALL_CMD in .herdr-orchestrate"; fi
elif [ "${DRY_RUN:-0}" = 1 ]; then echo "[dry-run] (cd $WT && $INSTALL_CMD) > $INSTALL_LOG"
elif ! ( cd "$WT" && eval "$INSTALL_CMD" ) >"$INSTALL_LOG" 2>&1; then
  echo "add-lane: install failed (see $INSTALL_LOG); starting the agent anyway" >&2
  tail -n 5 "$INSTALL_LOG" >&2
fi

start_agent_with_trust_retry "$NAME" "$PANE"

# .env (gitignored) only after the agent owns the pane: the pane's shell must
# never see a .env at startup or on a cd, or a dotenv-style plugin prompts and
# eats whatever is typed next. The brief arrives later, so the lane has it in time.
[ -f "$WT/.env" ] || cp "$REPO_ROOT/.env" "$WT/.env" 2>/dev/null || true

printf 'lane %s:         %s   (agent "%s", kind %s, branch %s, checkout %s, model %s)\n' \
  "$LANE" "$PANE" "$NAME" "$EXECUTOR_KIND" "$BRANCH" "$WT" "$EXECUTOR_MODEL" >> "$MAP"
if [ "$HAVE_TOWER" = 1 ]; then
  echo "lane $LANE ready: agent $NAME in $PANE — next:  tower brief $LANE > $RUN_DIR/brief-$LANE.md, add the judgement (brief-template.md, with merge points in both briefs), then  herdr agent prompt $NAME \"\$(cat $RUN_DIR/brief-$LANE.md)\""
else
  echo "lane $LANE ready: agent $NAME in $PANE — next: write $RUN_DIR/brief-$LANE.md from brief-template.md (\"Without tower\"; tasks $TASKS, merge points in both briefs), then  herdr agent prompt $NAME \"\$(cat $RUN_DIR/brief-$LANE.md)\""
fi
