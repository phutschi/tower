# tower

A console for watching a crew of coding agents implement a plan, and the
record they report into. tower keeps the record and draws the board; it never
acts on the run.

## Language

### The run

**Run**:
One execution of a plan by a crew of executors, from `init` to `close`. A run
has an identity (repository, branch, plan) and a record.
_Avoid_: session, job, dashboard, project

**Plan**:
The document that lists the tasks, in order. Where it came from is not tower's
concern. A run may have none; its tasks then all come from adds.
_Avoid_: spec, ticket, backlog

**Task**:
One unit of the plan, named by an id, owned by at most one lane at a time.
_Avoid_: item, step, ticket, issue, flight (rendering only)

**Lane**:
A group of tasks worked in order by one executor.
_Avoid_: runway (rendering only), worker, thread, track, stream

**Assignment**:
The recorded fact that a lane owns certain tasks. Assigning is a judgement the
orchestrator makes after reading the plan; tower only records it.
_Avoid_: lane cut, ownership

**Callsign**:
The short upper-case name of the run's repository, used to name tasks aloud on
the board (`ACME 14`).
_Avoid_: prefix, tag

### The people and programs

**Orchestrator**:
The person or agent who creates the run, briefs the executors, watches, and
decides. Never implements.
_Avoid_: supervisor, manager, lead, controller, tower

**Executor**:
The agent working one lane's tasks and reporting on them. An executor holds
whichever role the current phase needs.
_Avoid_: worker, implementer (a role, not the agent), agent (too broad)

**Runner**:
Whatever starts and hosts executor sessions — panes, worktrees, processes.
tower knows nothing about it.
_Avoid_: harness, launcher, orchestrator

**Harness**:
The tool an agent runs inside (a coding-agent CLI or IDE). Distinct from the
runner: the runner starts sessions, the harness is what a session is. tower and
its skill are harness-neutral.
_Avoid_: runner, platform, client

**Role**:
A named part in the workflow that a model fills — implementer, spec reviewer,
quality reviewer, or anything a run declares. A run maps roles to models.
_Avoid_: tier, seat

**Model**:
The language model on a task right now. The **implementer** model is sticky:
the last one to hold a task in progress or done.
_Avoid_: agent, engine

### The record

**Record**:
The append-only history of a run: every event, in the order it was written.
The record is the truth; everything else is derived from it.
_Avoid_: log, status file, journal, database

**Event**:
One line of the record. Seven kinds: a report, a note, an assignment, a
close, an add, a change, a remove.
_Avoid_: message, entry, update

**Report**:
An executor's statement that a task's status (and phase) changed. Only the
executor working a task reports on it.
_Avoid_: update, status update, progress, ping

**Note**:
A free-text event spoken in a voice: the tower's, a lane's, or a task's. The
narrative channel — merges, escalations, decisions.
_Avoid_: comment, message, log line, remark

**Close**:
The declaration that a run is finished, whatever its tasks' statuses. A
closed run needs no attention.
_Avoid_: complete, finish, end, archive

**Add**:
The event that gives a run a task the plan did not have. A task's origin is
either the plan or an add.
_Avoid_: create, insert, new task

**Change**:
The event that edits a task's title, area, or position. Never its status.
_Avoid_: edit, update, rename

**Remove**:
The event that takes a task off the board. Its history stays in the record.
_Avoid_: delete, drop, cancel

### What the record says

**Status**:
One of exactly five words a task can be in: `pending`, `in_progress`,
`reviewing`, `done`, `blocked`. Any status may follow any status; the last
report wins.
_Avoid_: state (that is the whole run), stage, condition

**Phase**:
Free text refining a status: conventionally `implementing`, `spec-review`,
`quality-review`, `fixing`, `committed`. tower shows an unknown phase as-is.
_Avoid_: step, stage, sub-status

**Blocked**:
A status: the executor cannot proceed and has said, in a note, exactly what it
needs. Blocked is never stale.
_Avoid_: stuck, waiting, paused

**State**:
What the record folds to: every task with its status, lane and model, plus the
derived facts below. Pure: the same record always gives the same state.
_Avoid_: status (that is one task's word), dashboard, view

**Stale**:
Derived: an `in_progress` or `reviewing` task with no report for longer than
the stale threshold. `pending`, `done` and `blocked` are never stale.
_Avoid_: hung, dead, silent, NORDO (rendering only)

**Attention**:
Derived: the run is not closed and something is blocked or stale. The one
boolean a script needs.
_Avoid_: alert, alarm, needs-human, urgent

**Complete**:
Derived: every task is `done`. Never declared — contrast **Close**.
_Avoid_: finished, closed, done (that is a task's status)

**Brief**:
The letter an executor receives: its tasks, how to report, the plan's
conventions, the roles, the standing rules. Composed from the run, never
templated.
_Avoid_: prompt, instructions, system prompt

### The screen

**Console**:
The live, read-only screen of a run.
_Avoid_: dashboard, TUI, UI, app

**Board**:
The console's list of tasks.
_Avoid_: table, task list, departures (rendering only)

**Transcript**:
The console's list of events, newest last.
_Avoid_: log, feed, stream, timeline

**Snapshot**:
The console rendered once as plain text — what a pipe, an agent's tool call,
or `state` without `--json` receives.
_Avoid_: dump, print, export

**Theme**:
A vocabulary: one word per status, phase and heading, used only by the console.
A theme renames; it never re-models. `airport` is the only one that ships;
`plain` is the literal rendering.
_Avoid_: skin, mode, style, language

### Airport words (rendering only)

The default theme's vocabulary. These words appear on the board and in the
README. They never appear in code identifiers, error messages, JSON, or the
brief — those use the terms above.

| board says                    | the term is                             |
| ----------------------------- | --------------------------------------- |
| tower (the voice)             | the orchestrator's notes                |
| runway                        | lane                                    |
| flight, callsign + id         | task                                    |
| on the ground                 | pending                                 |
| cleared for takeoff, airborne | in_progress                             |
| on approach, on final         | reviewing (spec review, quality review) |
| go around                     | in_progress, phase `fixing`             |
| landed                        | done                                    |
| holding short, squawk 7700    | blocked                                 |
| NORDO                         | stale                                   |
| field closed                  | closed                                  |
| information + letter          | the run's broadcast line                |
