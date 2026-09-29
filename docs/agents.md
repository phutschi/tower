# Pointing your agents at tower

This page is for people whose agents should report into tower. (Agents
working _on_ tower read [AGENTS.md](../AGENTS.md) instead.)

## Executors need no skill

`tower brief <lane>` prints everything an executor has to know: its tasks, the
reporting commands, the plan's conventions section, the model roles, and the
standing rules (never push, never open a pull request, commit after every
task). Paste it into the agent as its instructions. It is generated from the
run, so it cannot drift from what tower accepts.

```sh
tower brief A > /tmp/brief-A.md
```

The commands it teaches:

```
tower task <id> <status> [phase] [note] --model <model>
tower block <id> "<what you need>"
tower note [--task <id> | --lane <lane>] "<text>"
tower add "<title>" --lane <yours>
```

Validation is the teaching mechanism. A wrong status, an unknown id, a missing
`--model`, a `block` without a note — each exits 1 with the correct form on
stderr and appends nothing. Agents fix themselves on the next call.

An executor that discovers a task the plan does not have adds it before
starting it — `tower add "<title>" --lane <yours>` prints the new id, and the
executor reports against that. `tower change` and `tower remove` (anyone,
any time) edit and retire tasks the same way; the console picks them up
without a restart. In a `/tower:orchestrate` run the executor's brief
overrides this: only the orchestrator changes the tasks, and the executor
reports what it found with `tower note` or `tower block` and waits
([ADR 0008](adr/0008-lanes-never-change-the-task-list.md)).

If an agent runs bare `tower` in a tool call, it gets one text snapshot of the
board and exit 0 — never a hung terminal app.

## The orchestrator

The agent (or person) running the loop uses the [orchestrator
skill](../skills/run/SKILL.md), `/tower:run`, which is harness-neutral. Inside
herdr, `/tower:orchestrate` runs the whole loop instead, from the layout to
the pull request ([docs/orchestrate.md](orchestrate.md)). The loop:

```
tower init --plan <plan> --lane A=… --lane B=…
tower brief <lane>            → paste into each executor
… start executors with your runner …
tower wait                    → 0: read the printed reasons, act, wait again
tower close "<note>"
```

Run `tower wait` in the background if your harness can run a command there
and wake you when it exits: without `--timeout` it waits as long as it takes.
`--timeout <s>` is for a harness that can only run commands in the
foreground: pick a number under its tool call limit, and on exit 3 (the
timeout passed quietly) wait again.

## What tower will not do

Start an agent, unblock one, message one, or re-brief one. Those are your
runner's and your judgement. tower keeps the record.
