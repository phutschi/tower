---
name: preflight
description: Use to check a whole branch before its PR ("run preflight", "is this branch ready for a PR", "preflight this branch"). Look: static scan and the full suite on the diff, then agent review by area. Act: one triage table, fixes, follow-up issues, push, draft PR. Also loaded by a herdr-orchestrate Reviewer for its areas only.
---

# Preflight

Preflight checks a whole branch before its PR, in two halves:

- **Look**: the static baseline, the full suite, then agent review by area.
  Every result is a finding in the shared format (`findings.md`, next to
  this file).
- **Act**: triage every finding into one table, get the human's one
  confirmation, then fix, file follow-ups, push and open the PR.

Vocabulary: Reviewer, Finding, Follow-up, Full suite, Repo contract, as in
herdr-orchestrate's `CONTEXT.md`.

## Who does what

Find your role first; it decides which half you run.

- **Alone** (no herdr-orchestrate run): you run both halves in this session.
- **A Reviewer in a run**: your brief names your areas and your findings
  file. Run look, for those areas only. You only report: leave every file
  of the repo as it is, and never commit, push or open a PR. Your last
  line is `FINDINGS WRITTEN <findings-file>`.
- **The orchestrator of a run**: run act, on the Reviewers' findings files.
  Your triage table also carries the findings you deferred during lane
  reviews.

## Settings

Read from the environment, else the repo's `.herdr-orchestrate`. Inside a
run, the `switches:` line of `panes.txt` has the values the run uses.

- `STATIC_BASELINE=off`: skip semgrep and gitleaks.
- `SUITE_SKIP=build,lint`: skip these suite steps.
- `REVIEW_AREAS=security,spec`: review only these areas. Empty: every area.
- `PR=draft|ready|off`: how act opens the PR. `off`: no push, no PR.
- `PR_TEMPLATE=<path>`: the PR body template in the repo. Empty:
  `templates/pr-body.md`.

## Look

1. **Findings dir.** Alone: `$(git rev-parse --git-dir)/preflight/`; empty
   it first. A Reviewer: the directory of the findings file in its brief.
2. **Base.** The branch the PR goes into, usually `origin/main`. Run
   `git fetch origin` first.
3. **Static baseline and full suite.** Alone, and the Reviewer whose brief
   lists them (R1 by default), run:

   ```bash
   <this skill's dir>/look.sh <base> <findings-dir>
   ```

   Its header is its manual. It writes `look.json` and prints the verdict.
   - Exit 0: green, go on.
   - Exit 1: a must-fix finding. **Stop before agent review.** Alone: go
     to act with `look.json` alone, fix, and run look again. A Reviewer:
     write your findings file with one `skip` row per area, note
     `look is red`, and end.
   - Exit 2: setup error. Report the printed error and stop.
4. **Agent review by area.** The areas are the files in `areas/` next to
   this file, plus the repo's `.preflight/areas/*.md`. A repo file with a
   built-in's name adds to that area; its rules win where they differ. The
   file name, without `.md`, is the area's name. `REVIEW_AREAS` narrows the
   list.
   - Alone on claude: one subagent per area, in parallel. Each reads its
     area file and `findings.md` and writes `<findings-dir>/<area>.json`.
   - Alone on codex: the areas one after another, each to
     `<findings-dir>/<area>.json`.
   - A Reviewer: your areas one after another, all into your one findings
     file, one verdict row per area.

   The review covers the diff against the merge base:
   `git diff $(git merge-base <base> HEAD)`. Every area is done when each
   rule of its file is applied to every changed file. An area with nothing
   to report still gets its verdict row: `pass`.
5. A Reviewer ends here: `FINDINGS WRITTEN <findings-file>`.

## Act

1. **Collect** every `*.json` in the findings dir. Inside a run, add the
   findings you deferred during lane reviews.
2. **Triage** each finding, adding the fields in `findings.md`:
   - **Validity**: re-read the cited lines yourself. The evidence names the
     lines you read. The reviewer's word is not evidence.
   - **Scope**: `git blame` the lines and compare with the merge base.
   - **Outcome**:

     | Validity | Scope | Suggested outcome |
     |---|---|---|
     | false-positive | | reject |
     | uncertain | | accept or follow-up |
     | valid | in-scope | fix |
     | valid | pre-existing | accept or follow-up |

3. **One table, one confirmation.** Show every finding in one table:
   number, area, severity, file:line, title, suggested outcome, validity
   and scope with their evidence. Ask once. The human's one reply decides
   every outcome and approves the fixes, the follow-up issues, the push and
   the PR. Until that reply, everything stays on this machine.
4. **Fix.** Alone: fix, commit, run look again for the areas the fix
   touches. Inside a run: each fix becomes a task for lane A; the Reviewer
   re-reviews. After two rounds with a finding still open, stop and hand it
   to the human.
5. **Follow-ups.** One issue per follow-up, in the tracker that
   `docs/agents/issue-tracker.md` names. No such file: stop and ask the
   human where follow-ups go. Keep each issue's link for the PR body.
6. **Push and PR**, as `PR` says:
   - `draft`: `git push -u origin HEAD`, then `gh pr create --draft`.
   - `ready`: the same without `--draft`.
   - `off`: push nothing, open nothing; report the branch ready.

   A PR already open for the branch gets its body updated
   (`gh pr edit --body-file`) instead.
7. **PR body.** Fill `PR_TEMPLATE`, else `templates/pr-body.md`. Every
   placeholder filled, in a merge-ready tone: a trade-off reads as decided
   and accepted, with its reason, never as an open question.
