# orchestrate: tower's runner kit

The `tower` plugin's skills for planning and running a multi-task
implementation inside [herdr](https://herdr.dev) or Orca (a desktop app that
runs coding agents in worktrees, each with its own terminals and chats): one
orchestrating session and one to four executing lanes.
[tower](https://github.com/phutschi/tower) keeps the record: every run has its
board and transcript.

| Skill                 | What it does                                                                                    |
| --------------------- | ----------------------------------------------------------------------------------------------- |
| `/tower:spec-to-plan` | Turns a spec into `plan.md`: tasks, lanes, merge points. Any session.                           |
| `/tower:orchestrate`  | Runs a plan (or a request) with lanes, reviews, merge, preflight and a PR. Needs herdr or Orca. |
| `/tower:preflight`    | Checks a whole branch before its PR. Also on its own, in any session.                           |

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

**3. Run.** In a new session, from a herdr pane or an Orca chat, same repo
and branch:

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

That checks the dependencies (herdr or Orca's CLI, tower, git, bash,
python3, node; claude, codex, cursor-agent, semgrep and gitleaks optional). tower is required and
must run: a missing tower shows up here, not at the start of a run. Orca's
CLI is found as Orca finds it: the value of `ORCA_CLI_COMMAND` when it is set,
else `orca-ide`, else `orca` (on Linux a bare `orca` can be the GNOME screen
reader).

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

From a herdr pane or an Orca chat, in your repo, on the feature branch:

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

## herdr or Orca

orchestrate runs in the runner it was started in, the program that opens its
panes and starts its agents. It decides before it creates anything:

- **herdr** when the orchestrator runs in a herdr pane (`HERDR_ENV=1`) and
  herdr answers, even inside an Orca terminal.
- **Orca** otherwise, when it runs in an Orca chat or terminal
  (`ORCA_CLI_COMMAND` is set) and `"$ORCA_CLI_COMMAND" status --json` says
  its runtime is reachable.

Outside both it refuses, names herdr, Orca and `/tower:run`, and creates no
run. In an Orca whose runtime does not answer, or answers that it is not
reachable, it refuses too, and says Orca is not reachable.

The run is the same in both: the same briefs, the same reviews, the same
record. In Orca the kit drives terminals through Orca's CLI, the command
`ORCA_CLI_COMMAND` names, the way it drives herdr panes: it starts each agent
CLI in a terminal it opens, types the brief in once the agent accepts input,
reads the terminal back and watches the agent's status. Orca's own orchestration (its runs, tasks and mailbox) is not
used: tower's board stays the only record (ADR 0005, ADR 0011).

## The layout

Nothing is closed until you say so.

### On herdr

Up to three tabs in the orchestrator's workspace, each opened without
moving your focus: the orchestrator's own, `lanes`, and `research` (and
`reviews` in the one case under **Lanes** below).

```
the orchestrator's tab             lanes
┌──────────────┬──────────────┐    ┌──────────┬──────────┬──────────┐
│ orchestrator │ console      │    │ lane A   │ lane B   │ R1       │
│              ├───────┬──────┤    ├──────────┼──────────┼──────────┤
│              │ dev   │ shell│    │ lane C   │ lane D   │ R2       │
└──────────────┴───────┴──────┘    └──────────┴──────────┴──────────┘

research (opens with the first such lane)
┌──────────┬──────────┐
│ lane B   │ lane D   │
└──────────┴──────────┘
```

