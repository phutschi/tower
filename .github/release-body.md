## [0.5.0] — 2026-10-07

### Added

- A Cursor plugin manifest and marketplace (`.cursor-plugin/`) ship beside the claude one: in Cursor, add the marketplace from GitHub and enable **tower**.

### Changed

- Lane review is off by default (`LANE_REVIEW=off`). The orchestrator merges a lane as soon as it reports ready; the per-task reviews and preflight cover what the lane review did. `LANE_REVIEW=on` brings it back.
- The orchestrator keeps lanes busy: a merged lane takes over tasks nobody started from the busiest lane (`tower assign`, a more-work prompt).
- A lane at a merge point no longer polls every 3 minutes: it does its other tasks, notes what it waits for and stops, and the orchestrator prompts it once the task it needs is done.
- A lane's two per-task review subagents run in parallel.
- Preflight's Reviewers run on claude-fable-5-1 (`PREFLIGHT_MODEL_CLAUDE`, `add-reviewer.sh` `REVIEW_STAGE=preflight`). Below `REVIEWER_CREDITS_MIN` % claude credits, codex or cursor review on their Reviewer models, and with neither, claude on claude-opus-5-5.
- Preflight's fixes go back, in parallel, to the lanes that wrote the code, not all to lane A.
