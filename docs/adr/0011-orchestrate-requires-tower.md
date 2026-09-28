---
status: accepted
---

# orchestrate requires tower

ADR 0009 kept a second record for runs without tower: a tasks file and a lane
file in the run dir, and a git log in the console pane. That fallback existed
because the kit was installed on its own, on machines that might not have
tower. The kit now ships inside tower's plugin, so whoever has the kit is one
install away from tower, and the kit and the CLI release together under one
version, so there is no version floor to check. The fallback was not one
branch but a second design: its own brief section, its own console, its own
tests, all kept in step with the first. We deleted it. An orchestrate run's
record is tower's board and transcript, and nothing else. If tower does not
run, `/tower:orchestrate` refuses before it creates anything and says how to
install it. The run dir holds only the pane map and the briefs. This
supersedes ADR 0009.

## Consequences

- The kit's tests run the tower CLI from the same checkout, so a change to
  tower's commands or `state --json` that breaks the kit fails in the same
  PR.
- A machine without tower cannot run orchestrate until tower is installed.
- tower itself does not change: it still observes and never acts (ADR 0003).
  The acting stays in the skill.
