#!/usr/bin/env bash
# One round of process-level watching. Run it in the background from the
# orchestrator right after `herdr agent prompt`, and re-run it after each exit.
#
#   watch-lanes.sh <run-dir> <agent-name>...     lane and Reviewer agents alike
#   env: ROUND_SECONDS (540)  GRACE_SECONDS (45)  POLL_SECONDS (15)
#
# Task-level attention (blocked / stale / complete / closed) is tower's job:
# run  tower wait --timeout 540 --stale <STALE>  beside this (bootstrap.sh
# prints it with the run's threshold). This script covers what tower cannot
# see, the agent process itself. Without tower it is the only watch, and
# "done" is a lane idle after its final report.
#
# Output starts with one line per lane that needs the orchestrator:
#   attention: <agent> blocked | idle-after-final-report | idle-unexplained | done | gone
# then the state table with the pane tails, then the tower summary (or the git
# log without tower). Exit 0 with attention, 3 when everyone is still working.
# With tower, a closed run is attention too (`tower: run closed`), and so is a
# complete board once no watched agent is working (`tower: run complete`): a
# complete board alone is not, since a lane's final review, preflight and the
# PR come after its last task.
#
# Idle is ambiguous: a lane that was just prompted, or is waiting on its own
# review subagent, reads idle for a moment. So idle counts only after
# GRACE_SECONDS and only when seen on two consecutive polls, and the reason
# says whether the pane tail shows the final report's marker or not: the
# report phrase in double square brackets, [[ALL DONE]] (lane A),
# [[READY TO MERGE]] (lanes B-D) or [[FINDINGS WRITTEN]] <file> (a Reviewer),
# in any case and with spaces inside the brackets.
# Briefs and skills describe the marker and never spell it, so a pane that
# still shows only its brief reads idle-unexplained.
#
# Reviewer agents (add-reviewer.sh) are watched like lane agents: pass their
# names too.
#
# Never run this for real to see what it does; use DRY_RUN=1, which answers
# every herdr and tower call from tests/stub and touches nothing.
set -uo pipefail
KIT="$(cd "$(dirname "$0")" && pwd)"
. "$KIT/common.sh"
in_herdr; need python3
[ $# -ge 2 ] || die 'usage: watch-lanes.sh <run-dir> <agent-name>...'
RUN_DIR="$1"; shift
ROUND=${ROUND_SECONDS:-540}; GRACE=${GRACE_SECONDS:-45}; POLL=${POLL_SECONDS:-15}

state_of() { herdr agent get "$1" 2>/dev/null | jsonq 'd["result"]["agent"]["agent_status"]' 2>/dev/null || echo gone; }
tail_of()  { herdr agent read "$1" --source recent-unwrapped --lines 40 2>/dev/null | grep -v '^[[:space:]]*$' | tail -12; }
reason_for() {  # $1 name, $2 state
  case "$2" in
    idle) if tail_of "$1" | grep -qiE '\[\[ *(ALL DONE|READY TO MERGE|FINDINGS WRITTEN)'; then echo idle-after-final-report; else echo idle-unexplained; fi ;;
    *)    echo "$2" ;;
  esac
}
board()    { tower_ok && tower state --json --run "$RUN_DIR" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print("closed" if d["closed"] else "complete" if d["summary"]["complete"] else "open")' 2>/dev/null; }
# $1: 1 while any watched agent is still working, and an idle one that has not
# settled counts as working. $2: the board, read here when not given. A
# complete board is not the end while an agent works on (its final review,
# preflight, the PR); closed is.
finished() { local b; if [ $# -ge 2 ]; then b=$2; else b=$(board); fi
  case "$b" in closed) return 0 ;; complete) [ "$1" = 0 ] ;; *) return 1 ;; esac; }

IDLE_SEEN=(); i=0; for _ in "$@"; do IDLE_SEEN[$i]=0; i=$((i+1)); done
started=$(date +%s)
while [ $(( $(date +%s) - started )) -lt "$ROUND" ]; do
  settled=0; working=0; i=0
  for name in "$@"; do
    case "$(state_of "$name")" in
      working|unknown) IDLE_SEEN[$i]=0; working=1 ;;
      idle) if [ $(( $(date +%s) - started )) -ge "$GRACE" ]; then
              IDLE_SEEN[$i]=$(( IDLE_SEEN[$i] + 1 ))
            fi
            if [ "${IDLE_SEEN[$i]}" -ge 2 ]; then settled=1; else working=1; fi ;;
      *) settled=1 ;;
    esac
    i=$((i+1))
  done
  [ "$settled" = 1 ] && break
  finished "$working" && break
  sleep "$POLL"
done

alert=0; i=0
# idle only settles at IDLE_SEEN>=2 (the polling loop above); reporting it on
# a single fresh sample here would let a lane idle for its very first poll
# report attention just because a *different* lane is what broke the loop.
STATES=()
for name in "$@"; do
  state=$(state_of "$name"); STATES[$i]=$state
  case "$state" in
    idle) [ "${IDLE_SEEN[$i]}" -ge 2 ] && { alert=1; echo "attention: $name $(reason_for "$name" "$state")"; } ;;
    blocked|done|gone) alert=1; echo "attention: $name $(reason_for "$name" "$state")" ;;
  esac
  i=$((i+1))
done
i=0; working=0
for name in "$@"; do
  state=${STATES[$i]}
  case "$state" in
    working|unknown) working=1 ;;
    idle) [ "${IDLE_SEEN[$i]}" -ge 2 ] || working=1 ;;
  esac
  printf '%-22s %s\n' "$name" "$state"
  case "$state" in
    blocked|done) tail_of "$name" | sed 's/^/    │ /' ;;
    idle) [ "${IDLE_SEEN[$i]}" -ge 2 ] && tail_of "$name" | sed 's/^/    │ /' ;;
  esac
  i=$((i+1))
done
if tower_ok; then
  b=$(board); if finished "$working" "$b"; then echo "tower: run $b"; alert=1; fi
  echo "--- tower"
  tower state --json --run "$RUN_DIR" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["summary"], "attention:", d["attention"])' 2>/dev/null || true
else
  REPO=$(sed -n 's/^repo: *//p' "$RUN_DIR/run.txt" 2>/dev/null); REPO=${REPO:-$PWD}
  echo "--- no tower: task state is in git ($REPO) —"; git -C "$REPO" log --oneline --branches="*" -8 2>/dev/null | sed 's/^/    /'
fi
[ "$alert" = 1 ] && exit 0 || exit 3
