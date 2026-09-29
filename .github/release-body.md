## [0.3.0] — 2026-09-07

### Added

- One `tower` plugin (`tower@phutschi-tower`) with four skills: `/tower:run`, `/tower:orchestrate`, `/tower:spec-to-plan` and `/tower:preflight`. The herdr-orchestrate kit moved into this repo with its history; `/tower:orchestrate` is its herdr runner.
- `./install.sh` installs tower when it is missing, from the release binary for macOS or Linux, verified against the release's `SHA256SUMS`, and migrates from the old `phutschi` plugin and marketplace.
- A git install that needs Node alone, no bun: `npm i -g github:phutschi/tower` builds and links a working `tower`.
- The release attaches `SHA256SUMS` for its binaries.
- ADR 0011: orchestrate requires tower.

### Changed

- The board is two sections under the theme's own labels — AIRBORNE and ON THE GROUND in airport — so a running flight is never hidden behind a pending one on a short pane. Everything landed collapses to one line.
- Every row in a section shares one column layout; a blocked row's note starts in the model column instead of shifting the lane and area columns.
- The runway strip wraps into evenly filled rows when the lanes overflow the width, with the unit labels aligned in columns.
- `tower theme check` requires the pending label in the preview, since every board now prints it.
- `/tower:orchestrate` requires herdr and tower: outside herdr it stops and points to `/tower:run`, and without a runnable tower it stops and says how to install it.
- tower needs Node 22.12 or later (`engines`).
- The npm package's files list ships the CLI only: no skills, scripts or compiled binaries.
- One CI workflow checks the CLI and the kit (shellcheck and its tests, against the tower from the same checkout) on Linux and macOS.

### Removed

- The orchestrate kit's no-tower fallback: the tasks, lanes and run files in the run dir, the git log console, and the "tower 0.2.0 or later" check. tower's board and transcript are a run's only record.
