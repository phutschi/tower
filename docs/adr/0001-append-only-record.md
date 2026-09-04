---
status: accepted
---

# The record is an append-only log; state is a pure fold of it

tower's predecessor kept one mutable `status.json` that every executor rewrote
with read-modify-write, and two lanes finishing in the same second lost each
other's report. tower instead appends one line per event to `events.ndjson`
with a single `O_APPEND` write — indivisible on a local filesystem — and
derives all state by folding the log. No lock, no lost writes, a restart loses
nothing, and a finished run is still readable. The cost is that nothing can
ever be edited: a wrong report is corrected by another report, and both stay
visible. That is a feature.

## Consequences

- Network filesystems are unsupported; the atomicity guarantee does not hold on
  NFS.
- Identity (`run.json`) is written once and never folded. Anything that changes
  during a run — including lane assignments — is an event.
