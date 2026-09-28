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
task list, briefs lanes, watches, merges finished lanes, and closes. It never
implements.
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

**Repo contract**:
The `.herdr-orchestrate` file in a repo root: its panes, its check gate, and
the run's defaults for the executor kind and model, the reviewer models and
the stale threshold. Without it the kit uses the JS default and claude. The
environment of a bootstrap or add-lane call wins over the file.
_Avoid_: config, override file

### Watching

**Attention**:
A lane state the orchestrator must act on: blocked, idle after its final
report, idle unexplained, done, or gone.

**Settled**:
A lane whose executor has stopped working, for any reason.
