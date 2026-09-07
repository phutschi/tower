# The protocol

Two shapes are public contracts: the event line, and `tower state --json`.
Both carry `"v": 1`. A breaking change to either bumps `v` and the package's
major version; an additive change (a new optional field) bumps the minor.

## The run directory

```
<run dir>/
  run.json        written once by `tower init`; never modified afterwards
  events.ndjson   append-only; one JSON object per line
```

Where: `$XDG_STATE_HOME/tower/runs/<repo>-<branch>-<yyyymmdd-hhmm>/`
(default `~/.local/state/tower/runs/…`), unless `--run <dir>` was given.

## run.json

```json
{
  "v": 1,
  "plan": "Widgets Implementation Plan",
  "planPath": "/abs/path/plan.md",
  "repo": "acme",
  "branch": "feature/widgets",
  "callsign": "ACME",
  "theme": "airport",
  "startedAt": "2026-09-04T19:12:00.000Z",
  "models": {
    "implementer": "sonnet-5",
    "spec-reviewer": "sonnet",
    "quality-reviewer": "opus"
  },
  "tasks": [
    {
      "id": "1",
      "title": "The shared prompt shortcuts",
      "area": "packages/core"
    }
  ]
}
```

- `planPath` is `null` when tasks came from a TSV or stdin.
- `models` is a free map of role → model. `implementer`, `spec-reviewer` and
  `quality-reviewer` are the three default _role names_ when `--model` is
  never given; each starts out empty until a model is assigned to it.
- `tasks` is in plan order. Everything tower shows is in plan order.
- `tasks` may be `[]`: a run created without a plan. Tasks then arrive as
  `add` events.
- Lane assignments are **not** here; they are events.

## Task ids

Strings matching `[A-Za-z0-9][A-Za-z0-9._-]*`: `14`, `3a`, `auth-1`, `T-12`.
Case-sensitive. A range `7-9` on the command line expands only when both ends
are integers.

## Events

Every line: `"v": 1`, a `"kind"`, and an ISO 8601 `"ts"` with offset. Order in
the file is the order of the run; timestamps are for display. Seven kinds:

```json
{"v":1,"kind":"report","ts":"…","task":"14","status":"in_progress","phase":"implementing","model":"sonnet-5","note":"","commit":"4f27b92"}
{"v":1,"kind":"note","ts":"…","text":"merged lane B at task 8","task":null,"lane":"A"}
{"v":1,"kind":"assign","ts":"…","lane":"B","tasks":["5","7","8","9"]}
{"v":1,"kind":"close","ts":"…","text":"shipped as v0.1.0"}
{"v":1,"kind":"add","ts":"…","task":{"id":"12","title":"Wire the webhook","area":""},"after":"8"}
{"v":1,"kind":"change","ts":"…","task":"12","title":"Wire the outbound webhook","area":null,"after":null}
{"v":1,"kind":"remove","ts":"…","task":"12"}
```

### report

| field    |                                                                                                  |
| -------- | ------------------------------------------------------------------------------------------------ |
| `status` | `pending` · `in_progress` · `reviewing` · `done` · `blocked`                                     |
| `phase`  | free text; conventionally `implementing`, `spec-review`, `quality-review`, `fixing`, `committed` |
| `model`  | required by the CLI on `in_progress` and `reviewing`; `none` is the documented escape            |
| `note`   | ≤ 500 characters; required on `blocked`                                                          |
| `commit` | short sha of `HEAD` in the reporting process's cwd, or `""`                                      |

### add, change, remove

The run's word on what its tasks are, on top of the plan's. They are events
because `run.json` is written once (ADR 0001).

| kind     |                                                                                                        |
| -------- | ------------------------------------------------------------------------------------------------------ |
| `add`    | `task` is a full task (`id`, `title`, `area`); `after` is an id to insert after, or `null` for the end |
| `change` | `title`, `area`, `after`: each a string, or `null` for "untouched"                                     |
| `remove` | `task` is the id                                                                                       |

