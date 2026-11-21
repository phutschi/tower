---
name: panel
description: "Set up the Panel: a page on your always-on Mac where moving a GitHub issue between stages starts its grill or run on one of your Macs, until its PR is ready for review. Walks you through the hub, the stations, the listed repos and the linked Inbox. Setup only; the Panel itself runs as launchd agents."
disable-model-invocation: true
---

# Setting up the Panel

The Panel is a page served by the hub on the always-on server Mac, reached
over Tailscale. It lists the open issues of the repos you list, at their
stage. Moving an issue sets its stage label; the Dispatcher, a script with no
model in it, starts the job that stage asks for (ADR 0016). Jobs run on your
Macs: each Mac runs a station that claims them from the hub (ADR 0017).
docs/panel.md says what each stage does.

You walk the user through setup, one step at a time, and run what they ask
you to run. Every command runs from a checkout of tower. Say what each step
does before it runs, and check each one before the next.

## What each Mac needs

- **Both Macs:** bun, git, gh logged in (`gh auth status`), Claude Code logged
  in, tower's plugin, tower on PATH, Plannotator, and Tailscale up on the same
  tailnet (`tailscale ip -4` answers).
- **A Mac that takes runs:** the orchestrate kit's needs too
  (`/tower:orchestrate` lists them).

Ask which Mac is the server and which is the MacBook. Check what is missing on
each and stop on the first gap: say what is missing and how to get it.

## 1. The hub, on the server

```
bun skills/panel/cli.ts install hub
```

It writes and loads a launchd agent that starts the hub on the server's
Tailscale address, never on every address, and prints the Panel's URL. Open it
on the phone: it should list nothing yet.

## 2. The listed repos

Ask which repos the Panel covers (`owner/name`). List each one on the Panel,
under Repos. The first poll records every issue's stage and starts nothing, so
issues already in ready-for-agent stay where they are until a move.

## 3. The server's station

```
bun skills/panel/cli.ts install station --hub <the Panel's URL>
```

On the server. Its station is on from the start; set its job limit on the
Panel, under Stations (how many jobs at once keep the Mac usable).

## 4. The MacBook's station

The same command, on the MacBook. A station other than the server's starts
switched off: it takes jobs only while the user switches it on, on the Panel.
Leave it off.

## 5. One Inbox

Jobs on the server ask their questions in the server's Plannotator Inbox. Link
it to the MacBook's, so every question shows in one place: run
`plannotator inbox link` and follow what it prints, on both Macs.

## 6. Check

Move one small issue into shaping on the Panel. A grill job appears under
Jobs, claimed by the server's station, and its first question reaches the
MacBook's Inbox. Move the issue back to needs-triage to stop it.

## Undo

`bun skills/panel/cli.ts uninstall hub` or `uninstall station` unloads that
agent and removes it. The hub's database stays in
`~/.local/state/tower/panel/`.
