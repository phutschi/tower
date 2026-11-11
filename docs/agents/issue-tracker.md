# Issue tracker

Issues for this repo live in GitHub issues on `phutschi/tower`.

- Specs are published there (`/to-spec`).
- Preflight follow-ups are filed there, one issue per follow-up, and linked
  from the PR:

  ```bash
  title=$(cat <title-file>)
  gh issue create -R phutschi/tower --title "$title" --body-file <body-file>
  ```

  The title and the body go in files, as plain text, and are read back:
  never paste either into the command. A title may hold `'` or `"`, and
  evidence quotes code, whose backticks or `$(…)` would run in the shell.

  With `TRIAGE=auto`, preflight first looks for an open issue with exactly
  the same title; a match is a URL this prints. It then looks up the
  `preflight` label and creates it only when the lookup prints nothing.
  Each new issue gets that label. A failed lookup is not a missing label. A
  lookup or a create that fails is a missing fact (a credential): that
  follow-up becomes an open decision and is never filed without the label.
  A create that fails because the label already exists is not a failure.

  ```bash
  title=$(cat <title-file>)
  gh issue list -R phutschi/tower --state open --search "\"$title\" in:title" --json title,url | jq -r --arg t "$title" '.[] | select(.title == $t) | .url'
  gh label list -R phutschi/tower --search preflight --json name --jq '.[] | select(.name=="preflight") | .name'
  gh label create preflight -R phutschi/tower --color ededed --description "Filed by preflight"   # only when the lookup printed nothing
  gh issue create -R phutschi/tower --label preflight --title "$title" --body-file <body-file>
  ```
