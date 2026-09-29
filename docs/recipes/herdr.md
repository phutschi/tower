# Recipe: lanes in herdr

[herdr](https://herdr.dev) runs agent sessions in panes and worktrees. This is
the layout tower grew out of: one orchestrator pane, one executor lane per
pane, and tower where the browser dashboard used to be.

This recipe is the minimal version, done by hand. For the full version of
this layout, run by the orchestrator for you, use `/tower:orchestrate`
([docs/orchestrate.md](../orchestrate.md)).

```sh
cd ~/code/acme
tower init --plan docs/plans/widgets.md --lane A=1-6 --lane B=7-9

# lane A: the main checkout
herdr agent start lane-a --kind claude          # then paste `tower brief A`

# lane B: its own worktree, same run
herdr worktree create feature/widgets-lane-b    # → <repo>/.worktrees/…
herdr agent start lane-b --kind claude          # then paste `tower brief B`

# the console, in a pane of its own
tower
```

The orchestrator (your own chat session) keeps watch with `tower wait`. If
your harness offers a background command that re-invokes you on exit, run
`tower wait` there and read the printed reasons when it wakes you; otherwise
poll it in the foreground with `--timeout` under the harness's limit.

herdr also classifies each pane as working/idle/done/blocked from its screen;
that is process-level signal. tower is task-level signal. You want both.
