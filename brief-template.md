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
| `tower task <id> in_progress\|done`           | one commit per task, subject starting with the task id       |
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

## Switches

Read `switches:` in panes.txt before writing the brief.

- `METHOD=plain`: METHOD starts at "When green:"; drop the tdd sentence.
- `TASK_REVIEW=off`: METHOD ends at "commit"; drop the per-task review tail
  for either kind. The final review of WHEN YOUR LAST TASK IS DONE stays.

## Merge points

Lane A's branch is the integration branch. A lane that needs another lane's
work merges that lane's branch (or the integration branch, to pick up work
already merged into it) before the task that needs it. A finished lane never
merges its own branch into the integration branch — only the orchestrator
does that, right away, not lane A at its next merge point. So lane B's brief
never says "merge into A"; it says "tower note … ready to merge" and waits.
Ready is not the end: a lane review follows, and its fixes come back to the
same lane, so every lane stays alive until the orchestrator says it is
merged.

---

You are lane {{LANE}} of a {{N}}-lane run, agent {{AGENT}}. Working directory: {{CHECKOUT}} (branch {{BRANCH}} — already a checkout; do NOT create a worktree, do NOT cd to any other checkout). {{"Dependencies are installed." | "First run: <install cmd>."}}

Read first: CONTEXT.md and docs/adr/ if the repo has them, then the spec and the plan named below.

YOUR TASKS are the ones below and nothing else. Do not add, change or remove tasks on the board — ignore the `tower add` paragraph below; if you discover work the list is missing, `tower block <id> "<what you found>"` (or `tower note --lane {{LANE}}`) and let the orchestrator decide.

METHOD: {{e.g. "Before each task load the tdd skill and follow its loop; the seams are the modules in the task's Files list, tested through their exports. One failing test, then the minimal implementation, one slice at a time. When green: run the check gate  {{CHECK_CMD from panes.txt}}  from the repo root, commit, then" — claude: "a spec-compliance review subagent (model sonnet) and a code-quality review subagent (model opus); fix what they flag. Pass the model explicitly on every dispatch." — codex: "review the task's diff yourself: first against the task spec, then with the code-review skill; fix what it flags before the next task. Report the two reviewing phases as usual; both reviewer roles below are you."}}

OTHER LANES: {{e.g. "Lane B (agent <name>, branch <branch>) owns tasks 5, 7-9; skip them entirely — do not implement them, do not touch their files, do not report on their ids."}}

MERGE POINTS: {{lane A: "Before task N run  git merge <lane-b-branch> ; if lane B has not finished task M (tower state --json, or git log <branch> --oneline) wait and re-check every 3 minutes. Resolve conflicts keeping both sides, run the check gate, commit the merge, continue."  lane B: "Task M needs X from lane A's task K: before task M run  git merge <integration-branch>  and confirm <file> exists; if not, wait and re-check every 3 minutes — never write a local copy."}}

PANES you may read instead of re-running suites (herdr pane read <id> --source recent-unwrapped --lines 60): checks {{id}}{{, dev {{id}}}} — they run in lane A's checkout on the integration branch, so what they show is the merged state, not necessarily yours.

Do not stop between tasks to ask whether to continue. If you cannot proceed: tower block <id> "<exactly what you need>", then stop and wait.

WHEN YOUR LAST TASK IS DONE: {{lane A: "run the check gate from the repo root, then a final whole-implementation review (claude: subagent, model opus; codex: self-review of the whole lane diff with the code-review skill), fix what it flags, then  tower note --lane A 'ALL DONE - check green'  and report a summary; end your message with a last line of ALL DONE in double square brackets."  other lanes: "run the check gate for your files, then  tower note --lane {{LANE}} 'lane {{LANE}} complete - ready to merge' , end your message with a last line of READY TO MERGE in double square brackets, and wait; the orchestrator merges you."}} A Reviewer then reviews your lane. Stay in this session: fix tasks from that review come to you on the board and by prompt; do them like any task, and after the last one end your message with the same last line again.

