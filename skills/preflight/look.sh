#!/usr/bin/env bash
# Preflight's look runner: the static baseline on the branch's diff, then the
# repo's full suite.
#
#   preflight/look.sh <base-ref> <findings-dir>
#
# Run from the checkout. The diff is the merge base of <base-ref> and HEAD
# against HEAD. Steps, each one verdict row:
#   base      whether <base-ref> is what its remote has now. look.sh never
#             fetches (a sandboxed Reviewer cannot write .git; whoever runs
#             look fetches first); it asks with  git ls-remote , which writes
#             nothing, with ssh in batch mode and a 10-second connect
#             timeout, so no prompt waits (a GIT_SSH wrapper is left as is). pass when they match; warn "base
#             is stale" when the remote moved on; warn "base could not be
#             refreshed" when the remote cannot be asked (no network, no such
#             remote) or no longer has the branch; skip when <base-ref> is no
#             remote-tracking branch.
#             Never a failure: the look goes on against the base as fetched.
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
# Steps get no stdin and no timeout. A red step whose output has a
# permission error (PermissionDenied, Operation not permitted, EACCES) most
# likely hit the sandbox, not the code: a warn row whose note starts
# "setup:", with that line, and a watchpoint finding (not must-fix) with the
# tail; the look is then a setup error (exit 2). A SUITE_SKIP name that
# matches no step is a warn row.
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
# refused repo contract, a suite step's permission error); look.json is
# removed first, so after exit 2 there is none, except after a permission
# error: every step ran, and look.json holds their rows and findings.
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
unset CONTRACT_RUN  # the branch's own contract: look runs inside the Reviewer
. "$KIT/detect-stack.sh"
MERGE_BASE=$(git merge-base "$BASE" HEAD) || die "look: no merge base between '$BASE' and HEAD"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
VERDICT="$WORK/verdict.tsv"; FINDINGS="$WORK/findings.jsonl"; : > "$VERDICT"; : > "$FINDINGS"
verdict() {  # STEP STATUS NOTE; tabs, carriage returns and newlines in NOTE become spaces
  local note="${3//$'\t'/ }"; note="${note//$'\r'/ }"
  printf '%s\t%s\t%s\n' "$1" "$2" "${note//$'\n'/ }" >> "$VERDICT"
}

# --- the base ----------------------------------------------------------------
# Never a fetch: a sandboxed Reviewer cannot write .git. The remote is asked
# with ls-remote, which writes nothing.
BASE_REF=$(git rev-parse --symbolic-full-name "$BASE" 2>/dev/null || true)
REMOTE=""
for rem in $(git remote); do  # the longest remote name that prefixes the ref
  case "$BASE_REF" in "refs/remotes/$rem/"*) [ "${#rem}" -le "${#REMOTE}" ] || REMOTE=$rem ;; esac
done
if [ -z "$REMOTE" ]; then
  verdict base skip "$BASE is not a remote-tracking branch"
