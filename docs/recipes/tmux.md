# Recipe: lanes in tmux

One window, one pane per lane, tower in the last pane.

```sh
cd ~/code/acme
tower init --plan docs/plans/widgets.md --lane A=1-6 --lane B=7-9

tmux new-session -d -s widgets -c "$PWD"
tmux send-keys -t widgets 'tower' C-m
tmux split-window -h -t widgets -c "$PWD"
tmux send-keys -t widgets '<start your lane A agent here>' C-m
tmux split-window -v -t widgets -c "$PWD/.worktrees/lane-b"
tmux send-keys -t widgets '<start your lane B agent here>' C-m
tmux attach -t widgets
```

Give each agent its letter: `tower brief A`, `tower brief B`. Lane B works in a
git worktree of the same repository, so `tower` inside it finds the same run
through the common git directory.

From your own shell, or a script:

```sh
while tower wait --timeout 540; do
  tower state --json | jq '.tasks[] | select(.status == "blocked" or .stale)'
  # read, decide, re-brief, continue
done
```

`wait` returns 3 on a quiet timeout, which ends the `while`; wrap it in an
outer loop if you want to keep watching.
