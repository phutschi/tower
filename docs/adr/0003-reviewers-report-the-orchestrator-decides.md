# Reviewers report, the orchestrator decides

A Reviewer that finds a problem does not fix it. It writes findings; the
orchestrator re-reads the cited lines, triages each finding (fix, accept,
follow-up, reject), turns fixes into tasks for a lane, and files follow-ups
in the repo's issue tracker. Only the orchestrator pushes and opens the PR;
executors and Reviewers never do. We chose this so the rules stay the same
ones as for lanes (the orchestrator plans, lanes execute, ADR 0001), so no
agent grades its own work, and so everything that leaves the machine goes
through one role and one confirmation from the human. The cost is a round
trip per fix, and a Reviewer that could fix a one-line problem in seconds
has to wait for a lane to do it.
