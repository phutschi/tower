---
status: accepted
---

# tower observes; it never acts on the run

tower starts nothing, reads no agent's screen, sends nothing to an agent, and
has no opinion about what should happen next. A "cockpit" with keys to unblock
or re-brief a lane was considered and rejected: it would make tower a runner,
tie it to one harness, and turn a component you leave running for six hours
into one you have to trust. Actions belong to the runner and the orchestrator;
tower keeps the record. The test: tower could be replaced by a piece of paper
without changing what gets built.

## Amended: the Panel carries the user's stage moves

The Panel sets an issue's stage label when the user moves the issue, and does
nothing else to the tracker. That is the user acting, not tower; the
Dispatcher, a script in the plugin, starts the job the stage asks for (ADR
0016).
