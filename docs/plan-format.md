# Task sources

`tower init` reads tasks from one of three places, or from none.

## A markdown plan (`--plan <file>`)

tower looks for headings shaped

```
### Task <id>: <title>
```

anywhere in the file, in order (headings inside fenced ``` code blocks are
ignored, so a plan that quotes its own convention as a sample doesn't confuse
the scanner). Backticks in the title are stripped. Optional frontmatter
supplies the repository and branch; without it, both come from git:

```
---
repo: acme
branch: feature/widgets
---
```

The plan's title is its first `# ` heading (falling back to a `project:`
frontmatter key). If the plan has a section headed

```
## Repo conventions every task must follow
```

`tower brief` lifts it verbatim into every executor's letter. Another heading
can be named with `tower brief --conventions-heading "<heading>"`.

## A TSV (`--tasks <file>`, or stdin)

One task per line: `id<TAB>title[<TAB>area]`. Blank lines and lines starting
with `#` are ignored.

```
# id	title	area
1	The shared prompt shortcuts	packages/core
2	The gate	apps/server
auth-1	Voice notes
```

Piped on stdin: `cat tasks.tsv | tower init`.

A TSV or stdin source has no title of its own — pass `--title "<text>"` to
name the run; it defaults to "untitled" otherwise. `--title` also overrides a
markdown plan's own title when given.

## No source

`tower init` alone creates a run with no tasks. Add them as they are known:

    tower add "<title>" [--id <id>] [--area <text>] [--after <id>] [--lane <lane>]

Without `--id`, the id is the next integer above every integer id the run
has seen. Both kinds of run accept `tower add`, `tower change` and
`tower remove` at any time; the console picks them up without a restart.

## Ids

`[A-Za-z0-9][A-Za-z0-9._-]*`, case-sensitive, unique. Order is the file's
order everywhere tower shows tasks.
