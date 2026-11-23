#!/usr/bin/env bash
# run-state.sh <agent>
#
# The Panel's station calls it, in the run's checkout, while a run job runs:
# it prints {"agent":"<state>","stale":<minutes>} and exits 0. <state> is the
# orchestrator's state as herdr reads it (state_of: working, idle, blocked,
# done, gone once it exited, unreadable when herdr cannot say). <minutes> is
# the repo's stale threshold: STALE from the environment, the checkout's
# .orchestrate, or the user contract, else 30. A run with no progress for that
# long is stuck.
set -euo pipefail
KIT="$(cd "$(dirname "$0")" && pwd)"
. "$KIT/common.sh"
[ $# -eq 1 ] || { echo "usage: run-state.sh <agent>" >&2; exit 2; }
need herdr
# shortcut: reads a  STALE=<n>  line (quoted, exported or indented too), not
# the contract's bash; upgrade to detect-stack.sh's loading if a contract
# computes it.
stale_of() {
  [ -f "$1" ] || return 0
  sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}STALE=[\"']\{0,1\}\([0-9][0-9]*\).*/\2/p" "$1" | tail -n 1
}
stale="${STALE:-}"
case $stale in *[!0-9]*) stale= ;; esac
contract=.orchestrate
[ -f "$contract" ] || contract=.herdr-orchestrate
[ -n "$stale" ] || stale=$(stale_of "$contract")
[ -n "$stale" ] || stale=$(stale_of "${XDG_CONFIG_HOME:-$HOME/.config}/tower/orchestrate")
[ -n "$stale" ] || stale=30
printf '{"agent":"%s","stale":%s}\n' "$(state_of "$1")" "$stale"
