# The tower CLI

The CLI keeps a run's record and draws its board. It starts nothing and acts
on nothing; the skills do the acting ([README](../README.md)). This page is
the reference for driving it by hand or from scripts. To install tower, see
the [README](../README.md#install).

## Sixty seconds

```sh
# 1. From your repository, create a run from a plan.
tower init --plan docs/plans/widgets.md --lane A=1-6 --lane B=7-9

# 2. Print the letter each lane's agent gets. Paste it into the agent.
tower brief A

# 3. Leave this open.
tower
```

Your agents report with three commands (the brief teaches them; tower refuses a
malformed report and prints the correct form, so they self-correct):

```sh
tower task 4 in_progress implementing --model sonnet-5
tower task 4 reviewing spec-review --model sonnet
tower task 4 done committed "feat: the gate" --model sonnet-5
tower block 7 "needs the test database created"
tower note --lane B "merged lane A at task 4"
```

Scripts ask tower instead of polling:

```sh
tower state --json           # the folded state; literal, versioned
tower wait                   # exit 0 with the reasons on attention, completion, or close
tower wait --timeout 300     # the same, or 3 once 300 s pass quietly (foreground-only harnesses)
```

No plan? Start empty and let the executor add its tasks as it derives them
(outside `/tower:orchestrate`, where only the orchestrator adds tasks):

```sh
tower init                                 # 0 tasks
tower add "Wire the webhook" --lane A      # prints the id; report against it
tower brief A                              # once lane A has a task
tower change 1 --title "Wire the outbound webhook"
tower add "A task we did not need" --lane A
tower remove 2
```

## Commands

|                                                       |                                                                     |
| ----------------------------------------------------- | ------------------------------------------------------------------- |
| `tower`                                               | the console (`--plain`, `--theme`, `--stale <min>`, `--run <dir>`)  |
| `tower init`                                          | create a run from `--plan <md>`, `--tasks <tsv>`, stdin, or nothing |
| `tower assign <lane> <ids>`                           | record which tasks a lane owns                                      |
| `tower brief <lane>`                                  | the executor letter                                                 |
| `tower close [note]`                                  | declare the run finished                                            |
| `tower add "<title>" [--lane <lane>]`                 | add a task the plan did not have                                    |
| `tower change <id> --title\|--area\|--after`          | edit a task                                                         |
| `tower remove <id> [--force]`                         | take a task off the board (`--force` overrides an active task)      |
| `tower task <id> <status> [phase] [note] --model <m>` | report                                                              |
| `tower block <id> "<need>"`                           | report blocked                                                      |
| `tower note [--task\|--lane] "<text>"`                | narrate                                                             |
| `tower state --json`                                  | the folded state                                                    |
| `tower ids <ids>`                                     | expand and check ids against the run, as `assign` reads them        |
| `tower wait [--timeout <s>]`                          | block until attention                                               |
| `tower theme rules\|new\|check\|preview`              | author a theme                                                      |

`tower --help` for the flags.

## The screen

A small run in a repository called `acme`, as a pipe gets it (`tower | cat`):

```
TOWER ─────────────────────────────────────────────────── ACME · feature/widgets
INFORMATION ALFA · 17:23 · 0m since first departure
████▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒  1 of 6 landed · 1 airborne · 1 holding short

RUNWAY A  ▸ 2  sonnet-5        RUNWAY B  ⚠ 5  opus

DEPARTURES
 AIRBORNE
 ▸ 2         The wid…  A   apps/web          sonnet-5        0m · airborne
 ⚠ 5         Widget …  B   apps/api          holding short: needs the test data…
 ON THE GROUND
 ○ 3         Rename a widget                   A   apps/web
 ○ 4         The widget API                    A   apps/api
 ○ 6         The audit log                     B   apps/api
 ✓ 1 landed  (1)

TRANSCRIPT
 17:23:42  TOWER     RUNWAY A ← 1, 2, 3, 4
 17:23:42  TOWER     RUNWAY B ← 5, 6
 17:23:43  ACME 1    landed  afbbb94
 17:23:43  ACME 2    cleared for takeoff · sonnet-5
 17:23:43  ACME 5    cleared for takeoff · opus
 17:23:43  ACME 5    squawk 7700 · needs the test database created
 17:23:43  RUNWAY A  rex: lane A starts on the list
```

The vocabulary is air traffic control because a task's life is a flight: a
task departs, is reviewed on approach, and either bounces (_go around_) or
lands. A task nobody has heard from is _NORDO_. Prefer plain words?
`tower --plain`. Prefer a different domain? See [themes](themes.md); a
worked example, a factory floor, ships in
[`themes/examples/`](../themes/examples/).

## How it works

```
<run dir>/
  run.json        identity, written once by `tower init`
  events.ndjson   append-only; one JSON line per report
```

Every report is a single `O_APPEND` write, so lanes in different worktrees can
report in the same millisecond without a lock and without losing a line. State
is a pure fold of the log: kill tower, restart it, read a finished run a week
later — nothing is lost. The event line and `tower state --json` are versioned
public contracts; see [protocol.md](protocol.md).

tower finds its run through `--run`, then `$TOWER_RUN`, then a pointer file in
the repository's common git directory — so every worktree of a repository lands
on the same run without being told where it is.

## Platforms

macOS and Linux on local filesystems. Windows is not supported (WSL works).
Network filesystems are not supported: the append atomicity tower relies on
does not hold on NFS.

No telemetry, no update checks. `NO_COLOR` is respected.
