# Contributing

Thanks for looking. tower is small on purpose; the best contributions keep it
that way.

## Setup

```sh
bun install
bun run check        # format, lint, typecheck, test — the same as CI
bun run dev -- --help
```

## What is welcome

- Bugs, with a failing test.
- Better error messages: every refusal should print the correct form.
- Recipes for other runners under `docs/recipes/`.
- Anything that makes the non-TTY path or `tower wait` more useful to a
  harness we have not tried.

## What is not

- **Built-in themes.** `airport` is the only one, by policy. Themes are JSON
  files in your config directory; `tower theme rules` tells you how. This
  keeps the repository from collecting pull requests that argue about words.
- Actions: starting, unblocking, messaging or re-briefing agents. tower
  observes; that boundary is the design.
- A web UI, a server, a port.
- Windows support, for now.

## Pull requests

Branch from `main`, keep `bun run check` green, write a conventional commit
message, no attribution trailers. The event line and `state --json` are
contracts: a change to either edits `docs/protocol.md` in the same commit.
