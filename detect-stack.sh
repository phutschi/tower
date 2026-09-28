#!/usr/bin/env bash
# The repo contract and the JS default. Sourced (after common.sh) with $PWD at
# the checkout. Resolution for every value: environment > .herdr-orchestrate >
# detection > built-in default.
#
# .herdr-orchestrate is plain bash in the repo root (see example.herdr-orchestrate):
#   CHECK_CMD="bun run check"           the check gate; one-shot, must pass before a commit
#   INSTALL_CMD="make deps"             what add-lane.sh runs in a new lane's worktree; default:
#                                       the package manager's install, none without a package.json
#   pane checks "bun test --watch"      pane NAME "CMD" [DIR]; DIR relative to the checkout
#   pane dev    "bun run dev" apps/web  only checks and dev are placed
#   EXECUTOR_KIND=codex                 the lanes' harness: claude (default) | codex
#   EXECUTOR_MODEL=gpt-6-astra          the lanes' model (executor.sh has the kind's default)
#   SPEC_REVIEWER_MODEL=sonnet          the two reviewer models tower records for the run
#   QUALITY_REVIEWER_MODEL=opus
#   STALE=30                            minutes before the console and tower wait flag a lane as stale
#   suite lint "bun run lint" [DIR]     suite NAME "CMD" [DIR]: the full suite as named steps, in order
# plus PM, TYPECHECK_TASK, TEST_PKG and TEST_FILTER to steer the detection below,
# and the run switches (default first; a value outside the list is refused):
#   TASK_REVIEW LANE_REVIEW PREFLIGHT STATIC_BASELINE   on | off
#   PR                                                   draft | ready | off
#   METHOD                                               tdd | plain
#   REVIEWER_KIND                                        other | claude | codex
#   REVIEWER_MODEL REVIEW_AREAS SUITE_SKIP PR_TEMPLATE   free text, empty by default;
#                                                        lists are comma-separated
# A value set in the environment of the bootstrap or add-lane call wins over the
# file, even an empty one (REVIEW_AREAS= clears the file's list); anything else
# the file sets is ignored with a note. The switches keep their plain names (PR,
# METHOD, ...), so an unrelated PR or METHOD in the calling shell is read too.
#
# Sets: PM PM_EXEC PM_RUN INSTALL_CMD TYPECHECK_TASK CHECK_CMD
#       INSTALL_WHY  (why INSTALL_CMD is empty, for the one line add-lane.sh prints)
#       EXECUTOR_KIND EXECUTOR_MODEL SPEC_REVIEWER_MODEL QUALITY_REVIEWER_MODEL STALE  (when the file sets them)
#       PANE_NAMES PANE_CMDS PANE_DIRS   (parallel arrays; pane_index NAME finds one)
#       SUITE_NAMES SUITE_CMDS SUITE_DIRS  (parallel arrays in contract order; empty without suite lines)
#       every switch above, exported; switches_line prints them all on one line,
#       NAME=value, a value with spaces or quotes single-quoted the shell's way

