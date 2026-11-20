---
status: accepted
---

# Jobs run on the user's own Macs, through a hub we wrote, in worktrees

The Panel's jobs (grills, runs, order advice, labelling) run on the user's
Macs, never in the cloud. The always-on server Mac is the hub: it serves the
Panel and holds the job queue. Every Mac, the server included, runs a station
that claims jobs over Tailscale with a lease it renews while the job runs,
and sends the job's events back. While a Mac is offline its jobs wait in the
queue. The server takes jobs by default; the MacBook only while the user
switches it on. Each Mac takes as many jobs at once as the user set for it.

The queue is ours: a job table on the hub with the claim-with-lease pattern
holli's Runner already uses. A run works in a git worktree on its Mac, as
orchestrate runs do today, with its own test database and ports. The station
keeps "where a run executes" behind one seam so a container can replace the
worktree later.

## Considered Options

- GitHub Actions self-hosted runners as queue and station. Rejected: a queued
  job is cancelled after 24 hours, a label set with the built-in token
  starts no workflow, every listed repo would need a workflow file, and the
  Panel would still pull run events from a second place.
- Hatchet or another job platform. Rejected: a whole platform to host for two
  Macs.
- No hub, with a station on every Mac claiming issues through GitHub labels.
  Rejected: the Panel could not see live runs on other Macs, and two Macs
  could race for one issue.
- An apple/container Linux VM per run. Deferred: herdr, Xcode builds and
  Claude Code's login, skills and plugins do not work there today. A Tart
  macOS VM per run is capped at two per Mac by the macOS licence.

## Consequences

- The server Mac must stay up for anything to be dispatched; a station
  finishes its current job without it and reports when the hub is back.
- Runs on one Mac share it, so per-run databases and ports are the station's
  job, and the per-Mac job limit is what keeps a Mac usable.
- The Panel is reached only on the tailnet, so the hub learns of label
  changes and merges by checking GitHub on a timer, not from webhooks.
