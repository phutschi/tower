#!/usr/bin/env bash
# The demo's layout, built from inside the first pane of the isolated herdr
# (demo/record.sh): lanes A and B right of the orchestrator, the tower console
# below. Refuses to touch a herdr that is not the demo's own.
set -euo pipefail
: "${DEMO_DIR:?run demo/record.sh}" "${DEMO_ROOT:?run demo/record.sh}"
case "${HERDR_SOCKET_PATH:-}" in "$DEMO_DIR"/*) ;; *) echo "demo: not the demo's herdr; stopping" >&2; exit 1 ;; esac
workspaces=$(herdr workspace list | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["result"]["workspaces"]))')
[ "$workspaces" = 1 ] || { echo "demo: this herdr has other workspaces; stopping" >&2; exit 1; }

D="$DEMO_ROOT/demo"
export DEMO_T0; DEMO_T0=$(date +%s)  # the clock the lanes, the feed and the orchestrator share
id() { python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])'; }
herdr workspace rename "$HERDR_WORKSPACE_ID" acme >/dev/null
console=$(herdr pane split --current --direction down --ratio 0.5 --no-focus | id)
lane_a=$(herdr pane split --current --direction right --ratio 0.45 --no-focus | id)
lane_b=$(herdr pane split --pane "$lane_a" --direction down --ratio 0.5 --no-focus | id)
herdr pane rename "$HERDR_PANE_ID" orchestrator >/dev/null
herdr pane rename "$lane_a" lane A >/dev/null
herdr pane rename "$lane_b" lane B >/dev/null
herdr pane rename "$console" tower >/dev/null
herdr pane run "$console" "clear; node '$DEMO_ROOT/dist/cli.js' --stale 30" >/dev/null
herdr pane run "$lane_a" "clear; DEMO_T0=$DEMO_T0 '$D/lane.sh' A" >/dev/null
herdr pane run "$lane_b" "clear; DEMO_T0=$DEMO_T0 '$D/lane.sh' B" >/dev/null
"$D/feed.sh" >/dev/null 2>&1 &
clear
exec "$D/orchestrator.sh"
