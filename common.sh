# Sourced first by every script in the kit. Expects `set -u`.
#
# DRY_RUN=1 puts tests/stub first on PATH: herdr and tower are then stand-ins
# that log their argv (HERDR_STUB_LOG, default stderr) and answer with canned
# JSON, so a script can be run outside herdr to see what it would do. test.sh
# runs everything this way.
KIT="${KIT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
die()      { echo "$*" >&2; exit 1; }
if [ "${DRY_RUN:-0}" = 1 ]; then
  # A broken or non-executable stub would otherwise fall through silently to
  # whatever herdr/tower is next on PATH — the real ones. Refuse instead.
  [ -x "$KIT/tests/stub/herdr" ] || die "DRY_RUN=1 but $KIT/tests/stub/herdr is missing or not executable — refusing to fall through to the real herdr"
  export PATH="$KIT/tests/stub:$PATH"
  export HERDR_STUB_LOG="${HERDR_STUB_LOG:-/dev/stderr}"
  export HERDR_ENV=1 HERDR_PANE_ID="${HERDR_PANE_ID:-pane-0}" HERDR_TAB_ID="${HERDR_TAB_ID:-tab-0}"
fi

in_herdr() { [ "${HERDR_ENV:-}" = 1 ] || die "not inside herdr: run this from a herdr pane (HERDR_ENV=1), or with DRY_RUN=1 to see what it would do"; }
need()     { local c; for c in "$@"; do command -v "$c" >/dev/null || die "missing dependency: $c"; done; }
jsonq()    { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
pane_id()  { jsonq 'd["result"]["pane"]["pane_id"]'; }
# The main checkout's root, from any worktree of it.
repo_root() { git rev-parse --path-format=absolute --git-common-dir | sed 's#/\.git$##'; }

TOWER_POINTER='tower 0.2.0 or later: github.com/phutschi/tower (binaries on the releases page; npm i -g @phutschi/tower once published; or ~/.local/bin/tower -> bun run ~/code/tower/src/cli.ts from a checkout)'
# 0: tower 0.2.0 or later is on PATH; 1: not installed or not runnable;
# 2: installed but older than 0.2.0 (its usage has no `tower add`).
tower_ok() {
  local usage
  command -v tower >/dev/null || return 1
  usage=$(tower --help 2>&1) || return 1
  echo "$usage" | grep -q 'tower add ' && return 0
  echo "$usage" | grep -q 'tower init' && return 2
  return 1
}
