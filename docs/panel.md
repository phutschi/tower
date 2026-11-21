# The Panel

The Panel is a page on your always-on Mac where you move GitHub issues between
stages, from a phone or any device on your tailnet. A move starts the job that
stage asks for, on one of your Macs, until the issue's PR is ready for review.
`/tower:panel` sets it up. The words below are the glossary's
([CONTEXT.md](../CONTEXT.md), The Panel).

## The parts

- **Hub:** the server Mac's part. It serves the Panel and an HTTP API on its
  Tailscale address only, with no login, holds the job queue and keeps every
  job's events. It checks GitHub through `gh` on a timer, since a page on the
  tailnet gets no webhooks.
- **Dispatcher:** part of the hub, a script with no model in it
  ([ADR 0016](adr/0016-the-dispatcher-is-a-script.md)). It compares each
  issue's stage label with the one it last saw and queues the job the new
  stage asks for. Its first poll of a repo only records.
- **Station:** a process on each Mac, the server included. It claims jobs
  from the hub with a lease it renews while the job runs, works each in a
  checkout of its own with its own test database name and ports, and posts
  the job's events and result
  ([ADR 0017](adr/0017-jobs-run-on-the-users-macs-through-a-hub.md)). The
  server's station takes jobs from the start; any other only while you switch
  it on. Each Mac takes as many jobs at once as you set.

## Stages and jobs

An issue's stage is its label: needs-triage, shaping, ready-for-agent,
in-progress, in-review. Closed is GitHub's closed state. A move on the Panel
sets the label and changes nothing else on GitHub; a label you change on
github.com counts the same.

| Move                              | Job                                                                                                                                         |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| into shaping                      | a grill: a headless session asks you its questions in the Plannotator Inbox, writes the spec into the issue and moves it to ready-for-agent |
| into ready-for-agent              | a run: in a workspace of its own, `/tower:spec-to-plan` then `/tower:orchestrate` with `TRIAGE=auto`, until the PR is ready for review      |
| a new issue                       | labelling its issue area, from the repo's `CONTEXT-MAP.md`                                                                                  |
| a merge to main                   | an order advice: an order to build in and bundles, for you to accept or reject in parts                                                     |
| back, or closed, while a job runs | the job stops; its checkout stays a day                                                                                                     |

The hub sets in-progress when a station claims a run, and in-review once a
ready PR opened for the run closes its issues.

- **Held runs:** a run waits while one of its issues waits on an open issue
  (GitHub's issue dependencies), and shows what it waits on.
- **Bundles:** a bundle is issues you accepted from an order advice to build
  in one run and one PR. It starts once every open issue in it is in
  ready-for-agent; stopping one of its issues stops the run and sends the
  others back to ready-for-agent.
- **Stuck runs:** a run that fails, or whose station stops reporting, is
  marked stuck, gets one Inbox message, and is never tried again: move its
  issues back to ready-for-agent to start a new one.
- **Usage limits:** when Claude refuses a job at a usage limit, the
  Dispatcher starts nothing new until the reset, and says so once in the
  Inbox. The Panel shows each job's duration and tokens, and your limits.

## Setup

`/tower:panel` walks you through it. In short, from a checkout of tower:

```
bun skills/panel/cli.ts install hub                       # on the server
bun skills/panel/cli.ts install station --hub <Panel URL>  # on each Mac
```

Each writes and loads a launchd agent; `uninstall hub|station` removes it. The
agents run that checkout's `skills/panel/cli.ts` by path: install from a
checkout that stays put, not a worktree or the plugin's cache. Then list your
repos on the Panel, and link the server's Plannotator Inbox with the
MacBook's (`plannotator inbox link`). The hub and the stations run on Bun.
