---
name: herdr-orchestrate
description: Use when asked to implement a plan or a piece of work with separate executor agents inside herdr ("implement this plan with herdr-orchestrate", "spin up herdr-orchestrate", "orchestrate this", "run this with lanes"). The session becomes the orchestrator: it opens the run, derives or loads the task list, briefs one to four lanes, watches, reviews, merges, runs preflight, opens the PR, closes. Requires HERDR_ENV=1. Not for single-task changes you can make yourself.
---

# Orchestrating a run with herdr-orchestrate

You are the orchestrator. You open the run, own the task list, brief each
lane, watch, have every lane reviewed, merge, run preflight, open the PR,
and close. **You never implement, and you never report on a lane's
behalf.** The kit lives in this directory; every script's header is its
manual. Vocabulary: `CONTEXT.md`. Read
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
   the file). Turn the user's words about the run into switches (see
   "Switches") and set them in bootstrap's environment.
2. **Bootstrap.**
   ```
   <kit>/bootstrap.sh <run-dir> "<title>" <branch> [plan.md | tasks.tsv]
   ```
   With a source, every task goes to lane A unless `LANES="A=1-4 B=5,6"` is
   set. It builds the layout, starts lane A's executor and writes
   `<run-dir>/panes.txt`, the pane map for the whole run. Read it: the
   `check gate:` line is what every lane runs before a commit, `switches:`
   holds the switch values this run uses, `reviewer:` who reviews a lane of
   lane A's kind, with any fallback. Tell the user a fallback. Record the
   run base, lane A's fixed point:
   `tower note "run base: $(git rev-parse HEAD)"` (no tower: a
   `run base:` line in `run.txt`).
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
   In every brief and prompt, describe the final report's marker in words, as
   the template does: `watch-lanes.sh` reads the marker itself as the report,
   so a prompt that spells it makes an idle lane look finished.
6. **Watch, in the background.** Run what bootstrap's `watch:` line prints;
   it carries the run's stale threshold. With tower that is
   `tower wait --timeout 540 --stale <STALE>` for task-level attention and
   `watch-lanes.sh <run-dir> <agent>...` for the processes; without tower,
   `watch-lanes.sh` alone, and idle after the final report is done. Pass
   every lane agent and every live Reviewer agent. Both exit when something
   needs you; re-run them after acting. Never poll `tower state` or the
   panes in a loop.
7. **Act on attention.** `blocked` → decide, then re-brief with what the lane
   asked for (a discovered task: you add it, then tell the lane). `stale` or
   `idle-unexplained` → read the pane tail, then re-brief or wait. tower
   wait's `complete` → leave tower wait off (on a complete board it returns at
   once) and keep `watch-lanes.sh` running: a lane's final review comes after
   its last task, and the watch prints `tower: run complete` once no watched
   agent is working. A lane reporting ready (`ready to merge`, or lane A's
   `ALL DONE` after its last task) → verify its check gate and commits, then
   its lane review (step 8; `LANE_REVIEW=off`: step 9). A Reviewer's
   `FINDINGS WRITTEN` → triage it (see "Triage"), and start the review of a
   lane waiting for a free slot.
