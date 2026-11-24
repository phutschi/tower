#!/usr/bin/env bash
# The kit's tests. They need neither herdr, claude nor codex: DRY_RUN=1 puts
# tests/stub first on PATH, so every call to them is logged and answered by a
# stub. tower is the real CLI from this checkout (tests/stub/tower runs
# src/cli.ts with bun): the tests read what the scripts recorded with
# `tower state --json`.
#
#   ./test.sh            all sections, in parallel (TEST_JOBS at once; the CPU count);
#                        TEST_SHARD=i/n runs every nth section from the ith (CI)
#   ./test.sh bootstrap  one section (a word from the "# ---" headings below)
#   ./test.sh dryrun:orca  a section of PER_RUNNER, with the runner set to Orca
#                        (RUNNER=orca); --list names each such section twice
#   ./test.sh --fast     all sections but the slow ones (SLOW): the check gate's
#                        mode; the full suite runs them all. A section named
#                        with it runs even when slow.
#   ./test.sh --list     the sections that would run, one per line; runs nothing
#
# A new section runs in both modes unless it is added to SLOW.
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"; KIT="$ROOT/skills/orchestrate"; PREFLIGHT_DIR="$ROOT/skills/preflight"; export KIT
SLOW="look run"   # preflight's look.sh and one whole run: ~12 of ~35 seconds
PER_RUNNER="dryrun executor watch bootstrap watchline add-lane add-reviewer cursor-reviewer credit-guard send-brief"   # the sections run once per runner: herdr, and <section>:orca
ONLY=""; LIST=0; FAST=0; MATCHED=0
for _a in "$@"; do
  case "$_a" in
    --list) LIST=1 ;;
    --fast) FAST=1 ;;
    --*)    echo "test.sh: unknown flag $_a" >&2; exit 2 ;;
    *)      [ -z "$ONLY" ] || { echo "test.sh: one section at most" >&2; exit 2; }; ONLY=$_a ;;
  esac
done; unset _a
unset RUNNER   # herdr unless <section>:orca says Orca, whatever the calling shell exported
case "$ONLY" in
  *:*) SECTION_RUNNER=${ONLY#*:}; ONLY=${ONLY%%:*}
       [ "$SECTION_RUNNER" = orca ] || { echo "test.sh: no runner $SECTION_RUNNER (herdr or orca)" >&2; exit 2; }
       case " $PER_RUNNER " in *" $ONLY "*) ;; *) echo "test.sh: $ONLY does not run per runner" >&2; exit 2 ;; esac
       export RUNNER=orca ;;
esac
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; shift; printf '     %s\n' "$@"; }
assert_eq()      { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected: $3" "got:      $2"; }
assert_match()   { printf '%s\n' "$2" | grep -qE -- "$3" && ok "$1" || bad "$1" "no match for /$3/ in:" "$2"; }
assert_nomatch() { printf '%s\n' "$2" | grep -qE -- "$3" && bad "$1" "unexpected match for /$3/ in:" "$2" || ok "$1"; }
section() {
  [ -z "$ONLY" ] || [ "$ONLY" = "$1" ] || return 1
  MATCHED=1
  if [ "$FAST" = 1 ] && [ -z "$ONLY" ]; then
    case " $SLOW " in
      *" $1 "*) return 1 ;;
    esac
  fi
  [ "$LIST" = 0 ] || { echo "$1"; case " $PER_RUNNER " in *" $1 "*) echo "$1:orca" ;; esac; return 1; }
}

TMP=$(cd "$(mktemp -d)" && pwd -P)
# preflight's look.sh refuses a worktree dir under /tmp, TMPDIR or a checkout
# it looks at, and $TMP is under one of the first two: look's state dirs go
# under this checkout's gitignored .worktrees/, or under ~/.cache when this
# checkout is itself under /tmp or TMPDIR. Both go on exit.
_lsb="$ROOT/.worktrees"
case "$(cd "$ROOT" && pwd -P)/" in
  "$(cd /tmp && pwd -P)"/*|"$(cd "${TMPDIR:-/tmp}" && pwd -P)"/*) _lsb="$HOME/.cache" ;;
esac
mkdir -p "$_lsb"; LOOK_STATE=$(cd "$(mktemp -d "$_lsb/tower-test-look.XXXXXX")" && pwd -P); unset _lsb
# The user's state dir (contract pins, tower's state, look's worktree dir) is
# there too: add-reviewer grants a codex Reviewer look's dir only outside /tmp
# and TMPDIR.
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP" "$LOOK_STATE"' EXIT
export DRY_RUN=1 HERDR_ENV=1 HERDR_STUB_LOG="$TMP/log" HERDR_STUB_COUNTER="$TMP/counter" HERDR_STUB_STATES_DIR="$TMP/states"
# The fake orca logs to the same log, and keeps its states (per terminal
# handle) in the same dir.
export ORCA_STUB_LOG="$TMP/log" ORCA_STUB_COUNTER="$TMP/orca-counter" ORCA_STUB_STATES_DIR="$TMP/states"
unset ORCA_STUB ORCA_STUB_STATUS ORCA_STUB_WORKTREE_FAIL
# common.sh only defaults HERDR_PANE_ID/HERDR_TAB_ID when unset, so running
# test.sh from inside a real herdr pane (as its own agent does) would
# otherwise leak this pane's real ids into every assertion instead of the
# pane-0/tab-0 the plan's assertions expect.
unset HERDR_PANE_ID HERDR_TAB_ID
# tower is the real CLI from this checkout (tests/stub/tower): its state and
# config stay in $TMP, never the user's.
export XDG_STATE_HOME="$LOOK_STATE/xdg-state" XDG_CONFIG_HOME="$TMP/xdg-config"
unset TOWER_RUN
# The credit probes' knobs (credits.sh, the codex stub's app-server; the
# claude probe reads nothing under a CLAUDE_CONFIG_DIR).
unset CREDITS_TIMEOUT CODEX_STUB_RATE_LIMITS CLAUDE_CONFIG_DIR
# Session roles (roles.sh): no launcher unless a test says so, whatever
# session test.sh is started from.
unset CLAUDE_ROUTER_ROLE CLAUDE_STUB_ROLE
# The runner: herdr (HERDR_ENV=1 above) unless a test, or <section>:orca, says Orca.
unset ORCA_CLI_COMMAND
# The repo contract's names and the run switches: the fixtures decide them,
# not the shell test.sh is started from (a codex lane exports EXECUTOR_KIND).
unset EXECUTOR_KIND EXECUTOR_MODEL SPEC_REVIEWER_MODEL QUALITY_REVIEWER_MODEL STALE PM TYPECHECK_TASK \
  CHECK_CMD INSTALL_CMD LANES TASK_REVIEW LANE_REVIEW PREFLIGHT STATIC_BASELINE PR METHOD \
  REVIEWER_KIND REVIEWER_MODEL REVIEW_AREAS SUITE_SKIP PR_TEMPLATE TRIAGE GUIDED_REVIEW NOTIFY
# The model defaults (model-defaults): the kit's file, never the calling shell's keys.
# shellcheck disable=SC2046  # the file's keys, one word each
unset CURSOR_STUB REVIEWER_BY_CREDITS CREDITS_FAKES MODEL_DEFAULTS_FILE $(sed -n 's/^\([A-Z_]*\)=.*/\1/p' "$KIT/model-defaults")
mkdir -p "$HERDR_STUB_STATES_DIR"

# Guard: every section below runs herdr/tower/claude/codex calls through common.sh's
# DRY_RUN PATH shim. If a stub is missing, not executable, or shadowed by
# something earlier on PATH, refuse outright rather than risk a script under
# test touching the real herdr or tower (this happened once: HERDR_ENV=1 is
# inherited from the orchestrating pane, so `need_runner` alone does not stop a
# script run outside test.sh and outside DRY_RUN=1 from driving real panes).
for _tool in herdr orca tower claude codex semgrep gitleaks cursor-agent; do
  _which=$(bash -c ". \"$KIT/common.sh\"; command -v $_tool" 2>/dev/null || true)
  [ "$_which" = "$KIT/tests/stub/$_tool" ] || { echo "test.sh: $_tool resolves to '$_which', not the stub ($KIT/tests/stub/$_tool) — refusing to run" >&2; exit 1; }
done
unset _tool _which
command -v bun >/dev/null || { echo "test.sh: tower runs from this checkout with bun, and bun is not on PATH — refusing to run" >&2; exit 1; }
command -v npm >/dev/null || { echo "test.sh: the look section runs npm scripts in its fixtures, and npm is not on PATH — refusing to run" >&2; exit 1; }
# More than one section: each runs as its own ./test.sh <section>, with its
# own $TMP, up to TEST_JOBS (the CPU count) at once; their output is printed
# in section order and their counts summed.
if [ -z "$ONLY" ] && [ "$LIST" = 0 ]; then
  OUT="$TMP/sections"; mkdir -p "$OUT"
  if [ "$FAST" = 1 ]; then sections=$("$ROOT/test.sh" --fast --list); else sections=$("$ROOT/test.sh" --list); fi
  case "${TEST_SHARD:-}" in
    "") ;;
    [1-9]*/[1-9]*) sections=$(printf '%s\n' "$sections" | awk -v i="${TEST_SHARD%/*}" -v n="${TEST_SHARD#*/}" '(NR - i) % n == 0') ;;
    *) echo "test.sh: TEST_SHARD is i/n, not $TEST_SHARD" >&2; exit 2 ;;
  esac
  # shellcheck disable=SC2016 # expanded by the sh xargs starts
  printf '%s\n' "$sections" | xargs -P "${TEST_JOBS:-$(getconf _NPROCESSORS_ONLN)}" -I{} \
    sh -c '"$0" "$2" > "$1/$2" 2>&1' "$ROOT/test.sh" "$OUT" {}
  for s in $sections; do
    summary=$(tail -n 1 "$OUT/$s")
    sed '$d' "$OUT/$s"
    # shellcheck disable=SC2086 # the summary's words
    case "$summary" in
      *" passed, "*" failed") set -- $summary; pass=$((pass+$1)); fail=$((fail+$3)) ;;
      *) bad "$s: the section ran to no summary" "$summary" ;;
    esac
  done
  echo "$pass passed, $fail failed"
  [ "$fail" = 0 ]; exit
fi
reset_stub() { : > "$HERDR_STUB_LOG"; rm -f "$HERDR_STUB_COUNTER" "$HERDR_STUB_COUNTER.busy" "$HERDR_STUB_COUNTER.enters" "$HERDR_STUB_COUNTER.trust" "$HERDR_STUB_COUNTER.started" "$HERDR_STUB_COUNTER.tabs" "$ORCA_STUB_COUNTER" "$ORCA_STUB_COUNTER.terminals" "$ORCA_STUB_COUNTER.worktrees"; }
# mkwt REPO BRANCH: REPO's worktree on BRANCH at REPO/.worktrees/BRANCH, as a
# runner's worktree create makes it (the stubs make none); kept if there.
mkwt() {
  local d="$1/.worktrees/$2"; [ -d "$d" ] && return 0
  git -C "$1" worktree prune
  if git -C "$1" show-ref --verify --quiet "refs/heads/$2"; then git -C "$1" worktree add -q "$d" "$2"
  else git -C "$1" worktree add -q -b "$2" "$d"; fi
}
# A new git repo built from tests/fixtures/<name> (or empty), named <name>, in
# a directory of its own: every call is a fresh repo, so tower's run pointer
# (in the repo's git dir) is never shared between two runs. Prints its path.
fixture_repo() {
  local d
  mkdir -p "$TMP/repos"; d="$(mktemp -d "$TMP/repos/XXXXXX")/$1"
  mkdir -p "$d"
  [ -d "$KIT/tests/fixtures/$1" ] && cp -R "$KIT/tests/fixtures/$1/." "$d/"
  git -C "$d" init -q && git -C "$d" commit -q --allow-empty -m init
  echo "$d"
}
in_kit() { bash -c ". \"\$KIT/common.sh\"; $1" 2>&1; }
# tower's state of a run: `board <run-dir> '<python expression over d>'`
# prints the expression, d being `tower state --json`.
board() { "$KIT/tests/stub/tower" state --json --run "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); print($2)"; }
# The run's notes, one per line.
notes() { board "$1" '"\n".join(e["event"]["text"] for e in d["transcript"] if e["event"]["kind"] == "note")'; }

# --- common ------------------------------------------------------------------
if section common; then
  assert_eq "tower_ok: a tower that runs is 0"   "$(in_kit 'tower_ok; echo $?')" 0
  assert_match "DRY_RUN: tower is this checkout's CLI" "$(in_kit 'tower --help')" 'tower theme rules \| new <name>'
  assert_match "DRY_RUN: ... with tower add"         "$(in_kit 'tower --help')" 'tower add "<title>"'
  ln -s "$KIT" "$TMP/kit-link"
  assert_eq "DRY_RUN: tower runs when the kit is reached through a link" "$(env -u KIT bash -c ". \"$TMP/kit-link/common.sh\"; tower_ok; echo \$?" 2>&1)" 0
  assert_eq "tower_ok: absent tower is 1"        "$(TOWER_STUB=absent in_kit 'tower_ok; echo $?')" 1
  assert_match "TOWER_POINTER: says how to install tower" "$(in_kit 'echo "$TOWER_POINTER"')" 'github\.com/phutschi/tower'
  assert_nomatch "TOWER_POINTER: names no version" "$(in_kit 'echo "$TOWER_POINTER"')" '[0-9]+\.[0-9]+'
  assert_match "need names the missing tool"     "$(in_kit 'need git nosuchtool')" "missing dependency: nosuchtool"
  # The fake orca is on PATH under DRY_RUN; ORCA_STUB_STATUS=fail or offline: Orca not reachable.
  in_orca() { env ORCA_CLI_COMMAND=orca "$@" bash -c ". \"\$KIT/common.sh\"; runner_detect" 2>&1; }
  assert_eq "runner_detect: herdr when HERDR_ENV=1 and herdr answers" "$(in_kit 'runner_detect')" herdr
  assert_eq "runner_detect: orca when ORCA_CLI_COMMAND is set, herdr is absent and orca status answers" "$(in_orca HERDR_ENV=0)" orca
  assert_eq "runner_detect: ... and when herdr does not answer" "$(in_orca HERDR_STUB=absent)" orca
  assert_eq "runner_detect: herdr when both herdr and Orca are present" "$(in_orca HERDR_ENV=1)" herdr
  out=$(in_orca HERDR_ENV=0 ORCA_STUB_STATUS=fail; echo "exit=$?")
  assert_match "runner_detect: Orca set but orca status fails, it says Orca is not reachable" "$out" "Orca is not reachable"
  assert_match "runner_detect: ... and fails" "$out" 'exit=1$'
  # The runner's functions load in need_runner alone: a RUNNER the caller's
  # shell exported is not loaded; detection alone picks the runner.
  assert_eq "common.sh: an inherited RUNNER is not loaded" "$(RUNNER=bogus in_kit 'echo loaded')" loaded
  assert_eq "common.sh: ... and no runner functions before need_runner" "$(in_kit 'type runner_name >/dev/null 2>&1 && echo some || echo none')" none
  # Orca's CLI is the one ORCA_CLI_COMMAND names (orca-ide, a path), for the
  # probe and every call; no orca on PATH is needed.
  mkdir -p "$TMP/orca-ide-bin"; printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$KIT/tests/stub/orca" > "$TMP/orca-ide-bin/orca-ide"; chmod +x "$TMP/orca-ide-bin/orca-ide"
  : > "$ORCA_STUB_LOG"
  out=$(env -u RUNNER DRY_RUN=0 HERDR_ENV=0 PATH="/usr/bin:/bin" ORCA_CLI_COMMAND="$TMP/orca-ide-bin/orca-ide" bash -c '. "$KIT/common.sh"; need_runner; echo "$RUNNER"; runner_self' 2>&1)
  assert_match "ORCA_CLI_COMMAND: the probe runs it" "$out" '^orca$'
  assert_match "ORCA_CLI_COMMAND: ... and so does every runner call" "$(cat "$ORCA_STUB_LOG")" '^orca worktree current --json$'
  # Under DRY_RUN the fake wins over an Orca session's real CLI.
  assert_eq "DRY_RUN: an inherited ORCA_CLI_COMMAND is replaced by the fake" "$(ORCA_CLI_COMMAND=/opt/orca/bin/orca in_kit 'echo "$ORCA_CLI_COMMAND"')" "$KIT/tests/stub/orca"
  # Orca's JSON answer can succeed while its runtime is down: reachable false.
  out=$(in_orca HERDR_ENV=0 ORCA_STUB_STATUS=offline; echo "exit=$?")
  assert_match "runner_detect: orca status answers reachable false: Orca is not reachable" "$out" "Orca is not reachable"
  assert_match "runner_detect: ... and fails" "$out" 'exit=1$'
  out=$(HERDR_ENV=0 in_kit 'runner_detect; echo "exit=$?"')
  assert_match "runner_detect: outside both it refuses, naming herdr, Orca and /tower:run" "$out" "needs herdr.*Orca.*/tower:run"
  assert_match "runner_detect: ... and fails" "$out" 'exit=1$'
  out=$(HERDR_STUB=absent in_kit 'runner_detect')
  assert_match "runner_detect: without a runnable herdr it refuses the same way" "$out" "needs herdr.*Orca.*/tower:run"
  assert_eq "need_runner: exports RUNNER" "$(in_kit 'need_runner; bash -c "echo \$RUNNER"')" herdr
  out=$(HERDR_ENV=0 in_kit 'need_runner; echo after')
  assert_nomatch "need_runner: outside both it stops the script" "$out" "^after$"
  for s in bootstrap add-lane add-reviewer watch-lanes; do
    assert_match "$s.sh: outside both it refuses, naming herdr, Orca and /tower:run" "$(HERDR_ENV=0 "$KIT/$s.sh" 2>&1)" "needs herdr.*Orca.*/tower:run"
    assert_match "$s.sh: in Orca it passes the runner check" "$(env ORCA_CLI_COMMAND=orca HERDR_ENV=0 "$KIT/$s.sh" 2>&1)" '^usage: '
  done
  # Only the runner files call herdr or orca; every other script goes through them
  # (a comment, or a message an echo or die prints, may name them).
  raw=$(cd "$ROOT" && grep -nE '(^|[;&|!{]|\$\(|(^|[[:space:]])(if|elif|until|while|then|do|else|exec|command|time) )[[:space:]]*(herdr|orca) ' skills/*/*.sh \
    | grep -v '^skills/orchestrate/runner[^/]*\.sh:' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(#|echo |die )' || true)
  assert_eq "no script but the runner files calls herdr or orca" "$raw" ""
  assert_match "DRY_RUN puts the stubs on PATH"  "$(in_kit 'command -v herdr')" "tests/stub/herdr$"
  reset_stub
  assert_eq "pane_id reads herdr's split answer" "$(in_kit 'herdr pane split --current | pane_id')" pane-1
  reset_stub
  assert_match "the stub logs argv"              "$(in_kit 'herdr pane run p1 "echo hi" >/dev/null; cat "$HERDR_STUB_LOG"')" '^herdr pane run p1 echo hi$'
  r=$(fixture_repo none)
  assert_eq "repo_root from a checkout"          "$(cd "$r" && in_kit 'repo_root')" "$r"
fi

# --- executor ----------------------------------------------------------------
if section executor; then
  name_in() { (cd "$1" && EXECUTOR_KIND=claude bash -c ". \"\$KIT/common.sh\"; . \"\$KIT/executor.sh\"; agent_name \"$2\"" 2>&1); }
  r=$(fixture_repo none)
  assert_eq "agent_name: <repo>-lane-a"            "$(name_in "$r" -lane-a)" "none-lane-a"
  wt="$r/.worktrees/some-branch"; mkdir -p "$wt"; git -C "$r" worktree add -q "$wt" -b some-branch
  assert_eq "agent_name: a worktree names the main checkout" "$(name_in "$wt" -lane-b)" "none-lane-b"
  long="$TMP/repos/My.Very_Long-Repository Name With Spaces"; mkdir -p "$long"; git -C "$long" init -q
  n=$(name_in "$long" -lane-a)
  assert_eq "agent_name: 32 characters at most"    "${#n}" 32
  assert_match "agent_name: lowercase, safe characters, suffix intact" "$n" '^[a-z][a-z0-9_-]*-lane-a$'
  digits="$TMP/repos/123-Repo"; mkdir -p "$digits"; git -C "$digits" init -q
  assert_eq "agent_name: starts with a letter"     "$(name_in "$digits" -lane-a)" "repo-lane-a"
  # HOME with a codex tdd skill, so executor.sh's missing-skill note stays out of the output.
  mkdir -p "$TMP/rev-home/.codex/skills/tdd"
  rev() { HOME="$TMP/rev-home" in_kit ". \"\$KIT/executor.sh\"; reviewer_for $1"; }
  T=$(printf '\t')
  assert_eq "reviewer: both kinds, a claude lane gets codex on gpt-6-astra" "$(rev claude)" "codex${T}gpt-6-astra${T}"
  assert_eq "reviewer: both kinds, a codex lane gets claude on claude-opus-5-5" "$(EXECUTOR_KIND=codex rev codex)" "claude${T}claude-opus-5-5${T}"
  assert_eq "reviewer: claude only, a claude lane gets claude on claude-fable-5-1 with a note" \
    "$(CODEX_STUB=absent rev claude)" "claude${T}claude-fable-5-1${T}fallback: codex is not installed, so claude reviews claude"
  assert_eq "reviewer: codex only, a codex lane gets codex on the executor's model with a note" \
    "$(CLAUDE_STUB=absent EXECUTOR_KIND=codex EXECUTOR_MODEL=gpt-6-astra-mini rev codex)" "codex${T}gpt-6-astra-mini${T}fallback: claude is not installed, so a fresh codex agent reviews codex"
  assert_eq "reviewer: a codex lane's own model beats EXECUTOR_MODEL in the fallback" \
    "$(CLAUDE_STUB=absent EXECUTOR_KIND=codex EXECUTOR_MODEL=x rev "codex lane-m")" "codex${T}lane-m${T}fallback: claude is not installed, so a fresh codex agent reviews codex"
  assert_eq "reviewer: a claude lane's model does not change its Reviewer" "$(CODEX_STUB=absent rev "claude lane-m")" "claude${T}claude-fable-5-1${T}fallback: codex is not installed, so claude reviews claude"
  assert_eq "reviewer: REVIEWER_KIND=claude forces its own kind on a claude lane" "$(REVIEWER_KIND=claude rev claude)" "claude${T}claude-fable-5-1${T}"
  assert_eq "reviewer: REVIEWER_KIND=codex on a codex lane"   "$(EXECUTOR_KIND=codex EXECUTOR_MODEL=gpt-6-astra-mini REVIEWER_KIND=codex rev codex)" "codex${T}gpt-6-astra-mini${T}"
  assert_eq "reviewer: REVIEWER_MODEL overrides the model"   "$(REVIEWER_MODEL=gpt-6-astra-pro rev claude)" "codex${T}gpt-6-astra-pro${T}"
  assert_eq "reviewer: REVIEWER_MODEL overrides a fallback's model" "$(CODEX_STUB=absent REVIEWER_MODEL=sonnet rev claude)" "claude${T}sonnet${T}fallback: codex is not installed, so claude reviews claude"
  assert_match "reviewer: a forced kind that is not installed is refused" "$(CODEX_STUB=absent REVIEWER_KIND=codex rev claude; echo "exit=$?")" "REVIEWER_KIND=codex, but codex is not installed"
  assert_match "reviewer: the refusal exits non-zero" "$(CODEX_STUB=absent REVIEWER_KIND=codex rev claude; echo "exit=$?")" "exit=1$"
  assert_match "reviewer: an unknown REVIEWER_KIND is refused" "$(REVIEWER_KIND=Claude rev claude)" "REVIEWER_KIND must be other, claude, codex or cursor \(got 'Claude'\)"
  assert_match "reviewer: no candidate and the lane's own kind absent: refused" "$(CODEX_STUB=absent CLAUDE_STUB=absent rev claude)" "no Reviewer for a claude lane: codex and claude are not installed \\(cursor reviews a claude lane only with REVIEWER_KIND=cursor\\)"
  if [ "${RUNNER:-herdr}" = orca ]; then
  # An agent start in Orca: `ostart KIND [ENV...]` opens terminal term-1 and
  # runs start_agent_with_trust_retry acme-lane-a in it, in repo $r. The
  # terminal's agent states are ORCA_STUB_STATES_DIR/term-1.
  S="$ORCA_STUB_STATES_DIR"
  ostart() { local k=$1; shift; reset_stub; (cd "$r" && env HOME="$TMP/rev-home" EXECUTOR_KIND="$k" "$@" bash -c ". \"\$KIT/common.sh\"; need_runner; orca terminal create --json >/dev/null; . \"\$KIT/executor.sh\"; start_agent_with_trust_retry acme-lane-a term-1; echo \"exit=\$?\"" 2>&1); }
  rm -f "$S"/term-*
  out=$(ostart claude EXECUTOR_MODEL=opus SESSION_ROLE=code SESSION_TOPIC=a-first)
  assert_match "orca claude start: exit 0" "$out" 'exit=0$'
  assert_match "orca claude start: typed into its terminal, with its model and session role" "$(cat "$ORCA_STUB_LOG")" '^orca terminal send --terminal term-1 --text claude --model opus --role code --topic a-first --enter --json$'
  out=$(ostart codex EXECUTOR_MODEL=gpt-6-astra)
  assert_match "orca codex start: as codex, with -m and its sandbox flags as in herdr" "$(cat "$ORCA_STUB_LOG")" '^orca terminal send --terminal term-1 --text codex -m gpt-6-astra -a never -s workspace-write .* -c check_for_update_on_startup=false( .*)? --enter --json$'
  out=$(ostart cursor EXECUTOR_MODEL=composer-2)
  assert_match "orca cursor start: as cursor-agent, with --model and --trust as in herdr" "$(cat "$ORCA_STUB_LOG")" '^orca terminal send --terminal term-1 --text cursor-agent --model composer-2 --trust --force --disable-auto-update .*--enter --json$'
  # Ready means Orca lists the agent as waiting or working: until then (an
  # agent that has not reported to Orca yet) the start waits.
  printf 'unlisted\nunlisted\nwaiting\n' > "$S/term-1"
  out=$(ostart claude)
  assert_match "orca: not yet listed: waited for" "$out" 'exit=0$'
  assert_eq "orca: not yet listed: read until it is" "$([ "$(grep -c '^orca agent list --json$' "$ORCA_STUB_LOG")" -ge 3 ] && echo yes)" yes
  echo unlisted > "$S/term-1"
  out=$(ostart claude READY_WAIT_SECONDS=2)
  assert_match "orca: never listed, its TUI busy: the start fails, saying so" "$out" 'acme-lane-a does not accept input in pane term-1 after 2 checks \(unknown\)'
  assert_match "orca: ... and how to see when it does, with orca" "$out" 'brief it once  "\$ORCA_CLI_COMMAND" agent list --json  shows it waiting or done'
  assert_nomatch "orca: ... naming no herdr command" "$out" 'herdr'
  # A wait Orca cannot answer (an RPC error, not an unsatisfied wait) says
  # nothing about the agent: unreadable.
  echo unlisted-waitfail > "$S/term-1"
  out=$(ostart claude READY_WAIT_SECONDS=2)
  assert_match "orca: not listed, its wait failing: Orca cannot say" "$out" 'Orca cannot say whether acme-lane-a runs in term-1 after 2 checks'
  for st in 'unlisted:unknown False' 'unlisted-waittimeout:unknown False' 'unlisted-waitfail:unreadable' 'unlisted-shell:shell False'; do
    rm -f "$S"/term-*; reset_stub; echo "${st%%:*}" > "$S/term-1"
    assert_eq "orca: one reading for an unlisted agent (${st%%:*})" "$(bash -c 'set -o pipefail; . "$KIT/common.sh"; need_runner; orca terminal create --json >/dev/null; runner_agent_state acme-lane-a term-1' 2>&1)" "${st#*:}"
  done
  # Idle and unlisted, it is ready only on positive evidence, the agent's
  # footer words: a screen Orca cannot render, or one showing neither the
  # agent nor a shell, is not known yet; a bare % or $ prompt is a shell.
  ostate() { rm -f "$S"/term-*; reset_stub; echo unlisted-idle > "$S/term-1"; [ -z "$1" ] || printf '%s\n' "$1" > "$S/term-1.tail"; shift
    env "$@" bash -c 'set -o pipefail; . "$KIT/common.sh"; need_runner; orca terminal create --json >/dev/null; runner_agent_state acme-lane-a term-1' 2>&1; }
  assert_eq "orca: unlisted and idle, no rendered screen: not known yet" "$(ostate "" ORCA_STUB_SCREEN=unavailable)" "unknown False"
  assert_eq "orca: unlisted and idle, neither agent nor shell on screen: not known yet" "$(ostate "Loading...")" "unknown False"
  assert_eq "orca: unlisted and idle, a bare % prompt: a shell" "$(ostate "%")" "shell False"
  assert_eq "orca: unlisted and idle, a bare \$ prompt: a shell" "$(ostate '$')" "shell False"
  rm -f "$S"/term-*
  echo unlisted-idle > "$S/term-1"
  out=$(ostart claude READY_WAIT_SECONDS=2 START_TRIES=2 ORCA_STUB_SCREEN=unavailable)
  assert_match "orca: unlisted, idle, no rendered screen: the start stays pending" "$out" 'acme-lane-a does not accept input in pane term-1 after 2 checks \(unknown\)'
  assert_match "orca: ... and fails" "$out" 'exit=1$'
  # The agent's footer words win over a last line shaped like a prompt (a
  # status line under its input box): an agent, not a shell.
  rm -f "$S"/term-*; reset_stub; echo unlisted-idle > "$S/term-1"
  printf '> \n  ? for shortcuts\n  acme git:(main)  Opus 5.5 ❯\n' > "$S/term-1.tail"
  assert_eq "orca: footer words beat a prompt-shaped last line: ready" "$(bash -c '. "$KIT/common.sh"; need_runner; orca terminal create --json >/dev/null; runner_agent_state acme-lane-a term-1; orca_screen_shows_agent term-1 && echo agent' 2>&1)" "idle True
agent"
  # Unlisted at the send's first read, then listed done at a bare shell (an
  # agent that exited): the screen must show the agent, so nothing is sent.
  rm -f "$S"/term-*; reset_stub; printf 'unlisted\ndone-shell\n' > "$S/term-1"
  out=$(bash -c '. "$KIT/common.sh"; need_runner; orca terminal create --json >/dev/null; runner_send_message acme-lane-a term-1 "echo hi"; echo "rc=$?"' 2>&1)
  assert_match "orca: unlisted, then done at a bare shell: held" "$out" 'rc=1$'
  assert_match "orca: ... saying its screen does not show the agent" "$out" "terminal term-1's screen does not show the agent"
  assert_nomatch "orca: ... nothing sent" "$(cat "$ORCA_STUB_LOG")" '^orca terminal send '
  rm -f "$S"/term-*
  # A bare shell is no ready agent: a launch that left one (refused, or an
  # agent that exited) fails the start, saying so.
  echo unlisted-shell > "$S/term-1"
  out=$(ostart claude READY_WAIT_SECONDS=2 START_TRIES=2)
  assert_match "orca: a bare shell after the launch: the start fails" "$out" 'exit=1$'
  assert_match "orca: ... saying its terminal shows a shell" "$out" "acme-lane-a's terminal term-1 shows a shell, not the agent"
  rm -f "$S"/term-*
  # Not listed yet (a terminal agent reports on its first turn), but its TUI
  # is idle: it accepts input.
  echo unlisted-idle > "$S/term-1"
  out=$(ostart codex)
  assert_match "orca: not listed, its TUI idle: ready" "$out" 'exit=0$'
  assert_match "orca: ... asked of its terminal" "$(cat "$ORCA_STUB_LOG")" '^orca terminal wait --terminal term-1 --for tui-idle --timeout-ms [0-9]+ --json$'
  rm -f "$S"/term-*
  # A trust menu at start (the agent blocked, text-plus-Enter refused):
  # answered with separate sends, Down then Enter for claude, Enter for codex.
  printf 'unlisted\nunlisted\ntrust\ntrust\nwaiting\n' > "$S/term-1"
  out=$(ostart claude)
  log=$(cat "$ORCA_STUB_LOG")
  assert_match "orca trust: the start goes on" "$out" 'exit=0$'
  assert_match "orca trust: Down sent alone" "$log" $'^orca terminal send --terminal term-1 --text \e\\[B --json$'
  assert_match "orca trust: ... then Enter alone" "$log" '^orca terminal send --terminal term-1 --enter --json$'
  assert_eq "orca trust: the agent is not started twice" "$(grep -c '^orca terminal send --terminal term-1 --text claude' "$ORCA_STUB_LOG")" 1
  printf 'unlisted\nunlisted\ntrust\ntrust\nwaiting\n' > "$S/term-1"
  out=$(ostart codex)
  assert_match "orca trust, codex: Orca's trust reason, answered" "$out" 'exit=0$'
  assert_nomatch "orca trust, codex: no Down" "$(cat "$ORCA_STUB_LOG")" 'B --json$'
  assert_match "orca trust, codex: Enter alone" "$(cat "$ORCA_STUB_LOG")" '^orca terminal send --terminal term-1 --enter --json$'
  # A trust menu before Orca lists the agent (its TUI idle, so it would read
  # ready): Orca's wait reason names it, so it is blocked, and answered.
  rm -f "$S"/term-*
  printf 'unlisted-trust\nunlisted-trust\nunlisted-trust\nwaiting\n' > "$S/term-1"
  out=$(ostart codex)
  assert_match "orca trust, not listed yet: the start goes on" "$out" 'exit=0$'
  assert_match "orca trust, not listed yet: answered with Enter alone" "$(cat "$ORCA_STUB_LOG")" '^orca terminal send --terminal term-1 --enter --json$'
  # A launch whose record cannot be written: the agent runs, unreachable by
  # send-brief; the start fails, naming the recovery that starts nothing.
  rm -f "$S"/term-*; mkdir -p "$TMP/rec-run"; rec=$(in_kit "launch_record '$TMP/rec-run'"); mkdir -p "$rec"
  out=$(ostart claude RUN_DIR="$TMP/rec-run")
  assert_match "orca: a launch record that cannot be written: the start fails" "$out" 'exit=1$'
  assert_match "orca: ... saying the agent was launched, and how to record it" "$out" "acme-lane-a was launched in term-1, but the kit could not record it, so no brief reaches it yet: .*bind-pane\\.sh $TMP/rec-run acme-lane-a term-1  \\(it starts nothing\\)"
  assert_eq "orca: ... launched once" "$(grep -c '^orca terminal send --terminal term-1 --text claude' "$ORCA_STUB_LOG")" 1
  # The record failing beside a runner failure keeps the runner's code: a
  # launch with no receipt stays 4 (look first), and says it may not have
  # arrived; a trust prompt is still answered, and the start then fails,
  # saying how to record the agent.
  rm -f "$S"/term-*
  out=$(ostart claude RUN_DIR="$TMP/rec-run" ORCA_STUB_SEND_FAIL=unknown)
  assert_match "orca: no receipt and no record: still 4" "$out" 'exit=4$'
  assert_match "orca: ... saying the launch may not have arrived, and how to record it" "$out" "Orca cannot say whether acme-lane-a's launch reached term-1 \\(no receipt\\), and the kit could not record it either: look at that terminal; once you have seen the agent there, record it with  .*bind-pane\\.sh $TMP/rec-run acme-lane-a term-1  \\(it starts nothing\\)"
  assert_nomatch "orca: ... never that it was launched" "$out" 'was launched'
  rm -f "$S"/term-*; printf 'unlisted\nunlisted\ntrust\ntrust\nwaiting\n' > "$S/term-1"
  out=$(ostart claude RUN_DIR="$TMP/rec-run")
  assert_match "orca: a trust prompt and no record: the prompt answered" "$(cat "$ORCA_STUB_LOG")" '^orca terminal send --terminal term-1 --enter --json$'
  assert_match "orca: ... then the start fails" "$out" 'exit=1$'
  assert_match "orca: ... saying how to record it" "$out" "acme-lane-a runs in term-1 now its trust prompt is answered, but the kit could not record it, so no brief reaches it yet: record it with  .*bind-pane\\.sh $TMP/rec-run acme-lane-a term-1  \\(it starts nothing\\)"
  assert_eq "orca: ... launched once" "$(grep -c '^orca terminal send --terminal term-1 --text claude' "$ORCA_STUB_LOG")" 1
  rmdir "$rec"
  # launch_line prints a start's command for a person: its words split back
  # into the same arguments, TOML quotes and all.
  ll=$(cd "$r" && env HOME="$TMP/rev-home" EXECUTOR_KIND=codex EXECUTOR_MODEL=gpt-6-astra RUN_DIR="$TMP/run x" AGENT_TMP="$TMP/t \"q\"" bash -c '. "$KIT/common.sh"; need_runner; . "$KIT/executor.sh"; launch_line' 2>&1)
  assert_eq "launch_line: the CLI and model first" "$(eval "set -- $ll"; echo "$1 $2 $3")" "codex -m gpt-6-astra"
  assert_match "launch_line: a grant with a space and quotes survives the round trip" "$(eval "set -- $ll"; printf '%s\n' "$@")" "^shell_environment_policy.set.TMPDIR=\"$TMP/t \\\\\"q\\\\\"\"\$"
  # The start's return code says what was sent: 3, Orca refused the launch
  # line (nothing typed); 4, Orca took it without a receipt (unknown); any
  # other failure, it may have been typed.
  rcstart() { reset_stub; (cd "$r" && env HOME="$TMP/rev-home" EXECUTOR_KIND=claude "$@" bash -c '. "$KIT/common.sh"; need_runner; orca terminal create --json >/dev/null; . "$KIT/executor.sh"; start_agent_with_trust_retry acme-lane-a term-1; echo "rc=$?"' 2>&1 | tail -1); }
  rm -f "$S"/term-*; printf 'unlisted\nblocked\n' > "$S/term-1"
  assert_eq "orca: a launch sent, then failed: neither 3 nor 4" "$(rcstart)" rc=1
  rm -f "$S"/term-*; assert_eq "orca: a launch Orca refused: 3" "$(rcstart ORCA_STUB_SEND_FAIL=refused)" rc=3
  rm -f "$S"/term-*; assert_eq "orca: a launch with no receipt: 4" "$(rcstart ORCA_STUB_SEND_FAIL=unknown)" rc=4
  rm -f "$S"/term-*; assert_eq "orca: a lost reply (runtime_unavailable) proves nothing: 4" "$(rcstart ORCA_STUB_SEND_FAIL=1)" rc=4
  # The start's result is its return code, never words in Orca's answer: a
  # lost reply whose message and echoed command hold busy and trust words is
  # a launch with no receipt, with no retry and no trust keys.
  rm -f "$S"/term-*; assert_eq "orca: busy and trust words in a no-receipt error: still 4" "$(rcstart ORCA_STUB_SEND_FAIL=echo)" rc=4
  assert_eq "orca: ... the launch typed once" "$(grep -c '^orca terminal send --terminal term-1 --text claude' "$ORCA_STUB_LOG")" 1
  assert_nomatch "orca: ... and no trust keys" "$(cat "$ORCA_STUB_LOG")" '^orca terminal send --terminal term-1 (--enter|--text .\[B)'
  # A launch line goes to a shell, which gives no delivery receipt: the agent's
  # own state says whether it started.
  rm -f "$S"/term-*; assert_eq "orca: a launch taken with no delivery receipt: read by the agent's state" "$(rcstart ORCA_STUB_SEND_WARN=unsupported)" rc=0
  # Blocked on any other prompt (a hooks review, an update): no keys, the
  # start fails, and the prompt stays for the operator. The trust prompt is
  # known by Orca's own wait reason: an answered trust question still on the
  # screen above the hooks-review menu changes nothing.
  rm -f "$S"/term-*
  printf 'unlisted\nblocked\n' > "$S/term-1"
  printf 'Do you trust the files in this folder?\n 2. Yes, I trust this folder\nHooks changed since you last ran: review them?\n> 1. Yes\n  2. No\n' > "$S/term-1.tail"
  out=$(ostart claude)
  assert_match "orca blocked, not the trust menu: the start fails" "$out" 'exit=1$'
  assert_match "orca blocked, not the trust menu: ... saying to answer it in its terminal" "$out" 'acme-lane-a is blocked on a prompt in terminal term-1 that Orca does not report as the workspace trust prompt: answer it there'
  assert_nomatch "orca blocked, not the trust menu: ... and sends no keys" "$(cat "$ORCA_STUB_LOG")" '^orca terminal send --terminal term-1 (--enter|--text .\[B)'
  echo done > "$S/term-1"
  out=$(ostart claude)
  assert_match "orca: done (a finished turn) is ready for input" "$out" 'exit=0$'
  echo gone > "$S/term-1"
  out=$(ostart claude)
  assert_match "orca: a closed terminal: the start fails with Orca's error" "$out" 'terminal_handle_stale'
  rm -f "$S"/term-*
  out=$(ostart claude CLAUDE_STUB=absent)
  assert_match "orca: claude not installed: the start fails, nothing sent (3)" "$out" 'exit=3$'
  assert_match "orca: ... naming the missing CLI" "$out" 'claude is not installed'
  assert_nomatch "orca: ... and typing nothing" "$(cat "$ORCA_STUB_LOG")" '^orca terminal send '
  out=$(ostart cursor CURSOR_STUB=absent)
  assert_match "orca: cursor-agent not installed: named" "$out" 'cursor-agent is not installed'
  else
    # An agent start: `start NAME [ENV...]` runs start_agent_with_trust_retry
    # for NAME in pane-9 of a codex executor, in repo $r.
    start() { local n=$1; shift; reset_stub; (cd "$r" && env HOME="$TMP/rev-home" EXECUTOR_KIND=codex "$@" bash -c ". \"\$KIT/common.sh\"; need_runner; . \"\$KIT/executor.sh\"; start_agent_with_trust_retry $n pane-9; echo \"exit=\$?\"" 2>&1); }
    out=$(start acme-lane-a)
    assert_match "codex start: its startup update check is off" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start acme-lane-a --kind codex --pane pane-9 -- .* -c check_for_update_on_startup=false( |$)'
    out=$(start acme-lane-a 'AGENT_TMP=/run/it"s \tmp')
    assert_match "AGENT_TMP: a TOML string, quote and backslash escaped" "$(cat "$HERDR_STUB_LOG")" '-c shell_environment_policy\.set\.TMPDIR="/run/it\\"s \\\\tmp"'
    # A codex lane in a worktree may write only what its commits need in the
    # common git dir, never its hooks or config (#10); lane A in the main
    # checkout keeps the whole common dir, as its index and HEAD live there.
    C=$(git -C "$r" rev-parse --path-format=absolute --git-common-dir)
    start_in() { local d=$1; shift; reset_stub; (cd "$d" && env HOME="$TMP/rev-home" EXECUTOR_KIND=codex RUN_DIR=/run/x "$@" bash -c ". \"\$KIT/common.sh\"; need_runner; . \"\$KIT/executor.sh\"; start_agent_with_trust_retry acme-lane-b pane-9" >/dev/null 2>&1); cat "$HERDR_STUB_LOG"; }
    log=$(start_in "$wt")
    assert_match "codex worktree lane: writes only objects, refs, logs, packed-refs and its own git dir" "$log" \
      "^herdr agent start acme-lane-b .* -c sandbox_workspace_write\\.writable_roots=\\[\"/run/x\",\"$C/objects\",\"$C/refs\",\"$C/logs\",\"$C/packed-refs\",\"$C/packed-refs\\.lock\",\"$C/packed-refs\\.new\",\"$C/worktrees/some-branch\"\\]( |\$)"
    assert_nomatch "codex worktree lane: not the whole common git dir" "$log" "--add-dir $C( |\$)"
    assert_match "codex worktree lane: the run dir still added" "$log" "--add-dir /run/x( |\$)"
    log=$(start_in "$r")
    assert_match "codex lane in the main checkout: the whole common git dir" "$log" "--add-dir $C( |\$)"
    assert_nomatch "codex lane in the main checkout: no narrowed roots" "$log" 'writable_roots'
    # AGENT_LOOK (add-reviewer.sh sets it for a codex Reviewer, and only then)
    # is one more writable dir, beside the grants above.
    log=$(start_in "$r" AGENT_LOOK=/state/look)
    assert_match "AGENT_LOOK in the main checkout: added as a dir" "$log" "--add-dir /state/look( |\$)"
    log=$(start_in "$wt" AGENT_LOOK=/state/look)
    assert_match "AGENT_LOOK in a worktree: one of the writable roots" "$log" 'writable_roots=\[.*"/state/look".*\]'
    log=$(start_in "$r" AGENT_LOOK=/state/look)
    assert_match "AGENT_LOOK: the run dir reaches look as TOWER_RUN" "$log" '-c shell_environment_policy\.set\.TOWER_RUN="/run/x"( |$)'
    log=$(start_in "$r")
    assert_nomatch "no AGENT_LOOK: no look dir" "$log" 'state/look'
    assert_nomatch "no AGENT_LOOK: no TOWER_RUN" "$log" 'TOWER_RUN'
    # An agent that exits right after its start (codex updating itself, say)
    # is started once more; gone again, the start fails, saying so.
    printf 'gone\nidle\n' > "$HERDR_STUB_STATES_DIR/acme-lane-a.started"
    out=$(start acme-lane-a)
    assert_eq "gone after its start: started once more" "$(grep -c '^herdr agent start acme-lane-a ' "$HERDR_STUB_LOG")" 2
    assert_match "gone after its start: ... then it runs" "$out" 'exit=0$'
    assert_match "gone after its start: ... saying so" "$out" 'acme-lane-a exited right after its start in pane pane-9; starting it once more'
    echo gone > "$HERDR_STUB_STATES_DIR/acme-lane-a.started"
    out=$(start acme-lane-a)
    assert_eq "gone twice: no third start" "$(grep -c '^herdr agent start acme-lane-a ' "$HERDR_STUB_LOG")" 2
    assert_match "gone twice: the start fails" "$out" 'exit=1$'
    assert_match "gone twice: ... saying so" "$out" 'acme-lane-a exited again after it was started once more in pane pane-9'
    # The trust prompt answered, the agent reads working, then it exits: it is
    # started once more.
    rm -f "$HERDR_STUB_STATES_DIR/acme-lane-a.started"; printf 'working\ngone\n' > "$HERDR_STUB_STATES_DIR/acme-lane-a"
    out=$(start acme-lane-a HERDR_STUB_TRUST_STARTS=1)
    assert_eq "trust answered, then gone: started once more" "$(grep -c '^herdr agent start acme-lane-a ' "$HERDR_STUB_LOG")" 2
    assert_match "trust answered, then gone: ... then it runs" "$out" 'exit=0$'
    # A trust prompt left to the operator (its keys not sent) while the
    # record cannot be written: both said, with how to record the agent.
    mkdir -p "$TMP/rec-run-h"; rech=$(in_kit "launch_record '$TMP/rec-run-h'"); mkdir -p "$rech"; rm -f "$HERDR_STUB_STATES_DIR"/acme-lane-a*
    out=$(start acme-lane-a HERDR_STUB_TRUST_STARTS=1 HERDR_STUB_SEND_KEYS_FAIL=1 RUN_DIR="$TMP/rec-run-h")
    assert_match "trust left to the operator, no record: says to answer it" "$out" "could not answer acme-lane-a's trust prompt in pane pane-9"
    assert_match "trust left to the operator, no record: ... and how to record the agent" "$out" "the kit could not record acme-lane-a in pane-9 either, so no brief reaches it yet: once it runs there, record it with  .*bind-pane\\.sh $TMP/rec-run-h acme-lane-a pane-9  \\(it starts nothing\\)"
    assert_match "trust left to the operator, no record: fails" "$out" 'exit=1$'
    rmdir "$rech"
    # Ready means accepting input: herdr's interactive_ready. Until then the
    # start waits (READY_WAIT_SECONDS checks), and fails when it never comes.
    rm -f "$HERDR_STUB_STATES_DIR"/acme-lane-a*; echo "unready unready idle" > "$HERDR_STUB_STATES_DIR/acme-lane-a.started"
    out=$(start acme-lane-a)
    assert_match "not yet accepting input: waited for" "$out" 'exit=0$'
    assert_eq "not yet accepting input: read until it does" "$(grep -c '^herdr agent get acme-lane-a$' "$HERDR_STUB_LOG")" 3
    assert_eq "not yet accepting input: not started again" "$(grep -c '^herdr agent start acme-lane-a ' "$HERDR_STUB_LOG")" 1
    echo unready > "$HERDR_STUB_STATES_DIR/acme-lane-a.started"
    out=$(start acme-lane-a READY_WAIT_SECONDS=3)
    assert_match "never accepting input: the start fails" "$out" 'exit=1$'
    assert_match "never accepting input: ... saying so" "$out" 'acme-lane-a does not accept input in pane pane-9 after 3 checks \(idle, not ready for input\)'
    assert_eq "never accepting input: READY_WAIT_SECONDS checks" "$(grep -c '^herdr agent get acme-lane-a$' "$HERDR_STUB_LOG")" 3
    echo blocked > "$HERDR_STUB_STATES_DIR/acme-lane-a.started"
    out=$(start acme-lane-a READY_WAIT_SECONDS=2)
    assert_match "blocked after its start: fails, naming the state" "$out" 'acme-lane-a does not accept input in pane pane-9 after 2 checks \(blocked\)'
    echo unreachable > "$HERDR_STUB_STATES_DIR/acme-lane-a.started"
    out=$(start acme-lane-a READY_WAIT_SECONDS=2)
    assert_match "herdr failing after the start: fails, saying herdr cannot tell" "$out" 'herdr cannot say whether acme-lane-a runs in pane-9 after 2 checks$'
    assert_nomatch "herdr failing after the start: not said to be running" "$out" 'left running'
    # An older herdr answers without interactive_ready: idle is then ready.
    echo legacy > "$HERDR_STUB_STATES_DIR/acme-lane-a.started"
    out=$(start acme-lane-a READY_WAIT_SECONDS=2)
    assert_match "no interactive_ready (an older herdr): idle is ready" "$out" 'exit=0$'
    assert_eq "no interactive_ready: one read" "$(grep -c '^herdr agent get acme-lane-a$' "$HERDR_STUB_LOG")" 1
    # Started once more after an exit, and then never accepting input: that fails.
    printf 'gone\nunready\n' > "$HERDR_STUB_STATES_DIR/acme-lane-a.started"
    out=$(start acme-lane-a READY_WAIT_SECONDS=2)
    assert_eq "gone, then never ready: two starts" "$(grep -c '^herdr agent start acme-lane-a ' "$HERDR_STUB_LOG")" 2
    assert_match "gone, then never ready: fails" "$out" 'exit=1$'
    assert_match "gone, then never ready: says it does not accept input" "$out" 'acme-lane-a does not accept input in pane pane-9 after 2 checks'
    assert_match "never ready: says the agent is left running" "$out" 'left running in pane-9: brief it once  herdr agent get acme-lane-a  shows interactive_ready true, or end it'
    rm -f "$HERDR_STUB_STATES_DIR"/acme-lane-a*
  fi
fi

# --- detect ------------------------------------------------------------------
if section detect; then
  detect_in() { (cd "$1" && bash -c ". \"\$KIT/common.sh\"; . \"\$KIT/detect-stack.sh\"; $2" 2>&1); }
  r=$(fixture_repo bun-vitest)
  assert_eq "detect: bun from bun.lock"              "$(detect_in "$r" 'echo $PM')" bun
  assert_eq "detect: check gate = typecheck && test" "$(detect_in "$r" 'echo "$CHECK_CMD"')" "bun run typecheck && bun run test"
  assert_eq "detect: no pane by default (no checks pane, no dev)" "$(detect_in "$r" 'echo ${#PANE_NAMES[@]}')" 0
  assert_eq "detect: CHECK_CMD from the environment wins" "$(CHECK_CMD='make it' detect_in "$r" 'echo "$CHECK_CMD"')" "make it"
  r=$(fixture_repo pnpm-notest)
  assert_eq "detect: check-types, no test script"   "$(detect_in "$r" 'echo "$CHECK_CMD"')" "pnpm run check-types"
  assert_nomatch "detect: no runner, no note" "$(detect_in "$r" 'true')" "no test runner detected"
  printf 'pane checks "make test"\n' > "$r/.orchestrate"
  assert_eq "detect: a pane checks line is accepted, and places no pane" "$(detect_in "$r" 'echo ${#PANE_NAMES[@]}' 2>/dev/null | tail -1)" 0
  assert_eq "detect: ... with one info: line that it is ignored" "$(detect_in "$r" 'true' | grep -c '^info: \.orchestrate: pane checks is ignored: the checks pane is gone')" 1
  rm "$r/.orchestrate"
  assert_eq "install: the package manager's install with a package.json" "$(detect_in "$(fixture_repo bun-vitest)" 'echo "$INSTALL_CMD"')" "bun install"
  assert_eq "install: none without a package.json"  "$(detect_in "$(fixture_repo none)" 'echo "[$INSTALL_CMD]"')" "[]"
  ir="$TMP/repos/install-contract"; mkdir -p "$ir"; echo 'INSTALL_CMD="make deps"' > "$ir/.orchestrate"
  assert_eq "install: INSTALL_CMD from the repo contract" "$(detect_in "$ir" 'echo "$INSTALL_CMD"')" "make deps"
  assert_nomatch "install: INSTALL_CMD is a setting the kit reads" "$(detect_in "$ir" 'true')" "not a setting"
  or_="$TMP/repos/old-contract"; mkdir -p "$or_"; echo 'INSTALL_CMD="make old"' > "$or_/.herdr-orchestrate"
  assert_eq "contract: the old name .herdr-orchestrate is still read" "$(detect_in "$or_" 'echo "$INSTALL_CMD"' 2>/dev/null | tail -1)" "make old"
  assert_match "contract: ... with a note to rename it" "$(detect_in "$or_" 'true')" 'rename \.herdr-orchestrate to \.orchestrate'
  echo 'INSTALL_CMD="make new"' > "$or_/.orchestrate"
  assert_eq "contract: .orchestrate wins over the old name" "$(detect_in "$or_" 'echo "$INSTALL_CMD"')" "make new"
  assert_eq "install: the environment wins over the file" "$(INSTALL_CMD='make all' detect_in "$ir" 'echo "$INSTALL_CMD"')" "make all"
  assert_eq "install: the environment wins, even empty" "$(INSTALL_CMD='' detect_in "$ir" 'echo "[$INSTALL_CMD]"')" "[]"
  r=$(fixture_repo contract)
  assert_eq "contract: CHECK_CMD"                   "$(detect_in "$r" 'echo "$CHECK_CMD"')" "make check"
  assert_eq "contract: panes in order with dirs"    "$(detect_in "$r" 'echo "${PANE_NAMES[*]}|${PANE_CMDS[0]}|${PANE_DIRS[0]}"')" "dev|make dev|web"
  assert_eq "contract: harness, models and stale"   "$(detect_in "$r" 'echo "$EXECUTOR_KIND $EXECUTOR_MODEL $SPEC_REVIEWER_MODEL $QUALITY_REVIEWER_MODEL $STALE"')" "codex gpt-6-astra-mini haiku sonnet 45"
  assert_eq "contract: the environment wins over the file" "$(EXECUTOR_KIND=claude STALE=5 detect_in "$r" 'echo "$EXECUTOR_KIND $STALE $EXECUTOR_MODEL"')" "claude 5 gpt-6-astra-mini"
  assert_match "contract: an unknown setting is named" "$(detect_in "$(fixture_repo contract-typo)" 'echo reached')" "'MODEL' is not a setting"
  assert_match "contract: an unknown setting does not stop the script" "$(detect_in "$(fixture_repo contract-typo)" 'echo reached')" "^reached$"
  RUNC="$TMP/run-contract"; reset_stub
  (cd "$r" && "$KIT/bootstrap.sh" "$RUNC" "Contract" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
  assert_eq "contract: bootstrap records the file's models" "$(board "$RUNC" '" ".join(k+"="+v for k,v in sorted(d["run"]["models"].items()))')" "implementer=gpt-6-astra-mini quality-reviewer=sonnet spec-reviewer=haiku"
  assert_match "contract: lane A is codex"          "$(cat "$RUNC/panes.txt")" '^lane A: .*kind codex, .*model gpt-6-astra-mini, tab lanes\)'
  assert_match "contract: console stale from the file" "$(cat "$HERDR_STUB_LOG")" '^herdr pane run pane-1 tower --stale 45$'
  reset_stub; out=$(cd "$r" && EXECUTOR_KIND=claude "$KIT/add-lane.sh" "$RUNC" B feat/b main 2 2>&1)
  assert_match "contract: add-lane env overrides the file's kind" "$(cat "$RUNC/panes.txt")" '^lane B: .*kind claude, .*model gpt-6-astra-mini, tab lanes\)'
  r=$(fixture_repo none)
  assert_eq "switches: defaults when neither file nor environment sets them" \
    "$(detect_in "$r" 'switches_line')" \
    "TASK_REVIEW=on LANE_REVIEW=off PREFLIGHT=on STATIC_BASELINE=on PR=draft METHOD=tdd REVIEWER_KIND=other REVIEWER_MODEL= REVIEWER_BY_CREDITS=off REVIEWER_CREDITS_MIN=20 REVIEW_AREAS= SUITE_SKIP= PR_TEMPLATE= TRIAGE=ask GUIDED_REVIEW=off NOTIFY="
  r=$(fixture_repo contract-switches)
  assert_eq "switches: the file's values are used" \
    "$(detect_in "$r" 'switches_line')" \
    "TASK_REVIEW=off LANE_REVIEW=off PREFLIGHT=off STATIC_BASELINE=off PR=ready METHOD=plain REVIEWER_KIND=claude REVIEWER_MODEL=claude-fable-5-1 REVIEWER_BY_CREDITS=off REVIEWER_CREDITS_MIN=20 REVIEW_AREAS=security,spec SUITE_SKIP=build PR_TEMPLATE=.github/pull_request_template.md TRIAGE=auto GUIDED_REVIEW=on NOTIFY="
  assert_eq "switches: the environment wins over the file" \
    "$(PR=off METHOD=tdd SUITE_SKIP=lint,test REVIEWER_KIND=codex TRIAGE=ask detect_in "$r" 'echo "$PR $METHOD $SUITE_SKIP $REVIEWER_KIND $TASK_REVIEW $TRIAGE"')" \
    "off tdd lint,test codex off ask"
  assert_nomatch "switches: not reported as unknown settings" "$(detect_in "$r" 'true')" "not a setting the kit reads"
  assert_eq "switches: an environment value with spaces wins whole" \
    "$(CHECK_CMD='make it all' PR_TEMPLATE='my template.md' detect_in "$r" 'echo "$CHECK_CMD|$PR_TEMPLATE"')" "make it all|my template.md"
  assert_eq "suite: steps in contract order, DIR defaulting to ." \
    "$(detect_in "$r" 'for i in 0 1 2; do printf "%s|%s|%s;" "${SUITE_NAMES[$i]}" "${SUITE_CMDS[$i]}" "${SUITE_DIRS[$i]}"; done')" \
    "lint|make lint|.;test|make test|pkg/core;build|make build|.;"
  assert_match "this repo's contract: the check gate runs tower's check, the fast tests and shellcheck" "$(detect_in "$ROOT" 'echo "$CHECK_CMD"')" '^bun run check && \./test\.sh --fast && shellcheck '
  assert_eq "this repo's contract: the full suite is tower's check, every test, then shellcheck" "$(detect_in "$ROOT" 'echo "${SUITE_NAMES[*]}|${SUITE_CMDS[0]}|${SUITE_CMDS[1]}|${SUITE_CMDS[2]}"')" "check tests shellcheck|bun run check|./test.sh|shellcheck -S warning *.sh skills/*/*.sh skills/orchestrate/tests/stub/*"
  assert_nomatch "this repo's contract: no pane checks line, no unknown settings" "$(detect_in "$ROOT" 'true')" 'pane checks is ignored|not a setting'
  assert_eq "suite: none without suite lines" "$(detect_in "$(fixture_repo none)" 'echo ${#SUITE_NAMES[@]}')" 0
  r=$(fixture_repo contract-switches-bad)
  assert_match "switches: a bad value is refused with the allowed values" "$(detect_in "$r" 'echo reached')" "PR must be draft, ready or off \(got 'maybe'\)"
  assert_nomatch "switches: the refusal stops the script" "$(detect_in "$r" 'echo reached')" "^reached$"
  assert_match "switches: METHOD=fast is refused"          "$(METHOD=fast detect_in "$(fixture_repo none)" 'true')" "METHOD must be tdd or plain \(got 'fast'\)"
  assert_match "switches: an unknown REVIEWER_KIND is refused" "$(REVIEWER_KIND=gemini detect_in "$(fixture_repo none)" 'true')" "REVIEWER_KIND must be other, claude, codex or cursor \(got 'gemini'\)"
  assert_match "switches: a value on two lines is refused" "$(PR_TEMPLATE=$'a\nb' detect_in "$(fixture_repo none)" 'true')" "PR_TEMPLATE must be one line"
  assert_match "switches: NOTIFY on two lines is refused" "$(NOTIFY=$'a\nb' detect_in "$(fixture_repo none)" 'true')" "NOTIFY must be one line"
  nr="$TMP/repos/repo-notify"; mkdir -p "$nr"; echo 'NOTIFY="~/bin/notify --repo"' > "$nr/.orchestrate"
  assert_match "switches: a repo contract's NOTIFY is named" "$(detect_in "$nr" 'true')" "^\.orchestrate: 'NOTIFY' is a user contract setting; ignored here$"
  assert_eq "switches: ... and ignored" "$(detect_in "$nr" 'echo "[$NOTIFY]"' 2>/dev/null | tail -1)" "[]"
  assert_eq "switches: NOTIFY from the environment wins" "$(NOTIFY='/opt/bin/notify --env' detect_in "$nr" 'echo "[$NOTIFY]"' | tail -1)" "[/opt/bin/notify --env]"
  assert_match "switches: TRIAGE=maybe is refused"         "$(TRIAGE=maybe detect_in "$(fixture_repo none)" 'true')" "TRIAGE must be ask or auto \(got 'maybe'\)"
  assert_match "switches: GUIDED_REVIEW=yes is refused"   "$(GUIDED_REVIEW=yes detect_in "$(fixture_repo none)" 'true')" "GUIDED_REVIEW must be off or on \(got 'yes'\)"
  assert_match "switches: LANE_REVIEW=yes is refused"      "$(LANE_REVIEW=yes detect_in "$(fixture_repo none)" 'true')" "LANE_REVIEW must be on or off \(got 'yes'\)"
  tr_="$TMP/repos/suite-typo"; mkdir -p "$tr_"; echo 'SUITE_SKP=build' > "$tr_/.orchestrate"
  assert_match "suite: a mistyped SUITE_ setting is named" "$(detect_in "$tr_" 'true')" "'SUITE_SKP' is not a setting"
  assert_eq "switches: an empty environment value clears the file's" "$(REVIEW_AREAS='' SUITE_SKIP='' detect_in "$(fixture_repo contract-switches)" 'echo "[$REVIEW_AREAS][$SUITE_SKIP]"')" "[][]"
  sr="$TMP/repos/suite-nocmd"; mkdir -p "$sr"; echo 'suite lint' > "$sr/.orchestrate"
  assert_match "suite: a step without a command is refused" "$(detect_in "$sr" 'echo reached')" "suite lint needs a command"
  assert_nomatch "suite: that refusal stops the script"      "$(detect_in "$sr" 'echo reached')" "^reached$"
  r=$(fixture_repo contract-bad)
  assert_match "contract: unknown pane name is refused" "$(detect_in "$r" 'echo reached')" "unknown pane 'logs'"
  assert_nomatch "contract: refusal stops the script" "$(detect_in "$r" 'echo reached')" "^reached$"
fi

# --- bootstrap ---------------------------------------------------------------
if section bootstrap; then
  # layout.sh: the tabs and the grid inside each, read from a pane map.
  . "$KIT/layout.sh"
  M="$TMP/layout-map"
  printf '%s\n' 'orchestrator:   pane-0' 'lanes tab:      tab-5   (R1 pane-6, R2 pane-7)' > "$M"
  assert_eq "layout: tab_line reads a tab's id"          "$(tab_line "$M" lanes)" tab-5
  assert_eq "layout: tab_line is empty for a tab not open" "$(tab_line "$M" research)" ""
  for role in code review ""; do assert_eq "layout: lane_tab '$role' is lanes" "$(lane_tab "$role")" lanes; done
  for role in data research code-research; do assert_eq "layout: lane_tab '$role' is research" "$(lane_tab "$role")" research; done
  assert_eq "layout: no lane in the tab, the first goes under R2" "$(grid_anchor "$M" lanes)" "pane-7 down"
  assert_eq "layout: no lane and no Reviewer column, no anchor" "$(grid_anchor "$M" research)" ""
  echo 'lane A:         pane-5   (agent "acme-lane-a", kind claude, branch main, checkout /x, model m, tab lanes)' >> "$M"
  assert_eq "layout: the second lane goes right of the first" "$(grid_anchor "$M" lanes)" "pane-5 right"
  echo 'lane C:         pane-9   (agent "acme-lane-c", kind codex, branch c, checkout /x/c, model m, tab lanes) starting' >> "$M"
  assert_eq "layout: the third under the first, whatever the letters" "$(grid_anchor "$M" lanes)" "pane-5 down"
  echo 'unplaced lane D: pane-11  (agent "acme-lane-d", kind claude, branch d, checkout /x/d, model m, tab lanes)' >> "$M"
  echo 'lane B:         pane-10  (agent "acme-lane-b", kind claude, branch b, checkout /x/b, model m, tab research)' >> "$M"
  echo 'lane D:         pane-12  (agent "acme-lane-d", kind claude, branch d, checkout /x/d, model m, tab lanes)' >> "$M"
  assert_eq "layout: after three, under the second; unplaced lanes and other tabs not counted" "$(grid_anchor "$M" lanes)" "pane-9 down"
  assert_eq "layout: another tab has its own grid"       "$(grid_anchor "$M" research)" "pane-10 right"
  printf '%s\n' 'lane A:         pane-2   (agent "acme-lane-a", kind claude, branch main, checkout /x, model m)' > "$M"
  assert_eq "layout: a lane line with no tab (an older pane map) is in the lanes tab" "$(grid_anchor "$M" lanes)" "pane-2 right"

  if [ "${RUNNER:-herdr}" = orca ]; then
  # Orca, from an orchestrator that is a chat (no terminal handle of its own):
  # the orchestrator's workspace is the caller's (the fake's repo-0::<cwd>).
  boot() { (cd "$1" && shift && env -u ORCA_TERMINAL_HANDLE "$KIT/bootstrap.sh" "$@" 2>&1); }
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-orca"; reset_stub
  out=$(boot "$r" "$RUN" "Orca run" main; echo "exit=$?")
  log=$(cat "$ORCA_STUB_LOG"); map=$(cat "$RUN/panes.txt" 2>/dev/null)
  WS="repo-0::$r"
  assert_match "orca: bootstrap finishes" "$out" 'exit=0$'
  assert_nomatch "orca: no herdr call" "$log" '^herdr '
  assert_match "orca: a tower tab in the orchestrator's workspace, the console running tower" "$log" "^orca terminal create --worktree id:$WS --title tower --command cd $r && tower --stale 30 --json$"
  assert_match "orca: ... the shell below the console, running nothing" "$log" '^orca terminal split --terminal term-1 --direction horizontal --command cd '"$r"' --json$'
  assert_nomatch "orca: no dev tab by default" "$log" '--title dev '
  assert_match "orca: lane A in a terminal of the orchestrator's workspace" "$log" "^orca terminal create --worktree id:$WS --title lane-a --command cd $r --json$"
  assert_match "orca: ... its agent started there" "$log" '^orca terminal send --terminal term-3 --text claude --model claude-opus-5-5\\\[1m\\\] --enter --json$'
  assert_match "pane map (orca): the orchestrator's workspace" "$map" "^orchestrator: +$WS$"
  assert_match "pane map (orca): the console's terminal" "$map" '^console: +term-1 '
  assert_match "pane map (orca): the shell's terminal, in the checkout" "$map" "^shell: +term-2 +\\(a shell in $r, for the human\\)$"
  assert_match "pane map (orca): the tower tab" "$map" '^tower tab: +tab-1 +\(console over shell\)$'
  assert_match "pane map (orca): lane A's terminal and checkout, in tab lanes" "$map" '^lane A: +term-3 +\(agent "bun-vitest-lane-a", kind claude, branch main, checkout '"$r"', model [^,]+, tab lanes\)$'
  assert_match "pane map (orca): lane A's tab" "$map" '^lanes tab: +tab-3$'
  assert_match "pane map (orca): the same switches line" "$map" '^switches: +TASK_REVIEW=on '
  assert_match "pane map (orca): read a pane, with orca" "$map" '^read a pane: +"\$ORCA_CLI_COMMAND" terminal read --terminal <id> --json$'
  assert_nomatch "pane map (orca): no message line, briefs go through the kit" "$map" '^message a pane:'
  assert_match "orca: the next step sends the brief with send-brief.sh" "$out" "send-brief\\.sh $RUN bun-vitest-lane-a $RUN/brief-A\\.md\$"
  # A layout call that fails (the console's terminal closed before its split)
  # stops bootstrap, with no pane map line for what did not open.
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-orca-fail"; reset_stub; echo gone > "$ORCA_STUB_STATES_DIR/term-1"
  out=$(boot "$r" "$RUN" "Orca fail" main; echo "exit=$?")
  rm -f "$ORCA_STUB_STATES_DIR/term-1"
  assert_match "orca: a failing layout call: bootstrap fails" "$out" 'exit=1$'
  assert_match "orca: ... with Orca's error" "$out" 'terminal_handle_stale'
  assert_nomatch "orca: ... and no shell line" "$(cat "$RUN/panes.txt" 2>/dev/null)" '^shell:'
  assert_match "orca: ... the console it opened recorded in the pane map" "$(cat "$RUN/panes.txt" 2>/dev/null)" '^opened: +term-1 +\(before a failure: close it\)$'
  assert_match "orca: ... and named to close" "$out" "opened term-1 before it failed: close it"
  # Lane A's tab failing after the tower tab opened: both its panes named.
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-orca-fail-a"; reset_stub
  out=$(ORCA_STUB_CREATE_FAIL=lane-a boot "$r" "$RUN" "Orca fail A" main; echo "exit=$?")
  assert_match "orca: lane A's tab fails: the console and shell recorded" "$(cat "$RUN/panes.txt" 2>/dev/null)" '^opened: +term-1 term-2 +\(before a failure: close it\)$'
  assert_match "orca: ... and named to close" "$out" "opened term-1 term-2 before it failed"
  r=$(fixture_repo contract); RUN="$TMP/run-orca-dev"; reset_stub
  out=$(boot "$r" "$RUN" "Orca dev" main; echo "exit=$?")
  log=$(cat "$ORCA_STUB_LOG"); map=$(cat "$RUN/panes.txt" 2>/dev/null)
  assert_match "orca dev: bootstrap finishes" "$out" 'exit=0$'
  assert_match "orca dev: its own tab, in lane A's checkout, running the dev server in its dir" "$log" "^orca terminal create --worktree id:repo-0::$r --title dev --command cd $r/web && make dev --json$"
  assert_match "pane map (orca dev): the dev line" "$map" '^dev: +term-3 +\(make dev in web\)$'
  assert_match "pane map (orca dev): the dev tab" "$map" '^dev tab: +tab-3$'
  # A lane reads the dev pane with read-pane.sh --dev, which finds it in the
  # kit's launch record, not in the lane-writable map.
  printf 'starting\nready on :3000\n' > "$ORCA_STUB_STATES_DIR/term-3.tail"; sed -i.bak '/^dev:/s/term-3/term-1/' "$RUN/panes.txt"
  out=$( (cd "$r" && "$KIT/read-pane.sh" "$RUN" --dev 1 2>&1; echo "exit=$?") )
  assert_match "read-pane --dev (orca): the dev pane's last lines, from the kit's record" "$out" '^ready on :3000$'
  assert_nomatch "read-pane --dev (orca): ... as many as asked" "$out" '^starting$'
  assert_match "read-pane --dev (orca): ... exit 0" "$out" 'exit=0$'
  rm -f "$ORCA_STUB_STATES_DIR/term-3.tail"
  else
    boot() { (cd "$1" && shift && "$KIT/bootstrap.sh" "$@" 2>&1); }
    r=$(fixture_repo bun-vitest); RUN="$TMP/run-empty"; reset_stub
    out=$(boot "$r" "$RUN" "Empty run" main)
    log=$(cat "$HERDR_STUB_LOG")
    assert_eq "empty: the run is on the board, titled"    "$(board "$RUN" 'd["run"]["plan"]')" "Empty run"
    assert_eq "empty: no tasks yet"                       "$(board "$RUN" 'len(d["tasks"])')" 0
    assert_eq "empty: the roles' models are recorded"     "$(board "$RUN" '" ".join(k+"="+v for k,v in sorted(d["run"]["models"].items()))')" "implementer=claude-opus-5-5[1m] quality-reviewer=opus spec-reviewer=sonnet"
    assert_eq "empty: no lane assignment"                 "$(board "$RUN" 'len(d["lanes"])')" 0
    assert_match "layout: console right of the orchestrator, half the tab" "$log" '^herdr pane split --current --direction right --ratio 0.5 '
    assert_match "layout: the shell under the console, in the checkout" "$log" "^herdr pane split --pane pane-1 --direction down --ratio 0.6 --cwd $r --no-focus$"
    assert_nomatch "layout: the shell runs nothing"       "$log" '^herdr pane run pane-2 '
    assert_match "layout: console runs tower"             "$log" '^herdr pane run pane-1 tower --stale 30$'
    assert_match "lanes tab: opened in the orchestrator's workspace, unfocused" "$log" "^herdr tab create --workspace ws-0 --cwd $r --label lanes --no-focus$"
    assert_match "lanes tab: Reviewer column right of lane A, lanes keep two thirds" "$log" '^herdr pane split --pane pane-3 --direction right --ratio 0.67 '
    assert_match "lanes tab: R2 under R1"                 "$log" '^herdr pane split --pane pane-4 --direction down --ratio 0.5 '
    assert_eq "layout: no checks pane, so four splits"    "$(grep -c '^herdr pane split ' <<< "$log")" 4
    assert_match "lane A: agent named and started in the lanes tab's root" "$log" '^herdr agent start bun-vitest-lane-a --kind claude --pane pane-3 -- --model claude-opus-5-5\[1m\]$'
    map=$(cat "$RUN/panes.txt")
    assert_match "pane map: lanes tab line, with the Reviewer column" "$map" '^lanes tab: +tab-3 +\(R1 pane-4, R2 pane-5\)$'
    assert_match "pane map: lane A line, in tab lanes"    "$map" '^lane A: +pane-3 +\(agent "bun-vitest-lane-a", kind claude, branch main, checkout '"$r"', model [^,]+, tab lanes\)$'
    assert_nomatch "pane map: no checks line"             "$map" '^checks:'
    assert_match "pane map: shell line"                   "$map" "^shell: +pane-2 +\\(a shell in $r, for the human\\)$"
    assert_match "pane map: console line"                 "$map" '^console: +pane-1 '
    assert_match "pane map: check gate"                   "$map" '^check gate: +bun run typecheck && bun run test$'
    assert_match "pane map: read a pane, with herdr"      "$map" '^read a pane: +herdr pane read <id> --source recent-unwrapped --lines 60$'
    assert_nomatch "pane map: no message line, briefs go through the kit" "$map" '^message a pane:'
    assert_nomatch "pane map: no dev line by default"     "$map" '^dev:'
    assert_nomatch "pane map: no research tab line"       "$map" '^research tab:'
    assert_nomatch "layout: no research tab opened"       "$log" '(--label|--tab-label) research( |$)'
    assert_match "output: the pane map is printed"        "$out" '^lane A: '
    assert_match "output: next step for the empty opening" "$out" 'tower add'
    assert_nomatch "output: no info line without a pane checks line" "$out" '^info:'
    for outside in HERDR_ENV=0 HERDR_STUB=absent; do
      RUN="$TMP/run-outside-${outside%%=*}"; reset_stub
      out=$(env "$outside" bash -c 'cd "$1" && shift && "$KIT/bootstrap.sh" "$@" 2>&1' _ "$r" "$RUN" "Outside" main; echo "exit=$?")
      assert_match "outside herdr ($outside): bootstrap refuses, pointing to /tower:run" "$out" "needs herdr.*/tower:run"
      assert_match "outside herdr ($outside): ... and fails"          "$out" 'exit=1$'
      assert_eq "outside herdr ($outside): no run dir is created"     "$([ -e "$RUN" ] && echo made || echo none)" none
      assert_nomatch "outside herdr ($outside): no pane is opened"    "$(cat "$HERDR_STUB_LOG")" '^herdr(-absent)? (pane|agent|tab|worktree) '
      assert_nomatch "outside herdr ($outside): no run in the repo"   "$(cd "$r" && "$KIT/tests/stub/tower" state --json 2>&1)" "run-outside"
    done
    out=$(boot "$(fixture_repo pnpm-notest)" "$TMP/run-norunner" "No runner" main)
    assert_nomatch "output: no test runner detected, no note" "$out" 'no test runner detected'
    assert_match "switches: pane map has every switch"    "$map" '^switches: +TASK_REVIEW=on LANE_REVIEW=off PREFLIGHT=on STATIC_BASELINE=on PR=draft METHOD=tdd REVIEWER_KIND=other REVIEWER_MODEL= REVIEWER_BY_CREDITS=off REVIEWER_CREDITS_MIN=20 REVIEW_AREAS= SUITE_SKIP= PR_TEMPLATE= TRIAGE=ask GUIDED_REVIEW=off NOTIFY=$'
    assert_match "switches: the record gets a tower note" "$(notes "$TMP/run-empty")" '^switches: TASK_REVIEW=on LANE_REVIEW=off .* PR_TEMPLATE= TRIAGE=ask GUIDED_REVIEW=off NOTIFY=$'
    assert_match "switches: printed with the pane map"    "$out" '^switches: +TASK_REVIEW=on '
    assert_match "reviewer: pane map has kind and model"  "$map" '^reviewer: +kind codex, model gpt-6-astra$'
    assert_match "reviewer: the record gets a tower note" "$(notes "$TMP/run-empty")" '^reviewer: kind codex, model gpt-6-astra$'

    # An agent's shell may have a pipe on stdin: the empty opening reads none of it.
    RUN="$TMP/run-stdin"
    out=$(printf '9\tStray\tcore\n' | boot "$(fixture_repo bun-vitest)" "$RUN" "Stdin" main)
    assert_eq "empty: a task list on stdin is not read" "$(board "$RUN" 'len(d["tasks"])')" 0
    r=$(fixture_repo bun-vitest); RUN="$TMP/run-planned"; reset_stub
    out=$(boot "$r" "$RUN" "Planned" main "$KIT/example-tasks.tsv")
    assert_eq "planned: the task file's tasks are on the board" "$(board "$RUN" 'len(d["tasks"])')" "$(grep -c '^[0-9]' "$KIT/example-tasks.tsv")"
    assert_eq "planned: every task to lane A"             "$(board "$RUN" '",".join(t["lane"] for t in d["tasks"] if t["lane"] != "A") or "all A"')" "all A"
    # A markdown plan: its tasks and titles reach the board, and LANES splits them.
    r=$(fixture_repo bun-vitest); RUN="$TMP/run-plan-md"; reset_stub
    out=$(LANES="A=1,2 B=3" boot "$r" "$RUN" "Plan" main "$KIT/tests/example-plan.md")
    assert_eq "plan.md: its tasks, with their titles, are on the board" \
      "$(board "$RUN" '"|".join(t["id"]+":"+t["title"] for t in d["tasks"])')" \
      "1:The widget model|2:The widget list shows every widget|3:A widget can be renamed"
    assert_eq "plan.md: LANES assigns each lane" \
      "$(board "$RUN" '" ".join(k+"="+",".join(v) for k,v in sorted(d["lanes"].items()))')" "A=1,2 B=3"
    assert_eq "plan.md: the run's title is bootstrap's, repo and branch the plan's" \
      "$(board "$RUN" '"|".join([d["run"]["plan"], d["run"]["repo"], d["run"]["branch"]])')" "Plan|acme|feature/widgets"
    # <lane>=all: every task on the board, as spec-to-plan writes a serial plan.
    r=$(fixture_repo bun-vitest); RUN="$TMP/run-all"; reset_stub
    out=$(LANES="A=all" boot "$r" "$RUN" "All" main "$KIT/tests/example-plan.md"; echo "exit=$?")
    assert_match "LANES A=all: bootstrap finishes"        "$out" 'exit=0$'
    assert_eq "LANES A=all: every task is lane A's"       "$(board "$RUN" '" ".join(k+"="+",".join(v) for k,v in sorted(d["lanes"].items()))')" "A=1,2,3"
    # all means every task, so it is the whole of LANES; a bad spec, lane or id
    # is refused before the run exists (tower init checks the ids).
    r=$(fixture_repo bun-vitest); : > "$r/A=zzz"
    for bad in "A=all B=2" "A=1 B=all" "A" "A=1 =2" "A==1" "A=" " " "E=1" "A=1 A=2" "A=*" "A=9"; do
      RUN="$TMP/run-badlanes"; rm -rf "$RUN"
      out=$(LANES="$bad" boot "$r" "$RUN" "Bad" main "$KIT/tests/example-plan.md"; echo "exit=$?")
      assert_match "LANES '$bad': refused"                "$out" 'exit=1$'
      assert_match "LANES '$bad': ... saying why"         "$out" '^(LANES[ :]|tower: )'
      assert_eq "LANES '$bad': ... before the run exists" "$([ -e "$RUN" ] && echo made || echo none)" none
    done
    RUN="$TMP/run-lanes-init"; out=$(LANES="A=1,2 B=3" boot "$r" "$RUN" "Split" main "$KIT/tests/example-plan.md")
    assert_eq "LANES: the lanes come with the run"      "$(board "$RUN" '" ".join(k+"="+",".join(v) for k,v in sorted(d["lanes"].items()))')" "A=1,2 B=3"
    r=$(fixture_repo bun-vitest); RUN="$TMP/run-lanes"; reset_stub
    out=$(LANES="A=1 B=2,3" boot "$r" "$RUN" "Lanes" main "$KIT/example-tasks.tsv")
    assert_eq "planned: LANES assigns each lane"          "$(board "$RUN" '" ".join(k+"="+",".join(v) for k,v in sorted(d["lanes"].items()))')" "A=1 B=2,3"
    out=$(LANES="A=1" boot "$r" "$TMP/run-x" "X" main)
    assert_match "empty: LANES without a source is refused" "$out" 'LANES needs a plan or task file'
    out=$(boot "$r" "$TMP/run-y" "Y" main /nonexistent.md)
    assert_match "a missing source is refused"            "$out" 'no such plan or task file'

    r=$(fixture_repo bun-vitest); RUN="$TMP/run-notower"; reset_stub
    out=$(TOWER_STUB=absent boot "$r" "$RUN" "Refused" main; echo "exit=$?")
    assert_match "tower not runnable: bootstrap refuses"            "$out" 'exit=1$'
    assert_match "tower not runnable: ... saying tower is required"  "$out" 'needs tower'
    assert_match "tower not runnable: ... with the install pointer" "$out" 'github\.com/phutschi/tower'
    assert_eq "tower not runnable: no run dir is created"           "$([ -e "$RUN" ] && echo made || echo none)" none
    assert_nomatch "tower not runnable: no pane is opened"          "$(cat "$HERDR_STUB_LOG")" '^herdr (pane|agent|tab|worktree) '
    assert_match "tower not runnable: no run in the repo"          "$(cd "$r" && "$KIT/tests/stub/tower" state --json 2>&1)" 'no run'
    # Two runs from the same fixture: each in its own repo, each its own board.
    r1=$(fixture_repo bun-vitest); r2=$(fixture_repo bun-vitest)
    boot "$r1" "$TMP/run-iso-1" "Iso one" main >/dev/null; boot "$r2" "$TMP/run-iso-2" "Iso two" main >/dev/null
    assert_eq "two tests never see each other's run" \
      "$(cd "$r1" && "$KIT/tests/stub/tower" state --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["run"]["plan"])')|$(cd "$r2" && "$KIT/tests/stub/tower" state --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["run"]["plan"])')" "Iso one|Iso two"
    RUN="$TMP/run-only-panes"; reset_stub
    out=$(boot "$r" "$RUN" "Only panes" main "$KIT/example-tasks.tsv")
    assert_nomatch "run dir: no second record beside tower" "$(ls -A "$RUN")" '^(tasks\.tsv|lanes\.txt|run\.txt|plan\.md)$'
    RUN="$TMP/run-switches"; reset_stub
    out=$(PR=off boot "$(fixture_repo contract-switches)" "$RUN" "Switches" main)
    assert_match "switches: the file and the environment reach the pane map" "$(cat "$RUN/panes.txt")" '^switches: +TASK_REVIEW=off .* PR=off METHOD=plain .* SUITE_SKIP=build '
    out=$(boot "$(fixture_repo contract-switches-bad)" "$TMP/run-bad" "Bad" main)
    assert_match "switches: bootstrap refuses a bad value" "$out" "PR must be draft, ready or off"
    [ -e "$TMP/run-bad/panes.txt" ] && bad "switches: a refused run writes no pane map" || ok "switches: a refused run writes no pane map"
    RUN="$TMP/run-lines"; reset_stub
    out=$(boot "$(fixture_repo contract-lines)" "$RUN" "Lines only" main; echo "exit=$?")
    assert_match "a contract with only pane and suite lines: bootstrap finishes" "$out" 'exit=0$'
    assert_match "a contract with only pane and suite lines: pane map written" "$(cat "$RUN/panes.txt" 2>&1)" '^shell: +pane-[0-9]+ '
    assert_eq "pane checks: bootstrap says once that the line is ignored" "$(grep -c '^info: \.orchestrate: pane checks is ignored: the checks pane is gone' <<< "$out")" 1
    assert_nomatch "pane checks: ... and opens no checks pane" "$(cat "$RUN/panes.txt" "$HERDR_STUB_LOG")" '^checks:|make watch'
    assert_nomatch "pane checks: the info line is on stderr" "$(cd "$(fixture_repo contract-lines)" && "$KIT/bootstrap.sh" "$TMP/run-lines2" "Lines" main 2>/dev/null)" '^info:'
    r=$(fixture_repo bun-vitest); RUN="$TMP/run-fallback"; reset_stub
    out=$(CODEX_STUB=absent boot "$r" "$RUN" "Fallback" main)
    assert_match "reviewer: a fallback is in the pane map" "$(cat "$RUN/panes.txt")" '^reviewer: +kind claude, model claude-fable-5-1 \(fallback: codex is not installed'
    assert_match "reviewer: a fallback is printed"         "$out" '^reviewer: +kind claude, model claude-fable-5-1 \(fallback: '
    assert_match "reviewer: a fallback goes to the record" "$(notes "$RUN")" '^reviewer: kind claude, model claude-fable-5-1 \(fallback: '
    r=$(fixture_repo bun-vitest)
    out=$(CODEX_STUB=absent REVIEWER_KIND=codex boot "$r" "$TMP/run-forced" "Forced" main)
    assert_match "reviewer: bootstrap refuses a forced kind that is not installed" "$out" 'REVIEWER_KIND=codex, but codex is not installed'
    [ -e "$TMP/run-forced" ] && bad "reviewer: a refused run creates no run dir" || ok "reviewer: a refused run creates no run dir"
    r=$(fixture_repo bun-vitest); RUN="$TMP/run-noreview"; reset_stub
    out=$(LANE_REVIEW=off PREFLIGHT=off CODEX_STUB=absent REVIEWER_KIND=codex boot "$r" "$RUN" "No review" main)
    assert_match "reviewer: none when lane review and preflight are off" "$(cat "$RUN/panes.txt")" '^reviewer: +none \(LANE_REVIEW=off, PREFLIGHT=off\)$'
    assert_match "lanes tab: no Reviewer column when reviews are off" "$(cat "$RUN/panes.txt")" '^lanes tab: +tab-3 +\(no Reviewer column\)$'
    assert_nomatch "lanes tab: ... so lane A is not split" "$(cat "$HERDR_STUB_LOG")" '^herdr pane split --pane pane-3 '
    r=$(fixture_repo bun-vitest); RUN="$TMP/run-lanereview"; reset_stub
    out=$(LANE_REVIEW=on PREFLIGHT=off boot "$r" "$RUN" "Lane review" main)
    assert_match "lanes tab: a Reviewer column with lane review alone" "$(cat "$RUN/panes.txt")" '^lanes tab: +tab-3 +\(R1 pane-4, R2 pane-5\)$'

    r=$(fixture_repo contract); RUN="$TMP/run-dev"; reset_stub
    out=$(boot "$r" "$RUN" "Dev" main)
    log=$(cat "$HERDR_STUB_LOG")
    assert_match "dev: under the console"                 "$log" '^herdr pane split --pane pane-1 --direction down --ratio 0.6 '
    assert_match "dev: the shell right of dev"            "$log" '^herdr pane split --pane pane-2 --direction right --ratio 0.5 '
    assert_match "dev: dev pane runs in its dir"          "$log" "^herdr pane run pane-2 cd $r/web && make dev$"
    assert_nomatch "dev: the shell runs nothing"          "$log" '^herdr pane run pane-3 '
    assert_match "dev: pane map has dev"                  "$(cat "$RUN/panes.txt")" '^dev: +pane-2 '
    assert_match "dev: console is pane-1"                 "$(cat "$RUN/panes.txt")" '^console: +pane-1 '
    assert_match "dev: shell is pane-3"                   "$(cat "$RUN/panes.txt")" '^shell: +pane-3 '
    printf 'starting\nready on :3000\n' > "$HERDR_STUB_STATES_DIR/pane-2.tail"; sed -i.bak '/^dev:/s/pane-2/pane-1/' "$RUN/panes.txt"
    : > "$HERDR_STUB_LOG"; out=$( (cd "$r" && "$KIT/read-pane.sh" "$RUN" --dev 1 2>&1; echo "exit=$?") )
    assert_match "read-pane --dev (herdr): the dev pane's last line, from the kit's record" "$out" '^ready on :3000$'
    assert_match "read-pane --dev (herdr): ... read by its pane" "$(cat "$HERDR_STUB_LOG")" '^herdr pane read pane-2 --source recent-unwrapped --lines 1$'
    rm -f "$HERDR_STUB_STATES_DIR/pane-2.tail"
    assert_match "dev: console runs tower"                "$log" '^herdr pane run pane-1 tower --stale 45$'
    assert_match "dev: lane A in the lanes tab"           "$(cat "$RUN/panes.txt")" '^lane A: +pane-4 '

    # Lane A runs where bootstrap is run from, which is often a herdr worktree
    # of the checkout, not the main checkout repo_root() resolves to.
    r=$(fixture_repo bun-vitest); wt="$TMP/repos/bun-vitest-wt"
    git -C "$r" worktree add -q "$wt" -b wt-branch
    RUN="$TMP/run-worktree"; reset_stub
    boot "$wt" "$RUN" "Worktree" wt-branch >/dev/null
    assert_match "worktree: lane A checkout is where bootstrap ran, not repo_root" "$(cat "$RUN/panes.txt")" '^lane A: +pane-3 +\(agent "[^"]+", kind claude, branch wt-branch, checkout '"$wt"', model '
    assert_match "worktree: the shell opens in the worktree" "$(cat "$RUN/panes.txt")" "^shell: +pane-2 +\\(a shell in $wt, "

    # The pane commands are shell code built around the checkout's path: a path
    # with an apostrophe (or one crafted to run code) must stay one directory.
    # Each pane's logged command is run as its shell would (bash, and zsh where
    # it is installed), with the runner replaced by one that prints where it ran.
    mkdir -p "$TMP/fakebin"; printf '#!/bin/sh\npwd -P\n' > "$TMP/fakebin/bunx"; printf '#!/bin/sh\npwd -P\n' > "$TMP/fakebin/make"
    chmod +x "$TMP/fakebin/bunx" "$TMP/fakebin/make"
    pane_cwd() { PATH="$TMP/fakebin:$PATH" "$1" -c "$(sed -n "s/^herdr pane run $2 //p" "$HERDR_STUB_LOG")" 2>&1; }
    shells=bash; command -v zsh >/dev/null && shells="bash zsh"
    for name in "rex's repo" "x'; touch pwned; '"; do
      src=$(fixture_repo contract); r="$TMP/repos/quoted/$name"; mkdir -p "$TMP/repos/quoted"; mv "$src" "$r"; mkdir -p "$r/web"
      RUN="$TMP/run-quoted"; rm -rf "$RUN"; reset_stub
      out=$(boot "$r" "$RUN" "Quoted" main; echo "exit=$?")
      assert_match "quoted path ($name): bootstrap finishes"    "$out" 'exit=0$'
      for sh in $shells; do
        assert_eq "quoted path ($name, $sh): dev pane runs in its dir"         "$(cd "$TMP/repos/quoted" && pane_cwd "$sh" pane-2)" "$r/web"
        assert_eq "quoted path ($name, $sh): no code in the path runs" "$([ -e "$TMP/repos/quoted/pwned" ] && echo ran || echo none)" none
      done
      rm -rf "$TMP/repos/quoted"
    done

    # A new pane's shell may not be ready when the agent starts: herdr answers
    # agent_pane_busy, and the start is tried again.
    r=$(fixture_repo bun-vitest); RUN="$TMP/run-busy"; reset_stub
    out=$(HERDR_STUB_BUSY_STARTS=1 boot "$r" "$RUN" "Busy" main; echo "exit=$?")
    assert_match "busy pane: bootstrap finishes"          "$out" 'exit=0$'
    assert_nomatch "busy pane: a start that recovers shows no busy error" "$out" 'agent_pane_busy'
    assert_eq "busy pane: lane A's start is tried again"  "$(grep -c '^herdr agent start bun-vitest-lane-a ' "$HERDR_STUB_LOG")" 2
    r=$(fixture_repo bun-vitest); RUN="$TMP/run-busy-long"; reset_stub
    out=$(HERDR_STUB_BUSY_STARTS=99 START_TRIES=3 boot "$r" "$RUN" "Busy long" main; echo "exit=$?")
    assert_eq "busy pane: START_TRIES starts, then it gives up" "$(grep -c '^herdr agent start bun-vitest-lane-a ' "$HERDR_STUB_LOG")" 3
    assert_match "busy pane: giving up shows herdr's answer" "$out" 'agent_pane_busy'
    assert_match "busy pane: giving up says what to do"   "$out" 'pane pane-3 is still not a ready shell after 3 tries; check it, or raise START_TRIES'
    assert_match "busy pane: giving up fails bootstrap"    "$out" 'exit=1$'
    # Busy and trust are herdr's error codes, not words in its message.
    r=$(fixture_repo bun-vitest); RUN="$TMP/run-start-words"; reset_stub
    out=$(HERDR_STUB_START_FAIL="echo" boot "$r" "$RUN" "Start words" main; echo "exit=$?")
    assert_eq "herdr start: busy words in another error: no retry" "$(grep -c '^herdr agent start bun-vitest-lane-a ' "$HERDR_STUB_LOG")" 1
    assert_nomatch "herdr start: trust words in another error: no keys" "$(cat "$HERDR_STUB_LOG")" '^herdr pane send-keys'
    assert_match "herdr start: ... the start fails with herdr's error" "$out" 'server_unavailable'

    # A fresh checkout's trust prompt blocks the start: it is answered, and the
    # agent is started again only when herdr says it is not there.
    S="$HERDR_STUB_STATES_DIR"
    for case in "gone:2:0" "working:1:0" "idle:1:0" "unreachable:1:1" "blocked:1:1" "unknown:1:1"; do
      IFS=: read -r state starts code <<< "$case"
      r=$(fixture_repo bun-vitest); RUN="$TMP/run-trust-$state"; reset_stub; echo "$state" > "$S/bun-vitest-lane-a"
      out=$(HERDR_STUB_TRUST_STARTS=1 boot "$r" "$RUN" "Trust" main; echo "exit=$?")
      assert_match "trust prompt: answered"                "$(cat "$HERDR_STUB_LOG")" '^herdr pane send-keys pane-3 Down Enter$'
      assert_eq "trust prompt, agent $state: starts"       "$(grep -c '^herdr agent start bun-vitest-lane-a ' "$HERDR_STUB_LOG")" "$starts"
      assert_match "trust prompt, agent $state: exit $code" "$out" "exit=$code\$"
      case $state in
        unreachable) assert_match "trust prompt, herdr failing: says so" "$out" 'herdr cannot say whether bun-vitest-lane-a started' ;;
        unknown)     assert_match "trust prompt, agent unknown: says so" "$out" 'bun-vitest-lane-a is still unknown in pane pane-3 after its trust prompt was answered' ;;
      esac
    done
    r=$(fixture_repo bun-vitest); RUN="$TMP/run-trust-keys"; reset_stub
    out=$(HERDR_STUB_TRUST_STARTS=1 HERDR_STUB_SEND_KEYS_FAIL=1 boot "$r" "$RUN" "Trust" main; echo "exit=$?")
    assert_match "trust prompt, send-keys failing: bootstrap fails, saying so" "$out" "could not answer bun-vitest-lane-a's trust prompt in pane pane-3"
    assert_match "trust prompt, send-keys failing: exit 1" "$out" 'exit=1$'
    # Lane A's agent exits twice: nothing to brief, and bootstrap says so.
    r=$(fixture_repo bun-vitest); RUN="$TMP/run-gone-a"; reset_stub
    printf 'gone\ngone\n' > "$S/bun-vitest-lane-a.started"
    out=$(boot "$r" "$RUN" "Gone" main; echo "exit=$?")
    rm -f "$S"/bun-vitest-lane-a*
    assert_match "lane A gone twice: bootstrap fails" "$out" 'exit=1$'
    assert_match "lane A gone twice: says there is no agent to brief" "$out" "lane A's agent bun-vitest-lane-a is not running in pane-3: .*rerun bootstrap\.sh with a new run dir"
    assert_nomatch "lane A gone twice: not told to brief it" "$out" 'brief it once it accepts input'
    rm -f "$S/bun-vitest-lane-a"
    # herdr stops answering once lane A started: bootstrap cannot say whether it
    # runs, and says so instead of telling to brief it.
    r=$(fixture_repo bun-vitest); RUN="$TMP/run-unread-a"; reset_stub
    echo unreachable > "$S/bun-vitest-lane-a.started"
    out=$(READY_WAIT_SECONDS=2 boot "$r" "$RUN" "Unread" main; echo "exit=$?")
    rm -f "$S"/bun-vitest-lane-a*
    assert_match "lane A unreadable: bootstrap fails" "$out" 'exit=1$'
    assert_match "lane A unreadable: says herdr cannot answer" "$out" "bootstrap: herdr cannot say whether lane A's agent bun-vitest-lane-a runs in pane-3; .*check that pane, and with the agent there brief it once  herdr agent get bun-vitest-lane-a  shows interactive_ready true; with none, rerun bootstrap\.sh with a new run dir"
    assert_nomatch "lane A unreadable: not told to brief it once it accepts input" "$out" 'brief it once it accepts input'
    assert_nomatch "lane A unreadable: not told to rerun once herdr answers" "$out" 'rerun once herdr answers'
  fi
  # Lane A's kind not installed: refused before tower init, naming its CLI.
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-nokind-${RUNNER:-herdr}"; reset_stub
  out=$(cd "$r" && EXECUTOR_KIND=cursor CURSOR_STUB=absent "$KIT/bootstrap.sh" "$RUN" "No kind" main 2>&1; echo "exit=$?")
  assert_match "lane A's kind not installed: refused" "$out" 'exit=1$'
  assert_match "lane A's kind not installed: ... naming its CLI" "$out" "bootstrap: lane A's kind cursor runs as cursor-agent, which is not installed: install it, or set EXECUTOR_KIND to another kind"
  assert_eq "lane A's kind not installed: no run dir" "$([ -e "$RUN" ] && echo made || echo none)" none
fi

# --- add-lane ----------------------------------------------------------------
if section add-lane; then
  if [ "${RUNNER:-herdr}" = orca ]; then
  # Orca: a lane is a child worktree of the orchestrator's workspace, its
  # executor in a terminal there; Orca picks the worktree's path.
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-orca-lanes"; reset_stub; WS="repo-0::$r"
  (cd "$r" && "$KIT/bootstrap.sh" "$RUN" "Orca lanes" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
  lane() { (cd "$r" && "$KIT/add-lane.sh" "$RUN" "$@" 2>&1); }
  : > "$ORCA_STUB_LOG"; out=$(lane B feat/b main 2,3; echo "exit=$?"); log=$(cat "$ORCA_STUB_LOG"); map=$(cat "$RUN/panes.txt")
  assert_match "orca B: add-lane finishes" "$out" 'exit=0$'
  assert_nomatch "orca B: no herdr call" "$log" '^herdr '
  assert_eq "orca B: the board has lane B owning its tasks" "$(board "$RUN" '",".join(d["lanes"].get("B", []))')" "2,3"
  assert_match "orca B: a child worktree of the orchestrator's workspace" "$log" "^orca worktree create --name bun-vitest-lane-b --branch feat/b --base-branch main --parent-worktree id:$WS --setup skip --json$"
  wt=$(sed -nE 's/^lane B: .* checkout (.*), model .*/\1/p' "$RUN/panes.txt")
  assert_eq "orca B: its checkout is the worktree Orca made" "$wt" /orca-stub/worktrees/wt-4
  assert_match "orca B: its executor in a terminal of that worktree" "$log" '^orca terminal create --worktree id:repo-0::/orca-stub/worktrees/wt-4 --title bun-vitest-lane-b --command cd /orca-stub/worktrees/wt-4 --json$'
  bpane=$(sed -nE 's/^lane B: +([^ ]+).*/\1/p' "$RUN/panes.txt")
  assert_match "orca B: ... the agent started in it" "$log" "^orca terminal send --terminal $bpane --text claude "
  assert_match "orca B: pane map line: the terminal and the worktree" "$map" '^lane B: +term-5 +\(agent "bun-vitest-lane-b", kind claude, branch feat/b, checkout /orca-stub/worktrees/wt-4, model [^,]+, tab lanes\)$'
  assert_nomatch "orca B: no unplaced line left" "$map" '^unplaced lane B:'
  assert_match "orca B: the next step sends the brief with send-brief.sh" "$out" "send-brief\\.sh $RUN bun-vitest-lane-b $RUN/brief-B\\.md\$"
  : > "$ORCA_STUB_LOG"; out=$(lane B feat/b main 2,3; echo "exit=$?")
  assert_match "orca B rerun, running: refused, the lane exists" "$out" 'lane B already exists'
  assert_nomatch "orca B rerun, running: nothing created" "$(cat "$ORCA_STUB_LOG")" '^orca (worktree create|terminal create|terminal send) '
  assert_eq "orca B rerun, running: the pane map as it was" "$(cat "$RUN/panes.txt")" "$map"
  echo gone > "$ORCA_STUB_STATES_DIR/$bpane"
  : > "$ORCA_STUB_LOG"; out=$(lane B feat/b main 2,3; echo "exit=$?")
  assert_match "orca B rerun, a stale handle: fails" "$out" 'exit=1$'
  assert_match "orca B rerun, a stale handle: asks to rebind it" "$out" "Orca says lane B's terminal handle $bpane is stale: it may still be open under a new handle\\. Find lane B's terminal in Orca, put its handle on lane B's line in $RUN/panes.txt and record it with  .*bind-pane\\.sh $RUN bun-vitest-lane-b <its handle>, then rerun"
  assert_nomatch "orca B rerun, a stale handle: no removal advised" "$out" 'remove'
  # Its restart command, only when the lane's line and checkout are checked:
  # the fake's worktree is not on disk, so the default text.
  assert_match "orca B rerun, a stale handle, its checkout unchecked: the default text" "$out" "if Orca has no such terminal, it was closed: open one where it worked and put that handle there"
  assert_nomatch "orca B rerun, a stale handle, its checkout unchecked: no restart command" "$out" 'start the agent there with'
  # A lane whose checkout git names (lane D, made real below): the command,
  # whose words split back into the CLI with its model.

  assert_nomatch "orca B rerun, a stale handle: nothing created or started" "$(cat "$ORCA_STUB_LOG")" '^orca (worktree create|terminal create|terminal send) '
  rm -f "$ORCA_STUB_STATES_DIR/$bpane"
  # A worktree create that fails, or answers with no worktree: refused,
  # saying what to remove, with no terminal opened.
  : > "$ORCA_STUB_LOG"; out=$(ORCA_STUB_WORKTREE_FAIL=1 lane D feat/d main 5; echo "exit=$?")
  assert_match "orca D, worktree create fails: refused" "$out" 'exit=1$'
  assert_match "orca D, worktree create fails: ... with Orca's error, and a look at the branch first" "$out" "Orca could not create lane D's worktree .*runtime_unavailable.*If branch feat/d exists now, look at it before you remove it"
  assert_nomatch "orca D, worktree create fails: no terminal" "$(cat "$ORCA_STUB_LOG")" '^orca terminal create '
  : > "$ORCA_STUB_LOG"; out=$(ORCA_STUB_WORKTREE_FAIL=garbled lane D feat/d main 5; echo "exit=$?")
  assert_match "orca D, a create answer with no worktree: refused" "$out" 'exit=1$'
  assert_match "orca D, a create answer with no worktree: ... saying to find it, and remove only this lane's" "$out" "Orca made lane D's worktree but its answer names none .*find it \\(\"\\\$ORCA_CLI_COMMAND\" worktree list --json\\) and its branch, and remove only what is this lane's"
  assert_nomatch "orca D, a create answer with no worktree: no terminal" "$(cat "$ORCA_STUB_LOG")" '^orca terminal create '
  # A branch taken between the check and the create: Orca makes the worktree
  # on a suffixed branch, which is refused before a terminal opens.
  : > "$ORCA_STUB_LOG"; out=$(ORCA_STUB_WORKTREE_FAIL=suffix ORCA_STUB_WORKTREES="/orca-stub/team repo" lane D feat/d main 5; echo "exit=$?")
  assert_match "orca D, made on another branch: refused" "$out" 'exit=1$'
  assert_match "orca D, made on another branch: ... saying which, and what to remove, its selector one argument" "$out" "Orca made lane D's worktree on branch feat/d-2, not feat/d: remove it \\(\"\\\$ORCA_CLI_COMMAND\" worktree rm --worktree id:repo-0::/orca-stub/team\\\\ repo/wt-[0-9]+ --force\\) and branch feat/d-2"
  assert_nomatch "orca D, made on another branch: no terminal" "$(cat "$ORCA_STUB_LOG")" '^orca terminal create '
  assert_nomatch "orca D, made on another branch: no lane D line" "$(cat "$RUN/panes.txt")" 'lane D:'
  # A launch Orca never sent (its send refused) is recorded as unsent; the
  # rerun starts the agent once, in the same terminal.
  : > "$ORCA_STUB_LOG"; out=$(ORCA_STUB_SEND_FAIL=refused ORCA_STUB_WORKTREES="$TMP/orca-wt" lane D feat/d2 main 5; echo "exit=$?")
  dpane=$(sed -nE 's/^lane D: +([^ ]+).*/\1/p' "$RUN/panes.txt"); dwt=$(sed -nE 's/^lane D: .* checkout (.*), model .*/\1/p' "$RUN/panes.txt")
  assert_match "orca D, its launch not sent: fails" "$out" 'exit=1$'
  assert_match "orca D, its launch not sent: recorded unsent" "$(cat "$RUN/panes.txt")" '^lane D: .*\) unsent$'
  assert_match "orca D, its launch not sent: says a rerun starts it" "$out" "lane D's launch was never sent: rerun  .*add-lane\\.sh .* D feat/d2 main 5  to start it in $dpane"
  mkdir -p "$TMP/orca-wt"; git -C "$r" worktree add -q -b feat/d2 "$dwt"   # the worktree Orca made
  # Its terminal showing no shell (an agent on screen, idle): no launch typed.
  echo unlisted-idle > "$ORCA_STUB_STATES_DIR/$dpane"
  : > "$ORCA_STUB_LOG"; out=$(lane D feat/d2 main 5; echo "exit=$?")
  assert_match "orca D rerun, its screen not a shell: refused" "$out" "lane D's launch was never sent, but terminal $dpane's screen does not show a shell"
  assert_nomatch "orca D rerun, its screen not a shell: nothing typed" "$(cat "$ORCA_STUB_LOG")" '^orca terminal send '
  # A last line shaped like a prompt is no shell while Orca lists an agent
  # there waiting or blocked (an input box, a status line): nothing typed.
  for st in waiting blocked; do
    echo "$st" > "$ORCA_STUB_STATES_DIR/$dpane"; printf 'Bye!\nacme $ \n' > "$ORCA_STUB_STATES_DIR/$dpane.tail"
    : > "$ORCA_STUB_LOG"; out=$(lane D feat/d2 main 5; echo "exit=$?")
    assert_match "orca D rerun, listed $st, a prompt-shaped screen: refused" "$out" "lane D's launch was never sent, but terminal $dpane's screen does not show a shell"
    assert_nomatch "orca D rerun, listed $st, a prompt-shaped screen: nothing typed" "$(cat "$ORCA_STUB_LOG")" '^orca terminal send '
  done
  rm -f "$ORCA_STUB_STATES_DIR/$dpane.tail"
  # An agent working there after all (started by hand): refused, nothing typed.
  echo working > "$ORCA_STUB_STATES_DIR/$dpane"
  : > "$ORCA_STUB_LOG"; out=$(lane D feat/d2 main 5; echo "exit=$?")
  assert_match "orca D rerun, an agent working there: refused" "$out" "an agent is working in $dpane although its launch was never sent"
  assert_nomatch "orca D rerun, an agent working there: nothing typed" "$(cat "$ORCA_STUB_LOG")" '^orca terminal send '
  echo unlisted-shell-launch > "$ORCA_STUB_STATES_DIR/$dpane"
  : > "$ORCA_STUB_LOG"; out=$(ORCA_STUB_SEND_FAIL=refused lane D feat/d2 main 5; echo "exit=$?")
  assert_match "orca D rerun, not sent again: still unsent" "$(cat "$RUN/panes.txt")" '^lane D: .*\) unsent$'
  assert_eq "orca D rerun, not sent again: one launch tried" "$(grep -c "^orca terminal send --terminal $dpane --text claude " "$ORCA_STUB_LOG")" 1
  # A launch with no receipt stays pending (starting): the operator looks
  # at the terminal before anything is typed again.
  : > "$ORCA_STUB_LOG"; out=$(ORCA_STUB_SEND_FAIL=unknown lane D feat/d2 main 5; echo "exit=$?")
  assert_match "orca D rerun, no receipt: pending, not unsent" "$(cat "$RUN/panes.txt")" '^lane D: .*\) starting$'
  assert_match "orca D rerun, no receipt: says to inspect the terminal first" "$out" "Orca cannot say whether lane D's launch reached $dpane \\(no receipt\\): look at that terminal before anything is sent again"
  sed -i.bak '/^lane D:/s/ starting$/ unsent/' "$RUN/panes.txt"; rm -f "$RUN/panes.txt.bak"   # the operator saw no agent there
  : > "$ORCA_STUB_LOG"; out=$(lane D feat/d2 main 5; echo "exit=$?")
  assert_match "orca D rerun: started" "$out" 'exit=0$'
  assert_eq "orca D rerun: its agent typed once, in the same terminal" "$(grep -c "^orca terminal send --terminal $dpane --text claude " "$ORCA_STUB_LOG")" 1
  assert_nomatch "orca D rerun: no new worktree or terminal" "$(cat "$ORCA_STUB_LOG")" '^orca (worktree create|terminal create) '
  assert_match "orca D rerun: the line is a started lane" "$(cat "$RUN/panes.txt")" '^lane D: .*, tab lanes\)$'
  echo gone > "$ORCA_STUB_STATES_DIR/$dpane"
  out=$(lane D feat/d2 main 5; echo "exit=$?")
  cmd=$(echo "$out" | sed -nE 's/.*start the agent there with  cd [^&]+ && (.*), put that terminal.*/\1/p')
  assert_match "orca D, its terminal closed: how to restart its agent by hand" "$out" "it was closed: open a terminal in .*, start the agent there with  cd .* && claude --model "
  assert_eq "orca D, ... the command's words split back into the CLI and its model" "$(eval "set -- $cmd"; echo "$1 $2")" "claude --model"
  out=$(EXECUTOR_KIND=codex lane D feat/d2 main 5; echo "exit=$?")
  assert_nomatch "orca D, a rerun of another kind: no restart command" "$out" 'start the agent there with'
  rm -f "$ORCA_STUB_STATES_DIR/$dpane"
  # A branch Orca's answer leaves unread: nothing is named for removal (it may
  # be another process's); the worktree is named for a look, one argument.
  : > "$ORCA_STUB_LOG"; out=$(ORCA_STUB_WORKTREE_FAIL=nobranch ORCA_STUB_WORKTREES="/orca-stub/team repo" lane C feat/c4 main 4; echo "exit=$?")
  assert_match "orca C, its branch unread: refused" "$out" 'exit=1$'
  assert_match "orca C, its branch unread: names the worktree to inspect, as one argument" "$out" "Orca made lane C's worktree /orca-stub/team repo/wt-[0-9]+, but its branch cannot be read: look at it .*worktree show --worktree id:repo-0::/orca-stub/team\\\\ repo/wt-[0-9]+ --json"
  assert_nomatch "orca C, its branch unread: no removal advised" "$out" 'remove it|worktree rm'
  assert_nomatch "orca C, its branch unread: no terminal" "$(cat "$ORCA_STUB_LOG")" '^orca terminal create '
  # Ids and paths with a space are kept whole: the orchestrator's workspace
  # (its checkout's path) and the worktree Orca makes.
  rs=$(fixture_repo bun-vitest); mkdir -p "$TMP/team space"; mv "$(dirname "$rs")" "$TMP/team space/r"; rs="$TMP/team space/r/bun-vitest"
  RUNS="$TMP/run-orca-space"; reset_stub; (cd "$rs" && "$KIT/bootstrap.sh" "$RUNS" "Orca space" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
  : > "$ORCA_STUB_LOG"; out=$(cd "$rs" && ORCA_STUB_WORKTREES="/orca-stub/team repo" "$KIT/add-lane.sh" "$RUNS" B feat/b main 2,3 2>&1; echo "exit=$?"); log=$(cat "$ORCA_STUB_LOG")
  assert_match "orca, a space in the paths: add-lane finishes" "$out" 'exit=0$'
  assert_match "orca, a space in the paths: the whole workspace id is the parent" "$log" "^orca worktree create .* --parent-worktree id:repo-0::$rs --setup skip --json\$"
  assert_match "orca, a space in the paths: the terminal opens in the whole worktree" "$log" '^orca terminal create --worktree id:repo-0::/orca-stub/team repo/wt-[0-9]+ --title bun-vitest-lane-b --command cd /orca-stub/team\\ repo/wt-[0-9]+ --json$'
  assert_match "orca, a space in the paths: the checkout recorded whole" "$(cat "$RUNS/panes.txt")" '^lane B: +term-[0-9]+ +\(agent "bun-vitest-lane-b", .*checkout /orca-stub/team repo/wt-[0-9]+, model '
  # Orca gives a taken branch name a numeric suffix: an existing branch is
  # refused before any worktree is made, or the lane would commit elsewhere.
  git -C "$r" branch feat/c
  : > "$ORCA_STUB_LOG"; out=$(lane C feat/c main 4; echo "exit=$?")
  assert_match "orca C, its branch exists: refused" "$out" 'exit=1$'
  assert_match "orca C, its branch exists: ... saying so" "$out" 'branch feat/c exists'
  assert_nomatch "orca C, its branch exists: no worktree" "$(cat "$ORCA_STUB_LOG")" '^orca worktree create '
  else
    r=$(fixture_repo bun-vitest); RUN="$TMP/run-grid"; reset_stub
    (cd "$r" && "$KIT/bootstrap.sh" "$RUN" "Grid" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
    lane() { (cd "$r" && "$KIT/add-lane.sh" "$RUN" "$@" 2>&1); }
    reset_stub; out=$(lane B feat/b main 2,3); log=$(cat "$HERDR_STUB_LOG")
    assert_eq "B: the board has lane B owning its tasks" "$(board "$RUN" '",".join(d["lanes"].get("B", []))')" "2,3"
    assert_match "B: worktree under .worktrees"         "$log" "^herdr worktree create --cwd $r --branch feat/b --base main --path $r/.worktrees/feat/b --label bun-vitest-lane-b --no-focus$"
    assert_match "B: placed right of lane A, in the lanes tab" "$log" '^herdr pane move pane-[0-9]+ --tab tab-3 --split right --target-pane pane-3 --ratio 0.5 --no-focus$'
    assert_match "B: agent start"                       "$log" '^herdr agent start bun-vitest-lane-b --kind claude --pane '
    assert_match "B: install not typed into the pane"   "$out" '\[dry-run\] \(cd .*/.worktrees/feat/b && bun install\) > '"$RUN"'/install-B.log'
    assert_eq    "B: nothing typed into the lane pane"  "$(grep -c '^herdr pane run' "$HERDR_STUB_LOG")" 0
    assert_match "B: pane map line, in tab lanes"       "$(cat "$RUN/panes.txt")" '^lane B: +pane-[0-9]+ +\(agent "bun-vitest-lane-b", kind claude, branch feat/b, checkout '"$r"'/.worktrees/feat/b, model [^,]+, tab lanes\)$'
    assert_match "B: prints the next step"              "$out" 'lane B ready'
    reset_stub; out=$(lane C feat/c main 4)
    assert_match "C: placed under lane A"               "$(cat "$HERDR_STUB_LOG")" '--tab tab-3 --split down --target-pane pane-3 '
    bpane=$(sed -nE 's/^lane B: +([^ ]+).*/\1/p' "$RUN/panes.txt")
    reset_stub; out=$(lane D feat/d main 5)
    assert_match "D: placed under lane B"               "$(cat "$HERDR_STUB_LOG")" "--split down --target-pane $bpane "
    assert_match "E: refused, four lanes at most"       "$(lane E feat/e main 6)" 'B, C or D'
    assert_match "A: refused, bootstrap starts it"      "$(lane A feat/a main 1)" 'lane A is started by bootstrap'
    assert_match "B again: refused"                     "$(lane B feat/b2 main 7)" 'lane B already exists'
    r2=$(fixture_repo bun-vitest); RUN2="$TMP/run-grid2"; reset_stub
    (cd "$r2" && "$KIT/bootstrap.sh" "$RUN2" "Grid2" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
    reset_stub; (cd "$r2" && "$KIT/add-lane.sh" "$RUN2" D feat/d main 5 >/dev/null 2>&1)
    assert_match "D before B and C: the second lane in the tab, so right of lane A" "$(cat "$HERDR_STUB_LOG")" '^herdr pane move pane-[0-9]+ --tab tab-3 --split right --target-pane pane-3 '
    assert_match "no pane map: refused"                 "$(cd "$r2" && "$KIT/add-lane.sh" "$TMP/nowhere" B feat/b main 2 2>&1)" 'run bootstrap.sh first'
    reset_stub; out=$(cd "$r2" && "$KIT/add-lane.sh" "$RUN2" B feat/typo main 99 2>&1)
    assert_match "an unknown task id: refused by tower"  "$out" '"99" is not a task'
    assert_nomatch "an unknown task id: no worktree"     "$(cat "$HERDR_STUB_LOG")" '^herdr worktree create'
    r=$(fixture_repo bun-vitest); RUN3="$TMP/run-nt"; reset_stub
    (cd "$r" && "$KIT/bootstrap.sh" "$RUN3" "NT" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
    reset_stub; out=$(cd "$r" && TOWER_STUB=absent "$KIT/add-lane.sh" "$RUN3" B feat/b main 2,3 2>&1; echo "exit=$?")
    assert_match "tower not runnable: add-lane refuses with the pointer" "$out" 'needs tower.*github\.com/phutschi/tower'
    assert_match "tower not runnable: ... and fails"              "$out" 'exit=1$'
    assert_nomatch "tower not runnable: no worktree, no agent"    "$(cat "$HERDR_STUB_LOG")" '^herdr (worktree|pane|agent) '
    assert_eq "tower not runnable: no lane B on the board"        "$(board "$RUN3" '"B" in d["lanes"]')" False
    nr=$(fixture_repo none); RUNN="$TMP/run-noinstall"; reset_stub
    (cd "$nr" && "$KIT/bootstrap.sh" "$RUNN" "No install" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
    out=$(cd "$nr" && "$KIT/add-lane.sh" "$RUNN" B feat/b main 2 2>&1)
    assert_nomatch "no package.json: no install"        "$out" '\[dry-run\] \(cd .*install'
    assert_eq "no package.json: one line says so"       "$(printf '%s\n' "$out" | grep -c 'no install')" 1
    assert_match "no package.json: the line names why"  "$out" '^add-lane: no install: no package.json and no INSTALL_CMD in \.orchestrate$'
    out=$(cd "$r" && INSTALL_CMD='' "$KIT/add-lane.sh" "$RUN3" B feat/b main 5 2>&1)
    assert_match "INSTALL_CMD set empty: no install, and that is the reason" "$out" '^add-lane: no install: INSTALL_CMD is empty$'
    out=$(cd "$nr" && INSTALL_CMD='' "$KIT/add-lane.sh" "$RUNN" C feat/c main 3 2>&1)
    assert_match "INSTALL_CMD set empty, no package.json: that is the reason" "$out" '^add-lane: no install: INSTALL_CMD is empty$'
    reset_stub; out=$(cd "$r" && HERDR_STUB_BUSY_STARTS=1 "$KIT/add-lane.sh" "$RUN3" C feat/c main 4 2>&1; echo "exit=$?")
    assert_match "busy pane: add-lane finishes"         "$out" 'exit=0$'
    assert_nomatch "busy pane: add-lane shows no busy error" "$out" 'agent_pane_busy'
    assert_eq "busy pane: the lane's start is tried again" "$(grep -c '^herdr agent start bun-vitest-lane-c ' "$HERDR_STUB_LOG")" 2

    # An agent that fails to start leaves its lane in the pane map, and a rerun
    # starts the agent in that pane and worktree instead of creating them again.
    r=$(fixture_repo bun-vitest); RUNF="$TMP/run-failstart"; reset_stub
    (cd "$r" && "$KIT/bootstrap.sh" "$RUNF" "Fail start" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
    reset_stub; out=$(cd "$r" && HERDR_STUB_BUSY_STARTS=99 START_TRIES=1 "$KIT/add-lane.sh" "$RUNF" B feat/b main 2,3 2>&1; echo "exit=$?")
    assert_match "failed start: add-lane fails"          "$out" 'exit=1$'
    assert_match "failed start: the lane is in the pane map" "$(cat "$RUNF/panes.txt")" '^lane B: +pane-[0-9]+ +\(agent "bun-vitest-lane-b", kind claude, branch feat/b, checkout '"$r"'/.worktrees/feat/b, model '
    assert_match "failed start (herdr): starting, never unsent" "$(cat "$RUNF/panes.txt")" '^lane B: .*\) starting$'
    assert_match "failed start: says how to resume"      "$out" 'lane B is in the pane map, starting: rerun  .*/add-lane\.sh .* B feat/b main 2,3  to resume it'
    bpane=$(sed -nE 's/^lane B: +([^ ]+).*/\1/p' "$RUNF/panes.txt")
    echo gone > "$HERDR_STUB_STATES_DIR/bun-vitest-lane-b"
    mkwt "$r" feat/b   # the stub's worktree create makes none
    # Recorded unsent (a start that failed before its launch, say a git
    # error): herdr's own agent start guards the pane, so the rerun starts it.
    sed -i.bak '/^lane B:/s/ starting$/ unsent/' "$RUNF/panes.txt"; rm -f "$RUNF/panes.txt.bak"
    reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNF" B feat/b main 2,3 2>&1; echo "exit=$?"); log=$(cat "$HERDR_STUB_LOG")
    assert_match "rerun: add-lane finishes"               "$out" 'exit=0$'
    assert_nomatch "rerun: no second worktree"            "$log" '^herdr worktree create'
    assert_nomatch "rerun: the pane is not moved again"   "$log" '^herdr pane move'
    assert_match "rerun: the agent starts in the lane's pane" "$log" "^herdr agent start bun-vitest-lane-b --kind claude --pane $bpane "
    assert_eq "rerun: one lane B line in the pane map"    "$(grep -c '^lane B:' "$RUNF/panes.txt")" 1
    assert_match "rerun: prints the next step"            "$out" 'lane B ready'
    assert_eq "rerun: lane B still owns its tasks"        "$(board "$RUNF" '",".join(d["lanes"].get("B", []))')" "2,3"
    rm -f "$HERDR_STUB_STATES_DIR/bun-vitest-lane-b"
    reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNF" B feat/b main 2,3 2>&1; echo "exit=$?")
    assert_match "rerun, agent running: refused"         "$out" 'lane B already exists'
    assert_nomatch "rerun, agent running: no start"      "$(cat "$HERDR_STUB_LOG")" '^herdr agent start'
    echo unreachable > "$HERDR_STUB_STATES_DIR/bun-vitest-lane-b"
    reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNF" B feat/b main 2,3 2>&1; echo "exit=$?")
    assert_match "rerun, herdr failing: refused"         "$out" 'exit=1$'
    assert_match "rerun, herdr failing: ... saying herdr cannot tell" "$out" 'herdr cannot say whether agent bun-vitest-lane-b runs'
    assert_nomatch "rerun, herdr failing: no start"      "$(cat "$HERDR_STUB_LOG")" '^herdr agent start'
    echo gone > "$HERDR_STUB_STATES_DIR/bun-vitest-lane-b"
    reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNF" B feat/other main 2,3 2>&1; echo "exit=$?")
    assert_match "rerun, another branch: refused"        "$out" 'lane B is in the pane map with another branch, kind or model'
    assert_nomatch "rerun, another branch: no start"     "$(cat "$HERDR_STUB_LOG")" '^herdr agent start'
    reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNF" B feat/b main 4,5 2>&1; echo "exit=$?")
    assert_match "rerun, other task ids: refused, naming the lane's" "$out" 'lane B owns 2,3 on the board, not 4,5; rerun with those ids'
    assert_nomatch "rerun, other task ids: no start"     "$(cat "$HERDR_STUB_LOG")" '^herdr agent start'
    assert_eq "rerun, other task ids: the board keeps lane B's" "$(board "$RUNF" '",".join(d["lanes"].get("B", []))')" "2,3"
    reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNF" B feat/b main 2,3,9-7 2>&1; echo "exit=$?")
    assert_match "rerun, a backwards range: refused as tower refuses it" "$out" '^add-lane: range "9-7" runs backwards$'
    assert_match "rerun, a backwards range: fails"       "$out" 'exit=1$'
    assert_nomatch "rerun, a backwards range: no start"  "$(cat "$HERDR_STUB_LOG")" '^herdr agent start'
    reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNF" B feat/b main '2,3,a-b' 2>&1; echo "exit=$?")
    assert_match "rerun, a letter range: refused as tower refuses it" "$out" '^add-lane: range "a-b" must be integer to integer, like 7-9$'
    assert_match "rerun, a letter range: fails"          "$out" 'exit=1$'
    assert_nomatch "rerun, a letter range: no start"     "$(cat "$HERDR_STUB_LOG")" '^herdr agent start'
    reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNF" B feat/b main '2,3,a b' 2>&1; echo "exit=$?")
    assert_match "rerun, an invalid id: refused as tower refuses it" "$out" '^add-lane: "a b" is not a valid task id \(letters, digits, \. _ -; no spaces\)$'
    assert_match "rerun, an invalid id: fails"           "$out" 'exit=1$'
    assert_nomatch "rerun, an invalid id: no start"      "$(cat "$HERDR_STUB_LOG")" '^herdr agent start'
    reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNF" B feat/b main -2,3 2>&1; echo "exit=$?")
    assert_match "rerun, a spec led by a dash: read as ids, refused as tower refuses it" "$out" '^add-lane: "-2" is not a valid task id'
    reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNF" B feat/b main 2,3,99 2>&1; echo "exit=$?")
    assert_match "rerun, an id the run lacks: refused as tower refuses it" "$out" '^add-lane: unknown task "99"'
    assert_match "rerun, an id the run lacks: fails"     "$out" 'exit=1$'
    assert_nomatch "rerun, an id the run lacks: no start" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start'
    # tower failing to read the record is said as such, not blamed on the ids.
    chmod 000 "$RUNF/run.json"
    reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNF" B feat/b main 2,3 2>&1; echo "exit=$?")
    chmod 644 "$RUNF/run.json"
    assert_match "rerun, tower state failing: says tower failed" "$out" '^add-lane: tower state failed; rerun once tower answers$'
    assert_nomatch "rerun, tower state failing: the ids are not blamed" "$out" 'on the board, not'
    assert_nomatch "rerun, tower state failing: no start" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start'
    reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNF" B feat/b main 2-3 2>&1; echo "exit=$?")
    assert_match "rerun, the same ids as a range: finishes" "$out" 'exit=0$'
    # The pane map is lane-writable: a checkout that git does not name as this
    # repo's worktree on the lane's branch is refused before the install, the
    # .env copy or the start use it.
    echo gone > "$HERDR_STUB_STATES_DIR/bun-vitest-lane-b"
    # The repo's own checkout is a worktree of it, on another branch.
    before=$(cat "$RUNF/panes.txt")
    sed -i.bak "s|checkout $r/.worktrees/feat/b,|checkout $r,|" "$RUNF/panes.txt"; rm -f "$RUNF/panes.txt.bak"
    reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNF" B feat/b main 2,3 2>&1; echo "exit=$?")
    assert_match "rerun, a worktree on another branch: refused" "$out" 'exit=1$'
    assert_match "rerun, a worktree on another branch: ... naming the one git has" "$out" "lane B's checkout $r in $RUNF/panes.txt is not this repo's worktree on branch feat/b: git has $(cd "$r/.worktrees/feat/b" && pwd -P) on it"
    assert_nomatch "rerun, a worktree on another branch: no start" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start'
    printf '%s\n' "$before" > "$RUNF/panes.txt"
    rm -rf "$r/.worktrees/feat/b"
    reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNF" B feat/b main 2,3 2>&1; echo "exit=$?")
    assert_match "rerun, worktree removed: refused, saying what to remove" "$out" "lane B's checkout .*/\.worktrees/feat/b is gone: close its pane $bpane and remove its line"
    assert_nomatch "rerun, worktree removed: no start"   "$(cat "$HERDR_STUB_LOG")" '^herdr agent start'
    mkwt "$r" feat/b; echo gone > "$HERDR_STUB_STATES_DIR/$bpane"
    reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNF" B feat/b main 2,3 2>&1; echo "exit=$?")
    assert_match "rerun, pane closed: refused, saying what to remove" "$out" "lane B's pane $bpane is gone \(herdr pane get\): remove its line"
    assert_nomatch "rerun, pane closed: no start"        "$(cat "$HERDR_STUB_LOG")" '^herdr agent start'
    # herdr failing to answer for the pane is not the pane closed: nothing is
    # to be removed, and the map and the worktree stay.
    echo unreachable > "$HERDR_STUB_STATES_DIR/$bpane"; before=$(cat "$RUNF/panes.txt")
    reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNF" B feat/b main 2,3 2>&1; echo "exit=$?")
    assert_match "rerun, pane get failing: refused, herdr named" "$out" "herdr cannot say whether lane B's pane $bpane is open; rerun once herdr answers \(herdr: .*server_unavailable"
    assert_nomatch "rerun, pane get failing: no removal advice" "$out" 'remove its line'
    assert_nomatch "rerun, pane get failing: no start"   "$(cat "$HERDR_STUB_LOG")" '^herdr agent start'
    # add-lane only advises removal today; these guard against a cleanup added later.
    assert_eq "rerun, pane get failing: the pane map is kept" "$(cat "$RUNF/panes.txt")" "$before"
    assert_eq "rerun, pane get failing: the worktree is kept" "$([ -d "$r/.worktrees/feat/b" ] && echo kept || echo gone)" kept
    rm -f "$HERDR_STUB_STATES_DIR/$bpane"
    reset_stub; out=$(cd "$r" && HERDR_STUB_BUSY_STARTS=99 START_TRIES=1 "$KIT/add-lane.sh" "$RUNF" B feat/b main 2,3 2>&1; echo "exit=$?")
    assert_match "rerun, start fails again: says to rerun" "$out" 'is not ready in pane-[0-9]+; lane B is in the pane map, starting: rerun  .*/add-lane\.sh .* B feat/b main 2,3  to resume it'
    assert_match "rerun, start fails again: fails"       "$out" 'exit=1$'
    rm -f "$HERDR_STUB_STATES_DIR/bun-vitest-lane-b"

    # A rerun reads the task ids as tower does: a padded range keeps its width,
    # and spaces and empty tokens between commas are nothing.
    r=$(fixture_repo bun-vitest); RUNP="$TMP/run-padded"; reset_stub
    printf '07\tSeven\tcore\n08\tEight\tcore\n09\tNine\tcore\n10\tTen\tcore\n11\tEleven\tcore\n' > "$TMP/padded.tsv"
    (cd "$r" && "$KIT/bootstrap.sh" "$RUNP" "Padded" main "$TMP/padded.tsv" >/dev/null 2>&1)
    for spec in "B feat/b 07-09" "C feat/c 10, 11,"; do
      read -r l br ids <<< "$spec"; ln=$(echo "$l" | tr 'A-Z' 'a-z')
      reset_stub; out=$(cd "$r" && HERDR_STUB_BUSY_STARTS=99 START_TRIES=1 "$KIT/add-lane.sh" "$RUNP" "$l" "$br" main "$ids" 2>&1; echo "exit=$?")
      assert_match "first call with '$ids': the start fails" "$out" 'exit=1$'
      assert_match "first call with '$ids': the lane is in the pane map" "$(cat "$RUNP/panes.txt")" "^lane $l: "
      echo gone > "$HERDR_STUB_STATES_DIR/bun-vitest-lane-$ln"; mkwt "$r" "$br"
      reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNP" "$l" "$br" main "$ids" 2>&1; echo "exit=$?")
      assert_match "rerun with '$ids': the same ids, so it finishes" "$out" 'exit=0$'
      assert_match "rerun with '$ids': the agent starts"  "$(cat "$HERDR_STUB_LOG")" "^herdr agent start bun-vitest-lane-$ln "
      rm -f "$HERDR_STUB_STATES_DIR/bun-vitest-lane-$ln"
    done
    echo gone > "$HERDR_STUB_STATES_DIR/bun-vitest-lane-b"
    reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNP" B feat/b main 7-9 2>&1; echo "exit=$?")
    assert_match "rerun with '7-9' for 07,08,09: ids the run lacks, refused as tower refuses them" "$out" '^add-lane: unknown task "7" — did you mean 07\?'
    rm -f "$HERDR_STUB_STATES_DIR/bun-vitest-lane-b"
    assert_eq "padded: the board has the lanes' ids as written" "$(board "$RUNP" '" ".join(k+"="+",".join(v) for k,v in sorted(d["lanes"].items()))')" "B=07,08,09 C=10,11"
    # A trust prompt that cannot be answered, or an agent still blocked after
    # the answer, fails the call: no ready line, and the lane stays in the map
    # for a rerun.
    r=$(fixture_repo bun-vitest); RUNT="$TMP/run-trust-lane"; reset_stub
    (cd "$r" && "$KIT/bootstrap.sh" "$RUNT" "Trust" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
    reset_stub; out=$(cd "$r" && HERDR_STUB_TRUST_STARTS=1 HERDR_STUB_SEND_KEYS_FAIL=1 "$KIT/add-lane.sh" "$RUNT" B feat/b main 2 2>&1; echo "exit=$?")
    assert_match "trust, send-keys failing: fails"       "$out" 'exit=1$'
    assert_match "trust, send-keys failing: says so"     "$out" "could not answer bun-vitest-lane-b's trust prompt"
    assert_nomatch "trust, send-keys failing: no ready line" "$out" 'lane B ready'
    assert_match "trust, send-keys failing: the lane is in the pane map" "$(cat "$RUNT/panes.txt")" '^lane B: '
    # The start again after the answer can meet the prompt again: that fails,
    # saying so, and is not tried a third time.
    echo gone > "$HERDR_STUB_STATES_DIR/bun-vitest-lane-d"
    reset_stub; out=$(cd "$r" && HERDR_STUB_TRUST_STARTS=2 "$KIT/add-lane.sh" "$RUNT" D feat/d main 4 2>&1; echo "exit=$?")
    assert_match "trust, the start again fails: fails"   "$out" 'exit=1$'
    assert_match "trust, the start again fails: says so" "$out" 'bun-vitest-lane-d did not start again in pane pane-[0-9]+ after its trust prompt'
    assert_eq "trust, the start again fails: two starts" "$(grep -c '^herdr agent start bun-vitest-lane-d ' "$HERDR_STUB_LOG")" 2
    assert_nomatch "trust, the start again fails: no ready line" "$out" 'lane D ready'
    rm -f "$HERDR_STUB_STATES_DIR/bun-vitest-lane-d"
    echo blocked > "$HERDR_STUB_STATES_DIR/bun-vitest-lane-c"
    reset_stub; out=$(cd "$r" && HERDR_STUB_TRUST_STARTS=1 "$KIT/add-lane.sh" "$RUNT" C feat/c main 3 2>&1; echo "exit=$?")
    assert_match "trust, still blocked: fails"           "$out" 'exit=1$'
    assert_match "trust, still blocked: says so"         "$out" 'bun-vitest-lane-c is still blocked in pane pane-[0-9]+ after its trust prompt was answered'
    assert_nomatch "trust, still blocked: no ready line" "$out" 'lane C ready'
    assert_match "trust, still blocked: the lane is in the pane map" "$(cat "$RUNT/panes.txt")" '^lane C: '
    rm -f "$HERDR_STUB_STATES_DIR/bun-vitest-lane-c"
    # A codex lane's sandbox grant is worked out from its own worktree, not
    # from where add-lane is called (the main checkout) (#10).
    r=$(fixture_repo bun-vitest); RUNX="$TMP/run-codex-wt"; reset_stub
    (cd "$r" && "$KIT/bootstrap.sh" "$RUNX" "Codex" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
    git -C "$r" worktree add -q "$r/.worktrees/feat/x" -b feat/x   # the stub's worktree create makes none
    C=$(git -C "$r" rev-parse --path-format=absolute --git-common-dir); reset_stub
    (cd "$r" && EXECUTOR_KIND=codex "$KIT/add-lane.sh" "$RUNX" B feat/x main 2 >/dev/null 2>&1)
    assert_match "codex lane B: started" "$(cat "$HERDR_STUB_LOG")" "^herdr agent start bun-vitest-lane-b "
    log=$(grep '^herdr agent start bun-vitest-lane-b ' "$HERDR_STUB_LOG")
    assert_match "codex lane B: its own worktree's git dir is writable" "$log" "writable_roots=\\[.*\"$C/worktrees/x\"\\]"
    assert_nomatch "codex lane B: not the whole common git dir" "$log" "--add-dir $C( |\$)"
    # look's worktree dir is a codex Reviewer's alone: never a lane's, even
    # with AGENT_LOOK in the caller's environment.
    r=$(fixture_repo bun-vitest); RUNL="$TMP/run-codex-look"; reset_stub
    (cd "$r" && EXECUTOR_KIND=codex AGENT_LOOK="$XDG_STATE_HOME/tower/look" "$KIT/bootstrap.sh" "$RUNL" "Look" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
    assert_match "codex lane A: started" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-lane-a --kind codex '
    assert_nomatch "codex lane A: no grant of look's worktree dir" "$(cat "$HERDR_STUB_LOG")" 'tower/look'
    git -C "$r" worktree add -q "$r/.worktrees/feat/l" -b feat/l; reset_stub
    (cd "$r" && EXECUTOR_KIND=codex AGENT_LOOK="$XDG_STATE_HOME/tower/look" "$KIT/add-lane.sh" "$RUNL" B feat/l main 2 >/dev/null 2>&1)
    assert_match "codex lane B (look): started" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-lane-b --kind codex '
    assert_nomatch "codex lane B: no grant of look's worktree dir" "$(cat "$HERDR_STUB_LOG")" 'tower/look'
    # A start that never accepts input leaves the lane's line ending in
    # "starting" and its agent running; a rerun takes the agent once it accepts
    # input, starts it again when it is gone, and otherwise says to end it.
    r=$(fixture_repo bun-vitest); RUNR="$TMP/run-slow-lane"; reset_stub
    (cd "$r" && "$KIT/bootstrap.sh" "$RUNR" "Slow" main "$KIT/example-tasks.tsv" >/dev/null 2>&1); reset_stub
    echo unready > "$HERDR_STUB_STATES_DIR/bun-vitest-lane-b.started"
    out=$(cd "$r" && READY_WAIT_SECONDS=1 "$KIT/add-lane.sh" "$RUNR" B feat/b main 2 2>&1; echo "exit=$?")
    rm -f "$HERDR_STUB_STATES_DIR/bun-vitest-lane-b.started"; mkwt "$r" feat/b
    assert_match "never ready: add-lane fails"           "$out" 'exit=1$'
    assert_nomatch "never ready: no ready line"          "$out" 'lane B ready'
    assert_match "never ready: the lane's line says starting" "$(cat "$RUNR/panes.txt")" '^lane B: .* starting$'
    assert_match "never ready: says a rerun resumes it"  "$out" "lane B is in the pane map, starting: rerun  .*/add-lane\.sh .* B feat/b main 2  to resume it"
    echo blocked > "$HERDR_STUB_STATES_DIR/bun-vitest-lane-b"
    reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNR" B feat/b main 2 2>&1; echo "exit=$?")
    assert_match "rerun, agent blocked: refused"         "$out" 'exit=1$'
    assert_match "rerun, agent blocked: says to end it"  "$out" "agent bun-vitest-lane-b is in pane-[0-9]+ but does not accept input \(blocked\): answer or end it there, then rerun"
    assert_nomatch "rerun, agent blocked: no start"      "$(cat "$HERDR_STUB_LOG")" '^herdr agent start'
    echo idle > "$HERDR_STUB_STATES_DIR/bun-vitest-lane-b"
    reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNR" B feat/b main 2 2>&1; echo "exit=$?")
    assert_match "rerun, agent now ready: finishes"      "$out" 'exit=0$'
    assert_nomatch "rerun, agent now ready: not started again" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start'
    assert_match "rerun, agent now ready: resumed"       "$out" 'lane B ready: agent bun-vitest-lane-b in pane-[0-9]+ \(resumed\)'
    assert_match "rerun, agent now ready: its line is no longer starting" "$(cat "$RUNR/panes.txt")" '^lane B: .*model [^ ]+, tab lanes\)$'
    reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNR" B feat/b main 2 2>&1; echo "exit=$?")
    assert_match "rerun of a started lane: refused as existing" "$out" 'lane B already exists'
    # A started lane whose agent has gone is started again as starting: a
    # restart that times out leaves a lane the next rerun resumes.
    echo gone > "$HERDR_STUB_STATES_DIR/bun-vitest-lane-b"; echo unready > "$HERDR_STUB_STATES_DIR/bun-vitest-lane-b.started"
    reset_stub; out=$(cd "$r" && READY_WAIT_SECONDS=1 "$KIT/add-lane.sh" "$RUNR" B feat/b main 2 2>&1; echo "exit=$?")
    rm -f "$HERDR_STUB_STATES_DIR/bun-vitest-lane-b.started"
    assert_match "restart never ready: fails"            "$out" 'exit=1$'
    assert_match "restart never ready: the line says starting again" "$(cat "$RUNR/panes.txt")" '^lane B: .* starting$'
    echo idle > "$HERDR_STUB_STATES_DIR/bun-vitest-lane-b"
    reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNR" B feat/b main 2 2>&1; echo "exit=$?")
    assert_match "restart never ready, then ready: resumed" "$out" 'lane B ready: .*\(resumed\)'
    rm -f "$HERDR_STUB_STATES_DIR/bun-vitest-lane-b"

    # A pane move that fails after the worktree is created leaves the lane
    # recorded as unplaced, and a rerun moves that pane and finishes the lane
    # instead of creating the worktree again.
    r=$(fixture_repo bun-vitest); RUNM="$TMP/run-failmove"; reset_stub
    (cd "$r" && "$KIT/bootstrap.sh" "$RUNM" "Fail move" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
    reset_stub; out=$(cd "$r" && HERDR_STUB_MOVE_FAIL=1 "$KIT/add-lane.sh" "$RUNM" B feat/b main 2,3 2>&1; echo "exit=$?")
    wtpane=$(sed -nE 's/^herdr pane move ([^ ]+) .*/\1/p' "$HERDR_STUB_LOG")
    assert_match "failed move: add-lane fails"           "$out" 'exit=1$'
    assert_match "failed move: says how to resume"       "$out" "could not move lane B's pane $wtpane into the grid.*rerun  .*/add-lane\.sh .* B feat/b main 2,3  to place it"
    assert_nomatch "failed move: no agent start"         "$(cat "$HERDR_STUB_LOG")" '^herdr agent start'
    assert_match "failed move: the worktree is installed before the move" "$out" '\[dry-run\] \(cd .*/.worktrees/feat/b && bun install\)'
    assert_nomatch "failed move: no placed lane B"       "$(cat "$RUNM/panes.txt")" '^lane B:'
    assert_match "failed move: the lane is recorded as unplaced" "$(cat "$RUNM/panes.txt")" "^unplaced lane B: +$wtpane +\(agent \"bun-vitest-lane-b\", kind claude, branch feat/b, checkout $r/\.worktrees/feat/b, model "
    # An unplaced rerun installs: a checkout git does not name is refused first.
    mkdir -p "$TMP/elsewhere"; before=$(cat "$RUNM/panes.txt")
    sed -i.bak "s|checkout $r/.worktrees/feat/b,|checkout $TMP/elsewhere,|" "$RUNM/panes.txt"; rm -f "$RUNM/panes.txt.bak"
    reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNM" B feat/b main 2,3 2>&1; echo "exit=$?")
    assert_match "failed move, a checkout git does not name: refused" "$out" "lane B's checkout $TMP/elsewhere in $RUNM/panes.txt is not this repo's worktree on branch feat/b: git has none on it"
    assert_nomatch "failed move, a checkout git does not name: no install" "$out" 'dry-run.*install'
    assert_nomatch "failed move, a checkout git does not name: no move, no start" "$(cat "$HERDR_STUB_LOG")" '^herdr (pane move|agent start)'
    assert_eq "failed move, a checkout git does not name: no .env copied there" "$(ls -A "$TMP/elsewhere")" ""
    printf '%s\n' "$before" > "$RUNM/panes.txt"
    mkwt "$r" feat/b   # the stub's worktree create makes none
    # A checkout spelled through a link in the run dir passes the check, but
    # everything after it uses git's own path: the link could be swapped.
    ln -s "$r/.worktrees/feat/b" "$RUNM/link"; real=$(cd "$r/.worktrees/feat/b" && pwd -P)
    sed -i.bak "s|checkout $r/.worktrees/feat/b,|checkout $RUNM/link,|" "$RUNM/panes.txt"; rm -f "$RUNM/panes.txt.bak"
    reset_stub; out=$(cd "$r" && HERDR_STUB_MOVE_FAIL=1 "$KIT/add-lane.sh" "$RUNM" B feat/b main 2,3 2>&1; echo "exit=$?")
    assert_match "failed move, a checkout through a link: installed in git's path" "$out" "\\[dry-run\\] \\(cd $real && bun install\\)"
    assert_nomatch "failed move, a checkout through a link: ... not the link" "$out" "cd $RUNM/link"
    echo 'KEY=1' > "$r/.env"
    reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNM" B feat/b main 2,3 2>&1; echo "exit=$?")
    assert_match "a checkout through a link, placed: the map records git's path" "$(cat "$RUNM/panes.txt")" "^lane B: .*checkout $real, model "
    assert_eq "a checkout through a link, placed: .env copied into git's path" "$(cat "$real/.env" 2>/dev/null)" KEY=1
    rm -f "$RUNM/link" "$r/.env" "$real/.env"; printf '%s\n' "$before" > "$RUNM/panes.txt"
    echo gone > "$HERDR_STUB_STATES_DIR/$wtpane"
    reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNM" B feat/b main 2,3 2>&1; echo "exit=$?")
    assert_match "failed move, pane closed: says the move may have gone through" "$out" "lane B's pane $wtpane is gone \(herdr pane get\).*look for .*/\.worktrees/feat/b in the grid"
    assert_nomatch "failed move, pane closed: no move"   "$(cat "$HERDR_STUB_LOG")" '^herdr pane move'
    rm -f "$HERDR_STUB_STATES_DIR/$wtpane"
    reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNM" B feat/other main 2,3 2>&1; echo "exit=$?")
    assert_match "failed move, rerun with another branch: refused" "$out" 'lane B is in the pane map with another branch, kind or model'
    assert_nomatch "failed move, rerun with another branch: no move" "$(cat "$HERDR_STUB_LOG")" '^herdr pane move'
    reset_stub; out=$(cd "$r" && HERDR_STUB_MOVE_FAIL=garbled "$KIT/add-lane.sh" "$RUNM" B feat/b main 2,3 2>&1; echo "exit=$?")
    assert_match "move answered without a pane: fails"   "$out" 'exit=1$'
    assert_match "move answered without a pane: says what to do" "$out" "herdr moved lane B's pane $wtpane but its answer names no pane: find the lane's pane in the grid .* into  lane B: <that pane's id> "
    assert_nomatch "move answered without a pane: no agent start" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start'
    reset_stub; out=$(cd "$r" && HERDR_STUB_MOVE_FAIL=1 "$KIT/add-lane.sh" "$RUNM" B feat/b main 2,3 2>&1; echo "exit=$?")
    assert_match "failed move, rerun fails to move again: says to rerun" "$out" "could not move lane B's pane $wtpane into the grid.*to place it"
    assert_eq "failed move, rerun fails to move again: one unplaced line" "$(grep -c '^unplaced lane B:' "$RUNM/panes.txt")" 1
    reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNM" B feat/b main 2,3 2>&1; echo "exit=$?"); log=$(cat "$HERDR_STUB_LOG")
    assert_match "failed move, rerun: add-lane finishes" "$out" 'exit=0$'
    assert_nomatch "failed move, rerun: no second worktree" "$log" '^herdr worktree create'
    assert_match "failed move, rerun: the recorded pane is moved" "$log" "^herdr pane move $wtpane --tab tab-3 --split right --target-pane pane-3 "
    assert_match "failed move, rerun: the agent starts"  "$log" '^herdr agent start bun-vitest-lane-b --kind claude --pane '
    assert_match "failed move, rerun: lane B is placed"  "$(cat "$RUNM/panes.txt")" '^lane B: +pane-[0-9]+ +\(agent "bun-vitest-lane-b"'
    assert_nomatch "failed move, rerun: no unplaced line left" "$(cat "$RUNM/panes.txt")" '^unplaced lane B:'
    assert_match "failed move, rerun: prints the next step" "$out" 'lane B ready'
    assert_eq "failed move, rerun: lane B owns its tasks" "$(board "$RUNM" '",".join(d["lanes"].get("B", []))')" "2,3"
    assert_match "failed move, rerun: the rest of the pane map is kept" "$(cat "$RUNM/panes.txt")" '^lane A: '
    assert_match "failed move, rerun: ... the switches line too" "$(cat "$RUNM/panes.txt")" '^switches:'
    assert_eq "failed move, rerun: no scratch map left" "$(compgen -G "$RUNM/panes.txt.*" || true)" ""
    # A pane map that cannot be read when the lane's line replaces its unplaced
    # one stops there: the map is kept whole and no agent starts. A grep on PATH
    # fails only that read (exit 2, as grep does on a read error).
    r=$(fixture_repo bun-vitest); RUNG="$TMP/run-failread"; reset_stub
    (cd "$r" && "$KIT/bootstrap.sh" "$RUNG" "Fail read" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
    reset_stub; (cd "$r" && HERDR_STUB_MOVE_FAIL=1 "$KIT/add-lane.sh" "$RUNG" B feat/b main 2,3 >/dev/null 2>&1)
    gbin="$TMP/grep-fails-map"; mkdir -p "$gbin"; realgrep=$(command -v grep)
    printf '#!/usr/bin/env bash\ncase "$1 $2" in "-v ^unplaced lane "*) echo "grep: "%q": read error" >&2; exit 2 ;; esac\nexec %q "$@"\n' "$RUNG/panes.txt" "$realgrep" > "$gbin/grep"; chmod +x "$gbin/grep"
    mkwt "$r" feat/b; before=$(cat "$RUNG/panes.txt")
    reset_stub; out=$(cd "$r" && PATH="$gbin:$PATH" "$KIT/add-lane.sh" "$RUNG" B feat/b main 2,3 2>&1; echo "exit=$?")
    assert_match "map read fails: add-lane fails"        "$out" 'exit=1$'
    assert_match "map read fails: says how to recover"   "$out" "could not rewrite .*/panes\.txt; lane B's pane is pane-[0-9]+: turn its unplaced line into  lane B: pane-[0-9]+  \(the rest as it is\) and rerun"
    assert_eq "map read fails: the pane map is unchanged" "$(cat "$RUNG/panes.txt")" "$before"
    assert_nomatch "map read fails: no agent start"      "$(cat "$HERDR_STUB_LOG")" '^herdr agent start'
    assert_eq "map read fails: no scratch map left"      "$(compgen -G "$RUNG/panes.txt.*" || true)" ""
    # A pane map written before the lanes tab: no lanes tab line, no tab on
    # lane A's line. Its lanes are in the orchestrator's tab, and a new lane
    # goes there.
    r=$(fixture_repo bun-vitest); RUNO="$TMP/run-oldmap"; reset_stub
    (cd "$r" && "$KIT/bootstrap.sh" "$RUNO" "Old map" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
    sed -i.bak -e '/^lanes tab:/d' -e 's/, tab lanes)$/)/' "$RUNO/panes.txt"
    reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNO" B feat/b main 2 2>&1; echo "exit=$?")
    assert_match "older pane map: lane B is added"       "$out" 'exit=0$'
    assert_match "older pane map: right of lane A, in the orchestrator's tab" "$(cat "$HERDR_STUB_LOG")" '^herdr pane move pane-[0-9]+ --tab tab-0 --split right --target-pane pane-3 '
    assert_match "older pane map: the new lane's line keeps the old shape, no tab" "$(cat "$RUNO/panes.txt")" '^lane B: .*, model [^,]+\)$'
    reset_stub; out=$(cd "$r" && HERDR_STUB_BUSY_STARTS=99 START_TRIES=1 "$KIT/add-lane.sh" "$RUNO" C feat/c main 3 2>&1; echo "exit=$?")
    assert_match "older pane map: a failed start ..."    "$out" 'exit=1$'
    sed -i.bak 's/, tab lanes) starting$/) starting/' "$RUNO/panes.txt"   # as a kit from before the lanes tab wrote it
    echo gone > "$HERDR_STUB_STATES_DIR/bun-vitest-lane-c"; mkwt "$r" feat/c
    reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNO" C feat/c main 3 2>&1; echo "exit=$?"); rm -f "$HERDR_STUB_STATES_DIR/bun-vitest-lane-c"
    assert_match "older pane map: ... and its rerun resumes the lane" "$out" 'exit=0$'
    # A lane's line keeps its place in the pane map when it is rewritten, so the
    # grid follows the order the lanes were placed: B's start fails, C is
    # added, B is started again, and D still goes under B.
    r=$(fixture_repo bun-vitest); RUNO="$TMP/run-order"; reset_stub
    (cd "$r" && "$KIT/bootstrap.sh" "$RUNO" "Order" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
    (cd "$r" && HERDR_STUB_BUSY_STARTS=99 START_TRIES=1 "$KIT/add-lane.sh" "$RUNO" B feat/b main 2 >/dev/null 2>&1)
    (cd "$r" && "$KIT/add-lane.sh" "$RUNO" C feat/c main 3 >/dev/null 2>&1)
    echo gone > "$HERDR_STUB_STATES_DIR/bun-vitest-lane-b"; mkwt "$r" feat/b
    (cd "$r" && "$KIT/add-lane.sh" "$RUNO" B feat/b main 2 >/dev/null 2>&1); rm -f "$HERDR_STUB_STATES_DIR/bun-vitest-lane-b"
    bpane=$(sed -nE 's/^lane B: +([^ ]+).*/\1/p' "$RUNO/panes.txt")
    reset_stub; (cd "$r" && "$KIT/add-lane.sh" "$RUNO" D feat/d main 4 >/dev/null 2>&1)
    assert_match "a rerun keeps the grid order: D under B" "$(cat "$HERDR_STUB_LOG")" "--split down --target-pane $bpane "
    # A worktree create that fails says what may be left behind.
    r=$(fixture_repo bun-vitest); RUNW="$TMP/run-failwt"; reset_stub
    (cd "$r" && "$KIT/bootstrap.sh" "$RUNW" "Fail worktree" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
    reset_stub; out=$(cd "$r" && HERDR_STUB_WORKTREE_FAIL=1 "$KIT/add-lane.sh" "$RUNW" B feat/b main 2,3 2>&1; echo "exit=$?")
    assert_match "failed worktree create: fails"         "$out" 'exit=1$'
    assert_match "failed worktree create: says what to remove" "$out" "herdr worktree create failed: remove .*/\.worktrees/feat/b and branch feat/b if they exist, then rerun  .*/add-lane\.sh "
    assert_nomatch "failed worktree create: no move"     "$(cat "$HERDR_STUB_LOG")" '^herdr pane move'
    reset_stub; out=$(cd "$r" && HERDR_STUB_WORKTREE_FAIL=garbled "$KIT/add-lane.sh" "$RUNW" B feat/b main 2,3 2>&1; echo "exit=$?")
    assert_match "worktree create answered without a pane: says to close it too" "$out" "herdr created .*/\.worktrees/feat/b but its answer names no pane: close the pane labelled bun-vitest-lane-b, remove .*/\.worktrees/feat/b and branch feat/b, then rerun "
  fi
  # A lane whose kind is not installed: refused before tower assign and the
  # worktree, naming its CLI.
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-nokind-lane-${RUNNER:-herdr}"; reset_stub
  (cd "$r" && "$KIT/bootstrap.sh" "$RUN" "No kind lane" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
  : > "$HERDR_STUB_LOG"; : > "$ORCA_STUB_LOG"
  out=$(cd "$r" && EXECUTOR_KIND=codex CODEX_STUB=absent "$KIT/add-lane.sh" "$RUN" B feat/b main 2,3 2>&1; echo "exit=$?")
  assert_match "a lane's kind not installed: refused" "$out" 'exit=1$'
  assert_match "a lane's kind not installed: ... naming its CLI" "$out" "add-lane: lane B's kind codex runs as codex, which is not installed: install it, or set EXECUTOR_KIND to another kind"
  assert_eq "a lane's kind not installed: no lane B on the board" "$(board "$RUN" '"B" in d["lanes"]')" False
  assert_nomatch "a lane's kind not installed: no worktree" "$(cat "$HERDR_STUB_LOG" "$ORCA_STUB_LOG")" '(herdr|orca) worktree create'
fi

# --- add-reviewer ------------------------------------------------------------
if section add-reviewer; then
  if [ "${RUNNER:-herdr}" = orca ]; then
  # Orca: the slots are terminal tabs R1 and R2 in the orchestrator's
  # workspace; a new Reviewer in a slot ends the one before it with /exit,
  # closes its terminal and gets a tab of its own.
  S="$ORCA_STUB_STATES_DIR"; rm -f "$S"/*
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-orca-review"; reset_stub; WS="repo-0::$r"
  (cd "$r" && "$KIT/bootstrap.sh" "$RUN" "Orca review" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
  review() { (cd "$r" && EXIT_WAIT_SECONDS=3 "$KIT/add-reviewer.sh" "$RUN" "$@" 2>&1); }
  : > "$ORCA_STUB_LOG"; out=$(review R1 claude "Lane review A" "$RUN/findings/lane-a.json"; echo "exit=$?"); log=$(cat "$ORCA_STUB_LOG"); map=$(cat "$RUN/panes.txt")
  assert_match "orca R1: add-reviewer finishes" "$out" 'exit=0$'
  assert_nomatch "orca R1: no herdr call" "$log" '^herdr '
  assert_match "orca R1: a terminal tab R1 in the orchestrator's workspace" "$log" "^orca terminal create --worktree id:$WS --title R1 --command cd $r --json$"
  assert_match "orca R1: ... and one for R2" "$log" "^orca terminal create --worktree id:$WS --title R2 --command cd $r --json$"
  assert_match "orca R1: the Reviewer started in R1's terminal" "$log" '^orca terminal send --terminal term-4 --text codex -m gpt-6-astra '
  assert_match "pane map (orca): the review tabs" "$map" '^review tab: +tab-4,tab-5 +\(R1 term-4, R2 term-5\)$'
  assert_match "pane map (orca): reviewer R1's terminal" "$map" '^reviewer R1: +term-4 +\(agent "bun-vitest-r1-1", kind codex, model gpt-6-astra, review "Lane review A", findings '"$RUN"'/findings/lane-a.json\)$'
  assert_match "orca R1: the next step sends the brief with send-brief.sh" "$out" 'send-brief\.sh .* bun-vitest-r1-1 .*/brief-R1-1\.md  and add'
  echo waiting > "$S/term-4"
  : > "$ORCA_STUB_LOG"; out=$(review R1 claude "Lane review A again" "$RUN/findings/lane-a-2.json"; echo "exit=$?"); log=$(cat "$ORCA_STUB_LOG"); map=$(cat "$RUN/panes.txt")
  assert_match "orca R1 again: add-reviewer finishes" "$out" 'exit=0$'
  assert_match "orca R1 again: /exit sent alone to the previous Reviewer" "$log" '^orca terminal send --terminal term-4 --text /exit --json$'
  assert_match "orca R1 again: ... then Enter alone" "$log" '^orca terminal send --terminal term-4 --enter --json$'
  assert_match "orca R1 again: ... then its terminal closed" "$log" '^orca terminal close --terminal term-4 --json$'
  assert_match "orca R1 again: a new tab R1 for the new Reviewer" "$log" "^orca terminal create --worktree id:$WS --title R1 --command cd $r --json$"
  assert_match "orca R1 again: started there" "$log" '^orca terminal send --terminal term-6 --text codex '
  assert_match "pane map (orca): reviewer R1's new terminal" "$map" '^reviewer R1: +term-6 +\(agent "bun-vitest-r1-2", '
  echo working > "$S/term-6"
  : > "$ORCA_STUB_LOG"; out=$(review R1 claude "Lane review A third" "$RUN/findings/lane-a-3.json"; echo "exit=$?")
  assert_match "orca R1, its Reviewer working: refused" "$out" 'Reviewer bun-vitest-r1-2 is still working in R1'
  assert_nomatch "orca R1, its Reviewer working: nothing sent or opened" "$(cat "$ORCA_STUB_LOG")" '^orca terminal (send|create|close) '
  # A Reviewer whose start failed and that now accepts input is resumed in
  # its own terminal, not the slot's first one.
  echo waiting > "$S/term-6"; sed -i.bak '/^reviewer R1:/s/)$/) starting/' "$RUN/panes.txt"
  tower_run() { "$KIT/tests/stub/tower" "$@" --run "$RUN" >/dev/null 2>&1; }
  tower_run remove R1-3
  : > "$ORCA_STUB_LOG"; out=$(review R1 claude "Lane review A again" "$RUN/findings/lane-a-2.json"; echo "exit=$?")
  assert_match "orca R1 resumed: in its own terminal" "$out" 'resuming bun-vitest-r1-2 in term-6'
  assert_nomatch "orca R1 resumed: nothing opened or closed" "$(cat "$ORCA_STUB_LOG")" '^orca terminal (create|close) '
  # A Reviewer's terminal at a bare shell (a refused launch, or one that
  # exited) is never resumed as ready: still starting, it waits for someone to
  # look and mark it unsent; unsent, the Reviewer starts there.
  echo unlisted-shell-launch > "$S/term-6"; sed -i.bak '/^reviewer R1:/s/)$/) starting/' "$RUN/panes.txt"
  : > "$ORCA_STUB_LOG"; out=$(review R1 claude "Lane review A again" "$RUN/findings/lane-a-2.json"; echo "exit=$?")
  assert_nomatch "orca R1, starting at a bare shell: not resumed as ready" "$out" 'resuming'
  assert_match "orca R1, starting at a bare shell: says to look, then mark it unsent" "$out" "Reviewer bun-vitest-r1-2's terminal term-6 shows a shell, not the Reviewer: .* end reviewer R1's line in $RUN/panes\\.txt with \" unsent\" instead of \" starting\""
  assert_nomatch "orca R1, starting at a bare shell: nothing typed into it" "$(cat "$ORCA_STUB_LOG")" '^orca terminal send '
  sed -i.bak '/^reviewer R1:/s/ starting$/ unsent/' "$RUN/panes.txt"
  : > "$ORCA_STUB_LOG"; out=$(review R1 claude "Lane review A again" "$RUN/findings/lane-a-2.json"; echo "exit=$?")
  assert_match "orca R1, unsent at a shell: add-reviewer finishes" "$out" 'exit=0$'
  assert_match "orca R1, unsent at a shell: its Reviewer started in that terminal" "$(cat "$ORCA_STUB_LOG")" '^orca terminal send --terminal term-6 --text codex '
  assert_nomatch "orca R1, unsent at a shell: no /exit typed into it" "$(cat "$ORCA_STUB_LOG")" 'text /exit'
  assert_match "orca R1, unsent at a shell: the same review" "$(cat "$RUN/panes.txt")" '^reviewer R1: +term-6 +\(agent "bun-vitest-r1-2", .*\)$'
  # A launch Orca refused (nothing typed) marks the line unsent; one with no
  # receipt stays starting, and says to look first.
  sed -i.bak '/^reviewer R1:/s/$/ ended/' "$RUN/panes.txt"; echo gone > "$S/term-6"
  out=$(ORCA_STUB_SEND_FAIL=refused review R1 claude "Lane review A next" "$RUN/findings/lane-a-n.json"; echo "exit=$?")
  assert_match "orca R1, a refused launch: says a rerun starts it" "$out" "Reviewer bun-vitest-r1-3's launch was never sent: rerun  .*add-reviewer\\.sh .* to start it in term-7"
  assert_match "orca R1, a refused launch: its line unsent" "$(cat "$RUN/panes.txt")" '^reviewer R1: +term-7 +\(agent "bun-vitest-r1-3", .*\) unsent$'
  sed -i.bak '/^reviewer R1:/s/ unsent$/ ended/' "$RUN/panes.txt"; echo gone > "$S/term-7"
  out=$(ORCA_STUB_SEND_FAIL=unknown review R1 claude "Lane review A next" "$RUN/findings/lane-a-n.json"; echo "exit=$?")
  assert_match "orca R1, a launch with no receipt: look at the terminal first" "$out" "Orca cannot say whether Reviewer bun-vitest-r1-4's launch reached term-8 \\(no receipt\\): look at that terminal before anything is sent again"
  assert_match "orca R1, a launch with no receipt: its line starting" "$(cat "$RUN/panes.txt")" '^reviewer R1: +term-8 +\(agent "bun-vitest-r1-4", .*\) starting$'
  # That pending review rerun while its terminal is not known yet (a TUI
  # still loading, a screen Orca cannot render) or blocked on a prompt: kept
  # as it is. The rerun stops at once, saying what it read; nothing typed,
  # nothing closed.
  for st in unlisted blocked unlisted-idle:unavailable; do
    echo "${st%%:*}" > "$S/term-8"; scr=""; [ "${st#*:}" = "$st" ] || scr=${st#*:}
    : > "$ORCA_STUB_LOG"; out=$(ORCA_STUB_SCREEN=$scr review R1 claude "Lane review A next" "$RUN/findings/lane-a-n.json"; echo "exit=$?")
    assert_match "orca R1 pending, $st: stops" "$out" 'exit=1$'
    assert_match "orca R1 pending, $st: says what it read, and to look" "$out" "Reviewer bun-vitest-r1-4's review is still pending, and Orca reads its terminal term-8 as (unknown|blocked): nothing was typed into it or closed\\. Look at it there"
    assert_nomatch "orca R1 pending, $st: nothing typed, nothing closed" "$(cat "$ORCA_STUB_LOG")" '^orca terminal (send|close) '
    assert_match "orca R1 pending, $st: its line still starting" "$(cat "$RUN/panes.txt")" '^reviewer R1: +term-8 +\(agent "bun-vitest-r1-4", .*\) starting$'
  done
  # Unknown or blocked at the first read, idle at the next (a Reviewer still
  # starting, a prompt being answered): it stops on the first read, kept.
  # (An unlisted read takes two of the fake's lines: the list, then the wait.)
  for st in unlisted blocked; do
    if [ "$st" = unlisted ]; then printf 'unlisted\nunlisted\nwaiting\n' > "$S/term-8"; else printf 'blocked\nwaiting\n' > "$S/term-8"; fi
    : > "$ORCA_STUB_LOG"; out=$(review R1 claude "Lane review A next" "$RUN/findings/lane-a-n.json"; echo "exit=$?")
    assert_match "orca R1 pending, $st then idle: stops" "$out" 'exit=1$'
    assert_match "orca R1 pending, $st then idle: says what it read first" "$out" "Reviewer bun-vitest-r1-4's review is still pending, and Orca reads its terminal term-8 as (unknown|blocked): nothing was typed into it or closed"
    assert_nomatch "orca R1 pending, $st then idle: nothing typed, nothing closed" "$(cat "$ORCA_STUB_LOG")" '^orca terminal (send|close) '
    assert_match "orca R1 pending, $st then idle: its line still starting" "$(cat "$RUN/panes.txt")" '^reviewer R1: +term-8 +\(agent "bun-vitest-r1-4", .*\) starting$'
  done
  # A bare % prompt is a shell, never a ready Reviewer; the agent's footer
  # words, under a prompt-shaped status line too, resume it.
  echo unlisted-idle > "$S/term-8"; printf '%%\n' > "$S/term-8.tail"
  out=$(review R1 claude "Lane review A next" "$RUN/findings/lane-a-n.json"; echo "exit=$?")
  assert_match "orca R1 pending at a bare % prompt: a shell, not resumed" "$out" "Reviewer bun-vitest-r1-4's terminal term-8 shows a shell, not the Reviewer"
  printf '> \n  ? for shortcuts\n  acme git:(main) %%\n' > "$S/term-8.tail"
  out=$(review R1 claude "Lane review A next" "$RUN/findings/lane-a-n.json"; echo "exit=$?")
  assert_match "orca R1 pending, footer words on screen: resumed" "$out" 'resuming bun-vitest-r1-4 in term-8'
  rm -f "$S/term-8.tail"
  rm -f "$RUN/panes.txt.bak"
  rm -f "$S"/*
  # A workspace whose checkout path holds a space: the slots, and a new
  # Reviewer's tab, open in the whole workspace.
  rs=$(fixture_repo bun-vitest); mkdir -p "$TMP/review space"; mv "$(dirname "$rs")" "$TMP/review space/r"; rs="$TMP/review space/r/bun-vitest"
  RUNS="$TMP/run-orca-review-space"; reset_stub; (cd "$rs" && "$KIT/bootstrap.sh" "$RUNS" "Orca review space" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
  : > "$ORCA_STUB_LOG"; (cd "$rs" && EXIT_WAIT_SECONDS=3 "$KIT/add-reviewer.sh" "$RUNS" R1 claude "Lane review A" "$RUNS/findings/a.json" >/dev/null 2>&1)
  assert_match "orca, a space in the workspace: the slots open in it whole" "$(cat "$ORCA_STUB_LOG")" "^orca terminal create --worktree id:repo-0::$rs --title R1 "
  r1=$(sed -nE 's/^reviewer R1: +([^ ]+).*/\1/p' "$RUNS/panes.txt"); echo waiting > "$S/$r1"
  : > "$ORCA_STUB_LOG"; (cd "$rs" && EXIT_WAIT_SECONDS=3 "$KIT/add-reviewer.sh" "$RUNS" R1 claude "Lane review A again" "$RUNS/findings/a-2.json" >/dev/null 2>&1)
  assert_match "orca, a space in the workspace: a new Reviewer's tab opens in it whole" "$(cat "$ORCA_STUB_LOG")" "^orca terminal create --worktree id:repo-0::$rs --title R1 "
  # The Reviewer's handle gone stale (Orca restarted): it may still run, so
  # nothing is ended, closed or opened; the operator rebinds the handle.
  r1=$(sed -nE 's/^reviewer R1: +([^ ]+).*/\1/p' "$RUNS/panes.txt"); echo gone > "$S/$r1"
  : > "$ORCA_STUB_LOG"; out=$(cd "$rs" && EXIT_WAIT_SECONDS=3 "$KIT/add-reviewer.sh" "$RUNS" R1 claude "Lane review A third" "$RUNS/findings/a-3.json" 2>&1; echo "exit=$?")
  assert_match "orca R1, a stale handle: refused" "$out" 'exit=1$'
  assert_match "orca R1, a stale handle: asks to rebind it" "$out" "Orca says Reviewer bun-vitest-r1-2's terminal handle $r1 is stale: .* put its handle on reviewer R1's line in $RUNS/panes\\.txt and record it with  .*bind-pane\\.sh $RUNS bun-vitest-r1-2 <its handle>, then rerun"
  assert_nomatch "orca R1, a stale handle: nothing sent, closed or opened" "$(cat "$ORCA_STUB_LOG")" '^orca terminal (send|close|create) '
  # A slot's own terminal gone stale before its first Reviewer: rebound too.
  r2=$(sed -nE 's/^review tab: .*R2 ([^,)]+).*/\1/p' "$RUNS/panes.txt"); echo gone > "$S/$r2"
  : > "$ORCA_STUB_LOG"; out=$(cd "$rs" && EXIT_WAIT_SECONDS=3 "$KIT/add-reviewer.sh" "$RUNS" R2 claude "Preflight" "$RUNS/findings/p.json" 2>&1; echo "exit=$?")
  assert_match "orca R2, its slot's handle stale: asks to rebind it" "$out" "Orca says Reviewer slot R2's terminal handle $r2 is stale"
  assert_nomatch "orca R2, its slot's handle stale: nothing sent or opened" "$(cat "$ORCA_STUB_LOG")" '^orca terminal (send|create) '
  # A Reviewer this script ended, then a failure: the rerun goes on, its
  # terminal closed, not stale.
  rm -f "$S/$r1" "$S/$r2"; r1=$(sed -nE 's/^reviewer R1: +([^ ]+).*/\1/p' "$RUNS/panes.txt")
  sed -i.bak "/^reviewer R1:/s/\$/ ended/" "$RUNS/panes.txt"; rm -f "$RUNS/panes.txt.bak"; echo gone > "$S/$r1"
  : > "$ORCA_STUB_LOG"; out=$(cd "$rs" && EXIT_WAIT_SECONDS=3 "$KIT/add-reviewer.sh" "$RUNS" R1 claude "Lane review A fourth" "$RUNS/findings/a-4.json" 2>&1; echo "exit=$?")
  assert_match "orca R1, its last Reviewer ended by this script: goes on" "$out" 'exit=0$'
  assert_match "orca R1, ... in a new tab" "$(cat "$ORCA_STUB_LOG")" "^orca terminal create --worktree id:repo-0::$rs --title R1 "
  rm -f "$S"/*
  # R2's tab failing after R1's opened: R1 is recorded at once, and the rerun
  # opens R2 alone.
  rp=$(fixture_repo bun-vitest); RUNP="$TMP/run-orca-partial"; reset_stub
  (cd "$rp" && "$KIT/bootstrap.sh" "$RUNP" "Orca partial" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
  : > "$ORCA_STUB_LOG"; out=$(cd "$rp" && ORCA_STUB_CREATE_FAIL=R2 EXIT_WAIT_SECONDS=3 "$KIT/add-reviewer.sh" "$RUNP" R1 claude "Lane review A" "$RUNP/findings/a.json" 2>&1; echo "exit=$?")
  assert_match "orca, R2's tab fails: refused" "$out" 'exit=1$'
  assert_match "orca, R2's tab fails: R1 recorded at once" "$(cat "$RUNP/panes.txt")" '^review tab: +tab-[0-9]+ +\(R1 term-[0-9]+\)$'
  assert_match "orca, R2's tab fails: says the rerun opens R2" "$out" "opened R1's tab but not R2's: rerun  .*add-reviewer\\.sh"
  : > "$ORCA_STUB_LOG"; out=$(cd "$rp" && EXIT_WAIT_SECONDS=3 "$KIT/add-reviewer.sh" "$RUNP" R1 claude "Lane review A" "$RUNP/findings/a.json" 2>&1; echo "exit=$?")
  assert_match "orca, rerun: goes on" "$out" 'exit=0$'
  assert_eq "orca, rerun: R2's tab opened" "$(grep -c '^orca terminal create .*--title R2 ' "$ORCA_STUB_LOG")" 1
  assert_eq "orca, rerun: no second R1 tab" "$(grep -c '^orca terminal create .*--title R1 ' "$ORCA_STUB_LOG")" 0
  assert_match "orca, rerun: both slots recorded" "$(cat "$RUNP/panes.txt")" '^review tab: +tab-[0-9]+,tab-[0-9]+ +\(R1 term-[0-9]+, R2 term-[0-9]+\)$'
  assert_eq "orca, rerun: one review tab line" "$(grep -c '^review tab:' "$RUNP/panes.txt")" 1
  # R1 is in the map before R2's tab is asked for (an interrupt there leaves
  # it recorded); a findings dir that cannot be made stops the call before a
  # Reviewer's tab opens.
  rp=$(fixture_repo bun-vitest); RUNP="$TMP/run-orca-order"; reset_stub
  (cd "$rp" && "$KIT/bootstrap.sh" "$RUNP" "Orca order" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
  : > "$ORCA_STUB_LOG"; (cd "$rp" && ORCA_STUB_PEEK="$RUNP/panes.txt" EXIT_WAIT_SECONDS=3 "$KIT/add-reviewer.sh" "$RUNP" R1 claude "Lane review A" "$RUNP/findings/a.json" >/dev/null 2>&1)
  assert_match "orca: R1 recorded before R2's tab is asked for" "$(grep -A2 -- '--title R2 ' "$ORCA_STUB_LOG")" '^peek: review tab: +tab-[0-9]+ +\(R1 term-[0-9]+\)$'
  r1=$(sed -nE 's/^reviewer R1: +([^ ]+).*/\1/p' "$RUNP/panes.txt"); echo waiting > "$S/$r1"; : > "$RUNP/notadir"
  : > "$ORCA_STUB_LOG"; out=$(cd "$rp" && EXIT_WAIT_SECONDS=3 "$KIT/add-reviewer.sh" "$RUNP" R1 claude "Lane review A again" "$RUNP/notadir/a.json" 2>&1; echo "exit=$?")
  assert_match "orca: findings dir not made: refused" "$out" 'exit=1$'
  assert_nomatch "orca: findings dir not made: no Reviewer tab opened" "$(cat "$ORCA_STUB_LOG")" '^orca terminal create '
  rm -f "$S/$r1"
  # The same in a run whose slots open as its lanes tab (lane A in another
  # tab, no lanes tab yet): the rerun keeps that line's key.
  rp=$(fixture_repo bun-vitest); RUNP="$TMP/run-orca-partial-lanes"; reset_stub
  (cd "$rp" && "$KIT/bootstrap.sh" "$RUNP" "Orca partial lanes" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
  sed -i.bak -e '/^lanes tab:/d' -e '/^lane A:/s/, tab lanes)/, tab research)/' "$RUNP/panes.txt"; rm -f "$RUNP/panes.txt.bak"
  (cd "$rp" && ORCA_STUB_CREATE_FAIL=R2 EXIT_WAIT_SECONDS=3 "$KIT/add-reviewer.sh" "$RUNP" R1 claude "Lane review A" "$RUNP/findings/a.json" >/dev/null 2>&1)
  assert_match "orca, R2 fails, slots as the lanes tab: R1 recorded there" "$(cat "$RUNP/panes.txt")" '^lanes tab: +tab-[0-9]+ +\(R1 term-[0-9]+\)$'
  (cd "$rp" && EXIT_WAIT_SECONDS=3 "$KIT/add-reviewer.sh" "$RUNP" R1 claude "Lane review A" "$RUNP/findings/a.json" >/dev/null 2>&1)
  assert_match "orca, rerun: the lanes tab line holds both slots" "$(cat "$RUNP/panes.txt")" '^lanes tab: +tab-[0-9]+,tab-[0-9]+ +\(R1 term-[0-9]+, R2 term-[0-9]+\)$'
  assert_eq "orca, rerun: one slot line in all" "$(grep -cE '^(lanes|review) tab:' "$RUNP/panes.txt")" 1
  rm -f "$S"/*
  else
    S="$HERDR_STUB_STATES_DIR"
    r=$(fixture_repo bun-vitest); RUN="$TMP/run-review"; reset_stub
    (cd "$r" && "$KIT/bootstrap.sh" "$RUN" "Review" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
    review() { (cd "$r" && EXIT_WAIT_SECONDS=3 "$KIT/add-reviewer.sh" "$RUN" "$@" 2>&1); }
    line_of() { grep -nE -- "$1" "$HERDR_STUB_LOG" | head -1 | cut -d: -f1; }
    reset_stub; out=$(review R1 claude "Lane review A" "$RUN/findings/lane-a.json"); log=$(cat "$HERDR_STUB_LOG")
    assert_nomatch "first call: no tab is opened, no pane split" "$log" '^herdr (tab create|pane split) '
    map=$(cat "$RUN/panes.txt")
    assert_nomatch "pane map: no review tab line"       "$map" '^review tab:'
    assert_match "pane map: the lanes tab line as bootstrap wrote it" "$map" '^lanes tab: +tab-3 +\(R1 pane-4, R2 pane-5\)$'
    assert_match "pane map: reviewer R1 line"           "$map" '^reviewer R1: +pane-4 +\(agent "bun-vitest-r1-1", kind codex, model gpt-6-astra, review "Lane review A", findings '"$RUN"'/findings/lane-a.json\)$'
    assert_match "R1: a claude lane gets a codex Reviewer" "$log" '^herdr agent start bun-vitest-r1-1 --kind codex --pane pane-4 -- -m gpt-6-astra '
    reviews() { board "$1" '" ".join(t["id"]+"@"+t["lane"]+":"+t["title"] for t in d["tasks"] if t["area"] == "review")'; }
    assert_eq "R1: the review is a board task owned by the slot" "$(reviews "$RUN")" "R1-1@R1:Lane review A"
    assert_match "R1: prints the task id and the next step" "$out" 'reviewer R1 ready \(task R1-1\): agent bun-vitest-r1-1'
    [ -d "$RUN/findings" ] && ok "R1: the findings dir exists" || bad "R1: the findings dir exists"
    # A codex Reviewer's temp files and package caches go to the run dir, which
    # its sandbox can write: the commands it runs get them in their environment.
    for v in TMPDIR BUN_TMPDIR BUN_INSTALL_CACHE_DIR npm_config_cache; do
      assert_match "codex Reviewer: $v is the run dir's tmp" "$log" "^herdr agent start bun-vitest-r1-1 .* -c shell_environment_policy\\.set\\.$v=\"$RUN/tmp\"( |\$)"
    done
    [ -d "$RUN/tmp" ] && ok "codex Reviewer: the run dir's tmp exists" || bad "codex Reviewer: the run dir's tmp exists"
    # ... and it may write look's worktree dir, outside what any lane may write.
    assert_match "codex Reviewer: look's worktree dir is writable" "$log" "^herdr agent start bun-vitest-r1-1 .* --add-dir $XDG_STATE_HOME/tower/look( |\$)"
    assert_eq "codex Reviewer: ... it exists, mode 700" "$(ls -ld "$XDG_STATE_HOME/tower/look" 2>/dev/null | cut -c1-10)" drwx------

    reset_stub; out=$(review R2 codex "Lane review B" "$RUN/findings/lane-b.json"); log=$(cat "$HERDR_STUB_LOG")
    assert_nomatch "second call: no new tab"            "$log" '^herdr tab create'
    assert_nomatch "second call: no new pane"           "$log" '^herdr pane split'
    assert_match "R2: a codex lane gets a claude Reviewer in the R2 pane" "$log" '^herdr agent start bun-vitest-r2-1 --kind claude --pane pane-5 -- --model claude-opus-5-5$'
    assert_nomatch "claude Reviewer: no codex environment" "$log" 'shell_environment_policy'
    assert_nomatch "claude Reviewer: no look dir grant" "$log" 'tower/look'
    assert_match "brief: the Reviewer's look command names the run dir" "$(grep 'look.sh origin/main' "$KIT/brief-template.md")" 'TOWER_RUN=\{\{RUN_DIR\}\} '
    # A tower/look that is a symlink could point anywhere: never granted.
    L="$XDG_STATE_HOME/tower/look"; mv "$L" "$L.real"; mkdir -p "$TMP/sym-target"; ln -s "$TMP/sym-target" "$L"
    echo gone > "$S/bun-vitest-r1-1"; reset_stub
    out=$(review R1 claude "Sym" "$RUN/findings/sym.json"; echo "exit=$?")
    rm "$L"; mv "$L.real" "$L"
    assert_match "codex Reviewer, look dir a symlink: refused" "$out" "its worktree dir $L is a symlink"
    assert_match "... and fails"                        "$out" 'exit=1$'
    assert_nomatch "... no agent start"                 "$(cat "$HERDR_STUB_LOG")" '^herdr agent start'
    # add-reviewer refuses what look refuses (look.sh --dir, one check): a look
    # dir under the git dir, a worktree, the run dir, the checkout, TMPDIR or /tmp.
    pin=$(sed -nE 's/^contract: +//p' "$RUN/panes.txt")
    grant_refused() {  # WHAT XDG [ENV...]: the pin copied along, so only the look dir differs
      local what=$1 x=$2; shift 2
      mkdir -p "$x/tower/contracts"; cp "$pin" "$x/tower/contracts/"
      echo gone > "$S/bun-vitest-r1-1"; reset_stub
      out=$(cd "$r" && env XDG_STATE_HOME="$x" EXIT_WAIT_SECONDS=3 "$@" "$KIT/add-reviewer.sh" "$RUN" R1 claude "Where" "$RUN/findings/where.json" 2>&1; echo "exit=$?")
      assert_match "codex Reviewer, look dir under $what: refused" "$out" "its worktree dir .* is under $what"
      assert_match "... fails"                          "$out" 'exit=1$'
      assert_nomatch "... no agent start"               "$(cat "$HERDR_STUB_LOG")" '^herdr agent start'
      rm -f "$S/bun-vitest-r1-1"; rm -rf "$x"
    }
    grant_refused "the git dir" "$r/.git/xdg"
    git -C "$r" worktree add -q --detach "$LOOK_STATE/review-wt"
    grant_refused "a worktree of this repo" "$LOOK_STATE/review-wt/xdg"
    git -C "$r" worktree remove --force "$LOOK_STATE/review-wt"
    grant_refused "the run dir" "$RUN/xdg"
    grant_refused "the checkout" "$r/xdg"
    mkdir -p "$LOOK_STATE/review-tmp"; grant_refused "TMPDIR" "$LOOK_STATE/review-tmp/xdg" TMPDIR="$LOOK_STATE/review-tmp"
    grant_refused "/tmp" "/tmp/tower-test-xdg.$$" TMPDIR="$LOOK_STATE/review-tmp"   # TMPDIR may be /tmp itself
    unset -f grant_refused
    rm -f "$S/bun-vitest-r1-1"
    assert_eq "R2: board task owned by R2"              "$(reviews "$RUN")" "R1-1@R1:Lane review A R2-1@R2:Lane review B"
    assert_eq "pane map: no review tab line, one lanes tab line" "$(grep -c '^review tab:' "$RUN/panes.txt")|$(grep -c '^lanes tab:' "$RUN/panes.txt")" "0|1"

    printf 'working\n' > "$S/bun-vitest-r1-1"; reset_stub
    out=$(review R1 claude "Lane review A, round 2" "$RUN/findings/lane-a-2.json")
    assert_match "a slot whose Reviewer is still working is refused" "$out" 'bun-vitest-r1-1 is still working in R1'
    assert_nomatch "that refusal starts nothing"        "$(cat "$HERDR_STUB_LOG")" '^herdr (agent start|pane send)'
    assert_eq "that refusal adds no board task"         "$(reviews "$RUN")" "R1-1@R1:Lane review A R2-1@R2:Lane review B"
    printf 'idle\ngone\n' > "$S/bun-vitest-r1-1"; reset_stub
    out=$(review R1 claude "Lane review A, round 2" "$RUN/findings/lane-a-2.json"); log=$(cat "$HERDR_STUB_LOG")
    assert_match "again in R1: the previous Reviewer is sent /exit" "$log" '^herdr pane send-text pane-4 /exit$'
    assert_match "again in R1: and Enter"               "$log" '^herdr pane send-keys pane-4 Enter$'
    assert_eq "again in R1: one Enter when the first one ends it" "$(grep -c '^herdr pane send-keys pane-4 Enter$' "$HERDR_STUB_LOG")" 1
    [ "$(line_of '^herdr pane send-keys pane-4 Enter')" -lt "$(line_of '^herdr agent start')" ] && ok "again in R1: ended before the new agent starts" || bad "again in R1: ended before the new agent starts" "$log"
    assert_match "again in R1: a new agent in the same pane" "$log" '^herdr agent start bun-vitest-r1-2 --kind codex --pane pane-4 '
    assert_eq "pane map: one line per slot"             "$(grep -c '^reviewer R1:' "$RUN/panes.txt")" 1
    assert_match "pane map: the slot line is the new review" "$(cat "$RUN/panes.txt")" '^reviewer R1: +pane-4 +\(agent "bun-vitest-r1-2", .*review "Lane review A, round 2"'
    assert_match "pane map: R2 line kept"               "$(cat "$RUN/panes.txt")" '^reviewer R2: +pane-5 +\(agent "bun-vitest-r2-1"'

    printf 'idle\n' > "$S/bun-vitest-r1-2"; reset_stub
    out=$(review R1 claude "Preflight R1" "$RUN/findings/preflight-r1.json")
    assert_match "a Reviewer that does not exit is refused" "$out" 'bun-vitest-r1-2 did not exit; end it in pane-4 and rerun'
    assert_eq "within 3 checks, one Enter: no retry storm" "$(grep -c '^herdr pane send-keys pane-4 Enter$' "$HERDR_STUB_LOG")" 1
    assert_nomatch "that refusal starts no agent"       "$(cat "$HERDR_STUB_LOG")" '^herdr agent start'
    assert_nomatch "that refusal adds no board task"    "$(reviews "$RUN")" 'R1-3'
    # herdr failing for another reason than agent_not_found is not the previous
    # Reviewer having exited.
    echo unreachable > "$S/bun-vitest-r1-2"; reset_stub
    out=$(review R1 claude "Preflight R1" "$RUN/findings/preflight-r1.json")
    assert_match "herdr failing: refused, the previous Reviewer's state unreadable" "$out" 'herdr cannot say whether Reviewer bun-vitest-r1-2 is still there'
    assert_nomatch "herdr failing: nothing sent, nothing started" "$(cat "$HERDR_STUB_LOG")" '^herdr (pane send|agent start)'
    assert_nomatch "herdr failing: no board task"       "$(reviews "$RUN")" 'R1-3'
    printf 'idle\nunreachable\n' > "$S/bun-vitest-r1-2"; reset_stub
    out=$(EXIT_WAIT_SECONDS=2 review R1 claude "Preflight R1" "$RUN/findings/preflight-r1.json")
    assert_match "herdr failing after /exit: /exit was sent" "$(cat "$HERDR_STUB_LOG")" '^herdr pane send-text pane-4 /exit$'
    assert_match "herdr failing after /exit: not read as exited, herdr named" "$out" 'herdr cannot say whether Reviewer bun-vitest-r1-2 exited'
    assert_nomatch "herdr failing after /exit: no agent start" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start'
    # herdr's own unknown status is an agent it cannot classify: it is there,
    # and is sent /exit like an idle one.
    echo unknown > "$S/bun-vitest-r1-2"; reset_stub
    out=$(EXIT_WAIT_SECONDS=2 review R1 claude "Preflight R1" "$RUN/findings/preflight-r1.json")
    assert_match "herdr's unknown: the previous Reviewer is sent /exit" "$(cat "$HERDR_STUB_LOG")" '^herdr pane send-text pane-4 /exit$'
    assert_match "herdr's unknown: ... and waited for"  "$out" 'bun-vitest-r1-2 did not exit'
    echo gone > "$S/bun-vitest-r1-2"; reset_stub
    out=$(REVIEWER_MODEL=gpt-6-astra-pro review R1 claude "Preflight R1" "$RUN/findings/preflight-r1.json"); log=$(cat "$HERDR_STUB_LOG")
    assert_nomatch "an exited Reviewer is not sent /exit" "$log" '^herdr pane send-text'
    assert_match "REVIEWER_MODEL reaches the agent start" "$log" '^herdr agent start bun-vitest-r1-3 --kind codex --pane pane-4 -- -m gpt-6-astra-pro '
    echo gone > "$S/bun-vitest-r2-1"
    out=$(CODEX_STUB=absent review R2 claude "Preflight R2" "$RUN/findings/preflight-r2.json")
    assert_match "a fallback is printed"                "$out" '^reviewer: fallback: codex is not installed'
    assert_match "a slot other than R1 or R2 is refused" "$(review R3 claude "X" "$RUN/findings/x.json")" "slot must be R1 or R2 \(got 'R3'\)"
    assert_match "a bad lane kind is refused"            "$(review R1 gemini "X" "$RUN/findings/x.json")" "lane kind must be claude, codex or cursor \(got 'gemini'\)"
    assert_match "a bad REVIEW_STAGE is refused"         "$(REVIEW_STAGE=final review R1 claude "X" "$RUN/findings/x.json")" "REVIEW_STAGE must be lane or preflight \(got 'final'\)"
    # A title is one field of one pane map line: a control character in it is
    # refused before the board, the map or an agent sees it.
    for c in "newline:$(printf 'two\nlines')" "tab:$(printf 'a\ttab')" "carriage return:$(printf 'a\rcr')"; do
      kind=${c%%:*}; t=${c#*:}
      cp "$RUN/panes.txt" "$TMP/panes-before"; : > "$HERDR_STUB_LOG"
      out=$(review R2 claude "$t" "$RUN/findings/t.json"; echo "exit=$?")
      assert_match "a title with a $kind: refused"       "$out" 'the review title must not hold a tab, a newline or another control character'
      assert_match "a title with a $kind: fails"         "$out" 'exit=1$'
      assert_eq "a title with a $kind: the pane map untouched" "$(cmp -s "$TMP/panes-before" "$RUN/panes.txt" && echo same || echo changed)" same
      assert_nomatch "a title with a $kind: no task on the board" "$(reviews "$RUN")" 'two|tab|cr'
      assert_nomatch "a title with a $kind: no herdr call" "$(cat "$HERDR_STUB_LOG")" '^herdr (tab|pane|agent) '
    done
    rm -f "$TMP/panes-before"
    assert_match "no pane map: refused"                 "$(cd "$r" && "$KIT/add-reviewer.sh" "$TMP/nowhere" R1 claude "X" x.json 2>&1)" 'run bootstrap.sh first'
    cr=$(fixture_repo contract-switches); mkdir -p "$cr/sub"; RUNS="$TMP/run-review-sub"
    (cd "$cr" && "$KIT/bootstrap.sh" "$RUNS" "Sub" main >/dev/null 2>&1); reset_stub
    out=$(cd "$cr/sub" && "$KIT/add-reviewer.sh" "$RUNS" R1 claude "From a subdir" "$RUNS/findings/sub.json" 2>&1)
    assert_match "from a subdirectory: the repo contract's REVIEWER_KIND and model are used" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start contract-switches-r1-1 --kind claude --pane [^ ]+ -- --model claude-fable-5-1$'
    assert_match "from a subdirectory: the tab opens in the repo root" "$(cat "$HERDR_STUB_LOG")" "^herdr tab create --workspace ws-0 --cwd $cr --label"
    RUNK="$TMP/run-review-switches"; reset_stub
    r=$(fixture_repo bun-vitest); (cd "$r" && REVIEWER_KIND=claude REVIEWER_MODEL=claude-sonnet-5 "$KIT/bootstrap.sh" "$RUNK" "Switches" main >/dev/null 2>&1); reset_stub
    out=$(cd "$r" && "$KIT/add-reviewer.sh" "$RUNK" R1 claude "Lane review A" "$RUNK/findings/a.json" 2>&1)
    assert_match "the run's switches from bootstrap reach the Reviewer" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-r1-1 --kind claude --pane [^ ]+ -- --model claude-sonnet-5$'
    out=$(cd "$r" && EXIT_WAIT_SECONDS=0 REVIEWER_KIND=codex "$KIT/add-reviewer.sh" "$RUNK" R2 claude "Lane review A" "$RUNK/findings/b.json" 2>&1)
    assert_match "this call's environment wins over the run's switches" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-r2-1 --kind codex --pane [^ ]+ -- -m claude-sonnet-5 '
    RUNQ="$TMP/run-review-spaces"; reset_stub
    r=$(fixture_repo bun-vitest); (cd "$r" && REVIEWER_KIND=claude REVIEWER_MODEL="it's my model *" PR_TEMPLATE="it's my template.md" "$KIT/bootstrap.sh" "$RUNQ" "Spaces" main >/dev/null 2>&1); reset_stub
    out=$(cd "$r" && "$KIT/add-reviewer.sh" "$RUNQ" R1 claude "Spaces" "$RUNQ/findings/a.json" 2>&1; echo "exit=$?")
    assert_match "a switch value with spaces: the Reviewer starts" "$out" 'exit=0$'
    assert_match "a switch value with spaces and a glob reaches the Reviewer whole" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-r1-1 --kind claude --pane [^ ]+ -- --model it.s my model \*$'
    assert_match "a switch value with spaces: the pane map quotes it" "$(cat "$RUNQ/panes.txt")" "^switches: .* REVIEWER_MODEL='it'\\\\''s my model \\*' .* PR_TEMPLATE='it'\\\\''s my template.md' TRIAGE=ask GUIDED_REVIEW=off NOTIFY=\$"
    # A mid-run edit of the user contract to values detect-stack.sh refuses:
    # the pane map's TRIAGE and NOTIFY win, so the Reviewer still starts.
    ART="$TMP/ar-uc"; mkdir -p "$ART/tower"; printf '%s\n' TRIAGE=auto 'NOTIFY=~/bin/notify' > "$ART/tower/orchestrate"
    RUNT="$TMP/run-review-triage"; rt=$(fixture_repo bun-vitest); (cd "$rt" && XDG_CONFIG_HOME="$ART" "$KIT/bootstrap.sh" "$RUNT" "Triage" main >/dev/null 2>&1)
    printf '%s\n' TRIAGE=maybe "NOTIFY='a" "b'" > "$ART/tower/orchestrate"; reset_stub
    out=$(cd "$rt" && XDG_CONFIG_HOME="$ART" "$KIT/add-reviewer.sh" "$RUNT" R1 claude "Triage" "$RUNT/findings/a.json" 2>&1; echo "exit=$?")
    assert_match "TRIAGE and NOTIFY come from the pane map: a mid-run contract edit does not reach the Reviewer" "$out" 'exit=0$'
    sed -i.bak "s/^switches: .*/switches:       PR_TEMPLATE='open/" "$RUNQ/panes.txt"
    out=$(cd "$r" && "$KIT/add-reviewer.sh" "$RUNQ" R2 claude "Bad" "$RUNQ/findings/b.json" 2>&1; echo "exit=$?")
    assert_match "a switches: line that cannot be read back is refused" "$out" "switches: line in $RUNQ/panes.txt cannot be read back"
    assert_match "that refusal exits non-zero"          "$out" 'exit=1$'
    sed -i.bak "s/^switches: .*/switches:       BASH_ENV=x/" "$RUNQ/panes.txt"
    assert_match "a switches: line naming something else is refused" "$(cd "$r" && "$KIT/add-reviewer.sh" "$RUNQ" R2 claude "Bad" "$RUNQ/findings/b.json" 2>&1)" "holds 'BASH_ENV=x', not a run switch"
    # A copy is another run dir: it needs its own pinned contract (detect-stack.sh).
    pin_of() { (cd "$r" && bash -c '. "$KIT/common.sh"; . "$KIT/detect-stack.sh" 2>/dev/null; contract_pin "$1"' _ "$1"); }
    CTL="$TMP/ctl"$'\t'"run"; cp -R "$RUNK" "$CTL"; cp "$(pin_of "$RUNK")" "$(pin_of "$CTL")"; echo gone > "$S/bun-vitest-r2-1"; reset_stub
    out=$(cd "$r" && EXIT_WAIT_SECONDS=0 REVIEWER_KIND=codex "$KIT/add-reviewer.sh" "$CTL" R2 claude "Ctl" "$CTL/findings/c.json" 2>&1; echo "exit=$?")
    assert_match "codex Reviewer, a run dir with a control character: refused" "$out" 'the run dir .* holds a control character'
    assert_nomatch "... before any agent starts" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start'
    RELD="$TMP/rel"; mkdir -p "$RELD"; cp -R "$RUNK" "$RELD/run"
    cp "$(pin_of "$RUNK")" "$(pin_of "$RELD/run")"; reset_stub
    echo gone > "$S/bun-vitest-r2-1"   # R2's earlier Reviewer has exited (its start above made it run)
    out=$(cd "$RELD" && EXIT_WAIT_SECONDS=0 REVIEWER_KIND=codex "$KIT/add-reviewer.sh" run R2 claude "Rel" run/findings/rel.json 2>&1)
    assert_match "a relative run dir is made absolute" "$(cat "$RELD/run/panes.txt")" "^reviewer R2: .*findings $RELD/run/findings/rel.json\\)$"
    assert_match "from outside the repo, the review lands on the given run" "$(reviews "$RELD/run")" 'R2-[0-9]+@R2:Rel$'
    RUN2="$TMP/run-review-nt"; reset_stub
    r=$(fixture_repo bun-vitest); (cd "$r" && "$KIT/bootstrap.sh" "$RUN2" "NT" main "$KIT/example-tasks.tsv" >/dev/null 2>&1); reset_stub
    out=$(cd "$r" && TOWER_STUB=absent "$KIT/add-reviewer.sh" "$RUN2" R1 claude "Lane review A" "$RUN2/findings/a.json" 2>&1; echo "exit=$?")
    assert_match "tower not runnable: add-reviewer refuses with the pointer" "$out" 'needs tower.*github\.com/phutschi/tower'
    assert_match "tower not runnable: ... and fails"              "$out" 'exit=1$'
    assert_nomatch "tower not runnable: no tab, no Reviewer"      "$(cat "$HERDR_STUB_LOG")" '^herdr (tab create|pane split|agent start) '
    assert_eq "tower not runnable: no findings dir"               "$([ -e "$RUN2/findings" ] && echo made || echo none)" none
    assert_eq "tower not runnable: no review task"                "$(reviews "$RUN2")" ""
    RUNG="$TMP/run-review-gone"; reset_stub
    r=$(fixture_repo bun-vitest); (cd "$r" && "$KIT/bootstrap.sh" "$RUNG" "Gone" main >/dev/null 2>&1); reset_stub
    # A run whose lanes tab is not open yet (lane A in another tab): add-reviewer
    # opens it, so it needs the orchestrator's workspace.
    sed -i.bak -e '/^lanes tab:/d' -e 's/, tab lanes)$/, tab research)/' "$RUNG/panes.txt"
    echo gone > "$S/pane-0"; before=$(cat "$RUNG/panes.txt")
    out=$(cd "$r" && "$KIT/add-reviewer.sh" "$RUNG" R1 claude "Gone" "$RUNG/findings/a.json" 2>&1; echo "exit=$?")
    assert_match "no orchestrator pane: refused, naming it" "$out" 'no workspace for the orchestrator pane pane-0'
    assert_match "no orchestrator pane: exits non-zero" "$out" 'exit=1$'
    assert_nomatch "no orchestrator pane: no tab, no agent" "$(cat "$HERDR_STUB_LOG")" '^herdr (tab create|agent start)'
    assert_eq "no orchestrator pane: no board task"     "$(reviews "$RUNG")" ""
    assert_eq "no orchestrator pane: the pane map is unchanged" "$(cat "$RUNG/panes.txt")" "$before"
    rm -f "$S/pane-0"
    grep -v '^orchestrator:' "$RUNG/panes.txt" > "$RUNG/panes.tmp"; mv "$RUNG/panes.tmp" "$RUNG/panes.txt"
    assert_match "a pane map without an orchestrator line is refused" \
      "$(cd "$r" && "$KIT/add-reviewer.sh" "$RUNG" R1 claude "Gone" "$RUNG/findings/a.json" 2>&1)" "no orchestrator line in $RUNG/panes.txt"
    # No lanes tab yet (lane A in another tab): the first review opens it in
    # the orchestrator's workspace, R1 its root and R2 under it, and a code lane
    # added after that goes under R2.
    r=$(fixture_repo bun-vitest); RUNL="$TMP/run-review-lanes"
    (cd "$r" && "$KIT/bootstrap.sh" "$RUNL" "Lanes" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
    sed -i.bak -e '/^lanes tab:/d' -e 's/, tab lanes)$/, tab research)/' "$RUNL/panes.txt"
    reset_stub; out=$(cd "$r" && "$KIT/add-reviewer.sh" "$RUNL" R2 claude "Open" "$RUNL/findings/o.json" 2>&1; echo "exit=$?"); log=$(cat "$HERDR_STUB_LOG")
    assert_match "no lanes tab: the review finishes"     "$out" 'exit=0$'
    assert_match "no lanes tab: opened in the orchestrator's workspace" "$log" "^herdr tab create --workspace ws-0 --cwd $r --label lanes --no-focus$"
    assert_match "no lanes tab: the workspace is the orchestrator pane's" "$log" '^herdr pane get pane-0$'
    assert_match "no lanes tab: R2 under R1"             "$log" '^herdr pane split --pane pane-1 --direction down --ratio 0.5 .*--no-focus$'
    assert_match "no lanes tab: the lanes tab line"      "$(cat "$RUNL/panes.txt")" '^lanes tab: +tab-1 +\(R1 pane-1, R2 pane-2\)$'
    assert_match "no lanes tab: the Reviewer starts in R2" "$log" '^herdr agent start bun-vitest-r2-1 --kind codex --pane pane-2 '
    reset_stub; (cd "$r" && "$KIT/add-lane.sh" "$RUNL" B feat/b main 2 >/dev/null 2>&1)
    assert_match "no lanes tab: a code lane added after it goes under R2" "$(cat "$HERDR_STUB_LOG")" '^herdr pane move pane-[0-9]+ --tab tab-1 --split down --target-pane pane-2 '
    assert_match "no lanes tab: ... in tab lanes"        "$(cat "$RUNL/panes.txt")" '^lane B: .*, tab lanes\)$'
    # A run opened before the lanes tab keeps its reviews tab and its slots.
    r=$(fixture_repo bun-vitest); RUNO="$TMP/run-review-old"
    (cd "$r" && "$KIT/bootstrap.sh" "$RUNO" "Old" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
    sed -i.bak -e '/^lanes tab:/d' -e 's/, tab lanes)$/)/' "$RUNO/panes.txt"
    echo 'review tab:     tab-9   (R1 pane-21, R2 pane-22)' >> "$RUNO/panes.txt"
    reset_stub; out=$(cd "$r" && "$KIT/add-reviewer.sh" "$RUNO" R2 claude "Old" "$RUNO/findings/o.json" 2>&1; echo "exit=$?"); log=$(cat "$HERDR_STUB_LOG")
    assert_match "review tab line: the review finishes"  "$out" 'exit=0$'
    assert_nomatch "review tab line: no tab is opened"   "$log" '^herdr (tab create|pane split) '
    assert_match "review tab line: the Reviewer starts in its R2" "$log" '^herdr agent start bun-vitest-r2-1 --kind codex --pane pane-22 '
    # The same run before its first review: a reviews tab, never a lanes tab
    # (its lanes sit in the orchestrator's tab).
    sed -i.bak '/^review tab:/d' "$RUNO/panes.txt"
    reset_stub; out=$(cd "$r" && "$KIT/add-reviewer.sh" "$RUNO" R1 claude "Old first" "$RUNO/findings/f.json" 2>&1; echo "exit=$?")
    assert_match "older pane map, first review: a reviews tab" "$(cat "$HERDR_STUB_LOG")" "^herdr tab create --workspace ws-0 --cwd $r --label reviews --no-focus$"
    assert_nomatch "older pane map, first review: no lanes tab line" "$(cat "$RUNO/panes.txt")" '^lanes tab:'
    # A lanes tab without a Reviewer column (reviews off at bootstrap): the
    # review opens a reviews tab of its own, as before the lanes tab.
    r=$(fixture_repo bun-vitest); RUNN="$TMP/run-review-nocolumn"
    (cd "$r" && LANE_REVIEW=off PREFLIGHT=off "$KIT/bootstrap.sh" "$RUNN" "No column" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
    reset_stub; out=$(cd "$r" && "$KIT/add-reviewer.sh" "$RUNN" R1 claude "No column" "$RUNN/findings/n.json" 2>&1; echo "exit=$?"); log=$(cat "$HERDR_STUB_LOG")
    assert_match "no Reviewer column: the review finishes" "$out" 'exit=0$'
    assert_match "no Reviewer column: a reviews tab"     "$log" "^herdr tab create --workspace ws-0 --cwd $r --label reviews --no-focus$"
    assert_match "no Reviewer column: R2 right of R1"    "$log" '^herdr pane split --pane pane-1 --direction right --ratio 0.5 '
    assert_match "no Reviewer column: the review tab line" "$(cat "$RUNN/panes.txt")" '^review tab: +tab-1 +\(R1 pane-1, R2 pane-2\)$'
    assert_match "no Reviewer column: the lanes tab stays without one" "$(cat "$RUNN/panes.txt")" '^lanes tab: +tab-[0-9]+ +\(no Reviewer column\)$'
    RUNF="$TMP/run-review-failed"; reset_stub
    r=$(fixture_repo bun-vitest); (cd "$r" && "$KIT/bootstrap.sh" "$RUNF" "Failed" main >/dev/null 2>&1)
    out=$(cd "$r" && HERDR_STUB_BUSY_STARTS=99 START_TRIES=1 "$KIT/add-reviewer.sh" "$RUNF" R1 claude "Try" "$RUNF/findings/a.json" 2>&1; echo "exit=$?")
    assert_match "a Reviewer that does not start: add-reviewer fails" "$out" 'exit=1$'
    assert_match "... its review is in the map, starting" "$(cat "$RUNF/panes.txt")" '^reviewer R1: .*agent "bun-vitest-r1-1".* starting$'
    echo gone > "$S/bun-vitest-r1-1"   # it never started: herdr does not know it
    : > "$HERDR_STUB_LOG"
    out=$(cd "$r" && "$KIT/add-reviewer.sh" "$RUNF" R1 claude "Try again" "$RUNF/findings/a.json" 2>&1; echo "exit=$?")
    assert_match "after a failed start, the same slot works again" "$out" 'exit=0$'
    assert_match "the retry starts the Reviewer"        "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-r1-1 '
    assert_eq "the reused task takes the new title"     "$(reviews "$RUNF")" "R1-1@R1:Try again"
    assert_match "the retry keeps the review's task id" "$(cat "$RUNF/panes.txt")" '^reviewer R1: .*agent "bun-vitest-r1-1".*review "Try again".*\)$'
    assert_match "the retry says it reuses the task"    "$out" '^reusing task R1-1: '
    (cd "$r" && HERDR_STUB_BUSY_STARTS=99 START_TRIES=1 "$KIT/add-reviewer.sh" "$RUNF" R2 claude "Try" "$RUNF/findings/b.json" >/dev/null 2>&1)
    echo gone > "$S/bun-vitest-r2-1"
    "$KIT/tests/stub/tower" task R2-1 done --model sonnet --run "$RUNF" >/dev/null
    out=$(cd "$r" && "$KIT/add-reviewer.sh" "$RUNF" R2 claude "Try again" "$RUNF/findings/b.json" 2>&1; echo "exit=$?")
    # Its line still says starting, but its task was worked on: that review
    # happened, and the next one starts fresh.
    assert_match "a starting line whose task was worked on: the next review" "$out" 'reviewer R2 ready \(task R2-2\)'
    assert_match "... as a new agent"                   "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-r2-2 '
    # The reviewer line is written before the start (#28): a start that fails
    # after its agent exists leaves the agent in the map, and a rerun ends it and
    # starts the review again under the same name and task.
    RUNB="$TMP/run-review-blocked"; reset_stub
    r=$(fixture_repo bun-vitest); (cd "$r" && "$KIT/bootstrap.sh" "$RUNB" "Blocked" main >/dev/null 2>&1); reset_stub
    echo blocked > "$S/bun-vitest-r1-1"
    out=$(cd "$r" && HERDR_STUB_TRUST_STARTS=1 "$KIT/add-reviewer.sh" "$RUNB" R1 claude "Blocked" "$RUNB/findings/a.json" 2>&1; echo "exit=$?")
    assert_match "blocked after its start: add-reviewer fails" "$out" 'exit=1$'
    assert_match "blocked after its start: its agent is in the pane map" "$(cat "$RUNB/panes.txt")" '^reviewer R1: +pane-4 +\(agent "bun-vitest-r1-1", .*review "Blocked"'
    # Still blocked, its review pending: kept as it is, the rerun stops at
    # once, saying what it read (nothing says that review should end).
    echo blocked > "$S/bun-vitest-r1-1"; : > "$HERDR_STUB_LOG"
    out=$(cd "$r" && EXIT_WAIT_SECONDS=3 "$KIT/add-reviewer.sh" "$RUNB" R1 claude "Blocked again" "$RUNB/findings/a.json" 2>&1; echo "exit=$?"); log=$(cat "$HERDR_STUB_LOG")
    assert_match "rerun, still blocked: stops"          "$out" 'exit=1$'
    assert_match "rerun, still blocked: says what it read, and to look" "$out" "Reviewer bun-vitest-r1-1's review is still pending, and herdr reads its terminal pane-4 as blocked: nothing was typed into it or closed\\. Look at it there"
    assert_nomatch "rerun, still blocked: nothing sent, nothing started" "$log" '^herdr (pane send-text|pane send-keys|agent start)'
    # Reported done instead (a finished Reviewer), it is ended and the review
    # started again under the same name, as before.
    printf 'done\ndone\ngone\n' > "$S/bun-vitest-r1-1"; : > "$HERDR_STUB_LOG"   # read for resuming, for ending, then gone
    out=$(cd "$r" && EXIT_WAIT_SECONDS=3 "$KIT/add-reviewer.sh" "$RUNB" R1 claude "Blocked again" "$RUNB/findings/a.json" 2>&1; echo "exit=$?"); log=$(cat "$HERDR_STUB_LOG")
    assert_match "rerun, done: finishes"                "$out" 'exit=0$'
    assert_match "rerun, done: the agent left in the slot is sent /exit" "$log" '^herdr pane send-text pane-4 /exit$'
    assert_match "rerun, done: the review starts again under the same name" "$log" '^herdr agent start bun-vitest-r1-1 '
    sed -i.bak '/^reviewer R1:/s/)$/) starting/' "$RUNB/panes.txt"; rm -f "$RUNB/panes.txt.bak"
    "$KIT/tests/stub/tower" task R1-1 pending --run "$RUNB" >/dev/null 2>&1 || true
    # Once the operator has ended it there, the rerun starts the review again.
    echo gone > "$S/bun-vitest-r1-1"; : > "$HERDR_STUB_LOG"
    out=$(cd "$r" && EXIT_WAIT_SECONDS=3 "$KIT/add-reviewer.sh" "$RUNB" R1 claude "Blocked again" "$RUNB/findings/a.json" 2>&1; echo "exit=$?"); log=$(cat "$HERDR_STUB_LOG")
    assert_match "rerun: finishes"                      "$out" 'exit=0$'
    assert_match "rerun: the review starts again under the same name" "$log" '^herdr agent start bun-vitest-r1-1 '
    assert_nomatch "rerun: no second agent"              "$log" '^herdr agent start bun-vitest-r1-2 '
    assert_eq "rerun: the same task, new title"         "$(reviews "$RUNB")" "R1-1@R1:Blocked again"
    assert_eq "rerun: one reviewer R1 line"             "$(grep -c '^reviewer R1:' "$RUNB/panes.txt")" 1
    assert_match "rerun: ready"                         "$out" 'reviewer R1 ready \(task R1-1\)'
    # A start that timed out leaves its agent running; once it accepts input, a
    # rerun takes it as it is.
    echo unready > "$S/bun-vitest-r2-1.started"; reset_stub
    out=$(cd "$r" && READY_WAIT_SECONDS=1 "$KIT/add-reviewer.sh" "$RUNB" R2 claude "Slow" "$RUNB/findings/b.json" 2>&1; echo "exit=$?")
    assert_match "never ready: add-reviewer fails"      "$out" 'exit=1$'
    echo idle > "$S/bun-vitest-r2-1"; rm -f "$S/bun-vitest-r2-1.started"; : > "$HERDR_STUB_LOG"
    out=$(cd "$r" && "$KIT/add-reviewer.sh" "$RUNB" R2 claude "Slow" "$RUNB/findings/b.json" 2>&1; echo "exit=$?"); log=$(cat "$HERDR_STUB_LOG")
    assert_match "rerun, agent now ready: finishes"     "$out" 'exit=0$'
    assert_nomatch "rerun, agent now ready: not ended, not started" "$log" '^herdr (pane send-text|agent start)'
    assert_match "rerun, agent now ready: says it resumes it" "$out" 'resuming bun-vitest-r2-1 in pane-5'
    assert_match "rerun, agent now ready: ready"        "$out" 'reviewer R2 ready \(task R2-1\)'
    assert_match "rerun, agent now ready: its line is no longer starting" "$(cat "$RUNB/panes.txt")" '^reviewer R2: .*review "Slow".*\)$'
    # A starting Reviewer that is working and accepts input is kept, as
    # add-lane keeps such a lane.
    echo unready > "$S/bun-vitest-r2-2.started"; echo gone > "$S/bun-vitest-r2-1"; reset_stub
    out=$(cd "$r" && READY_WAIT_SECONDS=1 "$KIT/add-reviewer.sh" "$RUNB" R2 claude "Busy" "$RUNB/findings/w.json" 2>&1; echo "exit=$?")
    rm -f "$S/bun-vitest-r2-2.started"; echo working > "$S/bun-vitest-r2-2"; : > "$HERDR_STUB_LOG"
    out=$(cd "$r" && "$KIT/add-reviewer.sh" "$RUNB" R2 claude "Busy" "$RUNB/findings/w.json" 2>&1; echo "exit=$?")
    assert_match "starting, working and ready: resumed" "$out" 'resuming bun-vitest-r2-2 in pane-5'
    assert_nomatch "starting, working and ready: not refused as working" "$out" 'still working'
    rm -f "$S"/bun-vitest-r2-2*
    assert_nomatch "rerun, agent now ready: not said to have not started" "$out" 'did not start'
    # A starting Reviewer that is working but not ready for input yet is waited
    # for, as its start waits, and then kept.
    echo gone > "$S/bun-vitest-r2-2"; echo unready > "$S/bun-vitest-r2-3.started"; reset_stub
    out=$(cd "$r" && READY_WAIT_SECONDS=1 "$KIT/add-reviewer.sh" "$RUNB" R2 claude "Loading" "$RUNB/findings/l.json" 2>&1; echo "exit=$?")
    rm -f "$S/bun-vitest-r2-3.started"; printf 'busy-unready\nbusy-unready\nworking\n' > "$S/bun-vitest-r2-3"; : > "$HERDR_STUB_LOG"
    out=$(cd "$r" && READY_WAIT_SECONDS=5 "$KIT/add-reviewer.sh" "$RUNB" R2 claude "Loading" "$RUNB/findings/l.json" 2>&1; echo "exit=$?"); log=$(cat "$HERDR_STUB_LOG")
    assert_match "starting, working, not ready: finishes" "$out" 'exit=0$'
    assert_match "starting, working, not ready: resumed once ready" "$out" 'resuming bun-vitest-r2-3 in pane-5'
    assert_nomatch "starting, working, not ready: not refused as working" "$out" 'still working'
    assert_nomatch "starting, working, not ready: not ended, not started" "$log" '^herdr (pane send-text|agent start)'
    # One that stays so: the rerun says it is still starting, and a rerun
    # resumes it once it accepts input.
    echo gone > "$S/bun-vitest-r2-3"; echo unready > "$S/bun-vitest-r2-4.started"; reset_stub
    out=$(cd "$r" && READY_WAIT_SECONDS=1 "$KIT/add-reviewer.sh" "$RUNB" R2 claude "Stuck" "$RUNB/findings/s.json" 2>&1; echo "exit=$?")
    rm -f "$S/bun-vitest-r2-4.started"; echo busy-unready > "$S/bun-vitest-r2-4"; : > "$HERDR_STUB_LOG"
    out=$(cd "$r" && READY_WAIT_SECONDS=2 "$KIT/add-reviewer.sh" "$RUNB" R2 claude "Stuck" "$RUNB/findings/s.json" 2>&1; echo "exit=$?"); log=$(cat "$HERDR_STUB_LOG")
    assert_match "starting, never ready on the rerun: fails" "$out" 'exit=1$'
    assert_match "starting, never ready on the rerun: says it is still starting" "$out" 'Reviewer bun-vitest-r2-4 is still starting in pane-5: .*rerun  .*add-reviewer\.sh .* R2 claude Stuck .*/findings/s\.json  to resume it once it accepts input'
    assert_nomatch "starting, never ready on the rerun: not refused as working" "$out" 'still working'
    assert_nomatch "starting, never ready on the rerun: no start's next step" "$out" 'agent start:'
    assert_nomatch "starting, never ready on the rerun: not ended, not started" "$log" '^herdr (pane send-text|agent start)'
    assert_match "starting, never ready on the rerun: its line still starting" "$(cat "$RUNB/panes.txt")" '^reviewer R2: .*review "Stuck".* starting$'
    rm -f "$S"/bun-vitest-r2-3* "$S"/bun-vitest-r2-4*
    # A kept agent must be of the kind and model this call picks: another one
    # is ended and started again.
    echo gone > "$S/bun-vitest-r1-1"; echo unready > "$S/bun-vitest-r1-2.started"; reset_stub
    out=$(cd "$r" && READY_WAIT_SECONDS=1 "$KIT/add-reviewer.sh" "$RUNB" R1 claude "Kind" "$RUNB/findings/k.json" 2>&1; echo "exit=$?")
    assert_match "never ready (codex): add-reviewer fails" "$out" 'exit=1$'
    assert_match "never ready: it says to rerun add-reviewer" "$out" 'rerun  .*add-reviewer\.sh .* R1 claude Kind .*/findings/k\.json  to resume it'
    printf 'idle\ngone\n' > "$S/bun-vitest-r1-2"; rm -f "$S/bun-vitest-r1-2.started"; : > "$HERDR_STUB_LOG"
    out=$(cd "$r" && REVIEWER_KIND=claude "$KIT/add-reviewer.sh" "$RUNB" R1 claude "Kind" "$RUNB/findings/k.json" 2>&1; echo "exit=$?"); log=$(cat "$HERDR_STUB_LOG")
    assert_match "rerun as another kind: the kept agent is ended" "$log" '^herdr pane send-text pane-4 /exit$'
    assert_match "rerun as another kind: started again as that kind" "$log" '^herdr agent start bun-vitest-r1-2 --kind claude '
    assert_match "rerun as another kind: ready"         "$out" 'reviewer R1 ready \(task R1-2\)'
    rm -f "$S"/bun-vitest-r1-1* "$S"/bun-vitest-r1-2* "$S"/bun-vitest-r2-1*
    # A codex-only machine: a codex lane's Reviewer is a fresh codex agent on the
    # reviewed lane's model, as the pane map records it.
    RUNM="$TMP/run-review-model"; reset_stub
    r=$(fixture_repo bun-vitest); (cd "$r" && CLAUDE_STUB=absent EXECUTOR_KIND=codex EXECUTOR_MODEL=gpt-6-astra-a "$KIT/bootstrap.sh" "$RUNM" "Model" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
    (cd "$r" && CLAUDE_STUB=absent EXECUTOR_KIND=codex EXECUTOR_MODEL=gpt-6-astra-b "$KIT/add-lane.sh" "$RUNM" B feat/mb main 2 >/dev/null 2>&1)
    reset_stub; out=$(cd "$r" && CLAUDE_STUB=absent "$KIT/add-reviewer.sh" "$RUNM" R1 codex "Lane B" "$RUNM/findings/b.json" B 2>&1)
    assert_match "codex only: the Reviewer of lane B runs on lane B's model" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-r1-1 --kind codex --pane [^ ]+ -- -m gpt-6-astra-b '
    assert_match "codex only: the pane map's reviewer line has that model" "$(cat "$RUNM/panes.txt")" '^reviewer R1: .*kind codex, model gpt-6-astra-b,'
    reset_stub; out=$(cd "$r" && CLAUDE_STUB=absent "$KIT/add-reviewer.sh" "$RUNM" R2 codex "Preflight" "$RUNM/findings/p.json" 2>&1)
    assert_match "codex only, no lane named: the first codex lane's model (lane A)" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-r2-1 --kind codex --pane [^ ]+ -- -m gpt-6-astra-a '
    assert_match "a lane of another kind than lane-kind is refused" "$(cd "$r" && "$KIT/add-reviewer.sh" "$RUNM" R1 claude "X" "$RUNM/findings/x.json" B 2>&1)" "lane B is codex, not claude"
    assert_match "a lane letter outside A-D is refused" "$(cd "$r" && "$KIT/add-reviewer.sh" "$RUNM" R1 codex "X" "$RUNM/findings/x.json" E 2>&1)" "lane must be A, B, C or D \(got 'E'\)"
    RUNM2="$TMP/run-review-model2"; reset_stub
    r=$(fixture_repo bun-vitest); (cd "$r" && EXECUTOR_KIND=claude "$KIT/bootstrap.sh" "$RUNM2" "Model2" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
    (cd "$r" && CLAUDE_STUB=absent EXECUTOR_KIND=codex EXECUTOR_MODEL=gpt-6-astra-b "$KIT/add-lane.sh" "$RUNM2" B feat/mb2 main 2 >/dev/null 2>&1)
    reset_stub; out=$(cd "$r" && CLAUDE_STUB=absent "$KIT/add-reviewer.sh" "$RUNM2" R1 codex "Codex lanes" "$RUNM2/findings/c.json" 2>&1)
    assert_match "no lane named, lane A is claude: the first codex lane (B) stands in" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-r1-1 --kind codex --pane [^ ]+ -- -m gpt-6-astra-b '
    assert_match "a lane not in the pane map is refused" "$(cd "$r" && "$KIT/add-reviewer.sh" "$RUNM" R1 codex "X" "$RUNM/findings/x.json" D 2>&1)" "no lane D in $RUNM/panes.txt"
    # codex can swallow the first Enter after /exit (its slash-command popup takes
    # it): while the Reviewer is still there, Enter is pressed again.
    RUNE="$TMP/run-review-exit"; reset_stub
    r=$(fixture_repo bun-vitest); (cd "$r" && "$KIT/bootstrap.sh" "$RUNE" "Exit" main >/dev/null 2>&1)
    (cd "$r" && "$KIT/add-reviewer.sh" "$RUNE" R1 claude "First" "$RUNE/findings/a.json" >/dev/null 2>&1)
    echo idle > "$S/bun-vitest-r1-1"; : > "$HERDR_STUB_LOG"
    out=$(cd "$r" && HERDR_STUB_EXIT_ON_ENTER=2 EXIT_WAIT_SECONDS=15 "$KIT/add-reviewer.sh" "$RUNE" R1 claude "Second" "$RUNE/findings/b.json" 2>&1; echo "exit=$?")
    rm -f "$S/bun-vitest-r1-1"
    assert_match "a Reviewer that needs a second Enter still ends" "$out" 'exit=0$'
    assert_eq "it gets the second Enter"                "$(grep -cE '^herdr pane send-keys [^ ]+ Enter$' "$HERDR_STUB_LOG")" 2
    assert_match "then the new Reviewer starts"         "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-r1-2 '
    RUN4="$TMP/run-review-busy"; reset_stub
    r=$(fixture_repo bun-vitest); (cd "$r" && "$KIT/bootstrap.sh" "$RUN4" "Busy" main >/dev/null 2>&1); reset_stub
    out=$(cd "$r" && HERDR_STUB_BUSY_STARTS=1 "$KIT/add-reviewer.sh" "$RUN4" R1 claude "Busy" "$RUN4/findings/a.json" 2>&1; echo "exit=$?")
    assert_match "busy pane: add-reviewer finishes"     "$out" 'exit=0$'
    assert_nomatch "busy pane: add-reviewer shows no busy error" "$out" 'agent_pane_busy'
    assert_eq "busy pane: the Reviewer's start is tried again" "$(grep -c '^herdr agent start bun-vitest-r1-1 ' "$HERDR_STUB_LOG")" 2
    # A trust prompt that cannot be answered fails the call, saying so.
    RUN5="$TMP/run-review-trust"
    r=$(fixture_repo bun-vitest); (cd "$r" && "$KIT/bootstrap.sh" "$RUN5" "Trust" main >/dev/null 2>&1); reset_stub
    out=$(cd "$r" && HERDR_STUB_TRUST_STARTS=1 HERDR_STUB_SEND_KEYS_FAIL=1 "$KIT/add-reviewer.sh" "$RUN5" R1 claude "Trust" "$RUN5/findings/a.json" 2>&1; echo "exit=$?")
    assert_match "trust, send-keys failing: add-reviewer fails" "$out" 'exit=1$'
    assert_match "trust, send-keys failing: says so"     "$out" "could not answer bun-vitest-r1-1's trust prompt"
    assert_nomatch "trust, send-keys failing: no ready line" "$out" 'reviewer R1 ready'
    # A Reviewer that never accepts input is not reported ready.
    RUN6="$TMP/run-review-unready"
    r=$(fixture_repo bun-vitest); (cd "$r" && "$KIT/bootstrap.sh" "$RUN6" "Unready" main >/dev/null 2>&1); reset_stub
    echo unready > "$S/bun-vitest-r1-1.started"
    out=$(cd "$r" && READY_WAIT_SECONDS=2 "$KIT/add-reviewer.sh" "$RUN6" R1 claude "Unready" "$RUN6/findings/a.json" 2>&1; echo "exit=$?")
    rm -f "$S"/bun-vitest-r1-1*
    assert_match "not accepting input: add-reviewer fails" "$out" 'exit=1$'
    assert_match "not accepting input: says so"          "$out" 'bun-vitest-r1-1 does not accept input in pane pane-[0-9]+ after 2 checks'
    assert_nomatch "not accepting input: no ready line"  "$out" 'reviewer R1 ready'
  fi
fi

# --- model-defaults ----------------------------------------------------------
# Every default model comes from the kit's model-defaults file; MODEL_DEFAULTS_FILE
# points the kit at a test copy with changed values.
if section model-defaults; then
  MD="$TMP/model-defaults"
  sed -e "s/^EXECUTOR_MODEL_CLAUDE=.*/EXECUTOR_MODEL_CLAUDE=claude-md-exec/" "$KIT/model-defaults" > "$MD"
  boot() { (cd "$1" && shift && "$KIT/bootstrap.sh" "$@" 2>&1); }
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-md-claude"; reset_stub
  out=$(MODEL_DEFAULTS_FILE="$MD" boot "$r" "$RUN" "Defaults" main)
  assert_match "model-defaults: a claude lane starts on EXECUTOR_MODEL_CLAUDE" "$(cat "$HERDR_STUB_LOG")" \
    '^herdr agent start bun-vitest-lane-a --kind claude --pane pane-3 -- --model claude-md-exec$'
  sed -i.bak -e "s/^EXECUTOR_MODEL_CODEX=.*/EXECUTOR_MODEL_CODEX=codex-md-exec/" \
    -e "s/^REVIEWER_MODEL_CODEX=.*/REVIEWER_MODEL_CODEX=codex-md-rev/" \
    -e "s/^REVIEWER_MODEL_CLAUDE=.*/REVIEWER_MODEL_CLAUDE=claude-md-rev/" \
    -e "s/^REVIEWER_MODEL_CLAUDE_SELF=.*/REVIEWER_MODEL_CLAUDE_SELF=claude-md-self/" "$MD"
  mkdir -p "$TMP/md-home/.codex/skills/tdd"
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-md-codex"; reset_stub
  out=$(HOME="$TMP/md-home" EXECUTOR_KIND=codex MODEL_DEFAULTS_FILE="$MD" boot "$r" "$RUN" "Defaults" main)
  assert_match "model-defaults: a codex lane starts on EXECUTOR_MODEL_CODEX" "$(cat "$HERDR_STUB_LOG")" \
    '^herdr agent start bun-vitest-lane-a --kind codex --pane pane-3 -- -m codex-md-exec '
  rev() { HOME="$TMP/md-home" MODEL_DEFAULTS_FILE="$MD" in_kit ". \"\$KIT/executor.sh\"; reviewer_for $1"; }
  T=$(printf '\t')
  assert_eq "model-defaults: codex reviews claude on REVIEWER_MODEL_CODEX" "$(rev claude)" "codex${T}codex-md-rev${T}"
  assert_eq "model-defaults: claude reviews codex on REVIEWER_MODEL_CLAUDE" "$(EXECUTOR_KIND=codex rev codex)" "claude${T}claude-md-rev${T}"
  assert_eq "model-defaults: claude reviews claude on REVIEWER_MODEL_CLAUDE_SELF" "$(CODEX_STUB=absent rev claude)" \
    "claude${T}claude-md-self${T}fallback: codex is not installed, so claude reviews claude"
  assert_eq "model-defaults: a codex Reviewer of a codex lane with no model known is on EXECUTOR_MODEL_CODEX" \
    "$(CLAUDE_STUB=absent rev codex)" "codex${T}codex-md-exec${T}fallback: claude is not installed, so a fresh codex agent reviews codex"
  sed -i.bak -e "s/^SPEC_REVIEWER_MODEL_CLAUDE=.*/SPEC_REVIEWER_MODEL_CLAUDE=claude-md-spec/" \
    -e "s/^QUALITY_REVIEWER_MODEL_CLAUDE=.*/QUALITY_REVIEWER_MODEL_CLAUDE=claude-md-quality/" \
    -e "s/^SPEC_REVIEWER_MODEL_CODEX=.*/SPEC_REVIEWER_MODEL_CODEX=codex-md-spec/" \
    -e "s/^QUALITY_REVIEWER_MODEL_CODEX=.*/QUALITY_REVIEWER_MODEL_CODEX=codex-md-quality/" "$MD"
  roles='" ".join(k+"="+v for k,v in sorted(d["run"]["models"].items()))'
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-md-roles-claude"
  out=$(MODEL_DEFAULTS_FILE="$MD" boot "$r" "$RUN" "Defaults" main)
  assert_eq "model-defaults: a claude run records its kind's spec and quality reviewer models" "$(board "$RUN" "$roles")" \
    "implementer=claude-md-exec quality-reviewer=claude-md-quality spec-reviewer=claude-md-spec"
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-md-roles-codex"
  out=$(HOME="$TMP/md-home" EXECUTOR_KIND=codex MODEL_DEFAULTS_FILE="$MD" boot "$r" "$RUN" "Defaults" main)
  assert_eq "model-defaults: a codex run records its kind's spec and quality reviewer models" "$(board "$RUN" "$roles")" \
    "implementer=codex-md-exec quality-reviewer=codex-md-quality spec-reviewer=codex-md-spec"
  # The unsuffixed names, from the environment or the repo contract, win over the file.
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-md-env"; reset_stub
  out=$(EXECUTOR_MODEL=lane-m SPEC_REVIEWER_MODEL=spec-m QUALITY_REVIEWER_MODEL=quality-m REVIEWER_MODEL=rev-m \
    MODEL_DEFAULTS_FILE="$MD" boot "$r" "$RUN" "Env" main)
  assert_match "model-defaults: EXECUTOR_MODEL in the environment wins" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start .* -- --model lane-m$'
  assert_eq "model-defaults: the environment's reviewer models win" "$(board "$RUN" "$roles")" \
    "implementer=lane-m quality-reviewer=quality-m spec-reviewer=spec-m"
  assert_match "model-defaults: REVIEWER_MODEL in the environment wins" "$(cat "$RUN/panes.txt")" '^reviewer: +kind codex, model rev-m$'
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-md-contract"; reset_stub
  printf '%s\n' EXECUTOR_MODEL=lane-c SPEC_REVIEWER_MODEL=spec-c QUALITY_REVIEWER_MODEL=quality-c REVIEWER_MODEL=rev-c > "$r/.orchestrate"
  out=$(MODEL_DEFAULTS_FILE="$MD" boot "$r" "$RUN" "Contract" main)
  assert_match "model-defaults: EXECUTOR_MODEL in the repo contract wins" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start .* -- --model lane-c$'
  assert_eq "model-defaults: the repo contract's reviewer models win" "$(board "$RUN" "$roles")" \
    "implementer=lane-c quality-reviewer=quality-c spec-reviewer=spec-c"
  assert_match "model-defaults: REVIEWER_MODEL in the repo contract wins" "$(cat "$RUN/panes.txt")" '^reviewer: +kind codex, model rev-c$'
  assert_eq "model-defaults: a per-kind key in the environment wins over the file" \
    "$(REVIEWER_MODEL_CODEX=rev-env rev claude)" "codex${T}rev-env${T}"
  # A key the file lacks is refused, never an agent on an empty model.
  grep -v '^EXECUTOR_MODEL_CLAUDE=' "$KIT/model-defaults" > "$TMP/md-nokey"
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-md-nokey"; reset_stub
  out=$(MODEL_DEFAULTS_FILE="$TMP/md-nokey" boot "$r" "$RUN" "No key" main; echo "exit=$?")
  assert_match "model-defaults: a missing key fails bootstrap" "$out" 'exit=[1-9][0-9]*$'
  assert_match "model-defaults: ... naming the key and the file" "$out" "no EXECUTOR_MODEL_CLAUDE in $TMP/md-nokey"
  assert_nomatch "model-defaults: ... and starts no agent" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start '
  grep -v '^REVIEWER_MODEL_CODEX=' "$KIT/model-defaults" > "$TMP/md-norev"
  out=$(HOME="$TMP/md-home" MODEL_DEFAULTS_FILE="$TMP/md-norev" in_kit ". \"\$KIT/executor.sh\"; reviewer_for claude; echo \"exit=\$?\"")
  assert_match "model-defaults: a missing Reviewer key is refused" "$out" "no REVIEWER_MODEL_CODEX in $TMP/md-norev"
  assert_nomatch "model-defaults: ... with no Reviewer line" "$out" "^codex$T"
  out=$(HOME="$TMP/md-home" MODEL_DEFAULTS_FILE="$TMP/nope" in_kit ". \"\$KIT/executor.sh\"; echo \"exit=\$?\"")
  assert_match "model-defaults: a missing file is refused" "$out" "no EXECUTOR_MODEL_CLAUDE in $TMP/nope"
  out=$(MODEL_DEFAULTS_FILE="$TMP/nope" boot "$(fixture_repo bun-vitest)" "$TMP/run-md-nofile" "No file" main; echo "exit=$?")
  assert_match "model-defaults: a missing file fails bootstrap, naming it" "$out" "no [A-Z_]+ in $TMP/nope"
  # No model id is left in the kit's logic; cursor's defaults are Grok -fast only.
  assert_nomatch "model-defaults: no model id in executor.sh or bootstrap.sh" \
    "$(cat "$KIT/executor.sh" "$KIT/bootstrap.sh")" '(claude-(opus|sonnet|fable|haiku)|gpt-[0-9]|grok-|\b(sonnet|opus|haiku)\b)'
  cursor_keys=$(grep -E '^[A-Z_]+_CURSOR=' "$KIT/model-defaults")
  assert_match "model-defaults: the file has cursor's executor and reviewer keys" "$(printf '%s\n' "$cursor_keys" | sed 's/=.*//' | sort | tr '\n' ' ')" \
    '^EXECUTOR_MODEL_CURSOR QUALITY_REVIEWER_MODEL_CURSOR REVIEWER_MODEL_CURSOR SPEC_REVIEWER_MODEL_CURSOR $'
  assert_eq "model-defaults: every cursor model is a Grok -fast model" \
    "$(printf '%s\n' "$cursor_keys" | grep -cvE "^[A-Z_]+=['\"]?grok-[a-z0-9.-]+-fast['\"]?\$")" 0
fi

# --- user-contract -----------------------------------------------------------
# One person's run defaults, ${XDG_CONFIG_HOME}/tower/orchestrate: under the
# repo contract and the call's environment, over the kit's model-defaults.
if section user-contract; then
  UC="$TMP/uc-config"; mkdir -p "$UC/tower" "$TMP/uc-home/.codex/skills/tdd"
  uc() { printf '%s\n' "$@" > "$UC/tower/orchestrate"; }
  boot() { (cd "$1" && shift && env HOME="$TMP/uc-home" XDG_CONFIG_HOME="$UC" "$KIT/bootstrap.sh" "$@" 2>&1); }
  lane_a() { sed -nE 's/^lane A: .*, kind ([a-z]+), .*, model (.*), tab lanes\)$/\1 \2/p' "$1/panes.txt"; }
  uc EXECUTOR_MODEL_CODEX=codex-user
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-uc-model"; reset_stub
  out=$(EXECUTOR_KIND=codex boot "$r" "$RUN" "User" main)
  assert_eq "user contract: its EXECUTOR_MODEL_CODEX is a codex lane's model" "$(lane_a "$RUN")" "codex codex-user"
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-uc-repo"; echo EXECUTOR_MODEL_CODEX=codex-repo > "$r/.orchestrate"
  out=$(EXECUTOR_KIND=codex boot "$r" "$RUN" "User" main)
  assert_eq "user contract: the repo contract wins over it" "$(lane_a "$RUN")" "codex codex-repo"
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-uc-env"; echo EXECUTOR_MODEL_CODEX=codex-repo > "$r/.orchestrate"
  out=$(EXECUTOR_KIND=codex EXECUTOR_MODEL_CODEX=codex-env boot "$r" "$RUN" "User" main)
  assert_eq "user contract: bootstrap's environment wins over both" "$(lane_a "$RUN")" "codex codex-env"
  # add-lane reads the user contract too; the run's repo contract and the
  # call's environment win over it.
  lane() { (cd "$1" && shift && env HOME="$TMP/uc-home" XDG_CONFIG_HOME="$UC" "$@" 2>&1); }
  lane_of() { sed -nE "s/^lane $2: .*, kind ([a-z]+), .*, model (.*), tab lanes\\)\$/\\1 \\2/p" "$1/panes.txt"; }
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-uc-lanes"
  out=$(boot "$r" "$RUN" "Lanes" main "$KIT/example-tasks.tsv")
  out=$(lane "$r" EXECUTOR_KIND=codex "$KIT/add-lane.sh" "$RUN" B feat/b main 2)
  out=$(lane "$r" EXECUTOR_KIND=codex EXECUTOR_MODEL_CODEX=codex-env "$KIT/add-lane.sh" "$RUN" C feat/c main 3)
  assert_eq "user contract: an add-lane call reads it" "$(lane_of "$RUN" B)" "codex codex-user"
  assert_eq "user contract: an add-lane call's environment wins over it" "$(lane_of "$RUN" C)" "codex codex-env"
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-uc-lanes-repo"; echo EXECUTOR_MODEL_CODEX=codex-repo > "$r/.orchestrate"
  out=$(boot "$r" "$RUN" "Lanes" main "$KIT/example-tasks.tsv")
  out=$(lane "$r" EXECUTOR_KIND=codex "$KIT/add-lane.sh" "$RUN" B feat/b main 2)
  assert_eq "user contract: an add-lane call's repo contract wins over it" "$(lane_of "$RUN" B)" "codex codex-repo"
  rm -f "$UC/tower/orchestrate"
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-uc-none"
  out=$(EXECUTOR_KIND=codex boot "$r" "$RUN" "User" main)
  assert_eq "user contract: without one, the defaults file's value" "$(lane_a "$RUN")" "codex gpt-6-astra"
  assert_nomatch "user contract: a missing file is silent" "$out" 'tower/orchestrate'
  uc EXECUTOR_KIND=codex LANE_REVIEW=on
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-uc-kind"
  out=$(boot "$r" "$RUN" "User" main)
  assert_eq "user contract: its EXECUTOR_KIND makes the lanes codex" "$(lane_a "$RUN")" "codex gpt-6-astra"
  assert_match "user contract: its run switch is in the switches: line" "$(cat "$RUN/panes.txt")" '^switches: .* LANE_REVIEW=on '
  uc TRIAGE=auto GUIDED_REVIEW=on "NOTIFY='~/bin/notify --run'"
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-uc-triage"
  out=$(boot "$r" "$RUN" "User" main)
  assert_match "user contract: its TRIAGE, GUIDED_REVIEW and NOTIFY are in the switches: line, NOTIFY quoted" "$(cat "$RUN/panes.txt")" "^switches: .* TRIAGE=auto GUIDED_REVIEW=on NOTIFY='~/bin/notify --run'\$"
  assert_match "user contract: ... and in the record's note" "$(notes "$RUN")" "^switches: .* TRIAGE=auto GUIDED_REVIEW=on NOTIFY='~/bin/notify --run'\$"
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-uc-triage-repo"; printf '%s\n' TRIAGE=ask 'NOTIFY=~/bin/repo-notify' > "$r/.orchestrate"
  out=$(boot "$r" "$RUN" "User" main)
  assert_match "user contract: the repo contract's TRIAGE wins, its NOTIFY does not" "$(cat "$RUN/panes.txt")" "^switches: .* TRIAGE=ask GUIDED_REVIEW=on NOTIFY='~/bin/notify --run'\$"
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-uc-triage-env"; printf '%s\n' TRIAGE=ask > "$r/.orchestrate"
  out=$(TRIAGE=auto NOTIFY=/opt/bin/env-notify boot "$r" "$RUN" "User" main)
  assert_match "user contract: bootstrap's TRIAGE and NOTIFY win over both" "$(cat "$RUN/panes.txt")" "^switches: .* TRIAGE=auto GUIDED_REVIEW=on NOTIFY=/opt/bin/env-notify\$"
  uc REVIEWER_MODEL_CODEX=rev-user
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-uc-rev"
  out=$(boot "$r" "$RUN" "User" main)
  assert_match "user contract: its REVIEWER_MODEL_CODEX is a codex Reviewer's model" "$(cat "$RUN/panes.txt")" '^reviewer: +kind codex, model rev-user$'
  # Repo-only keys and unknown keys are named, and ignored.
  # As the kit's scripts run: set -euo pipefail.
  detect_in() { (cd "$1" && env XDG_CONFIG_HOME="$UC" bash -c "set -euo pipefail; . \"\$KIT/common.sh\"; . \"\$KIT/detect-stack.sh\"; $2" 2>&1); }
  r=$(fixture_repo bun-vitest)
  for key in CHECK_CMD INSTALL_CMD PM TYPECHECK_TASK; do
    uc "$key=from-user"
    out=$(detect_in "$r" "echo \"[\$$key]\"")
    assert_match "user contract: repo-only $key is named, with the file" "$out" "^$UC/tower/orchestrate: '$key' is a repo contract setting"
    assert_nomatch "user contract: ... and ignored" "$out" '^\[from-user\]$'
  done
  uc 'pane checks "make watch"' 'suite lint "make lint"'
  out=$(detect_in "$r" 'echo "${#PANE_NAMES[@]}|${#SUITE_NAMES[@]}"')
  assert_match "user contract: repo-only pane is named" "$out" "^$UC/tower/orchestrate: 'pane' is a repo contract setting"
  assert_match "user contract: repo-only suite is named" "$out" "^$UC/tower/orchestrate: 'suite' is a repo contract setting"
  assert_match "user contract: ... and both ignored" "$out" '^0\|0$'
  uc EXECUTOR_MODEL=lane-m
  out=$(detect_in "$r" 'echo "[${EXECUTOR_MODEL:-}]"')
  assert_match "user contract: an unsuffixed model is ignored, pointing to the per-kind key" "$out" \
    "^$UC/tower/orchestrate: 'EXECUTOR_MODEL' is a repo contract setting; ignored here \\(set EXECUTOR_MODEL_<KIND>"
  assert_match "user contract: ... and not read" "$out" '^\[\]$'
  uc MODLE=x
  assert_match "user contract: an unknown key is named" "$(detect_in "$r" true)" "^$UC/tower/orchestrate: 'MODLE' is not a setting the kit reads"
  uc USER_CONTRACT_VARS=CHECK_CMD CHECK_CMD=from-user STALE=9
  out=$(detect_in "$r" 'echo "[$CHECK_CMD] [${STALE-}]"')
  assert_match "user contract: it cannot widen its own allowed keys" "$out" "^$UC/tower/orchestrate: 'CHECK_CMD' is a repo contract setting"
  assert_match "user contract: ... narrowing them only withholds its own, never sets one empty" "$out" '^\[bun run typecheck && bun run test\] \[\]$'
  uc PATH=/nowhere STALE=9
  assert_eq "user contract: a PATH it sets does not break its reader" "$(detect_in "$r" 'echo "[$STALE]"')" "[9]"
  # These read the contract in a scrubbed environment (env -i): a regression
  # that echoes values can then show only this fake token, never the caller's.
  detect_clean() { (cd "$1" && env -i PATH="$PATH" HOME="$TMP/uc-home" KIT="$KIT" DRY_RUN=1 ORCA_STUB_COUNTER="$TMP/orca-counter" XDG_CONFIG_HOME="$UC" \
    XDG_STATE_HOME="$XDG_STATE_HOME" SECRET_TOKEN_UC=sk_live_rex bash -c "set -euo pipefail; . \"\$KIT/common.sh\"; . \"\$KIT/detect-stack.sh\"; $2" 2>&1); }
  # The reader's own names are out of its reach too: none of them lets a key in.
  uc '_allowed=" CHECK_CMD "' 'CHECK_CMD="echo from-user-contract"'
  out=$(detect_clean "$r" 'echo "[$CHECK_CMD]"')
  assert_match "user contract: a reassigned _allowed does not let CHECK_CMD in" "$out" '^\[bun run typecheck && bun run test\]$'
  assert_match "user contract: ... CHECK_CMD is named and ignored" "$out" "^$UC/tower/orchestrate: 'CHECK_CMD' is a repo contract setting; ignored here$"
  uc '_known=" MODLE "' MODLE=x
  assert_match "user contract: a reassigned _known does not hide an unknown key" "$(detect_clean "$r" true)" "^$UC/tower/orchestrate: 'MODLE' is not a setting the kit reads"
  uc _file=/elsewhere CHECK_CMD=x
  assert_match "user contract: a reassigned _file does not change the file it names" "$(detect_clean "$r" true)" "^$UC/tower/orchestrate: 'CHECK_CMD' is a repo contract setting"
  # The reader's own surface: shadowed builtins and a stray write garble only
  # its report, which is refused, never echoed; no value reaches stderr.
  uc 'printf() { builtin printf "CHECK_CMD=pwned\0"; }' STALE=9
  out=$(detect_clean "$r" 'echo "[$CHECK_CMD] [$STALE]"'; echo "exit=$?")
  assert_match "user contract: a shadowed printf neither breaks its reader nor lets anything in" "$out" '^\[bun run typecheck && bun run test\] \[9\]$'
  assert_nomatch "user contract: ... no trace of its value" "$out" 'pwned'
  uc 'compgen() { echo CHECK_CMD; }' STALE=9
  out=$(detect_clean "$r" 'echo "[$CHECK_CMD] [$STALE]"')
  assert_match "user contract: a shadowed compgen garbles nothing in" "$out" '^\[bun run typecheck && bun run test\] \[9\]$'
  uc 'printf "X\0" >&3' STALE=9
  out=$(detect_clean "$r" true; echo "exit=$?")
  assert_match "user contract: a write to fd 3 is refused" "$out" 'exit=1$'
  assert_nomatch "user contract: ... and no value reaches stderr" "$out" 'sk_live_rex'
  uc 'printf "X\0" >&10' STALE=9
  out=$(detect_clean "$r" true; echo "exit=$?")
  assert_match "user contract: a stray write to the reader's saved stdout is refused" "$out" "^$UC/tower/orchestrate: its reader's report was garbled"
  assert_nomatch "user contract: ... and no value reaches stderr" "$out" 'sk_live_rex'
  uc 'printf abc >&10' STALE=9
  out=$(detect_clean "$r" true; echo "exit=$?")
  assert_match "user contract: ... even with no NUL in it" "$out" "^$UC/tower/orchestrate: its reader's report was garbled"
  uc 'set -x' STALE=9
  out=$(detect_clean "$r" 'echo "[$STALE]"')
  assert_nomatch "user contract: set -x in it traces no value of the reader's" "$out" 'sk_live_rex'
  assert_match "user contract: ... and it still loads" "$out" '^\[9\]$'
  uc '[[ abc =~ b ]]' 'read -r REPLY <<< x' 'getopts a: o -a 1 || true' 'cd /' STALE=9
  assert_nomatch "user contract: names bash sets itself are not warned about" "$(detect_clean "$r" true)" 'BASH_REMATCH|REPLY|OPTARG|OLDPWD|OPTIND'
  # A caller that traces (bash -x, while debugging the kit) sees no value
  # but the user contract's own.
  uc STALE=9
  out=$( (cd "$r" && env -i PATH="$PATH" HOME="$TMP/uc-home" KIT="$KIT" DRY_RUN=1 ORCA_STUB_COUNTER="$TMP/orca-counter" XDG_CONFIG_HOME="$UC" XDG_STATE_HOME="$XDG_STATE_HOME" \
    SECRET_TOKEN_UC=sk_live_rex bash -c 'set -x; . "$KIT/common.sh"; . "$KIT/detect-stack.sh"; echo "[$STALE]"' 2>&1) )
  assert_nomatch "user contract: a traced caller sees no environment value" "$out" 'sk_live_rex'
  assert_match "user contract: ... and the contract loads" "$out" '^\[9\]$'
  # Functions and traps it defines over the reader's builtins are cleared first.
  uc 'exec 7>&2' 'builtin() { echo "seen: $*" >&7; command builtin "$@"; }' 'trap '"'"'echo "trap: ${!_v-}" >&7'"'"' DEBUG' STALE=9
  out=$(detect_clean "$r" 'echo "[$STALE]"')
  assert_nomatch "user contract: its builtin() function or DEBUG trap sees no value" "$out" 'sk_live_rex'
  assert_match "user contract: ... and it loads" "$out" '^\[9\]$'
  # Nothing a file's function can shadow runs after it is cleared: a function
  # named unset or [ is never called by the reader.
  for f in unset '['; do
    uc 'exec 7>&2' "$f() { echo 'reader called the file' >&7; command $f \"\$@\"; }" STALE=9
    out=$(detect_clean "$r" 'echo "[$STALE]"')
    assert_nomatch "user contract: its function named $f is never called by the reader" "$out" 'reader called the file'
    assert_match "user contract: ... and it loads" "$out" '^\[9\]$'
  done
  uc 'enable -n compgen' STALE=9
  out=$(detect_clean "$r" true; echo "exit=$?")
  assert_match "user contract: a disabled compgen refuses the load, never drops it silently" "$out" 'exit=1$'
  uc 'enable -n compgen' 'set +e' STALE=9
  out=$(detect_clean "$r" true; echo "exit=$?")
  assert_match "user contract: ... even after a set +e in it" "$out" 'exit=1$'
  uc 'pane checks "x"' STALE=9
  out=$(detect_clean "$r" 'echo "[$STALE]"')
  assert_match "user contract: a pane line is still named" "$out" "^$UC/tower/orchestrate: 'pane' is a repo contract setting; ignored here$"
  assert_match "user contract: ... and the rest read" "$out" '^\[9\]$'
  uc 'IFS=x' STALE=9
  assert_eq "user contract: an IFS it sets does not break its reader" "$(detect_clean "$r" 'echo "$STALE"' 2>/dev/null)" 9
  uc _path=/nowhere STALE=9 CHECK_CMD=x
  out=$(detect_clean "$r" 'echo "[$CHECK_CMD] [$STALE]"'; echo "exit=$?")
  assert_match "user contract: a reassigned _path neither breaks the reader nor lets CHECK_CMD in" "$out" '^\[bun run typecheck && bun run test\] \[9\]$'
  assert_match "user contract: ... and CHECK_CMD is named" "$out" "^$UC/tower/orchestrate: 'CHECK_CMD' is a repo contract setting"
  # A contract that fails part way is refused, naming the file, never half read.
  for body in 'STALE=9; false' 'STALE=9; exit 3' 'STALE=9; if' 'STALE=9; echo "$UNSET_IN_TEST"'; do
    uc "$body"
    out=$(detect_in "$r" 'echo "reached [$STALE]"'; echo "exit=$?")
    assert_match "user contract: '$body' is refused" "$out" 'exit=1$'
    assert_match "user contract: '$body' ... naming the file" "$out" "^$UC/tower/orchestrate: it failed to load"
    assert_nomatch "user contract: '$body' ... before anything runs on it" "$out" '^reached'
  done
  uc LANE_REVIEW=maybe
  out=$(detect_in "$r" 'echo reached'; echo "exit=$?")
  assert_match "user contract: a bad switch value is refused" "$out" "LANE_REVIEW must be on or off \\(got 'maybe'\\)"
  assert_match "user contract: ... and fails" "$out" 'exit=1$'
  uc LANE_REVIEW=off
  assert_eq "user contract: the call's environment wins over its switch" "$(LANE_REVIEW=on detect_in "$r" 'echo $LANE_REVIEW')" on
  # add-reviewer reads it too.
  uc REVIEWER_MODEL_CODEX=rev-user
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-uc-review"
  out=$(boot "$r" "$RUN" "Review" main "$KIT/example-tasks.tsv")
  uc REVIEWER_MODEL_CODEX=rev-later
  out=$(cd "$r" && env HOME="$TMP/uc-home" XDG_CONFIG_HOME="$UC" EXIT_WAIT_SECONDS=3 "$KIT/add-reviewer.sh" "$RUN" R1 claude "Lane review A" "$RUN/findings/a.json" 2>&1)
  assert_match "user contract: add-reviewer's Reviewer takes its REVIEWER_MODEL_CODEX" "$(cat "$RUN/panes.txt")" '^reviewer R1: .*kind codex, model rev-later, '
fi

# --- cursor-lane -------------------------------------------------------------
# EXECUTOR_KIND=cursor: a lane in the Cursor CLI (cursor-agent), through herdr.
if section cursor-lane; then
  mkdir -p "$TMP/cl-home/.agents/skills/tdd"
  boot() { (cd "$1" && shift && env HOME="$TMP/cl-home" "$KIT/bootstrap.sh" "$@" 2>&1); }
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-cursor"; reset_stub
  out=$(EXECUTOR_KIND=cursor boot "$r" "$RUN" "Cursor" main)
  C=$(git -C "$r" rev-parse --path-format=absolute --git-common-dir)
  log=$(cat "$HERDR_STUB_LOG")
  assert_match "cursor lane: started trusted, without approvals or self-update, on grok-4.7-high-fast" "$log" \
    "^herdr agent start bun-vitest-lane-a --kind cursor --pane pane-3 -- --model grok-4\\.7-high-fast --trust --force --disable-auto-update --add-dir $RUN --add-dir $C\$"
  assert_nomatch "cursor lane: no --sandbox flag" "$log" '^herdr agent start .*--sandbox'
  assert_match "cursor lane: the pane map says kind cursor and its model" "$(cat "$RUN/panes.txt")" \
    '^lane A: +pane-3 +\(agent "bun-vitest-lane-a", kind cursor, .*, model grok-4\.7-high-fast, tab lanes\)$'
  assert_eq "cursor run: grok-4.7-high-fast is the recorded spec and quality reviewer model" \
    "$(board "$RUN" '" ".join(k+"="+v for k,v in sorted(d["run"]["models"].items()))')" \
    "implementer=grok-4.7-high-fast quality-reviewer=grok-4.7-high-fast spec-reviewer=grok-4.7-high-fast"
  assert_match "cursor run: its Reviewer has a model" "$(cat "$RUN/panes.txt")" '^reviewer: +kind claude, model claude-opus-5-5$'
  # start NAME [ENV...]: start_agent_with_trust_retry for a cursor NAME in pane-9.
  start() { local n=$1; shift; reset_stub; (cd "$r" && env HOME="$TMP/cl-home" EXECUTOR_KIND=cursor "$@" bash -c ". \"\$KIT/common.sh\"; need_runner; . \"\$KIT/executor.sh\"; start_agent_with_trust_retry $n pane-9; echo \"exit=\$?\"" 2>&1); }
  out=$(start acme-lane-a HERDR_STUB_TRUST_STARTS=1)
  assert_match "cursor trust box: the start fails" "$out" 'exit=1$'
  assert_match "cursor trust box: ... saying to check the pane" "$out" 'acme-lane-a is blocked during startup in pane pane-9.*check the pane'
  assert_nomatch "cursor trust box: ... and sends no keys" "$(cat "$HERDR_STUB_LOG")" '^herdr pane send-keys'
  model_of() { start acme-lane-a "$@" >/dev/null; sed -nE 's/^herdr agent start .* -- --model ([^ ]+) .*/\1/p' "$HERDR_STUB_LOG"; }
  assert_eq "cursor model: EXECUTOR_MODEL in the environment" "$(model_of EXECUTOR_MODEL=lane-m)" lane-m
  assert_eq "cursor model: EXECUTOR_MODEL_CURSOR in the environment" "$(model_of EXECUTOR_MODEL_CURSOR=lane-k)" lane-k
  mkdir -p "$TMP/cl-xdg/tower"; echo EXECUTOR_MODEL_CURSOR=lane-u > "$TMP/cl-xdg/tower/orchestrate"
  rc=$(fixture_repo bun-vitest); RUN="$TMP/run-cursor-uc"
  out=$(cd "$rc" && env HOME="$TMP/cl-home" XDG_CONFIG_HOME="$TMP/cl-xdg" EXECUTOR_KIND=cursor "$KIT/bootstrap.sh" "$RUN" "Cursor" main 2>&1)
  assert_match "cursor model: EXECUTOR_MODEL_CURSOR in the user contract" "$(cat "$RUN/panes.txt")" '^lane A: .*kind cursor, .*, model lane-u, tab lanes\)$'
  rc=$(fixture_repo bun-vitest); RUN="$TMP/run-cursor-rc"; echo EXECUTOR_MODEL=lane-r > "$rc/.orchestrate"
  out=$(cd "$rc" && env HOME="$TMP/cl-home" XDG_CONFIG_HOME="$TMP/cl-xdg" EXECUTOR_KIND=cursor "$KIT/bootstrap.sh" "$RUN" "Cursor" main 2>&1)
  assert_match "cursor model: EXECUTOR_MODEL in the repo contract" "$(cat "$RUN/panes.txt")" '^lane A: .*kind cursor, .*, model lane-r, tab lanes\)$'
  # One that exits right after its start is started once more; gone again, the start fails.
  printf 'gone\ngone\n' > "$HERDR_STUB_STATES_DIR/acme-lane-x.started"
  out=$(start acme-lane-x)
  assert_eq "cursor exits after its start: started once more" "$(grep -c '^herdr agent start acme-lane-x --kind cursor ' "$HERDR_STUB_LOG")" 2
  assert_match "cursor exits after its start: ... then the start fails, saying so" "$out" 'acme-lane-x exited again after it was started once more'
  assert_match "cursor exits after its start: ... non-zero" "$out" 'exit=1$'
  rm -f "$HERDR_STUB_STATES_DIR"/acme-lane-x*
  # A mixed run: a cursor lane B beside claude lane A.
  rm_=$(fixture_repo bun-vitest); RUN="$TMP/run-mixed-cursor"
  (cd "$rm_" && env HOME="$TMP/cl-home" "$KIT/bootstrap.sh" "$RUN" "Mixed" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
  git -C "$rm_" worktree add -q "$rm_/.worktrees/feat/b" -b feat/b   # the stub's worktree create makes none
  C=$(git -C "$rm_" rev-parse --path-format=absolute --git-common-dir)
  reset_stub; out=$(cd "$rm_" && env HOME="$TMP/cl-home" EXECUTOR_KIND=cursor "$KIT/add-lane.sh" "$RUN" B feat/b main 2 2>&1)
  map=$(cat "$RUN/panes.txt")
  assert_match "mixed: lane A is claude" "$map" '^lane A: .*kind claude, '
  assert_match "mixed: add-lane opens a cursor lane B" "$map" '^lane B: .*kind cursor, .*, model grok-4\.7-high-fast, tab lanes\)$'
  assert_match "mixed: ... started as cursor in its worktree's run" "$(cat "$HERDR_STUB_LOG")" "^herdr agent start bun-vitest-lane-b --kind cursor --pane pane-[0-9]+ -- --model grok-4\\.7-high-fast --trust --force --disable-auto-update --add-dir $RUN --add-dir $C\$"
  out=$(cd "$rm_" && EXECUTOR_KIND=gemini bash -c ". \"\$KIT/common.sh\"; . \"\$KIT/executor.sh\"" 2>&1)
  assert_match "EXECUTOR_KIND=gemini: refused, listing the kinds" "$out" "EXECUTOR_KIND must be claude, codex or cursor \\(got 'gemini'\\)"
  installed() { env HOME="$TMP/cl-home" "$@" bash -c ". \"\$KIT/common.sh\"; . \"\$KIT/executor.sh\"; kind_installed cursor && echo yes || echo no" 2>&1; }
  assert_eq "cursor: installed when cursor-agent answers --version" "$(installed)" yes
  assert_match "cursor: ... probed through cursor-agent" "$(reset_stub; installed >/dev/null; cat "$HERDR_STUB_LOG")" '^cursor-agent --version$'
  assert_eq "cursor: not installed when cursor-agent refuses" "$(installed CURSOR_STUB=absent)" no
  # The tdd skill: cursor reads ~/.agents/skills, ~/.claude/skills and ~/.codex/skills.
  hint_in() { env HOME="$1" EXECUTOR_KIND=cursor bash -c ". \"\$KIT/common.sh\"; . \"\$KIT/executor.sh\"" 2>&1; }
  mkdir -p "$TMP/cl-none"
  assert_match "cursor tdd: no skill in any of its dirs, a hint" "$(hint_in "$TMP/cl-none")" '^info: no tdd skill in ~/\.agents/skills, ~/\.claude/skills or ~/\.codex/skills — the cursor$'
  for d in .agents/skills .claude/skills .codex/skills; do
    mkdir -p "$TMP/cl-$d/$d/tdd"
    assert_eq "cursor tdd: in ~/$d, no hint" "$(hint_in "$TMP/cl-$d")" ""
  done
fi

# --- cursor-reviewer ---------------------------------------------------------
# The Reviewer is the first installed of the lane's candidates (claude lane:
# codex; codex lane: claude; cursor lane: claude, then codex), else the lane's
# own kind with a note.
if section cursor-reviewer; then
  mkdir -p "$TMP/cr-home/.codex/skills/tdd" "$TMP/cr-home/.agents/skills/tdd"
  rev() { HOME="$TMP/cr-home" in_kit ". \"\$KIT/executor.sh\"; reviewer_for $1"; }
  T=$(printf '\t')
  assert_eq "cursor lane: claude reviews it on claude-opus-5-5" "$(rev cursor)" "claude${T}claude-opus-5-5${T}"
  assert_eq "cursor lane, claude absent: codex on gpt-6-astra" "$(CLAUDE_STUB=absent rev cursor)" "codex${T}gpt-6-astra${T}"
  assert_eq "cursor lane, claude and codex absent: a fresh cursor agent, with a note" "$(CLAUDE_STUB=absent CODEX_STUB=absent rev cursor)" \
    "cursor${T}grok-4.7-high-fast${T}fallback: claude and codex are not installed, so a fresh cursor agent reviews cursor"
  assert_eq "claude lane, codex absent: never cursor, claude as before" "$(CODEX_STUB=absent rev claude)" \
    "claude${T}claude-fable-5-1${T}fallback: codex is not installed, so claude reviews claude"
  assert_eq "codex lane, claude absent: never cursor, codex as before" "$(CLAUDE_STUB=absent EXECUTOR_KIND=codex rev codex)" \
    "codex${T}gpt-6-astra${T}fallback: claude is not installed, so a fresh codex agent reviews codex"
  for lane in claude codex cursor; do
    assert_eq "REVIEWER_KIND=cursor: a $lane lane gets cursor on REVIEWER_MODEL_CURSOR" "$(REVIEWER_KIND=cursor rev $lane)" "cursor${T}grok-4.7-high-fast${T}"
  done
  assert_match "REVIEWER_KIND=cursor: refused when cursor is not installed" "$(CURSOR_STUB=absent REVIEWER_KIND=cursor rev claude)" 'REVIEWER_KIND=cursor, but cursor is not installed'
  assert_eq "REVIEWER_MODEL: replaces a cursor Reviewer's model" "$(REVIEWER_KIND=cursor REVIEWER_MODEL=rev-m rev cursor)" "cursor${T}rev-m${T}"
  assert_eq "REVIEWER_MODEL: replaces the model for a cursor lane" "$(REVIEWER_MODEL=rev-m rev cursor)" "claude${T}rev-m${T}"
  out=$(CLAUDE_STUB=absent CODEX_STUB=absent CURSOR_STUB=absent rev cursor)
  assert_match "no candidate and the lane's own kind absent: refused, naming all three" "$out" 'no Reviewer for a cursor lane: claude, codex and cursor are not installed'
  detect_in() { (cd "$1" && bash -c "set -euo pipefail; . \"\$KIT/common.sh\"; . \"\$KIT/detect-stack.sh\"; $2" 2>&1); }
  r=$(fixture_repo bun-vitest)
  assert_eq "REVIEWER_KIND=cursor: a valid switch value" "$(REVIEWER_KIND=cursor detect_in "$r" 'echo $REVIEWER_KIND')" cursor
  assert_match "REVIEWER_KIND: an unknown kind is refused, listing cursor" "$(REVIEWER_KIND=gemini detect_in "$r" true)" "REVIEWER_KIND must be other, claude, codex or cursor \\(got 'gemini'\\)"
  # add-reviewer: a cursor lane, and a cursor Reviewer.
  if [ "${RUNNER:-herdr}" = orca ]; then
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-cr-orca"; C=$(git -C "$r" rev-parse --path-format=absolute --git-common-dir)
  (cd "$r" && env HOME="$TMP/cr-home" REVIEWER_KIND=cursor "$KIT/bootstrap.sh" "$RUN" "Cursor reviews" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
  : > "$ORCA_STUB_LOG"; out=$(cd "$r" && env HOME="$TMP/cr-home" EXIT_WAIT_SECONDS=3 "$KIT/add-reviewer.sh" "$RUN" R1 claude "Lane review A" "$RUN/findings/a.json" 2>&1; echo "exit=$?")
  assert_match "orca, REVIEWER_KIND=cursor: add-reviewer finishes" "$out" 'exit=0$'
  assert_match "orca, REVIEWER_KIND=cursor: started as cursor-agent in its terminal, with the cursor argv" "$(cat "$ORCA_STUB_LOG")" \
    "^orca terminal send --terminal term-4 --text cursor-agent --model grok-4\\.7-high-fast --trust --force --disable-auto-update --add-dir $RUN --add-dir $C --enter --json\$"
  assert_match "orca, REVIEWER_KIND=cursor: the pane map's reviewer line" "$(cat "$RUN/panes.txt")" '^reviewer R1: +term-4 +\(agent "bun-vitest-r1-1", kind cursor, model grok-4\.7-high-fast, review '
  else
    review() { local d=$1; shift; (cd "$d" && env HOME="$TMP/cr-home" EXIT_WAIT_SECONDS=3 "$@" 2>&1); }
    r=$(fixture_repo bun-vitest); RUN="$TMP/run-cr-lane"
    out=$(review "$r" EXECUTOR_KIND=cursor "$KIT/bootstrap.sh" "$RUN" "Cursor" main "$KIT/example-tasks.tsv")
    reset_stub; out=$(review "$r" "$KIT/add-reviewer.sh" "$RUN" R1 cursor "Lane review A" "$RUN/findings/a.json" A; echo "exit=$?")
    assert_match "add-reviewer: lane kind cursor is accepted" "$out" 'exit=0$'
    assert_match "add-reviewer: a cursor lane gets a claude Reviewer" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-r1-1 --kind claude --pane pane-[0-9]+ -- --model claude-opus-5-5$'
    r=$(fixture_repo bun-vitest); RUN="$TMP/run-cr-kind"; C=$(git -C "$r" rev-parse --path-format=absolute --git-common-dir)
    out=$(review "$r" REVIEWER_KIND=cursor "$KIT/bootstrap.sh" "$RUN" "Cursor reviews" main "$KIT/example-tasks.tsv")
    assert_match "REVIEWER_KIND=cursor: the tower note names the cursor Reviewer" "$(notes "$RUN")" '^reviewer: kind cursor, model grok-4\.7-high-fast$'
    reset_stub; out=$(review "$r" "$KIT/add-reviewer.sh" "$RUN" R1 claude "Lane review A" "$RUN/findings/a.json")
    assert_match "REVIEWER_KIND=cursor: started with the cursor argv" "$(cat "$HERDR_STUB_LOG")" \
      "^herdr agent start bun-vitest-r1-1 --kind cursor --pane pane-[0-9]+ -- --model grok-4\\.7-high-fast --trust --force --disable-auto-update --add-dir $RUN --add-dir $C\$"
    assert_match "REVIEWER_KIND=cursor: the pane map's reviewer line" "$(cat "$RUN/panes.txt")" '^reviewer R1: +pane-[0-9]+ +\(agent "bun-vitest-r1-1", kind cursor, model grok-4\.7-high-fast, review '
    # A cursor lane reviewed by cursor: the lane named, its line read from the pane map.
    r=$(fixture_repo bun-vitest); RUN="$TMP/run-cr-self"
    out=$(review "$r" EXECUTOR_KIND=cursor EXECUTOR_MODEL=lane-m "$KIT/bootstrap.sh" "$RUN" "Cursor" main "$KIT/example-tasks.tsv")
    reset_stub; out=$(review "$r" CLAUDE_STUB=absent CODEX_STUB=absent "$KIT/add-reviewer.sh" "$RUN" R1 cursor "Lane review A" "$RUN/findings/a.json" A)
    assert_match "cursor reviews cursor: on REVIEWER_MODEL_CURSOR" "$(cat "$RUN/panes.txt")" '^reviewer R1: .*kind cursor, model grok-4\.7-high-fast, review '
    assert_match "cursor reviews cursor: ... with the fallback note" "$out" '^reviewer: fallback: claude and codex are not installed, so a fresh cursor agent reviews cursor$'
  fi
  assert_match "no candidate and a codex lane's own kind absent: refused, naming cursor's way in" "$(CLAUDE_STUB=absent CODEX_STUB=absent EXECUTOR_KIND=codex rev codex)" \
    'no Reviewer for a codex lane: claude and codex are not installed \(cursor reviews a codex lane only with REVIEWER_KIND=cursor\)'
  assert_match "an unknown lane kind is refused" "$(rev gemini)" "lane kind must be claude, codex or cursor \\(got 'gemini'\\)"
  assert_match "an unknown lane kind is refused, a forced Reviewer kind too" "$(REVIEWER_KIND=cursor rev gemini)" "lane kind must be claude, codex or cursor \\(got 'gemini'\\)"
  assert_eq "reviewer_candidates: a cursor lane's, in order" "$(HOME="$TMP/cr-home" in_kit ". \"\$KIT/executor.sh\"; reviewer_candidates cursor" | tr '\n' ' ')" "claude codex "
fi

# --- credit-guard ------------------------------------------------------------
# REVIEWER_BY_CREDITS=on skips a Reviewer candidate below REVIEWER_CREDITS_MIN
# (% left), with a note. The probes run for real against per-section fakes:
# security and curl here, the codex stub's app-server (CODEX_STUB_RATE_LIMITS).
if section credit-guard; then
  CG="$TMP/credit-guard"; mkdir -p "$CG/bin" "$CG/keychain" "$TMP/cg-home/.codex/skills/tdd" "$TMP/cg-home/.agents/skills/tdd"
  TOK=tok-fake-sam-0002
  cat > "$CG/bin/security" <<SH
#!/bin/sh
printf 'security %s\n' "\$*" >> "$CG/probes.log"
while [ \$# -gt 0 ]; do [ "\$1" = -s ] && svc=\$2; shift; done
[ -f "$CG/keychain/\$svc" ] || exit 44
cat "$CG/keychain/\$svc"
SH
  cat > "$CG/bin/curl" <<SH
#!/bin/sh
printf 'curl %s\n' "\$*" >> "$CG/probes.log"
h=\$(cat)
case "\$h" in
  *"Authorization: Bearer $TOK"*) ;;
  *) exit 22 ;;
esac
case "\$*" in
  *oauth/usage*) f=claude ;;
  *DashboardService*) f=cursor ;;
  *) exit 22 ;;
esac
[ -f "$CG/\$f.json" ] || exit 22
cat "$CG/\$f.json"
SH
  chmod +x "$CG/bin/security" "$CG/bin/curl"
  printf '{"claudeAiOauth":{"accessToken":"%s"}}' "$TOK" > "$CG/keychain/Claude Code-credentials"
  printf '%s' "$TOK" > "$CG/keychain/cursor-access-token"
  # left KIND N: KIND's tightest window has N% left; left KIND -: unreadable.
  left() {
    case "$1:$2" in
      *:-) rm -f "$CG/$1.json" "$CG/codex-limits" ;;
      claude:*) echo "{\"five_hour\":{\"utilization\":$((100-$2))},\"seven_day\":{\"utilization\":0}}" > "$CG/claude.json" ;;
      cursor:*) echo "{\"planUsage\":{\"totalPercentUsed\":$((100-$2))}}" > "$CG/cursor.json" ;;
      codex:*)  echo "{\"rateLimits\":{\"primary\":{\"usedPercent\":$((100-$2))},\"secondary\":null}}" > "$CG/codex-limits" ;;
    esac
  }
  export CODEX_STUB_RATE_LIMITS="$CG/codex-limits"
  rev() { : > "$CG/probes.log"; CREDITS_FAKES="$CG/bin" HOME="$TMP/cg-home" in_kit ". \"\$KIT/executor.sh\"; reviewer_for $1"; }
  T=$(printf '\t')
  left codex 12; left claude 90; left cursor 90
  # DRY_RUN opens nothing real: with a security and curl on PATH that are not
  # a test's declared fakes (CREDITS_FAKES), no probe runs.
  : > "$CG/probes.log"; reset_stub
  out=$(PATH="$CG/bin:$PATH" HOME="$TMP/cg-home" REVIEWER_BY_CREDITS=on in_kit ". \"\$KIT/executor.sh\"; reviewer_for claude")
  assert_eq "DRY_RUN: no CREDITS_FAKES, no keychain or endpoint is reached" "$(cat "$CG/probes.log"; grep '^codex app-server' "$HERDR_STUB_LOG")" ""
  assert_eq "DRY_RUN: ... and codex, its credits unread, reviews" "$(printf '%s\n' "$out" | head -1 | cut -f1)" codex
  assert_eq "DRY_RUN: credits_left prints nothing without CREDITS_FAKES" "$(PATH="$CG/bin:$PATH" in_kit ". \"\$KIT/credits.sh\"; credits_left claude")" ""
  assert_eq "DRY_RUN: ... nor for cursor" "$(PATH="$CG/bin:$PATH" in_kit ". \"\$KIT/credits.sh\"; credits_left cursor")" ""
  assert_eq "DRY_RUN: ... nor for codex" "$(in_kit ". \"\$KIT/credits.sh\"; credits_left codex")" ""
  # An incomplete fakes dir probes nothing either. Asked for codex, whose probe
  # is the stub's app-server: a regression here reaches no real tool.
  mkdir -p "$CG/no-curl" "$CG/no-security" "$CG/dir-fakes/security" "$CG/dir-fakes/curl"
  ln -sf "$CG/bin/security" "$CG/no-curl/security"; ln -sf "$CG/bin/curl" "$CG/no-security/curl"
  for d in no-curl no-security dir-fakes; do
    assert_eq "DRY_RUN: CREDITS_FAKES=$d probes nothing" "$(CREDITS_FAKES="$CG/$d" in_kit ". \"\$KIT/credits.sh\"; credits_left codex")" ""
  done
  assert_eq "DRY_RUN: ... though a full one does" "$(CREDITS_FAKES="$CG/bin" in_kit ". \"\$KIT/credits.sh\"; credits_left codex")" 12
  assert_eq "guard off: the Reviewer as without credits" "$(rev claude)" "codex${T}gpt-6-astra${T}"
  assert_eq "guard off: no probe runs" "$(cat "$CG/probes.log")" ""
  assert_eq "guard on: a claude lane with codex at 12% is reviewed by claude, noted" "$(REVIEWER_BY_CREDITS=on rev claude)" \
    "claude${T}claude-fable-5-1${T}reviewer: skipped codex, 12% credits left; fallback: codex is low on credits, so claude reviews claude"
  reset_stub; out=$(rev cursor)
  assert_nomatch "guard off: ... not even codex's app-server" "$(cat "$HERDR_STUB_LOG")" '^codex app-server'
  left claude 5; left codex 50
  assert_eq "guard on: a cursor lane with claude at 5% and codex at 50% is reviewed by codex" "$(REVIEWER_BY_CREDITS=on rev cursor)" \
    "codex${T}gpt-6-astra${T}reviewer: skipped claude, 5% credits left"
  left codex 9
  assert_eq "guard on: a cursor lane with claude and codex low is reviewed by cursor, a note for each" "$(REVIEWER_BY_CREDITS=on rev cursor)" \
    "cursor${T}grok-4.7-high-fast${T}reviewer: skipped claude, 5% credits left; reviewer: skipped codex, 9% credits left; fallback: claude and codex are low on credits, so a fresh cursor agent reviews cursor"
  assert_eq "guard on: one absent, one low, the fallback says which is which" "$(REVIEWER_BY_CREDITS=on CLAUDE_STUB=absent rev cursor)" \
    "cursor${T}grok-4.7-high-fast${T}reviewer: skipped codex, 9% credits left; fallback: claude is not installed and codex is low on credits, so a fresh cursor agent reviews cursor"
  left claude -
  assert_eq "guard on: unreadable credits count as enough, noted" "$(REVIEWER_BY_CREDITS=on rev cursor)" \
    "claude${T}claude-opus-5-5${T}reviewer: claude credits unreadable, counted as enough"
  assert_match "guard on: ... after a probe ran" "$(cat "$CG/probes.log")" '^security '
  left claude 5; left codex -
  assert_eq "guard on: a skip, then an unreadable candidate, both noted in order" "$(REVIEWER_BY_CREDITS=on rev cursor)" \
    "codex${T}gpt-6-astra${T}reviewer: skipped claude, 5% credits left; reviewer: codex credits unreadable, counted as enough"
  left claude -
  left claude 50
  assert_eq "guard on: REVIEWER_CREDITS_MIN=60 makes 50% a skip" "$(REVIEWER_BY_CREDITS=on REVIEWER_CREDITS_MIN=60 CODEX_STUB=absent rev cursor)" \
    "cursor${T}grok-4.7-high-fast${T}reviewer: skipped claude, 50% credits left; fallback: codex is not installed and claude is low on credits, so a fresh cursor agent reviews cursor"
  for v in 120 abc 99999999999999999999; do
    out=$(REVIEWER_BY_CREDITS=on REVIEWER_CREDITS_MIN="$v" rev claude; echo "exit=$?")
    assert_match "guard on: REVIEWER_CREDITS_MIN='$v' is refused by reviewer_for too" "$out" \
      "^REVIEWER_CREDITS_MIN must be a whole number from 0 to 100 \\(got '$v'\\)"
    assert_match "guard on: ... '$v' exits non-zero" "$out" 'exit=1$'
  done
  left codex 99
  assert_eq "guard on: REVIEWER_CREDITS_MIN=100 is valid, and 99% is below it" "$(REVIEWER_BY_CREDITS=on REVIEWER_CREDITS_MIN=100 rev claude | cut -f1,3)" \
    "claude${T}reviewer: skipped codex, 99% credits left; fallback: codex is low on credits, so claude reviews claude"
  assert_nomatch "guard on: ... with no shell error" "$(REVIEWER_BY_CREDITS=on REVIEWER_CREDITS_MIN=99999999999999999999 rev claude)" 'expression|out of range'
  left codex 20
  assert_eq "guard on: exactly the threshold is enough" "$(REVIEWER_BY_CREDITS=on rev claude)" "codex${T}gpt-6-astra${T}"
  left codex 1
  reset_stub
  assert_eq "guard on: REVIEWER_KIND=codex with codex at 1% is codex" "$(REVIEWER_BY_CREDITS=on REVIEWER_KIND=codex rev claude)" "codex${T}gpt-6-astra${T}"
  assert_eq "guard on: ... and no probe runs" "$(cat "$CG/probes.log"; grep '^codex app-server' "$HERDR_STUB_LOG")" ""
  assert_eq "guard on, the lane's own kind absent: the skipped candidate reviews after all" "$(REVIEWER_BY_CREDITS=on CLAUDE_STUB=absent rev claude)" \
    "codex${T}gpt-6-astra${T}reviewer: skipped codex, 1% credits left; fallback: claude is not installed, so codex reviews despite its credits"
  # A preflight slot: claude on Fable while its credits last, whatever the
  # guard switch says; below them another kind, and with none, claude on Opus.
  pre() { : > "$CG/probes.log"; CREDITS_FAKES="$CG/bin" HOME="$TMP/cg-home" in_kit ". \"\$KIT/executor.sh\"; preflight_reviewer $1"; }
  assert_eq "preflight: claude with credits reviews on Fable, for any lane kind" "$(pre codex)" "claude${T}claude-fable-5-1${T}"
  assert_match "preflight: ... after a probe, the guard switch off" "$(cat "$CG/probes.log")" '^security '
  left claude 5; left codex 50
  assert_eq "preflight: claude low, codex reviews on its Reviewer model" "$(pre claude)" "codex${T}gpt-6-astra${T}reviewer: skipped claude, 5% credits left"
  left codex 9
  assert_eq "preflight: claude and codex low, cursor reviews" "$(pre claude)" \
    "cursor${T}grok-4.7-high-fast${T}reviewer: skipped claude, 5% credits left; reviewer: skipped codex, 9% credits left"
  left cursor 3
  assert_eq "preflight: every kind low, claude reviews on Opus" "$(pre claude)" \
    "claude${T}claude-opus-5-5${T}reviewer: skipped claude, 5% credits left; reviewer: skipped codex, 9% credits left; reviewer: skipped cursor, 3% credits left; fallback: no other kind has credits, so claude reviews on claude-opus-5-5"
  assert_eq "preflight: REVIEWER_KIND=claude is Fable" "$(REVIEWER_KIND=claude pre codex)" "claude${T}claude-fable-5-1${T}"
  assert_eq "preflight: ... and no probe runs" "$(cat "$CG/probes.log")" ""
  assert_eq "preflight: REVIEWER_MODEL replaces the model" "$(REVIEWER_MODEL=m pre claude | cut -f1,2)" "claude${T}m"
  assert_eq "preflight: claude not installed, the lane order picks" "$(CLAUDE_STUB=absent pre claude | cut -f1,2)" "codex${T}gpt-6-astra"
  left claude 50; left codex 1; left cursor 90
  # The switches: in the pane map, validated, and from the user contract.
  detect_in() { (cd "$1" && env XDG_CONFIG_HOME="$CG/xdg" bash -c "set -euo pipefail; . \"\$KIT/common.sh\"; . \"\$KIT/detect-stack.sh\"; $2" 2>&1); }
  r=$(fixture_repo bun-vitest)
  assert_match "switches: the guard is off by default, its threshold the defaults file's" "$(detect_in "$r" switches_line)" ' REVIEWER_BY_CREDITS=off REVIEWER_CREDITS_MIN=20 '
  assert_match "switches: REVIEWER_BY_CREDITS accepts only on or off" "$(REVIEWER_BY_CREDITS=yes detect_in "$r" true)" "REVIEWER_BY_CREDITS must be on or off \\(got 'yes'\\)"
  for v in 120 abc -5 99999999999999999999 ' 7'; do
    assert_match "switches: REVIEWER_CREDITS_MIN='$v' is refused" "$(REVIEWER_CREDITS_MIN="$v" detect_in "$r" true 2>&1)" "^REVIEWER_CREDITS_MIN must be a whole number from 0 to 100 \\(got '$v'\\)\$"
  done
  assert_nomatch "switches: a huge REVIEWER_CREDITS_MIN is refused without a shell error" "$(REVIEWER_CREDITS_MIN=99999999999999999999 detect_in "$r" true 2>&1)" 'expression|out of range'
  assert_match "switches: REVIEWER_CREDITS_MIN=08 is 8%" "$(REVIEWER_CREDITS_MIN=08 detect_in "$r" switches_line)" ' REVIEWER_CREDITS_MIN=08 '
  mkdir -p "$CG/xdg/tower"; printf '%s\n' REVIEWER_BY_CREDITS=on REVIEWER_CREDITS_MIN=60 > "$CG/xdg/tower/orchestrate"
  out=$(detect_in "$r" switches_line)
  assert_match "user contract: sets the guard and its threshold" "$out" ' REVIEWER_BY_CREDITS=on REVIEWER_CREDITS_MIN=60 '
  assert_nomatch "user contract: ... both its keys" "$out" 'not a setting|repo contract setting'
  # add-reviewer under the guard.
  if [ "${RUNNER:-herdr}" = orca ]; then
  kit() { local d=$1; shift; (cd "$d" && env CREDITS_FAKES="$CG/bin" HOME="$TMP/cg-home" XDG_CONFIG_HOME="$TMP/cg-none" EXIT_WAIT_SECONDS=3 "$@" 2>&1); }
  left codex 12; left claude 90
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-cg-orca"; reset_stub
  out=$(kit "$r" REVIEWER_BY_CREDITS=on "$KIT/bootstrap.sh" "$RUN" "Credits" main "$KIT/example-tasks.tsv")
  : > "$ORCA_STUB_LOG"; out=$(kit "$r" "$KIT/add-reviewer.sh" "$RUN" R1 claude "Lane review A" "$RUN/findings/a.json" A)
  assert_match "orca: a claude lane with codex at 12% gets claude, in its terminal" "$(cat "$ORCA_STUB_LOG")" '^orca terminal send --terminal term-4 --text claude --model '
  assert_match "orca: the record gets the skip note" "$(notes "$RUN")" '^reviewer: skipped codex, 12% credits left$'
  else
    # add-reviewer: the skip notes go to the record, for a lane review and a
    # preflight slot alike; the run's switches come from the pane map.
    kit() { local d=$1; shift; (cd "$d" && env CREDITS_FAKES="$CG/bin" HOME="$TMP/cg-home" XDG_CONFIG_HOME="$TMP/cg-none" EXIT_WAIT_SECONDS=3 "$@" 2>&1); }
    left codex 12; left claude 90
    r=$(fixture_repo bun-vitest); RUN="$TMP/run-cg"; : > "$CG/probes.log"; reset_stub
    out=$(kit "$r" REVIEWER_BY_CREDITS=on "$KIT/bootstrap.sh" "$RUN" "Credits" main "$KIT/example-tasks.tsv")
    map=$(cat "$RUN/panes.txt")
    assert_match "bootstrap: its reviewer line is a forecast, probing nothing" "$map" '^reviewer: +kind codex, model gpt-6-astra \(credit guard on: each review skips a kind below 20% credits left\)$'
    assert_eq "bootstrap: ... no probe ran" "$(cat "$CG/probes.log"; grep '^codex app-server' "$HERDR_STUB_LOG")" ""
    reset_stub; out=$(kit "$r" "$KIT/add-reviewer.sh" "$RUN" R1 claude "Lane review A" "$RUN/findings/a.json" A)
    assert_match "add-reviewer: a claude lane with codex at 12% gets claude" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-r1-1 --kind claude '
    assert_match "add-reviewer: the record gets the skip note" "$(notes "$RUN")" '^reviewer: skipped codex, 12% credits left$'
    assert_eq "add-reviewer: ... and prints it once" "$(printf '%s\n' "$out" | grep -c '^reviewer: skipped codex, 12% credits left$')" 1
    assert_match "add-reviewer: ... and the fallback" "$out" '^reviewer: fallback: codex is low on credits, so claude reviews claude$'
    left codex 50
    reset_stub; out=$(kit "$r" "$KIT/add-reviewer.sh" "$RUN" R2 claude "Preflight: security" "$RUN/findings/security.json")
    assert_match "preflight slot: the same guard, codex at 50% reviews" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-r2-1 --kind codex '
    # A cursor lane with both candidates low: each skip in the record, the fallback printed.
    rc=$(fixture_repo bun-vitest); RUNC="$TMP/run-cg-cursor"; left claude 5; left codex 9
    out=$(kit "$rc" REVIEWER_BY_CREDITS=on EXECUTOR_KIND=cursor "$KIT/bootstrap.sh" "$RUNC" "Credits" main "$KIT/example-tasks.tsv")
    out=$(kit "$rc" "$KIT/add-reviewer.sh" "$RUNC" R1 cursor "Lane review A" "$RUNC/findings/a.json" A)
    assert_eq "add-reviewer: two skips, two notes in the record" "$(notes "$RUNC" | grep '^reviewer: skipped' | tr '\n' '|')" \
      "reviewer: skipped claude, 5% credits left|reviewer: skipped codex, 9% credits left|"
    assert_match "add-reviewer: ... and the fallback printed" "$out" '^reviewer: fallback: claude and codex are low on credits, so a fresh cursor agent reviews cursor$'
    left codex 3; echo gone > "$HERDR_STUB_STATES_DIR/bun-vitest-r1-1"   # R1's first Reviewer has exited
    reset_stub; out=$(kit "$r" "$KIT/add-reviewer.sh" "$RUN" R1 claude "Preflight: tests" "$RUN/findings/tests.json")
    assert_match "preflight slot: codex at 3% is skipped" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-r1-2 --kind claude '
    assert_match "preflight slot: ... noted in the record" "$(notes "$RUN")" '^reviewer: skipped codex, 3% credits left$'
    rm -f "$HERDR_STUB_STATES_DIR"/bun-vitest-r1-* "$HERDR_STUB_STATES_DIR"/bun-vitest-r2-*
    # The user's path: a user contract turns the guard on at 60%, bootstrap
    # records both, and add-reviewer skips a candidate at 50%, which the
    # default 20% would keep.
    UCG="$CG/uc-guard"; mkdir -p "$UCG/tower"; printf '%s\n' REVIEWER_BY_CREDITS=on REVIEWER_CREDITS_MIN=60 > "$UCG/tower/orchestrate"
    left claude 50; left codex 90
    r=$(fixture_repo bun-vitest); RUN="$TMP/run-cg-user"
    out=$(kit "$r" XDG_CONFIG_HOME="$UCG" EXECUTOR_KIND=cursor "$KIT/bootstrap.sh" "$RUN" "User guard" main "$KIT/example-tasks.tsv")
    assert_match "user contract guard: bootstrap records it" "$(cat "$RUN/panes.txt")" '^switches: .* REVIEWER_BY_CREDITS=on REVIEWER_CREDITS_MIN=60 '
    # add-reviewer without the user contract: only the pane map carries on/60.
    reset_stub; out=$(kit "$r" "$KIT/add-reviewer.sh" "$RUN" R1 cursor "Lane review A" "$RUN/findings/a.json" A)
    assert_match "user contract guard: claude at 50% is skipped" "$(notes "$RUN")" '^reviewer: skipped claude, 50% credits left$'
    assert_match "user contract guard: ... and codex, the next candidate, reviews" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-r1-1 --kind codex '
    # The user contract changed mid-run to 40%: the pane map's 60% still holds.
    printf '%s\n' REVIEWER_BY_CREDITS=on REVIEWER_CREDITS_MIN=40 > "$UCG/tower/orchestrate"
    reset_stub; out=$(kit "$r" XDG_CONFIG_HOME="$UCG" "$KIT/add-reviewer.sh" "$RUN" R2 cursor "Preflight: security" "$RUN/findings/security.json")
    assert_eq "user contract guard: a mid-run change to it does not reach a review" "$(notes "$RUN" | grep -c '^reviewer: skipped claude, 50% credits left$')" 2
    assert_match "user contract guard: ... codex still reviews" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-r2-1 --kind codex '
    r=$(fixture_repo bun-vitest); RUN="$TMP/run-cg-default"
    out=$(kit "$r" REVIEWER_BY_CREDITS=on EXECUTOR_KIND=cursor "$KIT/bootstrap.sh" "$RUN" "Default guard" main "$KIT/example-tasks.tsv")
    assert_match "without the user contract: the guard is on, at the default 20%" "$(cat "$RUN/panes.txt")" '^switches: .* REVIEWER_BY_CREDITS=on REVIEWER_CREDITS_MIN=20 '
    reset_stub; out=$(kit "$r" "$KIT/add-reviewer.sh" "$RUN" R1 cursor "Lane review A" "$RUN/findings/a.json" A)
    assert_match "without the user contract: claude at 50% reviews (the default 20%)" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-r1-1 --kind claude '
    assert_nomatch "without the user contract: ... with no skip note" "$(notes "$RUN")" '^reviewer: skipped'
    rm -f "$HERDR_STUB_STATES_DIR"/bun-vitest-r1-* "$HERDR_STUB_STATES_DIR"/bun-vitest-r2-*
    # add-reviewer writes an unreadable candidate's note to the record.
    left claude -; left codex 90
    r=$(fixture_repo bun-vitest); RUN="$TMP/run-cg-unread"
    out=$(kit "$r" REVIEWER_BY_CREDITS=on EXECUTOR_KIND=cursor "$KIT/bootstrap.sh" "$RUN" "Unreadable" main "$KIT/example-tasks.tsv")
    assert_nomatch "bootstrap: its forecast probes nothing, so notes no unreadable candidate" "$out" 'unreadable'
    reset_stub; out=$(kit "$r" "$KIT/add-reviewer.sh" "$RUN" R1 cursor "Lane review A" "$RUN/findings/a.json" A)
    assert_match "add-reviewer: an unreadable candidate's note is in the record" "$(notes "$RUN")" '^reviewer: claude credits unreadable, counted as enough$'
    assert_match "add-reviewer: ... and printed" "$out" '^reviewer: claude credits unreadable, counted as enough$'
    assert_match "add-reviewer: ... and claude reviews" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-r1-1 --kind claude '
    rm -f "$HERDR_STUB_STATES_DIR"/bun-vitest-r1-*
    unset CODEX_STUB_RATE_LIMITS
  fi
fi

# --- cursor-docs -------------------------------------------------------------
# install.sh and the example repo contract know cursor, the user contract and
# the credit guard.
if section cursor-docs; then
  # TOWER_BIN_DIR in $TMP: install.sh puts it on PATH, never a real ~/.local/bin.
  out=$(HOME="$TMP/cd-home" TOWER_BIN_DIR="$TMP/cd-home/bin" CURSOR_STUB=absent "$ROOT/install.sh" --check 2>&1)
  assert_match "install: cursor-agent is optional, for cursor lanes" "$out" '^  optional  cursor-agent lanes with EXECUTOR_KIND=cursor$'
  assert_match "install: ... ok when it answers" "$(HOME="$TMP/cd-home" TOWER_BIN_DIR="$TMP/cd-home/bin" "$ROOT/install.sh" --check 2>&1)" '^  ok        cursor-agent \(optional\)$'
  assert_nomatch "install: links no skill dir for cursor" "$(grep -E '^ *link ' "$ROOT/install.sh")" 'cursor'
  ex="$KIT/example.orchestrate"
  for key in 'EXECUTOR_KIND=cursor' 'EXECUTOR_MODEL_CURSOR=' 'EXECUTOR_MODEL_CLAUDE=' 'EXECUTOR_MODEL_CODEX=' 'REVIEWER_MODEL_CURSOR=' \
    'REVIEWER_MODEL_CLAUDE_SELF=' 'SPEC_REVIEWER_MODEL_CURSOR=' 'REVIEWER_BY_CREDITS=off' 'REVIEWER_CREDITS_MIN=20' 'tower/orchestrate'; do
    assert_match "example.orchestrate: documents $key" "$(cat "$ex")" "$key"
  done
  assert_match "example.orchestrate: REVIEWER_KIND lists cursor" "$(cat "$ex")" '^# REVIEWER_KIND=other +other \| claude \| codex \| cursor'
  r=$(fixture_repo bun-vitest); cp "$ex" "$r/.orchestrate"
  out=$(cd "$r" && bash -c "set -euo pipefail; . \"\$KIT/common.sh\"; . \"\$KIT/detect-stack.sh\"; echo parsed" 2>&1)
  assert_match "example.orchestrate: parses" "$out" '^parsed$'
  assert_nomatch "example.orchestrate: ... with no unknown setting" "$out" 'not a setting'
  # Every KEY=value it shows in a comment is a setting the kit reads.
  sed -nE 's/^# ([A-Z_]+=[^ "]*)( .*)?$/\1/p' "$ex" | grep -v '^EXECUTOR_KIND=' > "$r/.orchestrate"
  out=$(cd "$r" && bash -c "set -euo pipefail; . \"\$KIT/common.sh\"; . \"\$KIT/detect-stack.sh\"; echo parsed" 2>&1)
  assert_match "example.orchestrate: its commented settings, set, parse" "$out" '^parsed$'
  assert_nomatch "example.orchestrate: ... every one a setting the kit reads" "$out" 'not a setting'
fi

# --- watch -------------------------------------------------------------------
if section watch; then
  S="$HERDR_STUB_STATES_DIR"
  # A run with one task, in a repo of its own: open, complete (its task done)
  # or closed.
  watch_run() {
    local dir="$TMP/run-watch-$1" t="$KIT/tests/stub/tower"
    (cd "$(fixture_repo none)" && printf '1\tThe one task\tcore\n' | "$t" init --title "Watch $1" --run "$dir" >/dev/null)
    case "$1" in
      complete) "$t" task 1 done --model opus --run "$dir" >/dev/null ;;
      closed)   "$t" close "the run ended" --run "$dir" >/dev/null ;;
    esac
    # The agents the watch is given: a lane each for a and b, and Reviewer r.
    printf '%s\n' 'lane A:         pane-a   (agent "a", kind claude, branch main, checkout /work/acme, model opus, tab lanes)' \
      'lane B:         pane-b   (agent "b", kind claude, branch feat/b, checkout /work/acme-b, model opus, tab lanes)' \
      'reviewer R1:    pane-r   (agent "r", kind codex, model gpt-6-astra, review "Lane review A", findings /work/r.json)' > "$dir/panes.txt"
    echo "$dir"
  }
  RUN=$(watch_run open); RUN_COMPLETE=$(watch_run complete); RUN_CLOSED=$(watch_run closed)
  watch() { (cd "$TMP" && ROUND_SECONDS="${ROUND:-3}" GRACE_SECONDS=0 POLL_SECONDS=0 "$KIT/watch-lanes.sh" "${ON:-$RUN}" "$@" 2>&1; echo "exit=$?"); }
  # Each agent is one lane or Reviewer line's, by its literal name: anything
  # else is refused before the first poll.
  out=$(watch zz)
  assert_match "watch: an agent no line names: refused" "$out" "watch-lanes: no lane or Reviewer line in $RUN/panes.txt names agent zz"
  assert_match "watch: ... at once" "$out" 'exit=1$'
  out=$(watch 'a.*')
  assert_match "watch: a name read literally, not as a pattern" "$out" 'names agent a\.\*'
  assert_match "watch: ... refused" "$out" 'exit=1$'
  cp "$RUN/panes.txt" "$TMP/watch-map"; grep '^lane A:' "$TMP/watch-map" | sed 's/^lane A:/lane C:/' >> "$RUN/panes.txt"
  out=$(watch a)
  assert_match "watch: an agent two lines name: refused" "$out" "watch-lanes: 2 lines in $RUN/panes.txt name agent a"
  assert_match "watch: ... at once" "$out" 'exit=1$'
  # A Reviewer's free-text title may hold another row's marker: only the
  # agent field counts.
  cp "$TMP/watch-map" "$RUN/panes.txt"
  printf '%s\n' 'reviewer R2:    pane-t   (agent "t", kind codex, model gpt-6-astra, review "re (agent "ghost", kind x) and (agent "a", kind y)", findings /work/t.json)' >> "$RUN/panes.txt"
  out=$(watch ghost)
  assert_match "watch: a name only inside a review title: refused" "$out" "no lane or Reviewer line in $RUN/panes.txt names agent ghost"
  out=$(ROUND=1 watch a)
  assert_nomatch "watch: a name also inside another row's title: not ambiguous" "$out" 'lines in .* name agent a'
  assert_match "watch: ... it polls" "$out" 'exit=3$'
  cp "$TMP/watch-map" "$RUN/panes.txt"
  rm "$RUN/panes.txt"; out=$(watch a)
  assert_match "watch: no pane map: refused, saying so" "$out" "watch-lanes: no pane map at $RUN/panes.txt"
  assert_match "watch: ... at once" "$out" 'exit=1$'
  cp "$TMP/watch-map" "$RUN/panes.txt"
  if [ "${RUNNER:-herdr}" = orca ]; then
  # Orca: each agent is found by its terminal, the pane map's lane line; its
  # states and tail are the terminal's (ORCA_STUB_STATES_DIR/term-1).
  S="$ORCA_STUB_STATES_DIR"; rm -f "$S"/*
  reset_stub; in_kit 'orca terminal create --json' >/dev/null
  echo 'lane A:         term-1   (agent "a", kind claude, branch main, checkout /work/acme, model opus, tab lanes)' > "$RUN/panes.txt"
  echo working > "$S/term-1"; out=$(ROUND=1 watch a)
  assert_match "orca: working is quiet, exit 3"        "$out" 'exit=3$'
  assert_match "orca: ... read by its terminal"        "$(cat "$ORCA_STUB_LOG")" '^orca terminal show --terminal term-1 --json$'
  echo blocked > "$S/term-1"; printf 'need the API key\n' > "$S/term-1.tail"; out=$(watch a)
  assert_match "orca: blocked: attention"             "$out" '^attention: a blocked'
  assert_match "orca: blocked: the terminal's tail printed" "$out" 'need the API key'
  echo waiting > "$S/term-1"; printf '[[ALL DONE]]\n' > "$S/term-1.tail"; out=$(watch a)
  assert_match "orca: waiting reads as idle, after the final report" "$out" '^attention: a idle-after-final-report'
  echo waiting > "$S/term-1"; printf 'thinking about it\n' > "$S/term-1.tail"; out=$(watch a)
  assert_match "orca: waiting without the end line: idle-unexplained" "$out" '^attention: a idle-unexplained'
  echo done > "$S/term-1"; printf '[[ALL DONE]]\n' > "$S/term-1.tail"; out=$(watch a)
  assert_match "orca: done (a finished turn, Orca's resting state) reads as idle" "$out" '^attention: a idle-after-final-report'
  # A stale handle proves nothing (Orca's handles end with its runtime): it
  # is unreadable, never gone.
  echo gone > "$S/term-1"; out=$(UNREADABLE_POLLS=2 watch a)
  assert_match "orca: a stale handle: unreadable, not gone" "$out" '^attention: a unreadable'
  echo unreadable > "$S/term-1"; out=$(UNREADABLE_POLLS=2 watch a)
  assert_match "orca: Orca not answering: unreadable" "$out" '^attention: a unreadable'
  # An agent that exited before Orca listed it leaves a bare shell: gone, the
  # attention kind herdr gives an agent that exited.
  rm -f "$S/term-1.tail"; echo unlisted-shell > "$S/term-1"; out=$(watch a)
  assert_match "orca: a bare shell where the agent was: gone" "$out" '^attention: a gone$'
  assert_match "orca: ... gone in the state table too" "$out" '^a +gone$'
  assert_nomatch "orca: ... never a kind of its own" "$out" 'shell'
  rm -f "$S"/* "$RUN/panes.txt"
  else
    rm -f "$S"/*
    echo working > "$S/a"; out=$(ROUND=1 watch a)
    assert_match "quiet: exit 3"                        "$out" 'exit=3$'
    assert_nomatch "quiet: no attention line"           "$out" '^attention:'
    echo blocked > "$S/a"; printf 'need the API key\n' > "$S/a.tail"; out=$(watch a)
    assert_match "blocked: attention line first"        "$out" '^attention: a blocked'
    assert_match "blocked: tail printed"                "$out" 'need the API key'
    assert_match "blocked: exit 0"                      "$out" 'exit=0$'
    echo idle > "$S/a"; printf "tower note --lane A 'ALL DONE - check green'\nSummary: tasks 1-4 done.\n[[ALL DONE]]\n" > "$S/a.tail"; out=$(watch a)
    assert_match "idle after the final report"          "$out" '^attention: a idle-after-final-report'
    echo idle > "$S/b"; printf "tower note --lane B 'lane B complete - ready to merge'\n[[READY TO MERGE]]\n" > "$S/b.tail"; out=$(watch b)
    assert_match "lane B idle after its final report"   "$out" '^attention: b idle-after-final-report'
    echo idle > "$S/r"; printf '[[FINDINGS WRITTEN]] /run/findings/lane-a.json\n' > "$S/r.tail"; out=$(watch r)
    assert_match "a Reviewer idle after writing its findings" "$out" '^attention: r idle-after-final-report'
    echo idle > "$S/a"; printf '⏺ [[ALL DONE]]\n' > "$S/a.tail"; out=$(watch a)
    assert_match "the marker after a TUI bullet reads as the report" "$out" '^attention: a idle-after-final-report'
    # The marker quoted inside other text (a diff, a comment, a sentence) is not
    # a report: an agent reading the kit's own sources shows these.
    echo idle > "$S/a"; printf '+# [[READY TO MERGE]] (lanes B-D)\nreport phrase in double square brackets, [[ALL DONE]] (lane A),\n' > "$S/a.tail"; out=$(watch a)
    assert_match "a quoted marker is not the report"      "$out" '^attention: a idle-unexplained'
    echo idle > "$S/b"; printf '[[ Ready to merge ]]\n' > "$S/b.tail"; out=$(watch b)
    assert_match "the marker in another case or with spaces still reads as the report" "$out" '^attention: b idle-after-final-report'
    # A pane that still shows only its brief has not reported: the briefs name
    # the report phrases (ALL DONE, ready to merge, FINDINGS WRITTEN) but never
    # the marker itself.
    # The tail must still name a report phrase, or the case below tests nothing.
    names_report() { assert_match "$1: the tail names a report phrase" "$(grep -v '^[[:space:]]*$' "$2" | tail -12)" 'ALL DONE|ready to merge|FINDINGS WRITTEN'; }
    echo idle > "$S/a"; sed -n '/^You are lane/,/^Begin now/p' "$KIT/brief-template.md" > "$S/a.tail"; names_report "lane brief" "$S/a.tail"; out=$(watch a)
    assert_match "idle with only the lane brief in the tail is unexplained" "$out" '^attention: a idle-unexplained'
    for brief in 'Lane review' 'Preflight slot'; do
      echo idle > "$S/r"; sed -n "/^### $brief/,/^End with/p" "$KIT/brief-template.md" > "$S/r.tail"; names_report "$brief brief" "$S/r.tail"; out=$(watch r)
      assert_match "idle with only the Reviewer brief ($brief) in the tail is unexplained" "$out" '^attention: r idle-unexplained'
    done
    # The fix prompt rendered for round 2, for lane A and for lane B.
    fix_prompt() { sed -n '/^### Fix prompt/,/^Stay in this session/p' "$KIT/brief-template.md" \
      | sed -E -e 's/\{\{REPORT_ROUND\}\}/2/g' -e "s/\{\{LANE\}\}/$1/g" -e "$2"; }
    echo idle > "$S/a"; fix_prompt A 's/\{\{lane A: "([^"]*)" \| other lanes: "[^"]*"\}\}/\1/g' > "$S/a.tail"; names_report "lane A fix prompt" "$S/a.tail"; out=$(watch a:2)
    assert_match "idle with only lane A's fix prompt in the tail, watched as round 2, is unexplained" "$out" '^attention: a idle-unexplained'
    echo idle > "$S/b"; fix_prompt B 's/\{\{lane A: "[^"]*" \| other lanes: "([^"]*)"\}\}/\1/g' > "$S/b.tail"; names_report "lane B fix prompt" "$S/b.tail"; out=$(watch b:2)
    assert_match "idle with only lane B's fix prompt in the tail, watched as round 2, is unexplained" "$out" '^attention: b idle-unexplained'
    more_prompt() { sed -n '/^### More-work prompt/,/^Stay in this session/p' "$KIT/brief-template.md" \
      | sed -E -e 's/\{\{REPORT_ROUND\}\}/2/g' -e "s/\{\{LANE\}\}/$1/g" -e "$2"; }
    echo idle > "$S/b"; more_prompt B 's/\{\{lane A: "[^"]*" \| other lanes: "([^"]*)"\}\}/\1/g' > "$S/b.tail"; names_report "lane B more-work prompt" "$S/b.tail"; out=$(watch b:2)
    assert_match "idle with only lane B's more-work prompt in the tail, watched as round 2, is unexplained" "$out" '^attention: b idle-unexplained'
    echo idle > "$S/r"; sed -n '/^## Who does what/,/^Look only/p' "$PREFLIGHT_DIR/SKILL.md" > "$S/r.tail"; names_report "preflight skill" "$S/r.tail"; out=$(watch r)
    assert_match "idle with only the preflight skill's Reviewer lines in the tail is unexplained" "$out" '^attention: r idle-unexplained'
    # Report rounds: after a fix prompt the orchestrator watches <agent>:<n>, and
    # only round n's end line counts; an earlier report's line is still in the tail.
    echo idle > "$S/b"; printf "[[READY TO MERGE]]\nFix finding R-1 in watch-lanes.sh, then report again.\n" > "$S/b.tail"; out=$(watch b:2)
    assert_match "round 2: an old round-1 end line after a fix prompt is unexplained" "$out" '^attention: b idle-unexplained'
    echo idle > "$S/b"; printf "[[READY TO MERGE]]\nFix finding R-1 in watch-lanes.sh, then report again.\n[[READY TO MERGE r2]]\n" > "$S/b.tail"; out=$(watch b:2)
    assert_match "round 2: round 2's end line reads as the report" "$out" '^attention: b idle-after-final-report'
    echo idle > "$S/a"; printf '[[ALL DONE r2]]\n' > "$S/a.tail"; out=$(watch a:3)
    assert_match "round 3: round 2's end line is unexplained" "$out" '^attention: a idle-unexplained'
    echo idle > "$S/a"; printf '[[ALL DONE r30]]\n' > "$S/a.tail"; out=$(watch a:3)
    assert_match "round 3: round 30's end line is unexplained" "$out" '^attention: a idle-unexplained'
    echo idle > "$S/b"; printf '⏺ [[ Ready to merge R2 ]]\n' > "$S/b.tail"; out=$(watch b:2)
    assert_match "round 2: the round tag in another case or with spaces still reads as the report" "$out" '^attention: b idle-after-final-report'
    echo idle > "$S/b"; printf 'end the round with [[READY TO MERGE r2]] once green\n' > "$S/b.tail"; out=$(watch b:2)
    assert_match "round 2: a quoted round-2 end line is not the report" "$out" '^attention: b idle-unexplained'
    echo idle > "$S/b"; printf '[[READY TO MERGE r2]]\n' > "$S/b.tail"; out=$(watch b)
    assert_match "a bare name: an end line with a round tag is unexplained" "$out" '^attention: b idle-unexplained'
    echo idle > "$S/b"; printf '[[READY TO MERGE]]\n' > "$S/b.tail"; out=$(watch b:1)
    assert_match "round 1 named explicitly reads like a bare name" "$out" '^attention: b idle-after-final-report'
    echo idle > "$S/r"; printf '[[FINDINGS WRITTEN r2]] /run/findings/lane-a-2.json\n' > "$S/r.tail"; out=$(watch r:2)
    assert_match "round 2: a Reviewer's findings line is no round-2 end line" "$out" '^attention: r idle-unexplained'
    # Each agent is held to its own round.
    echo idle > "$S/a"; printf '[[ALL DONE r2]]\n' > "$S/a.tail"; echo idle > "$S/b"; printf '[[READY TO MERGE]]\n' > "$S/b.tail"
    out=$(watch a:2 b)
    assert_match "a:2 b: a reads its round-2 end line"  "$out" '^attention: a idle-after-final-report'
    assert_match "a:2 b: b reads its round-1 end line"  "$out" '^attention: b idle-after-final-report'
    out=$(watch a b:2)
    assert_match "a b:2: a's round-2 line is no round-1 end line" "$out" '^attention: a idle-unexplained'
    assert_match "a b:2: b's round-1 line is no round-2 end line" "$out" '^attention: b idle-unexplained'
    reset_stub; echo idle > "$S/b"; printf '[[READY TO MERGE r2]]\n' > "$S/b.tail"; out=$(watch b:2)
    assert_match "round 2: the state table names the bare agent" "$out" '^b +idle$'
    assert_nomatch "round 2: no output names the round suffix" "$out" 'b:2'
    assert_nomatch "round 2: herdr gets the bare name" "$(cat "$HERDR_STUB_LOG")" 'b:2'
    assert_match "round 2: herdr reads the agent by its bare name" "$(cat "$HERDR_STUB_LOG")" '^herdr agent read b '
    for arg in 'a:' 'a:x' 'a:0' 'a:-1' 'a:2:3' ':2'; do
      reset_stub; out=$(watch "$arg")
      assert_match "malformed agent argument $arg: the usage line" "$out" '^usage: watch-lanes\.sh '
      assert_match "malformed agent argument $arg: exit 1" "$out" 'exit=1$'
      assert_nomatch "malformed agent argument $arg: no herdr call" "$(cat "$HERDR_STUB_LOG")" '^herdr '
    done
    echo idle > "$S/a"; printf 'Running tests...\n' > "$S/a.tail"; out=$(watch a)
    assert_match "idle without a report is unexplained" "$out" '^attention: a idle-unexplained'
    echo gone > "$S/a"; out=$(watch a)
    assert_match "gone"                                 "$out" '^attention: a gone'
    # herdr failing for another reason than agent_not_found says nothing about
    # the agent: it reads unreadable, like working, and never settles as gone.
    printf 'unreachable\nworking\n' > "$S/a"; out=$(ROUND=1 watch a)
    assert_nomatch "herdr failing once: no attention"   "$out" '^attention: a '
    assert_match "herdr failing once: quiet"            "$out" 'exit=3$'
    # Only UNREADABLE_POLLS consecutive unreadable polls are attention, never
    # gone; a readable answer in between starts the count again.
    printf 'unreachable\nunreachable\nworking\nunreachable\nunreachable\nblocked\n' > "$S/a"
    out=$(UNREADABLE_POLLS=3 watch a)
    assert_match "herdr failing twice, answering, twice again: the lane's own attention" "$out" '^attention: a blocked$'
    assert_nomatch "herdr failing twice, answering, twice again: not unreadable" "$out" '^attention: a unreadable'
    echo unreachable > "$S/a"; : > "$HERDR_STUB_LOG"; out=$(UNREADABLE_POLLS=3 watch a)
    assert_match "herdr failing UNREADABLE_POLLS times: attention, unreadable" "$out" '^attention: a unreadable$'
    assert_nomatch "herdr failing UNREADABLE_POLLS times: not gone" "$out" '^attention: a gone'
    assert_match "herdr failing UNREADABLE_POLLS times: unreadable in the state table" "$out" '^a +unreadable$'
    assert_match "herdr failing UNREADABLE_POLLS times: exit 0" "$out" 'exit=0$'
    assert_match "herdr failing UNREADABLE_POLLS times: three polls and the resample" "$(grep -c '^herdr agent get a' "$HERDR_STUB_LOG")" '^4$'
    echo unreachable > "$S/a"; out=$(UNREADABLE_POLLS=3 ON=$RUN_COMPLETE watch a)
    assert_match "complete board, herdr failing: attention, unreadable" "$out" '^attention: a unreadable$'
    assert_nomatch "complete board, herdr failing: the run is not complete for it" "$out" '^tower: run'
    echo shapeless > "$S/a"; out=$(UNREADABLE_POLLS=3 watch a)
    assert_match "an answer without a status: unreadable, not settled early" "$out" '^attention: a unreadable$'
    for bad in abc 0 -5 1.5; do
      out=$(UNREADABLE_POLLS=$bad watch a)
      assert_match "UNREADABLE_POLLS=$bad: refused"    "$out" 'UNREADABLE_POLLS'
      assert_match "UNREADABLE_POLLS=$bad: exit 1"     "$out" 'exit=1$'
    done
    echo unreachable > "$S/a"; echo done > "$S/b"; out=$(watch a b)
    assert_match "herdr failing for one lane: the settled one" "$out" '^attention: b done'
    assert_nomatch "herdr failing for one lane: that lane is not gone" "$out" '^attention: a '
    echo working > "$S/a"; echo done > "$S/b"; out=$(watch a b)
    assert_match "two lanes: only the settled one"      "$out" '^attention: b done'
    assert_nomatch "two lanes: the working one is quiet" "$out" '^attention: a '
    assert_match "tower summary when tower is present"  "$out" '^--- tower'
    assert_match "the summary is the run's board"       "$out" "'total': 1, 'pending': 1"
    out=$(TOWER_STUB=absent watch b)
    assert_match "tower not runnable: watch-lanes refuses with the pointer" "$out" 'needs tower.*github\.com/phutschi/tower'
    assert_match "tower not runnable: watch-lanes fails (neither attention nor quiet)" "$out" 'exit=1$'
    # A complete board is not attention while a watched agent still works (the
    # lane's check gate and report come after its last task); a closed run always is.
    echo working > "$S/a"; out=$(ROUND=1 ON=$RUN_COMPLETE watch a)
    assert_match "complete board, lane working: exit 3"  "$out" 'exit=3$'
    assert_nomatch "complete board, lane working: no tower attention" "$out" '^tower: run'
    echo working > "$S/a"; out=$(ROUND=1 ON=$RUN_CLOSED watch a)
    assert_match "closed run, lane working: attention"   "$out" '^tower: run closed'
    assert_match "closed run, lane working: exit 0"      "$out" 'exit=0$'
    printf 'idle\nidle\nworking\n' > "$S/a"; out=$(ROUND=1 ON=$RUN_COMPLETE watch a)
    assert_nomatch "complete board, lane idle for one poll only: no tower attention" "$out" '^tower: run'
    printf 'working\nidle\n' > "$S/a"; printf 'idle\nidle\n' > "$S/b"; out=$(ON=$RUN_COMPLETE watch a b)
    assert_nomatch "complete board, one agent settled, the other idle only once: no tower attention" "$out" '^tower: run'
    echo working > "$S/a"; echo done > "$S/b"; out=$(ROUND=1 ON=$RUN_COMPLETE watch a b)
    assert_nomatch "complete board, one of two lanes working: no tower attention" "$out" '^tower: run'
    printf 'idle\nidle\n' > "$S/a"; out=$(ON=$RUN_COMPLETE watch a)
    assert_match "complete board, every agent settled: attention" "$out" '^tower: run complete'
    # No round limit unless ROUND_SECONDS asks for one: under a clock that jumps
    # 1000 s on every read, the watch still polls until the lane needs attention.
    clock="$TMP/clock"; mkdir -p "$clock"
    cat > "$clock/date" <<'CLOCK'
#!/usr/bin/env bash
[ "$*" = +%s ] || exec /bin/date "$@"
n=$(( $(cat "$0.now" 2>/dev/null || echo 0) + 1000 )); echo "$n" > "$0.now"; echo "$n"
CLOCK
    chmod +x "$clock/date"
    # A background kill caps the run, so a regression fails instead of hanging.
    # The script itself is the background job, so the kill reaches it.
    clocked() { (cd "$TMP" || exit; PATH="$clock:$PATH" GRACE_SECONDS=0 POLL_SECONDS=0 "$KIT/watch-lanes.sh" "$RUN" "${@:-a}" 2>&1 & p=$!
      (sleep 20; kill "$p" 2>/dev/null) >/dev/null 2>&1 & k=$!; wait "$p"; rc=$?; kill "$k" 2>/dev/null; echo "exit=$rc"); }
    printf 'working\nworking\nworking\nblocked\n' > "$S/a"; printf 'need the API key\n' > "$S/a.tail"; rm -f "$clock/date.now"
    out=$(clocked)
    assert_match "no ROUND_SECONDS: polls past 540 s until attention" "$out" '^attention: a blocked'
    assert_match "no ROUND_SECONDS: exit 0"             "$out" 'exit=0$'
    # 1000 s a read: the round starts at 1000, and the first poll's reads land
    # under 2500, the next ones past it.
    echo working > "$S/a"; rm -f "$clock/date.now"; : > "$HERDR_STUB_LOG"
    out=$(ROUND_SECONDS=2500 clocked)
    assert_match "ROUND_SECONDS given: exit 3 once it passes" "$out" 'exit=3$'
    assert_match "ROUND_SECONDS given: it polled before it passed" "$(grep -c '^herdr agent get a' "$HERDR_STUB_LOG")" '^[3-9]'
    # Blocked on one sample and working again on the resample: no time limit
    # means no quiet exit, so the watch polls on and reports once, when the lane
    # is blocked again.
    printf 'blocked\nworking\nworking\nblocked\n' > "$S/a"; rm -f "$clock/date.now"
    out=$(clocked)
    assert_match "blocked, then working on the resample: polls on until attention" "$out" '^attention: a blocked'
    assert_match "blocked, then working on the resample: exit 0" "$out" 'exit=0$'
    assert_match "blocked, then working on the resample: one report" "$(grep -c '^--- tower' <<<"$out")" '^1$'
    # Settled idle, working on the resample: idle counts afresh, so it takes two
    # more idle polls (and the resample) before the watch reports: 6 reads.
    printf 'idle\nidle\nworking\nidle\nidle\n' > "$S/a"; printf 'Running tests...\n' > "$S/a.tail"; rm -f "$clock/date.now"; : > "$HERDR_STUB_LOG"
    out=$(clocked)
    assert_match "idle, then working on the resample: reports idle again" "$out" '^attention: a idle-unexplained'
    assert_match "idle, then working on the resample: idle counts afresh" "$(grep -c '^herdr agent get a' "$HERDR_STUB_LOG")" '^6$'
    # Another lane settling and working again on the resample does not start
    # an unreadable agent's count again, and each resample's failure adds to
    # it: a reaches 4 on its fourth read (two polls, two resamples).
    echo unreachable > "$S/a"; printf 'blocked\nworking\nblocked\nworking\n' > "$S/b"; rm -f "$clock/date.now"; : > "$HERDR_STUB_LOG"
    out=$(UNREADABLE_POLLS=4 clocked a b)
    assert_match "a flapping lane beside a failing herdr: attention, unreadable" "$out" '^attention: a unreadable$'
    assert_match "a flapping lane beside a failing herdr: the count held" "$(grep -c '^herdr agent get a' "$HERDR_STUB_LOG")" '^4$'
    # A resample on which the agent answers is a readable answer too: it starts
    # the count again. a fails on reads 1, 3, 5 and 6 only (never 4 in a row)
    # while b settles and works again on every resample, then is done.
    printf 'unreachable\nworking\nunreachable\nworking\nunreachable\nunreachable\nworking\n' > "$S/a"
    printf 'blocked\nworking\nblocked\nworking\nblocked\nworking\ndone\n' > "$S/b"
    rm -f "$clock/date.now"; : > "$HERDR_STUB_LOG"
    out=$(UNREADABLE_POLLS=4 clocked a b)
    assert_nomatch "a resample that answers starts the count again: no unreadable attention" "$out" '^attention: a unreadable'
    assert_match "a resample that answers starts the count again: the lane that is done" "$out" '^attention: b done$'
    # A status the watch does not know settles the poll; it is attention, never
    # an endless quiet loop.
    echo waiting > "$S/a"; printf 'Choose an option\n' > "$S/a.tail"; rm -f "$clock/date.now"
    out=$(clocked)
    assert_match "an unknown status: attention with the status" "$out" '^attention: a waiting$'
    assert_match "an unknown status: the tail printed" "$out" 'Choose an option'
    assert_match "an unknown status: exit 0" "$out" 'exit=0$'
    # Without a round limit, a herdr that never answers still ends the watch,
    # after the default count of unreadable polls.
    echo unreachable > "$S/a"; rm -f "$clock/date.now"; : > "$HERDR_STUB_LOG"
    out=$(clocked)
    assert_match "no ROUND_SECONDS, herdr never answering: attention, unreadable" "$out" '^attention: a unreadable$'
    assert_match "no ROUND_SECONDS, herdr never answering: exit 0" "$out" 'exit=0$'
    assert_match "no ROUND_SECONDS, herdr never answering: 12 polls and the resample" "$(grep -c '^herdr agent get a' "$HERDR_STUB_LOG")" '^13$'
    # Unreadable up to the limit, working on the resample: it counts afresh, so
    # the next unreadable poll alone settles nothing: 6 reads, not 5.
    printf 'unreachable\nunreachable\nworking\nunreachable\nblocked\n' > "$S/a"; rm -f "$clock/date.now"; : > "$HERDR_STUB_LOG"
    out=$(UNREADABLE_POLLS=2 clocked)
    assert_match "unreadable, then working on the resample: the lane's own attention" "$out" '^attention: a blocked$'
    assert_match "unreadable, then working on the resample: counts afresh" "$(grep -c '^herdr agent get a' "$HERDR_STUB_LOG")" '^6$'
    printf 'blocked\nworking\n' > "$S/a"; rm -f "$clock/date.now"
    out=$(ROUND_SECONDS=2500 clocked)
    assert_match "ROUND_SECONDS given, blocked then working: exit 3 as before" "$out" 'exit=3$'
    for bad in abc 0 -5 1.5; do
      out=$(ROUND_SECONDS=$bad clocked)
      assert_match "ROUND_SECONDS=$bad: refused"       "$out" 'ROUND_SECONDS'
      assert_match "ROUND_SECONDS=$bad: exit 1"        "$out" 'exit=1$'
    done
  fi
fi

# --- watchline ---------------------------------------------------------------
# bootstrap.sh's printed "watch:" line: the run's stale threshold reaches
# tower wait, and watch-lanes.sh runs beside it, whatever the repo.
if section watchline; then
  r=$(fixture_repo contract); reset_stub
  wl=$(cd "$r" && "$KIT/bootstrap.sh" "$TMP/run-wl1" "WL" main 2>&1 | grep '^watch:')
  assert_match "watch line: tower wait takes the run's stale threshold" "$wl" '^watch: +tower wait --stale 45 +and +.*/watch-lanes\.sh '
  r=$(fixture_repo none); reset_stub
  wl=$(cd "$r" && "$KIT/bootstrap.sh" "$TMP/run-wl2" "WL" main 2>&1 | grep '^watch:')
  assert_match "watch line: always tower wait and watch-lanes.sh" "$wl" '^watch: +tower wait --stale 30 +and +.*/watch-lanes\.sh '
  assert_nomatch "watch line: no timeout and no round limit" "$wl" ' --timeout|ROUND_SECONDS'
fi

# --- contract-pin ------------------------------------------------------------
# The repo contract is bash. After bootstrap, add-lane and add-reviewer read it
# as bootstrap did, from a pin no lane can write: not a checkout, not the run
# dir, not the git dir (a codex lane may write all three).
if section contract-pin; then
  r=$(fixture_repo contract); git -C "$r" add -A; git -C "$r" commit -qm contract
  RUNP="$TMP/run-pin"; reset_stub
  (cd "$r" && "$KIT/bootstrap.sh" "$RUNP" "Pin" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
  pin=$(sed -nE 's/^contract: +//p' "$RUNP/panes.txt")
  assert_match "pin: the pane map names the pin, under the user's state dir" "$pin" "^$XDG_STATE_HOME/tower/contracts/[0-9a-f]+$"
  assert_match "pin: the pin holds the contract bootstrap read" "$(cat "$pin" 2>&1)" '^EXECUTOR_MODEL=gpt-6-astra-mini$'
  [ -f "$pin" ] && [ ! -w "$pin" ] && ok "pin: the pin is read-only" || bad "pin: the pin is read-only"
  reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNP" B feat/b main 2 2>&1)
  assert_match "pin: a clean contract reaches add-lane" "$(cat "$RUNP/panes.txt")" '^lane B: .*kind codex, .*model gpt-6-astra-mini, tab lanes\)'
  # A lane rewrites the contract and it lands in the checkout (its commit, a merge).
  printf 'EXECUTOR_MODEL=lane-written\ntouch "%s"\n' "$TMP/pin-ran-lane" >> "$r/.orchestrate"; git -C "$r" commit -qam lane
  reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNP" C feat/c main 3 2>&1)
  assert_match "pin: a lane-modified contract does not reach add-lane" "$(cat "$RUNP/panes.txt")" '^lane C: .*kind codex, .*model gpt-6-astra-mini, tab lanes\)'
  # The run dir is a codex lane's to write: a contract: line there picks nothing.
  [ -e "$TMP/pin-ran-lane" ] && bad "pin: the lane's contract never runs" || ok "pin: the lane's contract never runs"
  printf 'touch "%s"\n' "$TMP/pin-ran-forged" > "$RUNP/forged"; git -C "$r" hash-object -w "$RUNP/forged" > /dev/null
  printf 'contract:       %s\ncontract:       %s\n' "$RUNP/forged" "$(git -C "$r" hash-object "$RUNP/forged")" >> "$RUNP/panes.txt"
  reset_stub; out=$(cd "$r" && EXIT_WAIT_SECONDS=3 "$KIT/add-reviewer.sh" "$RUNP" R1 codex "Lane review B" "$RUNP/findings/b.json" 2>&1)
  assert_match "pin: add-reviewer still starts its Reviewer" "$(cat "$RUNP/panes.txt")" '^reviewer R1: '
  [ -e "$TMP/pin-ran-forged" ] || [ -e "$TMP/pin-ran-lane" ] && bad "pin: neither a forged pane map line nor the lane's contract runs in add-reviewer" || ok "pin: neither a forged pane map line nor the lane's contract runs in add-reviewer"
  # A relative run dir at bootstrap, CDPATH exported: add-lane, given the
  # absolute path, finds the same pin.
  r=$(fixture_repo contract); git -C "$r" add -A; git -C "$r" commit -qm contract; reset_stub
  (cd "$r" && CDPATH=. "$KIT/bootstrap.sh" run-rel "Pin rel" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
  reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$r/run-rel" B feat/b main 2 2>&1)
  assert_match "pin: a relative run dir at bootstrap has the pin add-lane finds" "$(cat "$r/run-rel/panes.txt")" '^lane B: .*kind codex, .*model gpt-6-astra-mini, tab lanes\)'
  # No contract at bootstrap: one a lane adds later is not read either.
  r=$(fixture_repo bun-vitest); RUNP="$TMP/run-pin-none"; reset_stub
  (cd "$r" && "$KIT/bootstrap.sh" "$RUNP" "Pin none" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
  printf 'EXECUTOR_KIND=codex\ntouch "%s"\n' "$TMP/pin-ran-added" > "$r/.orchestrate"; git -C "$r" add .orchestrate; git -C "$r" commit -qm lane
  reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNP" B feat/b main 2 2>&1)
  assert_match "pin: a contract added by a lane does not reach add-lane" "$(cat "$RUNP/panes.txt")" '^lane B: .*kind claude, '
  [ -e "$TMP/pin-ran-added" ] && bad "pin: ... and never runs" || ok "pin: ... and never runs"
  # No pin (a run an older kit opened, or a pin removed): refused, not the checkout.
  rm -f "$(sed -nE 's/^contract: +//p' "$RUNP/panes.txt" | head -1)"
  out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNP" C feat/c main 3 2>&1; echo "exit=$?")
  assert_match "pin: a run without its pin is refused" "$out" "no pinned contract for the run $RUNP"
  assert_match "pin: ... as an error"                    "$out" 'exit=1$'
  [ -e "$TMP/pin-ran-added" ] && bad "pin: ... and the checkout's contract does not run" || ok "pin: ... and the checkout's contract does not run"
fi

# --- credits -----------------------------------------------------------------
# credits_left KIND: % left in the kind's tightest window, or nothing. The
# keychain and the endpoints are fakes on PATH: `security` answers from
# $CB/keychain/<service> (no file: the item is missing), `curl` answers from
# $CB/reply only when the header lines it reads on stdin carry the fake token
# (and, for claude's endpoint, the OAuth beta header), prints nothing and fails
# as `curl -f` does otherwise, and logs its argv to $CB/curl.log.
if section credits; then
  CB="$TMP/credits"; mkdir -p "$CB/bin" "$CB/keychain"
  TOK=tok-fake-rex-0001
  cat > "$CB/bin/security" <<SH
#!/bin/sh
while [ \$# -gt 0 ]; do [ "\$1" = -s ] && svc=\$2; shift; done
[ -f "$CB/keychain/\$svc" ] || { echo "security: The specified item could not be found in the keychain." >&2; exit 44; }
cat "$CB/keychain/\$svc"
SH
  cat > "$CB/bin/curl" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$CB/curl.log"
[ -n "\${FAKE_CURL_SLEEP:-}" ] && sleep "\$FAKE_CURL_SLEEP"
h=\$(cat)
case "\$h" in
  *"Authorization: Bearer $TOK"*) ;;
  *) exit 22 ;;
esac
case "\$*" in
  *oauth/usage*)
    case "\$h" in
      *"anthropic-beta: oauth-2025-04-20"*) ;;
      *) exit 22 ;;
    esac ;;
esac
[ "\${FAKE_CURL_STATUS:-200}" = 200 ] || exit 22
cat "$CB/reply"
SH
  chmod +x "$CB/bin/security" "$CB/bin/curl"
  credits() { CREDITS_FAKES="$CB/bin" in_kit ". \"\$KIT/credits.sh\"; credits_left $1"; }  # KIND
  claude_creds() { printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"ref-fake-rex"}}' "$TOK" > "$CB/keychain/Claude Code-credentials"; }

  claude_creds
  echo '{"five_hour":{"utilization":31,"resets_at":null},"seven_day":{"utilization":85,"resets_at":null}}' > "$CB/reply"
  assert_eq "claude: the tightest of the 5-hour and 7-day windows" "$(credits claude)" 15
  assert_match "claude: ... asked with curl -f, so an error status fails" "$(tail -1 "$CB/curl.log")" '^-sf '
  assert_eq "claude: a 401 prints nothing" "$(FAKE_CURL_STATUS=401 credits claude)" ""
  assert_eq "claude: with CLAUDE_CONFIG_DIR, another account's item, nothing" "$(CLAUDE_CONFIG_DIR="$TMP/claude-other" credits claude)" ""
  rm "$CB/keychain/Claude Code-credentials"
  assert_eq "claude: a missing keychain item prints nothing" "$(credits claude)" ""

  printf '%s' "$TOK" > "$CB/keychain/cursor-access-token"
  echo '{"billingCycleStart":"1","planUsage":{"totalPercentUsed":93}}' > "$CB/reply"
  assert_eq "cursor: 100 - planUsage.totalPercentUsed" "$(credits cursor)" 7
  assert_match "cursor: ... from DashboardService/GetCurrentPeriodUsage" "$(tail -1 "$CB/curl.log")" 'DashboardService/GetCurrentPeriodUsage'
  echo '{"planUsage":{"totalPercentUsed":' > "$CB/reply"
  assert_eq "cursor: malformed JSON prints nothing" "$(credits cursor)" ""

  # codex: the stub's app-server answers account/rateLimits/read with the
  # result in $CODEX_STUB_RATE_LIMITS, errors without it, answers with a
  # JSON-RPC error when it is `error`, and never answers when it is `silent`.
  echo '{"rateLimits":{"primary":{"usedPercent":80,"windowDurationMins":300},"secondary":null}}' > "$CB/codex-limits"
  assert_eq "codex: primary only" "$(CODEX_STUB_RATE_LIMITS="$CB/codex-limits" credits codex)" 20
  echo '{"rateLimits":{"primary":{"usedPercent":10},"secondary":{"usedPercent":60}}}' > "$CB/codex-limits"
  reset_stub
  assert_eq "codex: the tightest of primary and secondary" "$(CODEX_STUB_RATE_LIMITS="$CB/codex-limits" credits codex)" 40
  assert_match "codex: ... read from codex app-server" "$(cat "$HERDR_STUB_LOG")" '^codex app-server$'
  assert_eq "codex: an app-server that errors prints nothing" "$(credits codex)" ""
  assert_eq "codex: a JSON-RPC error reply prints nothing" "$(CODEX_STUB_RATE_LIMITS=error credits codex)" ""
  SECONDS=0
  assert_eq "codex: an app-server that never answers prints nothing" "$(CREDITS_TIMEOUT=1 CODEX_STUB_RATE_LIMITS=silent credits codex)" ""
  [ "$SECONDS" -le 4 ] && ok "codex: ... within about the timeout" || bad "codex: ... within about the timeout" "took ${SECONDS}s"
  pgrep -f 'sleep 31.7' >/dev/null && bad "codex: ... and leaves no app-server behind" || ok "codex: ... and leaves no app-server behind"

  claude_creds
  echo '{"five_hour":{"utilization":31},"seven_day":{"utilization":85}}' > "$CB/reply"
  SECONDS=0
  assert_eq "a probe slower than its timeout prints nothing" "$(CREDITS_TIMEOUT=1 FAKE_CURL_SLEEP=8.3 credits claude)" ""
  [ "$SECONDS" -le 4 ] && ok "... and returns within about the timeout" || bad "... and returns within about the timeout" "took ${SECONDS}s"
  pgrep -f 'sleep 8.3' >/dev/null && bad "... and leaves nothing it started behind" || ok "... and leaves nothing it started behind"
  # A timeout set in the caller's shell, not exported, is the probe's too;
  # and the module, sourced by a relative path, still probes after a cd.
  assert_eq "a caller's CREDITS_TIMEOUT holds for the whole probe" \
    "$(CREDITS_FAKES="$CB/bin" in_kit "CREDITS_TIMEOUT=6; . \"\$KIT/credits.sh\"; FAKE_CURL_SLEEP=3 credits_left claude")" 15
  assert_eq "a module sourced by a relative path probes after a cd" \
    "$(cd "$KIT" && CREDITS_FAKES="$CB/bin" in_kit ". ./credits.sh; cd /; credits_left claude")" 15
  assert_eq "an unknown kind prints nothing" "$(credits gemini)" ""
  assert_eq "no kind prints nothing" "$(credits '')" ""

  # The token only ever reaches curl through a pipe.
  : > "$CB/curl.log"; reset_stub
  out=$(credits claude; FAKE_CURL_STATUS=401 credits claude; credits cursor; credits codex)
  assert_match "token: the probes ran" "$(cat "$CB/curl.log")" 'oauth/usage'
  assert_nomatch "token: never on stdout or stderr" "$out" "$TOK"
  assert_nomatch "token: never in curl's argv" "$(cat "$CB/curl.log")" "$TOK"
  assert_nomatch "token: never in HERDR_STUB_LOG" "$(cat "$HERDR_STUB_LOG")" "$TOK"
fi

# --- brief-cursor ------------------------------------------------------------
# The markdown a cursor lane, its orchestrator and a lone preflight read.
if section brief-cursor; then
  bt=$(cat "$KIT/brief-template.md"); os=$(cat "$KIT/SKILL.md"); ps=$(cat "$PREFLIGHT_DIR/SKILL.md")
  assert_match "brief: the per-kind table has a cursor column" "$bt" '^\| +\| claude lane +\| codex lane +\| cursor lane +\|'
  method=$(grep '^METHOD:' "$KIT/brief-template.md")
  assert_match "brief: METHOD has a cursor variant with subagent reviews on the run's models" "$method" 'cursor: "a spec-compliance review subagent \(model \{\{SPEC_REVIEWER_MODEL\}\}\) and a code-quality review subagent \(model \{\{QUALITY_REVIEWER_MODEL\}\}\).*Pass the model explicitly on every dispatch'
  assert_match "brief: a cursor lane loads tdd from its own skill dirs" "$bt" 'own skill dirs: ~/\.agents/skills'
  assert_match "preflight: alone on cursor, one subagent per area in parallel" "$ps" 'Alone on cursor: one subagent per area, in parallel'
  assert_match "orchestrate: EXECUTOR_KIND names cursor" "$os" 'EXECUTOR_KIND=codex` or `EXECUTOR_KIND=cursor`'
  assert_match "orchestrate: REVIEWER_KIND takes cursor" "$os" '^\| `REVIEWER_KIND` +\| other +\| .*claude, codex or cursor: that kind reviews every lane'
  assert_match "orchestrate: the switches table has REVIEWER_BY_CREDITS" "$os" '^\| `REVIEWER_BY_CREDITS` +\| off +\|'
  assert_match "orchestrate: the Reviewer order covers cursor" "$os" 'cursor lane: claude, then codex'
  assert_match "orchestrate: red flag, cursor has subagents" "$os" '^\| Briefing a cursor lane .*subagents'
  assert_match "orchestrate: red flag, never answer cursor's trust box" "$os" "^\\| Answering a cursor lane's trust box .*--trust"
  assert_nomatch "brief: the cursor variant names no claude model" "$(printf '%s\n' "$method" | sed -n 's/.*cursor: "\([^"]*\)".*/\1/p')" 'sonnet|opus'
  assert_nomatch "orchestrate: a cursor lane is never sent to the run's roles alone" "$os" "cursor.*run's reviewer models|run's .spec-reviewer. and .quality-reviewer. models"
  assert_nomatch "no two-kind wording is left in the three files" "$bt$os$ps" 'both kinds|either kind|claude or codex|one Reviewer of each kind'
  # The command the template gives for a cursor lane's reviewer models in a
  # run of another kind, run as written: every layer, the environment first.
  cmd=$(sed -n 's/^    \(bash -c .*kind_default SPEC_REVIEWER_MODEL cursor.*\)$/\1/p' "$KIT/brief-template.md")
  assert_match "brief: the template gives the command" "$cmd" 'kind_default QUALITY_REVIEWER_MODEL cursor'
  assert_match "brief: ... with _ as bash's \$0, the kit and run dir as \$1 and \$2" "$cmd" "' _ \"<kit>\" \"<run-dir>\"\$"
  assert_nomatch "brief: ... never the kit as \$0" "$cmd" '"\$0/'
  assert_match "brief: says what EXECUTOR_KIND=claude does" "$(tr '\n' ' ' < "$KIT/brief-template.md")" 'EXECUTOR_KIND=claude. resolves [^)]*EXECUTOR_MODEL_CLAUDE[^)]*off stderr'
  # cursor_run CHECKOUT RUN_DIR XDG [VAR=value]: runs the command; its stdout
  # and stderr land in $CM.out and $CM.err, and it prints the exit status.
  CM="$TMP/cursor-models"
  cursor_run() { (cd "$1" && env XDG_CONFIG_HOME="$3" ${4:+"$4"} bash -c "$(printf '%s' "$cmd" | sed "s#<kit>#$KIT#g; s#<run-dir>#$2#g")") >"$CM.out" 2>"$CM.err"; echo $?; }
  # cursor_models …: the same, its stdout's lines joined by a space.
  cursor_models() { cursor_run "$@" >/dev/null; paste -sd' ' - < "$CM.out"; }
  kit_spec=$(sed -n 's/^SPEC_REVIEWER_MODEL_CURSOR=//p' "$KIT/model-defaults"); kit_quality=$(sed -n 's/^QUALITY_REVIEWER_MODEL_CURSOR=//p' "$KIT/model-defaults")
  r=$(fixture_repo bun-vitest); RB="$TMP/run-brief-cursor"; reset_stub
  (cd "$r" && XDG_CONFIG_HOME="$TMP/xdg-brief-none" "$KIT/bootstrap.sh" "$RB" "Brief cursor" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
  assert_eq "brief: in a claude run, cursor's reviewer models are the kit's" "$(cursor_models "$r" "$RB" "$TMP/xdg-brief-none")" "$kit_spec $kit_quality"
  assert_eq "brief: ... exit 0" "$(cursor_run "$r" "$RB" "$TMP/xdg-brief-none")" 0
  assert_eq "brief: ... the two alone on stdout, one per line" "$(cat "$CM.out")" "$kit_spec
$kit_quality"
  assert_eq "brief: ... nothing on stderr" "$(cat "$CM.err")" ""
  grep -v '^SPEC_REVIEWER_MODEL_CURSOR=' "$KIT/model-defaults" > "$TMP/model-defaults-no-spec"
  assert_eq "brief: ... a missing SPEC model fails the command" "$(cursor_run "$r" "$RB" "$TMP/xdg-brief-none" MODEL_DEFAULTS_FILE="$TMP/model-defaults-no-spec")" 1
  assert_match "brief: ... SPEC named on stderr" "$(cat "$CM.err")" 'no SPEC_REVIEWER_MODEL_CURSOR'
  assert_eq "brief: ... and nothing on stdout" "$(cat "$CM.out")" ""
  grep -v '^QUALITY_REVIEWER_MODEL_CURSOR=' "$KIT/model-defaults" > "$TMP/model-defaults-no-quality"
  assert_eq "brief: ... a missing QUALITY model fails the command" "$(cursor_run "$r" "$RB" "$TMP/xdg-brief-none" MODEL_DEFAULTS_FILE="$TMP/model-defaults-no-quality")" 1
  assert_match "brief: ... QUALITY named on stderr" "$(cat "$CM.err")" 'no QUALITY_REVIEWER_MODEL_CURSOR'
  assert_eq "brief: ... stdout only the SPEC model, never the two" "$(cat "$CM.out")" "$kit_spec"
  # A contract's note goes to stderr: stdout stays the two.
  mkdir -p "$TMP/xdg-brief-note/tower"; echo MODLE=x > "$TMP/xdg-brief-note/tower/orchestrate"
  assert_eq "brief: ... with a contract's note, still exit 0" "$(cursor_run "$r" "$RB" "$TMP/xdg-brief-note")" 0
  assert_match "brief: ... the note on stderr" "$(cat "$CM.err")" "'MODLE' is not a setting"
  assert_eq "brief: ... stdout still the two alone" "$(cat "$CM.out")" "$kit_spec
$kit_quality"
  assert_match "brief: the template says stdout is the two, notes on stderr" "$(tr '\n' ' ' < "$KIT/brief-template.md")" 'Its stdout is the two lines, in that order[^.]*\. [^.]*note[^.]*stderr'
  UCB="$TMP/xdg-brief"; mkdir -p "$UCB/tower"
  printf 'SPEC_REVIEWER_MODEL_CURSOR=user-s\nQUALITY_REVIEWER_MODEL_CURSOR=user-q\n' > "$UCB/tower/orchestrate"
  r=$(fixture_repo bun-vitest); RB="$TMP/run-brief-cursor-2"
  echo 'QUALITY_REVIEWER_MODEL_CURSOR=repo-q' > "$r/.orchestrate"; git -C "$r" add .orchestrate; git -C "$r" commit -qm contract; reset_stub
  (cd "$r" && XDG_CONFIG_HOME="$UCB" "$KIT/bootstrap.sh" "$RB" "Brief cursor 2" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
  echo 'QUALITY_REVIEWER_MODEL_CURSOR=checkout-q' > "$r/.orchestrate"   # after bootstrap: the pin, never the checkout
  assert_eq "brief: ... the user contract over the kit, the repo contract over both" "$(cursor_models "$r" "$RB" "$UCB")" "user-s repo-q"
  assert_eq "brief: ... and the environment over all" "$(cursor_models "$r" "$RB" "$UCB" SPEC_REVIEWER_MODEL_CURSOR=env-s)" "env-s repo-q"
  mkdir -p "$TMP/home-no-skills"
  assert_eq "brief: ... printing only the two, whatever kind add-lane.sh was given" \
    "$(HOME="$TMP/home-no-skills" cursor_models "$r" "$RB" "$UCB" EXECUTOR_KIND=cursor)" "user-s repo-q"
  assert_eq "brief: ... and no setup hint on stderr" "$(cat "$CM.err")" ""
  for m in $(sed -n 's/^[A-Z_]*_CURSOR=//p' "$KIT/model-defaults" | sort -u); do
    case "$bt$os$ps" in
      *"$m"*) bad "no cursor default ($m) is written into the three files" ;;
      *) ok "no cursor default ($m) is written into the three files" ;;
    esac
  done
fi

# --- look --------------------------------------------------------------------
if section look; then
  # A harmless check gate for the fixtures without suite lines or scripts, so
  # the suite part of the look is green unless a test says otherwise.
  export CHECK_CMD=true
  # No install in look's temp worktree unless a test asks for one (set, even
  # empty, INSTALL_CMD wins over the package manager's).
  export INSTALL_CMD=
  # look makes its temp worktree under $XDG_STATE_HOME/tower/look and refuses
  # one under /tmp, TMPDIR or the checkout: this run's state dir is under $TMP,
  # so look gets one of its own here ($LOOK_STATE, above).
  SAVED_XDG_STATE_HOME=$XDG_STATE_HOME
  export XDG_STATE_HOME="$LOOK_STATE/xdg"; mkdir -p "$XDG_STATE_HOME"
  LOOK_ROOT="$(cd "$XDG_STATE_HOME" && pwd -P)/tower/look"
  # Settings the caller's shell may carry; the fixtures decide them here.
  unset STATIC_BASELINE SUITE_SKIP PR METHOD REVIEWER_KIND TYPECHECK_TASK PM
  # A fixture repo on a branch: tag base, then one commit that changes app.js,
  # adds new.py and deletes old.txt; kept.txt is untouched.
  look_repo() {  # FIXTURE NAME
    local r="$TMP/repos/look-$2"
    mkdir -p "$r"; [ -d "$KIT/tests/fixtures/$1" ] && cp -R "$KIT/tests/fixtures/$1/." "$r/"
    git -C "$r" init -q
    printf 'x\n' > "$r/kept.txt"; printf 'x\n' > "$r/old.txt"; printf 'a\n' > "$r/app.js"
    git -C "$r" add -A && git -C "$r" commit -qm base && git -C "$r" tag base
    git -C "$r" checkout -qb feat
    printf 'b\n' >> "$r/app.js"; printf 'y\n' > "$r/new.py"; git -C "$r" rm -q old.txt
    git -C "$r" add -A && git -C "$r" commit -qm change
    echo "$r"
  }
  commit_contract() { git -C "$1" add .orchestrate && git -C "$1" commit -qm contract; }  # look reads only a committed one
  # One line per finding in a look.json: "area severity file:line title | evidence".
  findings() { python3 -c "import json,sys
for f in json.load(open(sys.argv[1]))['findings']: print('%s %s %s:%s %s | %s' % (f['area'], f['severity'], f['file'], f['line'], f['title'], f['evidence']))" "$1"; }
  # One line per verdict row: "step status note[ | detail]".
  verdict() { python3 -c "import json,sys
for v in json.load(open(sys.argv[1]))['verdict']: print('%s %s %s' % (v['step'], v['status'], v['note']) + (' | ' + v['detail'] if 'detail' in v else ''))" "$1"; }
  look() { (cd "$1" && shift && "$PREFLIGHT_DIR/look.sh" "$@" 2>&1; echo "exit=$?"); }
  r=$(look_repo none plain); F="$TMP/findings-look"; reset_stub
  out=$(look "$r" base "$F"); log=$(cat "$HERDR_STUB_LOG")
  assert_match "look: semgrep scans the changed files"   "$log" '^semgrep scan .* app\.js new\.py$'
  assert_nomatch "look: an untouched file is not scanned" "$log" '^semgrep .*kept\.txt'
  assert_nomatch "look: a deleted file is not scanned"   "$log" '^semgrep .*old\.txt'
  assert_match "look: semgrep runs its default rules"    "$log" '^semgrep scan --config p/default '
  assert_match "look: semgrep reports only results new since the merge base" "$log" "^semgrep scan .* --baseline-commit $(git -C "$r" rev-parse base) "
  assert_nomatch "look: no .semgrep/, no repo rules"     "$log" '--config \.semgrep'
  assert_match "look: gitleaks scans the branch's commits since the base" "$log" "^gitleaks git --log-opts=$(git -C "$r" rev-parse base)\\.\\.HEAD "
  # No node on the machine (a node that cannot run answers 127, like a missing
  # one), a contract of suite lines only: detect-stack.sh must not end look.sh.
  NB="$TMP/no-node"; mkdir -p "$NB"; printf '#!/bin/sh\nexit 127\n' > "$NB/node"; chmod +x "$NB/node"
  r=$(look_repo none no-node); printf 'suite ok "true"\n' > "$r/.orchestrate"; commit_contract "$r"; reset_stub
  out=$(PATH="$NB:$PATH" look "$r" base "$TMP/findings-no-node")
  assert_match "look: no node and only suite lines, exit 0" "$out" 'exit=0$'
  assert_match "look: no node and only suite lines, the suite step runs" "$(verdict "$TMP/findings-no-node/look.json" 2>&1)" '^ok pass'
  # The contract is bash that look runs: only as committed, which a Reviewer
  # sees in the diff. Untracked, or changed since HEAD, it is refused unrun.
  mark="$TMP/look-contract-ran"
  r=$(look_repo none contract-untracked); printf 'touch "%s"\n' "$mark" > "$r/.orchestrate"; rm -f "$mark"
  out=$(look "$r" base "$TMP/findings-contract")
  assert_match "look: an untracked contract is a setup error" "$out" 'exit=2$'
  assert_match "look: ... naming the file" "$out" 'look: \.orchestrate is not committed as it is in HEAD'
  [ -e "$mark" ] && bad "look: ... and it is not run" || ok "look: ... and it is not run"
  assert_eq "look: ... and no look.json" "$([ -e "$TMP/findings-contract/look.json" ] && echo yes || echo no)" no
  rm -f "$mark"; r=$(look_repo none contract-old-name); printf 'touch "%s"\n' "$mark" > "$r/.herdr-orchestrate"
  out=$(look "$r" base "$TMP/findings-contract")
  assert_match "look: an untracked contract under the old name: refused" "$out" 'exit=2$'
  assert_match "look: ... naming it" "$out" 'look: \.herdr-orchestrate is not committed as it is in HEAD'
  [ -e "$mark" ] && bad "look: ... and not run" || ok "look: ... and not run"
  rm -f "$mark"; r=$(look_repo none contract-modified); printf 'true\n' > "$r/.orchestrate"
  git -C "$r" add .orchestrate; git -C "$r" commit -qm contract
  printf 'touch "%s"\n' "$mark" >> "$r/.orchestrate"
  out=$(look "$r" base "$TMP/findings-contract")
  assert_match "look: a modified contract is a setup error" "$out" 'exit=2$'
  assert_match "look: ... naming it" "$out" 'look: .*\.orchestrate'
  [ -e "$mark" ] && bad "look: ... and it is not run" || ok "look: ... and it is not run"
  rm -f "$mark"; git -C "$r" update-index --assume-unchanged .orchestrate   # hidden from git status and diff
  out=$(look "$r" base "$TMP/findings-contract")
  assert_match "look: a modified contract git is told to ignore: refused" "$out" 'exit=2$'
  assert_match "look: ... naming it" "$out" 'look: \.orchestrate is not committed as it is in HEAD'
  [ -e "$mark" ] && bad "look: ... and not run" || ok "look: ... and not run"
  rm -f "$mark"; r=$(look_repo none contract-symlink); printf 'touch "%s"\n' "$mark" > "$r/contract.sh"
  ln -s contract.sh "$r/.orchestrate"; git -C "$r" add contract.sh .orchestrate; git -C "$r" commit -qm contract
  out=$(look "$r" base "$TMP/findings-contract")
  assert_match "look: a committed symlink contract: refused" "$out" 'exit=2$'
  assert_match "look: ... saying it is a symlink" "$out" 'look: \.orchestrate is a symlink'
  [ -e "$mark" ] && bad "look: ... and what it points at is not run" || ok "look: ... and what it points at is not run"
  # look runs HEAD, not the live checkout: a fresh detached worktree of HEAD
  # in a temp dir, removed afterwards, on success and on failure. What the
  # checkout holds beyond HEAD (untracked files, index bits, dirty kit files)
  # does not reach the look.
  LT="$TMP/look-tmp"; mkdir -p "$LT"; LTP=$(cd "$LT" && pwd -P)
  tree_gone() {  # REPO: look's temp worktree, its dir and its temp files are gone
    [ -z "$(ls -A "$LT")" ] && [ -z "$(ls -A "$LOOK_ROOT" 2>/dev/null)" ] \
      && [ "$(git -C "$1" worktree list | wc -l | tr -d ' ')" = 1 ] && echo gone || echo left
  }
  rm -f "$mark"; r=$(look_repo none tree-untracked-test)
  printf '%s\n' "suite t 'for f in *.test.sh; do bash \"\$f\" || exit 1; done'" > "$r/.orchestrate"
  printf 'true\n' > "$r/ok.test.sh"; git -C "$r" add -A; git -C "$r" commit -qm tests
  printf 'touch "%s"; exit 1\n' "$mark" > "$r/evil.test.sh"
  out=$(TMPDIR="$LT" look "$r" base "$TMP/findings-tree")
  assert_match "look: an untracked test file in the checkout: not in the suite, green" "$out" 'exit=0$'
  [ -e "$mark" ] && bad "look: ... and it is not run" || ok "look: ... and it is not run"
  assert_eq "look: ... the temp worktree is gone after a green look" "$(tree_gone "$r")" gone
  # The kit inside the checkout under review (tower reviewing itself): HEAD's.
  kit_repo() {  # NAME
    local r; r=$(look_repo none "$1"); mkdir -p "$r/skills"
    cp -R "$PREFLIGHT_DIR" "$KIT" "$r/skills/"; rm -rf "$r/skills/orchestrate/tests/fixtures"
    git -C "$r" add -A && git -C "$r" commit -qm kit; echo "$r"
  }
  kit_look() { (cd "$1" && TMPDIR="$LT" "$1/skills/preflight/look.sh" base "$TMP/findings-tree" 2>&1; echo "exit=$?"); }
  rm -f "$mark"; r=$(kit_repo tree-dirty-common); printf 'touch "%s"\n' "$mark" >> "$r/skills/orchestrate/common.sh"
  out=$(kit_look "$r")
  assert_match "look: a dirty common.sh: refused as a dirty tree" "$out" 'uncommitted changes to tracked files: skills/orchestrate/common\.sh'
  assert_match "look: ... a setup error" "$out" 'exit=2$'
  [ -e "$mark" ] && bad "look: ... and the dirty common.sh is not run" || ok "look: ... and the dirty common.sh is not run"
  rm -f "$mark"; r=$(kit_repo tree-skip-worktree); git -C "$r" update-index --skip-worktree skills/orchestrate/detect-stack.sh
  printf 'touch "%s"\n' "$mark" >> "$r/skills/orchestrate/detect-stack.sh"
  out=$(kit_look "$r")
  assert_match "look: a skip-worktree detect-stack.sh with an edit: the look runs HEAD's, green" "$out" 'exit=0$'
  [ -e "$mark" ] && bad "look: ... and the edit is not run" || ok "look: ... and the edit is not run"
  assert_eq "look: ... the temp worktree is gone" "$(tree_gone "$r")" gone
  # The install runs in the temp worktree (INSTALL_CMD, else the package
  # manager's); one that fails is a setup error, and the worktree still goes.
  r=$(look_repo none tree-install); rm -f "$TMP/install-where"
  out=$(TMPDIR="$LT" INSTALL_CMD='pwd -P > "$INSTALL_WHERE"' INSTALL_WHERE="$TMP/install-where" look "$r" base "$TMP/findings-tree")
  assert_match "look: the install runs in the temp worktree, under look's own dir" "$(cat "$TMP/install-where" 2>/dev/null)" "^$LOOK_ROOT/look\.[^/]*/tree$"
  assert_match "look: ... and the look goes on" "$out" 'exit=0$'
  out=$(TMPDIR="$LT" INSTALL_CMD='echo "no lockfile" >&2; exit 4' look "$r" base "$TMP/findings-tree")
  assert_match "look: a failed install is a setup error" "$out" 'exit=2$'
  assert_match "look: ... saying so, with its output" "$out" 'look: the install failed \(exit 4\): .*no lockfile'
  assert_eq "look: ... no look.json" "$([ -e "$TMP/findings-tree/look.json" ] && echo yes || echo no)" no
  assert_eq "look: ... the temp worktree is gone after a setup error" "$(tree_gone "$r")" gone
  r=$(look_repo none tree-red); printf '%s\n' "suite red 'exit 1'" > "$r/.orchestrate"; commit_contract "$r"
  out=$(TMPDIR="$LT" look "$r" base "$TMP/findings-tree")
  assert_match "look: a red suite" "$out" 'exit=1$'
  assert_eq "look: ... the temp worktree is gone after a red look" "$(tree_gone "$r")" gone
  # What the suite changes, it changes in the temp worktree: a should-fix
  # finding names it, and the checkout is untouched.
  r=$(look_repo none tree-suite-writes); printf '%s\n' "suite writes 'echo z >> app.js; echo n > left.txt'" > "$r/.orchestrate"; commit_contract "$r"
  out=$(TMPDIR="$LT" look "$r" base "$TMP/findings-tree"); f=$(findings "$TMP/findings-tree/look.json")
  assert_match "look: tracked files the suite changed: a should-fix suite finding" "$f" '^suite should-fix \.:None the suite changed tracked files \| changed: app\.js; new, untracked: left\.txt$'
  assert_match "look: ... not a failure" "$out" 'exit=0$'
  assert_eq "look: ... the checkout untouched" "$(git -C "$r" status --porcelain)" ""
  r=$(look_repo none tree-suite-leaves); printf '%s\n' "suite leaves 'echo n > left.txt'" > "$r/.orchestrate"; commit_contract "$r"
  out=$(TMPDIR="$LT" look "$r" base "$TMP/findings-tree"); f=$(findings "$TMP/findings-tree/look.json")
  assert_match "look: only new untracked files: named in the same finding" "$f" '^suite should-fix \.:None the suite left untracked files \| new, untracked: left\.txt$'
  assert_eq "look: ... none in the checkout" "$([ -e "$r/left.txt" ] && echo yes || echo no)" no
  # The checkout's git hooks do not run when look adds its worktree.
  rm -f "$mark"; r=$(look_repo none tree-hook)
  printf '#!/bin/sh\ntouch "%s"\n' "$mark" > "$r/.git/hooks/post-checkout"; chmod +x "$r/.git/hooks/post-checkout"
  out=$(TMPDIR="$LT" look "$r" base "$TMP/findings-tree")
  assert_match "look: a post-checkout hook in the checkout: green" "$out" 'exit=0$'
  [ -e "$mark" ] && bad "look: ... and the hook does not run" || ok "look: ... and the hook does not run"
  r=$(look_repo none tree-no-tmp)
  out=$(TMPDIR="$TMP/no-such-tmp" look "$r" base "$TMP/findings-tree")
  assert_match "look: a TMPDIR that does not exist: look does not need one" "$out" 'exit=0$'
  # Every file look reads its verdict from is in its own dir, beside the
  # worktree, where no lane may write: a lane-writable TMPDIR cannot touch it.
  r=$(look_repo none tree-verdict-files)
  printf '%s\n' "suite where 'test -f ../verdict.tsv && test -f ../findings.jsonl'" "suite red 'exit 1'" \
    "suite sabotage 'ls -A \"\$TMPDIR\" > \"\$TMPDIR_SEEN\"; for f in \"\$TMPDIR\"/*/verdict.tsv \"\$TMPDIR\"/*/findings.jsonl; do [ ! -e \"\$f\" ] || ln -sf /dev/null \"\$f\"; done'" > "$r/.orchestrate"
  commit_contract "$r"
  out=$(TMPDIR="$LT" TMPDIR_SEEN="$TMP/tmpdir-seen" look "$r" base "$TMP/findings-tree"); v=$(verdict "$TMP/findings-tree/look.json")
  assert_match "look: the verdict files are in look's own dir, beside the worktree" "$v" '^where pass '
  assert_eq "look: ... nothing of look's in TMPDIR" "$(cat "$TMP/tmpdir-seen")" ""
  assert_match "look: ... a red step still fails the look" "$out" 'exit=1$'
  assert_match "look: ... and is in look.json" "$v" '^red fail exit 1'
  # bash 3.2 (macOS) writes a here-doc or here-string to a temp file in TMPDIR
  # and reads it back: look.sh has none, its verdict code is look.py beside it.
  assert_eq "look: look.sh has no here-doc or here-string" "$(grep -c '<<' "$PREFLIGHT_DIR/look.sh")" 0
  [ -f "$PREFLIGHT_DIR/look.py" ] && ok "look: ... its verdict code is look.py, beside it" || bad "look: ... its verdict code is look.py, beside it"
  # Suite changes are read by content: a file the install already changed,
  # and a file in a directory the install left, still count.
  r=$(look_repo none tree-install-then-suite)
  printf '%s\n' "suite writes 'echo z >> app.js; echo n > cache/new.txt'" > "$r/.orchestrate"; commit_contract "$r"
  out=$(TMPDIR="$LT" INSTALL_CMD='echo i >> app.js; mkdir cache; echo o > cache/old.txt' look "$r" base "$TMP/findings-tree"); f=$(findings "$TMP/findings-tree/look.json")
  assert_match "look: a file the install changed, changed again by the suite, and one added in the install's dir: named" "$f" '^suite should-fix \.:None the suite changed tracked files \| changed: app\.js; new, untracked: cache/new\.txt$'
  # Submodules are initialised in look's worktree, as they are in a checkout.
  sub="$TMP/repos/look-submodule-src"; mkdir -p "$sub"; git -C "$sub" init -q
  printf 'in the submodule\n' > "$sub/lib.txt"; git -C "$sub" add -A; git -C "$sub" commit -qm lib
  r=$(look_repo none tree-submodule)
  git -C "$r" -c protocol.file.allow=always submodule --quiet add "$sub" lib
  printf '%s\n' "suite sub 'grep -q \"in the submodule\" lib/lib.txt'" > "$r/.orchestrate"; git -C "$r" add -A; git -C "$r" commit -qm sub
  out=$(TMPDIR="$LT" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always look "$r" base "$TMP/findings-tree")
  assert_match "look: a submodule is there for the suite" "$(verdict "$TMP/findings-tree/look.json" 2>&1)" '^sub pass '
  assert_eq "look: ... the temp worktree is gone" "$(tree_gone "$r")" gone
  rm -f "$mark"
  # A state dir reached through a symlink (macOS: /var -> /private/var): the
  # suite sees one real path, the resolved one.
  ln -sfn "$XDG_STATE_HOME" "$XDG_STATE_HOME.link"; r=$(look_repo none tree-symlinked-state)
  printf '%s\n' "suite phys '[ \"\$PWD\" = \"\$(pwd -P)\" ] || { echo \"logical \$PWD, physical \$(pwd -P)\"; exit 1; }'" > "$r/.orchestrate"; commit_contract "$r"
  out=$(TMPDIR="$LT" XDG_STATE_HOME="$XDG_STATE_HOME.link" look "$r" base "$TMP/findings-tree")
  assert_match "look: a symlinked state dir: the suite runs in the resolved path" "$(verdict "$TMP/findings-tree/look.json" 2>&1)" '^phys pass '
  assert_eq "look: ... the temp worktree is gone" "$(tree_gone "$r")" gone
  rm -f "$XDG_STATE_HOME.link"
  assert_eq "look: its worktree dir is the user's alone (mode 700)" "$(ls -ld "$LOOK_ROOT" | cut -c1-10)" drwx------
  # Its worktree dir must be outside everything a lane may write: under the
  # checkout, its git dir, the run dir, /tmp or TMPDIR it is refused.
  r=$(look_repo none tree-where)
  refused() {  # WHAT XDG_STATE_HOME [ENV...]
    local what=$1 x=$2 n; shift 2; n=$(git -C "$r" worktree list | wc -l | tr -d ' ')
    out=$(env TMPDIR="$LT" XDG_STATE_HOME="$x" "$@" bash -c 'cd "${LOOK_FROM:-$1}" && "$2" base "$3" 2>&1; echo "exit=$?"' _ "$r" "$PREFLIGHT_DIR/look.sh" "$TMP/findings-tree")
    case "$what" in
      "a symlink") assert_match "look: a worktree dir that is a symlink: refused" "$out" "look: its worktree dir .* is a symlink" ;;
      *) assert_match "look: a worktree dir under $what: refused" "$out" "look: its worktree dir .* is under $what" ;;
    esac
    assert_match "look: ... a setup error" "$out" 'exit=2$'
    assert_eq "look: ... no worktree made" "$(git -C "$r" worktree list | wc -l | tr -d ' ')" "$n"
  }
  refused "the checkout" "$r/state"
  refused "the git dir" "$r/.git/state"
  mkdir -p "$LOOK_STATE/run"
  refused "the run dir" "$LOOK_STATE/run/state" TOWER_RUN="$LOOK_STATE/run"
  wt2="$r/.worktrees/w"; git -C "$r" worktree add -q --detach "$wt2"; mkdir -p "$LOOK_STATE/elsewhere"
  refused "a worktree of this repo" "$r/.worktrees/state" LOOK_FROM="$wt2"
  git -C "$r" worktree remove --force "$wt2"
  # A tower/look that is a symlink, or not the user's, is refused before
  # look touches it: it could point anywhere.
  mkdir -p "$LOOK_STATE/sym/tower" "$LOOK_STATE/target"; chmod 755 "$LOOK_STATE/target"
  ln -s "$LOOK_STATE/target" "$LOOK_STATE/sym/tower/look"
  refused "a symlink" "$LOOK_STATE/sym"
  assert_eq "look: ... its target's mode untouched" "$(ls -ld "$LOOK_STATE/target" | cut -c1-10)" drwxr-xr-x
  refused "/tmp" "/tmp/test-look-state.$$"; rm -rf "/tmp/test-look-state.$$"
  refused "TMPDIR" "$LT/state"; rm -rf "$LT/state"
  unset -f refused
  unset -f tree_gone kit_repo kit_look
  rm -f "$mark"; r=$(look_repo none contract-committed); printf 'touch "%s"\n' "$mark" > "$r/.orchestrate"
  git -C "$r" add .orchestrate; git -C "$r" commit -qm contract
  out=$(look "$r" base "$TMP/findings-contract")
  assert_match "look: a committed contract: the look runs" "$out" 'exit=0$'
  [ -e "$mark" ] && ok "look: ... and the contract is read" || bad "look: ... and the contract is read"
  rm -f "$mark"
  r=$(look_repo none findings); reset_stub
  out=$(SEMGREP_STUB=finding GITLEAKS_STUB=finding look "$r" base "$F")
  f=$(findings "$F/look.json")
  assert_match "look: a semgrep result is a finding"     "$f" '^security must-fix new\.py:3 stub\.rule \| semgrep ERROR$'
  assert_nomatch "look: semgrep's matched code and message are not copied (they may quote a secret)" "$(cat "$F/look.json")" 'AKIASTUBSECRET'
  assert_nomatch "look: gitleaks runs with its secrets redacted" "$(cat "$F/look.json")" 'GLSTUBSECRET'
  assert_match "look: a gitleaks result is a finding"    "$f" '^security must-fix app\.js:2 Generic API Key \| gitleaks generic-api-key in commit abc1234: key = REDACTED$'
  assert_match "look: the review is named look"          "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["review"])' "$F/look.json")" '^look$'
  v=$(verdict "$F/look.json")
  assert_match "look: a scanner with findings fails its verdict row" "$v" '^semgrep fail 1 finding$'
  assert_match "look: gitleaks has its own verdict row"  "$v" '^gitleaks fail 1 finding$'
  r=$(look_repo none clean); reset_stub; out=$(look "$r" base "$F"); v=$(verdict "$F/look.json")
  assert_match "look: a clean scanner passes"            "$v" '^semgrep pass $'
  assert_eq "look: a clean branch has no findings"       "$(findings "$F/look.json")" ""
  reset_stub; out=$(SEMGREP_STUB=absent look "$r" base "$F"); v=$(verdict "$F/look.json")
  assert_match "look: a missing scanner is a warn row"   "$v" '^semgrep warn semgrep is not installed'
  assert_match "look: the run continues past a missing scanner" "$v" '^gitleaks pass $'
  assert_match "look: a missing scanner is not a failure" "$out" 'exit=0$'
  reset_stub; out=$(SEMGREP_STUB=error look "$r" base "$F"); v=$(verdict "$F/look.json")
  assert_match "look: semgrep's error reason is in its warn row" "$v" '^semgrep warn semgrep exited 2: Invalid scanning root: gone\.js$'
  # semgrep can exit 0 and still report errors in its JSON (a file it could
  # not parse): the scan is incomplete, not clean.
  reset_stub; out=$(SEMGREP_STUB=incomplete look "$r" base "$F"); v=$(verdict "$F/look.json")
  assert_match "look: semgrep errors with exit 0 are a warn row with the error's type and file" "$v" '^semgrep warn scan incomplete, 1 error: PartialParsing in new\.py$'
  assert_match "look: ... not a failure"                 "$out" 'exit=0$'
  assert_nomatch "look: ... the error's message is not copied (it can quote code)" "$(cat "$F/look.json")" 'SECRETSTUB'
  reset_stub; out=$(SEMGREP_STUB=incomplete-odd look "$r" base "$F"); v=$(verdict "$F/look.json")
  assert_match "look: errors of odd shapes are still an incomplete scan, counted" "$v" '^semgrep warn scan incomplete, 2 errors'
  assert_match "look: ... and do not stop look"          "$out" 'exit=0$'
  reset_stub; out=$(SEMGREP_STUB=incomplete-finding look "$r" base "$F"); v=$(verdict "$F/look.json")
  assert_match "look: an incomplete scan keeps its findings" "$(findings "$F/look.json")" '^security must-fix new\.py:3 stub\.rule \| semgrep ERROR$'
  assert_match "look: ... its row fails and says the scan is incomplete" "$v" '^semgrep fail 1 finding; scan incomplete, 1 error: Timeout in new\.py$'
  reset_stub; out=$(SEMGREP_STUB=garbage look "$r" base "$F"); v=$(verdict "$F/look.json")
  assert_match "look: unreadable scanner output is a warn row" "$v" '^semgrep warn could not read semgrep output$'
  assert_match "look: unreadable scanner output does not stop the run" "$v" '^gitleaks pass $'
  reset_stub; out=$(GITLEAKS_STUB=error look "$r" base "$F"); v=$(verdict "$F/look.json")
  assert_match "look: a scanner that errors is a warn row with its message" "$v" '^gitleaks warn gitleaks exited 2: gitleaks: not a git repository \(stub\)$'
  reset_stub; out=$(STATIC_BASELINE=off SEMGREP_STUB=finding look "$r" base "$F"); v=$(verdict "$F/look.json")
  assert_match "look: STATIC_BASELINE=off skips semgrep and says so" "$v" '^semgrep skip STATIC_BASELINE=off$'
  assert_match "look: STATIC_BASELINE=off skips gitleaks and says so" "$v" '^gitleaks skip STATIC_BASELINE=off$'
  assert_nomatch "look: STATIC_BASELINE=off runs no scanner" "$(cat "$HERDR_STUB_LOG")" '^(semgrep|gitleaks) '
  r=$(look_repo none same); reset_stub; out=$(SEMGREP_STUB=finding GITLEAKS_STUB=finding look "$r" feat "$F"); v=$(verdict "$F/look.json")
  assert_nomatch "look: no changed files, no scan"       "$(cat "$HERDR_STUB_LOG")" '^(semgrep|gitleaks) (scan|git)'
  assert_match "look: no changed files is a skip row"    "$v" '^semgrep skip no changed files$'
  assert_match "look: no commits, gitleaks is a skip row" "$v" '^gitleaks skip no commits since the base$'
  assert_eq "look: no changed files, no findings"        "$(findings "$F/look.json")" ""
  r=$(look_repo none added-then-deleted)
  printf 'k\n' > "$r/leak.js"; git -C "$r" add leak.js; git -C "$r" commit -qm leak
  git -C "$r" rm -q leak.js new.py; git -C "$r" checkout -q base -- app.js; git -C "$r" commit -qm unleak
  reset_stub; out=$(look "$r" base "$F"); v=$(verdict "$F/look.json")
  assert_match "look: no net change still scans the commits for secrets" "$(cat "$HERDR_STUB_LOG")" '^gitleaks git '
  assert_match "look: no net change skips semgrep"       "$v" '^semgrep skip no changed files$'
  r=$(look_repo none odd-names)
  printf 'z\n' > "$r/café app.js"; git -C "$r" add -A; git -C "$r" commit -qm odd
  reset_stub; out=$(look "$r" base "$F"); log=$(cat "$HERDR_STUB_LOG")
  assert_match "look: a file name with spaces and accents is passed as is" "$log" '^semgrep scan .* -- app\.js café app\.js new\.py$'
  # A sparse checkout can lack a changed file without the tree being dirty:
  # look's worktree of HEAD has it, and scans it.
  git -C "$r" update-index --skip-worktree new.py; rm "$r/new.py"; reset_stub; out=$(look "$r" base "$F")
  assert_match "look: a changed file the checkout lacks (sparse) is scanned from HEAD" "$(cat "$HERDR_STUB_LOG")" '^semgrep scan .* -- app\.js café app\.js new\.py$'
  git -C "$r" update-index --no-skip-worktree new.py; git -C "$r" checkout -q -- new.py
  mkdir -p "$r/sub"; reset_stub
  out=$(cd "$r/sub" && "$PREFLIGHT_DIR/look.sh" base rel-findings 2>&1; echo "exit=$?")
  assert_match "look: runs from a subdirectory"          "$(cat "$HERDR_STUB_LOG")" '^semgrep scan .* -- app\.js café app\.js new\.py$'
  assert_eq "look: a relative findings dir is relative to where it was called" "$(verdict "$r/sub/rel-findings/look.json" | grep '^semgrep')" "semgrep pass "
  out=$(look "$r" nosuchref "$F")
  assert_match "look: an unknown base is refused"        "$out" "no merge base between 'nosuchref' and HEAD"
  assert_match "look: a setup error exits 2, not 1 (must-fix)" "$out" 'exit=2$'
  assert_eq "look: a setup error leaves no stale look.json" "$([ -e "$F/look.json" ] && echo stale || echo none)" none
  out=$(PR=maybe look "$r" base "$F")
  assert_match "look: a bad switch is refused"          "$out" "^PR must be draft, ready or off"
  assert_match "look: a bad switch is a setup error"     "$out" "exit=2$"
  r=$(look_repo none clean2); reset_stub
  out=$(SEMGREP_STUB=finding look "$r" base "$F")
  assert_match "look: a must-fix finding exits 1"        "$out" 'exit=1$'
  assert_match "look: the verdict table is printed"      "$out" '^semgrep +fail +1 finding$'
  out=$(look "$r" base "$F")
  assert_match "look: no must-fix finding exits 0"       "$out" 'exit=0$'
  assert_match "look: the table names the findings file" "$out" "findings: $F/look.json"
  r=$(look_repo suite suite); export SUITE_ORDER="$TMP/suite-order"; : > "$SUITE_ORDER"
  out=$(SUITE_SKIP='' look "$r" base "$F")
  o=$(cat "$SUITE_ORDER"); d=$(sed -n 's/^lint //p' <<< "$o")
  assert_eq "look: every suite step runs in its DIR, in contract order" "$o" "$(printf 'lint %s\ntest %s\nbuild %s/web' "$d" "$d" "$d")"
  [ -n "$d" ] && [ "$d" != "$r" ] && [ "$d" != "$(cd "$r" && pwd -P)" ] \
    && ok "look: ... in look's own worktree of HEAD, not the checkout" || bad "look: ... in look's own worktree of HEAD, not the checkout" "$d"
  v=$(verdict "$F/look.json")
  assert_match "look: a passing step is a pass row"      "$v" '^lint pass '
  assert_match "look: a failing step is a fail row"      "$v" '^test fail exit 3'
  assert_match "look: a failing step does not stop the next one" "$v" '^build pass '
  f=$(findings "$F/look.json")
  assert_match "look: a failing step is a must-fix finding" "$f" '^suite must-fix .* suite step test failed \(exit 3\) \|'
  assert_match "look: the finding carries the output tail" "$(python3 -c "import json,sys; print([x['evidence'] for x in json.load(open(sys.argv[1]))['findings'] if x['area'] == 'suite'][0])" "$F/look.json")" 'line-25'
  assert_nomatch "look: only the tail, not the whole output" "$(python3 -c "import json,sys; print([x['evidence'] for x in json.load(open(sys.argv[1]))['findings'] if x['area'] == 'suite'][0])" "$F/look.json")" 'line-1$'
  assert_match "look: a red step exits 1"                "$out" 'exit=1$'
  : > "$SUITE_ORDER"; out=$(look "$r" base "$F"); v=$(verdict "$F/look.json")
  assert_match "look: SUITE_SKIP from the file skips that step" "$v" '^lint skip SUITE_SKIP$'
  assert_nomatch "look: a skipped step does not run"     "$(cat "$SUITE_ORDER")" '^lint'
  : > "$SUITE_ORDER"; out=$(SUITE_SKIP=build look "$r" base "$F"); v=$(verdict "$F/look.json")
  assert_match "look: SUITE_SKIP from the environment wins over the file" "$v" '^build skip SUITE_SKIP$'
  assert_match "look: ... and the file's skip no longer applies" "$v" '^lint pass '
  : > "$SUITE_ORDER"; out=$(SUITE_SKIP='build, lint' look "$r" base "$F"); v=$(verdict "$F/look.json")
  assert_match "look: SUITE_SKIP is a comma list, spaces allowed" "$v" '^lint skip SUITE_SKIP$'
  assert_match "look: ... every name in it is skipped"   "$v" '^build skip SUITE_SKIP$'
  out=$(SUITE_SKIP=biuld look "$r" base "$F"); v=$(verdict "$F/look.json")
  assert_match "look: a SUITE_SKIP name with no step is a warn row" "$v" "^SUITE_SKIP warn no suite step named biuld$"
  r=$(look_repo suite-detected detected); out=$(look "$r" base "$F"); v=$(verdict "$F/look.json")
  assert_match "look: without suite lines the detected typecheck runs" "$v" '^typecheck pass npm run typecheck$'
  assert_match "look: without suite lines the detected test runs" "$v" '^test pass npm run test$'
  r=$(look_repo none nosuite); out=$(CHECK_CMD='echo checked' look "$r" base "$F"); v=$(verdict "$F/look.json")
  assert_match "look: with neither, CHECK_CMD is the one step" "$v" '^check pass echo checked$'
  assert_nomatch "look: with neither, no typecheck step" "$v" '^typecheck '
  out=$(CHECK_CMD=$'true\ntrue' look "$r" base "$F"); v=$(verdict "$F/look.json")
  assert_match "look: a multi-line command stays one verdict row" "$v" '^check pass true true$'
  assert_match "look: a multi-line command does not break the run" "$out" 'exit=0$'
  out=$(unset CHECK_CMD; look "$r" base "$F"); v=$(verdict "$F/look.json")
  assert_match "look: no package.json and no CHECK_CMD is a skip row, not a red npm step" "$v" '^check skip no suite lines, no package.json scripts, no CHECK_CMD$'
  assert_match "look: ... and not a failure"             "$out" 'exit=0$'
  r=$(look_repo suite-noscripts noscripts); out=$(unset CHECK_CMD; look "$r" base "$F"); v=$(verdict "$F/look.json")
  assert_match "look: a package.json without scripts and no CHECK_CMD is a skip row" "$v" '^check skip no suite lines, no package.json scripts, no CHECK_CMD$'
  # A step that fails on a permission error is the sandbox, not the code: a
  # setup verdict, not a must-fix suite finding.
  r=$(look_repo none perm)
  printf '%s\n' "suite lint 'echo \"error: bun is unable to write files to tempdir: PermissionDenied\"; exit 1'" "suite ok true" > "$r/.orchestrate"; commit_contract "$r"
  out=$(look "$r" base "$F"); v=$(verdict "$F/look.json")
  assert_match "look: a step failing on a permission error is a setup row" "$v" '^lint warn setup: exit 1, a permission error \(error: bun is unable to write files to tempdir: PermissionDenied\): echo'
  assert_nomatch "look: ... not a must-fix suite finding" "$(findings "$F/look.json")" 'must-fix'
  assert_match "look: ... the steps after it still run"  "$v" '^ok pass true$'
  assert_match "look: ... and the look is a setup error, with look.json kept" "$out" 'exit=2$'
  assert_match "look: ... it says which step and why"    "$out" '^look: setup error: suite step\(s\) lint failed on a permission error'
  printf '%s\n' "suite rm 'echo \"rm: /cache/x: Operation not permitted\" >&2; exit 1'" \
    "suite npm 'echo \"npm ERR! code EACCES\"; exit 243'" "suite unit 'echo \"expected 1, got 2\"; exit 1'" > "$r/.orchestrate"; commit_contract "$r"
  out=$(look "$r" base "$F"); v=$(verdict "$F/look.json")
  assert_match "look: Operation not permitted, on stderr, is a setup row" "$v" '^rm warn setup: exit 1, a permission error \(rm: /cache/x: Operation not permitted\)'
  assert_match "look: EACCES is a setup row"             "$v" '^npm warn setup: exit 243, a permission error \(npm ERR! code EACCES\)'
  assert_match "look: a step failing otherwise is still a must-fix suite finding" "$(findings "$F/look.json")" '^suite must-fix .* suite step unit failed \(exit 1\)'
  assert_match "look: ... the setup error still wins the exit" "$out" 'exit=2$'
  assert_match "look: ... and names every setup step"   "$out" 'suite step\(s\) rm npm failed'
  assert_match "look: a setup step keeps its output tail, as a watchpoint for triage" "$(findings "$F/look.json")" '^suite watchpoint .* suite step npm failed on a permission error \(exit 243\) \| \$ echo .*npm ERR! code EACCES'
  printf '%s\n' "suite bin 'printf \"x\\\\0y\\\\n\"; echo EACCES; exit 1'" "suite cr 'printf \"10%%\\\\rerror: PermissionDenied\\\\n\"; exit 1'" \
    "suite noisy 'echo \"warn: EACCES on a probe, retried\"'" > "$r/.orchestrate"; commit_contract "$r"
  out=$(look "$r" base "$F"); v=$(verdict "$F/look.json")
  assert_match "look: output with a NUL byte is still read for a permission error" "$v" '^bin warn setup: '
  assert_match "look: a carriage return in the matched line becomes a space" "$v" '^cr warn setup: exit 1, a permission error \(10% error: PermissionDenied\)'
  assert_match "look: a step that passes with EACCES in its output passes" "$v" '^noisy pass '
  # The permission error before a long summary: the whole output is searched.
  printf '%s\n' "suite late 'echo \"error: PermissionDenied\"; for i in \$(seq 1 30); do echo summary-\$i; done; exit 1'" > "$r/.orchestrate"; commit_contract "$r"
  out=$(look "$r" base "$F"); v=$(verdict "$F/look.json")
  assert_match "look: a permission error more than 20 lines before the end is a setup row" "$v" '^late warn setup: exit 1, a permission error \(error: PermissionDenied\)'
  assert_match "look: ... it is a watchpoint"           "$(findings "$F/look.json")" '^suite watchpoint .* suite step late failed on a permission error \(exit 1\) \|'
  ev=$(python3 -c "import json,sys; print([x['evidence'] for x in json.load(open(sys.argv[1]))['findings'] if x['area'] == 'suite'][0])" "$F/look.json")
  assert_match "look: ... carrying the bounded tail"      "$ev" '^summary-30$'
  assert_nomatch "look: ... only the tail"                "$ev" '^summary-10$'
  assert_nomatch "look: ... not a must-fix"               "$(findings "$F/look.json")" 'must-fix'
  assert_match "look: ... and the look is a setup error"  "$out" 'exit=2$'
  r=$(look_repo semgrep-rules rules); reset_stub; out=$(look "$r" base "$F")
  assert_match "look: the repo's .semgrep/ rules are added" "$(cat "$HERDR_STUB_LOG")" '^semgrep scan --config p/default --config \.semgrep '
  # A tracked file with edits the branch has not committed: the suite could
  # rewrite it, and putting the suite's changes back would take those edits
  # with it. look.sh refuses before any step runs.
  r=$(look_repo none dirty); printf 'my edit\n' >> "$r/app.js"; printf 'u\n' > "$r/untracked.txt"; reset_stub
  mkdir -p "$F"; echo '{}' > "$F/look.json"
  out=$(look "$r" base "$F")
  assert_eq "look: a refusal leaves no earlier look.json behind" "$([ -e "$F/look.json" ] && echo stale || echo none)" none
  assert_match "look: uncommitted edits to a tracked file are refused" "$out" '^look: .*app\.js'
  assert_match "look: ... as a setup error"              "$out" 'exit=2$'
  assert_nomatch "look: ... before any step runs"        "$(cat "$HERDR_STUB_LOG")" '^(semgrep|gitleaks) '
  assert_match "look: ... and the edits are still there" "$(cat "$r/app.js")" 'my edit'
  git -C "$r" add app.js; out=$(look "$r" base "$F")
  assert_match "look: a staged edit is refused too"      "$out" 'exit=2$'
  git -C "$r" reset -q; git -C "$r" checkout -q -- app.js; reset_stub; out=$(look "$r" base "$F")
  assert_match "look: an untracked file alone is no refusal" "$out" 'exit=0$'
  r=$(look_repo none local-base); reset_stub; out=$(look "$r" base "$F"); v=$(verdict "$F/look.json")
  assert_match "look: a base that is no remote branch is a skip row" "$v" '^base skip base is not a remote-tracking branch$'
  git -C "$r" remote add origin "$TMP/repos/no-such-remote.git"
  reset_stub; out=$(look "$r" base "$F"); v=$(verdict "$F/look.json")
  assert_match "look: ... even with a remote it cannot ask, which it does not ask" "$v" '^base skip base is not a remote-tracking branch$'
  reset_stub; out=$(look "$r" "$(git -C "$r" rev-parse base)" "$F"); v=$(verdict "$F/look.json")
  assert_match "look: a base given as a commit is a skip row" "$v" '^base skip [0-9a-f]{40} is not a remote-tracking branch$'
  # The base: look.sh never fetches (a sandboxed Reviewer cannot write .git);
  # it asks the remote with ls-remote whether origin/<base> is current.
  r=$(look_repo none remote); git init -q --bare "$TMP/repos/look-remote.git"
  git -C "$r" remote add origin "$TMP/repos/look-remote.git"; git -C "$r" push -q origin base:refs/heads/main; git -C "$r" fetch -q origin
  git -C "$r" push -q origin feat:refs/x/refs/heads/main   # ls-remote's pattern matches this too
  reset_stub; out=$(look "$r" origin/main "$F"); v=$(verdict "$F/look.json")
  assert_match "look: a current remote base is a pass row" "$v" "^base pass origin/main matches origin \($(git -C "$r" rev-parse --short base)\)$"
  git -C "$r" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  reset_stub; out=$(look "$r" origin/HEAD "$F"); v=$(verdict "$F/look.json")
  assert_match "look: origin/HEAD is checked as the branch it points at" "$v" "^base pass origin/HEAD matches origin \($(git -C "$r" rev-parse --short base)\)$"
  git -C "$r" config core.abbrev 12
  git -C "$r" push -q origin feat:refs/heads/main   # the remote moves on; origin/main is not fetched
  git -C "$r" update-ref refs/remotes/origin/main base; rm -f "$r/.git/FETCH_HEAD"
  reset_stub; out=$(look "$r" origin/main "$F"); v=$(verdict "$F/look.json")
  assert_eq "look: never fetches (a sandbox keeps .git read-only)" "$(git -C "$r" rev-parse origin/main):$([ -e "$r/.git/FETCH_HEAD" ] && echo fetched || echo none)" "$(git -C "$r" rev-parse base):none"
  assert_match "look: a base behind its remote is a warn row, named stale" "$v" "^base warn base is stale: origin/main is $(git -C "$r" rev-parse --short base), origin has $(git -C "$r" rev-parse --short feat); whoever runs look fetches, then looks again$"
  assert_match "look: ... not a failure"                 "$out" 'exit=0$'
  git -C "$r" update-ref refs/remotes/origin/gone base   # fetched once, since deleted on the remote
  reset_stub; out=$(look "$r" origin/gone "$F"); v=$(verdict "$F/look.json")
  assert_match "look: a base branch gone from its remote is a warn row" "$v" "^base warn base could not be refreshed: origin has no branch gone; origin/gone is $(git -C "$r" rev-parse --short base), as last fetched$"
  assert_match "look: ... not a failure"                 "$out" 'exit=0$'
  # A sandbox without network, or a remote that is gone: the named, expected case.
  git -C "$r" remote set-url origin "$TMP/repos/no-such-remote.git"
  reset_stub; out=$(look "$r" origin/main "$F"); v=$(verdict "$F/look.json")
  assert_match "look: a remote it cannot ask is a warn row: base could not be refreshed" "$v" "^base warn base could not be refreshed: git ls-remote origin failed \(.+\); origin/main is $(git -C "$r" rev-parse --short base), as last fetched$"
  assert_match "look: ... not a setup error"             "$out" 'exit=0$'
  assert_match "look: ... and the rest of the look runs" "$v" '^semgrep pass $'
  # An ssh remote must not wait on a passphrase or host-key prompt (ssh reads
  # /dev/tty), nor on a network that drops packets.
  printf '#!/bin/sh\necho "$*" >> "%s"; exit 255\n' "$TMP/ssh.log" > "$TMP/ssh-stub"; chmod +x "$TMP/ssh-stub"
  git -C "$r" config core.sshCommand "$TMP/ssh-stub"; git -C "$r" remote set-url origin ssh://git.example.invalid/acme.git
  reset_stub; out=$(look "$r" origin/main "$F"); v=$(verdict "$F/look.json")
  assert_match "look: ssh runs in batch mode, with a connect timeout" "$(cat "$TMP/ssh.log" 2>&1)" '-o BatchMode=yes -o ConnectTimeout=[0-9]+ .*git\.example\.invalid'
  assert_match "look: ... and a failed ssh is base could not be refreshed" "$v" '^base warn base could not be refreshed: git ls-remote origin failed'
  git -C "$r" config --unset core.sshCommand; : > "$TMP/ssh.log"
  reset_stub; out=$(GIT_SSH="$TMP/ssh-stub" look "$r" origin/main "$F")
  assert_match "look: a GIT_SSH wrapper is used as it is"  "$(cat "$TMP/ssh.log")" 'git\.example\.invalid'
  assert_nomatch "look: ... without ssh's -o options"     "$(cat "$TMP/ssh.log")" 'BatchMode'
  # Shortcuts: the marker comments the branch added, after a comment prefix.
  # The markers are spelled through $m and $p so this file adds none of its own.
  m=shortcut; p=ponytail; r=$(look_repo none shortcuts)
  printf '// %s: old limit, later\n' "$m" > "$r/base.js"; git -C "$r" add -A; git -C "$r" commit -qm old; git -C "$r" tag mid
  printf 'x = 1\ny = 2  # %s: no retry, when calls fail\n' "$m" > "$r/a.py"
  printf '/* %s: one global lock */\n' "$p" > "$r/b.js"
  printf 'the %s: marker in prose\n' "$m" > "$r/c.md"
  printf -- '-- %s: full scan, past 10k rows\n' "$m" > "$r/d.sql"
  printf 'more\n' >> "$r/base.js"
  git -C "$r" add -A; git -C "$r" commit -qm shortcuts
  out=$(look "$r" mid "$F"); v=$(verdict "$F/look.json"); f=$(findings "$F/look.json")
  assert_match "look: the shortcuts row lists every Shortcut the branch added, the one with no trigger marked" "$v" '^shortcuts warn 3 shortcuts, 1 with no trigger \| a\.py:2, b\.js:1 \(no trigger\), d\.sql:1$'
  assert_match "look: a Shortcut with no trigger is a watchpoint" "$f" "^shortcuts watchpoint b\\.js:1 Shortcut names no trigger \\| ponytail: one global lock$"
  assert_eq "look: ... the only finding of its area" "$(printf '%s\n' "$f" | grep -c '^shortcuts ')" 1
  assert_match "look: ... and the look stays green" "$out" 'exit=0$'
  out=$(STATIC_BASELINE=off look "$r" mid "$F"); v=$(verdict "$F/look.json")
  assert_match "look: STATIC_BASELINE=off still lists the Shortcuts" "$v" '^shortcuts warn 3 shortcuts, 1 with no trigger '
  # A doc comment's continuation line, a name with a space (git ends its +++
  # line with a tab), and a user's diff.noprefix: still found, by its name.
  r=$(look_repo none shortcuts-odd); git -C "$r" config diff.noprefix true
  printf '/**\n * %s: one lock, past 2 writers\n */\n' "$m" > "$r/e f.ts"; git -C "$r" add -A; git -C "$r" commit -qm doc
  out=$(look "$r" base "$F"); v=$(verdict "$F/look.json")
  assert_match "look: a Shortcut in a doc comment, in a file with a space, under diff.noprefix" "$v" '^shortcuts pass 1 shortcuts, 0 with no trigger \| e f\.ts:2$'
  # A user's diff.interHunkContext merges two hunks with context lines between
  # them: the Shortcut after them is still cited at its own line.
  r=$(look_repo none shortcuts-inter-hunk); git -C "$r" config diff.interHunkContext 5
  printf '%s\n' 1 2 3 4 5 6 7 8 > "$r/f.sh"; git -C "$r" add -A; git -C "$r" commit -qm lines; git -C "$r" tag mid
  printf '%s\n' 1 two 3 4 5 "x  # $m: no cache, past 10 calls" 7 8 > "$r/f.sh"; git -C "$r" commit -qam edit
  out=$(look "$r" mid "$F"); v=$(verdict "$F/look.json")
  assert_match "look: diff.interHunkContext does not move a Shortcut's line" "$v" '^shortcuts pass 1 shortcuts, 0 with no trigger \| f\.sh:6$'
  out=$(GIT_DIFF_OPTS=-u5 look "$r" mid "$F"); v=$(verdict "$F/look.json")
  assert_match "look: ... nor does GIT_DIFF_OPTS" "$v" '^shortcuts pass 1 shortcuts, 0 with no trigger \| f\.sh:6$'
  # A text file git is told to treat as binary still shows its added lines.
  git -C "$r" config core.bigFileThreshold 1
  out=$(look "$r" mid "$F"); v=$(verdict "$F/look.json")
  assert_match "look: a file core.bigFileThreshold calls binary: its Shortcut is still listed" "$v" '^shortcuts pass 1 shortcuts, 0 with no trigger \| f\.sh:6$'
  # Markdown: a bullet or bold that mentions the word is prose; only a comment
  # (HTML, or MDX's {/* */}) is a Shortcut. In code a SQLite-style ** line is.
  r=$(look_repo none shortcuts-markdown)
  printf '* %s: a bullet\n**%s: bold**\n<!-- %s: html comment, past 3 pages -->\n' "$m" "$m" "$m" > "$r/notes.md"
  printf '{/* %s: mdx comment, past 2 pages */}\n' "$m" > "$r/notes.mdx"
  printf '/*\n** %s: sqlite style, past 2 writers\n*/\n' "$m" > "$r/lib.c"
  git -C "$r" add -A; git -C "$r" commit -qm notes
  out=$(look "$r" base "$F"); v=$(verdict "$F/look.json")
  assert_match "look: in markdown only a comment is a Shortcut (HTML, or MDX's /*), not a bullet or bold; in code a ** block line is" "$v" '^shortcuts pass 3 shortcuts, 0 with no trigger \| lib\.c:2, notes\.md:3, notes\.mdx:1$'
  r=$(look_repo none no-shortcuts); out=$(look "$r" base "$F"); v=$(verdict "$F/look.json")
  assert_match "look: a branch with no Shortcuts: a pass row" "$v" '^shortcuts pass 0 shortcuts, 0 with no trigger \| $'
  export XDG_STATE_HOME=$SAVED_XDG_STATE_HOME; unset SAVED_XDG_STATE_HOME LOOK_ROOT
  unset CHECK_CMD INSTALL_CMD SUITE_ORDER; unset -f look_repo findings verdict look
fi

# --- install -----------------------------------------------------------------
if section install; then
  H="$TMP/home"; mkdir -p "$H"
  # The old layout's links, which install removes: Claude Code gets the plugin.
  mkdir -p "$H/.claude/skills" "$H/.agents/skills"; ln -s "$ROOT" "$H/.claude/skills/herdr-orchestrate"
  ln -s "$ROOT/preflight" "$H/.claude/skills/preflight"; ln -s "$TMP/tools/spec-to-plan" "$H/.claude/skills/spec-to-plan"
  ln -s "$ROOT" "$H/.agents/skills/herdr-orchestrate"; ln -s "$TMP/elsewhere" "$H/.claude/skills/other"
  export CLAUDE_STUB_STATE="$TMP/claude-state"; : > "$CLAUDE_STUB_STATE"
  reset_stub; out=$(HOME="$H" "$ROOT/install.sh" 2>&1; echo "exit=$?")
  assert_match "install: exit 0"                      "$out" 'exit=0$'
  assert_match "install: adds this repo as the phutschi-tower marketplace" "$(cat "$TMP/log")" "^claude plugin marketplace add $ROOT$"
  assert_match "install: installs tower@phutschi-tower" "$(cat "$TMP/log")" '^claude plugin install tower@phutschi-tower$'
  assert_nomatch "install: without the old plugin, removes nothing" "$(cat "$TMP/log")" '^claude plugin (uninstall|remove|marketplace (remove|rm)) '
  assert_eq "install: claude has the tower plugin and its marketplace" "$(sort "$CLAUDE_STUB_STATE")" "$(printf 'marketplace phutschi-tower\nplugin tower@phutschi-tower user')"
  assert_match "install: the closing message runs from herdr or Orca" "$out" 'from a herdr pane or an Orca chat'
  for n in herdr-orchestrate preflight; do
    [ -e "$H/.claude/skills/$n" ] || [ -L "$H/.claude/skills/$n" ] && bad "install: old ~/.claude/skills/$n link removed" || ok "install: old ~/.claude/skills/$n link removed"
  done
  assert_eq "install: a spec-to-plan link into another directory is left alone" "$(readlink "$H/.claude/skills/spec-to-plan")" "$TMP/tools/spec-to-plan"
  [ -L "$H/.agents/skills/herdr-orchestrate" ] && bad "install: old ~/.agents/skills link removed" || ok "install: old ~/.agents/skills link removed"
  assert_eq "install: a link of someone else's is left alone" "$(readlink "$H/.claude/skills/other")" "$TMP/elsewhere"
  for n in orchestrate spec-to-plan preflight; do
    assert_eq "install: $n linked into ~/.agents/skills" "$(readlink "$H/.agents/skills/$n")" "$ROOT/skills/$n"
  done
  assert_eq "install: preflight linked into ~/.codex/skills" "$(readlink "$H/.codex/skills/preflight")" "$PREFLIGHT_DIR"
  assert_match "install: lists herdr as ok (stub)"    "$out" 'ok +herdr'
  assert_match "install: tower is required, and runs"  "$out" 'ok +tower$'
  assert_match "install: prints the two openings"     "$out" 'with a plan: +/tower:orchestrate'
  assert_match "install: prints how to plan"          "$out" '/tower:spec-to-plan'
  assert_nomatch "install: names no old plugin or command" "$out" 'phutschi[@:]'
  assert_match "install: semgrep is optional"         "$out" 'semgrep.*optional'
  assert_match "install: gitleaks is optional"        "$out" 'gitleaks.*optional'
  links() { find "$H" -type l -exec sh -c 'printf "%s -> %s\n" "$1" "$(readlink "$1")"' _ {} \; | sort; }
  before=$(links)
  reset_stub; out=$(HOME="$H" "$ROOT/install.sh" 2>&1; echo "exit=$?")
  assert_match "install: idempotent"                  "$out" 'exit=0$'
  assert_nomatch "install: a second run installs and removes nothing" "$(cat "$TMP/log")" '^claude plugin (install|uninstall|remove|marketplace (add|remove|rm)) '
  assert_eq "install: a second run leaves claude's plugins as they are" "$(sort "$CLAUDE_STUB_STATE")" "$(printf 'marketplace phutschi-tower\nplugin tower@phutschi-tower user')"
  assert_eq "install: a second run changes no link"   "$(links)" "$before"
  assert_nomatch "install: a second run skips nothing" "$out" 'SKIPPED'
  ln -s "$ROOT" "$TMP/repo-link"; out=$(HOME="$H" "$TMP/repo-link/install.sh" 2>&1; echo "exit=$?")
  assert_eq "install: run through a link, the links still point at the repo" "$(links)" "$before"
  out=$("$H/.codex/skills/preflight/look.sh" 2>&1; echo "exit=$?")
  assert_match "install: look.sh runs through the installed link" "$out" '^usage: preflight/look.sh'
  assert_match "install: ... and finds the kit behind it" "$out" 'exit=2$'
  H3="$TMP/home3"; mkdir -p "$H3/.codex/skills/preflight"
  out=$(HOME="$H3" SEMGREP_STUB=absent GITLEAKS_STUB=absent "$ROOT/install.sh" 2>&1; echo "exit=$?")
  assert_match "install: a real dir in the way is skipped" "$out" "SKIPPED +$H3/.codex/skills/preflight exists"
  assert_eq "install: ... and left as it is"          "$([ -L "$H3/.codex/skills/preflight" ] && echo link || echo dir)" dir
  assert_match "install: a missing semgrep is optional" "$out" 'optional +semgrep'
  assert_match "install: a missing gitleaks is optional" "$out" 'optional +gitleaks'
  assert_match "install: missing scanners do not fail it" "$out" 'exit=0$'
  # A skills dir that cannot be written: the link fails, and so does the install.
  # (Where chmod does not bind, as for root, these cases are skipped.)
  read_only() { chmod 555 "$1"; if touch "$1/.probe" 2>/dev/null; then rm -f "$1/.probe"; chmod 755 "$1"; return 1; fi; }
  H5="$TMP/home5"; mkdir -p "$H5/.agents/skills"
  if read_only "$H5/.agents/skills"; then
  out=$(HOME="$H5" "$ROOT/install.sh" 2>&1; echo "exit=$?"); chmod 755 "$H5/.agents/skills"
  assert_match "install: an unwritable skills dir is FAILED, with the command" "$out" "FAILED +ln -sfn .* $H5/.agents/skills/orchestrate"
  assert_nomatch "install: ... and nothing there claims linked" "$out" "linked +$H5/.agents/skills/"
  assert_match "install: ... and the install fails"   "$out" 'exit=1$'
  assert_nomatch "install: ... without the closing message" "$out" 'with a plan: +/tower:orchestrate'
  assert_match "install: ... with the reason"         "$out" 'FAILED +ln -sfn .*\(.*[Pp]ermission denied'
  else ok "install: (skipped: chmod does not bind here)"; fi
  # The old kit's own links, from a herdr-orchestrate checkout (its scripts at
  # the root, or under skills/), go; anybody else's skill of the same name stays.
  H7="$TMP/home7"; OLD="$TMP/old/herdr-orchestrate"; OLD2="$TMP/old2/herdr-orchestrate"; NOTKIT="$TMP/notkit/herdr-orchestrate"
  mkdir -p "$H7/.claude/skills" "$H7/.agents/skills" "$OLD/preflight" "$OLD2/skills/orchestrate" "$OLD2/skills/preflight" "$NOTKIT" "$TMP/plugin-x/preflight"
  : > "$OLD/bootstrap.sh"; : > "$OLD2/skills/orchestrate/bootstrap.sh"
  ln -s "$OLD" "$H7/.claude/skills/herdr-orchestrate"; ln -s "$OLD/preflight" "$H7/.claude/skills/preflight"
  ln -s "$OLD2/skills/spec-to-plan" "$H7/.claude/skills/spec-to-plan"; ln -s "$NOTKIT" "$H7/.agents/skills/herdr-orchestrate"
  out=$(HOME="$H7" "$ROOT/install.sh" 2>&1; echo "exit=$?")
  for n in herdr-orchestrate preflight spec-to-plan; do
    [ -L "$H7/.claude/skills/$n" ] && bad "install: the old kit's ~/.claude/skills/$n link removed" || ok "install: the old kit's ~/.claude/skills/$n link removed"
  done
  assert_eq "install: a herdr-orchestrate link to something else is left alone" "$(readlink "$H7/.agents/skills/herdr-orchestrate")" "$NOTKIT"
  # A checkout that is gone goes; a dir named herdr-orchestrate that is not the
  # kit stays, whether the link is absolute or relative; this repo reached
  # through another path is still this repo.
  H9="$TMP/home9"; mkdir -p "$H9/.claude/skills" "$TMP/via"; ln -s "$ROOT" "$TMP/via/kit"
  ln -s "$TMP/gone/herdr-orchestrate/preflight" "$H9/.claude/skills/preflight"
  ln -s "$NOTKIT/spec-to-plan" "$H9/.claude/skills/spec-to-plan"
  ln -s "../../../notkit/herdr-orchestrate" "$H9/.claude/skills/herdr-orchestrate"
  out=$(HOME="$H9" "$ROOT/install.sh" 2>&1; echo "exit=$?")
  assert_match "install: a link into a gone kit checkout is removed" "$out" "removed +$H9/.claude/skills/preflight"
  assert_nomatch "install: a link under a herdr-orchestrate dir that is not the kit stays" "$out" "removed +$H9/.claude/skills/spec-to-plan"
  assert_nomatch "install: ... and so does a relative link to it" "$out" "removed +$H9/.claude/skills/herdr-orchestrate"
  H10="$TMP/home10"; mkdir -p "$H10/.claude/skills"; ln -s "$TMP/via/kit/skills/preflight" "$H10/.claude/skills/preflight"
  out=$(HOME="$H10" "$ROOT/install.sh" 2>&1; echo "exit=$?")
  assert_match "install: a link to this repo through another path is removed" "$out" "removed +$H10/.claude/skills/preflight"
  # A target is judged by where it really points: '..' out of this repo or out
  # of an old checkout is somebody else's; a relative link into the kit is the kit's.
  H11="$TMP/home11"; mkdir -p "$H11/.claude/skills"
  ln -s "$ROOT/../acme-other-plugin/skills/spec-to-plan" "$H11/.claude/skills/spec-to-plan"
  ln -s "$OLD/../elsewhere/preflight" "$H11/.claude/skills/preflight"
  ln -s "../../../old/herdr-orchestrate" "$H11/.claude/skills/herdr-orchestrate"
  out=$(HOME="$H11" "$ROOT/install.sh" 2>&1; echo "exit=$?")
  assert_nomatch "install: a target that climbs out of this repo is left alone" "$out" "removed +$H11/.claude/skills/spec-to-plan"
  assert_nomatch "install: a target that climbs out of an old checkout is left alone" "$out" "removed +$H11/.claude/skills/preflight"
  assert_match "install: a relative link into the old kit is removed" "$out" "removed +$H11/.claude/skills/herdr-orchestrate"
  H8="$TMP/home8"; mkdir -p "$H8/.claude/skills"; ln -s "$TMP/plugin-x/preflight" "$H8/.claude/skills/preflight"
  out=$(HOME="$H8" "$ROOT/install.sh" 2>&1; echo "exit=$?")
  assert_eq "install: another plugin's preflight is left alone" "$(readlink "$H8/.claude/skills/preflight")" "$TMP/plugin-x/preflight"
  assert_nomatch "install: ... and not reported as old layout" "$out" 'old layout'
  H6="$TMP/home6"; mkdir -p "$H6/.claude/skills"; ln -s "$ROOT" "$H6/.claude/skills/herdr-orchestrate"
  if read_only "$H6/.claude/skills"; then
  out=$(HOME="$H6" "$ROOT/install.sh" 2>&1; echo "exit=$?"); chmod 755 "$H6/.claude/skills"
  assert_match "install: an old link that cannot be removed is FAILED" "$out" "FAILED +rm $H6/.claude/skills/herdr-orchestrate"
  assert_nomatch "install: ... and not claimed removed" "$out" "removed +$H6/"
  assert_match "install: ... and the install fails"   "$out" 'exit=1$'
  else ok "install: (skipped: chmod does not bind here)"; fi
  # An old kit install: the phutschi plugin and its marketplace go, tower comes.
  H4="$TMP/home4"; mkdir -p "$H4"; printf 'marketplace phutschi\nplugin phutschi@phutschi user\nplugin phutschi@phutschi local\nmarketplace acme-tools\n' > "$CLAUDE_STUB_STATE"
  reset_stub; out=$(HOME="$H4" "$ROOT/install.sh" 2>&1; echo "exit=$?")
  assert_match "migrate: exit 0"                      "$out" 'exit=0$'
  assert_match "migrate: uninstalls phutschi@phutschi" "$(cat "$TMP/log")" '^claude plugin uninstall phutschi@phutschi --scope user$'
  assert_match "migrate: ... from every scope it is in" "$(cat "$TMP/log")" '^claude plugin uninstall phutschi@phutschi --scope local$'
  assert_match "migrate: removes the phutschi marketplace" "$(cat "$TMP/log")" '^claude plugin marketplace remove phutschi$'
  assert_eq "migrate: claude keeps others' marketplaces, and has tower instead of phutschi" "$(sort "$CLAUDE_STUB_STATE")" "$(printf 'marketplace acme-tools\nmarketplace phutschi-tower\nplugin tower@phutschi-tower user')"
  # tower installed in project scope only: updated there, not installed again.
  printf 'marketplace phutschi-tower\nplugin tower@phutschi-tower project\n' > "$CLAUDE_STUB_STATE"
  reset_stub; out=$(HOME="$H4" "$ROOT/install.sh" 2>&1; echo "exit=$?")
  assert_match "scopes: a project-only tower plugin installs fine" "$out" 'exit=0$'
  assert_match "scopes: ... is updated in its own scope" "$(cat "$TMP/log")" '^claude plugin update tower@phutschi-tower --scope project$'
  assert_nomatch "scopes: ... and not installed again"  "$(cat "$TMP/log")" '^claude plugin install '
  assert_eq "scopes: ... and claude has it in project scope only" "$(sort "$CLAUDE_STUB_STATE")" "$(printf 'marketplace phutschi-tower\nplugin tower@phutschi-tower project')"
  # A local install in another directory is that directory's business.
  printf 'marketplace phutschi-tower\nplugin tower@phutschi-tower local /elsewhere/acme\n' > "$CLAUDE_STUB_STATE"
  reset_stub; out=$(HOME="$H4" "$ROOT/install.sh" 2>&1; echo "exit=$?")
  assert_match "scopes: a local install elsewhere does not stop the install" "$out" 'exit=0$'
  assert_match "scopes: ... tower is installed for the user" "$(cat "$TMP/log")" '^claude plugin install tower@phutschi-tower$'
  assert_nomatch "scopes: ... and the other directory's install is left alone" "$(cat "$TMP/log")" '^claude plugin update '
  assert_eq "scopes: ... claude has both"               "$(sort "$CLAUDE_STUB_STATE")" "$(printf 'marketplace phutschi-tower\nplugin tower@phutschi-tower local /elsewhere/acme\nplugin tower@phutschi-tower user')"
  # A local install of this directory, named through a symlink, is here.
  ln -s "$PWD" "$TMP/here"
  printf 'marketplace phutschi-tower\nplugin tower@phutschi-tower local %s\n' "$TMP/here" > "$CLAUDE_STUB_STATE"
  reset_stub; out=$(HOME="$H4" "$ROOT/install.sh" 2>&1; echo "exit=$?")
  assert_match "scopes: a local install of this directory installs fine" "$out" 'exit=0$'
  assert_match "scopes: ... is updated there"           "$(cat "$TMP/log")" '^claude plugin update tower@phutschi-tower --scope local$'
  assert_eq "scopes: ... and claude still has it there" "$(sort "$CLAUDE_STUB_STATE")" "$(printf 'marketplace phutschi-tower\nplugin tower@phutschi-tower local %s' "$TMP/here")"
  assert_nomatch "scopes: ... and not installed again"   "$(cat "$TMP/log")" '^claude plugin install '
  # claude cannot say what is installed: the install fails and guesses nothing.
  for how in CLAUDE_STUB_FAIL=list "CLAUDE_STUB_FAIL=marketplace list" CLAUDE_STUB_GARBAGE=1 CLAUDE_STUB_GARBAGE=list; do
    printf 'marketplace phutschi\nplugin phutschi@phutschi user\n' > "$CLAUDE_STUB_STATE"
    reset_stub; out=$(env HOME="$H4" "$how" "$ROOT/install.sh" 2>&1; echo "exit=$?")
    assert_match "discover ($how): the failed list is named" "$out" 'FAILED +claude plugin (marketplace )?list --json'
    assert_match "discover ($how): ... and fails the install" "$out" 'exit=1$'
    assert_nomatch "discover ($how): ... and changes nothing in claude" "$(cat "$TMP/log")" '^claude plugin (install|uninstall|update|marketplace (add|remove|update)) '
  done
  : > "$CLAUDE_STUB_STATE"
  out=$(HOME="$H4" CLAUDE_STUB_FAIL=install "$ROOT/install.sh" 2>&1; echo "exit=$?")
  assert_match "install: a claude command that fails is named" "$out" 'FAILED +claude plugin install tower@phutschi-tower'
  assert_match "install: ... and fails the install"    "$out" 'exit=1$'
  H2="$TMP/home2"; mkdir -p "$H2"
  out=$(HOME="$H2" "$ROOT/install.sh" --check 2>&1; echo "exit=$?")
  assert_match "check: exit 0"                        "$out" 'exit=0$'
  [ -e "$H2/.agents/skills/orchestrate" ] && bad "check: links nothing" || ok "check: links nothing"
  # A PATH with everything the script needs except node.
  B="$TMP/bin"; mkdir -p "$B"; for t in git bash python3 dirname sed readlink mkdir ln cat tr grep; do ln -sf "$(command -v $t)" "$B/$t"; done
  out=$(HOME="$H2" PATH="$KIT/tests/stub:$B" "$ROOT/install.sh" --check 2>&1; echo "exit=$?")
  assert_match "check: a missing dependency is named"  "$out" 'MISSING +node'
  assert_match "check: a missing dependency fails"     "$out" 'exit=1$'
  out=$(HOME="$H2" TOWER_STUB=absent "$ROOT/install.sh" --check 2>&1; echo "exit=$?")
  assert_match "check: a tower that does not run is missing" "$out" 'MISSING +tower'
  assert_match "check: ... and fails"                  "$out" 'exit=1$'
  ln -sf "$KIT/tests/stub/herdr" "$B/herdr"; ln -sf "$(command -v node)" "$B/node"
  out=$(HOME="$H2" DRY_RUN=0 PATH="$B" "$ROOT/install.sh" --check 2>&1; echo "exit=$?")
  assert_match "check: no tower on PATH is missing"    "$out" 'MISSING +tower'
  assert_match "check: ... and fails"                  "$out" 'exit=1$'
  # The runner: herdr or orca on the PATH (only its presence is checked).
  O="$TMP/bin-orca"; mkdir -p "$O"; printf '#!/bin/sh\nexec "%s" "$@"\n' "$KIT/tests/stub/tower" > "$O/tower"; chmod +x "$O/tower"; ln -sf "$(command -v bun)" "$O/bun"
  ln -sf "$(command -v node)" "$O/node"; printf '#!/bin/sh\nexit 0\n' > "$O/orca"; chmod +x "$O/orca"
  rm "$B/herdr"; out=$(HOME="$H2" DRY_RUN=0 PATH="$O:$B" "$ROOT/install.sh" --check 2>&1; echo "exit=$?")
  assert_match "check: orca without herdr is a runner" "$out" '^  ok        orca$'
  assert_nomatch "check: ... herdr is then not missing" "$out" 'MISSING +herdr'
  assert_match "check: ... and passes"                 "$out" 'exit=0$'
  # Orca's CLI as Orca finds it: ORCA_CLI_COMMAND's value, else orca-ide, else orca.
  cp "$O/orca" "$O/orca-ide"; out=$(HOME="$H2" DRY_RUN=0 PATH="$O:$B" "$ROOT/install.sh" --check 2>&1)
  assert_match "check: orca-ide comes before a bare orca" "$out" '^  ok        orca-ide$'
  mkdir -p "$TMP/orca-app"; cp "$O/orca" "$TMP/orca-app/orca"
  out=$(HOME="$H2" DRY_RUN=0 ORCA_CLI_COMMAND="$TMP/orca-app/orca" PATH="$O:$B" "$ROOT/install.sh" --check 2>&1; echo "exit=$?")
  assert_match "check: ORCA_CLI_COMMAND's value comes before orca-ide" "$out" "^  ok        $TMP/orca-app/orca$"
  assert_match "check: ... and passes"                 "$out" 'exit=0$'
  out=$(HOME="$H2" DRY_RUN=0 ORCA_CLI_COMMAND="$TMP/orca-app/none" PATH="$O:$B" "$ROOT/install.sh" --check 2>&1; echo "exit=$?")
  assert_nomatch "check: an ORCA_CLI_COMMAND that does not exist: orca-ide or orca does not stand in" "$out" '^  ok        orca(-ide)?$'
  assert_match "check: ... the missing line names it"  "$out" "MISSING +herdr or $TMP/orca-app/none"
  assert_match "check: ... and fails"                  "$out" 'exit=1$'
  rm "$O/orca-ide" "$O/orca"; out=$(HOME="$H2" DRY_RUN=0 PATH="$O:$B" "$ROOT/install.sh" --check 2>&1; echo "exit=$?")
  assert_match "check: neither herdr nor orca is missing" "$out" 'MISSING +herdr or orca +the terminal this kit runs in'
  assert_match "check: ... and fails"                  "$out" 'exit=1$'
  : > "$CLAUDE_STUB_STATE"
  # tower missing: install.sh fetches the release binary for this version.
  # A fixture release, served over file://, and a fake uname (Linux x86_64).
  V=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/.claude-plugin/plugin.json")
  REL="$TMP/release"; mkdir -p "$REL/v$V"
  release() {  # the fixture binary and its SHA256SUMS
    printf '#!/bin/sh\necho "tower %s (fixture)"\n' "$V" > "$REL/v$V/tower-linux-x64"
    (cd "$REL/v$V" && if command -v sha256sum >/dev/null; then sha256sum tower-linux-x64; else shasum -a 256 tower-linux-x64; fi) > "$REL/v$V/SHA256SUMS"
  }
  release
  U="$TMP/uname"; mkdir -p "$U"
  printf '#!/bin/sh\ncase "$1" in -s) echo "${FAKE_OS:-Linux}" ;; -m) echo "${FAKE_ARCH:-x86_64}" ;; *) echo "${FAKE_OS:-Linux}" ;; esac\n' > "$U/uname"; chmod +x "$U/uname"
  fetch() {  # HOME BIN [VAR=VALUE...]: install.sh with tower not runnable
    local h=$1 bin=$2; shift 2
    env HOME="$h" TOWER_BIN_DIR="$bin" TOWER_RELEASE_URL="file://$REL" TOWER_STUB=absent PATH="$U:$PATH" "$@" "$ROOT/install.sh" 2>&1; echo "exit=$?"
  }
  H5="$TMP/home5"; BIN="$TMP/bin5"; mkdir -p "$H5"
  out=$(fetch "$H5" "$BIN")
  assert_match "fetch: exit 0"                          "$out" 'exit=0$'
  assert_eq "fetch: the release binary is installed and runs" "$("$BIN/tower" --help 2>&1)" "tower $V (fixture)"
  assert_match "fetch: says what it installed"          "$out" "tower-linux-x64 v$V"
  assert_match "fetch: ... and that tower now runs"      "$out" 'ok +tower$'
  assert_match "fetch: a tower that does not run, earlier on PATH, is named" "$out" "note +$KIT/tests/stub/tower comes first on your PATH"
  before=$(ls -l "$BIN")
  out=$(fetch "$H5" "$BIN")
  assert_match "fetch: a second run exits 0"            "$out" 'exit=0$'
  assert_nomatch "fetch: a second run fetches nothing"  "$out" 'tower-linux-x64'
  assert_eq "fetch: ... and leaves the binary as it is" "$(ls -l "$BIN")" "$before"
  BIN="$TMP/bin6"
  echo 'tampered' >> "$REL/v$V/tower-linux-x64"
  out=$(fetch "$H5" "$BIN")
  assert_match "fetch: a checksum mismatch is refused"  "$out" 'checksum'
  assert_match "fetch: ... and fails"                   "$out" 'exit=1$'
  assert_eq "fetch: ... and installs nothing"           "$(ls -A "$BIN" 2>/dev/null)" ""
  release; rm "$REL/v$V/SHA256SUMS"
  out=$(fetch "$H5" "$BIN")
  assert_match "fetch: a release without SHA256SUMS is refused" "$out" 'SHA256SUMS'
  assert_match "fetch: ... and fails"                   "$out" 'exit=1$'
  assert_eq "fetch: ... and installs nothing"           "$(ls -A "$BIN" 2>/dev/null)" ""
  release
  out=$(fetch "$H5" "$BIN" FAKE_OS=SunOS)
  assert_match "fetch: an unsupported platform is named" "$out" 'SunOS'
  assert_match "fetch: ... with the git install as the way" "$out" 'npm i(nstall)? -g github:phutschi/tower'
  assert_match "fetch: ... and fails"                   "$out" 'exit=1$'
  assert_eq "fetch: ... and installs nothing"           "$(ls -A "$BIN" 2>/dev/null)" ""
  B8="$TMP/bin8"; mkdir -p "$B8"; printf '#!/bin/sh\nexit 1\n' > "$B8/tower"; chmod +x "$B8/tower"
  out=$(fetch "$H5" "$B8")
  assert_match "fetch: a broken tower in the bin dir is moved aside" "$out" "moved +.*$B8/tower.old"
  assert_eq "fetch: ... kept as tower.old"              "$(cat "$B8/tower.old")" "$(printf '#!/bin/sh\nexit 1')"
  assert_eq "fetch: ... and replaced by the release binary" "$("$B8/tower" --help 2>&1)" "tower $V (fixture)"
  # Every download gives up on a server that stalls: a connect timeout and a
  # stall limit, and never a redirect to plain http. (A curl on PATH that logs
  # its arguments, then runs the real one.)
  REAL_CURL=$(command -v curl)
  fake_curl() { mkdir -p "$1"; printf '#!/bin/sh\n%s\n' "$2" > "$1/curl"; chmod +x "$1/curl"; }  # DIR BODY
  : > "$TMP/curl.log"
  fake_curl "$TMP/curlspy" "printf '%s\\n' \"\$*\" >> '$TMP/curl.log'; exec '$REAL_CURL' \"\$@\""
  out=$(fetch "$H5" "$TMP/bin10" PATH="$TMP/curlspy:$U:$PATH")
  assert_match "fetch: with the spy, tower is still fetched" "$out" 'exit=0$'
  assert_eq "fetch: both downloads (checksums and binary) go through curl" "$(wc -l < "$TMP/curl.log" | tr -d ' ')" 2
  assert_eq "fetch: each has a connect timeout, a stall limit and https-only redirects" \
    "$(grep -- '--proto-redir =https' "$TMP/curl.log" | grep -- '--connect-timeout 15' | grep -- '--speed-limit 1024' | grep -c -- '--speed-time 30')" 2
  # The checksums come; the binary's download then stalls (curl exit 28), or
  # is interrupted with Ctrl-C (SIGINT to the installer).
  real_for_sums="case \"\$*\" in
  *SHA256SUMS*) exec '$REAL_CURL' \"\$@\" ;;
esac"
  fake_curl "$TMP/curlstall" "$real_for_sums; exit 28"
  out=$(fetch "$H5" "$TMP/bin11" PATH="$TMP/curlstall:$U:$PATH")
  assert_match "fetch: a stalled download names curl's exit" "$out" 'could not download tower-linux-x64 .*curl exit 28'
  assert_match "fetch: ... and fails"                   "$out" 'exit=1$'
  assert_eq "fetch: ... and leaves no temp file"        "$(ls -A "$TMP/bin11" 2>/dev/null)" ""
  fake_curl "$TMP/curlint" "$real_for_sums; kill -INT \$PPID; sleep 1; exit 130"
  out=$(fetch "$H5" "$TMP/bin12" PATH="$TMP/curlint:$U:$PATH")
  assert_match "fetch: an interrupt stops the install"  "$out" 'exit=130$'
  assert_nomatch "fetch: ... before anything after the download" "$out" '^(dependencies|skills):'
  assert_eq "fetch: ... and leaves no temp file"        "$(ls -A "$TMP/bin12" 2>/dev/null)" ""
  # A release whose SHA256SUMS has no line for this platform: refused before
  # any binary is downloaded.
  NOSUM="$TMP/release-nosum"; mkdir -p "$NOSUM/v$V"; cp "$REL/v$V/tower-linux-x64" "$NOSUM/v$V/"
  echo "0000000000000000000000000000000000000000000000000000000000000000  tower-darwin-arm64" > "$NOSUM/v$V/SHA256SUMS"
  : > "$TMP/curl.log"
  out=$(fetch "$H5" "$TMP/bin13" TOWER_RELEASE_URL="file://$NOSUM" PATH="$TMP/curlspy:$U:$PATH")
  assert_match "fetch: no checksum for this platform is named" "$out" "release v$V has no checksum for tower-linux-x64"
  assert_match "fetch: ... with the git install as the way" "$out" 'npm i(nstall)? -g github:phutschi/tower'
  assert_match "fetch: ... and fails"                   "$out" 'exit=1$'
  assert_eq "fetch: ... requesting only the checksums" "$(grep -c . "$TMP/curl.log")|$(grep -c 'SHA256SUMS$' "$TMP/curl.log")" "1|1"
  assert_eq "fetch: ... and leaves nothing in the bin dir" "$(ls -A "$TMP/bin13" 2>/dev/null)" ""
  # A CRLF SHA256SUMS that lists the platform twice: the first line counts.
  CRLF="$TMP/release-crlf"; mkdir -p "$CRLF/v$V"; cp "$REL/v$V/tower-linux-x64" "$CRLF/v$V/"
  printf '%s  tower-linux-x64\r\n%s  tower-linux-x64\r\n' "$(awk '{print $1}' "$REL/v$V/SHA256SUMS")" \
    0000000000000000000000000000000000000000000000000000000000000000 > "$CRLF/v$V/SHA256SUMS"
  out=$(fetch "$H5" "$TMP/bin14" TOWER_RELEASE_URL="file://$CRLF")
  assert_match "fetch: a CRLF SHA256SUMS with the platform twice: installed" "$out" 'exit=0$'
  assert_eq "fetch: ... the binary verified by its first line" "$("$TMP/bin14/tower" --help 2>&1)" "tower $V (fixture)"
  out=$(fetch "$H5" "$TMP/bin9" TOWER_RELEASE_URL="file://$TMP/no-release")
  assert_match "fetch: a release that cannot be reached is named" "$out" "could not fetch .*SHA256SUMS"
  out=$(env HOME="$H5" TOWER_BIN_DIR="$TMP/bin7" TOWER_RELEASE_URL="file://$REL" PATH="$U:$PATH" "$ROOT/install.sh" 2>&1; echo "exit=$?")
  assert_eq "fetch: a tower that runs is left alone"    "$(ls -A "$TMP/bin7" 2>/dev/null)" ""
  unset CLAUDE_STUB_STATE
  # The git install (npm i -g github:phutschi/tower): npm runs prepare, which
  # builds with Node alone. A copy of the package, and a PATH without bun.
  P="$TMP/pkg"; mkdir -p "$P"
  for f in src themes scripts package.json tsconfig.json tsconfig.build.json; do [ -e "$ROOT/$f" ] && cp -R "$ROOT/$f" "$P/"; done
  # The node_modules Node would resolve from $ROOT: a worktree under
  # .worktrees/ has none of its own and uses the main checkout's.
  NM="$ROOT"; while [ "$NM" != / ] && [ ! -d "$NM/node_modules/typescript" ]; do NM=$(dirname "$NM"); done
  [ -d "$NM/node_modules/typescript" ] || echo "prepare: no node_modules with typescript above $ROOT; run bun install" >&2
  ln -s "$NM/node_modules" "$P/node_modules"
  NB="$TMP/nobun"; mkdir -p "$NB"; for t in node npm sh env dirname; do ln -sf "$(command -v $t)" "$NB/$t"; done
  PATH="$NB" command -v bun >/dev/null && bad "prepare: the PATH has no bun" || ok "prepare: the PATH has no bun"
  out=$(cd "$P" && HOME="$TMP/npmhome" PATH="$NB" npm_config_update_notifier=false npm run prepare 2>&1; echo "exit=$?")
  assert_match "prepare: builds with node alone"        "$out" 'exit=0$'
  [ -x "$P/dist/cli.js" ] && ok "prepare: dist/cli.js is executable" || bad "prepare: dist/cli.js is executable"
  out=$(PATH="$NB" "$P/dist/cli.js" --help 2>&1; echo "exit=$?")
  assert_match "prepare: the built tower runs with node" "$out" 'tower init'
  assert_match "prepare: ... and exits 0"               "$out" 'exit=0$'
  assert_nomatch "prepare: ... with no warning on stderr (Node >= 22.12)" "$out" 'ExperimentalWarning'
  mkdir -p "$P/dist/bin"; : > "$P/dist/bin/tower-linux-x64"; : > "$P/dist/bin/SHA256SUMS"  # what compile and the release leave
  packed=$(cd "$P" && HOME="$TMP/npmhome" npm_config_update_notifier=false npm pack --dry-run --json --ignore-scripts 2>/dev/null | python3 -c 'import json,sys; [print(f["path"]) for f in json.load(sys.stdin)[0]["files"]]')
  assert_match "pack: ships the built CLI"               "$packed" '^dist/cli\.js$'
  assert_match "pack: ... with its modules in subdirectories" "$packed" '^dist/commands/.+\.js$'
  assert_match "pack: ... and the built-in theme"         "$packed" '^themes/airport\.json$'
  assert_nomatch "pack: ... and no compiled binary or checksum" "$packed" '^dist/bin/'
  files=$(cd "$ROOT" && HOME="$TMP/npmhome" npm_config_update_notifier=false npm pack --dry-run --json --ignore-scripts 2>/dev/null | python3 -c 'import json,sys; [print(f["path"]) for f in json.load(sys.stdin)[0]["files"]]')
  assert_match "pack: ships the CLI"                     "$files" '^package\.json$'
  assert_nomatch "pack: ships no skill, test.sh or install.sh" "$files" '^(skills/|test\.sh$|install\.sh$)'
fi

# --- run ---------------------------------------------------------------------
# One whole run through the stubs: bootstrap, a codex lane B, a lane review per
# lane, a second round in R1, preflight in both slots, and the look runner, all
# on one fixture repo and one pane map.
if section run; then
  S="$HERDR_STUB_STATES_DIR"
  r=$(fixture_repo suite); git -C "$r" tag base; git -C "$r" checkout -qb feat
  printf 'a\n' > "$r/app.sh"; git -C "$r" add -A; git -C "$r" commit -qm change
  RUN="$TMP/run-whole"; reset_stub
  in_repo() { (cd "$r" && "$@" 2>&1); }
  in_repo "$KIT/bootstrap.sh" "$RUN" "Whole run" feat "$KIT/example-tasks.tsv" >/dev/null
  in_repo env EXECUTOR_KIND=codex "$KIT/add-lane.sh" "$RUN" B feat-b feat 2,3 >/dev/null
  review() { in_repo env EXIT_WAIT_SECONDS=0 "$KIT/add-reviewer.sh" "$RUN" "$@"; }
  review R1 claude "Lane review A, round 1" "$RUN/findings/lane-A-1.json" >/dev/null
  review R2 codex  "Lane review B, round 1" "$RUN/findings/lane-B-1.json" >/dev/null
  map=$(cat "$RUN/panes.txt")
  assert_match "run: the pane map has lane A"          "$map" '^lane A: +pane-[0-9]+ +\(agent "suite-lane-a", kind claude, '
  assert_match "run: the pane map has lane B on codex" "$map" '^lane B: +pane-[0-9]+ +\(agent "suite-lane-b", kind codex, '
  assert_match "run: the Reviewers are in the lanes tab's column"  "$map" '^lanes tab: +tab-[0-9]+ +\(R1 pane-[0-9]+, R2 pane-[0-9]+\)$'
  assert_match "run: lane A is reviewed by codex in R1" "$map" '^reviewer R1: .*kind codex, model gpt-6-astra, review "Lane review A, round 1"'
  assert_match "run: lane B is reviewed by claude in R2" "$map" '^reviewer R2: .*kind claude, model claude-opus-5-5, review "Lane review B, round 1"'
  r1=$(sed -nE 's/^lanes tab: .*\(R1 ([^,]+),.*/\1/p' "$RUN/panes.txt")

  echo gone > "$S/suite-r1-1"
  review R1 claude "Lane review A, round 2" "$RUN/findings/lane-A-2.json" >/dev/null
  assert_match "run: the second review in R1 is a new agent in the same slot" "$(cat "$HERDR_STUB_LOG")" "^herdr agent start suite-r1-2 --kind codex --pane $r1 "
  assert_match "run: the pane map shows the new R1 Reviewer in the same pane" "$(cat "$RUN/panes.txt")" "^reviewer R1: +$r1 +\\(agent \"suite-r1-2\", .*round 2"

  echo gone > "$S/suite-r1-2"; echo gone > "$S/suite-r2-1"
  review R1 claude "Preflight R1, round 1" "$RUN/findings/preflight/1/R1.json" >/dev/null
  review R2 codex  "Preflight R2, round 1" "$RUN/findings/preflight/1/R2.json" >/dev/null
  map=$(cat "$RUN/panes.txt")
  assert_match "run: preflight in a mixed run: R1 is a codex Reviewer" "$map" '^reviewer R1: .*kind codex, .*review "Preflight R1, round 1"'
  assert_match "run: preflight in a mixed run: R2 is a claude Reviewer" "$map" '^reviewer R2: .*kind claude, .*review "Preflight R2, round 1"'

  assert_eq "run: lane B owns its tasks on the board" "$(board "$RUN" '",".join(d["lanes"]["B"])')" "2,3"
  assert_eq "run: one board task per review, owned by its slot" \
    "$(board "$RUN" '"|".join(t["id"]+"@"+t["lane"]+":"+t["title"] for t in d["tasks"] if t["area"] == "review")')" \
    "R1-1@R1:Lane review A, round 1|R2-1@R2:Lane review B, round 1|R1-2@R1:Lane review A, round 2|R1-3@R1:Preflight R1, round 1|R2-2@R2:Preflight R2, round 1"

  export SUITE_ORDER="$TMP/run-suite-order"; : > "$SUITE_ORDER"
  # look's worktree dir must be outside /tmp and TMPDIR, where this run's
  # state dir is: one of its own (gitignored), as in the look section.
  out=$(in_repo env XDG_STATE_HOME="$LOOK_STATE/run-xdg" "$PREFLIGHT_DIR/look.sh" base "$RUN/findings/preflight/1")
  assert_match "run: look.sh names the findings file it wrote" "$out" "$RUN/findings/preflight/1/look.json"
  steps=$(python3 -c "import json,sys; print(' '.join(v['step']+':'+v['status'] for v in json.load(open(sys.argv[1]))['verdict']))" "$RUN/findings/preflight/1/look.json" 2>&1)
  assert_eq "run: look.json has a row for the base, each scanner, the shortcuts and every suite step" "$steps" "base:skip semgrep:pass gitleaks:pass shortcuts:pass lint:skip test:fail build:pass"
  unset SUITE_ORDER

  assert_eq "run: one switches line in the pane map" "$(grep -c '^switches:' "$RUN/panes.txt")" 1
  assert_eq "run: one reviewer line in the pane map" "$(grep -c '^reviewer:' "$RUN/panes.txt")" 1
  assert_eq "run: one switches note in the record"   "$(notes "$RUN" | grep -c '^switches:')" 1
  assert_eq "run: one reviewer note in the record"   "$(notes "$RUN" | grep -c '^reviewer:')" 1
  unset -f in_repo review
fi

# --- roles -------------------------------------------------------------------
if section roles; then
  S="$HERDR_STUB_STATES_DIR"
  PLAN="$TMP/roles-plan.md"
  cat > "$PLAN" <<'EOF'
---
repo: acme
branch: feature/widgets
---

# Widgets for acme

## Repo conventions every task must follow

Role: Not A Role!

## Tasks

### Task 1: The widget model

**Delivers:** a widget.

### Task 2: Ship-to fix for the widget export pipeline

**Role:** data

### Task 3: Research the widget API

Role: code-research

```md
### Task 9: a sample inside a fence
Role: Bad!
```

### Task 4: A widget can be renamed

### Task 5: Mixed one

Role: data

### Task 6: Mixed two

- **Role**: `web-research`
EOF
  boot() { (cd "$1" && shift && "$KIT/bootstrap.sh" "$@" 2>&1; echo "exit=$?"); }

  # Without the launcher: as before roles, with one note.
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-roles-off"; reset_stub
  out=$(boot "$r" "$RUN" "Roles off" main "$PLAN")
  assert_match "no launcher: bootstrap runs" "$out" 'exit=0$'
  assert_match "no launcher: lane A starts as before" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-lane-a --kind claude --pane pane-3 -- --model claude-opus-5-5\[1m\]$'
  assert_eq "no launcher: one roles note" "$(notes "$RUN" | grep -c '^roles: ')" 1
  assert_match "no launcher: the note says roles are off, and why" "$(notes "$RUN")" '^roles: off \(no Claude launcher: CLAUDE_ROUTER_ROLE is not set and claude takes no --role\)$'
  assert_match "no launcher: the pane map says so" "$(cat "$RUN/panes.txt")" '^roles: +off \(no Claude launcher'
  assert_match "no launcher: the lane A line is as before" "$(cat "$RUN/panes.txt")" '^lane A: +pane-3 +\(agent "bun-vitest-lane-a", kind claude, branch main, '
  assert_match "no launcher: lane A of a plan naming Role data is in the lanes tab" "$(cat "$RUN/panes.txt")" '^lane A: .*, tab lanes\)$'
  assert_eq "no launcher: no roles file" "$([ -e "$RUN/roles.tsv" ] && echo made || echo none)" none
  assert_nomatch "no launcher: no research tab opened" "$(cat "$HERDR_STUB_LOG")" '(--label|--tab-label) research( |$)'
  reset_stub; (cd "$r" && "$KIT/add-lane.sh" "$RUN" B feat/b main 5,6 >/dev/null 2>&1)
  assert_match "no launcher: a lane with mixed Roles starts as before" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-lane-b --kind claude --pane pane-[0-9]+ -- --model [^ ]+$'
  assert_match "no launcher: ... in the lanes tab"   "$(cat "$RUN/panes.txt")" '^lane B: .*, tab lanes\)$'
  assert_nomatch "no launcher: ... no research tab opened" "$(cat "$HERDR_STUB_LOG")" '(--label|--tab-label) research( |$)'
  assert_nomatch "no launcher: no research tab line" "$(cat "$RUN/panes.txt")" '^research tab:'
  reset_stub; (cd "$r" && REVIEW_STAGE=preflight "$KIT/add-reviewer.sh" "$RUN" R1 claude "Preflight R1" "$RUN/findings/p1.json" >/dev/null 2>&1)
  assert_match "no launcher: a claude Reviewer starts as before" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-r1-1 --kind claude --pane pane-[0-9]+ -- --model [^ ]+$'

  # The launcher there, and this session not an orchestrator: refused first.
  for who in CLAUDE_ROUTER_ROLE=code CLAUDE_STUB_ROLE=1; do
    r=$(fixture_repo bun-vitest); RUN="$TMP/run-roles-${who%%=*}"; reset_stub
    out=$(env "$who" bash -c 'cd "$1" && shift && "$KIT/bootstrap.sh" "$@" 2>&1; echo "exit=$?"' _ "$r" "$RUN" "Not orch" main "$PLAN")
    assert_match "not an orchestrator ($who): refused, saying how to start one" "$out" 'orchestrate runs only in an orchestrator session.*claude --role orchestrator'
    assert_match "not an orchestrator ($who): ... and fails" "$out" 'exit=1$'
    assert_eq "not an orchestrator ($who): no run dir" "$([ -e "$RUN" ] && echo made || echo none)" none
    assert_nomatch "not an orchestrator ($who): no pane, no agent" "$(cat "$HERDR_STUB_LOG")" '^herdr (pane|agent|tab|worktree) '
  done
  assert_match "not an orchestrator: the message names this session's role" "$(cd "$r" && CLAUDE_ROUTER_ROLE=code "$KIT/bootstrap.sh" "$TMP/run-roles-x" "x" main 2>&1)" 'this one is code'

  # An orchestrator session: every claude session gets a role and a topic.
  export CLAUDE_ROUTER_ROLE=orchestrator
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-roles"; reset_stub
  out=$(LANES="A=1,4 B=2 C=3" boot "$r" "$RUN" "Roles" main "$PLAN")
  assert_match "orchestrator: bootstrap runs" "$out" 'exit=0$'
  assert_match "lane A: tasks naming no Role run as code, topic from the first task" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-lane-a --kind claude --pane pane-3 -- --model claude-opus-5-5\[1m\] --role code --topic a-the-widget-model$'
  map=$(cat "$RUN/panes.txt")
  assert_match "pane map: lane A's role and topic" "$map" '^lane A: +pane-3 +\(agent "bun-vitest-lane-a", kind claude, role code, topic a-the-widget-model, branch main, checkout '"$r"', model '
  assert_match "pane map: roles on" "$map" '^roles: +on$'
  assert_match "record: roles on" "$(notes "$RUN")" '^roles: on$'
  assert_eq "roles file: the plan's tasks with a Role, fences and other sections left out" "$(tr '\t\n' ': ' < "$RUN/roles.tsv")" "2:data 3:code-research 5:data 6:web-research "
  assert_nomatch "lane A in code, no other lane yet: no research tab opened" "$(cat "$HERDR_STUB_LOG")" '(--label|--tab-label) research( |$)'
  assert_nomatch "lane A in code, no other lane yet: no research tab line" "$map" '^research tab:'
  lane() { (cd "$r" && "$KIT/add-lane.sh" "$RUN" "$@" 2>&1); }
  reset_stub; lane B feat/b main 2 >/dev/null
  assert_match "lane B: its task's Role, a long title cut at a word" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-lane-b --kind claude --pane pane-[0-9]+ -- --model [^ ]+ --role data --topic b-ship-to-fix-for-the$'
  assert_match "pane map: lane B's role and topic" "$(cat "$RUN/panes.txt")" '^lane B: .*kind claude, role data, topic b-ship-to-fix-for-the, branch feat/b, '
  assert_match "a data lane, no research tab yet: its pane moves into a new one, unfocused" "$(cat "$HERDR_STUB_LOG")" '^herdr pane move pane-[0-9]+ --new-tab --workspace ws-0 --tab-label research --no-focus$'
  bpane=$(sed -nE 's/^lane B: +([^ ]+).*/\1/p' "$RUN/panes.txt")
  assert_match "a data lane: the research tab line" "$(cat "$RUN/panes.txt")" "^research tab: +tab-${bpane#pane-}\$"
  assert_match "a data lane: its line ends with tab research" "$(cat "$RUN/panes.txt")" '^lane B: .*, tab research\)$'
  assert_nomatch "a data lane: no Reviewer column in the research tab" "$(cat "$HERDR_STUB_LOG")" '^herdr pane split '
  # A rerun keeps the topic the lane started with, though its task was renamed.
  TOWER_RUN="$RUN" "$KIT/tests/stub/tower" change 2 --title "Something else entirely" >/dev/null
  echo gone > "$S/bun-vitest-lane-b"; mkwt "$r" feat/b   # the stub makes no worktree
  reset_stub; out=$(lane B feat/b main 2; echo "exit=$?")
  assert_match "rerun after a rename: the lane starts again" "$out" 'exit=0$'
  assert_match "rerun after a rename: ... under its first topic" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-lane-b .* --role data --topic b-ship-to-fix-for-the$'
  reset_stub; lane C feat/c main 3 >/dev/null
  assert_match "lane C: code-research" "$(cat "$HERDR_STUB_LOG")" ' --role code-research --topic c-research-the-widget-api$'
  assert_match "lane C, another role: right of lane B in the research tab, lane A not counted" "$(cat "$HERDR_STUB_LOG")" "^herdr pane move pane-[0-9]+ --tab tab-${bpane#pane-} --split right --target-pane $bpane "
  reset_stub; out=$(lane D feat/d main 5,6; echo "exit=$?")
  assert_match "mixed Roles in a lane: refused, naming them" "$out" "lane D's tasks 5,6 name different Roles \(data: task 5; web-research: task 6\)"
  assert_match "mixed Roles in a lane: ... and fails" "$out" 'exit=1$'
  assert_nomatch "mixed Roles in a lane: no worktree" "$(cat "$HERDR_STUB_LOG")" '^herdr worktree create'
  assert_eq "mixed Roles in a lane: nothing assigned" "$(board "$RUN" '"D" in d["lanes"]')" False
  reset_stub; (cd "$r" && EXECUTOR_KIND=codex "$KIT/add-lane.sh" "$RUN" D feat/d main 5 >/dev/null 2>&1)
  assert_match "a codex lane: no role" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-lane-d --kind codex '
  assert_nomatch "a codex lane: ... no role, no topic" "$(cat "$HERDR_STUB_LOG")" '--role|--topic'
  assert_match "pane map: a codex lane's line has no role" "$(cat "$RUN/panes.txt")" '^lane D: .*kind codex, branch feat/d, '
  assert_match "a codex lane whose tasks name data: under lane B in the research tab" "$(cat "$HERDR_STUB_LOG")" "^herdr pane move pane-[0-9]+ --tab tab-${bpane#pane-} --split down --target-pane $bpane "
  assert_match "a codex lane in data: its line ends with tab research" "$(cat "$RUN/panes.txt")" '^lane D: .*, tab research\)$'
  review() { (cd "$r" && "$KIT/add-reviewer.sh" "$RUN" "$@" 2>&1); }
  reset_stub; REVIEW_STAGE=preflight review R1 claude "Preflight R1" "$RUN/findings/p1.json" >/dev/null
  assert_match "preflight slot: review, topic the slot" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-r1-1 --kind claude --pane pane-[0-9]+ -- --model [^ ]+ --role review --topic r1$'
  reset_stub; review R2 codex "Lane review D" "$RUN/findings/d.json" D >/dev/null
  assert_match "lane review by claude: review, topic the slot" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-r2-1 --kind claude --pane pane-[0-9]+ -- --model [^ ]+ --role review --topic r2$'
  echo gone > "$S/bun-vitest-r1-1"
  reset_stub; review R1 claude "Lane review A" "$RUN/findings/a.json" A >/dev/null
  assert_match "a codex Reviewer: no role" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-r1-2 --kind codex '
  assert_nomatch "a codex Reviewer: ... no role, no topic" "$(cat "$HERDR_STUB_LOG")" '--role|--topic'

  # Lane A in a role its tasks name; a lane that mixes them refused at bootstrap.
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-roles-a2"; reset_stub
  LANES="A=2" boot "$r" "$RUN" "Roles A" main "$PLAN" >/dev/null
  assert_match "lane A: its tasks' Role" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-lane-a .* --role data --topic a-ship-to-fix-for-the$'
  assert_match "lane A in data: the research tab, unfocused, lane A its root" "$(cat "$HERDR_STUB_LOG")" "^herdr tab create --workspace ws-0 --cwd $r --label research --no-focus$"
  assert_match "lane A in data: ... started there" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-lane-a --kind claude --pane pane-3 '
  assert_nomatch "lane A in data: no lanes tab, no Reviewer column" "$(cat "$HERDR_STUB_LOG")" '--label lanes|^herdr pane split --pane pane-3 '
  assert_match "lane A in data: the research tab line" "$(cat "$RUN/panes.txt")" '^research tab: +tab-3$'
  assert_nomatch "lane A in data: no lanes tab line" "$(cat "$RUN/panes.txt")" '^lanes tab:'
  assert_match "lane A in data: its line ends with tab research" "$(cat "$RUN/panes.txt")" '^lane A: +pane-3 .*, tab research\)$'
  # A code lane with lane A in research and no lanes tab: the lanes tab opens
  # with it as root, and the Reviewer column.
  reset_stub; (cd "$r" && "$KIT/add-lane.sh" "$RUN" B feat/b main 1 >/dev/null 2>&1); log=$(cat "$HERDR_STUB_LOG")
  assert_match "a code lane, no lanes tab yet: its pane moves into a new one" "$log" '^herdr pane move pane-[0-9]+ --new-tab --workspace ws-0 --tab-label lanes --no-focus$'
  bpane=$(sed -nE 's/^lane B: +([^ ]+).*/\1/p' "$RUN/panes.txt")
  assert_match "a code lane, no lanes tab yet: the Reviewer column right of it" "$log" "^herdr pane split --pane $bpane --direction right --ratio 0.67 --cwd $r --no-focus$"
  assert_match "a code lane, no lanes tab yet: the lanes tab line" "$(cat "$RUN/panes.txt")" "^lanes tab: +tab-${bpane#pane-} +\\(R1 pane-[0-9]+, R2 pane-[0-9]+\\)$"
  assert_match "a code lane: its line ends with tab lanes" "$(cat "$RUN/panes.txt")" '^lane B: .*, tab lanes\)$'
  # The column follows the run's switches (the pane map), not add-lane's own
  # environment; a data lane whose move into a new tab fails stays unplaced,
  # and a rerun opens the tab.
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-roles-a2-off"; reset_stub
  LANES="A=2" LANE_REVIEW=off PREFLIGHT=off boot "$r" "$RUN" "Roles A off" main "$PLAN" >/dev/null
  reset_stub; (cd "$r" && "$KIT/add-lane.sh" "$RUN" B feat/b main 1 >/dev/null 2>&1)
  assert_match "a code lane opening the lanes tab: no column when the run's switches say so" "$(cat "$RUN/panes.txt")" '^lanes tab: +tab-[0-9]+ +\(no Reviewer column\)$'
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-roles-movefail"; reset_stub
  LANES="A=1" boot "$r" "$RUN" "Move fail" main "$PLAN" >/dev/null
  reset_stub; out=$(cd "$r" && HERDR_STUB_MOVE_FAIL=1 "$KIT/add-lane.sh" "$RUN" B feat/b main 2 2>&1; echo "exit=$?")
  assert_match "a data lane, its move into a new tab failing: fails" "$out" 'exit=1$'
  assert_match "... saying a rerun places it"          "$out" "rerun  .*/add-lane\.sh .* B feat/b main 2  to place it"
  assert_match "... the lane stays unplaced"           "$(cat "$RUN/panes.txt")" '^unplaced lane B: '
  assert_nomatch "... no research tab line"            "$(cat "$RUN/panes.txt")" '^research tab:'
  mkwt "$r" feat/b
  reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUN" B feat/b main 2 2>&1; echo "exit=$?")
  assert_match "... a rerun places it"                 "$out" 'exit=0$'
  assert_match "... a rerun opens the research tab"    "$(cat "$HERDR_STUB_LOG")" '^herdr pane move pane-[0-9]+ --new-tab --workspace ws-0 --tab-label research --no-focus$'
  assert_match "... and writes its line"               "$(cat "$RUN/panes.txt")" '^research tab: +tab-[0-9]+$'
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-roles-tabwrite"; reset_stub
  LANES="A=1" boot "$r" "$RUN" "Tab write" main "$PLAN" >/dev/null
  reset_stub; out=$(cd "$r" && HERDR_STUB_NEW_TAB_LOCKS="$RUN/panes.txt" "$KIT/add-lane.sh" "$RUN" B feat/b main 2 2>&1; echo "exit=$?")
  chmod u+w "$RUN/panes.txt"
  assert_match "a data lane, its research tab line not written: fails" "$out" 'exit=1$'
  assert_match "... naming the moved pane and its tab, to add by hand" "$out" "moved pane pane-[0-9]+ into a new research tab tab-[0-9]+ as pane-[0-9]+, but could not write $RUN/panes.txt; its line:  research tab: +tab-[0-9]+$"
  assert_match "... and the lane's repair steps"      "$out" "^add-lane: lane B's pane pane-[0-9]+ did not get a research tab .* unplaced lane B: pane-[0-9]+  in $RUN/panes.txt into  lane B: <its pane's id> .*add its tab line"
  assert_nomatch "... no agent started"               "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-lane-b '
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-roles-a2-codex"; reset_stub
  LANES="A=2" EXECUTOR_KIND=codex boot "$r" "$RUN" "Roles A codex" main "$PLAN" >/dev/null
  assert_match "a codex lane A in data: the research tab too" "$(cat "$RUN/panes.txt")" '^lane A: .*kind codex, .*, tab research\)$'
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-roles-mixed"; reset_stub
  out=$(LANES="A=1,2 B=5-6" boot "$r" "$RUN" "Mixed" main "$PLAN")
  assert_match "bootstrap: a LANES spec with mixed Roles is refused" "$out" "LANES: lane B's tasks 5-6 name different Roles \(data: task 5; web-research: task 6\)"
  assert_match "bootstrap: ... and fails" "$out" 'exit=1$'
  assert_eq "bootstrap: ... before the run exists" "$([ -e "$RUN" ] && echo made || echo none)" none
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-roles-all"; reset_stub
  out=$(boot "$r" "$RUN" "All" main "$PLAN")
  assert_match "bootstrap: A=all with mixed Roles is refused" "$out" "LANES: lane A's tasks all name different Roles"
  bad_plan="$TMP/roles-bad.md"; printf '# Bad\n\n### Task 1: One\n\nRole: Data!\n' > "$bad_plan"
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-roles-bad"; reset_stub
  out=$(boot "$r" "$RUN" "Bad" main "$bad_plan")
  assert_match "a Role that is not a role name: refused, naming the task" "$out" "plan: task 1's Role 'Data!' is not a role name"
  assert_eq "a Role that is not a role name: no run dir" "$([ -e "$RUN" ] && echo made || echo none)" none
  twice="$TMP/roles-twice.md"; printf '# Twice\n\n### Task 1: One\n\nRole: data\nRole: code\n' > "$twice"
  assert_match "a task with two Roles: refused" "$(boot "$(fixture_repo bun-vitest)" "$TMP/run-roles-twice" "Twice" main "$twice")" 'plan: task 1 names a Role twice \(data, code\)'

  # No plan: lane A is code; a task file names no roles.
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-roles-empty"; reset_stub
  boot "$r" "$RUN" "Empty" main >/dev/null
  assert_match "empty opening: lane A is code, topic its letter" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-lane-a .* --role code --topic a$'
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-roles-tsv"; reset_stub
  boot "$r" "$RUN" "TSV" main "$KIT/example-tasks.tsv" >/dev/null
  assert_match "task file: lane A is code" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start bun-vitest-lane-a .* --role code --topic a-[a-z0-9-]+$'
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-roles-codex"; reset_stub
  EXECUTOR_KIND=codex boot "$r" "$RUN" "Codex" main "$KIT/example-tasks.tsv" >/dev/null
  assert_nomatch "a codex lane A: no role, no topic" "$(cat "$HERDR_STUB_LOG")" '--role|--topic'
  assert_match "a codex lane A: roles are still on" "$(cat "$RUN/panes.txt")" '^roles: +on$'
  unset CLAUDE_ROUTER_ROLE
fi

# --- fake-orca ---------------------------------------------------------------
# The fake orca itself (tests/stub/orca): what the Orca sections rely on.
if section fake-orca; then
  o() { in_kit "orca $*"; }
  reset_stub
  out=$(o terminal create --worktree active --title lane-a --command claude --json)
  assert_match "fake orca: logs argv" "$(cat "$ORCA_STUB_LOG")" '^orca terminal create --worktree active --title lane-a --command claude --json$'
  assert_match "fake orca: terminal create answers a handle" "$out" '"handle": *"term-1"'
  assert_match "fake orca: ... and its tab" "$out" '"tabId": *"tab-1"'
  assert_match "fake orca: handles count up" "$(o terminal split --terminal term-1 --direction horizontal --command sh --json)" '"handle": *"term-2"'
  assert_match "fake orca: ... a split stays in the tab it splits" "$(o terminal split --terminal term-1 --direction horizontal --json)" '"tabId": *"tab-1"'
  reset_stub
  assert_match "fake orca: ... per test (reset_stub)" "$(o terminal create --json)" '"handle": *"term-1"'
  assert_match "fake orca: ok on success" "$(o terminal create --json)" '"ok": *true'
  # Without ORCA_STUB_COUNTER its state is in a directory of its own, never
  # a shared name in TMPDIR; a DRY_RUN script gives its calls one such dir.
  mkdir -p "$TMP/stub-tmp"
  out=$(env -u ORCA_STUB_COUNTER TMPDIR="$TMP/stub-tmp" "$KIT/tests/stub/orca" terminal create --json)
  assert_match "fake orca, no counter: still answers" "$out" '"handle": *"term-1"'
  assert_eq "fake orca, no counter: leaves nothing in TMPDIR" "$(ls -A "$TMP/stub-tmp")" ""
  c=$(env -u ORCA_STUB_COUNTER TMPDIR="$TMP/stub-tmp" RUNNER=orca bash -c '. "$KIT/common.sh"; echo "$ORCA_STUB_COUNTER"')
  assert_match "DRY_RUN, no counter: the fake's state in a new dir of its own" "$c" '/tmp\.[^/]+/orca-counter$'
  assert_eq "DRY_RUN, no counter: ... only its owner can enter" "$(stat -c %a "$(dirname "$c")" 2>/dev/null || stat -f %Lp "$(dirname "$c")")" 700
  # A run's scripts share one private state folder, beside its run dir: a
  # dry-run bootstrap, then its printed send-brief, see the same terminals.
  dr=$(fixture_repo bun-vitest); DRUN="$TMP/run-dry-chain"
  (cd "$dr" && env -u ORCA_STUB_COUNTER -u ORCA_STUB_STATES_DIR RUNNER=orca "$KIT/bootstrap.sh" "$DRUN" "Dry chain" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
  echo "Do task 1." > "$DRUN/brief-A.md"
  out=$(cd "$dr" && env -u ORCA_STUB_COUNTER -u ORCA_STUB_STATES_DIR RUNNER=orca "$KIT/send-brief.sh" "$DRUN" bun-vitest-lane-a "$DRUN/brief-A.md" 2>&1; echo "exit=$?")
  assert_match "DRY_RUN, a run's scripts: send-brief finds bootstrap's terminal" "$out" 'sent to bun-vitest-lane-a in term-3'
  out=$(cd "$dr" && env -u ORCA_STUB_COUNTER -u ORCA_STUB_STATES_DIR RUNNER=orca "$KIT/bind-pane.sh" "$DRUN" bun-vitest-lane-a term-3 2>&1; echo "exit=$?")
  assert_match "DRY_RUN, a run's scripts: bind-pane finds bootstrap's terminal" "$out" 'recorded bun-vitest-lane-a in term-3'
  sd="$(cd "$(dirname "$DRUN")" && pwd -P)/.$(basename "$DRUN").orca-stub"
  assert_eq "DRY_RUN, a run's scripts: their state folder beside the run dir, private" "$(stat -c %a "$sd" 2>/dev/null || stat -f %Lp "$sd")" 700
  # A run dir in a parent not made yet works; a state folder that is a link
  # is refused.
  dr2=$(fixture_repo bun-vitest)
  out=$(cd "$dr2" && env -u ORCA_STUB_COUNTER -u ORCA_STUB_STATES_DIR RUNNER=orca "$KIT/bootstrap.sh" "$TMP/new-runs/r1" "Dry new" main "$KIT/example-tasks.tsv" 2>&1; echo "exit=$?")
  assert_match "DRY_RUN, a run dir whose parent is new: bootstrap finishes" "$out" 'exit=0$'
  mkdir -p "$TMP/elsewhere-state"; ln -s "$TMP/elsewhere-state" "$(cd "$TMP" && pwd -P)/.run-link.orca-stub"
  out=$(cd "$dr" && env -u ORCA_STUB_COUNTER -u ORCA_STUB_STATES_DIR RUNNER=orca "$KIT/send-brief.sh" "$TMP/run-link" bun-vitest-lane-a "$DRUN/brief-A.md" 2>&1; echo "exit=$?")
  assert_match "DRY_RUN, a state folder that is a link: refused" "$out" "is not a private dir of yours"
  # Workspaces: the caller's, and child worktrees that record their parent.
  assert_match "fake orca: worktree current names the caller's workspace" "$(o worktree current --json)" "\"id\": *\"repo-0::$(pwd -P)\""
  reset_stub
  out=$(o worktree create --name acme-lane-b --branch feat/b --base-branch feat/a --parent-worktree id:repo-0::/work/acme --json)
  assert_match "fake orca: worktree create answers an id" "$out" '"id": *"repo-0::/orca-stub/worktrees/wt-1"'
  assert_match "fake orca: ... and its path" "$out" '"path": *"/orca-stub/worktrees/wt-1"'
  assert_match "fake orca: worktree ids count up" "$(o worktree create --name acme-lane-c --parent-worktree active --json)" '"id": *"repo-0::/orca-stub/worktrees/wt-2"'
  out=$(o worktree show --worktree id:repo-0::/orca-stub/worktrees/wt-1 --json)
  assert_match "fake orca: worktree show reports the parent it was given" "$out" '"parentWorktreeId": *"repo-0::/work/acme"'
  assert_match "fake orca: ... its name" "$out" '"displayName": *"acme-lane-b"'
  assert_match "fake orca: ... its branch" "$out" '"branch": *"feat/b"'
  assert_match "fake orca: --parent-worktree active is the caller's workspace" "$(o worktree show --worktree id:repo-0::/orca-stub/worktrees/wt-2 --json)" "\"parentWorktreeId\": *\"repo-0::$(pwd -P)\""
  o worktree create --name acme-lane-d --json >/dev/null
  assert_match "fake orca: a worktree with no parent reports null" "$(o worktree show --worktree id:repo-0::/orca-stub/worktrees/wt-3 --json)" '"parentWorktreeId": *null'
  out=$(o terminal create --title "'lane \"a\"'" --json)
  assert_eq "fake orca: free text is valid JSON" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["terminal"]["title"])')" 'lane "a"'
  out=$(ORCA_STUB_WORKTREE_FAIL=1 o worktree create --name x --json; echo "exit=$?")
  assert_match "fake orca: ORCA_STUB_WORKTREE_FAIL=1: create fails" "$out" '"code": *"runtime_unavailable"'
  assert_match "fake orca: ... exit 1" "$out" 'exit=1$'
  assert_eq "fake orca: ORCA_STUB_WORKTREE_FAIL=garbled: no worktree in the answer" "$(ORCA_STUB_WORKTREE_FAIL=garbled o worktree create --name x --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"])')" '{}'
  out=$(o worktree show --worktree id:repo-0::/nowhere --json; echo "exit=$?")
  assert_match "fake orca: an unknown worktree is an error" "$out" '"code": *"selector_not_found"'
  assert_match "fake orca: ... exit 1" "$out" 'exit=1$'
  # Agent states, per terminal handle, from ORCA_STUB_STATES_DIR.
  reset_stub; o terminal create --title lane-a --json >/dev/null; o terminal create --title lane-b --json >/dev/null
  st="$ORCA_STUB_STATES_DIR"; rm -f "$st"/term-*
  state() { in_kit "orca agent list --json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(' '.join(a['state'] for a in d['result']['agents'] if a['paneKey'] == 'tab-$1:leaf-$1') or 'none')"; }
  assert_eq "fake orca: an agent with no state file is working" "$(state 1)" working
  for w in waiting blocked done; do
    echo "$w" > "$st/term-1"; assert_eq "fake orca: state $w" "$(state 1)" "$w"
  done
  printf 'working\nwaiting\n' > "$st/term-1"
  assert_eq "fake orca: several lines: the first, then dropped" "$(state 1) $(state 1) $(state 1)" "working waiting waiting"
  echo unlisted > "$st/term-2"; assert_eq "fake orca: an unlisted agent is not listed" "$(state 2)" none
  assert_match "fake orca: ... and its busy TUI leaves a wait unsatisfied" "$(o terminal wait --terminal term-2 --for tui-idle --timeout-ms 1 --json)" '"satisfied": *false'
  echo unlisted-waitfail > "$st/term-2"; assert_eq "fake orca: unlisted-waitfail is not listed" "$(state 2)" none
  out=$(o terminal wait --terminal term-2 --for tui-idle --timeout-ms 1 --json; echo "exit=$?")
  assert_match "fake orca: ... and its wait fails, an RPC error" "$out" '"code": *"runtime_unavailable"'
  assert_match "fake orca: ... exit 1" "$out" 'exit=1$'
  echo unlisted-idle > "$st/term-2"; assert_eq "fake orca: unlisted-idle is not listed either" "$(state 2)" none
  assert_match "fake orca: ... but its idle TUI satisfies a wait" "$(o terminal wait --terminal term-2 --for tui-idle --timeout-ms 1 --json)" '"satisfied": *true'
  echo gone > "$st/term-2"
  assert_eq "fake orca: a gone agent is not listed" "$(state 2)" none
  out=$(o terminal read --terminal term-2 --json; echo "exit=$?")
  assert_match "fake orca: a gone terminal is a stale handle" "$out" '"code": *"terminal_handle_stale"'
  assert_match "fake orca: ... exit 1" "$out" 'exit=1$'
  echo unreadable > "$st/term-2"
  out=$(o agent list --json; echo "exit=$?")
  assert_match "fake orca: unreadable: Orca does not answer" "$out" '"code": *"runtime_unavailable"'
  assert_match "fake orca: ... exit 1" "$out" 'exit=1$'
  assert_match "fake orca: ... for a terminal too" "$(o terminal read --terminal term-2 --json)" '"code": *"runtime_unavailable"'
  rm -f "$st/term-2"
  assert_match "fake orca: terminal show names its tab and leaf" "$(o terminal show --terminal term-2 --json)" '"leafId": *"leaf-2"'
  # The terminal's tail.
  printf 'line one\nREADY "quoted"\n' > "$st/term-1.tail"
  out=$(o terminal read --terminal term-1 --json)
  assert_eq "fake orca: terminal read answers the tail file" "$(printf '%s' "$out" | python3 -c 'import json,sys; print("|".join(json.load(sys.stdin)["result"]["terminal"]["tail"]))')" 'line one|READY "quoted"'
  # A trust menu refuses a text-plus-Enter send; separate sends answer it.
  echo trust > "$st/term-1"
  assert_eq "fake orca: a trust menu shows as blocked" "$(state 1)" blocked
  out=$(o terminal send --terminal term-1 --text '"hello"' --enter --json; echo "exit=$?")
  assert_match "fake orca: a trust menu refuses text plus Enter" "$out" '"code": *"agent_prompt_blocked"'
  assert_match "fake orca: ... exit 1" "$out" 'exit=1$'
  assert_match "fake orca: ... text alone is accepted" "$(o terminal send --terminal term-1 --text 1 --json)" '"accepted": *true'
  assert_eq "fake orca: ... and leaves the menu" "$(state 1)" blocked
  o terminal send --terminal term-1 --enter --json >/dev/null
  assert_eq "fake orca: ... Enter alone answers it" "$(state 1)" working
  assert_match "fake orca: then text plus Enter is accepted" "$(o terminal send --terminal term-1 --text '"go"' --enter --json)" '"accepted": *true'
  # Waiting for an agent, and closing its terminal.
  echo waiting > "$st/term-1"
  assert_match "fake orca: terminal wait --for tui-idle: an idle agent satisfies it" "$(o terminal wait --terminal term-1 --for tui-idle --timeout-ms 1000 --json)" '"satisfied": *true'
  echo working > "$st/term-1"
  out=$(o terminal wait --terminal term-1 --for tui-idle --timeout-ms 1000 --json; echo "exit=$?")
  assert_match "fake orca: ... a working one leaves it unsatisfied" "$out" '"satisfied": *false'
  assert_match "fake orca: ... exit 1, as Orca sets it for an unsatisfied wait" "$out" 'exit=1$'
  o terminal close --terminal term-1 --json >/dev/null
  assert_eq "fake orca: a closed terminal's agent is gone" "$(state 1)" none
  # Reachability and installation.
  assert_match "fake orca: status answers" "$(o status --json)" '"reachable": *true'
  out=$(ORCA_STUB_STATUS=fail o status --json; echo "exit=$?")
  assert_match "fake orca: ORCA_STUB_STATUS=fail: status fails" "$out" '"code": *"runtime_unavailable"'
  assert_match "fake orca: ... exit 1" "$out" 'exit=1$'
  reset_stub; out=$(ORCA_STUB=absent o terminal create --json; echo "exit=$?")
  assert_match "fake orca: ORCA_STUB=absent: not installed" "$out" 'exit=127$'
  assert_match "fake orca: ... the refused call is logged" "$(cat "$ORCA_STUB_LOG")" '^orca-absent terminal create --json$'
  unset -f o state; unset st
fi

# --- dryrun ------------------------------------------------------------------
# DRY_RUN's runner, run once per runner (./test.sh dryrun:orca for Orca).
if section dryrun; then
  if [ "${RUNNER:-herdr}" = orca ]; then
    assert_eq "dryrun: RUNNER=orca: runner_detect picks orca" "$(in_kit 'runner_detect')" orca
    assert_eq "dryrun: ... ORCA_CLI_COMMAND is the fake orca" "$(in_kit 'echo "$ORCA_CLI_COMMAND"')" "$KIT/tests/stub/orca"
    assert_match "dryrun: ... the fake orca is on PATH" "$(in_kit 'command -v orca')" "tests/stub/orca$"
    assert_eq "dryrun: ... need_runner exports RUNNER=orca" "$(in_kit 'need_runner; bash -c "echo \$RUNNER"')" orca
    assert_eq "dryrun: ... even from a herdr pane" "$(HERDR_ENV=1 in_kit 'runner_detect')" orca
  else
    assert_eq "dryrun: runner_detect picks herdr" "$(in_kit 'runner_detect')" herdr
    assert_eq "dryrun: ... ORCA_CLI_COMMAND stays unset" "$(in_kit 'echo "[${ORCA_CLI_COMMAND:-}]"')" "[]"
  fi
fi

# --- send-brief ----------------------------------------------------------------
# A brief goes through the kit, to the pane of the one lane or Reviewer line
# that names the agent; nothing in the pane map is run.
if section send-brief; then
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-send-brief-${RUNNER:-herdr}"; reset_stub
  (cd "$r" && "$KIT/bootstrap.sh" "$RUN" "Send brief" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
  if [ "${RUNNER:-herdr}" = orca ]; then S="$ORCA_STUB_STATES_DIR"; L="$ORCA_STUB_LOG"; else S="$HERDR_STUB_STATES_DIR"; L="$HERDR_STUB_LOG"; fi
  send() { : > "$L"; (cd "$r" && "$KIT/send-brief.sh" "$@" 2>&1; echo "exit=$?"); }
  sent() { grep -E '^(herdr agent prompt|orca terminal send)' "$L" || true; }
  apane=$(sed -nE 's/^lane A: +([^ ]+).*/\1/p' "$RUN/panes.txt")
  printf 'Do task 1.\nThen report.\n' > "$RUN/brief-A.md"
  out=$(send "$RUN" bun-vitest-lane-a "$RUN/brief-A.md")
  assert_match "send-brief: sent" "$out" 'exit=0$'
  if [ "${RUNNER:-herdr}" = orca ]; then
    assert_match "send-brief (orca): typed into lane A's terminal" "$(sent)" "^orca terminal send --terminal $apane --text Do task 1\\.\$"
    assert_match "send-brief (orca): ... all of it, then Enter" "$(cat "$L")" '^Then report\. --enter --json$'
  else
    assert_match "send-brief (herdr): prompted to the agent by name" "$(sent)" '^herdr agent prompt bun-vitest-lane-a Do task 1\.$'
    assert_match "send-brief (herdr): ... all of it" "$(cat "$L")" '^Then report\.$'
  fi
  assert_match "send-brief: says where it went" "$out" "brief $RUN/brief-A.md sent to bun-vitest-lane-a in $apane"
  # No command in the map is run: a lane may write one there (an older map
  # had a message line).
  echo "message a pane: touch $TMP/send-brief-ran" >> "$RUN/panes.txt"
  out=$(send "$RUN" bun-vitest-lane-a "$RUN/brief-A.md")
  assert_match "send-brief, a message line in the map: still sent by the kit" "$out" 'exit=0$'
  assert_eq "send-brief, a message line in the map: ... which is not run" "$([ -e "$TMP/send-brief-ran" ] && echo ran || echo not)" not
  out=$(send "$RUN" bun-vitest-lane-z "$RUN/brief-A.md")
  assert_match "send-brief, an agent no line names: refused" "$out" "send-brief: no lane or Reviewer line in $RUN/panes.txt names agent bun-vitest-lane-z"
  assert_match "send-brief, an agent no line names: ... fails" "$out" 'exit=1$'
  assert_eq "send-brief, an agent no line names: nothing sent" "$(sent)" ""
  out=$(send "$RUN" 'bun-vitest-lane-.' "$RUN/brief-A.md")
  assert_match "send-brief, a name read literally: no pattern matches" "$out" 'names agent bun-vitest-lane-\.'
  out=$(send "$RUN" bun-vitest-lane-a "$RUN/brief-none.md")
  assert_match "send-brief, no brief file: refused" "$out" "send-brief: no brief, or an empty one, at $RUN/brief-none.md"
  assert_eq "send-brief, no brief file: nothing sent" "$(sent)" ""
  : > "$RUN/brief-empty.md"
  out=$(send "$RUN" bun-vitest-lane-a "$RUN/brief-empty.md")
  assert_match "send-brief, an empty brief: refused" "$out" "send-brief: no brief, or an empty one, at $RUN/brief-empty.md"
  assert_eq "send-brief, an empty brief: nothing sent" "$(sent)" ""
  if [ "${RUNNER:-herdr}" = orca ]; then
    # Orca: working or waiting, the brief goes; done, only while the screen
    # shows the agent (an agent that exited stays listed done, at a shell);
    # unlisted, once the screen is idle (a terminal agent reports on its first
    # turn); blocked or busy and unlisted, it is held.
    for st in waiting done unlisted-idle; do
      echo "$st" > "$S/$apane"
      out=$(send "$RUN" bun-vitest-lane-a "$RUN/brief-A.md")
      assert_match "send-brief (orca), agent $st: sent" "$out" 'exit=0$'
    done
    rm -f "$S/$apane"
    # An unlisted agent gets its first brief only when the screen shows the
    # agent: not when Orca has no rendered screen, nor when the screen shows
    # neither the agent nor a shell.
    echo unlisted-idle > "$S/$apane"
    out=$(ORCA_STUB_SCREEN=unavailable send "$RUN" bun-vitest-lane-a "$RUN/brief-A.md")
    assert_match "send-brief (orca), unlisted, no rendered screen: held" "$out" "Orca lists no agent in terminal $apane, and its screen does not show the agent"
    assert_eq "send-brief (orca), unlisted, no rendered screen: nothing sent" "$(sent)" ""
    printf 'Compiling...\nstill going\n' > "$S/$apane.tail"
    out=$(send "$RUN" bun-vitest-lane-a "$RUN/brief-A.md")
    assert_match "send-brief (orca), unlisted, a screen that is neither agent nor shell: held" "$out" "its screen does not show the agent"
    assert_eq "send-brief (orca), unlisted, an ambiguous screen: nothing sent" "$(sent)" ""
    rm -f "$S/$apane" "$S/$apane.tail"
    # An agent's footer words win over a status line shaped like a prompt.
    echo done > "$S/$apane"; printf '> \n  ? for shortcuts\n  acme git:(main)  Opus 5.5 ❯\n' > "$S/$apane.tail"
    out=$(send "$RUN" bun-vitest-lane-a "$RUN/brief-A.md")
    assert_match "send-brief (orca), done, footer words over a prompt-shaped status line: sent" "$out" 'exit=0$'
    rm -f "$S/$apane" "$S/$apane.tail"
    # Orca took the brief (exit 0) but says it could not see it arrive: the
    # operator looks before anything is sent again.
    for w in old-host unsupported permission incarnation; do
      out=$(ORCA_STUB_SEND_WARN=$w send "$RUN" bun-vitest-lane-a "$RUN/brief-A.md")
      assert_match "send-brief (orca), taken with an unverified receipt ($w): look before sending again" "$out" "Orca cannot say whether the brief reached bun-vitest-lane-a in $apane"
      assert_match "send-brief (orca), taken with an unverified receipt ($w): fails" "$out" 'exit=1$'
    done
    # A send Orca took without a receipt may have arrived: not "send again".
    out=$(ORCA_STUB_SEND_FAIL=unknown send "$RUN" bun-vitest-lane-a "$RUN/brief-A.md")
    assert_match "send-brief (orca), no receipt: says to look before sending again" "$out" "send-brief: Orca cannot say whether the brief reached bun-vitest-lane-a in $apane \\(no receipt\\): look at that terminal before you send anything again"
    assert_nomatch "send-brief (orca), no receipt: never 'nothing was sent'" "$out" 'nothing was sent'
    assert_match "send-brief (orca), no receipt: fails" "$out" 'exit=1$'
    out=$(ORCA_STUB_SEND_FAIL=refused send "$RUN" bun-vitest-lane-a "$RUN/brief-A.md")
    assert_match "send-brief (orca), refused: nothing was sent, send again" "$out" 'nothing was sent, send again'

    for st in unlisted-shell:"Orca lists no agent in terminal $apane, and its screen shows a shell" done-shell:"lists bun-vitest-lane-a as done, but terminal $apane's screen does not show the agent" unlisted:"Orca lists no agent in terminal $apane, and its screen does not show the agent \\(not idle yet" blocked:"terminal $apane as blocked: not ready for input"; do
      echo "${st%%:*}" > "$S/$apane"
      out=$(send "$RUN" bun-vitest-lane-a "$RUN/brief-A.md")
      assert_match "send-brief (orca), agent ${st%%:*}: held, saying why" "$out" "send-brief: Orca did not take the brief for bun-vitest-lane-a in $apane; nothing was sent, send again \\(.*${st#*:}"
      assert_match "send-brief (orca), agent ${st%%:*}: ... fails" "$out" 'exit=1$'
      assert_eq "send-brief (orca), agent ${st%%:*}: nothing sent" "$(sent)" ""
    done
    rm -f "$S/$apane"
  else
    # herdr not taking the prompt: said, with herdr's error.
    echo gone > "$S/bun-vitest-lane-a"
    out=$(send "$RUN" bun-vitest-lane-a "$RUN/brief-A.md")
    rm -f "$S/bun-vitest-lane-a"
    assert_match "send-brief (herdr), the prompt refused: says so, with herdr's error" "$out" "send-brief: herdr did not take the brief for bun-vitest-lane-a in $apane; nothing was sent, send again \\(.*agent_not_found"
    assert_match "send-brief (herdr), the prompt refused: fails" "$out" 'exit=1$'
  fi
  # read-pane.sh reads an agent's screen as send-brief.sh finds its pane: the
  # map's read line is never run.
  if [ "${RUNNER:-herdr}" = orca ]; then printf 'line one\nline two\n' > "$S/$apane.tail"; else printf 'line one\nline two\n' > "$S/bun-vitest-lane-a.tail"; fi
  echo "read a pane:    touch $TMP/read-pane-ran" >> "$RUN/panes.txt"
  out=$( (cd "$r" && "$KIT/read-pane.sh" "$RUN" bun-vitest-lane-a 1 2>&1; echo "exit=$?") )
  assert_match "read-pane: the agent's last lines" "$out" '^line two$'
  assert_match "read-pane: ... exit 0" "$out" 'exit=0$'
  assert_nomatch "read-pane: ... as many as asked" "$out" '^line one$'
  assert_eq "read-pane: the map's read line is not run" "$([ -e "$TMP/read-pane-ran" ] && echo ran || echo not)" not
  # A documented maximum of 120 lines, on both runners.
  out=$( (cd "$r" && "$KIT/read-pane.sh" "$RUN" bun-vitest-lane-a 120 2>&1; echo "exit=$?") )
  assert_match "read-pane: 120 lines: read" "$out" 'exit=0$'
  out=$( (cd "$r" && "$KIT/read-pane.sh" "$RUN" bun-vitest-lane-a 121 2>&1; echo "exit=$?") )
  assert_match "read-pane: more than 120 lines: refused, saying the maximum" "$out" 'read-pane: at most 120 lines \(asked for 121\)'
  assert_match "read-pane: more than 120 lines: exit 1" "$out" 'exit=1$'
  # A run with no dev pane: --dev says so.
  out=$( (cd "$r" && "$KIT/read-pane.sh" "$RUN" --dev 2>&1; echo "exit=$?") )
  assert_match "read-pane --dev, a run with no dev pane: says so" "$out" "read-pane: the kit has no dev pane on record for $RUN"
  out=$( (cd "$r" && "$KIT/read-pane.sh" "$RUN" bun-vitest-lane-z 2>&1; echo "exit=$?") )
  assert_match "read-pane, an agent no line names: refused" "$out" "read-pane: no lane or Reviewer line in $RUN/panes.txt names agent bun-vitest-lane-z"
  assert_match "read-pane, an agent no line names: exit 1" "$out" 'exit=1$'
  rm -f "$S/$apane.tail" "$S/bun-vitest-lane-a.tail"; sed -i.bak '/^read a pane:    touch/d' "$RUN/panes.txt"; rm -f "$RUN/panes.txt.bak"
  # The brief is read once, from a regular file: a link (it could point
  # outside the run dir) or a directory is refused, with nothing sent.
  echo secret > "$TMP/outside.txt"; ln -sf "$TMP/outside.txt" "$RUN/brief-link.md"
  out=$(send "$RUN" bun-vitest-lane-a "$RUN/brief-link.md")
  assert_match "send-brief, a brief that is a link: refused" "$out" "send-brief: $RUN/brief-link.md is not a regular"
  assert_eq "send-brief, a brief that is a link: nothing sent" "$(sent)" ""
  mkdir -p "$RUN/brief-dir.md"
  out=$(send "$RUN" bun-vitest-lane-a "$RUN/brief-dir.md")
  assert_match "send-brief, a brief that is a directory: refused" "$out" "send-brief: $RUN/brief-dir.md is not a regular"
  assert_eq "send-brief, a brief that is a directory: nothing sent" "$(sent)" ""
  mkfifo "$RUN/brief-fifo.md"
  out=$(send "$RUN" bun-vitest-lane-a "$RUN/brief-fifo.md")
  assert_match "send-brief, a brief that is a FIFO: refused, not waited on" "$out" "send-brief: $RUN/brief-fifo.md is not a regular"
  printf 'Fix the caf\xe9\n' > "$RUN/brief-latin1.md"
  out=$(send "$RUN" bun-vitest-lane-a "$RUN/brief-latin1.md")
  assert_match "send-brief, a brief not in UTF-8: refused, saying so" "$out" "is not a regular UTF-8 text file"
  # Only a file directly in the run dir is a brief, opened by its name there:
  # a nested path, or one through a directory link, is refused.
  mkdir -p "$RUN/sub" "$TMP/outside-dir"; cp "$RUN/brief-A.md" "$RUN/sub/brief.md"; cp "$RUN/brief-A.md" "$TMP/outside-dir/brief.md"
  ln -sfn "$TMP/outside-dir" "$RUN/subl"
  for b in "$RUN/sub/brief.md" "$RUN/subl/brief.md" "$TMP/outside-dir/brief.md"; do
    out=$(send "$RUN" bun-vitest-lane-a "$b")
    assert_match "send-brief, a brief not directly in the run dir ($b): refused" "$out" "send-brief: a brief must be a file directly in $RUN: nothing sent"
    assert_eq "send-brief, a brief not directly in the run dir ($b): nothing sent" "$(sent)" ""
  done
  out=$(send "$RUN" bun-vitest-lane-a brief-A.md)
  assert_match "send-brief, a brief named by its file name: sent from the run dir" "$out" 'exit=0$'
  # A NUL byte cannot travel in a prompt: refused, not dropped.
  printf 'Do task 1.\0Then report.\n' > "$RUN/brief-nul.md"
  out=$(send "$RUN" bun-vitest-lane-a "$RUN/brief-nul.md")
  assert_match "send-brief, a brief with a NUL byte: refused, saying so" "$out" "send-brief: $RUN/brief-nul.md holds a NUL byte, which a prompt cannot carry: nothing sent"
  assert_eq "send-brief, a brief with a NUL byte: nothing sent" "$(sent)" ""
  printf 'Fix it \xe2\x9c\x93\n' > "$RUN/brief-utf8.md"
  out=$(LC_ALL=C send "$RUN" bun-vitest-lane-a "$RUN/brief-utf8.md")
  assert_match "send-brief, a UTF-8 brief under a C locale: sent" "$out" 'exit=0$'
  # A Reviewer's line names its agent the same way.
  spane=$(sed -nE 's/^shell: +([^ ]+).*/\1/p' "$RUN/panes.txt")
  printf 'reviewer R1:    %s   (agent "bun-vitest-r1-1", kind codex, model gpt-6-astra, review "Lane review A", findings %s)\n' "$spane" "$RUN/findings/lane-a.json" >> "$RUN/panes.txt"
  out=$(send "$RUN" bun-vitest-r1-1 "$RUN/brief-A.md")
  # The kit's own launch record (under the user's state dir, out of a lane's
  # reach) binds an agent to its pane: Orca refuses an agent it has no record of
  # launching; herdr sends by name.
  if [ "${RUNNER:-herdr}" = orca ]; then
    assert_match "send-brief (orca), an agent the kit never launched: refused" "$out" "send-brief: the kit has no record of launching bun-vitest-r1-1"
    assert_eq "send-brief (orca), an agent the kit never launched: nothing sent" "$(sent)" ""
  else
    assert_match "send-brief (herdr), no launch record: sent by name" "$out" "sent to bun-vitest-r1-1 in $spane\$"
  fi
  assert_match "the kit records lane A's launch" "$(in_kit "launched '$RUN' bun-vitest-lane-a")" "^bun-vitest-lane-a $apane\$"
  rec=$(in_kit "launch_record '$RUN'")
  assert_match "the launch record lives under the user's state dir, named by the run dir" "$rec" "^$XDG_STATE_HOME/tower/launched/[0-9a-f]+\$"
  assert_eq "the launch record: a private file" "$(ls -l "$rec" | cut -c1-10)" -rw-------
  # bind-pane.sh: the operator records an agent's pane by hand; the map's line
  # must give that pane, and the runner must say it is open.
  bind() { (cd "$r" && "$KIT/bind-pane.sh" "$@" 2>&1; echo "exit=$?"); }
  out=$(bind "$RUN" bun-vitest-lane-a "$spane")
  assert_match "bind-pane, a pane the map does not give the agent: refused" "$out" "bind-pane: the pane map gives bun-vitest-lane-a pane $apane, not $spane"
  assert_match "bind-pane, a pane the map does not give the agent: fails" "$out" 'exit=1$'
  out=$(bind "$RUN" bun-vitest-r1-1 "$spane")
  assert_match "bind-pane: recorded" "$out" "recorded bun-vitest-r1-1 in $spane"
  assert_match "bind-pane: ... in the record" "$(in_kit "launched '$RUN' bun-vitest-r1-1")" "^bun-vitest-r1-1 $spane\$"
  # The record is written only as a regular file of yours, never through a link.
  mv "$rec" "$rec.real"; ln -s "$TMP/rec-elsewhere" "$rec"
  out=$(bind "$RUN" bun-vitest-r1-1 "$spane")
  assert_match "bind-pane, the record a link: refused" "$out" "bind-pane: cannot write the launch record $rec"
  assert_eq "bind-pane, the record a link: nothing written through it" "$([ -e "$TMP/rec-elsewhere" ] && echo written || echo none)" none
  rm -f "$rec"; mv "$rec.real" "$rec"
  out=$(send "$RUN" bun-vitest-r1-1 "$RUN/brief-A.md")
  assert_match "send-brief, a Reviewer: sent to its pane" "$out" "sent to bun-vitest-r1-1 in $spane\$"
  # A swapped handle: the map gives lane A's agent another live pane.
  cp "$RUN/panes.txt" "$TMP/sb-map"; sed -i.bak "/^lane A:/s|$apane|$spane|" "$RUN/panes.txt"; rm -f "$RUN/panes.txt.bak"
  sed -i.bak '/^reviewer R1:/d' "$RUN/panes.txt"; rm -f "$RUN/panes.txt.bak"
  out=$(send "$RUN" bun-vitest-lane-a "$RUN/brief-A.md")
  if [ "${RUNNER:-herdr}" = orca ]; then
    assert_match "send-brief (orca), a swapped handle: refused" "$out" "send-brief: the pane map gives bun-vitest-lane-a pane $spane, but the kit's record has it in $apane"
    assert_eq "send-brief (orca), a swapped handle: nothing sent" "$(sent)" ""
    # Orca restarted: the recorded handle is stale, and the map gives another
    # open terminal. A map edit alone binds nothing (a lane can make it): the
    # operator records the new handle with bind-pane.sh, then it is sent.
    echo gone > "$S/$apane"
    out=$(send "$RUN" bun-vitest-lane-a "$RUN/brief-A.md")
    assert_match "send-brief (orca), the recorded handle stale, the map rebound: refused" "$out" "but the kit's record has it in $apane; .*record it with  $KIT/bind-pane\\.sh $RUN bun-vitest-lane-a $spane"
    assert_eq "send-brief (orca), the recorded handle stale, the map rebound: nothing sent" "$(sent)" ""
    assert_match "send-brief (orca), ... the record unchanged" "$(in_kit "launched '$RUN' bun-vitest-lane-a")" "^bun-vitest-lane-a $apane\$"
    # The copyable bind command gives every argument as one literal shell
    # word: shell syntax in the map's handle runs nothing.
    sed -i.bak "/^lane A:/s/ $spane / term-9\$(id) /" "$RUN/panes.txt"; rm -f "$RUN/panes.txt.bak"
    out=$(send "$RUN" bun-vitest-lane-a "$RUN/brief-A.md")
    cmd=$(printf '%s\n' "$out" | sed -nE 's/.*record it with  (.*)\): nothing sent$/\1/p' | head -1)
    assert_eq "send-brief (orca), shell syntax in the map's handle: the bind command takes it as one literal word" "$(eval "set -- $cmd"; echo "$#|$1|$4")" "4|$KIT/bind-pane.sh|term-9\$(id)"
    sed -i.bak "/^lane A:/s/ term-9\$(id) / $spane /" "$RUN/panes.txt"; rm -f "$RUN/panes.txt.bak"
    out=$(bind "$RUN" bun-vitest-lane-a "$spane")
    out=$(send "$RUN" bun-vitest-lane-a "$RUN/brief-A.md")
    assert_match "send-brief (orca), the new handle recorded with bind-pane: sent" "$out" "sent to bun-vitest-lane-a in $spane\$"
    rm -f "$S/$apane"
  else
    assert_match "send-brief (herdr), another pane in the map: sent by name all the same" "$(sent)" '^herdr agent prompt bun-vitest-lane-a '
  fi
  cp "$TMP/sb-map" "$RUN/panes.txt"; bind "$RUN" bun-vitest-lane-a "$apane" >/dev/null
  echo gone > "$S/$apane"
  out=$(send "$RUN" bun-vitest-lane-a "$RUN/brief-A.md")
  rm -f "$S/$apane"
  if [ "${RUNNER:-herdr}" = orca ]; then
    assert_match "send-brief (orca), a stale handle: asks to rebind it" "$out" "Orca says bun-vitest-lane-a's terminal handle $apane is stale: .* put its handle on its line in $RUN/panes\\.txt and record it with  $KIT/bind-pane\\.sh $RUN bun-vitest-lane-a <its handle>, then rerun"
  else
    assert_match "send-brief, its pane closed: refused" "$out" "send-brief: bun-vitest-lane-a's pane $apane is gone"
  fi
  assert_eq "send-brief, its pane closed: nothing sent" "$(sent)" ""
  grep '^lane A:' "$RUN/panes.txt" | sed 's/^lane A:/lane B:/' >> "$RUN/panes.txt"
  out=$(send "$RUN" bun-vitest-lane-a "$RUN/brief-A.md")
  assert_match "send-brief, two lines name the agent: refused" "$out" "send-brief: 2 lines in $RUN/panes.txt name agent bun-vitest-lane-a"
  assert_eq "send-brief, two lines name the agent: nothing sent" "$(sent)" ""
fi

# --- runner ------------------------------------------------------------------
if section runner; then
  list=$("$ROOT/test.sh" --list 2>&1)
  assert_match "--list: names the sections, one per line" "$list" '^bootstrap$'
  assert_match "--list: the slow ones too"               "$list" '^look$'
  assert_nomatch "--list: runs no test"                  "$list" '^(ok|FAIL) '
  fast=$("$ROOT/test.sh" --fast --list 2>&1)
  # shellcheck disable=SC2086 # SLOW is a list of words
  assert_nomatch "--fast: skips the slow sections"       "$fast" "^($(echo $SLOW | tr ' ' '|'))\$"
  # shellcheck disable=SC2086
  assert_eq "--fast: runs every other section" "$(printf '%s\n' "$fast" | wc -l | tr -d ' ')" "$(( $(printf '%s\n' "$list" | wc -l) - $(set -- $SLOW; echo $#) ))"
  out=$("$ROOT/test.sh" --fsat 2>&1; echo "exit=$?")
  assert_match "an unknown flag is refused"              "$out" "test.sh: unknown flag --fsat"
  assert_match "an unknown flag fails"                   "$out" 'exit=2$'
  out=$("$ROOT/test.sh" lok 2>&1; echo "exit=$?")
  assert_match "an unknown section is refused"           "$out" "test.sh: no section named lok"
  assert_match "an unknown section fails"                "$out" 'exit=2$'
  assert_match "--fast with a slow section named runs it" "$("$ROOT/test.sh" --fast --list run 2>&1)" '^run$'
  assert_match "two sections are refused"                "$("$ROOT/test.sh" bootstrap detect 2>&1)" "test.sh: one section at most"
  assert_match "--list: a per-runner section once per runner" "$list" '^dryrun$'
  assert_match "--list: ... and with :orca"              "$list" '^dryrun:orca$'
  out=$("$ROOT/test.sh" dryrun:orca 2>&1; echo "exit=$?")
  assert_match "<section>:orca runs it with the runner set to orca" "$out" '^ok   dryrun: RUNNER=orca: runner_detect picks orca$'
  assert_match "<section>:orca: ... and passes"          "$out" 'exit=0$'
  assert_match "an inherited RUNNER does not make a section Orca's" "$(RUNNER=orca "$ROOT/test.sh" dryrun 2>&1)" '^ok   dryrun: runner_detect picks herdr$'
  out=$("$ROOT/test.sh" dryrun:tmux 2>&1; echo "exit=$?")
  assert_match "an unknown runner is refused"            "$out" 'test.sh: no runner tmux \(herdr or orca\)'
  assert_match "an unknown runner fails"                 "$out" 'exit=2$'
  out=$("$ROOT/test.sh" look:orca 2>&1; echo "exit=$?")
  assert_match "a section that does not run per runner is refused with :orca" "$out" 'test.sh: look does not run per runner'
  assert_match "... and fails"                           "$out" 'exit=2$'
fi

[ -z "$ONLY" ] || [ "$MATCHED" = 1 ] || { echo "test.sh: no section named $ONLY (./test.sh --list)" >&2; exit 2; }
[ "$LIST" = 0 ] || exit 0
echo; echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
