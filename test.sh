#!/usr/bin/env bash
# The kit's tests. They need neither herdr nor tower: DRY_RUN=1 puts tests/stub
# first on PATH, so every herdr and tower call is logged and answered by a stub.
#
#   ./test.sh            all sections
#   ./test.sh bootstrap  one section (a word from the "# ---" headings below)
set -u
KIT="$(cd "$(dirname "$0")" && pwd)"; export KIT
ONLY="${1:-}"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; shift; printf '     %s\n' "$@"; }
assert_eq()      { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected: $3" "got:      $2"; }
assert_match()   { printf '%s\n' "$2" | grep -qE -- "$3" && ok "$1" || bad "$1" "no match for /$3/ in:" "$2"; }
assert_nomatch() { printf '%s\n' "$2" | grep -qE -- "$3" && bad "$1" "unexpected match for /$3/ in:" "$2" || ok "$1"; }
section() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP"' EXIT
export DRY_RUN=1 HERDR_STUB_LOG="$TMP/log" HERDR_STUB_COUNTER="$TMP/counter" HERDR_STUB_STATES_DIR="$TMP/states"
# common.sh only defaults HERDR_PANE_ID/HERDR_TAB_ID when unset, so running
# test.sh from inside a real herdr pane (as its own agent does) would
# otherwise leak this pane's real ids into every assertion instead of the
# pane-0/tab-0 the plan's assertions expect.
unset HERDR_PANE_ID HERDR_TAB_ID
mkdir -p "$HERDR_STUB_STATES_DIR"

# Guard: every section below runs herdr/tower calls through common.sh's
# DRY_RUN PATH shim. If a stub is missing, not executable, or shadowed by
# something earlier on PATH, refuse outright rather than risk a script under
# test touching the real herdr or tower (this happened once: HERDR_ENV=1 is
# inherited from the orchestrating pane, so `in_herdr` alone does not stop a
# script run outside test.sh and outside DRY_RUN=1 from driving real panes).
for _tool in herdr tower claude codex; do
  _which=$(bash -c ". \"$KIT/common.sh\"; command -v $_tool" 2>/dev/null || true)
  [ "$_which" = "$KIT/tests/stub/$_tool" ] || { echo "test.sh: $_tool resolves to '$_which', not the stub ($KIT/tests/stub/$_tool) — refusing to run" >&2; exit 1; }
done
unset _tool _which
reset_stub() { : > "$HERDR_STUB_LOG"; rm -f "$HERDR_STUB_COUNTER"; }
# A git repo built from tests/fixtures/<name> (or empty). Prints its path.
fixture_repo() {
  local d="$TMP/repos/$1"
  mkdir -p "$d"
  [ -d "$KIT/tests/fixtures/$1" ] && cp -R "$KIT/tests/fixtures/$1/." "$d/"
  git -C "$d" init -q && git -C "$d" commit -q --allow-empty -m init
  echo "$d"
}
in_kit() { bash -c ". \"\$KIT/common.sh\"; $1" 2>&1; }

# --- common ------------------------------------------------------------------
if section common; then
  assert_eq "tower_ok: stub tower 0.2.0 is 0"     "$(in_kit 'tower_ok; echo $?')" 0
  assert_eq "tower_ok: old tower is 2"           "$(TOWER_STUB=old in_kit 'tower_ok; echo $?')" 2
  assert_eq "tower_ok: absent tower is 1"        "$(TOWER_STUB=absent in_kit 'tower_ok; echo $?')" 1
  assert_match "need names the missing tool"     "$(in_kit 'need git nosuchtool')" "missing dependency: nosuchtool"
  assert_match "in_herdr passes under DRY_RUN"   "$(in_kit 'in_herdr && echo inside')" "^inside$"
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
  rev() { HOME="$TMP/rev-home" bash -c ". \"\$KIT/common.sh\"; . \"\$KIT/executor.sh\"; reviewer_for $1" 2>&1; }
  T=$(printf '\t')
  assert_eq "reviewer: both kinds, a claude lane gets codex on gpt-6-astra" "$(rev claude)" "codex${T}gpt-6-astra${T}"
  assert_eq "reviewer: both kinds, a codex lane gets claude on claude-opus-5-5" "$(rev codex)" "claude${T}claude-opus-5-5${T}"
  assert_eq "reviewer: claude only, a claude lane gets claude on claude-fable-5-1 with a note" \
    "$(CODEX_STUB=absent rev claude)" "claude${T}claude-fable-5-1${T}fallback: codex is not installed, so claude reviews claude on another model"
  assert_eq "reviewer: codex only, a codex lane gets codex on the executor's model with a note" \
    "$(CLAUDE_STUB=absent EXECUTOR_KIND=codex EXECUTOR_MODEL=gpt-6-astra-mini rev codex)" "codex${T}gpt-6-astra-mini${T}fallback: claude is not installed, so a fresh codex agent reviews codex on the same model"
  assert_eq "reviewer: REVIEWER_KIND=claude forces its own kind on a claude lane" "$(REVIEWER_KIND=claude rev claude)" "claude${T}claude-fable-5-1${T}"
  assert_eq "reviewer: REVIEWER_KIND=codex on a codex lane"   "$(REVIEWER_KIND=codex rev codex)" "codex${T}gpt-6-astra${T}"
  assert_eq "reviewer: REVIEWER_MODEL overrides the model"   "$(REVIEWER_MODEL=gpt-6-astra-pro rev claude)" "codex${T}gpt-6-astra-pro${T}"
  assert_eq "reviewer: REVIEWER_MODEL overrides a fallback's model" "$(CODEX_STUB=absent REVIEWER_MODEL=sonnet rev claude)" "claude${T}sonnet${T}fallback: codex is not installed, so claude reviews claude on another model"
  assert_match "reviewer: a forced kind that is not installed is refused" "$(CODEX_STUB=absent REVIEWER_KIND=codex rev claude; echo "exit=$?")" "REVIEWER_KIND=codex, but codex is not installed"
  assert_match "reviewer: the refusal exits non-zero" "$(CODEX_STUB=absent REVIEWER_KIND=codex rev claude; echo "exit=$?")" "exit=1$"
  assert_match "reviewer: neither kind installed is refused" "$(CODEX_STUB=absent CLAUDE_STUB=absent rev claude)" "neither claude nor codex is installed"
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
  r=$(fixture_repo contract)
  assert_eq "contract: CHECK_CMD"                   "$(detect_in "$r" 'echo "$CHECK_CMD"')" "make check"
  assert_eq "contract: panes in order with dirs"    "$(detect_in "$r" 'echo "${PANE_NAMES[*]}|${PANE_CMDS[1]}|${PANE_DIRS[1]}"')" "checks dev|make dev|web"
  assert_eq "contract: harness, models and stale"   "$(detect_in "$r" 'echo "$EXECUTOR_KIND $EXECUTOR_MODEL $SPEC_REVIEWER_MODEL $QUALITY_REVIEWER_MODEL $STALE"')" "codex gpt-6-astra-mini haiku sonnet 45"
  assert_eq "contract: the environment wins over the file" "$(EXECUTOR_KIND=claude STALE=5 detect_in "$r" 'echo "$EXECUTOR_KIND $STALE $EXECUTOR_MODEL"')" "claude 5 gpt-6-astra-mini"
  assert_match "contract: an unknown setting is named" "$(detect_in "$(fixture_repo contract-typo)" 'echo reached')" "'MODEL' is not a setting"
  assert_match "contract: an unknown setting does not stop the script" "$(detect_in "$(fixture_repo contract-typo)" 'echo reached')" "^reached$"
  RUNC="$TMP/run-contract"; reset_stub
  (cd "$r" && "$KIT/bootstrap.sh" "$RUNC" "Contract" main >/dev/null 2>&1)
  assert_match "contract: bootstrap records the file's models" "$(cat "$HERDR_STUB_LOG")" '^tower init --title Contract --run '"$RUNC"' --model implementer=gpt-6-astra-mini --model spec-reviewer=haiku --model quality-reviewer=sonnet$'
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
  assert_eq "suite: none without suite lines" "$(detect_in "$(fixture_repo none)" 'echo ${#SUITE_NAMES[@]}')" 0
  r=$(fixture_repo contract-switches-bad)
  assert_match "switches: a bad value is refused with the allowed values" "$(detect_in "$r" 'echo reached')" "PR must be draft, ready or off \(got 'maybe'\)"
  assert_nomatch "switches: the refusal stops the script" "$(detect_in "$r" 'echo reached')" "^reached$"
  assert_match "switches: METHOD=fast is refused"          "$(METHOD=fast detect_in "$(fixture_repo none)" 'true')" "METHOD must be tdd or plain \(got 'fast'\)"
  assert_match "switches: REVIEWER_KIND=cursor is refused" "$(REVIEWER_KIND=cursor detect_in "$(fixture_repo none)" 'true')" "REVIEWER_KIND must be other, claude or codex \(got 'cursor'\)"
  assert_match "switches: LANE_REVIEW=yes is refused"      "$(LANE_REVIEW=yes detect_in "$(fixture_repo none)" 'true')" "LANE_REVIEW must be on or off \(got 'yes'\)"
  tr_="$TMP/repos/suite-typo"; mkdir -p "$tr_"; echo 'SUITE_SKP=build' > "$tr_/.herdr-orchestrate"
  assert_match "suite: a mistyped SUITE_ setting is named" "$(detect_in "$tr_" 'true')" "'SUITE_SKP' is not a setting"
  assert_eq "switches: an empty environment value clears the file's" "$(REVIEW_AREAS='' SUITE_SKIP='' detect_in "$(fixture_repo contract-switches)" 'echo "[$REVIEW_AREAS][$SUITE_SKIP]"')" "[][]"
  sr="$TMP/repos/suite-nocmd"; mkdir -p "$sr"; echo 'suite lint' > "$sr/.herdr-orchestrate"
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
  assert_match "empty: tower init without a source"     "$log" '^tower init --title Empty run --run '"$RUN"' --model implementer=claude-opus-5-5\[1m\] --model spec-reviewer=sonnet --model quality-reviewer=opus$'
  assert_nomatch "empty: no lane assignment"            "$log" '^tower assign'
  assert_match "layout: bottom row first"               "$log" '^herdr pane split --current --direction down --ratio 0.7 '
  assert_match "layout: lane A right of the orchestrator" "$log" '^herdr pane split --current --direction right --ratio 0.3 '
  assert_match "layout: console right of checks"        "$log" '^herdr pane split --pane pane-1 --direction right --ratio 0.5 '
  assert_match "layout: checks pane runs the runner in the checkout" "$log" "^herdr pane run pane-1 cd '$r/.' && bunx vitest --watch$"
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
  assert_match "switches: pane map has every switch"    "$map" '^switches: +TASK_REVIEW=on LANE_REVIEW=on PREFLIGHT=on STATIC_BASELINE=on PR=draft METHOD=tdd REVIEWER_KIND=other REVIEWER_MODEL= REVIEW_AREAS= SUITE_SKIP= PR_TEMPLATE=$'
  assert_match "switches: the record gets a tower note" "$log" '^tower note switches: TASK_REVIEW=on LANE_REVIEW=on .* PR_TEMPLATE=$'
  assert_match "switches: printed with the pane map"    "$out" '^switches: +TASK_REVIEW=on '
  assert_match "reviewer: pane map has kind and model"  "$map" '^reviewer: +kind codex, model gpt-6-astra$'
  assert_match "reviewer: the record gets a tower note" "$log" '^tower note reviewer: kind codex, model gpt-6-astra$'

  RUN="$TMP/run-planned"; reset_stub
  out=$(boot "$r" "$RUN" "Planned" main "$KIT/example-tasks.tsv")
  log=$(cat "$HERDR_STUB_LOG")
  assert_match "planned: tower init --tasks"            "$log" '^tower init --tasks '"$KIT"'/example-tasks.tsv --title Planned '
  assert_match "planned: every task to lane A"          "$log" '^tower assign A 1,2,3$'
  RUN="$TMP/run-lanes"; reset_stub
  out=$(LANES="A=1 B=2,3" boot "$r" "$RUN" "Lanes" main "$KIT/example-tasks.tsv")
  assert_match "planned: LANES assigns each lane"       "$(cat "$HERDR_STUB_LOG")" '^tower assign B 2,3$'
  out=$(LANES="A=1" boot "$r" "$TMP/run-x" "X" main)
  assert_match "empty: LANES without a source is refused" "$out" 'LANES needs a plan or task file'
  out=$(boot "$r" "$TMP/run-y" "Y" main /nonexistent.md)
  assert_match "a missing source is refused"            "$out" 'no such plan or task file'

  RUN="$TMP/run-notower"; reset_stub
  out=$(TOWER_STUB=absent boot "$r" "$RUN" "No tower" main)
  assert_match "no tower: info with the pointer"        "$out" 'tower is not installed'
  assert_eq "no tower: empty tasks.tsv with the header" "$(cat "$RUN/tasks.tsv")" "$(printf '# id\ttitle\tarea\tlane')"
  assert_eq "no tower: lanes.txt exists and is empty"   "$(cat "$RUN/lanes.txt" | wc -l | tr -d ' ')" 0
  assert_match "no tower: run.txt records the title"    "$(cat "$RUN/run.txt")" '^title: +No tower$'
  assert_match "no tower: run.txt has the switches"     "$(cat "$RUN/run.txt")" '^switches: +TASK_REVIEW=on LANE_REVIEW=on .* PR_TEMPLATE=$'
  assert_nomatch "no tower: no tower note"              "$(cat "$HERDR_STUB_LOG")" '^tower note'
  assert_match "no tower: run.txt has the reviewer"     "$(cat "$RUN/run.txt")" '^reviewer: +kind codex, model gpt-6-astra$'
  assert_match "no tower: console shows the git log"    "$(cat "$HERDR_STUB_LOG")" '^herdr pane run pane-3 while true; do clear; .*git log'
  assert_match "no tower: pane map says so"             "$(cat "$RUN/panes.txt")" '^console: +pane-3 +\(git log'
  RUN="$TMP/run-switches"; reset_stub
  out=$(PR=off boot "$(fixture_repo contract-switches)" "$RUN" "Switches" main)
  assert_match "switches: the file and the environment reach the pane map" "$(cat "$RUN/panes.txt")" '^switches: +TASK_REVIEW=off .* PR=off METHOD=plain .* SUITE_SKIP=build '
  out=$(boot "$(fixture_repo contract-switches-bad)" "$TMP/run-bad" "Bad" main)
  assert_match "switches: bootstrap refuses a bad value" "$out" "PR must be draft, ready or off"
  [ -e "$TMP/run-bad/panes.txt" ] && bad "switches: a refused run writes no pane map" || ok "switches: a refused run writes no pane map"
  RUN="$TMP/run-fallback"; reset_stub
  out=$(CODEX_STUB=absent boot "$r" "$RUN" "Fallback" main)
  assert_match "reviewer: a fallback is in the pane map" "$(cat "$RUN/panes.txt")" '^reviewer: +kind claude, model claude-fable-5-1 \(fallback: codex is not installed'
  assert_match "reviewer: a fallback is printed"         "$out" '^reviewer: +kind claude, model claude-fable-5-1 \(fallback: '
  assert_match "reviewer: a fallback goes to the record" "$(cat "$HERDR_STUB_LOG")" '^tower note reviewer: kind claude, model claude-fable-5-1 \(fallback: '
  out=$(CODEX_STUB=absent REVIEWER_KIND=codex boot "$r" "$TMP/run-forced" "Forced" main)
  assert_match "reviewer: bootstrap refuses a forced kind that is not installed" "$out" 'REVIEWER_KIND=codex, but codex is not installed'
  [ -e "$TMP/run-forced" ] && bad "reviewer: a refused run creates no run dir" || ok "reviewer: a refused run creates no run dir"
  RUN="$TMP/run-noreview"; reset_stub
  out=$(LANE_REVIEW=off PREFLIGHT=off CODEX_STUB=absent REVIEWER_KIND=codex boot "$r" "$RUN" "No review" main)
  assert_match "reviewer: none when lane review and preflight are off" "$(cat "$RUN/panes.txt")" '^reviewer: +none \(LANE_REVIEW=off, PREFLIGHT=off\)$'
  out=$(TOWER_STUB=absent boot "$r" "$TMP/run-nt2" "NT2" main "$KIT/example-tasks.tsv")
  assert_eq "no tower, planned: lane A owns all"        "$(cat "$TMP/run-nt2/lanes.txt")" "A=all"
  out=$(TOWER_STUB=old boot "$r" "$TMP/run-old" "Old" main)
  assert_match "old tower is refused"                   "$out" 'older than 0.2.0'
  [ -d "$TMP/run-old" ] && bad "old tower: nothing created" || ok "old tower: nothing created"

  r=$(fixture_repo contract); RUN="$TMP/run-dev"; reset_stub
  out=$(boot "$r" "$RUN" "Dev" main)
  log=$(cat "$HERDR_STUB_LOG")
  assert_match "dev: bottom row in thirds, checks after dev" "$log" '^herdr pane split --pane pane-1 --direction right --ratio 0.34 '
  assert_match "dev: console after checks"              "$log" '^herdr pane split --pane pane-3 --direction right --ratio 0.5 '
  assert_match "dev: dev pane runs in its dir"          "$log" "^herdr pane run pane-1 cd '$r/web' && make dev$"
  assert_match "dev: checks pane runs make watch"       "$log" "^herdr pane run pane-3 cd '$r/.' && make watch$"
  assert_match "dev: pane map has dev, checks, console" "$(cat "$RUN/panes.txt")" '^dev: +pane-1 '
  assert_match "dev: console is pane-4"                 "$(cat "$RUN/panes.txt")" '^console: +pane-4 '

  # Lane A runs where bootstrap is run from, which is often a herdr worktree
  # of the checkout, not the main checkout repo_root() resolves to.
  r=$(fixture_repo bun-vitest); wt="$TMP/repos/bun-vitest-wt"
  git -C "$r" worktree add -q "$wt" -b wt-branch
  RUN="$TMP/run-worktree"; reset_stub
  boot "$wt" "$RUN" "Worktree" wt-branch >/dev/null
  assert_match "worktree: lane A checkout is where bootstrap ran, not repo_root" "$(cat "$RUN/panes.txt")" '^lane A: +pane-2 +\(agent "[^"]+", kind claude, branch wt-branch, checkout '"$wt"', model '
  assert_match "worktree: checks pane cds into the worktree"  "$(cat "$HERDR_STUB_LOG")" "^herdr pane run pane-1 cd '$wt/.' && "
fi

# --- add-lane ----------------------------------------------------------------
if section add-lane; then
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-grid"; reset_stub
  (cd "$r" && "$KIT/bootstrap.sh" "$RUN" "Grid" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
  lane() { (cd "$r" && "$KIT/add-lane.sh" "$RUN" "$@" 2>&1); }
  reset_stub; out=$(lane B feat/b main 2,3); log=$(cat "$HERDR_STUB_LOG")
  assert_match "B: ownership first"                   "$log" '^tower assign B 2,3$'
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
  RUN2="$TMP/run-grid2"; reset_stub
  (cd "$r" && "$KIT/bootstrap.sh" "$RUN2" "Grid2" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
  assert_match "D before B: refused"                  "$(cd "$r" && "$KIT/add-lane.sh" "$RUN2" D feat/d main 5 2>&1)" 'lane D goes under lane B, which does not exist yet'
  assert_match "no pane map: refused"                 "$(cd "$r" && "$KIT/add-lane.sh" "$TMP/nowhere" B feat/b main 2 2>&1)" 'run bootstrap.sh first'
  RUN3="$TMP/run-nt"; reset_stub
  (cd "$r" && TOWER_STUB=absent "$KIT/bootstrap.sh" "$RUN3" "NT" main "$KIT/example-tasks.tsv" >/dev/null 2>&1)
  out=$(cd "$r" && TOWER_STUB=absent "$KIT/add-lane.sh" "$RUN3" B feat/b main 2,3 2>&1)
  assert_eq "no tower: ownership in lanes.txt"        "$(tail -1 "$RUN3/lanes.txt")" "B=2,3"
fi

# --- watch -------------------------------------------------------------------
if section watch; then
  S="$HERDR_STUB_STATES_DIR"; RUN="$TMP/run-watch"; mkdir -p "$RUN"
  watch() { (cd "$TMP" && ROUND_SECONDS="${ROUND:-3}" GRACE_SECONDS=0 POLL_SECONDS=0 "$KIT/watch-lanes.sh" "$RUN" "$@" 2>&1; echo "exit=$?"); }
  rm -f "$S"/*
  echo working > "$S/a"; out=$(ROUND=1 watch a)
  assert_match "quiet: exit 3"                        "$out" 'exit=3$'
  assert_nomatch "quiet: no attention line"           "$out" '^attention:'
  echo blocked > "$S/a"; printf 'need the API key\n' > "$S/a.tail"; out=$(watch a)
  assert_match "blocked: attention line first"        "$out" '^attention: a blocked'
  assert_match "blocked: tail printed"                "$out" 'need the API key'
  assert_match "blocked: exit 0"                      "$out" 'exit=0$'
  echo idle > "$S/a"; printf 'tower note --lane A ALL DONE - check green\n' > "$S/a.tail"; out=$(watch a)
  assert_match "idle after the final report"          "$out" '^attention: a idle-after-final-report'
  echo idle > "$S/a"; printf 'Running tests...\n' > "$S/a.tail"; out=$(watch a)
  assert_match "idle without a report is unexplained" "$out" '^attention: a idle-unexplained'
  echo gone > "$S/a"; out=$(watch a)
  assert_match "gone"                                 "$out" '^attention: a gone'
  echo working > "$S/a"; echo done > "$S/b"; out=$(watch a b)
  assert_match "two lanes: only the settled one"      "$out" '^attention: b done'
  assert_nomatch "two lanes: the working one is quiet" "$out" '^attention: a '
  assert_match "tower summary when tower is present"  "$out" '^--- tower'
  out=$(TOWER_STUB=absent watch b)
  assert_match "no tower: git log instead"            "$out" 'no tower: task state is in git'
fi

# --- install -----------------------------------------------------------------
if section install; then
  H="$TMP/home"; mkdir -p "$H"
  out=$(HOME="$H" "$KIT/install.sh" 2>&1; echo "exit=$?")
  assert_match "install: exit 0"                      "$out" 'exit=0$'
  assert_eq "install: ~/.claude/skills link"          "$(readlink "$H/.claude/skills/herdr-orchestrate")" "$KIT"
  assert_eq "install: ~/.agents/skills link"          "$(readlink "$H/.agents/skills/herdr-orchestrate")" "$KIT"
  assert_match "install: lists herdr as ok (stub)"    "$out" 'ok +herdr'
  assert_match "install: tower optional"              "$out" 'tower'
  assert_match "install: prints the two openings"     "$out" 'with a plan'
  out=$(HOME="$H" "$KIT/install.sh" 2>&1; echo "exit=$?")
  assert_match "install: idempotent"                  "$out" 'exit=0$'
  H2="$TMP/home2"; mkdir -p "$H2"
  out=$(HOME="$H2" "$KIT/install.sh" --check 2>&1; echo "exit=$?")
  assert_match "check: exit 0"                        "$out" 'exit=0$'
  [ -e "$H2/.claude/skills/herdr-orchestrate" ] && bad "check: links nothing" || ok "check: links nothing"
  # A PATH with everything the script needs except node.
  B="$TMP/bin"; mkdir -p "$B"; for t in git bash python3 dirname sed readlink mkdir ln cat tr grep; do ln -sf "$(command -v $t)" "$B/$t"; done
  out=$(HOME="$H2" PATH="$KIT/tests/stub:$B" "$KIT/install.sh" --check 2>&1; echo "exit=$?")
  assert_match "check: a missing dependency is named"  "$out" 'MISSING +node'
  assert_match "check: a missing dependency fails"     "$out" 'exit=1$'
  out=$(HOME="$H2" TOWER_STUB=old "$KIT/install.sh" --check 2>&1)
  assert_match "check: an old tower is called out"    "$out" 'OLD +tower'
fi

echo; echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
