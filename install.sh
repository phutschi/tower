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
# Needs: herdr (the terminal), tower (the record and the console; it must run,
# and install.sh fetches the release binary into TOWER_BIN_DIR, default
# ~/.local/bin, when it is missing), git, bash, python3 (reads herdr's JSON),
# node (reads package.json in JS repos), curl (fetches tower). Optional: claude (the plugin), codex (EXECUTOR_KIND=codex lanes),
# semgrep and gitleaks (preflight's static baseline). Running it again changes
# nothing. A claude command that fails is printed as FAILED, and the install
# exits 1.
set -u
ROOT="$(cd "$(dirname "$0")" && pwd -P)"  # -P: run through a link, it still installs the real repo
SKILLS="$ROOT/skills"
. "$SKILLS/orchestrate/common.sh"
CHECK_ONLY=0; [ "${1:-}" = --check ] && CHECK_ONLY=1

ok=1
# tower is required. When it does not run, install.sh (not --check) fetches the
# release binary of this version into TOWER_BIN_DIR, verified against the
# release's SHA256SUMS; anything that does not verify is removed again.
BIN_DIR="${TOWER_BIN_DIR:-$HOME/.local/bin}"
RELEASE_URL="${TOWER_RELEASE_URL:-https://github.com/phutschi/tower/releases/download}"
GIT_INSTALL='npm i -g github:phutschi/tower (Node >= 22)'
on_path() {  # a tower in BIN_DIR that runs, though BIN_DIR is not on PATH
  export PATH="$BIN_DIR:$PATH"
  case ":$ORIG_PATH:" in *":$BIN_DIR:"*) ;; *) echo "  note      $BIN_DIR is not on your PATH; add it" ;; esac
}
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }
fetch_tower() {
  local os arch v asset sums want rc
  case "$(uname -s)" in Darwin) os=darwin ;; Linux) os=linux ;; *) os="" ;; esac
  case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; x86_64|amd64) arch=x64 ;; *) arch="" ;; esac
  [ -n "$os" ] && [ -n "$arch" ] || { echo "  no release binary of tower for $(uname -s) $(uname -m); install it with  $GIT_INSTALL" >&2; return 1; }
  command -v curl >/dev/null || { echo "  curl is needed to fetch tower; or install it with  $GIT_INSTALL" >&2; return 1; }
  v=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/.claude-plugin/plugin.json") || return 1
  asset="tower-$os-$arch"
  # --proto-redir: a redirect never drops to plain http.
  sums=$(curl -fsSL --proto-redir '=https' "$RELEASE_URL/v$v/SHA256SUMS" 2>/dev/null); rc=$?
  [ "$rc" = 0 ] || { echo "  could not fetch the SHA256SUMS of release v$v (curl exit $rc; 22 is no such release or no checksums): refusing an unverified tower; or install it with  $GIT_INSTALL" >&2; return 1; }
  want=$(printf '%s\n' "$sums" | awk -v a="$asset" '$2 == a || $2 == "*" a { print $1 }')
  mkdir -p "$BIN_DIR" && FETCH_TMP=$(mktemp "$BIN_DIR/.tower.XXXXXX") || return 1
  trap 'rm -f "$FETCH_TMP"' EXIT INT TERM
  if ! curl -fsSL --proto-redir '=https' -o "$FETCH_TMP" "$RELEASE_URL/v$v/$asset" 2>/dev/null; then
    echo "  could not download $asset v$v from $RELEASE_URL" >&2; rm -f "$FETCH_TMP"; return 1
  fi
  if [ -z "$want" ] || [ "$(sha256 "$FETCH_TMP")" != "$want" ]; then
    echo "  $asset v$v does not match the release's checksum: refused, nothing installed" >&2; rm -f "$FETCH_TMP"; return 1
  fi
  # A tower already here does not run (install.sh checked): keep it, aside.
  if [ -e "$BIN_DIR/tower" ]; then
    mv "$BIN_DIR/tower" "$BIN_DIR/tower.old" && echo "  moved     $BIN_DIR/tower (it does not run) to $BIN_DIR/tower.old"
  fi
  chmod +x "$FETCH_TMP" && mv "$FETCH_TMP" "$BIN_DIR/tower" || { rm -f "$FETCH_TMP"; return 1; }
  trap - EXIT INT TERM
  echo "  fetched   $asset v$v -> $BIN_DIR/tower"
}
FETCH_TMP=""

ORIG_PATH=$PATH
if ! tower_ok; then
  echo "tower:"
  if [ -x "$BIN_DIR/tower" ] && "$BIN_DIR/tower" --help >/dev/null 2>&1; then on_path
  elif [ "$CHECK_ONLY" = 0 ] && fetch_tower; then on_path
  fi
fi
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
  # try WHAT CMD...: run a claude command, and say what it did or that it failed.
  try() { local what=$1; shift; if "$@" >/dev/null; then echo "  $what"; else echo "  FAILED    $*" >&2; ok=0; fi; }
  # The scopes claude has plugin $1 installed in, one per line.
  scopes() { claude plugin list --json 2>/dev/null | python3 -c 'import json,sys; [print(p.get("scope","user")) for p in json.load(sys.stdin) if p.get("id")==sys.argv[1]]' "$1" 2>/dev/null; }
  marketplace() { claude plugin marketplace list --json 2>/dev/null | python3 -c 'import json,sys; sys.exit(not any(m.get("name")==sys.argv[1] for m in json.load(sys.stdin)))' "$1" 2>/dev/null; }
  # The kit's old plugin: a second orchestrator next to tower's.
  for s in $(scopes phutschi@phutschi); do
    try "removed   phutschi@phutschi ($s scope, old plugin)" claude plugin uninstall phutschi@phutschi --scope "$s"
  done
  marketplace phutschi && try "removed   marketplace phutschi (old)" claude plugin marketplace remove phutschi
  # An existing phutschi-tower marketplace is kept and updated, wherever it points.
  if marketplace phutschi-tower; then
    try "updated   marketplace phutschi-tower" claude plugin marketplace update phutschi-tower
  else
    try "added     marketplace phutschi-tower -> $ROOT" claude plugin marketplace add "$ROOT"
  fi
  if [ -n "$(scopes tower@phutschi-tower)" ]; then
    try "updated   tower@phutschi-tower" claude plugin update tower@phutschi-tower
  else
    try "installed tower@phutschi-tower" claude plugin install tower@phutschi-tower
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
[ "$ok" = 1 ] || { echo "install failed: see FAILED above" >&2; exit 1; }
cat <<'MSG'

Plan, in any session:  /tower:spec-to-plan <spec path or issue URL>
Run, from a herdr pane in your repo on the feature branch:
  with a plan:   /tower:orchestrate <path to plan.md or tasks.tsv>
  without:       /tower:orchestrate, then say what to build
MSG
