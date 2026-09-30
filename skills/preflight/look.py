#!/usr/bin/env python3
# preflight/look.sh's reader and writer: turns a scanner's JSON (stdin) into
# findings (JSON lines on stdout), and the collected verdict rows and findings
# into look.json. A file beside look.sh, never a here-doc: bash 3.2 (macOS)
# writes a here-doc to a temp file in TMPDIR and reads it back, and a lane may
# write TMPDIR. look.sh runs it as  python3 look.py MODE ARGS...
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
elif mode == "snapshot":
    # Every path git status names, untracked ones one by one, with a hash of
    # its content: two snapshots differ where a file changed, even when its
    # status line did not.
    import hashlib, os, subprocess
    out = subprocess.run(["git", "status", "--porcelain=v1", "-z", "--untracked-files=all"],
                         check=True, capture_output=True).stdout.decode("utf-8", "surrogateescape")
    entries, snap, i = out.split("\0"), {}, 0
    while i < len(entries):
        e = entries[i]; i += 1
        if len(e) < 4:
            continue
        code, path = e[:2], e[3:]
        if code[0] in "RC":
            i += 1  # the rename's source path follows
        if os.path.islink(path):
            h = "link:" + os.readlink(path)
        elif os.path.isfile(path):
            h = hashlib.sha1(open(path, "rb").read()).hexdigest()
        else:
            h = "dir" if os.path.isdir(path) else "missing"
        snap[path] = [code, h]
    json.dump(snap, open(sys.argv[2], "w"))
elif mode == "changed":
    # What differs between the snapshots before and after the suite.
    before, after = json.load(open(sys.argv[2])), json.load(open(sys.argv[3]))
    paths = sorted(p for p in set(before) | set(after) if before.get(p) != after.get(p))
    new = [p for p in paths if (after.get(p) or before[p])[0] == "??"]
    changed = [p for p in paths if (after.get(p) or before[p])[0] != "??"]
    parts = (["changed: " + ", ".join(changed)] if changed else []) + \
            (["new, untracked: " + ", ".join(new)] if new else [])
    if paths:
        print(json.dumps({"area": "suite", "severity": "should-fix", "file": ".", "line": None,
                          "title": "the suite changed tracked files" if changed else "the suite left untracked files",
                          "evidence": "; ".join(parts)}))
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
