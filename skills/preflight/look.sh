#!/usr/bin/env bash
# Preflight's look runner: the static baseline on the branch's diff, then the
# repo's full suite.
#
#   preflight/look.sh <base-ref> <findings-dir>
#
# Run from the checkout. The diff is the merge base of <base-ref> and HEAD
# against HEAD. Steps, each one verdict row:
#   semgrep   its default rules (p/default), plus the repo's .semgrep/ when it
#             exists, over the files the branch changed that are still in the
#             checkout, reporting only results new since the merge base
#             (--baseline-commit); skip row when there are none
#   gitleaks  the branch's commits since the merge base, secrets redacted (8.19+);
#             skip row when there are none
#   the full suite, one row per step, in order, every step even when one fails:
#             the repo contract's `suite NAME "CMD" [DIR]` lines (run in DIR);
#             without them the detected typecheck and test scripts
#             (package.json); with neither, CHECK_CMD as the step `check`,
#             or a skip row when neither the repo nor the call set CHECK_CMD
# A scanner that is not installed, exits non-zero or prints what look.sh cannot
# read is a warn row and the run goes on. semgrep can exit 0 and still list
# errors in its JSON (a file it could not parse): that scan is incomplete, so
# its row is warn, or fail with its findings kept, and the note says
# "scan incomplete" with the count and the first error's type and file. (Not
# --strict: that turns those errors into a non-zero exit, which would drop the
# findings.) Findings and notes never quote the matched code, nor a scanner's
# error message when its type and file say enough: semgrep does not redact
# either. A red suite step is a fail row and a
# must-fix finding (area suite, file = the step's DIR, line null) carrying the
# last 20 lines of its output, unredacted: it is the repo's own test output.
# Steps get no stdin and no timeout. A SUITE_SKIP name that matches no step is
# a warn row.
#
# Settings (environment > .orchestrate, read through detect-stack.sh):
#   STATIC_BASELINE=off   skip both scanners; their rows say so
#   SUITE_SKIP=build,lint suite steps to skip; their rows are skip rows
#   CHECK_CMD             the one step when there are no suite lines or scripts
#
# Writes <findings-dir>/look.json (created if missing), the shared findings
# format (preflight/findings.md):
#   { "review": "look",
#     "verdict":  [ { "step", "status": pass|fail|warn|skip, "note" } ],
#     "findings": [ { "area", "severity": must-fix|should-fix|watchpoint,
#                     "file", "line", "title", "evidence" } ] }
# Prints each suite step as it starts (stderr), the verdict table and the
# findings file. Exit 0 when no finding is must-fix, 1 when one is, 2 on a
# setup error (usage, uncommitted changes to tracked files, unknown base, a
# refused repo contract); look.json is removed first, so after exit 2 there
# is none.
#
# The checkout must have no uncommitted changes to tracked files (untracked
# files are fine): whatever the suite then leaves changed is the suite's own,
# and  git checkout -- <files>  puts it back without touching anyone's edits.
set -euo pipefail
LOOK_DIR="$(cd "$(dirname "$0")" && pwd -P)"
KIT="$(dirname "$LOOK_DIR")/orchestrate"  # the orchestrate skill beside this one
. "$KIT/common.sh"
die() { echo "$*" >&2; exit 2; }  # a setup error, apart from exit 1 (must-fix found)

