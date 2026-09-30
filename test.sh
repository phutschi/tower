#!/usr/bin/env bash
# The kit's tests. They need neither herdr, claude nor codex: DRY_RUN=1 puts
# tests/stub first on PATH, so every call to them is logged and answered by a
# stub. tower is the real CLI from this checkout (tests/stub/tower runs
# src/cli.ts with bun): the tests read what the scripts recorded with
# `tower state --json`.
#
#   ./test.sh            all sections
#   ./test.sh bootstrap  one section (a word from the "# ---" headings below)
#   ./test.sh --fast     all sections but the slow ones (SLOW): the check gate's
#                        mode; the full suite runs them all. A section named
#                        with it runs even when slow.
#   ./test.sh --list     the sections that would run, one per line; runs nothing
#
# A new section runs in both modes unless it is added to SLOW.
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"; KIT="$ROOT/skills/orchestrate"; PREFLIGHT_DIR="$ROOT/skills/preflight"; export KIT
SLOW="look run"   # preflight's look.sh and one whole run: ~12 of ~35 seconds
ONLY=""; LIST=0; FAST=0; MATCHED=0
for _a in "$@"; do
  case "$_a" in
    --list) LIST=1 ;;
    --fast) FAST=1 ;;
    --*)    echo "test.sh: unknown flag $_a" >&2; exit 2 ;;
    *)      [ -z "$ONLY" ] || { echo "test.sh: one section at most" >&2; exit 2; }; ONLY=$_a ;;
  esac
done; unset _a
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; shift; printf '     %s\n' "$@"; }
assert_eq()      { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected: $3" "got:      $2"; }
assert_match()   { printf '%s\n' "$2" | grep -qE -- "$3" && ok "$1" || bad "$1" "no match for /$3/ in:" "$2"; }
assert_nomatch() { printf '%s\n' "$2" | grep -qE -- "$3" && bad "$1" "unexpected match for /$3/ in:" "$2" || ok "$1"; }
section() {
  [ -z "$ONLY" ] || [ "$ONLY" = "$1" ] || return 1
  MATCHED=1
  [ "$FAST" = 0 ] || [ -n "$ONLY" ] || case " $SLOW " in *" $1 "*) return 1 ;; esac
  [ "$LIST" = 0 ] || { echo "$1"; return 1; }
}

TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
export DRY_RUN=1 HERDR_ENV=1 HERDR_STUB_LOG="$TMP/log" HERDR_STUB_COUNTER="$TMP/counter" HERDR_STUB_STATES_DIR="$TMP/states"
# common.sh only defaults HERDR_PANE_ID/HERDR_TAB_ID when unset, so running
# test.sh from inside a real herdr pane (as its own agent does) would
# otherwise leak this pane's real ids into every assertion instead of the
# pane-0/tab-0 the plan's assertions expect.
unset HERDR_PANE_ID HERDR_TAB_ID
# tower is the real CLI from this checkout (tests/stub/tower): its state and
# config stay in $TMP, never the user's.
export XDG_STATE_HOME="$TMP/xdg-state" XDG_CONFIG_HOME="$TMP/xdg-config"
unset TOWER_RUN
# The repo contract's names and the run switches: the fixtures decide them,
# not the shell test.sh is started from (a codex lane exports EXECUTOR_KIND).
unset EXECUTOR_KIND EXECUTOR_MODEL SPEC_REVIEWER_MODEL QUALITY_REVIEWER_MODEL STALE PM TYPECHECK_TASK \
  CHECK_CMD INSTALL_CMD TEST_PKG TEST_FILTER LANES TASK_REVIEW LANE_REVIEW PREFLIGHT STATIC_BASELINE PR METHOD \
  REVIEWER_KIND REVIEWER_MODEL REVIEW_AREAS SUITE_SKIP PR_TEMPLATE
mkdir -p "$HERDR_STUB_STATES_DIR"

# Guard: every section below runs herdr/tower/claude/codex calls through common.sh's
# DRY_RUN PATH shim. If a stub is missing, not executable, or shadowed by
# something earlier on PATH, refuse outright rather than risk a script under
# test touching the real herdr or tower (this happened once: HERDR_ENV=1 is
# inherited from the orchestrating pane, so `in_herdr` alone does not stop a
# script run outside test.sh and outside DRY_RUN=1 from driving real panes).
for _tool in herdr tower claude codex semgrep gitleaks; do
  _which=$(bash -c ". \"$KIT/common.sh\"; command -v $_tool" 2>/dev/null || true)
  [ "$_which" = "$KIT/tests/stub/$_tool" ] || { echo "test.sh: $_tool resolves to '$_which', not the stub ($KIT/tests/stub/$_tool) — refusing to run" >&2; exit 1; }