Begin now with task {{FIRST_ID}}.

--- (paste the output of `tower brief <lane>` below this line) ---

## Reviewer briefs

A Reviewer gets its own brief, not a lane's: one message, sent with
`herdr agent prompt <reviewer-agent> "$(cat <run-dir>/brief-<task-id>.md)"`
(add-reviewer.sh prints the agent, the task id and the findings file). No
`tower brief` part. Both kinds use the same text. Without tower, drop the
REPORT paragraph: the findings line is the report. In the empty opening
there is no plan: name the tasks' titles from the board or `tasks.tsv`.
`{{ROUND}}` is the preflight round `<n>` (SKILL.md step 11): the directory
of `{{FINDINGS_FILE}}` is `<run-dir>/findings/preflight/{{ROUND}}/`.

### Lane review

You are a Reviewer in a herdr-orchestrate run, agent {{AGENT}}, board task {{TASK_ID}} (slot {{SLOT}}). Working directory: {{CHECKOUT}}, lane A's live checkout. You review lane {{LANE}}'s work, which you did not write. You only report: the one file you write is your findings file. Leave the working tree and the branch as they are; read other branches with  git diff  ,  git log  and  git show .

Load the code-review skill and review the changes on branch {{LANE_BRANCH}} since the fixed point {{LANE_BASE}}. {{lane A: "Review lane A's own commits:  git log --no-merges {{LANE_BASE}}..{{LANE_BRANCH}} --not {{OTHER_LANE_BRANCHES}} ; the other lanes get their own review."}} The spec is tasks {{TASK_IDS}} of the plan {{PLAN}} and the spec it links. Also check the tests of each task: they cover its acceptance criteria and assert what a user or the next script sees.

Write every finding to {{FINDINGS_FILE}} in the format of {{KIT}}/preflight/findings.md (review "Lane review {{LANE}}", one verdict row per task, its step the task id).

REPORT: at the start  tower task {{TASK_ID}} reviewing --model {{MODEL}} ; at the end  tower note --task {{TASK_ID}} "<n> findings"  then  tower task {{TASK_ID}} done --model {{MODEL}} . If you cannot proceed:  tower block {{TASK_ID}} "<what you need>" .

End with one line: FINDINGS WRITTEN in double square brackets, a space, then {{FINDINGS_FILE}} after the closing brackets. Then stop.

### Preflight slot

You are a Reviewer in a herdr-orchestrate run, agent {{AGENT}}, board task {{TASK_ID}} (slot {{SLOT}}). Working directory: {{CHECKOUT}}, the integration branch with every lane and origin/main merged. You only report: the one file you write is your findings file. Leave the working tree and the branch as they are.

Load the preflight skill and run its look half as a Reviewer. Your areas: {{AREAS, e.g. R1: "spec (the whole plan {{PLAN}} and its spec issue), between-lanes"; R2: "security, performance, error-handling"}}. {{R1: "You run look.sh:  (cd {{CHECKOUT}} && STATIC_BASELINE={{from switches:}} SUITE_SKIP={{from switches:}} {{KIT}}/preflight/look.sh origin/main {{RUN_DIR}}/findings/preflight/{{ROUND}}) . If it is red, stop before your areas as the skill says." | R2: "R1 runs look.sh; you review your areas only."}} Your findings file: {{FINDINGS_FILE}}.

REPORT: at the start  tower task {{TASK_ID}} reviewing --model {{MODEL}} ; at the end  tower note --task {{TASK_ID}} "<n> findings"  then  tower task {{TASK_ID}} done --model {{MODEL}} . If you cannot proceed:  tower block {{TASK_ID}} "<what you need>" .

End with one line: FINDINGS WRITTEN in double square brackets, a space, then {{FINDINGS_FILE}} after the closing brackets. Then stop.
