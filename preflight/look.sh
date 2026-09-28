#!/usr/bin/env bash
# Preflight's look runner: the static baseline on the branch's diff.
#
#   preflight/look.sh <base-ref> <findings-dir>
#
# Run from the checkout. The diff is the merge base of <base-ref> and HEAD
# against HEAD. Steps, each one verdict row:
#   semgrep   its default rules (p/default), plus the repo's .semgrep/ when it
#             exists, over the files the branch changed that are still in the
#             checkout; skip row when there are none
#   gitleaks  the branch's commits since the merge base, secrets redacted (8.19+);
#             skip row when there are none
# A scanner that is not installed, exits non-zero or prints what look.sh cannot
# read is a warn row and the run goes on. Findings never quote the matched
# code: semgrep does not redact it.
#
# Settings (environment):
#   STATIC_BASELINE=off   skip both scanners; their rows say so
#
# Writes <findings-dir>/look.json (created if missing), the shared findings
# format (preflight/findings.md):
#   { "review": "look",
#     "verdict":  [ { "step", "status": pass|fail|warn|skip, "note" } ],
#     "findings": [ { "area", "severity": must-fix|should-fix|watchpoint,
#                     "file", "line", "title", "evidence" } ] }
# Prints the verdict table and the findings file. Exit 0 when no finding is
# must-fix, 1 when one is.
set -euo pipefail
LOOK_DIR="$(cd "$(dirname "$0")" && pwd -P)"
KIT="$(dirname "$LOOK_DIR")"
. "$KIT/common.sh"

[ $# -eq 2 ] || die "usage: preflight/look.sh <base-ref> <findings-dir>"
BASE="$1"; FINDINGS_DIR="$2"
need git python3
mkdir -p "$FINDINGS_DIR"; FINDINGS_DIR="$(cd "$FINDINGS_DIR" && pwd -P)"
cd "$(git rev-parse --show-toplevel)"
MERGE_BASE=$(git merge-base "$BASE" HEAD) || die "look: no merge base between '$BASE' and HEAD"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
VERDICT="$WORK/verdict.tsv"; FINDINGS="$WORK/findings.jsonl"; : > "$VERDICT"; : > "$FINDINGS"
verdict() { printf '%s\t%s\t%s\n' "$1" "$2" "${3//$'\t'/ }" >> "$VERDICT"; }

# Turns a scanner's JSON (stdin) into findings (JSON lines on stdout), and the
# collected verdict rows and findings into look.json.
PY=$(cat <<'PY'
import json, sys
mode = sys.argv[1]
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
        print(json.load(sys.stdin)["errors"][0]["message"].splitlines()[0])
    except Exception:
        pass
elif mode == "gitleaks":
    for r in json.load(sys.stdin) or []:
        finding("must-fix", r["File"], r["StartLine"], r["Description"],
                "gitleaks %s in commit %s: %s" % (r["RuleID"], r["Commit"][:7], r.get("Match", "")))
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

# Changed files that are still in the checkout; -z keeps odd names unquoted.
FILES=()
while IFS= read -r -d '' f; do [ -e "$f" ] && FILES+=("$f"); done < <(git diff -z --name-only --diff-filter=d "$MERGE_BASE" HEAD)
COMMITS=$(git rev-list --count "$MERGE_BASE..HEAD")

# scan STEP VERSION-ARG CMD...: runs one scanner, turns its JSON into findings
# and adds its verdict row. Missing, erroring or unreadable is a warn row, never
# a stop.
scan() {
  local step="$1" version="$2" rc=0 n reason; shift 2
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
  case "$n" in 0) verdict "$step" pass "" ;; 1) verdict "$step" fail "1 finding" ;; *) verdict "$step" fail "$n findings" ;; esac
}

if [ "${STATIC_BASELINE:-on}" = off ]; then
  verdict semgrep skip "STATIC_BASELINE=off"; verdict gitleaks skip "STATIC_BASELINE=off"
else
  if [ "${#FILES[@]}" = 0 ]; then
    verdict semgrep skip "no changed files"
  else
    SEMGREP_CONFIGS=(--config p/default)
    [ -d .semgrep ] && SEMGREP_CONFIGS+=(--config .semgrep)
    scan semgrep --version semgrep scan "${SEMGREP_CONFIGS[@]}" --json --quiet --metrics off -- "${FILES[@]}"
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

py write "$VERDICT" "$FINDINGS" "$FINDINGS_DIR/look.json"
