#!/usr/bin/env bash
# stop-run.sh <workspace-id>
#
# The Panel's station calls it when a run job is stopped (its issue moved
# back, or closed): it closes the herdr workspace start-run.sh opened, which
# ends the orchestrator and every pane in it. The run's checkout and branch
# stay; the station removes them a day later.
#
# Exits 0 once herdr closed the workspace; non-zero, saying why, otherwise.
set -euo pipefail
KIT="$(cd "$(dirname "$0")" && pwd)"
. "$KIT/common.sh"
[ $# -eq 1 ] || { echo "usage: stop-run.sh <workspace-id>" >&2; exit 2; }
need herdr
out=$(herdr workspace close "$1" 2>&1) || die "stop-run: herdr could not close workspace $1: $out"
