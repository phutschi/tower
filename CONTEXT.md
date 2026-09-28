# tower

A console for watching a crew of coding agents implement a plan, and the
record they report into. tower keeps the record and draws the board; it never
acts on the run. The acting lives in the plugin's skills: `/tower:run` for any
runner, `/tower:orchestrate` for herdr, and `/tower:spec-to-plan` and
`/tower:preflight` around them.

## Language

### The run

**Run**:
One execution of a plan by a crew of executors, from `init` to `close`. A run
has an identity (repository, branch, plan) and a record.
_Avoid_: session, job, dashboard, project

**Plan**:
The document that lists the tasks, in order. Where it came from is not tower's
concern; `/tower:spec-to-plan` writes one from a spec. A run may have none;
its tasks then all come from adds.
_Avoid_: spec, ticket, backlog, design

**Opening**:
How an orchestrate run starts. Planned: the user names a plan, and its tasks
are on the board from `init`. Empty: the user names nothing, their next
message is the work, and the orchestrator adds the tasks. Either way no lane
is briefed before its tasks are on the board.
_Avoid_: mode, entry point

**Task**:
One unit of the plan, named by an id, owned by at most one lane at a time.
_Avoid_: item, step, ticket, issue, flight (rendering only)

**Lane**:
A group of tasks worked in order by one executor. In an orchestrate run lanes
are lettered A to D, and each has its own branch and checkout: lane A the
checkout the run opens in, the others a worktree each.
_Avoid_: runway (rendering only), worker, thread, track, stream

**Integration branch**:
Lane A's branch, the feature branch of an orchestrate run. Lane A works on it
in the checkout the run opens in, which may itself be a worktree. The
orchestrator merges finished lanes into it, and the checks pane runs on it.
_Avoid_: main lane, trunk

**Merge point**:
A task before which a lane merges another lane's branch, written in its brief.

**Assignment**:
The recorded fact that a lane owns certain tasks. Assigning is a judgement the
orchestrator makes after reading the plan; tower only records it.
_Avoid_: lane cut, ownership

**Callsign**:
The short upper-case name of the run's repository, used to name tasks aloud on
the board (`ACME 14`).
_Avoid_: prefix, tag

**Run dir**:
The directory that holds a run's record, made by `init` and printed by
`state --json` as `runDir`. An orchestrate run also keeps its pane map, its
briefs and its findings there. None of them is a second record.

**Pane map**:
`panes.txt` in the run dir: every pane of an orchestrate run by role and id,
and a `switches:` line with the run switches the run used.

### The people and programs

**Orchestrator**:
The person or agent who creates the run, briefs the executors, watches, and
decides. Never implements. In an orchestrate run it also merges finished
lanes and closes; a merge that conflicts is aborted and becomes a task for
lane A.
_Avoid_: supervisor, manager, lead, controller, main session, tower

**Executor**:
The agent working one lane's tasks and reporting on them. An executor holds
whichever role the current phase needs. In an orchestrate run its kind is
claude or codex, and it never adds, changes or removes a task (ADR 0008).
_Avoid_: worker, implementer (a role, not the agent), agent (too broad)

**Reviewer**:
An agent in an orchestrate run that reviews finished work it did not write,
by default of the other kind than the executors. It only reports findings;
the orchestrator decides what becomes a fix task and which lane does it
(ADR 0010).
_Avoid_: review lane, reviewer model (the spec and quality reviewer roles
inside a lane)

**Reviewer slot**:
One of two places a Reviewer runs, R1 and R2. Each review in a slot is a task
on the board, `R<n>-<k>` in lane `R<n>` with area `review`. A lane that
reports ready while both slots are busy waits.
_Avoid_: review lane, reviewer pane

**Runner**:
Whatever starts and hosts executor sessions — panes, worktrees, processes.
herdr is one, and `/tower:orchestrate` drives it. The CLI and `/tower:run`
know nothing about any runner (ADR 0005).
_Avoid_: harness, launcher, orchestrator

**Harness**:
The tool an agent runs inside (a coding-agent CLI or IDE). Distinct from the
runner: the runner starts sessions, the harness is what a session is. The CLI
and `/tower:run` are harness-neutral.
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
_Avoid_: log, status file, journal, database, history

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
boolean a script needs. In an orchestrate run the watch also reports
attention per agent, lane or Reviewer: herdr says it is blocked, done or
gone, or it is idle with or without its end line.
_Avoid_: alert, alarm, needs-human, urgent

