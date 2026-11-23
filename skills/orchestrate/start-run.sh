#!/usr/bin/env bash
# start-run.sh <workspace-name> <worktree-path> <brief-file>
#
# The Panel's station calls it for a run job: it opens a herdr workspace with
# that name in the run's checkout, starts an interactive Claude Code
# orchestrator in the workspace's first pane, and gives it the brief file as
# its first prompt. The brief has it run /tower:spec-to-plan, then
# /tower:orchestrate. The orchestrator's model is EXECUTOR_MODEL
# (model-defaults, or the call's environment).
#
# Prints {"workspace":"<id>","pane":"<id>","agent":"<name>"} once the
# orchestrator has its
# brief, and exits 0; exits non-zero, saying why, otherwise, closing the
# workspace if it opened one (the checkout stays, for a look). Run outside
# herdr (the station is a launchd service): it needs herdr runnable, not a pane.
set -euo pipefail
KIT="$(cd "$(dirname "$0")" && pwd)"
. "$KIT/common.sh"
[ $# -eq 3 ] || { echo "usage: start-run.sh <workspace-name> <worktree-path> <brief-file>" >&2; exit 2; }
NAME="$1"; CHECKOUT="$2"; BRIEF="$3"
[ -d "$CHECKOUT" ] || die "start-run: no checkout at $CHECKOUT"
[ -r "$BRIEF" ] || die "start-run: cannot read the brief $BRIEF"
need herdr python3
EXECUTOR_KIND=claude
. "$KIT/executor.sh"
. "$KIT/roles.sh"

out=$(herdr workspace create --cwd "$CHECKOUT" --label "$NAME" --no-focus 2>&1) \
  || die "start-run: herdr could not open workspace $NAME: $out"
WS=$(printf '%s' "$out" | jsonq 'd["result"]["workspace"]["workspace_id"]' 2>/dev/null) \
  && PANE=$(printf '%s' "$out" | jsonq 'd["result"]["root_pane"]["pane_id"]' 2>/dev/null) \
  || die "start-run: herdr opened workspace $NAME without naming its pane: $out"
# From here a failure leaves no workspace behind: nobody would own it.
trap '[ $? -eq 0 ] || herdr workspace close "$WS" >/dev/null 2>&1 || echo "start-run: could not close workspace $NAME ($WS)" >&2' EXIT
# bash 3.2 runs no EXIT trap on a signal: launchd stopping the station mid-start.
trap 'exit 143' TERM INT HUP
# An agent name herdr accepts (executor.sh agent_name): a lowercase letter
# first, then lowercase letters, digits, '-' or '_', at most 32 characters.
# A long name loses words from its front, never the issue number at its end:
# herdr addresses the agent by it, and two runs of one repo must differ.
AGENT=$(printf '%s' "$NAME" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9_-]/-/g')
[ "${#AGENT}" -le 32 ] || { AGENT="${AGENT: -32}"; AGENT="${AGENT#*-}"; }
AGENT=$(printf '%s' "$AGENT" | sed 's/^[^a-z]*//'); [ -n "$AGENT" ] || AGENT=run
# With a Claude launcher (roles.sh), orchestration runs only in an
# orchestrator session.
if claude_launcher; then
  SESSION_ROLE=orchestrator; SESSION_TOPIC=$AGENT
fi
start_agent_with_trust_retry "$AGENT" "$PANE" \
  || die "start-run: the orchestrator did not start in workspace $NAME (pane $PANE); the workspace is closed"
herdr agent prompt "$AGENT" "$(cat "$BRIEF")" >/dev/null \
  || die "start-run: could not give the orchestrator its brief (herdr agent prompt $AGENT)"
printf '{"workspace":"%s","pane":"%s","agent":"%s"}\n' "$WS" "$PANE" "$AGENT"
