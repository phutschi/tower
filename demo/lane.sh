#!/usr/bin/env bash
# A lane's pane in the demo: canned output in the rhythm of a coding agent.
set -u
. "$DEMO_ROOT/demo/clock.sh"
case "$1" in
  A)
    say "lane A · opus · tasks 1-3" ""
    at 1;  say "⏺ task 1: The widget model" "  reading src/widgets/"
    at 3;  say "  writing src/widgets/model.ts" "  bun test  ✓ 8 passed"
    at 5;  say "⏺ spec review (sonnet): clean"
    at 7;  say "⏺ quality review (opus): clean"
    at 9;  say "  committed feat: the widget model"
    at 10; say "⏺ task 2: The widget list" "  writing apps/web/list.tsx"
    at 14; say "  bun test  ✓ 14 passed"
    at 16; say "  committed feat: the widget list"
    at 17; say "⏺ task 3: Rename a widget"
    at 21; say "  bun test  ✓ 17 passed"
    at 22; say "⏺ spec review (sonnet): clean"
    at 24; say "  committed feat: rename a widget" "" "[[ALL DONE]]"
    ;;
  B)
    say "lane B · opus · tasks 4-6" ""
    at 2;  say "⏺ task 4: The widget API" "  writing apps/api/widgets.ts"
    at 6;  say "  bun test  ✓ 6 passed"
    at 7;  say "  committed feat: the widget API"
    at 8;  say "⏺ task 5: Widget search"
    at 10; say "  bun test  ✗ no test database"
    at 11; say "  blocked: needs the test database created"
    at 15; say "⏺ task 5: fixing, the database is there" "  bun test  ✓ 11 passed"
    at 19; say "  committed feat: widget search"
    at 20; say "⏺ task 6: The audit log"
    at 25; say "  committed feat: the audit log" "" "[[READY TO MERGE]]"
    ;;
esac
sleep 600  # keep the pane's output on screen
