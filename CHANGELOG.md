# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `tower ids <ids>` prints the ids a spec expands to, one per line, as
  `tower assign` would record them, and refuses an id the run lacks. It
  records nothing. Additive: a minor version.

### Changed

- `add-lane.sh`'s rerun check reads task ids with `tower ids` instead of its
  own parser, so an id tower refuses is refused in tower's words.
- `add-lane.sh` resumes a lane whose pane move failed after the worktree was
  created: the pane is in the pane map as `unplaced lane <X>:`, and a rerun
  moves it instead of creating the worktree again. The install now runs
  before the move.
- `tower wait` no longer needs `--timeout`. Without it, it waits until
  attention, completion or close and exits 0 with the reasons; it exits 3
  only when a timeout was given and passed, and 2 when the run dir disappears
  during a wait without a timeout. Additive: a minor version.
- The orchestrate kit's watches wait without a time limit: `bootstrap.sh`
  prints `tower wait` without `--timeout`, and `watch-lanes.sh` stops after a
  time limit only when `ROUND_SECONDS` sets one (a whole number of seconds;
  anything else is refused).
- `watch-lanes.sh` no longer reads a failing herdr call as the agent gone:
  gone is herdr's `agent_not_found` only. Any other failure is `unreadable`,
  counted as working, and attention (`attention: <agent> unreadable`) only
  after `UNREADABLE_POLLS` polls in a row (default 12, three minutes at the
  default `POLL_SECONDS`).
- `/tower:spec-to-plan` saves plans to
  `$TOWER_PLANS_DIR/<repo>_<branch>/plan.md`, by default under
  `${XDG_STATE_HOME:-$HOME/.local/state}/tower/plans`, instead of one
  user's notes vault.
- The orchestrate kit reports an agent ready only once it accepts input
  (herdr's `interactive_ready`): after a start it waits `START_SETTLE_SECONDS`
  (default 3), then reads the agent about once a second, `READY_WAIT_SECONDS`
  times (default 30). One that exits right after its start is started once
  more; one that never accepts input fails the call and is left running in its
  pane. codex agents start with their startup update check off.
- `add-reviewer.sh` writes the slot's reviewer line before the start, ending in
  ` starting` until the Reviewer accepts input; a rerun after a failed start
  resumes that review under the same agent and task. A codex Reviewer gets
  `<run-dir>/tmp` as `TMPDIR`, `BUN_TMPDIR`, `BUN_INSTALL_CACHE_DIR` and
  `npm_config_cache`.
- `add-lane.sh` writes the lane's line before its agent starts, ending in
  ` starting` until the agent accepts input. A rerun of a starting lane takes
  an agent left running once it accepts input, starts one herdr no longer
  finds again, and otherwise says to answer or end it.
- A codex lane in a worktree may write only `objects`, `refs`, `logs`,
  `packed-refs` and its own `worktrees/<lane>` in the common git dir, no longer
  its hooks or config. Lane A and Reviewers, in the main checkout, keep the
  whole common git dir (docs/orchestrate.md says what that exposes).

## [0.3.0] — 2026-09-07

### Added

- One `tower` plugin (`tower@phutschi-tower`) with four skills:
  `/tower:run`, `/tower:orchestrate`, `/tower:spec-to-plan` and
  `/tower:preflight`. The herdr-orchestrate kit moved into this repo with its
  history; `/tower:orchestrate` is its herdr runner.
- `./install.sh` installs tower when it is missing, from the release binary
  for macOS or Linux, verified against the release's `SHA256SUMS`, and
  migrates from the old `phutschi` plugin and marketplace.
- A git install that needs Node alone, no bun:
  `npm i -g github:phutschi/tower` builds and links a working `tower`.
- The release attaches `SHA256SUMS` for its binaries.
- ADR 0011: orchestrate requires tower.

### Changed

- The board is two sections under the theme's own labels — AIRBORNE and
  ON THE GROUND in airport — so a running flight is never hidden behind a
  pending one on a short pane. Everything landed collapses to one line.
- Every row in a section shares one column layout; a blocked row's note
  starts in the model column instead of shifting the lane and area columns.
- The runway strip wraps into evenly filled rows when the lanes overflow the
  width, with the unit labels aligned in columns.
- `tower theme check` requires the pending label in the preview, since every
  board now prints it.
- `/tower:orchestrate` requires herdr and tower: outside herdr it stops and
  points to `/tower:run`, and without a runnable tower it stops and says how
  to install it.
- tower needs Node 22.12 or later (`engines`).
- The npm package's files list ships the CLI only: no skills, scripts or
  compiled binaries.
- One CI workflow checks the CLI and the kit (shellcheck and its tests,
  against the tower from the same checkout) on Linux and macOS.

### Removed

- The orchestrate kit's no-tower fallback: the tasks, lanes and run files in
  the run dir, the git log console, and the "tower 0.2.0 or later" check.
  tower's board and transcript are a run's only record.

## [0.2.0] — 2026-09-07

### Added

- On-the-fly tasks: `tower add`, `tower change`, `tower remove`, and the
  three event kinds behind them. `tower init` with no plan creates an empty
  run. `state --json` gains `origin` per task and `nextId`. (ADR 0007)

## [0.1.0] — 2026-09-05

tower's first run was its own build.

### Added

- The console: a live Ink board of a run, with the airport vocabulary and
  `--plain`.
- The reporting CLI: `task`, `block`, `note`, refusing malformed reports with
  the correct form.
- `init` from a markdown plan, a TSV, or stdin; `assign`; `close`; `brief`.
- `state --json` and `wait --timeout`, the two commands for scripts.
- Themes as JSON with `theme rules|new|check|preview`.
- The orchestrator skill (`skills/run/SKILL.md`), experimental.

[Unreleased]: https://github.com/phutschi/tower/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/phutschi/tower/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/phutschi/tower/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/phutschi/tower/releases/tag/v0.1.0
