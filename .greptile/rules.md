# Reviewing tower

tower is a control tower for long agent implementation runs. Two halves:

- `src/` is the CLI, in TypeScript, built for Node ≥ 22.12. It keeps the record of a run (`events.ndjson`, `run.json`) and shows it. It observes and never acts (ADR 0003), and it names no harness or runner (ADR 0005).
- `skills/` is the plugin: agent skills in markdown with bash scripts. `run` is the neutral orchestrator skill. `orchestrate`, `spec-to-plan` and `preflight` are the orchestrate kit, and `orchestrate` is the one herdr-only skill.

Vocabulary is in `CONTEXT.md`: use its terms (Run, Lane, Orchestrator, Executor, Reviewer, Record, Event, Brief, Finding, Preflight). A new term in a PR belongs in the glossary.

## Trust boundaries

What is trusted, so not a finding by itself:

- Sourcing the repo contract (`.orchestrate`) and the user contract (`~/.config/tower/orchestrate`), and running their command fields (CHECK_CMD, INSTALL_CMD, `pane`, `suite`, NOTIFY), with `eval` where the kit does. Both are shell files their owner writes, the same trust as a Makefile. Flag new code that runs values from anywhere else.
- Writing the run pointer into the git common dir (`<git common dir>/tower-run`, ADR 0006). It is the one place every worktree agrees on.
- The kit driving local agent CLIs and herdr. That is its job; the CLI in `src/` never does it.

What is untrusted and must stay data: plan and task text, branch names, PR and issue titles and bodies, Reviewer findings JSON, anything read back from GitHub, and file contents of the repo under review. The orchestrator pastes some of these into prompts and commands, so quoting, `jq --arg` and argument passing matter.

Anything that leaves the machine (push, PR, issue, notification) goes through the orchestrator only (ADR 0010). A Reviewer or executor that pushes, opens a PR or files an issue is a bug.

## Do not flag

- Style, formatting, import order, naming taste: prettier, eslint, tsc and shellcheck run in CI.
- `test.sh` being long. It is the kit's single test file by design.
- The verbatim upstream copies `skills/orchestrate/lean.md`, `lean-review.md` and `skills/preflight/areas/structure.md`: editing them breaks the copy.
- Double spaces and exact wording in `skills/orchestrate/brief-template.md` and the templates: `test.sh` slices them.
- Missing support for network filesystems: the record's atomicity needs a local one (ADR 0001).
- A wrong report not being editable: a later report corrects it, by design (ADR 0001).

## What a good finding looks like

Cite the lines, give the input that breaks them and what goes wrong, and name the ADR or doc the expectation comes from. A change that adds more code than the task needs is worth a comment (ADR 0014): something the standard library, an installed dependency or an existing helper in `src/` or `skills/orchestrate/common.sh` already does.
