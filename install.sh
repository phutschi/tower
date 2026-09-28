#!/usr/bin/env bash
# Install the kit as a skill and check what it needs.
#
#   install.sh           check dependencies, then symlink the kit into
#                        ~/.claude/skills and ~/.agents/skills as herdr-orchestrate
#   install.sh --check   only check
#
# Needs: herdr (the terminal), git, bash, python3 (reads herdr's JSON), node
# (reads package.json in JS repos). Optional: tower 0.2.0+ (the record and the
# console), codex (EXECUTOR_KIND=codex lanes).
set -u
KIT="$(cd "$(dirname "$0")" && pwd)"
. "$KIT/common.sh"
CHECK_ONLY=0; [ "${1:-}" = --check ] && CHECK_ONLY=1

ok=1
have() { if command -v "$1" >/dev/null; then printf '  ok        %s\n' "$1"; else printf '  MISSING   %-8s %s\n' "$1" "$2"; ok=0; fi; }
opt()  { if command -v "$1" >/dev/null; then printf '  ok        %s (optional)\n' "$1"; else printf '  optional  %-8s %s\n' "$1" "$2"; fi; }
echo "dependencies:"
have herdr   "the terminal this kit runs in"
have git     "version control"
have bash    "the scripts"
have python3 "reads herdr's JSON"
have node    "reads package.json in JS repos"
opt  tower   "the record and the console — $TOWER_POINTER"
opt  codex   "lanes with EXECUTOR_KIND=codex"
if command -v tower >/dev/null; then
  tower_ok; case $? in 2) printf '  OLD       tower    0.2.0 or later is required — %s\n' "$TOWER_POINTER" ;; esac
fi
[ "$ok" = 1 ] || { echo "install the missing dependencies first" >&2; exit 1; }
[ "$CHECK_ONLY" = 1 ] && exit 0

echo "skill:"
for d in "$HOME/.claude/skills" "$HOME/.agents/skills"; do
  mkdir -p "$d"
  if [ -L "$d/herdr-orchestrate" ] || [ ! -e "$d/herdr-orchestrate" ]; then
    ln -sfn "$KIT" "$d/herdr-orchestrate"; echo "  linked    $d/herdr-orchestrate -> $KIT"
  else
    echo "  SKIPPED   $d/herdr-orchestrate exists and is not a symlink"
  fi
done
cat <<'MSG'

Two ways to start, from a herdr pane in your repo on the feature branch:
  with a plan:   "implement <path to plan.md or tasks.tsv> with herdr-orchestrate"
  without:       "spin up herdr-orchestrate", then say what to build
MSG
