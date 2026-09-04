---
name: run
description: Run a multi-task implementation plan with agent lanes reporting into tower — init the run, brief each lane, wait for attention, close. Use when asked to orchestrate a plan with tower, or when a plan should be executed by several agents and watched from one console. Experimental in 0.1.0.
---

# Orchestrating a run with tower

You are the orchestrator. You do not implement tasks. You create the run,
brief the executors, watch, and decide. tower keeps the record and draws the
board; your runner (whatever starts agent sessions for you) runs the
executors.

Everything below shells out to `tower`. Never restate its command syntax from
memory — `tower --help` and `tower brief` are the source of truth.

## 1. Create the run

From the repository root, on the branch the work lands on:

```
tower init --plan <plan.md> --lane A=<ids> [--lane B=<ids>] [--model <role>=<model>]...
```

Cut lanes on package or module boundaries with no shared files; put tasks
that depend on each other in the same lane, in order. If you are unsure, one
lane. `tower init` prints the run directory; note it.

If `tower init` refuses because a run is already open, decide whether that run
is truly over (`tower close`) before forcing.

## 2. Brief each lane

```
tower brief A
```

Paste the output into the executor as its instructions, then add — by hand,
above or below it — the judgement only you have: why the lanes are cut this
way, where lane B merges into lane A and at which task, which tasks depend on
another lane's work. Start the executor with your runner. Repeat per lane.

## 3. Wait

```
tower wait --timeout <seconds>
```

Pick a timeout under your harness's limit for a single command. If your
harness can run a command in the background and wake you when it exits, run
`wait` there. Otherwise run it in the foreground.

- **exit 0** — it printed why. Read the lines (`blocked`, `stale`, `complete`,
  `closed`), then `tower state --json` for detail. Act: re-brief a lane, give
  it what it asked for, escalate a model, or tell the human. Then wait again.
- **exit 3** — quiet. Wait again.

Never poll with `tower state` in a loop; that is what `wait` is for.

## 4. Close

When the run is over — merged, shipped, abandoned:

```
tower close "<one line on how it ended>"
```

This frees the repository for the next run.

## Rules

- Do not implement. If a lane is stuck, re-brief it; do not fix the code
  yourself.
- Do not report on a lane's behalf. Only the executor reports its own tasks.
- `tower note "<text>"` is your voice on the board: use it for merges,
  escalations, and decisions, so the transcript reads as a record.
- If an executor runs bare `tower`, it gets a text snapshot; that is fine.
