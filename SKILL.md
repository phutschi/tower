---
name: herdr-orchestrate
description: Use when asked to implement a plan or a piece of work with separate executor agents inside herdr ("implement this plan with herdr-orchestrate", "spin up herdr-orchestrate", "orchestrate this", "run this with lanes"). The session becomes the orchestrator: it opens the run, derives or loads the task list, briefs one to four lanes, watches, merges, closes. Requires HERDR_ENV=1. Not for single-task changes you can make yourself.
---

# Orchestrating a run with herdr-orchestrate

You are the orchestrator. You open the run, own the task list, brief each
lane, watch, merge finished lanes, and close. **You never implement, and you
never report on a lane's behalf.** The kit lives in this directory; every
script's header is its manual. Vocabulary: `CONTEXT.md`. Read
`bootstrap.sh`'s header before the first command.

tower 0.2.0+ (github.com/phutschi/tower) is the record and the console when
installed. Without it the run dir is the record and the console shows the
git log; the scripts say so when it happens.

## Two openings

**With a plan.** The user points to a plan (`.md` with `### Task <id>:`
headings) or a task file (`.tsv`, see `example-tasks.tsv`). The kit takes the
path as given; it never guesses where plans live.

**Without.** The user says "spin up herdr-orchestrate" and nothing else.
Bootstrap with no source, report the pane map, and wait. The user's next
message is the work: derive the task list from it (read the repo; reading is
not implementing), write it to the board, print it, and brief. Ask the user
first only if they asked to be consulted. If the work is one task, say so
and do it in a lane anyway or suggest doing it without the kit.

**The gate:** no lane is briefed before the task list exists on the board.

## The run, in order

1. **Prepare.** From the repo checkout on the feature branch (the
   integration branch). Pick a run dir, e.g. `~/.local/state/tower/runs/<name>`.
   Lanes run on claude unless the repo's `.herdr-orchestrate` says
   `EXECUTOR_KIND=codex` or that is set for a bootstrap or add-lane call
   (`EXECUTOR_MODEL` overrides the model; the call's environment wins over
   the file). The file also carries the reviewer models and `STALE`.
2. **Bootstrap.**
   ```
   <kit>/bootstrap.sh <run-dir> "<title>" <branch> [plan.md | tasks.tsv]
   ```
   With a source, every task goes to lane A unless `LANES="A=1-4 B=5,6"` is
   set. It builds the layout, starts lane A's executor and writes
   `<run-dir>/panes.txt`, the pane map for the whole run. Read it: it also
   carries the check gate every lane runs before a commit, on its
   `check gate:` line.
3. **The task list.** With a source it is loaded. Without: one
   `tower add "<title>" --area <area> --lane <X>` per task (no tower: append
   to `tasks.tsv` and `lanes.txt`). Group by area and dependency: one lane per
   independent area, at most four; a dependency between lanes is a merge
   point, not a reason to share a lane. The user's message may name the lane
   count.
4. **Lanes B to D.** `add-lane.sh <run-dir> B <branch> <base> <ids>` (`<branch>`
   is the lane's own branch, `<base>` the integration branch it forks from);
   the lane gets a worktree under `.worktrees/`, and the pane goes into the
   grid (B right of A, C under A, D under B).
5. **Brief.** Per lane: `tower brief <X> > <run-dir>/brief-<X>.md`, then add
   the judgement from `brief-template.md` above it (method, other lanes,
   merge points, the boundary sentence, the review tail for the lane's kind).
   Send with `herdr agent prompt <agent> "$(cat <run-dir>/brief-<X>.md)"`.
   Without tower, write the derivable part yourself (template, "Without tower").
6. **Watch, in the background.** `tower wait --timeout 540 --stale 30` for
   task-level attention, and `watch-lanes.sh <run-dir> <agent>...` for the
   processes. Both exit when something needs you; re-run them after acting.
   Never poll `tower state` or the panes in a loop. Without tower, watch with
   `watch-lanes.sh` alone; idle after the final report is done.
7. **Act on attention.** `blocked` → decide, then re-brief with what the lane
   asked for (a discovered task: you add it, then tell the lane). `stale` or
   `idle-unexplained` → read the pane tail, then re-brief or wait. A lane
   B–D reporting `idle-after-final-report`, `done`, or a `tower note … ready
   to merge` → verify its check gate and commits, merge its branch into the
   integration branch yourself, note it
   (`tower note --lane <X> 'merged into <branch>'`), tell lane A if it was
   waiting. On lane A → verify the check gate and the commits; the run is done.
8. **Close.** `tower close "<how it ended>"` (no tower: a line in
   `<run-dir>/run.txt`). Tear nothing down until the user says so; the
   console stays open in any case, the human quits it with `q`.

## Rules

- Do not implement. A stuck lane gets a better brief, not your edit.
- Only the orchestrator changes the task list (ADR 0001). Lanes never
  `tower add|change|remove`; the brief says so.
- Only the executor reports its own tasks (`tower task|block|note`).
- `tower note` is your voice on the board: merges, escalations, decisions.
- Merging a finished lane is your job, right away, not lane A's.
- Executors never push and never open a PR. The brief says so; keep it.
- The brief's review tail matches the lane's kind (panes.txt): review
  subagents for claude, self-review with the code-review skill for codex.
- Never close a pane you did not create; never close the console pane;
  close nothing until the user says so.

## Common mistakes

| Mistake | Instead |
|---|---|
| Hand-rolling `herdr pane split` and `herdr agent start` | Run `bootstrap.sh`; the layout and pane map are its job |
| Briefing before the task list exists | Load or derive it first; the board is the plan |
| Drip-feeding one task per prompt | One brief per lane with all its tasks; "do not stop between tasks" is in the template |
| Briefing with the plan alone | Brief = template judgement + derived part; method, other lanes, merge points, reporting |
| Letting a lane `tower add` | The boundary sentence stays in every brief; a discovered task goes through you |
| Waiting for lane A to merge lane B | You merge B into the integration branch when B reports ready |
| Sleeping and re-reading panes | The two watches in `run_in_background`; act only when one exits |
| Closing panes during teardown | Nothing closes until the user says so; the console never |
| A second run in a repo with an open one | tower refuses; `tower close` the old one first |
| Briefing a codex lane with subagent review instructions | Codex has no subagents; it reviews its own diff with the code-review skill |