8. **Lane review.** Every lane, lane A included. Start it with
   ```
   <kit>/add-reviewer.sh <run-dir> <R1|R2> <lane-kind> "Lane review <X>, round <n>" <run-dir>/findings/lane-<X>-<n>.json
   ```
   `<lane-kind>` is the lane's `kind` in the pane map; the script picks the
   other kind and prints the Reviewer's agent and task id. The first call
   opens the review tab. Add the agent to `watch-lanes.sh`, then brief it
   with the lane review brief (`brief-template.md`). The fixed point is the
   lane's base: the commit it forked from; for lane A the run base (step 2),
   leaving out the commits of the other lanes. Triage the findings alone
   (see "Triage"). Fix tasks → the lane fixes (the prompt asks it to end
   with its final report's marker again, in words) → a new round with a fresh
   Reviewer and the next `<n>`. The review is clean when no finding triaged
   fix is left → step 9.
9. **Merge the lane** into the integration branch, note it
   (`tower note --lane <X> 'merged into <branch>'`), and tell lane A if it
   was waiting. Lane A is the integration branch: its clean review is its
   merge.
10. **Merge `origin/main`.** After the last lane: `git fetch origin`, then
    `git merge origin/main` in lane A's checkout, and run the check gate.
11. **Preflight** (`PREFLIGHT=off`: step 12 with the lane-review findings
    alone). Two Reviewers, one findings dir apart from the lane reviews':
    ```
    <kit>/add-reviewer.sh <run-dir> R1 <kind> "Preflight R1" <run-dir>/findings/preflight/R1.json
    <kit>/add-reviewer.sh <run-dir> R2 <kind> "Preflight R2" <run-dir>/findings/preflight/R2.json
    ```
    `<kind>`: in a single-kind run the lanes' kind, for both; in a mixed run
    `claude` for R1 and `codex` for R2, so one Reviewer of each kind
    reviews. Brief both with the preflight slot brief (`brief-template.md`):
    - R1: `look.sh` (static baseline and full suite), `spec` against the
      whole plan and its spec issue, `between-lanes`. Only R1 runs
      `look.sh`.
    - R2: `security`, `performance`, `error-handling`.

    `REVIEW_AREAS` narrows the areas; split what is left over the two
    slots.
12. **Act.** Load the `preflight` skill and run its act half on
    `<run-dir>/findings/preflight/*.json` plus the deferred lane-review
    findings: those in `<run-dir>/findings/lane-*.json` without an
    `outcome`. One triage table, one reply from the user. Fixes become lane
    A tasks; after them a fresh Reviewer re-reviews (lane review brief, lane
    A, fixed point = HEAD before the fixes, file
    `<run-dir>/findings/preflight/fix-<n>.json`). A new finding there gets a
    new table and a new reply. Then the follow-up issues (tracker in
    `docs/agents/issue-tracker.md`; none: ask in the table), the push, and
    the PR as `PR` says, with the body from the skill's template or
    `PR_TEMPLATE`.
13. **Close.** `tower close "<how it ended>"` (no tower: a line in
    `<run-dir>/run.txt`). Tear nothing down until the user says so; the
    console, the review tab and its panes stay open, the human quits them.

## Switches

The pane map's `switches:` line has the values this run uses. Defaults come
from the repo contract; the user's words override them ("no PR", "skip lane
reviews", "plain, no tdd"): set them in bootstrap's environment.
`add-reviewer.sh` reads them back from the pane map; `look.sh` does not, so
the preflight slot brief passes `STATIC_BASELINE` and `SUITE_SKIP` on its
call.

| Switch | Default | What it changes |
|---|---|---|
| `TASK_REVIEW` | on | off: briefs drop the per-task review tail |
| `LANE_REVIEW` | on | off: a ready lane is merged without step 8 |
| `PREFLIGHT` | on | off: step 11 is skipped; act has only the deferred lane-review findings |
| `STATIC_BASELINE` | on | off: `look.sh` skips semgrep and gitleaks |
| `PR` | draft | ready: a PR ready for review; off: no push, no PR |
| `METHOD` | tdd | plain: briefs drop the tdd sentence |
| `REVIEWER_KIND` | other | claude or codex: that kind reviews every lane |
| `REVIEWER_MODEL` | empty | the Reviewer's model, instead of the kit's pick |
| `REVIEW_AREAS` | empty | preflight's areas, comma-separated; empty: all |
| `SUITE_SKIP` | empty | suite steps `look.sh` skips |
| `PR_TEMPLATE` | empty | the PR body template; empty: preflight's own |

## Triage

You triage lane reviews alone; the user sees findings once, in the
preflight table. Per finding, in its findings file (the fields of
`preflight/findings.md`, "Added in triage"):

- `validity`: re-read the cited lines.
- `scope`: `git blame` them against the lane's base.
- `outcome`: `fix` for a valid in-scope finding: a fix task for the lane
  that wrote the code (`tower add … --lane <X>`, then tell the lane);
  `reject` for a false positive. Leave `outcome` out to defer a finding to
  the preflight table.

A fix loop stops after two rounds: a finding still open after the second
re-review goes to the user, and the lane waits unmerged for the answer.

Two review slots, R1 and R2. A lane that reports ready while both hold a
working Reviewer waits idle; `add-reviewer.sh` refuses a slot whose Reviewer
is still working. The next `FINDINGS WRITTEN` frees a slot.

## Rules

- Do not implement. A stuck lane gets a better brief, not your edit. A merge
  that conflicts is aborted (`git merge --abort`) and becomes a task for
  lane A.
- Only the orchestrator changes the task list (ADR 0001). Lanes never
  `tower add|change|remove`; the brief says so.
- Only the executor reports its own tasks (`tower task|block|note`).
- `tower note` is your voice on the board: merges, escalations, decisions.
- Merging a reviewed lane is your job, right away, not lane A's.
- Executors and Reviewers never push and never open a PR (ADR 0003). You
  push and open the PR after the user's reply to the triage table; until
  then everything stays on this machine.
- Reviewers only report; their findings go through you.
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
| Waiting for lane A to merge lane B | You merge B into the integration branch after its lane review |
| Sleeping and re-reading panes | The two watches in `run_in_background`; act only when one exits |
| Closing panes during teardown | Nothing closes until the user says so; the console never |
| A second run in a repo with an open one | tower refuses; `tower close` the old one first |
| Briefing a codex lane with subagent review instructions | Codex has no subagents; it reviews its own diff with the code-review skill |
| Merging a lane the moment it reports ready | Lane review first (unless `LANE_REVIEW=off`) |
| Asking the user about each lane-review finding | Triage alone; deferred findings wait for the one preflight table |
| Reusing a Reviewer for a second review | `add-reviewer.sh` again: every review gets a fresh agent |
| One findings file for every round of a lane | `lane-<X>-<n>.json`: a new round never overwrites deferred findings |
