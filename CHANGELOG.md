# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/phutschi/tower/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/phutschi/tower/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/phutschi/tower/releases/tag/v0.1.0