**Complete**:
Derived: every task is `done`. Never declared — contrast **Close**.
_Avoid_: finished, closed, done (that is a task's status)

**Brief**:
The letter an executor receives: its tasks, how to report, the plan's
conventions, the roles, the standing rules. tower composes it from the run,
with no template. In an orchestrate run the orchestrator writes what tower
cannot know on top, from the kit's brief template: the method, the other
lanes and the merge points.
_Avoid_: prompt, instructions, system prompt

### Watching and review

**Settled**:
A lane whose executor has stopped working, for any reason.

**End line**:
A phrase in double square brackets that starts a line near the end of a
lane's or Reviewer's reply: `READY TO MERGE`, `ALL DONE` or
`FINDINGS WRITTEN`, tagged `r<n>` from round 2. The watch reads it to tell an
agent that finished from one that stopped. It is not an event.

**Report round**:
One ask for a lane's end line. Round 1 is its brief; each fix prompt after it
starts the next round, and that round's end line carries its number. The
watch counts only the expected round's end line. A re-brief keeps the
round.
_Avoid_: fix round (a round is the ask, not the fix), iteration

**Lane review**:
A Reviewer's review of one lane's diff, after the lane reports ready and
before the orchestrator merges it. Fixes go back to the same lane.
_Avoid_: per-task review (the executor's own review inside a lane)

**Preflight**:
The check of a whole branch before its PR: static analysis, the repo's full
suite, and agent review by area. `/tower:preflight` is a skill of its own and
the last phase of an orchestrate run.
_Avoid_: pre-PR check, final review

**Preflight round**:
One look at the branch, and the triage and fixes that follow, with its own
findings dir. After fixes the next round looks at the whole branch again.
_Avoid_: re-review (a lane review's word), fix round

**Static baseline**:
Preflight's static analysis of the branch's diff (semgrep and gitleaks), run
before the full suite and the agent review.
_Avoid_: lint, scan

**Review area**:
One subject a preflight review covers (security, spec, performance and the
rest), named by a file in preflight's `areas/` or the repo's
`.preflight/areas/`. Not a task's area, which is free text on the board.
_Avoid_: area alone where a task's area could be meant

**Finding**:
One problem a review reports, with the file and line it cites. Triage gives
it one outcome: fix, accept, follow-up or reject.

**Follow-up**:
A finding chosen to be done later. It always becomes an issue in the repo's
issue tracker, linked from the PR.
_Avoid_: todo, deferred finding

### The screen

**Console**:
The live, read-only screen of a run.
_Avoid_: dashboard, TUI, UI, app

**Board**:
The console's list of tasks.
_Avoid_: table, task list (say the board, or the run's tasks), departures
(rendering only)

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

### The orchestrate layout

**Layout**:
The fixed pane arrangement of an orchestrate run on one herdr tab:
orchestrator left, the lane grid right, and a bottom row of dev, checks and
console.

**Lane grid**:
The 2x2 area for lane panes: A and B on top, C and D below. It grows as lanes
are added and is capped at four.

**Console pane**:
The bottom-right pane that runs the console. It stays open after the run until
the human quits it.
_Avoid_: tower pane

**Checks pane**:
The bottom pane running the repo's checks on change, in lane A's checkout.
_Avoid_: tests pane, typecheck pane, watch pane

**Dev pane**:
An optional bottom pane running the repo's development server in lane A's
checkout. One per run, never per lane.

**Check gate**:
The one-shot command a lane must pass before committing a task. Declared by
the repo contract, or the JS default.

**Full suite**:
The repo's thorough checks, run once in preflight on the whole branch: every
test, typecheck, lint and build. Slower and broader than the check gate.
_Avoid_: check gate (that runs per task), checks pane (that watches)

**Repo contract**:
The `.orchestrate` file in a repo root: its panes, its install command, its
check gate, its full suite as named `suite` steps, and the run's defaults for
the executor kind and model, the reviewer models, the stale threshold and the
run switches. The environment of any kit call wins over the file; without
either, the kit detects the repo's stack, and falls back to the JS default
and claude.
_Avoid_: config, override file

**Run switch**:
One setting that turns a stage or choice of the run on, off or to a variant:
per-task review, lane review, preflight, static baseline, PR mode, method,
reviewer kind and model, review areas, skipped suite steps, PR template. The
repo contract sets its default, the user's message overrides it, and the pane
map records the value the run used.
_Avoid_: flag, option, profile

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