done
unset _tool _which
command -v bun >/dev/null || { echo "test.sh: tower runs from this checkout with bun, and bun is not on PATH — refusing to run" >&2; exit 1; }
command -v npm >/dev/null || { echo "test.sh: the look section runs npm scripts in its fixtures, and npm is not on PATH — refusing to run" >&2; exit 1; }
reset_stub() { : > "$HERDR_STUB_LOG"; rm -f "$HERDR_STUB_COUNTER" "$HERDR_STUB_COUNTER.busy" "$HERDR_STUB_COUNTER.enters" "$HERDR_STUB_COUNTER.trust" "$HERDR_STUB_COUNTER.started"; }
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
  assert_match "in_herdr passes under DRY_RUN"   "$(in_kit 'in_herdr && echo inside')" "^inside$"
  out=$(HERDR_ENV=0 in_kit 'in_herdr && echo inside')
  assert_nomatch "in_herdr: outside herdr it refuses" "$out" "^inside$"
  assert_match "in_herdr: ... saying the skill needs herdr" "$out" "needs herdr"
  assert_match "in_herdr: ... and pointing to /tower:run" "$out" "/tower:run"
  out=$(HERDR_STUB=absent in_kit 'in_herdr && echo inside')
  assert_match "in_herdr: without a runnable herdr it refuses the same way" "$out" "needs herdr.*/tower:run"
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
  assert_match "reviewer: an unknown REVIEWER_KIND is refused" "$(REVIEWER_KIND=Claude rev claude)" "REVIEWER_KIND must be other, claude or codex \(got 'Claude'\)"
  assert_match "reviewer: neither kind installed is refused" "$(CODEX_STUB=absent CLAUDE_STUB=absent rev claude)" "neither claude nor codex is installed"
  # An agent start: `start NAME [ENV...]` runs start_agent_with_trust_retry
  # for NAME in pane-9 of a codex executor, in repo $r.
  start() { local n=$1; shift; reset_stub; (cd "$r" && env HOME="$TMP/rev-home" EXECUTOR_KIND=codex "$@" bash -c ". \"\$KIT/common.sh\"; . \"\$KIT/executor.sh\"; start_agent_with_trust_retry $n pane-9; echo \"exit=\$?\"" 2>&1); }
  out=$(start acme-lane-a)
  assert_match "codex start: its startup update check is off" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start acme-lane-a --kind codex --pane pane-9 -- .* -c check_for_update_on_startup=false( |$)'
  out=$(start acme-lane-a 'AGENT_TMP=/run/it"s \tmp')
  assert_match "AGENT_TMP: a TOML string, quote and backslash escaped" "$(cat "$HERDR_STUB_LOG")" '-c shell_environment_policy\.set\.TMPDIR="/run/it\\"s \\\\tmp"'
  # A codex lane in a worktree may write only what its commits need in the
  # common git dir, never its hooks or config (#10); lane A in the main
  # checkout keeps the whole common dir, as its index and HEAD live there.
  C=$(git -C "$r" rev-parse --path-format=absolute --git-common-dir)
  start_in() { local d=$1; shift; reset_stub; (cd "$d" && env HOME="$TMP/rev-home" EXECUTOR_KIND=codex RUN_DIR=/run/x "$@" bash -c ". \"\$KIT/common.sh\"; . \"\$KIT/executor.sh\"; start_agent_with_trust_retry acme-lane-b pane-9" >/dev/null 2>&1); cat "$HERDR_STUB_LOG"; }
  log=$(start_in "$wt")
  assert_match "codex worktree lane: writes only objects, refs, logs, packed-refs and its own git dir" "$log" \
    "^herdr agent start acme-lane-b .* -c sandbox_workspace_write\\.writable_roots=\\[\"/run/x\",\"$C/objects\",\"$C/refs\",\"$C/logs\",\"$C/packed-refs\",\"$C/packed-refs\\.lock\",\"$C/packed-refs\\.new\",\"$C/worktrees/some-branch\"\\]( |\$)"
  assert_nomatch "codex worktree lane: not the whole common git dir" "$log" "--add-dir $C( |\$)"
  assert_match "codex worktree lane: the run dir still added" "$log" "--add-dir /run/x( |\$)"
  log=$(start_in "$r")
  assert_match "codex lane in the main checkout: the whole common git dir" "$log" "--add-dir $C( |\$)"
  assert_nomatch "codex lane in the main checkout: no narrowed roots" "$log" 'writable_roots'
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

