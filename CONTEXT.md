# herdr-orchestrate

A skill and a kit of scripts for running a multi-task implementation inside
herdr: one orchestrating session, one to four executing agents, a live record.

## Language

### The run

**Run**:
One implementation, from bootstrap to close, with one task list and one record.
_Avoid_: session, job

**Task list**:
The tasks of a run, on the board with tower or in the run dir's tasks file
without. It exists before any lane is briefed.
_Avoid_: plan (a plan is where a task list may come from), backlog

**Plan**:
A file the user points to, from which the task list is loaded. The kit never
guesses where it lives.
_Avoid_: spec, design

**Opening**:
The way a run starts. Planned: the user gives a plan or task file. Empty: the
user gives nothing and their next message is the work.
_Avoid_: mode, entry point

**Record**:
What a human reads after the run: tower's board and transcript when tower is
installed, the run dir and the git log without.
_Avoid_: log, history

**Run dir**:
The directory holding a run's files: the pane map, briefs, and without tower
the task list and lane ownership.

**Pane map**:
`panes.txt` in the run dir: every pane of the run by role and id.

### Who does what

**Orchestrator**:
The session the user talks to. It sets up the layout, loads or derives the
task list, briefs lanes, watches, merges finished lanes and `main`, and
closes. It never implements: a merge that conflicts is aborted and becomes a
task for lane A.
_Avoid_: main session, controller, manager

**Lane**:
The unit of work ownership: a set of task ids, a branch, a checkout and one
executor. Lanes are lettered A to D. Lane A works in the main checkout on the
integration branch.

**Executor**:
The agent running a lane. Its kind is claude or codex. It executes its brief
and reports only its own tasks. It never changes the task list.
_Avoid_: worker, implementer (a tower role name), agent (herdr's word)

**Brief**:
The one message that gives a lane all its tasks, method, other lanes, merge
points and reporting rules.
_Avoid_: prompt, instructions

**Reviewer**:
An agent that reviews finished work it did not write, by default of the other
kind than the executors. It only reports findings; the orchestrator decides
what becomes a fix task and which lane does it.
_Avoid_: review lane, reviewer model (tower's per-task review roles inside a lane)

**Lane review**:
A Reviewer's review of one lane's diff, after the lane reports ready and
before the orchestrator merges it. Fixes go back to the same lane.
_Avoid_: per-task review (the executor's own review inside a lane)

**Preflight**:
The check of a whole branch before its PR: static analysis, the repo's full
suite, and agent review by area. A generic skill of its own; the last phase
of a run.
_Avoid_: pre-PR check, final review

**Preflight round**:
One look of preflight and the act on it, with its own findings dir. After
fixes the next round looks at the whole branch again.
_Avoid_: re-review (a lane review's word), fix round

**Finding**:
One problem a review reports, with the file and line it cites. Triage gives
it one outcome: fix, accept, follow-up or reject.

**Follow-up**:
A finding chosen to be done later. It always becomes an issue in the repo's
issue tracker, linked from the PR.
_Avoid_: todo, deferred finding

**Integration branch**:
Lane A's branch, the feature branch of the run. Finished lanes are merged into
it by the orchestrator, and the checks pane runs on it.
_Avoid_: main lane, trunk

**Merge point**:
A task before which a lane merges another lane's branch, written in the brief.

### The layout

**Layout**:
The fixed pane arrangement of a run on one tab: orchestrator left, the lane
grid right, the bottom row of dev, checks and console.

**Lane grid**:
The 2x2 area for lane panes: A and B on top, C and D below. It grows as lanes
are added and is capped at four.

**Console pane**:
The bottom-right pane holding the record's live view: tower's board, or the
git log without tower. It stays open after the run until the human quits it.
_Avoid_: tower pane, git log pane

**Checks pane**:
The bottom pane running the repo's checks on change, in lane A's checkout.
_Avoid_: tests pane, typecheck pane, watch pane

**Dev pane**:
An optional bottom pane running the repo's development server in lane A's
checkout. One per run, never per lane.

**Check gate**:
The one-shot command a lane must pass before committing a task. Declared by
the repo, or the JS default.

**Full suite**:
The repo's thorough checks, run once in preflight on the whole branch: every
test, typecheck, lint and build. Slower and broader than the check gate.
_Avoid_: check gate (that runs per task), checks pane (that watches)

**Repo contract**:
The `.herdr-orchestrate` file in a repo root: its panes, its check gate, its
full suite as named `suite` steps, and the run's defaults for the executor
kind and model, the reviewer models, the stale threshold and the run
switches. Without it the kit uses the JS default and claude. The environment
of any kit call wins over the file.
_Avoid_: config, override file

**Run switch**:
One setting that turns a stage or choice of the run on, off or to a variant:
per-task review, lane review, preflight, static baseline, PR mode, method,
reviewer kind and model, review areas, skipped suite steps, PR template. The
repo contract sets its default, the user's message overrides it, and the pane
map's `switches:` line records the value the run used.
_Avoid_: flag, option, profile

### Watching

**Attention**:
A lane state the orchestrator must act on: blocked, idle after its final
report, idle unexplained, done, or gone.

**Settled**:
A lane whose executor has stopped working, for any reason.
