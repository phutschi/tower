# Findings format

Every review writes one JSON file into the findings dir. `look.sh` writes
`look.json`; an area review writes `<area>.json` (alone) or the file its brief
names (a Reviewer in a run). The triaging session reads every `*.json` there.

```json
{ "review": "security",
  "verdict":  [ { "step": "security", "status": "fail", "note": "1 finding",
                  "detail": "Read every changed route: 3 new handlers, all behind requireUser; ..." } ],
  "findings": [ { "area": "security", "severity": "must-fix",
                  "file": "src/api/login.ts", "line": 42,
                  "title": "Password compared with ==",
                  "evidence": "L40-44: `if (hash == input)`; timing-safe compare missing" } ] }
```

`review`: `look`, the area name, or the review title from the brief.

`verdict`: one row per step or area.

- `status` is `pass` (no finding), `fail` (a finding), `warn` (the step could
  not run fully), or `skip` (not run; `note` says why).
- `note` is one line.
- `detail`: an area review's account of what it checked, in a few lines of
  Markdown: each criterion, hotspot with its bound, or failure point. It
  feeds the PR body's details. `look.sh` leaves it out; its rows are the
  detail.

`findings`: one record per problem.

- `area`: the area the finding belongs to (`security`, `suite`, `spec`, ...).
- `severity` is one of three:
  - `must-fix`: blocks the merge.
  - `should-fix`: wrong, but the merge can carry it.
  - `watchpoint`: fine now; say what would make it a problem.
- `file` and `line`: where it is, relative to the repo root. `line` is `null`
  when no line fits, as for a red suite step.
- `title`: one line.
- `evidence`: the lines you read and what they show. Quote code. Never quote a
  secret: name its kind and place instead.

## Added in triage

Only the triaging session adds these, per finding. A Reviewer and `look.sh`
never write them.

- `validity`:
  - `valid`, `false-positive` or `uncertain`,
  - plus the lines re-read, e.g. `"valid: read L40-44, no timing-safe compare"`.
- `scope`:
  - `in-scope` (the branch introduced it) or `pre-existing`,
  - plus the check, e.g. `"in-scope: git blame L42 is commit abc1234 on this branch"`.
- `outcome`: `fix`, `accept`, `follow-up` or `reject`.
