#!/usr/bin/env bash
# Preflight's look runner: the static baseline on the branch's diff.
#
#   preflight/look.sh <base-ref> <findings-dir>
#
# Run from the checkout. The diff is the merge base of <base-ref> and HEAD
# against HEAD. Steps, each one verdict row:
#   semgrep   its default rules (p/default), plus the repo's .semgrep/ when it
#             exists, over the files the branch changed (deleted files left out)
#   gitleaks  the branch's commits since the merge base, secrets redacted
# A scanner that is not installed or exits non-zero is a warn row and the run
# goes on. No changed files: both are skip rows and nothing is scanned.
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
verdict() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$VERDICT"; }

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
        x = r.get("extra", {})
        # Not extra.lines: semgrep does not redact, and the match may be a secret.
        finding(levels.get(str(x.get("severity", "")).upper(), "watchpoint"),
                r["path"], r["start"]["line"], x.get("message", r["check_id"]),
                "semgrep " + r["check_id"])
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

FILES=()
while IFS= read -r f; do FILES+=("$f"); done < <(git diff --name-only --diff-filter=d "$MERGE_BASE" HEAD)

# scan STEP VERSION-ARG CMD...: runs one scanner, turns its JSON into findings
# and adds its verdict row. Missing or erroring is a warn row, never a stop.
scan() {
  local step="$1" version="$2" rc=0 n; shift 2
  if ! "$step" "$version" >/dev/null 2>&1; then
    verdict "$step" warn "$step is not installed"; echo "look: $step is not installed; skipped" >&2; return
  fi
  "$@" > "$WORK/$step.json" 2> "$WORK/$step.err" || rc=$?
  if [ "$rc" != 0 ]; then
    verdict "$step" warn "$step exited $rc: $(grep . "$WORK/$step.err" | tail -1)"; return
  fi
  n=$(py "$step" < "$WORK/$step.json" | tee -a "$FINDINGS" | wc -l | tr -d ' ')
  case "$n" in 0) verdict "$step" pass "" ;; 1) verdict "$step" fail "1 finding" ;; *) verdict "$step" fail "$n findings" ;; esac
}

if [ "${STATIC_BASELINE:-on}" = off ]; then
  verdict semgrep skip "STATIC_BASELINE=off"; verdict gitleaks skip "STATIC_BASELINE=off"
elif [ "${#FILES[@]}" = 0 ]; then
  verdict semgrep skip "no changed files"; verdict gitleaks skip "no changed files"
else
  SEMGREP_CONFIGS=(--config p/default)
  [ -d .semgrep ] && SEMGREP_CONFIGS+=(--config .semgrep)
  scan semgrep --version semgrep scan "${SEMGREP_CONFIGS[@]}" --json --quiet --metrics off -- "${FILES[@]}"
  scan gitleaks version gitleaks git --log-opts="$MERGE_BASE..HEAD" --report-format json --report-path - \
    --exit-code 0 --redact --no-banner --log-level error .
fi

py write "$VERDICT" "$FINDINGS" "$FINDINGS_DIR/look.json"
