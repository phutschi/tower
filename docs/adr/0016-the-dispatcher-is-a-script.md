---
status: accepted
---

# The Dispatcher is a script; the Panel carries only the user's stage moves

The Panel lets the user move an issue between stages. A move into shaping
starts a grill, and a move into ready-for-agent starts a run. Something has to
see the move and start that job. We gave that to the Dispatcher: a script in
tower's plugin with no model in its loop, like the kit's scripts that already
start herdr panes. The jobs it starts are skills and do all the thinking:
the grill, `/tower:spec-to-plan` with `/tower:orchestrate`, and the order
advice. So the pattern stays the one orchestrate already uses: the acting
lives in the plugin, every job reports into tower's record, and the CLI and
console only watch (ADR 0003).

The Panel writes to the tracker in one case only: when the user moves an
issue, it sets that issue's stage label. That is the user acting through a
form, not tower acting on a run.

## Considered Options

- A Dispatcher skill, like orchestrate: one long-running Claude session in a
  herdr pane that watches the Panel. Rejected: a model in a loop that never
  ends spends tokens on every check, its context fills up over hours, and it
  acts differently from one day to the next. Choosing the next job from a
  stage needs no judgment.
- tower itself acting, replacing ADR 0003. Rejected: the console would stop
  being something you can leave running without trusting it.
- A Panel that only shows, with stages moved in GitHub. Rejected: the user
  moves issues from the phone, and the Panel is where they look.

## Consequences

- A Dispatcher bug can start a job nobody asked for, so it starts jobs only
  from stage changes, never from its own reading of an issue.
- The Dispatcher is new code with its own tests. The kit's tests already run
  the tower CLI from the same checkout (ADR 0011), and the Dispatcher's tests
  do too.
