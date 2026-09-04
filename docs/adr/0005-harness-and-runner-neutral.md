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
