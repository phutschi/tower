---
type: plan
project: <human-readable project or ticket name>
repo: <repo name>
branch: <full git branch with slashes>
spec: <path or tracker URL of the spec>
---

# <Feature name>

**Goal:** <one sentence>

**Spec:** <path or URL>. **Decisions:** <links to the ADRs this plan rests on>.

## Repo conventions every task must follow

<the rules an executor cannot read off the code: commit style, where tests
live, naming, what to run before a commit if it differs from the repo's
check gate, and anything the spec's Testing Decisions section fixed>

## Lanes

`A=<ids> B=<ids>`

- Lane A: <area>. Lane B: <area>.
- Merge points: before task <n>, lane B merges the integration branch and
  confirms <file> exists (from lane A's task <k>). Before task <m>, lane A
  merges lane B's branch.

## Tasks

### Task 1: <title>

**Delivers:** <the end-to-end behaviour this task makes work>

**Acceptance criteria:**
- [ ] <behaviour, phrased like a test name>
- [ ] <behaviour>

**Files and seams:**
- Create: `exact/path/new.ts` — tested through its exports `<name>`, `<name>`
- Modify: `exact/path/existing.ts` — seam: `<exported function>`

**Interfaces:**
```ts
export function name(arg: Type): Result
```

**Depends on:** none

**Decisions:** [[ADR 000x]], spec § <section>

### Task 2: <title>

…
