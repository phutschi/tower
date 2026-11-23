---
status: accepted
---

# Nothing in the product or the skill knows a harness or a runner

tower grew out of one specific layout (herdr panes, a particular agent CLI),
but ships with no knowledge of either. The brief is plain text; the skill is
in the open Agent Skills format and never names a harness; `wait` blocks with a
required `--timeout` and prints its reasons so any harness can act on the exit
code, with no background-wake-up assumption. The specific layouts live in
`docs/recipes/` as worked examples. The alternative — a skill that knows how to
run panes in the background of one harness — would have been more convenient
for its first user and useless for everyone else.

## Amended: one opt-in skill is herdr-only

The skill above is `/tower:run`. The orchestrate kit (orchestrate,
spec-to-plan and preflight) has since moved into tower's plugin. The CLI in
`src/` and `/tower:run` stay neutral: they name no harness and no runner, and a
test keeps harness names out of `/tower:run`. `/tower:orchestrate` is the one
exception. It is openly herdr-only, checks for herdr first, and refuses outside
it with a pointer to `/tower:run`. Nothing else depends on it, so a user
without herdr loses nothing. We keep it in the same plugin so there is one
install and one name, and we keep the exception in one skill so the rest
cannot drift toward herdr.

## Amended: orchestrate drives herdr or Orca

`/tower:orchestrate` is no longer herdr-only. It drives Orca the same way it
drives herdr: it starts each agent CLI in a terminal it opens, types the brief
in, reads the terminal back and watches the agent's status. It uses whichever
runner it was started in, and herdr wins when it runs inside an Orca terminal.
tower's board stays the only record of a run (ADR 0011).

We considered rebuilding orchestrate on Orca's own orchestration (its runs,
tasks, workers and mailbox). We rejected it: it is a rewrite, and the run
would get a second record beside tower's. We kept herdr because tower is
public and orchestrate runs there today; the kit tests a fake Orca next to the
fake herdr.

A whole run lives on one machine: the orchestrator, its lanes and the record.
Remote means a paired Orca server, where the human starts the run. A run
spread over several machines would need tower's record to travel over the
network, which is a separate design.

The exception still lives in one skill. The CLI and `/tower:run` still name
no runner.

## Amended: `wait` needs no timeout

`--timeout` is now optional. Without it, `wait` blocks until something needs
a human, which suits a harness that runs commands in the background and wakes
the agent on exit; `--timeout` stays for a harness that can only run commands
in the foreground. Neither mode is assumed: the exit code and the printed
reasons are the same either way.
