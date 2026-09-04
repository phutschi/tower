---
status: accepted
---

# The current run is found through a pointer file in the repository's common git directory

One global `tower` binary is invoked from several worktrees on several branches,
and more than one repository can have a live run. `tower init` writes the run
directory's path to `<git common dir>/tower-run`; every worktree of a
repository shares that directory, so lane A and lane B resolve to the same run
without being told where it is, and two repositories cannot collide. Writing
into `.git/` is unusual and deliberate: it is the one place all worktrees of a
repository agree on. `--run` and `$TOWER_RUN` override it; `close` clears it;
there is one live run per repository.
