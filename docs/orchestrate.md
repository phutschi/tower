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
them, and writes `plan.md` to `$TOWER_PLANS_DIR/<repo>_<branch>/`, outside
the repo (`TOWER_PLANS_DIR` defaults to
`${XDG_STATE_HOME:-$HOME/.local/state}/tower/plans`). It writes no code.

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

That checks the dependencies (herdr, tower, git, bash, python3, node; claude,
codex, cursor-agent, semgrep and gitleaks optional). tower is required and
must run: a missing tower shows up here, not at the start of a run.

When tower is missing, install.sh fetches it. The primary path is the release
binary for macOS or Linux (arm64 or x64) of this checkout's version, into
`~/.local/bin` (or `$TOWER_BIN_DIR`). It is checked against the release's
`SHA256SUMS`: a mismatch, a missing checksum file, or no checksum for this
platform is refused, and nothing is installed. On another platform, install tower from git first, with Node ≥ 22.12:
`npm i -g github:phutschi/tower`, which builds with Node alone. You never need
bun to use tower or the kit.

With claude, it adds this repo as the `phutschi-tower` marketplace in Claude
Code and installs the `tower` plugin from it. The kit's plugin and marketplace
from before it moved into tower are removed first, so only one orchestrator is
installed. A claude command that fails is printed as `FAILED`, and the install
exits 1. For codex it links `orchestrate`, `spec-to-plan` and `preflight` into
`~/.agents/skills`, and `preflight` into `~/.codex/skills` (codex Reviewers
load it). Links of the kit's old layout in `~/.claude/skills` are removed, so
no skill shows up twice. cursor needs no links of its own: it reads the
skills in `~/.agents/skills`, `~/.claude/skills` and `~/.codex/skills`.
`install.sh --check` only checks, and fetches nothing.

Claude Code installs a copy of the plugin. After a `git pull`, run
`install.sh` again (it updates the plugin) and restart Claude Code.

## Two openings

From a herdr pane, in your repo, on the feature branch:

- **With a plan.** `/tower:orchestrate <path>`. The path is a markdown
  plan with `### Task <id>: <title>` headings (what
  `/tower:spec-to-plan` writes), or a TSV (`id<TAB>title<TAB>area`, see
  `skills/orchestrate/example-tasks.tsv`). Keep plans wherever you like;
  the kit only takes the path. The plan's lanes go to bootstrap as
  `LANES="A=1-4,6 B=5"`; `A=all` gives lane A every task, and is then the
  only lane.
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
   a fresh agent of another kind, the first installed of an ordered list:
   codex for a claude lane, claude for a codex lane, claude then codex for
   a cursor lane. cursor never reviews a claude or codex lane unless
   `REVIEWER_KIND=cursor` says so. Each kind reviews on its
   `REVIEWER_MODEL_<KIND>` (by default codex on gpt-6-astra, claude on
   claude-opus-5-5, cursor on grok-4.7-high-fast). With no candidate
   installed, the lane's own kind reviews in a fresh agent (claude on
   claude-fable-5-1, codex on the reviewed lane's model, cursor on
   grok-4.7-high-fast), with a fallback note; bootstrap prints the choice on
   its `reviewer:` line. The credit guard (below) can skip a candidate that is
   nearly out of quota. Reviewers only report. The orchestrator triages their
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
EXECUTOR_KIND=codex               # the lanes' harness: claude (default), codex or cursor
EXECUTOR_MODEL=gpt-6-astra        # the lanes' model, for this repo's runs
EXECUTOR_MODEL_CURSOR=grok-4.7-high-fast  # a kind's default model (see below)
SPEC_REVIEWER_MODEL=sonnet        # the reviewer models tower records
QUALITY_REVIEWER_MODEL=opus
STALE=30                          # minutes before the console and tower wait flag a lane as stale
suite lint  "make lint"           # the full suite, as named steps preflight runs in order
suite test  "make test"
suite build "make build" web
```

A repo that still has the old name, `.herdr-orchestrate`, keeps working,
with a note to rename it.

The file is bash, run in the orchestrator's shell, so a run reads it once.
bootstrap pins the contract it read: a read-only copy under
`$XDG_STATE_HOME/tower/contracts/` (default `~/.local/state`), named by the
run dir, which the pane map's `contract:` line points to. add-lane and
add-reviewer read that pin, never a checkout, the run dir or the git dir,
all of which a codex lane may write. A lane's edit to `.orchestrate` takes
effect in the next run, after review. Pins stay after the run; they are
small, and removing `contracts/` once no run is open is safe. `look.sh`
still reads the branch's own file: it runs inside the Reviewer.

The same names in the environment of a bootstrap or add-lane call win over
the file for that call. A name the kit does not read is pointed out on stderr.
`START_TRIES` (environment only, default 10) is how often an agent start is
tried, a second apart, while a new pane's shell is not ready yet.
`START_SETTLE_SECONDS` (default 3) and `READY_WAIT_SECONDS` (default 30),
environment only too, are how long a started agent is given, and how many
reads about a second apart it then gets, to accept input. An agent that never
does fails the call and is left running in its pane.

### Model defaults and the user contract

Every default model is data: `skills/orchestrate/model-defaults` holds them,
keyed per kind (`EXECUTOR_MODEL_<KIND>`, `REVIEWER_MODEL_<KIND>`,
`REVIEWER_MODEL_CLAUDE_SELF`, `SPEC_REVIEWER_MODEL_<KIND>` and
`QUALITY_REVIEWER_MODEL_<KIND>`, with `<KIND>` one of `CLAUDE`, `CODEX`,
`CURSOR`), plus the credit guard's `REVIEWER_CREDITS_MIN`. A new model is a
change to that file, or to one of the contracts below, never to the kit's
logic.

Your own defaults for every repo go in the **user contract**,
`${XDG_CONFIG_HOME:-~/.config}/tower/orchestrate`, in the repo contract's
syntax. It may set:

- `EXECUTOR_KIND`, `STALE`, and the per-kind model keys and
  `REVIEWER_CREDITS_MIN`;
- the switches `TASK_REVIEW`, `LANE_REVIEW`, `PREFLIGHT`, `STATIC_BASELINE`,
  `METHOD`, `REVIEWER_KIND` and `REVIEWER_BY_CREDITS`.

Anything else is the repo's (the check gate, install, panes, suite and
toolchain, the unsuffixed `EXECUTOR_MODEL` and friends, `PR`,
`REVIEW_AREAS`, `SUITE_SKIP`, `PR_TEMPLATE`): the user contract names such a
key on stderr and ignores it. A file that fails to load is refused, and a
missing one is silent. It is read on every call, not pinned.

Precedence, first wins: the environment of a kit call, the repo contract,
the user contract, the kit's `model-defaults`. The unsuffixed
`EXECUTOR_MODEL` and `REVIEWER_MODEL` still replace the model of the lane or
Reviewer a call opens.

## Run switches

Each stage is a switch. The repo contract sets the defaults, you change them
per run in plain words ("no PR", "skip the lane reviews", "no tdd, it's a
spike"), and bootstrap records the values the run uses on the `switches:`
line of the pane map and in the record.

| Switch                 | Default        | Other values                                    |
| ---------------------- | -------------- | ----------------------------------------------- |
| `TASK_REVIEW`          | on             | off: no spec and quality review after each task |
| `LANE_REVIEW`          | on             | off: lanes are merged without a Reviewer        |
| `PREFLIGHT`            | on             | off: no whole-branch check before the PR        |
| `STATIC_BASELINE`      | on             | off: preflight skips semgrep and gitleaks       |
| `PR`                   | draft          | ready, or off (no push, no PR)                  |
| `METHOD`               | tdd            | plain: lanes work without the tdd loop          |
| `REVIEWER_KIND`        | other          | claude, codex or cursor, for every review       |
| `REVIEWER_MODEL`       | the kit's pick | any model                                       |
| `REVIEWER_BY_CREDITS`  | off            | on: the credit guard (below)                    |
| `REVIEWER_CREDITS_MIN` | 20             | 0-100: the % left below which the guard skips   |
| `REVIEW_AREAS`         | every area     | e.g. `security,spec`                            |
| `SUITE_SKIP`           | none           | suite steps to skip, e.g. `build`               |
| `PR_TEMPLATE`          | preflight's    | a PR body template in the repo                  |

A value outside the list is refused at bootstrap.

## Executor kinds

Lanes run Claude Code by default (`claude-opus-5-5[1m]`). A repo can switch
its runs to codex (`EXECUTOR_KIND=codex`, model `gpt-6-astra`) or to Cursor's
CLI (`EXECUTOR_KIND=cursor`, `cursor-agent`, model `grok-4.7-high-fast`) in
`.orchestrate` or the user contract; `EXECUTOR_MODEL` or the kind's
`EXECUTOR_MODEL_<KIND>` changes the model. A single lane can differ:
`EXECUTOR_KIND=cursor` in that bootstrap or add-lane call. Mixed runs are
fine.

A cursor agent starts with these arguments:

```
--model <m> --trust --force --disable-auto-update
--add-dir <run-dir> --add-dir <git-common-dir>
```

- `--trust`: no workspace trust box. herdr reads that box as idle and ready,
  so the brief would land in it. The kit never answers it with keys; a start
  still blocked there fails and asks you to check the pane.
- `--force`: no approval prompts.
- `--disable-auto-update`: no self-update during the run. The flag is
  undocumented.
- `--add-dir`: it may write the run dir and the common git dir.

It gets no `--sandbox` flag, so your own cursor sandbox setting applies. One
that exits right after its start is started once more, as the other kinds
are. A cursor lane loads the tdd skill from `~/.agents/skills`,
`~/.claude/skills` or `~/.codex/skills`. With it in none of them, the start
prints how to link it.

A codex agent runs in codex's workspace-write sandbox, with its startup update
check off. Outside its checkout it may write the run dir and what a commit
needs in the repo's common git dir. A lane in a worktree (lanes B-D) gets only
`objects`, `refs`, `logs`, `packed-refs` and its own `worktrees/<lane>`, so the
repo's hooks and config stay out of its reach; these writable roots replace any
set in your codex config. Lane A and the Reviewers work
in the main checkout, whose index, HEAD and rebase and stash state live in the
common git dir itself, so a codex agent there gets the whole common git dir.
Its sandbox then does not contain `.git/hooks` or `.git/config`: a hook or a
`core.fsmonitor` it writes runs outside the sandbox on the next git command,
yours or the kit's. Run lane A as claude, or read `.git/hooks` and
`git config --local --list` before you merge, when that matters.

No lane, lane A included, may write `$XDG_STATE_HOME/tower/` (default
`~/.local/state`): the contract pins live there, and preflight's `look.sh`
makes its temp worktree of HEAD under `tower/look/`, whose code it runs,
and keeps the files it reads its verdict from beside it. A codex Reviewer
alone is granted `tower/look/`, so it can run look, and gets `TOWER_RUN` so
look knows the run dir; look and add-reviewer (through `look.sh --dir`, one
check) refuse a
`tower/look/` that is a symlink, is not yours, or resolves under a checkout
or worktree of the repo, its git dir, the run dir, `/tmp` or `$TMPDIR`.

## The credit guard

With `REVIEWER_BY_CREDITS=on` (off by default), the Reviewer's kind also
follows how much quota each harness has left. Only the Reviewer is steered; a
lane's kind stays as it started (ADR 0013). For each candidate in order, the
kit reads the % left in its tightest window:

- claude: the OAuth token in the macOS keychain item `Claude Code-credentials`,
  then Anthropic's OAuth usage endpoint (the 5-hour and 7-day windows);
- codex: `codex app-server`'s `account/rateLimits/read` (primary and
  secondary windows);
- cursor: the token in the keychain item `cursor-access-token`, then Cursor's
  dashboard service (the month's plan usage).

These endpoints are undocumented or internal, and any CLI update can break
one, so the guard fails open: a probe that errors, times out (about 2 s) or
gets a reply of another shape counts as enough credits. A candidate with less
than `REVIEWER_CREDITS_MIN` % left (default 20) is skipped, and the record
gets a tower note: `reviewer: skipped codex, 12% credits left`. With every
candidate skipped, the lane's own kind reviews. The guard applies to lane
reviews and preflight's Reviewer slots alike. A `REVIEWER_KIND` other than
`other` bypasses it, and with the guard off the kit never reads the keychain. Tokens are never
logged or written to the run dir. bootstrap's `reviewer:` line is a forecast
made without probes; each review probes when it starts.

## Testing the kit

`./test.sh` runs without herdr, claude, codex, cursor-agent, semgrep or
gitleaks, and never reads the keychain or calls the network: stubs under
`skills/orchestrate/tests/stub/` log what would be called, and the credit
probes run against per-section fakes of `security` and `curl`. tower is the
real CLI from this checkout, run with bun, so a change to tower's commands or
to `tower state --json` breaks the kit's tests in the same change.
`DRY_RUN=1 skills/orchestrate/bootstrap.sh …` shows the same for a real repo,
but records a real run in the run dir you give it and points the repo at it:
use a scratch repo and run dir, never a live run's. The kit's tests need
bun, for tower, and npm, for the fixtures' scripts and the package checks;
run `bun install` in the checkout first.
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
change the task list (0008), orchestrate requires tower (0011, which
supersedes 0009), Reviewers report and the orchestrator decides (0010),
model defaults are data and a user contract holds them (0012), and credits
steer the Reviewer through opt-in probes (0013).