[ $# -eq 2 ] || die "usage: preflight/look.sh <base-ref> <findings-dir>"
BASE="$1"; FINDINGS_DIR="$2"
need git python3
mkdir -p "$FINDINGS_DIR"; FINDINGS_DIR="$(cd "$FINDINGS_DIR" && pwd -P)"
rm -f "$FINDINGS_DIR/look.json"
cd "$(git rev-parse --show-toplevel)"
# A clean tree, so what the suite changes is all the suite's: putting it back
# (git checkout) then touches nothing else. Untracked files may stay.
DIRTY=$(git status --porcelain --untracked-files=no | cut -c4- | tr '\n' ' ') || die "look: git status failed"
[ -z "$DIRTY" ] || die "look: uncommitted changes to tracked files: ${DIRTY% }. Commit or stash them, then run look again."
# The repo contract: STATIC_BASELINE, SUITE_SKIP, the suite steps, CHECK_CMD.
CHECK_CMD_FROM_ENV="${CHECK_CMD:+yes}"
. "$KIT/detect-stack.sh"
MERGE_BASE=$(git merge-base "$BASE" HEAD) || die "look: no merge base between '$BASE' and HEAD"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
VERDICT="$WORK/verdict.tsv"; FINDINGS="$WORK/findings.jsonl"; : > "$VERDICT"; : > "$FINDINGS"
verdict() {  # STEP STATUS NOTE; tabs and newlines in NOTE become spaces
  local note="${3//$'\t'/ }"
  printf '%s\t%s\t%s\n' "$1" "$2" "${note//$'\n'/ }" >> "$VERDICT"
}

# Turns a scanner's JSON (stdin) into findings (JSON lines on stdout), and the
# collected verdict rows and findings into look.json.
PY=$(cat <<'PY'
import json, sys
mode = sys.argv[1]
def describe(e):
    # One scanner error in a few words. Its type and file, when semgrep gives
    # them: the message is free text that can quote the scanned code. Never
    # raises; an error of an unknown shape still counts.
    if not isinstance(e, dict):
        return "an error"
    kind = e.get("type")
    kind = kind[0] if isinstance(kind, list) and kind else kind
    if isinstance(kind, str) and isinstance(e.get("path"), str):
        return "%s in %s" % (kind, e["path"])
    lines = str(e.get("message") or "").splitlines()
    return lines[0] if lines and lines[0].strip() else "an error"
def finding(severity, file, line, title, evidence):
    print(json.dumps({"area": "security", "severity": severity, "file": file,
                      "line": line, "title": title, "evidence": evidence}))
if mode == "semgrep":
    levels = {"CRITICAL": "must-fix", "HIGH": "must-fix", "ERROR": "must-fix",
              "MEDIUM": "should-fix", "WARNING": "should-fix"}
    for r in json.load(sys.stdin).get("results", []):
        # Neither extra.lines nor extra.message: semgrep does not redact, and
        # a rule's message can quote the matched code, which may be a secret.
        severity = str(r.get("extra", {}).get("severity", "")).upper()
        finding(levels.get(severity, "watchpoint"), r["path"], r["start"]["line"],
                r["check_id"], "semgrep " + severity)
elif mode == "reason":  # why a scanner failed, from its JSON errors (semgrep puts them there)
    try:
        print(describe(json.load(sys.stdin)["errors"][0]))
    except Exception:
        pass
elif mode == "errors":  # errors semgrep reports beside a successful exit
    try:
        errors = json.load(sys.stdin).get("errors") or []
    except Exception:
        errors = []
    if isinstance(errors, list) and errors:
        print("scan incomplete, %d error%s: %s" % (len(errors), "" if len(errors) == 1 else "s",
              describe(errors[0])))
elif mode == "gitleaks":
    for r in json.load(sys.stdin) or []:
        finding("must-fix", r["File"], r["StartLine"], r["Description"],
                "gitleaks %s in commit %s: %s" % (r["RuleID"], r["Commit"][:7], r.get("Match", "")))
elif mode == "suite":
    name, rc, cmd, where, tail_file = sys.argv[2:7]
    tail = open(tail_file, errors="replace").read().rstrip("\n")
    print(json.dumps({"area": "suite", "severity": "must-fix", "file": where, "line": None,
                      "title": "suite step %s failed (exit %s)" % (name, rc),
                      "evidence": "$ %s\n%s" % (cmd, tail)}))
elif mode == "write":
    verdict_file, findings_file, out = sys.argv[2:5]
    verdict = [dict(zip(("step", "status", "note"), l.rstrip("\n").split("\t")))
               for l in open(verdict_file) if l.strip()]
    findings = [json.loads(l) for l in open(findings_file) if l.strip()]
    with open(out, "w") as f:
        json.dump({"review": "look", "verdict": verdict, "findings": findings}, f, indent=2)
        f.write("\n")
    for v in verdict:
        print(("%-10s %-5s %s" % (v["step"], v["status"], v["note"])).rstrip())
    must = sum(1 for x in findings if x["severity"] == "must-fix")
    print("findings: %s (%d, %d must-fix)" % (out, len(findings), must))
    sys.exit(1 if must else 0)
PY
)
py() { python3 -c "$PY" "$@"; }

# Changed files that are still in the checkout (a sparse checkout can lack
# some); -z keeps odd names unquoted.
FILES=()
while IFS= read -r -d '' f; do [ -e "$f" ] && FILES+=("$f"); done < <(git diff -z --name-only --diff-filter=d "$MERGE_BASE" HEAD)
COMMITS=$(git rev-list --count "$MERGE_BASE..HEAD")

# scan STEP VERSION-ARG CMD...: runs one scanner, turns its JSON into findings
# and adds its verdict row. Missing, erroring or unreadable is a warn row, never
# a stop.
scan() {
  local step="$1" version="$2" rc=0 n reason errors; shift 2
  if ! "$step" "$version" >/dev/null 2>&1; then
    verdict "$step" warn "$step is not installed"; echo "look: $step is not installed; skipped" >&2; return
  fi
  "$@" > "$WORK/$step.json" 2> "$WORK/$step.err" || rc=$?
  if [ "$rc" != 0 ]; then
    reason=$(py reason < "$WORK/$step.json")
    [ -n "$reason" ] || reason=$(grep . "$WORK/$step.err" | tail -1 || true)
    verdict "$step" warn "$step exited $rc: $reason"; return
  fi
  py "$step" < "$WORK/$step.json" > "$WORK/$step.findings" 2>/dev/null \
    || { verdict "$step" warn "could not read $step output"; return; }
  cat "$WORK/$step.findings" >> "$FINDINGS"
  n=$(wc -l < "$WORK/$step.findings" | tr -d ' ')
  errors=$(py errors < "$WORK/$step.json" 2>/dev/null || true)
  case "$n" in
    0) if [ -n "$errors" ]; then verdict "$step" warn "$errors"; else verdict "$step" pass ""; fi ;;
    1) verdict "$step" fail "1 finding${errors:+; $errors}" ;;
    *) verdict "$step" fail "$n findings${errors:+; $errors}" ;;
  esac
}