SWITCHES="TASK_REVIEW LANE_REVIEW PREFLIGHT STATIC_BASELINE PR METHOD REVIEWER_KIND REVIEWER_MODEL REVIEW_AREAS SUITE_SKIP PR_TEMPLATE"
CONTRACT_VARS="EXECUTOR_KIND EXECUTOR_MODEL SPEC_REVIEWER_MODEL QUALITY_REVIEWER_MODEL STALE PM TYPECHECK_TASK CHECK_CMD INSTALL_CMD TEST_PKG TEST_FILTER $SWITCHES"
PANE_NAMES=(); PANE_CMDS=(); PANE_DIRS=()
SUITE_NAMES=(); SUITE_CMDS=(); SUITE_DIRS=()
pane() {
  case "${1:-}" in checks|dev) ;; *) die ".herdr-orchestrate: unknown pane '${1:-}' (only checks and dev are placed)" ;; esac
  [ -n "${2:-}" ] || die ".herdr-orchestrate: pane $1 needs a command"
  PANE_NAMES[${#PANE_NAMES[@]}]="$1"; PANE_CMDS[${#PANE_CMDS[@]}]="$2"; PANE_DIRS[${#PANE_DIRS[@]}]="${3:-.}"
}
suite() {
  [ -n "${1:-}" ] || die ".herdr-orchestrate: suite needs a name"
  [ -n "${2:-}" ] || die ".herdr-orchestrate: suite $1 needs a command"
  SUITE_NAMES[${#SUITE_NAMES[@]}]="$1"; SUITE_CMDS[${#SUITE_CMDS[@]}]="$2"; SUITE_DIRS[${#SUITE_DIRS[@]}]="${3:-.}"
}
pane_index() {  # prints the index of pane NAME, nothing when absent
  local i=0
  while [ "$i" -lt "${#PANE_NAMES[@]}" ]; do
    [ "${PANE_NAMES[$i]}" = "$1" ] && { echo "$i"; return; }
    i=$((i+1))
  done
}
if [ -f .herdr-orchestrate ]; then
  # Environment first: remember what the call set, source the file, put the
  # call's values back. Unknown names in the file are left alone but named,
  # so a typo does not pass silently.
  _env=()
  for _v in $CONTRACT_VARS; do [ -z "${!_v+set}" ] || _env+=("$_v=${!_v}"); done
  _before="$(compgen -v | sort)"
  . ./.herdr-orchestrate
  for _kv in ${_env[@]+"${_env[@]}"}; do export "$_kv"; done
  # grep finds nothing when the file adds no names (only pane and suite lines);
  # that is not an error for a caller running under set -e and pipefail.
  _new="$(comm -13 <(echo "$_before") <(compgen -v | sort) | { grep -vE '^(_|PANE_)' || true; })"
  for _v in $_new; do
    case " $CONTRACT_VARS " in *" $_v "*) ;; *) echo ".herdr-orchestrate: '$_v' is not a setting the kit reads (see example.herdr-orchestrate)" >&2 ;; esac
  done
  unset _env _v _kv _before _new
fi

# --- package manager ---------------------------------------------------------
if [ -z "${PM:-}" ]; then
  if   [ -f bun.lock ] || [ -f bun.lockb ]; then PM=bun
  elif [ -f pnpm-lock.yaml ];               then PM=pnpm
  elif [ -f yarn.lock ];                    then PM=yarn
  elif [ -f package-lock.json ];            then PM=npm
  else PM=$(node -p "((require('./package.json').packageManager)||'npm').split('@')[0]" 2>/dev/null || echo npm)
  fi
fi
case "$PM" in
  bun)  PM_EXEC="bunx";      PM_RUN="bun run";  _install="bun install" ;;
  pnpm) PM_EXEC="pnpm exec"; PM_RUN="pnpm run"; _install="pnpm install" ;;
  yarn) PM_EXEC="yarn exec"; PM_RUN="yarn run"; _install="yarn install" ;;
  *)    PM_EXEC="npx";       PM_RUN="npm run";  _install="npm install" ;;
esac
# The lane install: the package manager's, and nothing without a package.json.
# Set, even empty, it wins.
INSTALL_WHY="INSTALL_CMD is empty"
if [ -z "${INSTALL_CMD+set}" ]; then
  if [ -f package.json ]; then INSTALL_CMD=$_install
  else INSTALL_CMD=""; INSTALL_WHY="no package.json and no INSTALL_CMD in .herdr-orchestrate"; fi
fi
unset _install

