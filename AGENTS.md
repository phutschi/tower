# Working on tower

You are contributing to tower itself. If you are pointing agents _at_ tower,
read docs/agents.md instead.

- Runtime: `src/` uses `node:*` APIs only. No `Bun.*` (ESLint enforces it).
  Node ≥ 22 and Bun must both run the built CLI.
- Toolchain: Bun. `bun run check` = format + lint + typecheck + test, and is
  what CI runs. Run it before every push.
- Tests: `bun:test`, colocated as `*.test.ts`. The fold (`src/state.ts`) is
  pure and table-driven; the screen (`src/ui/rows.ts`) is pure rows; commands
  take an injected `Io` (`src/testing.ts` has the fake).
- Imports of local files carry explicit `.ts`/`.tsx` extensions.
- Fixtures are neutral: repo `acme`, people `rex` and `sam`,
  `someone@example.com`. No real names or paths.
- The event line and `tower state --json` are public contracts
  (docs/protocol.md). Changing either changes the doc in the same commit and
  follows semver.
- Themes: only `airport` ships. Do not add a built-in theme.
- Commits: conventional (`feat(state): …`). No attribution trailers.
- Never push to `main`; open a branch and let the maintainer merge.