# --- detect ------------------------------------------------------------------
if section detect; then
  detect_in() { (cd "$1" && bash -c ". \"\$KIT/common.sh\"; . \"\$KIT/detect-stack.sh\"; $2" 2>&1); }
  r=$(fixture_repo bun-vitest)
  assert_eq "detect: bun from bun.lock"              "$(detect_in "$r" 'echo $PM')" bun
  assert_eq "detect: check gate = typecheck && test" "$(detect_in "$r" 'echo "$CHECK_CMD"')" "bun run typecheck && bun run test"
  assert_eq "detect: default checks pane is the runner in watch mode" "$(detect_in "$r" 'echo "${PANE_NAMES[0]} ${PANE_CMDS[0]} ${PANE_DIRS[0]}"')" "checks bunx vitest --watch ."
  assert_eq "detect: no dev pane by default"        "$(detect_in "$r" 'echo ${#PANE_NAMES[@]}')" 1
  assert_eq "detect: CHECK_CMD from the environment wins" "$(CHECK_CMD='make it' detect_in "$r" 'echo "$CHECK_CMD"')" "make it"
  r=$(fixture_repo pnpm-notest)
  assert_eq "detect: check-types, no test script"   "$(detect_in "$r" 'echo "$CHECK_CMD"')" "pnpm run check-types"
  assert_match "detect: no runner gives a note, not a broken pane" "$(detect_in "$r" 'echo "${PANE_CMDS[0]}"')" "no test runner detected"
  assert_eq "detect: NO_RUNNER=1 without a runner"  "$(detect_in "$r" 'echo $NO_RUNNER')" 1
  assert_eq "detect: NO_RUNNER=0 with a detected runner" "$(detect_in "$(fixture_repo bun-vitest)" 'echo $NO_RUNNER')" 0
  printf 'pane checks "make test"\n' > "$r/.orchestrate"
  assert_eq "detect: NO_RUNNER=0 with a declared checks pane" "$(detect_in "$r" 'echo $NO_RUNNER')" 0
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
  assert_eq "contract: panes in order with dirs"    "$(detect_in "$r" 'echo "${PANE_NAMES[*]}|${PANE_CMDS[1]}|${PANE_DIRS[1]}"')" "checks dev|make dev|web"
  assert_eq "contract: harness, models and stale"   "$(detect_in "$r" 'echo "$EXECUTOR_KIND $EXECUTOR_MODEL $SPEC_REVIEWER_MODEL $QUALITY_REVIEWER_MODEL $STALE"')" "codex gpt-6-astra-mini haiku sonnet 45"
  assert_eq "contract: the environment wins over the file" "$(EXECUTOR_KIND=claude STALE=5 detect_in "$r" 'echo "$EXECUTOR_KIND $STALE $EXECUTOR_MODEL"')" "claude 5 gpt-6-astra-mini"
  assert_match "contract: an unknown setting is named" "$(detect_in "$(fixture_repo contract-typo)" 'echo reached')" "'MODEL' is not a setting"
  assert_match "contract: an unknown setting does not stop the script" "$(detect_in "$(fixture_repo contract-typo)" 'echo reached')" "^reached$"
  RUNC="$TMP/run-contract"; reset_stub
  (cd "$r" && "$KIT/bootstrap.sh" "$RUNC" "Contract" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
  assert_eq "contract: bootstrap records the file's models" "$(board "$RUNC" '" ".join(k+"="+v for k,v in sorted(d["run"]["models"].items()))')" "implementer=gpt-6-astra-mini quality-reviewer=sonnet spec-reviewer=haiku"
  assert_match "contract: lane A is codex"          "$(cat "$RUNC/panes.txt")" '^lane A: .*kind codex, .*model gpt-6-astra-mini\)'
  assert_match "contract: console stale from the file" "$(cat "$HERDR_STUB_LOG")" '^herdr pane run pane-4 tower --stale 45$'
  reset_stub; out=$(cd "$r" && EXECUTOR_KIND=claude "$KIT/add-lane.sh" "$RUNC" B feat/b main 2 2>&1)
  assert_match "contract: add-lane env overrides the file's kind" "$(cat "$RUNC/panes.txt")" '^lane B: .*kind claude, .*model gpt-6-astra-mini\)'
  r=$(fixture_repo none)
  assert_eq "switches: defaults when neither file nor environment sets them" \
    "$(detect_in "$r" 'switches_line')" \
    "TASK_REVIEW=on LANE_REVIEW=on PREFLIGHT=on STATIC_BASELINE=on PR=draft METHOD=tdd REVIEWER_KIND=other REVIEWER_MODEL= REVIEW_AREAS= SUITE_SKIP= PR_TEMPLATE="
  r=$(fixture_repo contract-switches)
  assert_eq "switches: the file's values are used" \
    "$(detect_in "$r" 'switches_line')" \
    "TASK_REVIEW=off LANE_REVIEW=off PREFLIGHT=off STATIC_BASELINE=off PR=ready METHOD=plain REVIEWER_KIND=claude REVIEWER_MODEL=claude-fable-5-1 REVIEW_AREAS=security,spec SUITE_SKIP=build PR_TEMPLATE=.github/pull_request_template.md"
  assert_eq "switches: the environment wins over the file" \
    "$(PR=off METHOD=tdd SUITE_SKIP=lint,test REVIEWER_KIND=codex detect_in "$r" 'echo "$PR $METHOD $SUITE_SKIP $REVIEWER_KIND $TASK_REVIEW"')" \
    "off tdd lint,test codex off"
  assert_nomatch "switches: not reported as unknown settings" "$(detect_in "$r" 'true')" "not a setting the kit reads"
  assert_eq "switches: an environment value with spaces wins whole" \
    "$(CHECK_CMD='make it all' PR_TEMPLATE='my template.md' detect_in "$r" 'echo "$CHECK_CMD|$PR_TEMPLATE"')" "make it all|my template.md"
  assert_eq "suite: steps in contract order, DIR defaulting to ." \
    "$(detect_in "$r" 'for i in 0 1 2; do printf "%s|%s|%s;" "${SUITE_NAMES[$i]}" "${SUITE_CMDS[$i]}" "${SUITE_DIRS[$i]}"; done')" \
    "lint|make lint|.;test|make test|pkg/core;build|make build|.;"
  assert_match "this repo's contract: the check gate runs tower's check, the fast tests and shellcheck" "$(detect_in "$ROOT" 'echo "$CHECK_CMD"')" '^bun run check && \./test\.sh --fast && shellcheck '
  assert_eq "this repo's contract: the full suite is tower's check, every test, then shellcheck" "$(detect_in "$ROOT" 'echo "${SUITE_NAMES[*]}|${SUITE_CMDS[0]}|${SUITE_CMDS[1]}|${SUITE_CMDS[2]}"')" "check tests shellcheck|bun run check|./test.sh|shellcheck -S warning *.sh skills/*/*.sh skills/orchestrate/tests/stub/*"
  assert_match "this repo's contract: the checks pane covers both sides" "$(detect_in "$ROOT" 'echo "${PANE_CMDS[0]}"')" 'bun run check.*\./test\.sh --fast'
  assert_nomatch "this repo's contract: a checks pane, no unknown settings" "$(detect_in "$ROOT" 'echo "${PANE_CMDS[0]}"')" 'no test runner detected|not a setting'
  assert_eq "suite: none without suite lines" "$(detect_in "$(fixture_repo none)" 'echo ${#SUITE_NAMES[@]}')" 0
  r=$(fixture_repo contract-switches-bad)
  assert_match "switches: a bad value is refused with the allowed values" "$(detect_in "$r" 'echo reached')" "PR must be draft, ready or off \(got 'maybe'\)"
  assert_nomatch "switches: the refusal stops the script" "$(detect_in "$r" 'echo reached')" "^reached$"
  assert_match "switches: METHOD=fast is refused"          "$(METHOD=fast detect_in "$(fixture_repo none)" 'true')" "METHOD must be tdd or plain \(got 'fast'\)"
  assert_match "switches: REVIEWER_KIND=cursor is refused" "$(REVIEWER_KIND=cursor detect_in "$(fixture_repo none)" 'true')" "REVIEWER_KIND must be other, claude or codex \(got 'cursor'\)"
  assert_match "switches: a value on two lines is refused" "$(PR_TEMPLATE=$'a\nb' detect_in "$(fixture_repo none)" 'true')" "PR_TEMPLATE must be one line"
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
  boot() { (cd "$1" && shift && "$KIT/bootstrap.sh" "$@" 2>&1); }
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-empty"; reset_stub
  out=$(boot "$r" "$RUN" "Empty run" main)
  log=$(cat "$HERDR_STUB_LOG")
  assert_eq "empty: the run is on the board, titled"    "$(board "$RUN" 'd["run"]["plan"]')" "Empty run"
  assert_eq "empty: no tasks yet"                       "$(board "$RUN" 'len(d["tasks"])')" 0
  assert_eq "empty: the roles' models are recorded"     "$(board "$RUN" '" ".join(k+"="+v for k,v in sorted(d["run"]["models"].items()))')" "implementer=claude-opus-5-5[1m] quality-reviewer=opus spec-reviewer=sonnet"
  assert_eq "empty: no lane assignment"                 "$(board "$RUN" 'len(d["lanes"])')" 0
  assert_match "layout: bottom row first"               "$log" '^herdr pane split --current --direction down --ratio 0.7 '
  assert_match "layout: lane A right of the orchestrator" "$log" '^herdr pane split --current --direction right --ratio 0.3 '
  assert_match "layout: console right of checks"        "$log" '^herdr pane split --pane pane-1 --direction right --ratio 0.5 '
  assert_match "layout: checks pane runs the runner in the checkout" "$log" "^herdr pane run pane-1 cd $r/\. && bunx vitest --watch$"
  assert_match "layout: console runs tower"             "$log" '^herdr pane run pane-3 tower --stale 30$'
  assert_match "lane A: agent named and started"        "$log" '^herdr agent start bun-vitest-lane-a --kind claude --pane pane-2 -- --model claude-opus-5-5\[1m\]$'
  map=$(cat "$RUN/panes.txt")
  assert_match "pane map: lane A line"                  "$map" '^lane A: +pane-2 +\(agent "bun-vitest-lane-a", kind claude, branch main, checkout '"$r"', model '
  assert_match "pane map: checks line"                  "$map" '^checks: +pane-1 '
  assert_match "pane map: console line"                 "$map" '^console: +pane-3 '
  assert_match "pane map: check gate"                   "$map" '^check gate: +bun run typecheck && bun run test$'
  assert_nomatch "pane map: no dev line by default"     "$map" '^dev:'
  assert_match "output: the pane map is printed"        "$out" '^lane A: '
  assert_match "output: next step for the empty opening" "$out" 'tower add'
  assert_nomatch "output: a detected runner needs no note" "$out" 'no test runner detected'
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
  assert_eq "output: no test runner detected, said once" "$(printf '%s\n' "$out" | grep -c '^info: no test runner detected')" 1
  assert_nomatch "output: the note is on stderr, not stdout" "$(cd "$(fixture_repo pnpm-notest)" && "$KIT/bootstrap.sh" "$TMP/run-norunner2" "No runner" main 2>/dev/null)" '^info: no test runner detected'
  assert_match "output: the note says how to declare one" "$out" '^info: no test runner detected: the checks pane has nothing to run; declare  pane checks "<cmd>"  in \.orchestrate$'
  assert_match "switches: pane map has every switch"    "$map" '^switches: +TASK_REVIEW=on LANE_REVIEW=on PREFLIGHT=on STATIC_BASELINE=on PR=draft METHOD=tdd REVIEWER_KIND=other REVIEWER_MODEL= REVIEW_AREAS= SUITE_SKIP= PR_TEMPLATE=$'
  assert_match "switches: the record gets a tower note" "$(notes "$TMP/run-empty")" '^switches: TASK_REVIEW=on LANE_REVIEW=on .* PR_TEMPLATE=$'
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
  assert_match "a contract with only pane and suite lines: pane map written" "$(cat "$RUN/panes.txt" 2>&1)" '^checks: +pane-[0-9]+ +\(make watch in \.\)$'
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

  r=$(fixture_repo contract); RUN="$TMP/run-dev"; reset_stub
  out=$(boot "$r" "$RUN" "Dev" main)
  log=$(cat "$HERDR_STUB_LOG")
  assert_match "dev: bottom row in thirds, checks after dev" "$log" '^herdr pane split --pane pane-1 --direction right --ratio 0.34 '
  assert_match "dev: console after checks"              "$log" '^herdr pane split --pane pane-3 --direction right --ratio 0.5 '
  assert_match "dev: dev pane runs in its dir"          "$log" "^herdr pane run pane-1 cd $r/web && make dev$"
  assert_match "dev: checks pane runs make watch"       "$log" "^herdr pane run pane-3 cd $r/\. && make watch$"
  assert_match "dev: pane map has dev, checks, console" "$(cat "$RUN/panes.txt")" '^dev: +pane-1 '
  assert_match "dev: console is pane-4"                 "$(cat "$RUN/panes.txt")" '^console: +pane-4 '

  # Lane A runs where bootstrap is run from, which is often a herdr worktree
  # of the checkout, not the main checkout repo_root() resolves to.
  r=$(fixture_repo bun-vitest); wt="$TMP/repos/bun-vitest-wt"
  git -C "$r" worktree add -q "$wt" -b wt-branch
  RUN="$TMP/run-worktree"; reset_stub
  boot "$wt" "$RUN" "Worktree" wt-branch >/dev/null
  assert_match "worktree: lane A checkout is where bootstrap ran, not repo_root" "$(cat "$RUN/panes.txt")" '^lane A: +pane-2 +\(agent "[^"]+", kind claude, branch wt-branch, checkout '"$wt"', model '
  assert_match "worktree: checks pane cds into the worktree"  "$(cat "$HERDR_STUB_LOG")" "^herdr pane run pane-1 cd $wt/\. && "

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
      assert_eq "quoted path ($name, $sh): checks pane runs in the checkout" "$(cd "$TMP/repos/quoted" && pane_cwd "$sh" pane-3)" "$r"
      assert_eq "quoted path ($name, $sh): dev pane runs in its dir"         "$(cd "$TMP/repos/quoted" && pane_cwd "$sh" pane-1)" "$r/web"
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
  assert_match "busy pane: giving up says what to do"   "$out" 'pane pane-2 is still not a ready shell after 3 tries; check it, or raise START_TRIES'
  assert_match "busy pane: giving up fails bootstrap"    "$out" 'exit=1$'

  # A fresh checkout's trust prompt blocks the start: it is answered, and the
  # agent is started again only when herdr says it is not there.
  S="$HERDR_STUB_STATES_DIR"
  for case in "gone:2:0" "working:1:0" "idle:1:0" "unreachable:1:1" "blocked:1:1" "unknown:1:1"; do
    IFS=: read -r state starts code <<< "$case"
    r=$(fixture_repo bun-vitest); RUN="$TMP/run-trust-$state"; reset_stub; echo "$state" > "$S/bun-vitest-lane-a"
    out=$(HERDR_STUB_TRUST_STARTS=1 boot "$r" "$RUN" "Trust" main; echo "exit=$?")
    assert_match "trust prompt: answered"                "$(cat "$HERDR_STUB_LOG")" '^herdr pane send-keys pane-2 Down Enter$'
    assert_eq "trust prompt, agent $state: starts"       "$(grep -c '^herdr agent start bun-vitest-lane-a ' "$HERDR_STUB_LOG")" "$starts"
    assert_match "trust prompt, agent $state: exit $code" "$out" "exit=$code\$"
    case $state in
      unreachable) assert_match "trust prompt, herdr failing: says so" "$out" 'herdr cannot say whether bun-vitest-lane-a started' ;;
      unknown)     assert_match "trust prompt, agent unknown: says so" "$out" 'bun-vitest-lane-a is still unknown in pane pane-2 after its trust prompt was answered' ;;
    esac
  done
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-trust-keys"; reset_stub
  out=$(HERDR_STUB_TRUST_STARTS=1 HERDR_STUB_SEND_KEYS_FAIL=1 boot "$r" "$RUN" "Trust" main; echo "exit=$?")
  assert_match "trust prompt, send-keys failing: bootstrap fails, saying so" "$out" "could not answer bun-vitest-lane-a's trust prompt in pane pane-2"
  assert_match "trust prompt, send-keys failing: exit 1" "$out" 'exit=1$'
  # Lane A's agent exits twice: nothing to brief, and bootstrap says so.
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-gone-a"; reset_stub
  printf 'gone\ngone\n' > "$S/bun-vitest-lane-a.started"
  out=$(boot "$r" "$RUN" "Gone" main; echo "exit=$?")
  rm -f "$S"/bun-vitest-lane-a*
  assert_match "lane A gone twice: bootstrap fails" "$out" 'exit=1$'
  assert_match "lane A gone twice: says there is no agent to brief" "$out" "lane A's agent bun-vitest-lane-a is not running in pane-2: .*rerun bootstrap\.sh with a new run dir"
  assert_nomatch "lane A gone twice: not told to brief it" "$out" 'brief it once it accepts input'
  rm -f "$S/bun-vitest-lane-a"
  # herdr stops answering once lane A started: bootstrap cannot say whether it
  # runs, and says so instead of telling to brief it.
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-unread-a"; reset_stub
  echo unreachable > "$S/bun-vitest-lane-a.started"
  out=$(READY_WAIT_SECONDS=2 boot "$r" "$RUN" "Unread" main; echo "exit=$?")
  rm -f "$S"/bun-vitest-lane-a*
  assert_match "lane A unreadable: bootstrap fails" "$out" 'exit=1$'
  assert_match "lane A unreadable: says herdr cannot answer" "$out" "bootstrap: herdr cannot say whether lane A's agent bun-vitest-lane-a runs in pane-2; .*check that pane, and with the agent there brief it once  herdr agent get bun-vitest-lane-a  shows interactive_ready true; with none, rerun bootstrap\.sh with a new run dir"
  assert_nomatch "lane A unreadable: not told to brief it once it accepts input" "$out" 'brief it once it accepts input'
  assert_nomatch "lane A unreadable: not told to rerun once herdr answers" "$out" 'rerun once herdr answers'
