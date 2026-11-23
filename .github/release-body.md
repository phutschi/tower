## [0.6.0] — 2026-11-23

### Added

- `/tower:orchestrate` runs in Orca as well as herdr. Started from an Orca chat, it opens terminals through Orca's CLI (`ORCA_CLI_COMMAND`; install.sh looks for it there, else as `orca-ide`, else `orca`): lane A in your checkout, lanes B to D as child worktrees of the orchestrator's workspace, a `tower` tab with the console over a shell, the dev pane and each Reviewer in a tab of their own. herdr wins when both are present, and outside both it still points to `/tower:run`. The orchestrator sends every brief with the new `send-brief.sh`, which runs nothing from the pane map. herdr runs are unchanged.
- Session roles for a Claude launcher: with `CLAUDE_ROUTER_ROLE` set or a `claude` that takes `--role`, `/tower:orchestrate` runs only in an orchestrator session, and every claude session it starts gets `--role` and `--topic`. Without the launcher a run is unchanged.
- `TRIAGE=auto` (default `ask`): preflight triages every finding itself, runs its rounds, pushes, opens the PR and files follow-ups with no reply; only a choice, a missing fact or a fix against a contract doc or an ADR escalates.
- `GUIDED_REVIEW=on` (default `off`): once a run's PR is open, the orchestrator sends one guided review of the branch to the Plannotator Inbox; a comment there becomes a fix for the lane that wrote the line.
- `NOTIFY`: a one-line command, run once at preflight's end with the PR link and the number of open decisions.
- A Reviewer marks a choice with a finding's `decision` options; triage writes `decided_by`, and the PR's findings tables show it.

### Changed

- An orchestrate run opens no checks pane: each lane runs the check gate itself, and an empty shell pane for the human takes its place.
- An orchestrate run opens a second tab, `lanes`: lane A starts there, lanes B–D join its grid, and R1 and R2 take a full-height column on its right.
- With session roles, a lane whose tasks name a role other than `code` or `review` goes to a third tab, `research`.
