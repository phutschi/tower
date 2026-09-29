# Area: error-handling

Every point in the changed code that can fail, and what happens when it
does. Read adversarially: assume each call fails at the worst moment.

For each failure point (a call, a parse, a file or network step, a
subprocess, an assumption about input):

1. What can fail?
2. What does the code do then? It stops with a clear message, it recovers
   on purpose, it carries on silently, or it crashes.
3. Is that right for the caller?

Look hard for:

- Errors swallowed: an empty catch, `|| true`, an ignored exit code, a
  default that hides a failure.
- Partial work: a write, commit or state change left half done when a
  later step fails; no cleanup or rollback.
- Exit codes and messages: a failure that exits 0, or a message that does
  not say what to do.
- Retries that repeat a side effect, or loop forever.

Severity: silent wrong result or lost data: `must-fix`. A confusing
failure the user can recover from: `should-fix`. Handled, but only while
one assumption holds: `watchpoint`.
