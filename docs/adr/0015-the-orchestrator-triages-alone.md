---
status: accepted
---

# The orchestrator triages alone, the PR is the human's gate

With `TRIAGE=auto`, the orchestrator, or preflight run alone, applies every
suggested outcome of the triage table without asking, every round. It fixes,
loops the rounds, pushes, opens the PR as `PR` says (a draft by default) and
files follow-ups. Only three kinds of finding escalate to the human: a choice
(two valid answers, or the spec is silent), a missing fact (no tracker file,
an unknown owner, a credential), and a fix that would change something a
contract doc (a public API, a protocol, a schema) or an ADR decided. A
finding still triaged `fix` after preflight round 3 is listed as unresolved
and counts as an escalation too. An escalation blocks only itself: it becomes
an open decision, listed in the PR (in the session with `PR=off`), and the
run stays open for its answer. The PR is where the human reads what was
decided, and by which rule. This supersedes, under `TRIAGE=auto`, ADR 0010's
"one confirmation from the human"; the rest of ADR 0010 holds. `TRIAGE=ask`,
the default, keeps that confirmation.

We chose this because the human was the bottleneck at one place. Across 25
recorded runs, lanes were blocked on the human for 0.1 h in total, while
every preflight round waited 39 to 294 minutes for the human's one reply,
two or three rounds per run, and the run notes show that reply was almost
always "go" or "approved as suggested". The table already suggests the
outcome; the human only confirmed it. The cost is that an escalation can be
missed until the PR is read, and a fix the human would have stopped is
already pushed. `NOTIFY` shortens the first; a draft PR, and its "Decided by"
column, keep the second reversible.
