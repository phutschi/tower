# Issue tracker

Issues for this repo live in GitHub issues on `phutschi/tower`.

- Specs are published there (`/to-spec`).
- Preflight follow-ups are filed there, one issue per follow-up, and linked
  from the PR:

  ```bash
  gh issue create -R phutschi/tower --title "<title>" --body "<body>"
  ```

  With `TRIAGE=auto`, preflight first looks for an open issue with the same
  title, and labels each new one `preflight`:

  ```bash
  gh issue list -R phutschi/tower --state open --search "<title> in:title"
  gh label create preflight -R phutschi/tower   # once, when it is missing
  gh issue create -R phutschi/tower --label preflight --title "<title>" --body "<body>"
  ```
