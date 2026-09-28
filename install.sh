#!/usr/bin/env bash
# Install the tower plugin's kit and check what it needs.
#
#   install.sh           check dependencies, then register this repo as the
#                        phutschi-tower marketplace in Claude Code and install
#                        tower@phutschi-tower (/tower:run, /tower:orchestrate,
#                        /tower:spec-to-plan, /tower:preflight), replacing the
#                        old phutschi plugin and marketplace, and link the kit's
#                        skills for codex: orchestrate and spec-to-plan into
#                        ~/.agents/skills, preflight into ~/.agents/skills and
#                        ~/.codex/skills
#   install.sh --check   only check
#
# Needs: herdr (the terminal), tower (the record and the console; it must run),
# git, bash, python3 (reads herdr's JSON), node (reads package.json in JS
# repos). Optional: claude (the plugin), codex (EXECUTOR_KIND=codex lanes),
# semgrep and gitleaks (preflight's static baseline). Running it again changes
# nothing.
set -u
ROOT="$(cd "$(dirname "$0")" && pwd -P)"  # -P: run through a link, it still installs the real repo
SKILLS="$ROOT/skills"
. "$SKILLS/orchestrate/common.sh"
CHECK_ONLY=0; [ "${1:-}" = --check ] && CHECK_ONLY=1

ok=1
have() { if command -v "$1" >/dev/null; then printf '  ok        %s\n' "$1"; else printf '  MISSING   %-8s %s\n' "$1" "$2"; ok=0; fi; }
runs() { if tower_ok; then printf '  ok        tower\n'; else printf '  MISSING   %-8s %s\n' tower "the record and the console, and it must run — $TOWER_POINTER"; ok=0; fi; }
# opt TOOL WHAT [PROBE-ARG]: with PROBE-ARG, the tool must also run (`TOOL PROBE-ARG`).
opt()  { if command -v "$1" >/dev/null && { [ -z "${3:-}" ] || "$1" "$3" >/dev/null 2>&1; }; then printf '  ok        %s (optional)\n' "$1"; else printf '  optional  %-8s %s\n' "$1" "$2"; fi; }
echo "dependencies:"
have herdr   "the terminal this kit runs in"
runs
have git     "version control"
have bash    "the scripts"
have python3 "reads herdr's JSON"
have node    "reads package.json in JS repos"
opt  claude  "Claude Code, where the plugin is installed"
opt  codex   "lanes with EXECUTOR_KIND=codex"
opt  semgrep "preflight's static baseline (a warn row without it)" --version
opt  gitleaks "preflight's secret scan (a warn row without it)" version
[ "$ok" = 1 ] || { echo "install the missing dependencies first" >&2; exit 1; }
[ "$CHECK_ONLY" = 1 ] && exit 0

if command -v claude >/dev/null; then
  echo "plugin:"
  # listed KIND NAME: claude lists that plugin or marketplace (`  ❯ <name>`).
  listed() {
    if [ "$1" = plugin ]; then claude plugin list; else claude plugin marketplace list; fi 2>/dev/null \
      | sed -n 's/^[[:space:]]*❯[[:space:]]*//p' | grep -qxF -- "$2"
  }
  # The kit's old plugin: a second orchestrator next to tower's.
  if listed plugin phutschi@phutschi; then
    claude plugin uninstall phutschi@phutschi >/dev/null && echo "  removed   phutschi@phutschi (old plugin)"
  fi
  if listed marketplace phutschi; then
    claude plugin marketplace remove phutschi >/dev/null && echo "  removed   marketplace phutschi (old)"
  fi
  if listed marketplace phutschi-tower; then
    claude plugin marketplace update phutschi-tower >/dev/null && echo "  updated   marketplace phutschi-tower"
  else
    claude plugin marketplace add "$ROOT" >/dev/null && echo "  added     marketplace phutschi-tower -> $ROOT"
  fi
  if listed plugin tower@phutschi-tower; then
    claude plugin update tower@phutschi-tower >/dev/null && echo "  updated   tower@phutschi-tower"
  else
    claude plugin install tower@phutschi-tower >/dev/null && echo "  installed tower@phutschi-tower"
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

Plan, in any session:  /tower:spec-to-plan <spec path or issue URL>
Run, from a herdr pane in your repo on the feature branch:
  with a plan:   /tower:orchestrate <path to plan.md or tasks.tsv>
  without:       /tower:orchestrate, then say what to build
MSG
