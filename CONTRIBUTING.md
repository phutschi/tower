# Contributing

Thanks for looking. tower is small on purpose; the best contributions keep it
that way.

## Two halves

`src/` is the CLI. It observes and never acts, and it knows no harness and no
runner. `skills/` is the plugin: `run` is the neutral orchestrator skill, and
`orchestrate`, `spec-to-plan` and `preflight` are the orchestrate kit.
`orchestrate` is the one skill that is openly herdr-only
([ADR 0005](docs/adr/0005-harness-and-runner-neutral.md)). The kit is bash
and markdown, and drives a run through the CLI.

## Setup

You need Bun to work on tower, and shellcheck for the kit. Users of tower need
neither.

```sh
bun install
bun run check        # format, lint, typecheck, test — the same as CI
bun run dev -- --help
./test.sh --fast     # the kit's shell tests, against this checkout's tower
shellcheck -S warning *.sh skills/*/*.sh skills/orchestrate/tests/stub/*
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
- Actions in the CLI: starting, unblocking, messaging or re-briefing agents.
  tower observes; that boundary is the design. The acting lives in the
  skills.
- A second runner for `/tower:orchestrate`. `/tower:run` covers every runner
  that is not herdr; a new layout belongs in `docs/recipes/`.
- A web UI, a server, a port.
- Windows support, for now.

## Pull requests

Branch from `main`, keep `bun run check` green, and when you touch `skills/` or
a root script keep `./test.sh` and shellcheck green too. Write a conventional
commit message, no attribution trailers. The event line and `state --json` are
contracts: a change to either edits `docs/protocol.md` in the same commit.