What the fold does with them:

- `add` for a new id creates a pending task, `origin: "added"`. `add` for an
  id the run already has, removed or not, is a change to that task: its
  status and history are kept, and a removed task comes back.
- an `after` id the run does not have puts the task at the end and flags the
  transcript entry `unknown-after`. The fold refuses nothing.
- `remove` takes the task off the board, out of its lane, and out of the
  summary. Its reports stay in the transcript. A later report for that id is
  `unknown-task`, as a typo is.
- reports that precede the `add` of their id in file order are `unknown-task`.
- the fold never invents a task from a report; only `add` creates one.

A reader that switches on `kind` must ignore kinds it does not know: a new
kind is an additive change.

### The state machine

There is none to enforce: any status may follow any status, and the last
report wins. tower shows a regressive report (a landed task reporting
`in_progress`) rather than rejecting it, because a reopened task is a fact
worth seeing. What the fold derives:

- **stale** — `in_progress` or `reviewing` with no report for longer than the
  stale threshold (default 30 min; `--stale`, or `stale` in the config file).
  `pending`, `done` and `blocked` are never stale.
- **complete** — the run has at least one task and every task is `done`.
- **closed** — a `close` event exists. A closed run has no attention.
- **attention** — not closed, and something is blocked or stale.

### Writing

One `O_APPEND` write per line. POSIX makes the seek-to-end and the write
indivisible for a regular file on a local filesystem, so concurrent appends
from separate processes interleave by line. Anything that appends a complete
line with one write can report into tower; the CLI is a convenience.

### Reading

A reader must tolerate a torn last line (a write in progress). tower skips
unparseable lines, counts them, and shows the count.

## `tower state --json`

```json
{
  "v": 1,
  "runDir": "/…/acme-feature-widgets-20260904-1912",
  "run": { "…": "run.json" },
  "tasks": [
    {
      "id": "14",
      "title": "…",
      "area": "…",
      "lane": "A",
      "status": "in_progress",
      "phase": "fixing",
      "note": "spec review: missing null guard",
      "model": "sonnet-5",
      "implementer": "sonnet-5",
      "commit": "",
      "startedAt": "…",
      "updatedAt": "…",
      "stale": true,
      "origin": "plan"
    }
  ],
  "lanes": { "A": ["1", "2", "14"], "B": ["12"] },
  "transcript": [
    { "ts": "…", "event": { "…": "…" }, "problem": "unknown-task" }
  ],
  "unreadable": 0,
  "unknown": ["99"],
  "nextId": "22",
  "closed": null,
  "firstEventAt": "…",
  "summary": {
    "total": 21,
    "pending": 5,
    "active": 3,
    "done": 12,
    "blocked": 1,
    "stale": 2,
    "complete": false
  },
  "attention": true
}
```

`implementer` is sticky: the last model that held `in_progress` or `done`.
`model` is whoever is on the task now.

`origin` is `"plan"` or `"added"`. `nextId` is one above the largest
plain-integer id any plan task or `add` has ever used, removed ids included;
it is what `tower add` picks when `--id` is not given.

## `tower wait --timeout <seconds>`

Blocks until attention, completion, or close — exit **0**, printing one
literal line per reason:

```
blocked   auth-3   needs the test DB created
stale     14       no event for 12m
complete
closed    shipped as v0.1.0
```

On a quiet timeout: exit **3**, nothing printed. `--timeout` is required.

## Exit codes

|     |                                                    |
| --- | -------------------------------------------------- |
| 0   | done (for `wait`: attention, complete, or closed)  |
| 1   | usage or validation error; nothing was appended    |
| 2   | no run found; the message is the `tower init` line |
| 3   | `wait` timed out with nothing to report            |

## Run discovery

1. `--run <dir>`
2. `$TOWER_RUN`
3. `<git common dir>/tower-run` — written by `tower init`, shared by every
   worktree of the repository, cleared by `tower close`
4. otherwise exit 2
