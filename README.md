# tower

Plan a spec into lanes, run the lanes with coding agents, and watch the whole
run on one board.

![an orchestrate run in herdr: the orchestrator, two lanes and the tower board](demo.gif)

## How a run goes

1. Write a spec: an issue or a file.
2. `/tower:spec-to-plan <spec>` slices it into tasks, groups them into lanes
   with their merge points, and writes `plan.md`. It writes no code.
3. `/tower:orchestrate <plan.md>`, from a pane in [herdr](https://herdr.dev),
   opens the run. Each lane gets an executor, lanes B to D each in their own
   worktree. The executors implement and report every step to tower.
4. A fresh Reviewer reviews each finished lane; the orchestrator merges it.
   Preflight checks the whole branch. You confirm once, and a draft PR opens.

The orchestrator never implements. It briefs, watches, decides and merges.
The record of all of it is tower's board and transcript.

## What you see

The console is the board: every task with its lane, status, phase and model,
and the transcript of the run below it. You leave it open for hours. It is
read-only: it starts nothing and sends nothing, so killing it only makes you
blind; the run goes on. The demo above is a whole run, from the first task to
a closed field.

## Without herdr

`/tower:run` is the same orchestrator for any harness and any runner: you
start the executor sessions yourself, and it briefs and watches them. The
skills use the open Agent Skills format; they are exercised with Claude Code,
and with Codex lanes under `/tower:orchestrate`.

Or use the CLI on its own: `tower init` from a plan, `tower brief` for each
executor, `tower` to watch. Executors report with `tower task`, `tower block`
and `tower note`. See [docs/cli.md](docs/cli.md).

## Install

You never need Bun to use tower. The CLI uses git; `/tower:orchestrate` also
needs herdr, python3 and node.

**A release binary** (macOS and Linux, arm64 or x64, no runtime needed). Each
release carries `tower-<os>-<arch>` and a `SHA256SUMS` to check it against:

```sh
v=v0.3.0; bin=tower-darwin-arm64   # or darwin-x64, linux-x64, linux-arm64
curl -fLO https://github.com/phutschi/tower/releases/download/$v/$bin
curl -fLO https://github.com/phutschi/tower/releases/download/$v/SHA256SUMS
shasum -a 256 -c --ignore-missing SHA256SUMS   # Linux: sha256sum -c --ignore-missing SHA256SUMS
mkdir -p ~/.local/bin && install -m 755 $bin ~/.local/bin/tower
```

**From a clone**, `./install.sh` does that for you when tower is missing, and
installs the plugin. It also checks what `/tower:orchestrate` needs.

**From git**, with Node ≥ 22.12 and nothing else:

```sh
npm install -g github:phutschi/tower     # builds with Node alone
```

tower is not on the npm registry yet.

**The skills** come as a Claude Code plugin, installed from git:

```
/plugin marketplace add phutschi/tower
/plugin install tower@phutschi-tower
```

## Docs

- [docs/orchestrate.md](docs/orchestrate.md): a run in herdr, step by step,
  and the switches.
- [docs/cli.md](docs/cli.md): the commands, the screen, how the record works.
- [docs/agents.md](docs/agents.md): pointing your agents at tower.
- [docs/plan-format.md](docs/plan-format.md),
  [docs/protocol.md](docs/protocol.md), [docs/themes.md](docs/themes.md),
  [docs/recipes/](docs/recipes/), and the decisions in
  [docs/adr/](docs/adr/).
- [CONTEXT.md](CONTEXT.md): the words tower uses.

## Contributing

Start with [CONTRIBUTING.md](CONTRIBUTING.md); agents working on tower read
[AGENTS.md](AGENTS.md). You need Bun for the CLI, and shellcheck for the kit.
`bun run check`, `./test.sh` and shellcheck are what CI runs. Every change goes
through a pull request, never straight to `main`.

## License

MIT © Philipp Wruck
