# The brief — the handwritten part

One brief per lane, one message, all of its tasks. `tower brief <lane>` prints
everything derivable: the lane's tasks, the three reporting commands, the
plan's conventions section, the model roles, and the two standing rules
(never push, never open a PR). Start from that:

    tower brief A > <run-dir>/brief-A.md

Then add, above it, only what tower cannot know, and send the whole file:

    herdr agent prompt <agent> "$(cat <run-dir>/brief-A.md)"

The agent names and pane ids are in `<run-dir>/panes.txt`.

## The boundary (ADR 0001)

tower's own brief tells an executor to `tower add` a task it discovers. In a
herdr-orchestrate run it must not: only the orchestrator changes the task
list. The template below says so in one sentence; keep it in every brief,
for every kind.

## Without tower

If tower is not installed (bootstrap said so), write the derivable part by
hand below the separator: the lane's task ids and the tasks file from
`<run-dir>/run.txt` and `lanes.txt`, the model roles from `run.txt`, and the
two standing rules. Then substitute the reporting:

| with tower                                   | without                                                     |
|----------------------------------------------|--------------------------------------------------------------|
| `tower task <id> start\|done`                 | one commit per task, subject starting with the task id       |
| `tower block <id> "<need>"`                  | stop, and state exactly what you need as your reply         |
| `tower note --lane X '<text>'`               | say it as your reply; the orchestrator reads the pane       |
| `tower state --json` (another lane's progress) | `git log <branch> --oneline`                              |

The orchestrator then watches with watch-lanes.sh alone; "idle after the
final report" is done.

## Executor kind

panes.txt says which agent runs the lane (`kind claude` or `kind codex`). The
brief is the same for both except the review tail of METHOD and of WHEN YOUR
LAST TASK IS DONE. Both kinds load the same tdd skill (claude from the
mattpocock plugin, codex from ~/.codex/skills/tdd); "load the tdd skill" is
the sentence that works for both.

|                     | claude lane                                                     | codex lane                                                        |
|---------------------|-----------------------------------------------------------------|-------------------------------------------------------------------|
| per-task review     | spec-compliance review subagent (model sonnet) + code-quality review subagent (model opus); pass the model explicitly | review the task's diff itself, first against the task spec, then with the code-review skill; fix what it flags before the next task |
| final review        | final whole-implementation review subagent (model opus)         | final self-review of the whole lane diff with the code-review skill |
| reviewer roles      | as tower prints them                                             | both reviewer roles are the lane's own model; say so in the brief |

A codex lane briefed with subagent instructions will improvise; match the
tail to the kind.

## Merge points

Lane A's branch is the integration branch. A lane that needs another lane's
work merges that lane's branch (or the integration branch, to pick up work
already merged into it) before the task that needs it. A finished lane never
merges its own branch into the integration branch — only the orchestrator
does that, right away, not lane A at its next merge point. So lane B's brief
never says "merge into A"; it says "tower note … ready to merge" and stops.

---

You are lane {{LANE}} of a {{N}}-lane run, agent {{AGENT}}. Working directory: {{CHECKOUT}} (branch {{BRANCH}} — already a checkout; do NOT create a worktree, do NOT cd to any other checkout). {{"Dependencies are installed." | "First run: <install cmd>."}}

Read first: CONTEXT.md and docs/adr/ if the repo has them, then the spec and the plan named below.

YOUR TASKS are the ones below and nothing else. Do not add, change or remove tasks on the board — ignore the `tower add` paragraph below; if you discover work the list is missing, `tower block <id> "<what you found>"` (or `tower note --lane {{LANE}}`) and let the orchestrator decide.

METHOD: {{e.g. "Before each task load the tdd skill and follow its loop; the seams are the modules in the task's Files list, tested through their exports. One failing test, then the minimal implementation, one slice at a time. When green: run the check gate  {{CHECK_CMD from panes.txt}}  from the repo root, commit, then" — claude: "a spec-compliance review subagent (model sonnet) and a code-quality review subagent (model opus); fix what they flag. Pass the model explicitly on every dispatch." — codex: "review the task's diff yourself: first against the task spec, then with the code-review skill; fix what it flags before the next task. Report the two reviewing phases as usual; both reviewer roles below are you."}}

OTHER LANES: {{e.g. "Lane B (agent <name>, branch <branch>) owns tasks 5, 7-9; skip them entirely — do not implement them, do not touch their files, do not report on their ids."}}

MERGE POINTS: {{lane A: "Before task N run  git merge <lane-b-branch> ; if lane B has not finished task M (tower state --json, or git log <branch> --oneline) wait and re-check every 3 minutes. Resolve conflicts keeping both sides, run the check gate, commit the merge, continue."  lane B: "Task M needs X from lane A's task K: before task M run  git merge <integration-branch>  and confirm <file> exists; if not, wait and re-check every 3 minutes — never write a local copy."}}

PANES you may read instead of re-running suites (herdr pane read <id> --source recent-unwrapped --lines 60): checks {{id}}{{, dev {{id}}}} — they run in lane A's checkout on the integration branch, so what they show is the merged state, not necessarily yours.

Do not stop between tasks to ask whether to continue. If you cannot proceed: tower block <id> "<exactly what you need>", then stop and wait.

WHEN YOUR LAST TASK IS DONE: {{lane A: "run the check gate from the repo root, then a final whole-implementation review (claude: subagent, model opus; codex: self-review of the whole lane diff with the code-review skill), fix what it flags, then  tower note --lane A 'ALL DONE - check green'  and report a summary."  other lanes: "run the check gate for your files, then  tower note --lane {{LANE}} 'lane {{LANE}} complete - ready to merge'  and stop; the orchestrator merges you."}}

Begin now with task {{FIRST_ID}}.

--- (paste the output of `tower brief <lane>` below this line) ---
