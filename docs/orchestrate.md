# orchestrate: tower's herdr runner

The `tower` plugin's skills for planning and running a multi-task
implementation inside [herdr](https://herdr.dev): one orchestrating session
and one to four executing lanes. [tower](https://github.com/phutschi/tower)
keeps the record: every run has its board and transcript.

| Skill                 | What it does                                                                            |
| --------------------- | --------------------------------------------------------------------------------------- |
| `/tower:spec-to-plan` | Turns a spec into `plan.md`: tasks, lanes, merge points. Any session.                   |
| `/tower:orchestrate`  | Runs a plan (or a request) with lanes, reviews, merge, preflight and a PR. Needs herdr. |
| `/tower:preflight`    | Checks a whole branch before its PR. Also on its own, without herdr.                    |

Planning and running are separate sessions, and the plan is the only thing
between them.

You talk to the orchestrator. It opens the run, owns the task list, briefs
the lanes, watches, has every lane reviewed, merges, checks the whole
branch, opens a pull request (a draft by default), and closes. It never
writes code. Lanes execute their brief and report their own tasks.
Reviewers review and report findings. Nothing else.

## Quick start

### Tell this to your agent to get started quickly

**1. Install.** Paste this into Claude Code:

```
Install the tower plugin: clone git@github.com:phutschi/tower.git into
~/tools/tower (or pull it if it is already there) and run
~/tools/tower/install.sh. If it reports a missing dependency,
tell me which one and how to install it, then run it again. When it passes,
tell me to restart Claude Code so the /tower: skills show up.
```

**2. Plan.** In any session, in your repo, on the feature branch:

```
/tower:spec-to-plan <path or issue URL of the spec>
```

It slices the spec into tasks, proposes the lanes, asks you to approve
them, and writes `plan.md`. It writes no code.

**3. Run.** In a new session, from a herdr pane, same repo and branch:

```
/tower:orchestrate <path to plan.md>
```

The orchestrator briefs the lanes, gets their work reviewed and merged,
checks the whole branch, and asks you once before it pushes and opens a
draft PR.

No spec yet? Skip step 2: run `/tower:orchestrate` with no plan, and
your next message is the work.

## Install

```
git clone git@github.com:phutschi/tower.git ~/tools/tower
~/tools/tower/install.sh
```

That checks the dependencies (herdr, git, bash, python3, node; claude,
tower, codex, semgrep and gitleaks optional), adds this repo as the
`phutschi-tower` marketplace in Claude Code and installs the `tower` plugin
from it. For codex it links `orchestrate`, `spec-to-plan` and `preflight`
into `~/.agents/skills`, and `preflight` into `~/.codex/skills` (codex
Reviewers load it). Links of the kit's old layout in
`~/.claude/skills` are removed, so no skill shows up twice.
`install.sh --check` only checks.

Claude Code installs a copy of the plugin. After a `git pull`, run
`install.sh` again (it updates the plugin) and restart Claude Code.

## Two openings

From a herdr pane, in your repo, on the feature branch:

- **With a plan.** `/tower:orchestrate <path>`. The path is a markdown
  plan with `### Task <id>: <title>` headings (what
  `/tower:spec-to-plan` writes), or a TSV (`id<TAB>title<TAB>area`, see
  `skills/orchestrate/example-tasks.tsv`). Keep plans wherever you like;
  the kit only takes the path.
- **Without.** `/tower:orchestrate` alone. The layout comes up, the
  orchestrator reports the pane map (`panes.txt` in the run dir), and your
  next message is the work. It derives the task list, puts it on the board,
  and briefs the lanes. Say "two lanes" or "ask me before you brief" if you
  want that.

Either way, the orchestrator briefs nobody until the task list is on the
board — the gate.

## The layout

One tab:

```
┌──────────────┬──────────┬──────────┐
│ orchestrator │ lane A   │ lane B   │
│              ├──────────┼──────────┤
│              │ lane C   │ lane D   │
├──────┬───────┴──┬───────┴──────────┤
│ dev  │ checks   │ console          │
└──────┴──────────┴──────────────────┘
```

- **Lanes** are the executors. Lane A works in your checkout on the feature
  branch (the integration branch); B to D get worktrees under `.worktrees/`.
  The grid grows one lane at a time: B right of A, C under A, D under B.
  Four at most. A lane that needs another lane's work merges it at its own
  merge point; a _finished_ lane is merged into the integration branch by
  the orchestrator, right away — never by lane A.
- **checks** runs your test runner in watch mode, **dev** your development
  server if you declare one. Both run in lane A's checkout.
- **console** is tower's live board, the record of the run. It stays open
  after the run; you quit it with `q`. The run dir is no second record: it
  holds the pane map, the briefs, the findings and tower's own run files.
  Console is tower's minimum width, 60
  columns; the bottom row always spans the full tab so it always gets them.

Nothing is closed until you say so.

## Reviews, preflight and the PR

A run ends in a pull request, a draft by default (the `PR` switch), in
this order:

1. **Lane review.** When a lane reports ready (lane A too, after its last
   task), a **Reviewer** reviews the lane's diff before it is merged. It is
   a fresh agent of the other kind: codex reviews claude lanes on
   gpt-6-astra, claude reviews codex lanes on claude-opus-5-5. With only
   one kind installed, the same kind reviews in a fresh agent (claude on
   claude-fable-5-1, codex on the reviewed lane's model); bootstrap prints
   the choice and any fallback on its `reviewer:` line. Reviewers only report. The orchestrator triages their
   findings alone: a real problem the lane introduced goes back to that
   lane as a fix task, the rest waits for the preflight table. Each fix
   prompt starts the lane's next report round and asks for an end line
   that carries the round's number; the orchestrator then watches the lane
   as `watch-lanes.sh <run-dir> <agent>:<n>`, so an earlier report
   still on the screen never reads as done. A fix loop stops after the
   second re-review and comes to you.
2. **The review tab.** The first review opens a second tab with two
   slots, R1 and R2 (`add-reviewer.sh`). Every review starts a new agent in
   a slot and becomes a task on the board owned by that slot. The tab
   stays open after the run.
3. **Merge.** The orchestrator merges each reviewed lane, then `origin/main`.
   A merge that conflicts is aborted and becomes a task for lane A.
4. **Preflight** checks the whole branch: semgrep and gitleaks on the diff,
   the repo's full suite, then agent review by area. R1 runs the checks and
   reviews the spec and problems between lanes; R2 reviews security,
   performance and error handling. `/tower:preflight` is also a skill of
   its own: run it on any branch, without herdr.
5. **One table, one reply.** The orchestrator shows you every finding in
   one table with a suggested outcome: fix, accept, follow-up or reject.
   Your one reply approves the fixes, the follow-up issues (filed where
   `docs/agents/issue-tracker.md` says), the push and the PR. Nothing
   leaves your machine before it.
6. **The PR.** The orchestrator pushes and opens the PR (a draft unless
   `PR=ready`; `PR=off`: no push, no PR), with a verdict table, the review
   of each area and the follow-ups in its body.
   Executors and Reviewers never push.

## Telling the kit about your repo

JS repos need nothing: the package manager, the typecheck script and the
test runner are detected from lockfiles and `package.json`. Anything else,
or any repo whose real entrypoint is its own tool, writes a `.orchestrate`
file in the root (see `skills/orchestrate/example.orchestrate`):

```bash
CHECK_CMD="make check"            # the check gate every lane runs before a commit
INSTALL_CMD="make deps"           # what each new lane's worktree runs; empty turns it off
pane checks "make test-watch"     # pane NAME "COMMAND" [DIR]; NAME is checks or dev
pane dev    "make dev" web
EXECUTOR_KIND=codex               # the lanes' harness: claude (default) or codex
EXECUTOR_MODEL=gpt-6-astra        # the lanes' model
SPEC_REVIEWER_MODEL=sonnet        # the reviewer models tower records
QUALITY_REVIEWER_MODEL=opus
STALE=30                          # minutes before the console and tower wait flag a lane as stale
suite lint  "make lint"           # the full suite, as named steps preflight runs in order
suite test  "make test"
suite build "make build" web
```

A repo that still has the old name, `.herdr-orchestrate`, keeps working,
with a note to rename it.

The same names in the environment of a bootstrap or add-lane call win over
the file for that call. A name the kit does not read is pointed out on stderr.
`START_TRIES` (environment only, default 10) is how often an agent start is
tried, a second apart, while a new pane's shell is not ready yet.

## Run switches

Each stage is a switch. The repo contract sets the defaults, you change them
per run in plain words ("no PR", "skip the lane reviews", "no tdd, it's a
spike"), and bootstrap records the values the run uses on the `switches:`
line of the pane map and in the record.

| Switch            | Default        | Other values                                    |
| ----------------- | -------------- | ----------------------------------------------- |
| `TASK_REVIEW`     | on             | off: no spec and quality review after each task |
| `LANE_REVIEW`     | on             | off: lanes are merged without a Reviewer        |
| `PREFLIGHT`       | on             | off: no whole-branch check before the PR        |
| `STATIC_BASELINE` | on             | off: preflight skips semgrep and gitleaks       |
| `PR`              | draft          | ready, or off (no push, no PR)                  |
| `METHOD`          | tdd            | plain: lanes work without the tdd loop          |
| `REVIEWER_KIND`   | other          | claude or codex, for every review               |
| `REVIEWER_MODEL`  | the kit's pick | any model                                       |
| `REVIEW_AREAS`    | every area     | e.g. `security,spec`                            |
| `SUITE_SKIP`      | none           | suite steps to skip, e.g. `build`               |
| `PR_TEMPLATE`     | preflight's    | a PR body template in the repo                  |

A value outside the list is refused at bootstrap.

## Executor kinds

Lanes run Claude Code by default (`claude-opus-5-5[1m]`). A repo can switch
its runs to codex in `.orchestrate` (`EXECUTOR_KIND=codex`, model
`gpt-6-astra`; `EXECUTOR_MODEL` overrides either), and a single lane can
differ: `EXECUTOR_KIND=codex` in that bootstrap or add-lane call. Mixed runs
are fine.

## Testing the kit

`./test.sh` runs without herdr, tower, claude, codex, semgrep or gitleaks:
stubs under `skills/orchestrate/tests/stub/` log what would be called.
`DRY_RUN=1 skills/orchestrate/bootstrap.sh …` from any directory shows the same for a real repo.
`shellcheck -S warning *.sh skills/*/*.sh skills/orchestrate/tests/stub/*` lints
(`.shellcheckrc` holds the deliberate exceptions). CI runs both on Linux and
macOS.
`./test.sh --fast` skips the slow sections (preflight's look and the whole
run) and is part of the check gate in tower's `.orchestrate`; the full
`./test.sh` is one of its suite steps.

## Where the kit lives in tower

```
.claude-plugin/        the phutschi-tower marketplace and the tower plugin manifest
src/                   the tower CLI (not part of the kit)
skills/run/            the runner-neutral skill (not part of the kit)
skills/orchestrate/    the orchestrator's skill and scripts; tests/ holds the stubs and fixtures
skills/spec-to-plan/   the planning skill and its plan template
skills/preflight/      the whole-branch check
install.sh, test.sh    install and test the kit
```

## Design

`CONTEXT.md` is the glossary. `docs/adr/` holds the decisions: lanes never
change the task list, tower is the record, Reviewers report and the
orchestrator decides.
