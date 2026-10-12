---
status: accepted
---

# Lanes write lean, preflight reviews structure

Runs produced more code than their tasks needed, and every extra line slowed
the reviews after it. So bloat is stopped where code is written: each lane
reads the kit's `lean.md` (Ponytail's ladder: does it need to exist, is it
already here, the standard library, an installed dependency, one line, then
the minimum), and its quality reviewer, per task, reviews with
`lean-review.md` (ponytail-review). The tdd skill still decides the tests.
Lane A's final whole-implementation review is gone: preflight sees more. The
whole branch then gets a `structure` review area (Thermo-nuclear) in
preflight, where duplication and spaghetti between lanes first show; a
structure fix that reaches past the branch's files defaults to follow-up, so
the end of a run does not turn into a refactor. All three are copied
verbatim, under their MIT notices, as kit files rather than skills or
plugin dependencies: codex and cursor lanes cannot load claude plugins, and
a `/tower:ponytail` skill would clash with the plugin itself. The phase stays
`quality-review`, so the event line does not change.

A shortcut an executor chooses to keep is marked with a `shortcut:` comment
naming its limit and the trigger to revisit it. It is a decision, not a
finding. The per-task review flags one with no trigger, where adding the
clause costs seconds; preflight only reports it as a `watchpoint` and lists
every shortcut the branch added in the PR body, because a `fix` there costs a
whole preflight round. Shortcuts never become follow-up issues: the comment
is the record, and a grep lists them all.
