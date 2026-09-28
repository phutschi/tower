---
name: preflight
description: Use to check a whole branch before its PR ("run preflight", "is this branch ready for a PR"), ending in a draft PR. Also loaded by an orchestrate Reviewer to review its areas only.
---

# Preflight

Preflight checks a whole branch before its PR, in two halves:

- **Look**: the static baseline, the full suite, then agent review by area.
  Every result is a finding in the shared format (`findings.md`, next to
  this file).
- **Act**: triage every finding into one table, get the human's one
  confirmation, then fix, file follow-ups, push and open the PR.

Words: a **Finding** is one problem with the file and line it cites. A
**Follow-up** is a finding chosen for later; it becomes an issue. The
**full suite** is the repo's thorough checks: every test, typecheck, lint
and build. A **Reviewer** is an agent in an orchestrate run that
reviews work it did not write and only reports. A **round** is one look and
the act on it: the first round looks at the whole branch, and after fixes
the next round looks again. Each round `<n>` (from 1) writes into its own
findings dir, `<preflight-dir>/<n>/`. A look is **red** while it has an
**open** must-fix finding: one not triaged `accept`, `follow-up` or
`reject` in an earlier round (the same area, file and title). A finding
triaged `fix` stays open until a later round that reviews its area no
longer finds it. `look.sh`
exits 1 on any must-fix finding; it does not know the triage.

## Who does what

Find your role first; it decides which half you run.

- **Alone** (no orchestrate run): you run both halves in this session.
- **A Reviewer in a run**: your brief names your areas, your findings file,
  and whether you run `look.sh`. Run look for those only, then end with one
  line: FINDINGS WRITTEN in double square brackets, a space, then the
  findings file after the closing brackets.
- **The orchestrator of a run**: run act, on the Reviewers' findings files
  plus the findings you deferred during lane reviews.

Look only reports. Whoever runs it (a Reviewer, or an area subagent) writes
its findings file and nothing else: no edit, commit, push or PR. The one
change it makes is putting back what the suite changed (look step 3).

## Settings

Read from the environment, else the repo's `.orchestrate`. Inside a
run, the `switches:` line of `panes.txt` has the values the run uses.
`look.sh` reads `STATIC_BASELINE` and `SUITE_SKIP` itself. You read:

- `REVIEW_AREAS=security,spec`: review only these areas. Empty: every area.
- `PR=draft|ready|off`, default `draft`: how act opens the PR. `off`: no
  push, no PR.
- `PR_TEMPLATE=<path>`: the PR body template in the repo. Empty:
  `templates/pr-body.md` next to this file.

## Look

1. **Findings dir.** Alone: `<preflight-dir>/<n>/`, where the preflight dir
   is `$(git rev-parse --git-dir)/preflight/`; empty the preflight dir before
   round 1 and keep earlier rounds after it. Inside a run the preflight dir
   is `<run-dir>/findings/preflight/`. A Reviewer: the directory of its
   findings file.
2. **Base.** Run `git fetch origin`. The base branch `<base>` is the name
   the PR goes into, without `origin/`: an open PR's
   (`gh pr view --json baseRefName -q .baseRefName`), else the remote's
   default (`git symbolic-ref --short refs/remotes/origin/HEAD`, minus
   `origin/`). Git commands take `origin/<base>`; `gh` takes `<base>`.
3. **Static baseline and full suite.** Alone, or when your brief says so.
   `look.sh` needs a clean tracked tree: `git status --short
   --untracked-files=no` prints nothing (untracked files are fine); it exits
   2 otherwise. Alone, when that prints files: ask the human whether to
   commit or stash them first. Then run

   ```bash
   <this skill's dir>/look.sh origin/<base> <findings-dir>
   ```

   Its header is its manual. It writes `look.json` and prints the verdict.
   If `git status --short --untracked-files=no` now lists files, the suite
   changed them: add a `should-fix` finding (area `suite`) naming them, and
   put them back with `git checkout -- <files>`. The tree was clean, so this
   returns the checkout to how look found it. Name new untracked files the
   suite left in the same finding, and leave them in place.
   - Exit 0: green, go on.
   - Exit 1: a must-fix finding. None of them open: go on as for exit 0.
     Otherwise the look is red. **Stop before agent review.** Alone: see
     "A red look" below. A Reviewer: write your findings file with one
     `skip` row per area, note `look is red`, and go to step 5.
   - Exit 2, or exit 1 with no `look.json`: setup error. Alone: report the
     printed error and stop. A Reviewer: write your findings file with one
     `warn` row per area, the error as its note, and go to step 5.
