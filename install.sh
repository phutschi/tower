#!/usr/bin/env bash
# Install the phutschi plugin and check what it needs.
#
#   install.sh           check dependencies, then register this repo as the
#                        phutschi marketplace in Claude Code and install the
#                        phutschi plugin (/phutschi:orchestrate,
#                        /phutschi:spec-to-plan, /phutschi:preflight), and link
#                        the same skills for codex: orchestrate and
#                        spec-to-plan into ~/.agents/skills, preflight into
#                        ~/.agents/skills and ~/.codex/skills
#   install.sh --check   only check
#
# Needs: herdr (the terminal), git, bash, python3 (reads herdr's JSON), node
# (reads package.json in JS repos). Optional: claude (the plugin), tower 0.2.0+
# (the record and the console), codex (EXECUTOR_KIND=codex lanes), semgrep and
# gitleaks (preflight's static baseline). Running it again changes nothing.
set -u
ROOT="$(cd "$(dirname "$0")" && pwd -P)"  # -P: run through a link, it still installs the real repo
SKILLS="$ROOT/skills"
. "$SKILLS/orchestrate/common.sh"
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
opt  claude  "Claude Code, where the plugin is installed"
opt  tower   "the record and the console — $TOWER_POINTER"
opt  codex   "lanes with EXECUTOR_KIND=codex"
opt  semgrep "preflight's static baseline (a warn row without it)" --version
opt  gitleaks "preflight's secret scan (a warn row without it)" version
if command -v tower >/dev/null; then
  tower_ok; case $? in 2) printf '  OLD       tower    0.2.0 or later is required — %s\n' "$TOWER_POINTER" ;; esac
fi
[ "$ok" = 1 ] || { echo "install the missing dependencies first" >&2; exit 1; }
[ "$CHECK_ONLY" = 1 ] && exit 0

if command -v claude >/dev/null; then
  echo "plugin:"
  if claude plugin marketplace list 2>/dev/null | grep -q 'phutschi'; then
    claude plugin marketplace update phutschi >/dev/null && echo "  updated   marketplace phutschi"
  else
    claude plugin marketplace add "$ROOT" >/dev/null && echo "  added     marketplace phutschi -> $ROOT"
  fi
  if claude plugin list 2>/dev/null | grep -q 'phutschi@phutschi'; then
    claude plugin update phutschi@phutschi >/dev/null && echo "  updated   phutschi@phutschi"
  else
    claude plugin install phutschi@phutschi >/dev/null && echo "  installed phutschi@phutschi"
  fi
fi

echo "skills:"
link() {  # TARGET DIR NAME
  mkdir -p "$2"
  if [ -L "$2/$3" ] || [ ! -e "$2/$3" ]; then
    ln -sfn "$1" "$2/$3"; echo "  linked    $2/$3 -> $1"
  else
    echo "  SKIPPED   $2/$3 exists and is not a symlink"
  fi
}
# The links of the kit's old layout: Claude Code now has the plugin, and a
# second copy of a skill under its bare name would shadow it.
unlink_old() {  # DIR NAME
  if [ -L "$1/$2" ]; then
    case "$(readlink "$1/$2")" in "$ROOT"|"$ROOT"/*|*herdr-orchestrate*|*spec-to-plan*) rm "$1/$2"; echo "  removed   $1/$2 (old layout)" ;; esac
  fi
}
for n in herdr-orchestrate preflight spec-to-plan; do unlink_old "$HOME/.claude/skills" "$n"; done
unlink_old "$HOME/.agents/skills" herdr-orchestrate
for n in orchestrate spec-to-plan preflight; do link "$SKILLS/$n" "$HOME/.agents/skills" "$n"; done
link "$SKILLS/preflight" "$HOME/.codex/skills" preflight
cat <<'MSG'

Plan, in any session:  /phutschi:spec-to-plan <spec path or issue URL>
Run, from a herdr pane in your repo on the feature branch:
  with a plan:   /phutschi:orchestrate <path to plan.md or tasks.tsv>
  without:       /phutschi:orchestrate, then say what to build
MSG
