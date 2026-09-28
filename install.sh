#!/usr/bin/env bash
# Install the kit as a skill and check what it needs.
#
#   install.sh           check dependencies, then symlink the kit into
#                        ~/.claude/skills and ~/.agents/skills as herdr-orchestrate,
#                        and preflight/ into ~/.claude/skills, ~/.agents/skills
#                        and ~/.codex/skills as preflight
#   install.sh --check   only check
#
# Needs: herdr (the terminal), git, bash, python3 (reads herdr's JSON), node
# (reads package.json in JS repos). Optional: tower 0.2.0+ (the record and the
# console), codex (EXECUTOR_KIND=codex lanes), semgrep and gitleaks (preflight's
# static baseline). Running it again changes nothing.
set -u
KIT="$(cd "$(dirname "$0")" && pwd -P)"  # -P: run through its own link, it still links the real kit
. "$KIT/common.sh"
CHECK_ONLY=0; [ "${1:-}" = --check ] && CHECK_ONLY=1

ok=1
have() { if command -v "$1" >/dev/null; then printf '  ok        %s\n' "$1"; else printf '  MISSING   %-8s %s\n' "$1" "$2"; ok=0; fi; }
# opt TOOL WHAT [PROBE-ARG]: with PROBE-ARG, the tool must also run (`TOOL PROBE-ARG`).
opt()  { if command -v "$1" >/dev/null && { [ -z "${3:-}" ] || "$1" "$3" >/dev/null 2>&1; }; then printf '  ok        %s (optional)\n' "$1"; else printf '  optional  %-8s %s\n' "$1" "$2"; fi; }
echo "dependencies:"
have herdr   "the terminal this kit runs in"
have git     "version control"
have bash    "the scripts"
have python3 "reads herdr's JSON"
have node    "reads package.json in JS repos"
opt  tower   "the record and the console — $TOWER_POINTER"
opt  codex   "lanes with EXECUTOR_KIND=codex"
opt  semgrep "preflight's static baseline (a warn row without it)" --version
opt  gitleaks "preflight's secret scan (a warn row without it)" version
if command -v tower >/dev/null; then
  tower_ok; case $? in 2) printf '  OLD       tower    0.2.0 or later is required — %s\n' "$TOWER_POINTER" ;; esac
fi
[ "$ok" = 1 ] || { echo "install the missing dependencies first" >&2; exit 1; }
[ "$CHECK_ONLY" = 1 ] && exit 0

echo "skills:"
link() {  # TARGET DIR NAME
  mkdir -p "$2"
  if [ -L "$2/$3" ] || [ ! -e "$2/$3" ]; then
    ln -sfn "$1" "$2/$3"; echo "  linked    $2/$3 -> $1"
  else
    echo "  SKIPPED   $2/$3 exists and is not a symlink"
  fi
}
for d in "$HOME/.claude/skills" "$HOME/.agents/skills"; do link "$KIT" "$d" herdr-orchestrate; done
for d in "$HOME/.claude/skills" "$HOME/.agents/skills" "$HOME/.codex/skills"; do link "$KIT/preflight" "$d" preflight; done
cat <<'MSG'

Two ways to start, from a herdr pane in your repo on the feature branch:
  with a plan:   "implement <path to plan.md or tasks.tsv> with herdr-orchestrate"
  without:       "spin up herdr-orchestrate", then say what to build
MSG