fi

# --- add-lane ----------------------------------------------------------------
if section add-lane; then
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-grid"; reset_stub
  (cd "$r" && "$KIT/bootstrap.sh" "$RUN" "Grid" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
  lane() { (cd "$r" && "$KIT/add-lane.sh" "$RUN" "$@" 2>&1); }
  reset_stub; out=$(lane B feat/b main 2,3); log=$(cat "$HERDR_STUB_LOG")
  assert_eq "B: the board has lane B owning its tasks" "$(board "$RUN" '",".join(d["lanes"].get("B", []))')" "2,3"
  assert_match "B: worktree under .worktrees"         "$log" "^herdr worktree create --cwd $r --branch feat/b --base main --path $r/.worktrees/feat/b --label bun-vitest-lane-b --no-focus$"
  assert_match "B: placed right of lane A"            "$log" '^herdr pane move pane-[0-9]+ --tab tab-0 --split right --target-pane pane-2 --ratio 0.5 --no-focus$'
  assert_match "B: agent start"                       "$log" '^herdr agent start bun-vitest-lane-b --kind claude --pane '
  assert_match "B: install not typed into the pane"   "$out" '\[dry-run\] \(cd .*/.worktrees/feat/b && bun install\) > '"$RUN"'/install-B.log'
  assert_eq    "B: nothing typed into the lane pane"  "$(grep -c '^herdr pane run' "$HERDR_STUB_LOG")" 0
  assert_match "B: pane map line"                     "$(cat "$RUN/panes.txt")" '^lane B: +pane-[0-9]+ +\(agent "bun-vitest-lane-b", kind claude, branch feat/b, checkout '"$r"'/.worktrees/feat/b, model '
  assert_match "B: prints the next step"              "$out" 'lane B ready'
  reset_stub; out=$(lane C feat/c main 4)
  assert_match "C: placed under lane A"               "$(cat "$HERDR_STUB_LOG")" '--split down --target-pane pane-2 '
  bpane=$(sed -nE 's/^lane B: +([^ ]+).*/\1/p' "$RUN/panes.txt")
  reset_stub; out=$(lane D feat/d main 5)
  assert_match "D: placed under lane B"               "$(cat "$HERDR_STUB_LOG")" "--split down --target-pane $bpane "
  assert_match "E: refused, four lanes at most"       "$(lane E feat/e main 6)" 'B, C or D'
  assert_match "A: refused, bootstrap starts it"      "$(lane A feat/a main 1)" 'lane A is started by bootstrap'
  assert_match "B again: refused"                     "$(lane B feat/b2 main 7)" 'lane B already exists'
  r2=$(fixture_repo bun-vitest); RUN2="$TMP/run-grid2"; reset_stub
  (cd "$r2" && "$KIT/bootstrap.sh" "$RUN2" "Grid2" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
  assert_match "D before B: refused"                  "$(cd "$r2" && "$KIT/add-lane.sh" "$RUN2" D feat/d main 5 2>&1)" 'lane D goes under lane B, which does not exist yet'
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
  assert_match "failed start: says how to resume"      "$out" 'lane B is in the pane map, starting: rerun  .*/add-lane\.sh .* B feat/b main 2,3  to resume it'
  bpane=$(sed -nE 's/^lane B: +([^ ]+).*/\1/p' "$RUNF/panes.txt")
  echo gone > "$HERDR_STUB_STATES_DIR/bun-vitest-lane-b"
  mkdir -p "$r/.worktrees/feat/b"   # the stub's worktree create makes none
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
  echo gone > "$HERDR_STUB_STATES_DIR/bun-vitest-lane-b"
  rm -rf "$r/.worktrees/feat/b"
  reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNF" B feat/b main 2,3 2>&1; echo "exit=$?")
  assert_match "rerun, worktree removed: refused, saying what to remove" "$out" "lane B's checkout .*/\.worktrees/feat/b is gone: close its pane $bpane and remove its line"
  assert_nomatch "rerun, worktree removed: no start"   "$(cat "$HERDR_STUB_LOG")" '^herdr agent start'
  mkdir -p "$r/.worktrees/feat/b"; echo gone > "$HERDR_STUB_STATES_DIR/$bpane"
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
    echo gone > "$HERDR_STUB_STATES_DIR/bun-vitest-lane-$ln"; mkdir -p "$r/.worktrees/$br"
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
  # A start that never accepts input leaves the lane's line ending in
  # "starting" and its agent running; a rerun takes the agent once it accepts
  # input, starts it again when it is gone, and otherwise says to end it.
  r=$(fixture_repo bun-vitest); RUNR="$TMP/run-slow-lane"; reset_stub
  (cd "$r" && "$KIT/bootstrap.sh" "$RUNR" "Slow" main "$KIT/example-tasks.tsv" >/dev/null 2>&1); reset_stub
  echo unready > "$HERDR_STUB_STATES_DIR/bun-vitest-lane-b.started"
  out=$(cd "$r" && READY_WAIT_SECONDS=1 "$KIT/add-lane.sh" "$RUNR" B feat/b main 2 2>&1; echo "exit=$?")
  rm -f "$HERDR_STUB_STATES_DIR/bun-vitest-lane-b.started"; mkdir -p "$r/.worktrees/feat/b"
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
  assert_match "rerun, agent now ready: its line is no longer starting" "$(cat "$RUNR/panes.txt")" '^lane B: .*model [^ ]+\)$'
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
  mkdir -p "$r/.worktrees/feat/b"   # the stub's worktree create makes none
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
  assert_match "failed move, rerun: the recorded pane is moved" "$log" "^herdr pane move $wtpane --tab tab-0 --split right --target-pane pane-2 "
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
  mkdir -p "$r/.worktrees/feat/b"; before=$(cat "$RUNG/panes.txt")
  reset_stub; out=$(cd "$r" && PATH="$gbin:$PATH" "$KIT/add-lane.sh" "$RUNG" B feat/b main 2,3 2>&1; echo "exit=$?")
  assert_match "map read fails: add-lane fails"        "$out" 'exit=1$'
  assert_match "map read fails: says how to recover"   "$out" "could not rewrite .*/panes\.txt; lane B's pane is pane-[0-9]+: turn its unplaced line into  lane B: pane-[0-9]+  \(the rest as it is\) and rerun"
  assert_eq "map read fails: the pane map is unchanged" "$(cat "$RUNG/panes.txt")" "$before"
  assert_nomatch "map read fails: no agent start"      "$(cat "$HERDR_STUB_LOG")" '^herdr agent start'
  assert_eq "map read fails: no scratch map left"      "$(compgen -G "$RUNG/panes.txt.*" || true)" ""
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

# --- add-reviewer ------------------------------------------------------------
if section add-reviewer; then
  S="$HERDR_STUB_STATES_DIR"
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-review"; reset_stub
  (cd "$r" && "$KIT/bootstrap.sh" "$RUN" "Review" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
  review() { (cd "$r" && EXIT_WAIT_SECONDS=3 "$KIT/add-reviewer.sh" "$RUN" "$@" 2>&1); }
  line_of() { grep -nE -- "$1" "$HERDR_STUB_LOG" | head -1 | cut -d: -f1; }
  reset_stub; out=$(review R1 claude "Lane review A" "$RUN/findings/lane-a.json"); log=$(cat "$HERDR_STUB_LOG")
  assert_match "first call: a new tab in the run's workspace" "$log" "^herdr tab create --workspace ws-0 --cwd $r --label reviews --no-focus$"
  assert_match "the workspace is the orchestrator pane's" "$log" '^herdr pane get pane-0$'
  assert_match "first call: R2 split right of R1"     "$log" '^herdr pane split --pane pane-1 --direction right --ratio 0.5 '
  assert_match "first call: prints both slot ids"     "$out" 'R1 pane-1, R2 pane-2'
  map=$(cat "$RUN/panes.txt")
  assert_match "pane map: review tab line"            "$map" '^review tab: +tab-1 +\(R1 pane-1, R2 pane-2\)$'
  assert_match "pane map: reviewer R1 line"           "$map" '^reviewer R1: +pane-1 +\(agent "bun-vitest-r1-1", kind codex, model gpt-6-astra, review "Lane review A", findings '"$RUN"'/findings/lane-a.json\)$'
  assert_match "R1: a claude lane gets a codex Reviewer" "$log" '^herdr agent start bun-vitest-r1-1 --kind codex --pane pane-1 -- -m gpt-6-astra '
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

  reset_stub; out=$(review R2 codex "Lane review B" "$RUN/findings/lane-b.json"); log=$(cat "$HERDR_STUB_LOG")
  assert_nomatch "second call: no new tab"            "$log" '^herdr tab create'
  assert_nomatch "second call: no new pane"           "$log" '^herdr pane split'
  assert_match "R2: a codex lane gets a claude Reviewer in the R2 pane" "$log" '^herdr agent start bun-vitest-r2-1 --kind claude --pane pane-2 -- --model claude-opus-5-5$'
  assert_nomatch "claude Reviewer: no codex environment" "$log" 'shell_environment_policy'
  assert_eq "R2: board task owned by R2"              "$(reviews "$RUN")" "R1-1@R1:Lane review A R2-1@R2:Lane review B"
  assert_eq "pane map: one review tab line"           "$(grep -c '^review tab:' "$RUN/panes.txt")" 1

  printf 'working\n' > "$S/bun-vitest-r1-1"; reset_stub
  out=$(review R1 claude "Lane review A, round 2" "$RUN/findings/lane-a-2.json")
  assert_match "a slot whose Reviewer is still working is refused" "$out" 'bun-vitest-r1-1 is still working in R1'
  assert_nomatch "that refusal starts nothing"        "$(cat "$HERDR_STUB_LOG")" '^herdr (agent start|pane send)'
  assert_eq "that refusal adds no board task"         "$(reviews "$RUN")" "R1-1@R1:Lane review A R2-1@R2:Lane review B"
  printf 'idle\ngone\n' > "$S/bun-vitest-r1-1"; reset_stub
  out=$(review R1 claude "Lane review A, round 2" "$RUN/findings/lane-a-2.json"); log=$(cat "$HERDR_STUB_LOG")
  assert_match "again in R1: the previous Reviewer is sent /exit" "$log" '^herdr pane send-text pane-1 /exit$'
  assert_match "again in R1: and Enter"               "$log" '^herdr pane send-keys pane-1 Enter$'
  assert_eq "again in R1: one Enter when the first one ends it" "$(grep -c '^herdr pane send-keys pane-1 Enter$' "$HERDR_STUB_LOG")" 1
  [ "$(line_of '^herdr pane send-keys pane-1 Enter')" -lt "$(line_of '^herdr agent start')" ] && ok "again in R1: ended before the new agent starts" || bad "again in R1: ended before the new agent starts" "$log"
  assert_match "again in R1: a new agent in the same pane" "$log" '^herdr agent start bun-vitest-r1-2 --kind codex --pane pane-1 '
  assert_eq "pane map: one line per slot"             "$(grep -c '^reviewer R1:' "$RUN/panes.txt")" 1
  assert_match "pane map: the slot line is the new review" "$(cat "$RUN/panes.txt")" '^reviewer R1: +pane-1 +\(agent "bun-vitest-r1-2", .*review "Lane review A, round 2"'
  assert_match "pane map: R2 line kept"               "$(cat "$RUN/panes.txt")" '^reviewer R2: +pane-2 +\(agent "bun-vitest-r2-1"'

  printf 'idle\n' > "$S/bun-vitest-r1-2"; reset_stub
  out=$(review R1 claude "Preflight R1" "$RUN/findings/preflight-r1.json")
  assert_match "a Reviewer that does not exit is refused" "$out" 'bun-vitest-r1-2 did not exit; end it in pane-1 and rerun'
  assert_eq "within 3 checks, one Enter: no retry storm" "$(grep -c '^herdr pane send-keys pane-1 Enter$' "$HERDR_STUB_LOG")" 1
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
  assert_match "herdr failing after /exit: /exit was sent" "$(cat "$HERDR_STUB_LOG")" '^herdr pane send-text pane-1 /exit$'
  assert_match "herdr failing after /exit: not read as exited, herdr named" "$out" 'herdr cannot say whether Reviewer bun-vitest-r1-2 exited'
  assert_nomatch "herdr failing after /exit: no agent start" "$(cat "$HERDR_STUB_LOG")" '^herdr agent start'
  # herdr's own unknown status is an agent it cannot classify: it is there,
  # and is sent /exit like an idle one.
  echo unknown > "$S/bun-vitest-r1-2"; reset_stub
  out=$(EXIT_WAIT_SECONDS=2 review R1 claude "Preflight R1" "$RUN/findings/preflight-r1.json")
  assert_match "herdr's unknown: the previous Reviewer is sent /exit" "$(cat "$HERDR_STUB_LOG")" '^herdr pane send-text pane-1 /exit$'
  assert_match "herdr's unknown: ... and waited for"  "$out" 'bun-vitest-r1-2 did not exit'
  echo gone > "$S/bun-vitest-r1-2"; reset_stub
  out=$(REVIEWER_MODEL=gpt-6-astra-pro review R1 claude "Preflight R1" "$RUN/findings/preflight-r1.json"); log=$(cat "$HERDR_STUB_LOG")
  assert_nomatch "an exited Reviewer is not sent /exit" "$log" '^herdr pane send-text'
  assert_match "REVIEWER_MODEL reaches the agent start" "$log" '^herdr agent start bun-vitest-r1-3 --kind codex --pane pane-1 -- -m gpt-6-astra-pro '
  echo gone > "$S/bun-vitest-r2-1"
  out=$(CODEX_STUB=absent review R2 claude "Preflight R2" "$RUN/findings/preflight-r2.json")
  assert_match "a fallback is printed"                "$out" '^reviewer: fallback: codex is not installed'
  assert_match "a slot other than R1 or R2 is refused" "$(review R3 claude "X" "$RUN/findings/x.json")" "slot must be R1 or R2 \(got 'R3'\)"
  assert_match "a bad lane kind is refused"            "$(review R1 cursor "X" "$RUN/findings/x.json")" "lane kind must be claude or codex"
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
  assert_match "a switch value with spaces: the pane map quotes it" "$(cat "$RUNQ/panes.txt")" "^switches: .* REVIEWER_MODEL='it'\\\\''s my model \\*' .* PR_TEMPLATE='it'\\\\''s my template.md'\$"
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
  assert_match "blocked after its start: its agent is in the pane map" "$(cat "$RUNB/panes.txt")" '^reviewer R1: +pane-1 +\(agent "bun-vitest-r1-1", .*review "Blocked"'
  printf 'blocked\nblocked\ngone\n' > "$S/bun-vitest-r1-1"; : > "$HERDR_STUB_LOG"   # read for resuming, for ending, then gone
  out=$(cd "$r" && EXIT_WAIT_SECONDS=3 "$KIT/add-reviewer.sh" "$RUNB" R1 claude "Blocked again" "$RUNB/findings/a.json" 2>&1; echo "exit=$?"); log=$(cat "$HERDR_STUB_LOG")
  assert_match "rerun: finishes"                      "$out" 'exit=0$'
  assert_match "rerun: the agent left in the slot is sent /exit" "$log" '^herdr pane send-text pane-1 /exit$'
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
  assert_match "rerun, agent now ready: says it resumes it" "$out" 'resuming bun-vitest-r2-1 in pane-2'
  assert_match "rerun, agent now ready: ready"        "$out" 'reviewer R2 ready \(task R2-1\)'
  assert_match "rerun, agent now ready: its line is no longer starting" "$(cat "$RUNB/panes.txt")" '^reviewer R2: .*review "Slow".*\)$'
  # A starting Reviewer that is working and accepts input is kept, as
  # add-lane keeps such a lane.
  echo unready > "$S/bun-vitest-r2-2.started"; echo gone > "$S/bun-vitest-r2-1"; reset_stub
  out=$(cd "$r" && READY_WAIT_SECONDS=1 "$KIT/add-reviewer.sh" "$RUNB" R2 claude "Busy" "$RUNB/findings/w.json" 2>&1; echo "exit=$?")
  rm -f "$S/bun-vitest-r2-2.started"; echo working > "$S/bun-vitest-r2-2"; : > "$HERDR_STUB_LOG"
  out=$(cd "$r" && "$KIT/add-reviewer.sh" "$RUNB" R2 claude "Busy" "$RUNB/findings/w.json" 2>&1; echo "exit=$?")
  assert_match "starting, working and ready: resumed" "$out" 'resuming bun-vitest-r2-2 in pane-2'
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
  assert_match "starting, working, not ready: resumed once ready" "$out" 'resuming bun-vitest-r2-3 in pane-2'
  assert_nomatch "starting, working, not ready: not refused as working" "$out" 'still working'
  assert_nomatch "starting, working, not ready: not ended, not started" "$log" '^herdr (pane send-text|agent start)'
  # One that stays so: the rerun says it is still starting, and a rerun
  # resumes it once it accepts input.
  echo gone > "$S/bun-vitest-r2-3"; echo unready > "$S/bun-vitest-r2-4.started"; reset_stub
  out=$(cd "$r" && READY_WAIT_SECONDS=1 "$KIT/add-reviewer.sh" "$RUNB" R2 claude "Stuck" "$RUNB/findings/s.json" 2>&1; echo "exit=$?")
  rm -f "$S/bun-vitest-r2-4.started"; echo busy-unready > "$S/bun-vitest-r2-4"; : > "$HERDR_STUB_LOG"
  out=$(cd "$r" && READY_WAIT_SECONDS=2 "$KIT/add-reviewer.sh" "$RUNB" R2 claude "Stuck" "$RUNB/findings/s.json" 2>&1; echo "exit=$?"); log=$(cat "$HERDR_STUB_LOG")
  assert_match "starting, never ready on the rerun: fails" "$out" 'exit=1$'
  assert_match "starting, never ready on the rerun: says it is still starting" "$out" 'Reviewer bun-vitest-r2-4 is still starting in pane-2: .*rerun  .*add-reviewer\.sh .* R2 claude Stuck .*/findings/s\.json  to resume it once it accepts input'
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
  assert_match "rerun as another kind: the kept agent is ended" "$log" '^herdr pane send-text pane-1 /exit$'
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
  r=$(fixture_repo bun-vitest); (cd "$r" && CLAUDE_STUB=absent EXECUTOR_KIND=claude "$KIT/bootstrap.sh" "$RUNM2" "Model2" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
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
    echo "$dir"
  }
  RUN=$(watch_run open); RUN_COMPLETE=$(watch_run complete); RUN_CLOSED=$(watch_run closed)
  watch() { (cd "$TMP" && ROUND_SECONDS="${ROUND:-3}" GRACE_SECONDS=0 POLL_SECONDS=0 "$KIT/watch-lanes.sh" "${ON:-$RUN}" "$@" 2>&1; echo "exit=$?"); }
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
  # lane's final review comes after its last task); a closed run always is.
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
  assert_match "pin: a clean contract reaches add-lane" "$(cat "$RUNP/panes.txt")" '^lane B: .*kind codex, .*model gpt-6-astra-mini\)'
  # A lane rewrites the contract and it lands in the checkout (its commit, a merge).
  printf 'EXECUTOR_MODEL=lane-written\ntouch "%s"\n' "$TMP/pin-ran-lane" >> "$r/.orchestrate"; git -C "$r" commit -qam lane
  reset_stub; out=$(cd "$r" && "$KIT/add-lane.sh" "$RUNP" C feat/c main 3 2>&1)
  assert_match "pin: a lane-modified contract does not reach add-lane" "$(cat "$RUNP/panes.txt")" '^lane C: .*kind codex, .*model gpt-6-astra-mini\)'
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
  assert_match "pin: a relative run dir at bootstrap has the pin add-lane finds" "$(cat "$r/run-rel/panes.txt")" '^lane B: .*kind codex, .*model gpt-6-astra-mini\)'
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

# --- look --------------------------------------------------------------------
if section look; then
  # A harmless check gate for the fixtures without suite lines or scripts, so
  # the suite part of the look is green unless a test says otherwise.
  export CHECK_CMD=true
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
  # One line per verdict row: "step status note".
  verdict() { python3 -c "import json,sys
for v in json.load(open(sys.argv[1]))['verdict']: print('%s %s %s' % (v['step'], v['status'], v['note']))" "$1"; }
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
  # A sparse checkout can lack a changed file without the tree being dirty.
  git -C "$r" update-index --skip-worktree new.py; rm "$r/new.py"; reset_stub; out=$(look "$r" base "$F")
  assert_nomatch "look: a changed file missing from a sparse checkout is not scanned" "$(cat "$HERDR_STUB_LOG")" '^semgrep .*new\.py'
  assert_match "look: ... the rest is still scanned"    "$(cat "$HERDR_STUB_LOG")" '^semgrep scan .* -- app\.js café app\.js$'
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
  assert_eq "look: every suite step runs in its DIR, in contract order" "$(cat "$SUITE_ORDER")" "$(printf 'lint %s\ntest %s\nbuild %s/web' "$r" "$r" "$r")"
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
  unset CHECK_CMD SUITE_ORDER; unset -f look_repo findings verdict look
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
  real_for_sums="case \"\$*\" in *SHA256SUMS*) exec '$REAL_CURL' \"\$@\" ;; esac"
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
  ln -s "$ROOT/node_modules" "$P/node_modules"
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
  assert_match "run: the pane map has the review tab"  "$map" '^review tab: +tab-[0-9]+ +\(R1 pane-[0-9]+, R2 pane-[0-9]+\)$'
  assert_match "run: lane A is reviewed by codex in R1" "$map" '^reviewer R1: .*kind codex, model gpt-6-astra, review "Lane review A, round 1"'
  assert_match "run: lane B is reviewed by claude in R2" "$map" '^reviewer R2: .*kind claude, model claude-opus-5-5, review "Lane review B, round 1"'
  r1=$(sed -nE 's/^review tab: .*\(R1 ([^,]+),.*/\1/p' "$RUN/panes.txt")

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
  out=$(in_repo "$PREFLIGHT_DIR/look.sh" base "$RUN/findings/preflight/1")
  assert_match "run: look.sh names the findings file it wrote" "$out" "$RUN/findings/preflight/1/look.json"
  steps=$(python3 -c "import json,sys; print(' '.join(v['step']+':'+v['status'] for v in json.load(open(sys.argv[1]))['verdict']))" "$RUN/findings/preflight/1/look.json" 2>&1)
  assert_eq "run: look.json has a row for the base, each scanner and every suite step" "$steps" "base:skip semgrep:pass gitleaks:pass lint:skip test:fail build:pass"
  unset SUITE_ORDER

  assert_eq "run: one switches line in the pane map" "$(grep -c '^switches:' "$RUN/panes.txt")" 1
  assert_eq "run: one reviewer line in the pane map" "$(grep -c '^reviewer:' "$RUN/panes.txt")" 1
  assert_eq "run: one switches note in the record"   "$(notes "$RUN" | grep -c '^switches:')" 1
  assert_eq "run: one reviewer note in the record"   "$(notes "$RUN" | grep -c '^reviewer:')" 1
  unset -f in_repo review
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
fi

[ -z "$ONLY" ] || [ "$MATCHED" = 1 ] || { echo "test.sh: no section named $ONLY (./test.sh --list)" >&2; exit 2; }
[ "$LIST" = 0 ] || exit 0
echo; echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
