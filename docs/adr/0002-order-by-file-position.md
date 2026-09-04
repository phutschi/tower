---
status: accepted
---

# Events are ordered by their position in the record, never by timestamp

Executors in different worktrees write timestamps from different shells, and a
clock skew of a second would reorder a `done` before its `in_progress`. The
fold therefore reads the record top to bottom and treats `ts` as display only.
Anyone tempted to sort by timestamp is undoing a deliberate choice.