if [ "${STATIC_BASELINE:-on}" = off ]; then
  verdict semgrep skip "STATIC_BASELINE=off"; verdict gitleaks skip "STATIC_BASELINE=off"
else
  if [ "${#FILES[@]}" = 0 ]; then
    verdict semgrep skip "no changed files"
  else
    SEMGREP_CONFIGS=(--config p/default)
    [ -d .semgrep ] && SEMGREP_CONFIGS+=(--config .semgrep)
    scan semgrep --version semgrep scan "${SEMGREP_CONFIGS[@]}" --json --quiet --metrics off \
      --baseline-commit "$MERGE_BASE" -- "${FILES[@]}"
  fi
  # By commits, not by files: a secret added and removed again on the branch
  # is still in its history. `gitleaks git` and `--report-path -` need 8.19+.
  if [ "$COMMITS" = 0 ]; then
    verdict gitleaks skip "no commits since the base"
  else
    scan gitleaks version gitleaks git --log-opts="$MERGE_BASE..HEAD" --report-format json --report-path - \
      --exit-code 0 --redact --no-banner --log-level error .
  fi
fi

# --- the full suite ----------------------------------------------------------
# The contract's suite lines; without them the detected typecheck and test
# scripts; with neither, CHECK_CMD as one step.
STEP_NAMES=(); STEP_CMDS=(); STEP_DIRS=()
step() { STEP_NAMES+=("$1"); STEP_CMDS+=("$2"); STEP_DIRS+=("$3"); }
if [ "${#SUITE_NAMES[@]}" -gt 0 ]; then
  for i in "${!SUITE_NAMES[@]}"; do step "${SUITE_NAMES[$i]}" "${SUITE_CMDS[$i]}" "${SUITE_DIRS[$i]}"; done
else
  for s in $(TYPECHECK_TASK="$TYPECHECK_TASK" node -e '
    const s = (() => { try { return require("./package.json").scripts || {}; } catch { return {}; } })();
    console.log([process.env.TYPECHECK_TASK, "test"].filter(n => s[n]).join(" "));' 2>/dev/null); do
    case "$s" in test) step test "$PM_RUN test" . ;; *) step typecheck "$PM_RUN $s" . ;; esac
  done
  # No typecheck script here, so detect-stack's default CHECK_CMD is a call
  # to it that can only fail; only a CHECK_CMD the repo or the call declared
  # is a step.
  if [ "${#STEP_NAMES[@]}" = 0 ]; then
    if [ -n "$CHECK_CMD_FROM_ENV" ] || [ "$CHECK_CMD" != "$PM_RUN $TYPECHECK_TASK" ]; then
      step check "$CHECK_CMD" .
    else
      verdict check skip "no suite lines, no package.json scripts, no CHECK_CMD"
    fi
  fi
fi
SKIP=",${SUITE_SKIP// /},"
for name in ${SUITE_SKIP//,/ }; do
  case " ${STEP_NAMES[*]:-} " in *" $name "*) ;; *) verdict SUITE_SKIP warn "no suite step named $name" ;; esac
done
for i in ${STEP_NAMES[@]+"${!STEP_NAMES[@]}"}; do
  name="${STEP_NAMES[$i]}"; cmd="${STEP_CMDS[$i]}"; dir="${STEP_DIRS[$i]}"
  case "$SKIP" in *",$name,"*) verdict "$name" skip SUITE_SKIP; continue ;; esac
  echo "look: suite step $name: $cmd" >&2
  rc=0; (cd "$dir" && bash -c "$cmd") < /dev/null > "$WORK/step.out" 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then
    verdict "$name" pass "$cmd"
  else
    verdict "$name" fail "exit $rc: $cmd"
    tail -n 20 "$WORK/step.out" > "$WORK/step.tail"
    py suite "$name" "$rc" "$cmd" "$dir" "$WORK/step.tail" >> "$FINDINGS"
  fi
done

py write "$VERDICT" "$FINDINGS" "$FINDINGS_DIR/look.json"