else
  BRANCH=${BASE_REF#"refs/remotes/$REMOTE/"}
  LOCAL_SHA=$(git rev-parse --short "$BASE")
  # No prompt may wait: git's own (https) nor ssh's, which reads /dev/tty.
  # A GIT_SSH wrapper (plink, ...) is left as it is: it may not take ssh's -o.
  if [ -n "${GIT_SSH:-}" ] && [ -z "${GIT_SSH_COMMAND:-}" ]; then SSH=""
  else SSH="${GIT_SSH_COMMAND:-$(git config core.sshCommand || echo ssh)} -o BatchMode=yes -o ConnectTimeout=10"; fi
  rc=0; env GIT_TERMINAL_PROMPT=0 ${SSH:+"GIT_SSH_COMMAND=$SSH"} git ls-remote "$REMOTE" "refs/heads/$BRANCH" < /dev/null \
    > "$WORK/ls-remote.out" 2> "$WORK/ls-remote.err" || rc=$?
  # The pattern also matches refs ending in it (refs/x/refs/heads/main): keep the exact one.
  REMOTE_SHA=$(awk -v ref="refs/heads/$BRANCH" '$2 == ref { print $1 }' "$WORK/ls-remote.out")
  if [ "$rc" != 0 ]; then
    reason=$(grep -m1 . "$WORK/ls-remote.err" || true)  # git's first complaint
    verdict base warn "base could not be refreshed: git ls-remote $REMOTE failed (${reason:-exit $rc}); $BASE is $LOCAL_SHA, as last fetched"
  elif [ -z "$REMOTE_SHA" ]; then
    verdict base warn "base could not be refreshed: $REMOTE has no branch $BRANCH; $BASE is $LOCAL_SHA, as last fetched"
  elif [ "$(git rev-parse "$BASE")" = "$REMOTE_SHA" ]; then
    verdict base pass "$BASE matches $REMOTE ($LOCAL_SHA)"
  else
    verdict base warn "base is stale: $BASE is $LOCAL_SHA, $REMOTE has ${REMOTE_SHA:0:${#LOCAL_SHA}}; whoever runs look fetches, then looks again"
  fi
fi

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
    # A permission error (setup) is a watchpoint: its tail still reaches triage.
    name, rc, cmd, where, tail_file, kind = sys.argv[2:8]
    tail = open(tail_file, errors="replace").read().rstrip("\n")
    setup = kind == "setup"
    print(json.dumps({"area": "suite", "severity": "watchpoint" if setup else "must-fix",
                      "file": where, "line": None,
                      "title": "suite step %s failed%s (exit %s)" % (name, " on a permission error" if setup else "", rc),
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
PERMISSION_ERROR='PermissionDenied|Operation not permitted|EACCES'; SETUP_STEPS=""
for name in ${SUITE_SKIP//,/ }; do
  case " ${STEP_NAMES[*]:-} " in *" $name "*) ;; *) verdict SUITE_SKIP warn "no suite step named $name" ;; esac
done
for i in ${STEP_NAMES[@]+"${!STEP_NAMES[@]}"}; do
  name="${STEP_NAMES[$i]}"; cmd="${STEP_CMDS[$i]}"; dir="${STEP_DIRS[$i]}"
  case "$SKIP" in *",$name,"*) verdict "$name" skip SUITE_SKIP; continue ;; esac
  echo "look: suite step $name: $cmd" >&2
  rc=0; (cd "$dir" && bash -c "$cmd") < /dev/null > "$WORK/step.out" 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then verdict "$name" pass "$cmd"; continue; fi
  tail -n 20 "$WORK/step.out" > "$WORK/step.tail"
  # A permission error anywhere in the output (a summary can follow it): most
  # likely the sandbox, not the code. -a: a NUL byte does not make it binary.
  perm=$(grep -a -m1 -E "$PERMISSION_ERROR" "$WORK/step.out" | cut -c1-200 || true)
  if [ -n "$perm" ]; then
    verdict "$name" warn "setup: exit $rc, a permission error ($perm): $cmd"
    SETUP_STEPS="$SETUP_STEPS $name"
    py suite "$name" "$rc" "$cmd" "$dir" "$WORK/step.tail" setup >> "$FINDINGS"
  else
    verdict "$name" fail "exit $rc: $cmd"
    py suite "$name" "$rc" "$cmd" "$dir" "$WORK/step.tail" red >> "$FINDINGS"
  fi
done

rc=0; py write "$VERDICT" "$FINDINGS" "$FINDINGS_DIR/look.json" || rc=$?
[ -z "$SETUP_STEPS" ] || die "look: setup error: suite step(s)${SETUP_STEPS} failed on a permission error, most likely the sandbox, not the code. Give them writable temp and cache dirs, then look again; their output is in look.json as watchpoints."
exit "$rc"
