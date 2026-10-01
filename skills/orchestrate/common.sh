# Sourced first by every script in the kit. Expects `set -u`.
#
# DRY_RUN=1 puts tests/stub first on PATH: herdr, claude, codex and
# cursor-agent are then stand-ins that log their argv (HERDR_STUB_LOG, default
# stderr) and answer with canned JSON, so a script can be run outside herdr to
# see what it would do. The credit guard's probes read no keychain and call no
# endpoint then, unless a test names its own fakes (credits.sh CREDITS_FAKES).
# tower is the real CLI from this checkout (tests/stub/tower), so the run is
# recorded for real, in the run dir. test.sh runs everything this way.
KIT="${KIT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
die()      { echo "$*" >&2; exit 1; }
# The kinds an executor or Reviewer runs in (CONTEXT.md Kind): kind_known K
# says whether K is one; kinds_say prints them for a message.
KINDS="claude codex cursor"
kind_known() { case " $KINDS " in *" $1 "*) return 0 ;; esac; return 1; }
kinds_say() {  # "a, b or c", from KINDS
  local k out="" n=0 total; total=$(echo $KINDS | wc -w)
  for k in $KINDS; do
    n=$((n+1))
    if [ "$n" -eq 1 ]; then out=$k; elif [ "$n" -eq "$total" ]; then out="$out or $k"; else out="$out, $k"; fi
  done
  echo "$out"
}
# VALUE is a REVIEWER_CREDITS_MIN: a whole number from 0 to 100 in at most
# three digits (so 0100 is refused), and the shell's own arithmetic never
# sees a huge one. The one
# check detect-stack.sh and executor.sh's reviewer_for share.
credits_min_ok() {
  case "$1" in ""|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 3 ] && [ "$1" -le 100 ]
}
credits_min_refused() { die "REVIEWER_CREDITS_MIN must be a whole number from 0 to 100 (got '$1')"; }
# The run switches' names (detect-stack.sh gives them their values).
SWITCHES="TASK_REVIEW LANE_REVIEW PREFLIGHT STATIC_BASELINE PR METHOD REVIEWER_KIND REVIEWER_MODEL REVIEWER_BY_CREDITS REVIEWER_CREDITS_MIN REVIEW_AREAS SUITE_SKIP PR_TEMPLATE"
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
# An agent as herdr reads it, one line: "<agent_status> <interactive_ready>"
# (True or False; True when herdr leaves the field out, as an older herdr
# does); gone only when herdr answers agent_not_found; unreadable when herdr
# fails for any other reason (a server restarting, a timeout) or answers
# without a status, which says nothing about the agent. herdr's errors are on
# stderr, read only when the call fails.
agent_of() {
  local out err r
  err=$(mktemp)
  if out=$(herdr agent get "$1" 2>"$err"); then
    r=$(echo "$out" | jsonq '(lambda a: "%s %s" % (a["agent_status"], a.get("interactive_ready", True)) if a.get("agent_status") else "unreadable")((d.get("result") or {}).get("agent") or {})' 2>/dev/null) || r=unreadable
  elif grep -q '"agent_not_found"' "$err"; then r=gone
  else r=unreadable
  fi
  rm -f "$err"; echo "$r"
}
# An agent's state: herdr's agent_status (its own unknown included: an agent
# herdr cannot classify), gone or unreadable (agent_of).
state_of() { local a; a=$(agent_of "$1"); echo "${a%% *}"; }
# The main checkout's root, from any worktree of it.
repo_root() { git rev-parse --path-format=absolute --git-common-dir | sed 's#/\.git$##'; }

TOWER_POINTER='install tower: a binary from github.com/phutschi/tower/releases into ~/.local/bin, or  npm i -g github:phutschi/tower'
# 0: tower is on PATH and runs; 1: not.
tower_ok() { command -v tower >/dev/null && tower --help >/dev/null 2>&1 || return 1; }
# An orchestrate run always has tower as its record: refuse before anything
# is created when it does not run.
need_tower() {
  local hint=""
  tower_ok && return 0
  [ "${DRY_RUN:-0}" = 1 ] && hint=" (under DRY_RUN=1, tower is the CLI from this kit's checkout, run with bun)"
  die "tower is not runnable: an orchestrate run needs tower, its record and console.$hint $TOWER_POINTER"
}