4. **Agent review by area.** The areas are the files in `areas/` next to
   this file, plus the repo's `.preflight/areas/*.md`. A repo file with a
   built-in's name adds to that area; its rules win where they differ. The
   file name, without `.md`, is the area's name. `REVIEW_AREAS` narrows the
   list.
   - Alone on claude: one subagent per area, in parallel. Its prompt holds:
     the area's file(s), `findings.md`, the merge base, the path
     `<findings-dir>/<area>.json` to write, the rule that it writes that
     file and nothing else, and from round 2 the earlier rounds' findings
     dirs with their triage.
   - Alone on codex: the areas one after another, each to
     `<findings-dir>/<area>.json`.
   - A Reviewer: your areas one after another, all into your one findings
     file. A brief with no areas: no area rows; the file still holds the
     look's `suite` finding (step 3) and, when the brief asks for it, the
     fix-commit review.

   The review covers `git diff $(git merge-base origin/<base> HEAD)`. An
   area is done when each rule of its file is applied to every changed file
   and its verdict row is written, with `detail` saying what was checked.
   The fix-commit review (a Reviewer from round 2, when its brief asks):
   the brief's `git diff <fix-base>..HEAD` against the findings the fixes
   answer. One verdict row, step `fixes`. Every review from round 2: leave
   out a finding an earlier round triaged `accept`, `follow-up` or
   `reject`. For each finding triaged `fix`, re-read the lines it cited;
   when you still see its problem, the fix did not hold: report it again
   with that finding's area, file and title, so it matches (see open).
5. A Reviewer ends here, with its findings line (see "Who does what").

### A red look

Alone, when the look is red: triage its open must-fix findings (act steps
2 and 4), show them in one table, and ask the human. This early round
approves fixes only. Fix the ones marked `fix`, commit, and look again as
round `<n+1>`, in its own findings dir. Go on to agent review once no
must-fix finding is open; carry those outcomes into the final table. After two red looks, stop and hand the branch to the human.

## Act

1. **Collect** every `*.json` in this round's findings dir. Inside a run,
   in round 1 also add the findings you deferred during lane reviews.
   Findings with the same area, file and title are one row. From round 2,
   leave out those an earlier round triaged `accept`, `follow-up` or
   `reject` (`look.json` repeats them: `look.sh` does not know the triage).
2. **Triage** each finding, adding the fields in `findings.md`:
   - **Validity**: re-read the cited lines yourself. The evidence names the
     lines you read. The reviewer's word is not evidence.
   - **Scope**: `git blame` the lines and compare with the merge base. A
     suite finding is in scope when that step passes on the merge base.
   - **Outcome**:

     | Validity | Scope | Suggested outcome |
     |---|---|---|
     | false-positive | | reject |
     | uncertain | | accept or follow-up |
     | valid | in-scope | fix |
     | valid | pre-existing | accept or follow-up |

3. **Tracker.** Read `docs/agents/issue-tracker.md` for where follow-ups
   go. No such file: ask where, as part of the table's question in step 4.
4. **One table, one confirmation.** Show every finding in one table:
   number, area, severity, file:line, title, suggested outcome, validity
   and scope with their evidence. Ask once. The human's one reply decides
   every outcome and approves the fixes, the follow-up issues, the push and
   the PR. Until that reply, everything stays on this machine.
5. **Fix.** The next round looks at the whole branch again, at the areas
   of this round's findings triaged `fix` (those among the areas of look
   step 4), and at the fix commits (`git diff <HEAD before the fixes>..HEAD`)
   against the findings they fix, whatever their area. Alone: fix, commit,
   then round `<n+1>`: `look.sh` ("A red look" when it is red), then those
   areas and the fix commits. Inside a run: each fix becomes a task for
   lane A, then the orchestrator starts round `<n+1>`: R1 reruns `look.sh`
   and reviews the fix commits, and Reviewers review those areas plus the
   ones this round skipped (a red look or a setup error). Its findings, new
   ones and fixes that did not hold, get a new table and a new
   confirmation. When round 3's triage still has a finding triaged `fix`,
   stop and hand it to the human.
6. **Follow-ups.** One issue per follow-up of every round, in the tracker.
   Keep each issue's link for the PR body.
7. **PR body.** Fill `PR_TEMPLATE`, else `templates/pr-body.md`, into
   `<preflight-dir>/pr-body.md`. Its sources: every findings file act read
   in every round (inside a run also the deferred lane-review findings):
   the latest verdict row per step or area and its `detail`, the findings
   with their outcomes, the spec, the commits. Every
   placeholder filled, in a merge-ready tone: a trade-off reads as decided
   and accepted, with its reason.
8. **Push and PR**, as `PR` says. The title: the spec's title, else a
   summary of the commits.
   - `draft`: `git push -u origin HEAD`, then
     `gh pr create --draft --base <base> --title "<title>" --body-file <preflight-dir>/pr-body.md`.
   - `ready`: the same without `--draft`.
   - `off`: push nothing, open nothing; report the branch ready.

   A PR already open for the branch: push, then
   `gh pr edit --body-file <preflight-dir>/pr-body.md`.
