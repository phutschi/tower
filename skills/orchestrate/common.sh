# Sourced first by every script in the kit. Expects `set -u`.
#
# DRY_RUN=1 puts tests/stub first on PATH: herdr, claude and codex are then
# stand-ins that log their argv (HERDR_STUB_LOG, default stderr) and answer
# with canned JSON, so a script can be run outside herdr to see what it would
# do. tower is the real CLI from this checkout (tests/stub/tower), so the run
# is recorded for real, in the run dir. test.sh runs everything this way.
KIT="${KIT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
die()      { echo "$*" >&2; exit 1; }
# The run switches' names (detect-stack.sh gives them their values).
SWITCHES="TASK_REVIEW LANE_REVIEW PREFLIGHT STATIC_BASELINE PR METHOD REVIEWER_KIND REVIEWER_MODEL REVIEW_AREAS SUITE_SKIP PR_TEMPLATE"
if [ "${DRY_RUN:-0}" = 1 ]; then
  # A broken or non-executable stub would otherwise fall through silently to
  # whatever herdr/tower is next on PATH — the real ones. Refuse instead.
  [ -x "$KIT/tests/stub/herdr" ] || die "DRY_RUN=1 but $KIT/tests/stub/herdr is missing or not executable — refusing to fall through to the real herdr"
  export PATH="$KIT/tests/stub:$PATH"
  export HERDR_STUB_LOG="${HERDR_STUB_LOG:-/dev/stderr}"
  # Inside herdr unless the caller says otherwise (HERDR_ENV=0 tests the refusal).
  export HERDR_ENV="${HERDR_ENV:-1}" HERDR_PANE_ID="${HERDR_PANE_ID:-pane-0}" HERDR_TAB_ID="${HERDR_TAB_ID:-tab-0}"
fi

# The orchestrate skill is herdr-only: it runs from a herdr pane with herdr
# runnable, or it refuses before touching anything.
in_herdr() {
  [ "${HERDR_ENV:-}" = 1 ] && herdr --version >/dev/null 2>&1 && return 0
  local hint=" DRY_RUN=1 shows what this script would do."
  [ "${DRY_RUN:-0}" = 1 ] && hint=""
  die "not inside herdr: the orchestrate skill needs herdr (https://herdr.dev) and runs from a herdr pane (HERDR_ENV=1). Without herdr, use /tower:run, which works with any runner.$hint"
}
need()     { local c; for c in "$@"; do command -v "$c" >/dev/null || die "missing dependency: $c"; done; }
jsonq()    { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
pane_id()  { jsonq 'd["result"]["pane"]["pane_id"]'; }
# The main checkout's root, from any worktree of it.
repo_root() { git rev-parse --path-format=absolute --git-common-dir | sed 's#/\.git$##'; }

TOWER_POINTER='install tower: a binary from github.com/phutschi/tower/releases into ~/.local/bin, or from a checkout of github.com/phutschi/tower'
# 0: tower is on PATH and runs; 1: not.
tower_ok() { command -v tower >/dev/null && tower --help >/dev/null 2>&1 || return 1; }
# An orchestrate run always has tower as its record: refuse before anything
# is created when it does not run.
need_tower() { tower_ok || die "tower is not runnable: an orchestrate run needs tower, its record and console. $TOWER_POINTER"; }
