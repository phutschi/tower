---
name: spec-to-plan
description: "Turn a spec into an orchestrate plan: tracer-bullet tasks with blocking edges, lanes and merge points, written as plan.md in the vault. No code."
disable-model-invocation: true
---

# Spec to plan

Produce `plan.md`: the file a later `/phutschi:orchestrate` session hands
to tower. The plan carries **what** each task delivers and **where** it lands;
the executor's tdd loop decides **how**. A plan step that shows test or
implementation code pre-empts that loop and goes stale on first contact,
so the plan holds interface signatures at most, never bodies.

Planning is a separate session from execution. Write the file, report its
path, stop.

## 1. Gather

The spec is the argument (a path or tracker URL) or the one already in the
conversation. Without either, ask for it.

Read the repo: `CONTEXT.md` and `docs/adr/` if present, then the modules the
spec touches, far enough to name real files and existing seams. Use the
domain glossary's vocabulary throughout. `git remote` and the current branch
give the frontmatter's `repo` and `branch`.

## 2. Slice into tracer bullets

Break the spec into **tracer-bullet** tasks and give each its **blocking
edges**:

- A task cuts a narrow but complete path through every layer it touches, so a
  finished task is demoable or verifiable on its own. Vertical, never one
  layer for all tasks.
- A task fits one fresh context window.
- Prefactoring that makes the change easy comes first, as its own task.
- A **wide refactor** (one mechanical change fanning across the codebase)
  runs as **expand–contract**: expand beside the old form, migrate call sites
  in batches sized by blast radius, contract once no caller remains, each
  batch a task blocked by the expand.
- Blocked by: the tasks that must be done before this one can start. A task
  with no blockers can start immediately.

## 3. Group into lanes

Lanes are the orchestrate skill's unit of parallel ownership: a set of
task ids, one executor, one branch. Lane A works on the integration branch; B to D
fork from it. At most four.

- One lane per independent **area** (a package, an app, a subsystem whose
  files no other lane touches). A dependency between lanes is a **merge
  point**, written for both sides, never a reason to share a lane.
- Lane A holds the tasks every other lane depends on, and the last
  integrating tasks.
- A serial spec is one lane. Write `A=all`.

Express the split in bootstrap's syntax: `A=1-4,6 B=5,7-9`.

## 4. Quiz the user

Present the tasks as a numbered list: title, blocked by, what it delivers.
Then the lane split with its merge points. Ask whether the granularity is
right, whether each edge genuinely gates, what to merge or split, and whether
the lanes match how they want to run it. Iterate until the user approves the
list and the split. Nothing is written before that.

## 5. Write plan.md

Follow `plan-template.md` in this folder, section by section. Save to
`$OBSIDIAN_VAULT_PATH/plans/<repo>_<branch>/plan.md` with `/` in the branch
replaced by `-`. Per task:

- **Delivers**: the end-to-end behaviour, from the user's side.
- **Acceptance criteria**: checkboxes, phrased like test names. Each is a
  behaviour observable through the task's seams.
- **Files and seams**: exact paths to create or modify, and the exported
  interface each is tested through. Existing seams over new ones, the
  highest seam that observes the behaviour.
- **Interfaces**: only the signatures another task consumes, so tasks agree
  on names. Types and function signatures, never bodies.
- **Depends on**: task ids, or "none".
- **Decisions**: links to the ADRs and spec sections that bind this task.

Repo conventions every task must follow is the section tower lifts verbatim
into every lane's brief: the rules an executor cannot infer from the code.
The check gate is the repo's own (`.orchestrate`); the plan names it
only if this run needs a different one.

## 6. Self-review, then stop

Check the file against the spec:

- Every spec requirement and user story maps to a task; list any that don't
  and add the task.
- Every task heading is `### Task <id>: <title>`, ids unique, outside code
  fences, in dependency order.
- Interface names match across the tasks that share them.
- The lane string covers every id exactly once; every cross-lane edge has a
  merge point on both sides.
- Fenced code holds signatures only.

Fix inline. Report the path and the lane string. The run is a different
session's job.
