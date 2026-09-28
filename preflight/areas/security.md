# Area: security

What an attacker, a careless caller or a leaked log could do with the
changed code. semgrep and gitleaks results are in `look.json` already;
spend this area on what a scanner cannot judge.

Walk every changed file for:

- **Input to commands and queries**: shell strings, SQL, paths, regexes,
  templates built from input. Is every value quoted, bound or checked?
- **Auth boundaries**: a new route, handler, script flag or file that
  skips a check the neighbouring code makes.
- **Secrets**: keys, tokens or passwords in code, fixtures, logs, error
  messages or findings files. Name the kind and the place; never copy the
  value.
- **Data exposure**: a response, log line or file that now carries more
  than before, or reaches someone new.
- **Files and processes**: temp files, permissions, symlinks followed,
  cleanup on failure, a command run with more rights than it needs.
- **New dependencies**: what each one runs at install and at runtime.

Severity: exploitable or leaks a secret: `must-fix`. Needs an unusual
caller or setup: `should-fix`. Safe today, unsafe if one assumption
changes: `watchpoint`, naming the assumption.
