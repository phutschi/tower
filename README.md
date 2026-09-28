# herdr-orchestrate

Run a multi-task implementation inside [herdr](https://herdr.dev) with one
orchestrating session and one to four executing lanes, and read the record
afterwards in [tower](https://github.com/phutschi/tower).

You talk to the orchestrator. It opens the run, owns the task list, briefs
the lanes, watches, merges what finishes, and closes. It never writes code.
Lanes execute their brief and report their own tasks. Nothing else.

## Install

```
git clone <this repo> ~/tools/herdr-orchestrate
~/tools/herdr-orchestrate/install.sh
```

That checks the dependencies (herdr, git, bash, python3, node; tower 0.2.0+
and codex optional) and links the kit into `~/.claude/skills` and
`~/.agents/skills` as the `herdr-orchestrate` skill. `install.sh --check`
only checks.

## Two openings

From a herdr pane, in your repo, on the feature branch:

- **With a plan.** "Implement `<path>` with herdr-orchestrate." The path is a
  markdown plan with `### Task <id>: <title>` headings, or a TSV
  (`id<TAB>title<TAB>area`, see `example-tasks.tsv`). Keep plans wherever
  you like; the kit only takes the path.
- **Without.** "Spin up herdr-orchestrate." The layout comes up, the
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
  merge point; a *finished* lane is merged into the integration branch by
  the orchestrator, right away — never by lane A.
- **checks** runs your test runner in watch mode, **dev** your development
  server if you declare one. Both run in lane A's checkout.
- **console** is tower's live board, the record of the run. It stays open
  after the run; you quit it with `q`. Without tower it shows the git log,
  and the run dir holds the record. Console is tower's minimum width, 60
  columns; the bottom row always spans the full tab so it always gets them.

Nothing is closed until you say so.

## Telling the kit about your repo

JS repos need nothing: the package manager, the typecheck script and the
test runner are detected from lockfiles and `package.json`. Anything else,
or any repo whose real entrypoint is its own tool, writes a
`.herdr-orchestrate` file in the root (see `example.herdr-orchestrate`):

```bash
CHECK_CMD="make check"            # the check gate every lane runs before a commit
pane checks "make test-watch"     # pane NAME "COMMAND" [DIR]; NAME is checks or dev
pane dev    "make dev" web
EXECUTOR_KIND=codex               # the lanes' harness: claude (default) or codex
EXECUTOR_MODEL=gpt-6-astra        # the lanes' model
SPEC_REVIEWER_MODEL=sonnet        # the reviewer models tower records
QUALITY_REVIEWER_MODEL=opus
STALE=30                          # minutes before the console flags a lane as stale
```

The same names in the environment of a bootstrap or add-lane call win over
the file for that call. A name the kit does not read is pointed out on stderr.

## Executor kinds

Lanes run Claude Code by default (`claude-opus-5-5[1m]`). A repo can switch
its runs to codex in `.herdr-orchestrate` (`EXECUTOR_KIND=codex`, model
`gpt-6-astra`; `EXECUTOR_MODEL` overrides either), and a single lane can
differ: `EXECUTOR_KIND=codex` in that bootstrap or add-lane call. Mixed runs
are fine.

## Without tower

Everything works; you lose the board, `tower wait`, and `tower brief`. The
run dir carries `tasks.tsv`, `lanes.txt` and `run.txt`, lanes report
through commits and their pane, and the console shows the git log.

## Testing the kit

`./test.sh` runs without herdr or tower: stubs under `tests/stub/` log what
would be called. `DRY_RUN=1 ./bootstrap.sh …` from any directory shows the
same for a real repo. `shellcheck -S warning *.sh tests/stub/*` lints
(`.shellcheckrc` holds the deliberate exceptions). CI runs both on Linux and
macOS.

## Design

`CONTEXT.md` is the glossary. `docs/adr/` holds the decisions: lanes never
change the task list, tower is the record.