# --- which script is "typecheck" here? ---------------------------------------
if [ -z "${TYPECHECK_TASK:-}" ]; then
  TYPECHECK_TASK=$(node -e '
    const fs = require("fs");
    const strip = s => s.replace(/^\s*\/\/.*$/gm, "");
    const read = f => { try { return JSON.parse(strip(fs.readFileSync(f, "utf8"))); } catch { return null; } };
    const turbo = read("turbo.json");
    const pkg   = read("package.json") || {};
    const names = [
      ...Object.keys((turbo && (turbo.tasks || turbo.pipeline)) || {}),
      ...Object.keys(pkg.scripts || {}),
    ];
    const want = ["typecheck", "check-types", "type-check", "types", "check:types"];
    process.stdout.write(want.find(w => names.includes(w)) || "typecheck");
  ' 2>/dev/null || echo typecheck)
fi

# --- the check gate ----------------------------------------------------------
# Typecheck, plus the root test script when there is one.
if [ -z "${CHECK_CMD:-}" ]; then
  if node -e 'const s=require("./package.json").scripts||{}; process.exit(s.test?0:1)' 2>/dev/null; then
    CHECK_CMD="$PM_RUN $TYPECHECK_TASK && $PM_RUN test"
  else
    CHECK_CMD="$PM_RUN $TYPECHECK_TASK"
  fi
fi

# --- the default checks pane -------------------------------------------------
# The target package's test runner in watch mode. Scans that package's own
# scripts: in a monorepo the package you watch often has no `test` script.
herdr_default_test_cmd() {  # $1 = test filter; run from the package directory
  local filter="$1"
  PM="$PM" PM_RUN="$PM_RUN" PM_EXEC="$PM_EXEC" FILTER="$filter" node -e '
  process.stdout.write((() => {
    const fs = require("fs");
    const { PM, PM_RUN, PM_EXEC, FILTER } = process.env;
    const filter = FILTER ? " " + FILTER : "";
    let scripts = {};
    try { scripts = JSON.parse(fs.readFileSync("package.json", "utf8")).scripts || {}; } catch {}
    for (const name of ["test:watch", "test:unit:watch"])
      if (scripts[name]) return `${PM_RUN} ${name}${filter}`;
    const name = ["test", "test:unit"].find(n => scripts[n]);
    const body = name ? scripts[name] : "";
    if (/\bvitest\b/.test(body))   return `${PM_EXEC} vitest --watch${filter}`;
    if (/\bjest\b/.test(body))     return `${PM_EXEC} jest --watch${filter}`;
    if (/\bbun test\b/.test(body)) return `bun test --watch${filter}`;
    if (name)                        return `${PM_RUN} ${name} --${filter ? " --watch" + filter : " --watch"}`;
    const has = re => fs.readdirSync(".").some(f => re.test(f));
    if (has(/^vitest\.(config|workspace)\./)) return `${PM_EXEC} vitest --watch${filter}`;
    if (has(/^jest\.config\./))               return `${PM_EXEC} jest --watch${filter}`;
    if (PM === "bun")                           return `bun test --watch${filter}`;
    return "";
  })());
  ' 2>/dev/null || true   # no node: no runner detected, not an error
}
if [ -z "$(pane_index checks)" ]; then
  TEST_PKG="${TEST_PKG:-.}"
  _cmd="$( cd "$TEST_PKG" 2>/dev/null || cd .; herdr_default_test_cmd "${TEST_FILTER:-}" )"
  [ -n "$_cmd" ] || _cmd="echo 'herdr-orchestrate: no test runner detected; declare  pane checks \"<cmd>\"  in .herdr-orchestrate'"
  pane checks "$_cmd" "$TEST_PKG"
  unset _cmd
fi

# --- the run switches --------------------------------------------------------
TASK_REVIEW="${TASK_REVIEW:-on}"; LANE_REVIEW="${LANE_REVIEW:-on}"
PREFLIGHT="${PREFLIGHT:-on}";     STATIC_BASELINE="${STATIC_BASELINE:-on}"
PR="${PR:-draft}"; METHOD="${METHOD:-tdd}"; REVIEWER_KIND="${REVIEWER_KIND:-other}"
REVIEWER_MODEL="${REVIEWER_MODEL:-}"; REVIEW_AREAS="${REVIEW_AREAS:-}"
SUITE_SKIP="${SUITE_SKIP:-}";         PR_TEMPLATE="${PR_TEMPLATE:-}"
switch_allows() {  # NAME "a, b or c" VALUE...: refuse NAME unless its value is one of VALUE...
  local name="$1" say="$2" v; shift 2
  for v in "$@"; do [ "${!name}" = "$v" ] && return 0; done
  die "$name must be $say (got '${!name}')"
}
for _v in TASK_REVIEW LANE_REVIEW PREFLIGHT STATIC_BASELINE; do switch_allows "$_v" "on or off" on off; done; unset _v
switch_allows PR            "draft, ready or off"     draft ready off
switch_allows METHOD        "tdd or plain"            tdd plain
switch_allows REVIEWER_KIND "other, claude or codex"  other claude codex
switches_line() {  # every switch and its value, on one line; a value with any
  # character outside [A-Za-z0-9_.,:/@%+-] is single-quoted the shell's way, so
  # add-reviewer.sh reads it back whole (python3 shlex, no eval, no globbing)
  local v val out=""
  for v in $SWITCHES; do
    val=${!v}
    case "$val" in *[!A-Za-z0-9_.,:/@%+-]*) val="'$(printf '%s' "$val" | sed "s/'/'\\\\''/g")'" ;; esac
    out="$out $v=$val"
  done
  echo "${out# }"
}

export PM PM_EXEC PM_RUN INSTALL_CMD TYPECHECK_TASK CHECK_CMD $SWITCHES
for _v in EXECUTOR_KIND EXECUTOR_MODEL SPEC_REVIEWER_MODEL QUALITY_REVIEWER_MODEL STALE; do
  [ -z "${!_v:-}" ] || export "$_v"
done; unset _v
