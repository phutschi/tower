# Issue tracker

Issues for this repo live in GitHub issues on `phutschi/tower`.

- Specs are published there (`/to-spec`).
- Preflight follow-ups are filed there, one issue per follow-up, and linked
  from the PR:

  ```bash
  gh issue create -R phutschi/tower --title '<title>' --body-file <body-file>
  ```

  The body goes in a file: evidence quotes code, and backticks or `$(…)` in
  a double-quoted `--body` would run in the shell.

  With `TRIAGE=auto`, preflight first looks for an open issue with exactly
  the same title (a match is a URL this prints), makes sure the `preflight`
  label exists (`--force` makes the call safe to repeat), and labels each
  new issue with it:

  ```bash
  gh issue list -R phutschi/tower --state open --search '"<title>" in:title' --json title,url --jq '.[] | select(.title == "<title>") | .url'
  gh label create preflight -R phutschi/tower --color ededed --description "Filed by preflight" --force
  gh issue create -R phutschi/tower --label preflight --title '<title>' --body-file <body-file>
  ```
