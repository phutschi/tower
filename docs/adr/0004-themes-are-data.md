---
status: accepted
---

# Themes are JSON files, never code; only `airport` ships

A theme renames the fixed states; it must never re-model them or leak into
`state --json`, `wait`, errors, or the brief. Making a theme a JSON lookup table
enforces that structurally — a file that cannot contain logic cannot fork the
state machine — and lets an agent author one unsupervised with `theme check`
and `theme preview` closing the loop. Built-ins stay at one (`airport`, plus
the literal `plain`) by policy: a public repository otherwise collects pull
requests that argue about words. User themes live in the XDG config directory.
