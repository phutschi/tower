# Themes

The rules below are the literal text of `tower theme rules` (`THEME_RULES` in
`src/theme.ts`), kept here verbatim so they're readable without running the
CLI. If you change one, change the other in the same commit.

tower theme rules — how to author a theme

A theme is a JSON file at <XDG_CONFIG_HOME>/tower/themes/<name>.json. It is a
lookup table over states tower already has. It cannot contain logic; that is
the point.

1. A theme renames; it never re-models. The states are fixed — pending,
   in_progress (+implementing/fixing), reviewing (+spec-review/quality-review),
   done, blocked, derived stale, and the closed-run banner. Every one needs a
   label. You may not add, merge, or drop a state.

2. Pick a domain that already has all of these situations, and use its real
   words. "Go around" is what air traffic control genuinely says for a
   rejected approach that must be re-flown. Test your domain against the two
   hard slots: a review that bounced and must be redone, and an active worker
   we have heard nothing from. A fire department has "toned out", "working",
   "recall", "no contact". A school has "handed in", "returned for
   corrections", "absent". An office has "circulated", "sent back with
   comments", "unresponsive". If your domain needs an invented phrase for
   either slot, the domain is wrong — choose another rather than making one up.

3. Never a synonym list. If the labels only make sense once someone explains
   the joke, it is a costume. Someone glancing at the board should infer
   roughly what is happening without being told the theme.

4. Length is enforced, because panes are narrow: state, phase and verb labels
   are at most 14 characters; board, transcript and broadcast headings 12;
   title, operator and unit 8. `tower theme check` fails on overflow rather
   than letting the board wrap.

5. Colour belongs to status, not to the theme. Blocked is red, active is cyan,
   done is dim, in every theme. A theme file has no colour keys to set.

6. Nothing outside the renderer is themed. `tower state --json`, `tower wait`,
   validation errors, `tower brief` and `--plain` are literal in every theme.

7. A theme ships with its preview. `tower theme check <name>` renders the
   theme against a demo run that shows every state, and fails if any label is
   missing from the output. Read that preview back before calling it done.

The loop:

```
tower theme new <name>       scaffold every key, empty
tower theme check <name>     what is missing or too long
tower theme preview <name>   see it against the demo run
tower --theme <name>         use it (or --theme at tower init)
```

Keys: name, title, operator, unit, flight, broadcast, board, transcript,
states{pending,in_progress,reviewing,done,blocked,stale,closed},
phases{implementing,spec-review,quality-review,fixing,committed,…},
verbs{started,blocked}, empty, elapsed.

## Why only one ships

`airport` is the only built-in, by policy. User themes live in
`$XDG_CONFIG_HOME/tower/themes/` and are yours. Keeping the built-ins at one
keeps the project from collecting pull requests that argue about words; the
rules above are how you make a good one for yourself.
