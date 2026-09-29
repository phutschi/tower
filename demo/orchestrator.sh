#!/usr/bin/env bash
# The orchestrator's pane in the demo: what /tower:orchestrate says as the
# run goes. Canned.
set -u
. "$DEMO_ROOT/demo/clock.sh"
say "/tower:orchestrate docs/plans/widgets.md" "" \
    "⏺ run Widgets on acme, feature/widgets" \
    "  lane A: tasks 1-3 · lane B: tasks 4-6" \
    "  lanes briefed; watching the board"
at 11; say "" "⏺ lane B is blocked: needs the test database"
at 14; say "  sam created it; B resumes"
at 25; say "" "⏺ lanes A and B done: a fresh Reviewer for each"
at 29; say "  both reviews clean; merged lane B"
at 32; say "" "⏺ preflight green" "  draft PR opened; closing the run"
sleep 600  # keep the pane's output on screen
