# Lanes never change the task list

tower 0.2.0 lets anyone run `tower add`, `change` and `remove`, and its own
brief tells an executor to add a task it discovers. In herdr-orchestrate only
the orchestrator changes the task list: a lane that discovers a task reports
it with `tower block` or `tower note` and waits. We chose this so the
boundary is one sentence (the orchestrator plans, lanes execute), so parallel
lanes never invent overlapping work, and so the board always reflects a
decision the orchestrator made. The cost is a round trip through the
orchestrator for every discovered task; the brief overrides tower's paragraph
explicitly so executors do not follow it.
