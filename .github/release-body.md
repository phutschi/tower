## [0.2.0] — 2026-09-07

### Added

- On-the-fly tasks: `tower add`, `tower change`, `tower remove`, and the
  three event kinds behind them. `tower init` with no plan creates an empty
  run. `state --json` gains `origin` per task and `nextId`. (ADR 0007)
