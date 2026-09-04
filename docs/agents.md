# Pointing your agents at tower

This page is for people whose agents should report into tower. (Agents
working _on_ tower read [AGENTS.md](../AGENTS.md) instead.)

## Executors need no skill

`tower brief <lane>` prints everything an executor has to know: its tasks, the
three commands, the plan's conventions section, the model roles, and the two
standing rules. Paste it into the agent as its instructions. It is generated
from the run, so it cannot drift from what tower accepts.

```sh
tower brief A > /tmp/brief-A.md
```

The commands it teaches:

```
tower task <id> <status> [phase] [note] --model <model>
tower block <id> "<what you need>"
tower note [--task <id> | --lane <lane>] "<text>"
```

Validation is the teaching mechanism. A wrong status, an unknown id, a missing
`--model`, a `block` without a note — each exits 1 with the correct form on
stderr and appends nothing. Agents fix themselves on the next call.

If an agent runs bare `tower` in a tool call, it gets one text snapshot of the
board and exit 0 — never a hung terminal app.

## The orchestrator

The agent (or person) running the loop uses the [orchestrator
skill](../skills/run/SKILL.md), which is harness-neutral. The loop:

```
tower init --plan <plan> --lane A=… --lane B=…
tower brief <lane>            → paste into each executor
… start executors with your runner …
tower wait --timeout <s>      → 0: read the printed reasons and act; 3: wait again
tower close "<note>"
```

`tower wait` has no default timeout. Pick a number under your harness's tool
call limit. If your harness can run a command in the background and wake you
when it exits, run `wait` there; otherwise run it in the foreground.

## What tower will not do

Start an agent, unblock one, message one, or re-brief one. Those are your
runner's and your judgement. tower keeps the record.
