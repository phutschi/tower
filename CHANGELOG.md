# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.3.0] — 2026-09-07

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
