#!/usr/bin/env bash
# The demo run's record over time: what the lanes, the Reviewer and the
# orchestrator would report to tower in a real run, appended to TOWER_RUN.
set -u
. "$DEMO_ROOT/demo/clock.sh"
t() { node "$DEMO_ROOT/dist/cli.js" "$@" >/dev/null; }
at 1;  t task 1 in_progress implementing --model opus
at 2;  t task 4 in_progress implementing --model opus
at 5;  t task 1 reviewing spec-review --model sonnet
at 7;  t task 1 reviewing quality-review --model opus
       t task 4 done committed "feat: the widget API" --model opus
at 8;  t task 5 in_progress implementing --model opus
at 9;  t task 1 done committed "feat: the widget model" --model opus
at 10; t task 2 in_progress implementing --model opus
at 11; t block 5 "needs the test database created"
at 14; t note "sam created the test database"
at 15; t task 5 in_progress fixing --model opus
at 16; t task 2 done committed "feat: the widget list" --model opus
at 17; t task 3 in_progress implementing --model opus
at 19; t task 5 done committed "feat: widget search" --model opus
at 20; t task 6 in_progress implementing --model opus
at 22; t task 3 reviewing spec-review --model sonnet
at 24; t task 3 done committed "feat: rename a widget" --model opus
       t note --lane A "ALL DONE - check green"
at 25; t task 6 done committed "feat: the audit log" --model opus
       t note --lane B "ready to merge"
       t add "Lane review A" --id R1-1 --area review --lane R1
       t task R1-1 reviewing --model sonnet
       t add "Lane review B" --id R2-1 --area review --lane R2
       t task R2-1 reviewing --model sonnet
at 29; t task R1-1 done --model sonnet
       t task R2-1 done --model sonnet
       t note "merged lane B into feature/widgets"
at 32; t note "preflight green; draft PR opened"
at 34; t close "draft PR opened"
