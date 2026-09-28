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
