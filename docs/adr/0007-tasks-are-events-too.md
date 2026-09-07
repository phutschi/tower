---
status: accepted
---

# Tasks are not fixed at init; add, change and remove are events

0.1.0 took its tasks once, at `init`, and the fold refused to know any other.
That blocked an executor started from a prompt with no plan, and a lane that
found a task the plan missed. Since `run.json` is written once (ADR 0001),
anything that changes during a run is an event: `add`, `change` and `remove`
join `report`, `note`, `assign` and `close`. `run.json.tasks` remains the
plan's word and may be empty; the record's adds, changes and removes are the
run's. The fold still never invents a task from a report — only an `add`
creates one — and a removed task keeps its history, so a re-add restores it.

## Consequences

- `state --json` gains `origin` per task and `nextId`; event `v` stays 1.
- A reader that switches on `kind` must ignore kinds it does not know.
- Two lanes adding in the same instant can pick the same id; the second add
  folds as a change to the first. Visible, never lost. There is no lock.