With session roles on (see [Session roles](#session-roles)), a lane whose
tasks name a role other than `code` or `review` (data, research, any other)
goes to the `research` tab, which opens with the first such lane and has a
grid of its own. Lane A too: then the lanes tab opens with the first code
or review lane, or Reviewer. Without roles, every lane is in the lanes tab.

- **Lanes** are the executors. Lane A works in your checkout on the feature
  branch (the integration branch); B to D get worktrees under `.worktrees/`.
  The grid in the lanes tab grows one lane at a time, in the order they are
  added: the second right of the first, the third under the first, the
  fourth under the second. Four at most. When anything reviews
  (`LANE_REVIEW` or `PREFLIGHT` on), the right third of the lanes tab is a
  full-height column for the Reviewer slots, R1 over R2. A lanes tab opened
  with both off has no column, and gets none later: a Reviewer started in
  that run all the same gets a `reviews` tab for the slots, the one case
  with a reviews tab. A lane that needs another lane's work
  merges it at its own merge point; until that work is done it does its
  other tasks, then stops, and the orchestrator prompts it the moment the
  task is done. A _finished_ lane is merged into the integration branch by
  the orchestrator, right away — never by lane A — and, while other lanes
  still have tasks nobody started, the orchestrator moves some to it, so no
  lane sits idle.
- **dev** runs your development server if you declare one, in lane A's
  checkout. **shell** is an empty shell in the same checkout, for you;
  without dev it takes the whole space under the console. There is no
  checks pane: each lane runs the check gate itself, and a `pane checks`
  line in `.orchestrate` is ignored with one `info:` line.
- **console** is tower's live board, the record of the run. It stays open
  after the run; you quit it with `q`. The run dir is no second record: it
  holds the pane map, the briefs, the findings and tower's own run files.
  Console is tower's minimum width, 60
  columns; it takes half the orchestrator's tab so it always gets them.

### On Orca

An Orca chat cannot be split, so each pane gets a tab of its own.

```
the orchestrator's workspace (your checkout)
  tabs:  orchestrator │ lane A │ tower │ dev │ R1 │ R2

  tower tab
  ┌──────────────┐
  │ console      │
  ├──────────────┤
  │ shell        │
  └──────────────┘

lanes B to D: child worktrees of that workspace, each with its lane's terminal
```

- **Lane A** works in your checkout, in a terminal of the orchestrator's
  workspace, so its work lands on the integration branch without a merge, as
  on herdr.
- **Lanes B to D** each get a child worktree of the orchestrator's workspace,
  named for the run and the lane, with their executor in a terminal there.
  Each worktree shows its agent's status in Orca's sidebar.
- **tower** is a tab in the orchestrator's workspace: the console on top and
  an empty shell below, in your checkout.
- **dev**, when the run has one, is a tab of its own, in lane A's checkout.
- **R1 and R2**, the Reviewer slots, are terminal tabs in the orchestrator's
  workspace. A new Reviewer in a busy slot ends the one before it with
  `/exit`, as on herdr. About 2 seconds later the kit closes the old
  Reviewer's terminal, and the new Reviewer starts in a new terminal tab
  named for the slot.

Each tab goes into the pane map as soon as it opens. When R2's tab fails
after R1's opened, the rerun of add-reviewer opens R2 alone. When bootstrap
fails after it opened the console or the shell, the pane map's `opened:` line
and the message name what to close; bootstrap has no rerun.

Watching reads Orca's agent status: working and blocked as on herdr; waiting
and done read as idle. An Orca that does not answer reads as unreadable, and
so does a stale terminal handle: Orca's handles end with its runtime, so the
terminal may still be open under a new one. A lane never settles on a missing
answer, and add-lane, add-reviewer and send-brief ask you to put the
terminal's new handle into the pane map rather than remove anything.

### The pane map

Both runners write the pane map, `panes.txt` in the run dir, with the same
lines and the same `switches:` line. On herdr it holds pane and tab ids. On
Orca, the `orchestrator:` line holds the orchestrator's workspace
(`<repo-id>::<path>`), each pane line an Orca terminal handle, and the
`lanes tab:`, `tower tab:` and `dev tab:` lines the tabs the run opened; lanes
B to D also record their worktree. Its `read a pane:` line is how a lane or
you read a pane back without naming a runner:
`herdr pane read <id> --source recent-unwrapped --lines 60` on herdr,
`"$ORCA_CLI_COMMAND" terminal read --terminal <id> --json` on Orca (every
Orca terminal has `ORCA_CLI_COMMAND`, the CLI the kit runs too). The briefs
tell lanes to read the dev pane with it.

The orchestrator sends each brief and fix prompt with
`send-brief.sh <run-dir> <agent> <file>`. It finds the agent's pane on its
one lane or Reviewer line and, on Orca, checks it against the kit's own
launch record, kept beside the run dir, outside the dirs a sandboxed lane is
granted: an agent the kit never launched is refused, and a recorded handle
gone stale yields to the map's once that terminal is open. It checks that the pane is open, and sends the
file through the runner: `herdr agent prompt` by the agent's name, or
`orca terminal send` with Enter to its terminal. On Orca the brief goes to an
agent listed working or waiting; to one listed done only while the screen
shows the agent, since an agent that exited stays listed done at its shell;
and to one not listed yet once its screen is idle, as the start counts it
ready, unless the screen ends in a shell prompt. Otherwise it holds the brief and says why. It runs nothing from the
pane map, which a lane can write.

## A run on a paired Orca server

A whole run lives on one machine: the orchestrator, its lanes and the record.
To run on another machine, pair it with your Orca as an Orca server (Orca on
that machine, which your Orca opens workspaces on), then:

1. Install tower, the plugin and the agent CLIs your plan needs on that
   server, as under [Install](#install).
2. In your Orca, open the server's workspace for the repo, on the feature
   branch.
3. Start a chat there and run `/tower:orchestrate`, with or without a plan.

The kit and Orca's CLI run on the server and address the server's own Orca, so
nothing names it. Its tower check runs there, and a missing tower stops the
run before it starts. You watch from your Mac's Orca, with no second window
and no SSH session. One run spread over several machines, plain SSH hosts and
handing a running run to another machine are not supported.

## Reviews, preflight and the PR

A run ends in a pull request, a draft by default (the `PR` switch). Before
each task, every lane, of any kind, reads the lean ladder
(`skills/orchestrate/lean.md`, from Ponytail) and writes the smallest
complete change; with `METHOD=tdd` the tdd skill still decides the tests.
Every task is reviewed inside its lane: tdd, then a spec review subagent and a
quality review subagent run in parallel; the quality review follows the lean
review (`skills/orchestrate/lean-review.md`, from Ponytail), and a codex lane
reviews its own diff the same way. The whole branch is reviewed once,
by preflight on the strongest model. In this order:

1. **Lane review**, off by default (`LANE_REVIEW=on` turns it on). When a
   lane reports ready (lane A too, after its last task), a **Reviewer**
   reviews the lane's diff before it is merged. It is
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
   second re-review and comes to you. With `TRIAGE=auto` the open finding is
   deferred to preflight instead, and the lane merges.
2. **The Reviewer slots.** On herdr, R1 and R2 are the lanes tab's right
   column (`add-reviewer.sh`). A run whose lanes tab is not open yet gets it
   from the first review, the column alone. On Orca they are terminal tabs
   (see [On Orca](#on-orca)). Every review starts a new agent in
   a slot and becomes a task on the board owned by that slot. The slots
   stay open after the run.
3. **Merge.** The orchestrator merges each lane as it reports ready (with
   lane review: once reviewed), then `origin/main`.
   A merge that conflicts is aborted and becomes a task for lane A.
4. **Preflight** checks the whole branch: semgrep and gitleaks on the diff,
   the repo's full suite, then agent review by area. R1 runs the checks and
   reviews the spec and problems between lanes; R2 reviews security,
   performance, error handling and structure. Both run on claude's
   `PREFLIGHT_MODEL_CLAUDE` (claude-fable-5-1). claude's credits are always
   probed here: below `REVIEWER_CREDITS_MIN` % another installed kind with
   credits reviews on its Reviewer model (codex, then cursor), and with
   none, claude on `REVIEWER_MODEL_CLAUDE` (claude-opus-5-5). `/tower:preflight` is also a skill of
   its own: run it on any branch, in any session.
5. **One table, one reply.** The orchestrator shows you every finding in
   one table with a suggested outcome: fix, accept, follow-up or reject.
   Fixes go back, in parallel, to the lanes that wrote the code, and the
   next preflight round reviews them; after round 3 an open fix comes to
   you. Your one reply approves the fixes, the follow-up issues (filed where
   `docs/agents/issue-tracker.md` says), the push and the PR. Nothing
   leaves your machine before it.

   With `TRIAGE=auto`, nobody asks you: the orchestrator applies every
   outcome itself, runs the rounds, pushes, opens the PR and files the
   follow-ups (de-duplicated, labelled `preflight`). Only an escalation
   waits for you: a choice, a missing fact, or a fix that would change what
   a contract doc or an ADR decided. The PR lists it under "Open
   decisions", and a fix still open after round 3 under "Unresolved";
   `NOTIFY` tells you the PR and how many decisions are open. Answer in the
   orchestrator's pane; the run stays open until you do, or until you tell
   it to close, which files them as follow-ups. Each round's tally is a tower note,
   and the PR's findings say who decided each one (ADR 0015).

   With `GUIDED_REVIEW=on`, once the PR is open the orchestrator writes a
   guided review of the branch: chapters ordered by importance, each with
   what changed and why, beside its diff. It sends it through its
   session's `submit_guide` tool (the Plannotator Inbox, with the PR on the
   thread). Your comments there come back to the orchestrator and become
   fix tasks, like an answer to the table. A session without the tool
   skips it and says so in a tower note.

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
pane dev    "make dev" web        # pane dev "COMMAND" [DIR]: the one pane a repo declares
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
`REVIEWER_MODEL_CLAUDE_SELF`, `PREFLIGHT_MODEL_CLAUDE`, `SPEC_REVIEWER_MODEL_<KIND>` and
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
  `METHOD`, `REVIEWER_KIND`, `REVIEWER_BY_CREDITS`, `TRIAGE` and
  `GUIDED_REVIEW`;
- `NOTIFY`, a one-line command the kit runs with a message as its one
  argument, e.g. `NOTIFY='~/bin/notify'`. Only the user contract (or the
  environment of a kit call) sets it: it is your setting, not the repo's, so
  `.orchestrate` naming it is noted on stderr and ignored.

Anything else is the repo's (the check gate, install, panes, suite and
toolchain, the unsuffixed `EXECUTOR_MODEL` and friends, `PR`,
`REVIEW_AREAS`, `SUITE_SKIP`, `PR_TEMPLATE`): the user contract names such a
key on stderr and ignores it. A file that fails to load is refused, and a
missing one is silent. The file itself is never pinned, but its run switches,
`REVIEWER_CREDITS_MIN` among them, are fixed at bootstrap: the pane map's
`switches:` line records them, and each review takes them from there, so a
switch you change mid-run does not reach the rest of the run (`STALE`, too, is
read only at bootstrap). Its per-kind model keys and `EXECUTOR_KIND` are read
on every call.

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
| `LANE_REVIEW`          | off            | on: a Reviewer reviews each lane before merging |
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
| `TRIAGE`               | ask            | auto: the orchestrator triages alone            |
| `GUIDED_REVIEW`        | off            | on: a guided review of the PR (below)           |
| `NOTIFY`               | none           | a command, set in the user contract (above)     |

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

### Session roles

With a Claude launcher installed (`CLAUDE_ROUTER_ROLE` is set, or `claude`
takes `--role`), bootstrap opens a run only from an orchestrator session
(`CLAUDE_ROUTER_ROLE=orchestrator`, started with `claude --role orchestrator`)
and refuses any other before it creates anything. Every claude session the
kit starts then gets `--role` and `--topic`:

- a lane: the role its plan tasks name (`**Role:** data` in a task), `code`
  when none does; tasks naming different roles in one lane are refused. Its
  topic is the lane's letter and its first task's title, e.g. `b-shipto-fix`.
- a Reviewer, in a lane review or a preflight slot: `review`, topic `r1` or
  `r2`.

`--model` is passed as before, and must be one the role allows. Codex and
cursor sessions get neither flag. Without the launcher a run is as before;
the pane map's `roles:` line and one tower note say `off` and why.

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
gets a reply of another shape counts as enough credits, with a tower note:
`reviewer: claude credits unreadable, counted as enough`. A candidate with less
than `REVIEWER_CREDITS_MIN` % left (default 20) is skipped, and the record
gets a tower note: `reviewer: skipped codex, 12% credits left`. With every
candidate absent or skipped, the lane's own kind reviews. When the lane's own
kind is not installed either, the first candidate skipped for credits reviews
after all, with the note
`fallback: <lane kind> is not installed, so <candidate> reviews despite its credits`.
Credits steer the choice of Reviewer; they never leave a lane unreviewed for
lack of credits. The guard applies to lane reviews and, with claude not
installed, to preflight's Reviewer slots; with claude installed, preflight
always probes claude's credits (see "Reviews, preflight and the PR"). A `REVIEWER_KIND` other than `other` bypasses it, and with the
guard off the kit never reads the keychain. Tokens are never logged or
written to the run dir. bootstrap's `reviewer:` line is a forecast
made without probes; each review probes when it starts.

## Testing the kit

`./test.sh` runs without herdr, Orca, claude, codex, cursor-agent, semgrep or
gitleaks, and never reads the keychain or calls the network: stubs under
`skills/orchestrate/tests/stub/` log what would be called (a fake herdr and a
fake orca among them), and the credit probes run against per-section fakes of
`security` and `curl` (`CREDITS_FAKES`; under `DRY_RUN=1` without it, no probe runs). tower is the
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
A section shared by both runners runs once per runner: `./test.sh executor`
runs it against the fake herdr, `./test.sh executor:orca` against the fake
orca, and the full run does both (`PER_RUNNER` in `test.sh` lists them).
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

`CONTEXT.md` is the glossary. `docs/adr/` holds the decisions: orchestrate
is the one skill that names a runner, herdr or Orca (0005), lanes never
change the task list (0008), orchestrate requires tower (0011, which
supersedes 0009), Reviewers report and the orchestrator decides (0010),
model defaults are data and a user contract holds them (0012), and credits
steer the Reviewer through opt-in probes (0013).
