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
# nothing. A claude command, or a link or unlink of a skill, that fails is
# printed as FAILED, and the install exits 1.
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
GIT_INSTALL='npm i -g github:phutschi/tower (Node >= 22.12)'
on_path() {  # a tower in BIN_DIR that runs, though BIN_DIR is not on PATH
  export PATH="$BIN_DIR:$PATH"
  case ":$ORIG_PATH:" in *":$BIN_DIR:"*) ;; *) echo "  note      $BIN_DIR is not on your PATH; add it" ;; esac
  # A tower that does not run, found before BIN_DIR, still wins in your shell.
  local first; first=$(PATH="$ORIG_PATH" command -v tower || true)
  if [ -n "$first" ] && [ "$first" != "$BIN_DIR/tower" ]; then
    echo "  note      $first comes first on your PATH and does not run; remove it, or put $BIN_DIR before it"
  fi
}
# get CURL-ARGS...: a download that never drops to plain http on a redirect,
# and gives up on a server that does not connect in 15 seconds or stalls
# below 1 KB/s for 30.
get() { curl -fsSL --proto-redir '=https' --connect-timeout 15 --speed-limit 1024 --speed-time 30 "$@"; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }
fetch_tower() {
  local os arch v asset sums want rc
  case "$(uname -s)" in Darwin) os=darwin ;; Linux) os=linux ;; *) os="" ;; esac
  case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; x86_64|amd64) arch=x64 ;; *) arch="" ;; esac
  [ -n "$os" ] && [ -n "$arch" ] || { echo "  no release binary of tower for $(uname -s) $(uname -m); install it with  $GIT_INSTALL" >&2; return 1; }
  command -v curl >/dev/null || { echo "  curl is needed to fetch tower; or install it with  $GIT_INSTALL" >&2; return 1; }
  v=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/.claude-plugin/plugin.json") || return 1
  asset="tower-$os-$arch"
  sums=$(get "$RELEASE_URL/v$v/SHA256SUMS" 2>/dev/null); rc=$?
  [ "$rc" = 0 ] || { echo "  could not fetch the SHA256SUMS of release v$v (curl exit $rc; 22 is no such release or no checksums, 28 a timeout or a stall): refusing an unverified tower; or install it with  $GIT_INSTALL" >&2; return 1; }
  want=$(printf '%s\n' "$sums" | awk -v a="$asset" '$2 == a || $2 == "*" a { print $1 }')
  [ -n "$want" ] || { echo "  release v$v has no checksum for $asset: refusing an unverified tower, nothing downloaded; install it with  $GIT_INSTALL" >&2; return 1; }
  mkdir -p "$BIN_DIR" && FETCH_TMP=$(mktemp "$BIN_DIR/.tower.XXXXXX") || return 1
  # The temp file goes whatever happens; Ctrl-C (or a kill) stops the install.
  trap 'rm -f "$FETCH_TMP"' EXIT
  trap 'rm -f "$FETCH_TMP"; exit 130' INT
  trap 'rm -f "$FETCH_TMP"; exit 143' TERM
  place_tower "$asset" "$v" "$want"; rc=$?
  rm -f "$FETCH_TMP"; trap - EXIT INT TERM
  return "$rc"
}
place_tower() {  # ASSET VERSION CHECKSUM: download into FETCH_TMP, verify, install
  local rc
  get -o "$FETCH_TMP" "$RELEASE_URL/v$2/$1" 2>/dev/null; rc=$?
  [ "$rc" = 0 ] || { echo "  could not download $1 v$2 from $RELEASE_URL (curl exit $rc; 28 is a timeout or a stall)" >&2; return 1; }
  if [ "$(sha256 "$FETCH_TMP")" != "$3" ]; then
    echo "  $1 v$2 does not match the release's checksum: refused, nothing installed" >&2; return 1
  fi
  # A tower already here does not run (install.sh checked): keep it, aside.
  if [ -e "$BIN_DIR/tower" ]; then
    mv "$BIN_DIR/tower" "$BIN_DIR/tower.old" && echo "  moved     $BIN_DIR/tower (it does not run) to $BIN_DIR/tower.old"
  fi
  chmod +x "$FETCH_TMP" && mv "$FETCH_TMP" "$BIN_DIR/tower" || return 1
  echo "  fetched   $1 v$2 -> $BIN_DIR/tower"
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
  # listed CMD...: the JSON list a claude list command prints. When claude
  # cannot say, it is FAILED: the install changes nothing and does not guess.
  listed() {
    local out
    if out=$("$@" 2>/dev/null) && printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(not (isinstance(d, list) and all(isinstance(x, dict) for x in d)))' 2>/dev/null; then
      printf '%s' "$out"
    else
      echo "  FAILED    $* (claude could not list what is installed, so no plugin was changed)" >&2; return 1
    fi
  }
  # The scopes plugin $1 is installed in for here: user, or a project or local
  # install of the directory install.sh runs in (as claude scopes them, run
  # from there). Other directories' installs are theirs.
  scopes() { printf '%s' "$PLUGINS" | python3 -c 'import json,os,sys; here=os.path.realpath(os.getcwd()); [print(p.get("scope","user")) for p in json.load(sys.stdin) if p.get("id")==sys.argv[1] and (not p.get("projectPath") or os.path.realpath(p["projectPath"])==here)]' "$1"; }
  marketplace() { printf '%s' "$MARKETS" | python3 -c 'import json,sys; sys.exit(not any(m.get("name")==sys.argv[1] for m in json.load(sys.stdin)))' "$1"; }
  if PLUGINS=$(listed claude plugin list --json) && MARKETS=$(listed claude plugin marketplace list --json); then
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
    tower_scopes=$(scopes tower@phutschi-tower)
    if [ -n "$tower_scopes" ]; then
      for s in $tower_scopes; do
        try "updated   tower@phutschi-tower ($s scope)" claude plugin update tower@phutschi-tower --scope "$s"
      done
    else
      try "installed tower@phutschi-tower" claude plugin install tower@phutschi-tower
    fi
  else
    ok=0
  fi
fi

echo "skills:"
# must CMD...: run a file command; when it fails, say FAILED with the command,
# and the install exits 1.
must() { local err; err=$("$@" 2>&1) || { echo "  FAILED    $* (${err:-no message})" >&2; ok=0; return 1; }; }
link() {  # TARGET DIR NAME
  must mkdir -p "$2" || return 1
  if [ -L "$2/$3" ] || [ ! -e "$2/$3" ]; then
    must ln -sfn "$1" "$2/$3" && echo "  linked    $2/$3 -> $1"
  else
    echo "  SKIPPED   $2/$3 exists and is not a symlink"
  fi
}
# The links of the kit's old layout: Claude Code now has the plugin, and a
# second copy of a skill under its bare name would shadow it. Only the kit's
# own links go: into this repo, or into a herdr-orchestrate checkout that holds
# the kit (bootstrap.sh at its root or in skills/orchestrate), or is gone.
# Anybody else's skill of the same name stays. A link is judged by the real
# path it resolves to, so a checkout reached through a link under another
# name is not recognised (the link then stays, which is the safe side).
old_kit_link() {  # TARGET: absolute, resolved (no links, no '..')
  local kit
  case "$1" in "$ROOT"|"$ROOT"/*) return 0 ;; esac
  case "$1" in
    */herdr-orchestrate) kit=$1 ;;
    */herdr-orchestrate/*) kit="${1%%/herdr-orchestrate/*}/herdr-orchestrate" ;;
    *) return 1 ;;
  esac
  # A checkout that is gone left the link dangling; one that is there must
  # hold the kit.
  { [ ! -e "$1" ] && [ ! -e "$kit" ]; } || [ -f "$kit/bootstrap.sh" ] || [ -f "$kit/skills/orchestrate/bootstrap.sh" ]
}
unlink_old() {  # DIR NAME
  local target
  [ -L "$1/$2" ] || return 0
  target=$(readlink "$1/$2")
  case "$target" in /*) ;; *) target="$1/$target" ;; esac  # relative to the link's dir
  # Where it really points: links followed as far as they exist, '..' resolved.
  target=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$target") || return 0
  if old_kit_link "$target"; then
    must rm "$1/$2" && echo "  removed   $1/$2 (old layout)"
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
