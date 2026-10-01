#!/usr/bin/env bash
# Preflight's look runner: the static baseline on the branch's diff, then the
# repo's full suite.
#
#   preflight/look.sh <base-ref> <findings-dir>
#
# Run from the checkout. The diff is the merge base of <base-ref> and HEAD
# against HEAD. look looks at HEAD, never at the checkout's files: it adds a
# fresh detached worktree of HEAD (git worktree add --detach) in a temp dir
# under $XDG_STATE_HOME/tower/look (default ~/.local/state; mode 700),
# resolved to its physical path, and reads the kit (common.sh,
# detect-stack.sh), the repo contract and package.json from it, runs the
# install, both scanners and every suite step in it, and removes it on every
# exit, a failure and a signal too. So untracked files (a *.test.ts the suite
# would pick up), index bits (assume-unchanged, skip-worktree) and dirty kit
# files in the checkout do not reach the look. Every file look reads its
# verdict from (verdict rows, findings, scanner and step output) is in that
# temp dir too, beside the worktree; look writes nothing to TMPDIR, so a lane
# that writes TMPDIR cannot change the verdict. That dir is outside everything
# a lane may write, the same reason the contract pin lives beside it
# (detect-stack.sh): a codex lane still running writes its checkout, the run
# dir, the git dir, /tmp and TMPDIR, and could otherwise swap a test in while
# the install runs, or look's verdict files after it. look refuses (exit 2) a
# dir that resolves under the git dir, the run dir (TOWER_RUN, when set: the
# Reviewer's brief and a codex Reviewer's environment set it), the checkout or
# any worktree of the repo, TMPDIR or /tmp, and one that is a symlink or not
# the user's. That check alone is  look.sh --dir , which prints the dir:
# add-reviewer.sh runs it before it grants a codex Reviewer's sandbox that dir
# (executor.sh AGENT_LOOK; no lane gets it). The checkout's git hooks stay off
# while the worktree is made (core.hooksPath=/dev/null); HEAD's submodules are
# checked out in it. look writes the git dir only for that worktree (its
# worktrees/, and modules/ for submodules); a sandbox that keeps those
# read-only, or a dir look cannot write, is a setup error.
#
# What look still trusts: itself, as invoked, and look.py beside it (its
# verdict code: a file, never a here-doc, which bash 3.2 would write to TMPDIR
# and read back); git, coreutils, python3 and the
# scanners on PATH; the repo's git config (a filter such as git-lfs's smudge
# runs as the worktree is made); and the kit beside look.sh when look.sh is
# not committed in the checkout (an installed plugin, outside what a lane
# edits). When it is
# (the repo under review is the kit's own), the kit is HEAD's copy. Before the
# worktree exists look runs git and coreutils only: the clean-tree check, the
# contract check and the merge base.
#
# The install: INSTALL_CMD (detect-stack.sh: the repo contract's, else the
# package manager's when there is a package.json; set, even empty, it wins),
# run in the temp worktree before the scanners, so the suite runs on the
# dependencies HEAD's lockfile names, not on the checkout's untracked
# node_modules. It needs the network, or the package manager's cache, as a
# lane's install does. One that fails is a setup error.
#
# Steps, each one verdict row:
#   base      whether <base-ref> is what its remote has now. look.sh never
#             fetches (a sandbox may keep .git read-only; whoever runs
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
# matches no step is a warn row. What the suite changes (tracked files it
# edits, untracked files it leaves, beside what the install left; compared by
# content, so a file the install changed and the suite changed again counts)
# it changes in the temp worktree: one should-fix finding (area suite, file ".", line
# null) names them, "the suite changed tracked files" or "the suite left
# untracked files", and the worktree goes with them. Nothing is put back,
# since the checkout was never touched.
#
# Settings (environment > .orchestrate > user contract, read through detect-stack.sh):
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
# setup error (usage, uncommitted changes to tracked files, a repo contract
# not committed as it is in HEAD or a symlink, unknown base, no temp dir or
# worktree, submodules that cannot be checked out, no kit, a failed install, a refused repo contract, a suite step's
# permission error); look.json is
# removed first, so after exit 2 there is none, except after a permission
# error: every step ran, and look.json holds their rows and findings.
#
# The checkout must have no uncommitted changes to tracked files (untracked
# files are fine, and never seen): look runs HEAD, so a tracked change it would
# not see is refused rather than looked past. The repo contract (.orchestrate,
# or .herdr-orchestrate) is read from HEAD too, and one in the checkout that is
# untracked, differs from HEAD's bytes or is a symlink is refused, naming the
# file, rather than passed over: whoever runs look sees which contract ran.
set -euo pipefail
# Until the temp worktree of HEAD exists: git and coreutils only, nothing the
# checkout holds runs (header).
die() { echo "$*" >&2; exit 2; }  # a setup error, apart from exit 1 (must-fix found)
LOOK_DIR="$(cd "$(dirname "$0")" && pwd -P)"

# look_root: LOOK_ROOT, look's own dir, where it makes its temp worktree and
# keeps every file it reads its verdict from; refused (exit 2) where a lane
# may write. It needs TOP, the checkout; git and coreutils only. The one
# check: add-reviewer.sh asks it through  look.sh --dir  before it grants a
# codex Reviewer that dir.
# Where no lane may write (a codex lane writes its checkout, the run dir, the
# git dir, /tmp and TMPDIR; a codex Reviewer is granted this dir alone:
# add-reviewer.sh AGENT_LOOK), by its physical path (macOS: /var is
# /private/var), so the suite sees one real path.
look_root() {
  LOOK_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/tower/look"
  mkdir -p "$LOOK_ROOT" || die "look: cannot make its worktree dir $LOOK_ROOT"
  # A symlink could point anywhere, one not the user's anyone may change:
  # refused before look touches it (the chmod below follows a symlink).
  [ ! -L "$LOOK_ROOT" ] && [ ! -L "$(dirname "$LOOK_ROOT")" ] \
    || die "look: its worktree dir $LOOK_ROOT is a symlink (or its tower/ is): it could point where a lane writes; make it a plain dir, then run look again"
  [ -O "$LOOK_ROOT" ] || die "look: its worktree dir $LOOK_ROOT is not yours; remove it, then run look again"
  LOOK_ROOT=$(cd "$LOOK_ROOT" && pwd -P) || die "look: cannot resolve its worktree dir $LOOK_ROOT"
  local wt
  under "the git dir" "$(git rev-parse --path-format=absolute --git-common-dir)"
  under "the git dir" "$(git rev-parse --path-format=absolute --git-dir)"
  [ -z "${TOWER_RUN:-}" ] || under "the run dir" "$TOWER_RUN"
  under "the checkout" "$TOP"
  while IFS= read -r wt; do  # the main checkout and every lane's worktree
    case "$wt" in
      "worktree "*) under "a worktree of this repo" "${wt#worktree }" ;;
    esac
  done < <(git worktree list --porcelain)
  [ -z "${TMPDIR:-}" ] || under "TMPDIR" "$TMPDIR"
  under "/tmp" /tmp
  chmod 700 "$LOOK_ROOT" || die "look: cannot make its worktree dir $LOOK_ROOT the user's alone"
}
under() {  # WHAT DIR: refused when LOOK_ROOT is DIR or under it
  local d; [ -n "$2" ] || return 0  # cd "" would stay here
  d=$(cd "$2" 2>/dev/null && pwd -P) || return 0
  case "$LOOK_ROOT/" in
    "${d%/}/"*)
      die "look: its worktree dir $LOOK_ROOT is under $1 ($d), which a lane may write; set XDG_STATE_HOME elsewhere, then run look again" ;;
  esac
}
# look.sh --dir: that check alone, from the checkout; prints LOOK_ROOT.
if [ "${1:-}" = --dir ]; then
  [ $# -eq 1 ] || die "usage: preflight/look.sh --dir"
  command -v git >/dev/null || die "look: needs git"
  TOP=$(git rev-parse --show-toplevel) || die "look: not in a git checkout"
  cd "$TOP"; TOP=$(pwd -P)
  look_root; echo "$LOOK_ROOT"; exit 0
fi

[ $# -eq 2 ] || die "usage: preflight/look.sh <base-ref> <findings-dir>"
BASE="$1"; FINDINGS_DIR="$2"
command -v git >/dev/null || die "look: needs git"
mkdir -p "$FINDINGS_DIR"; FINDINGS_DIR="$(cd "$FINDINGS_DIR" && pwd -P)"
rm -f "$FINDINGS_DIR/look.json"
TOP=$(git rev-parse --show-toplevel) || die "look: not in a git checkout"
cd "$TOP"; TOP=$(pwd -P)
# A clean tree: look runs HEAD, so a tracked change it would not see is
# refused rather than looked past. Untracked files may stay: look never
# sees them.
DIRTY=$(git status --porcelain --untracked-files=no | cut -c4- | tr '\n' ' ') || die "look: git status failed"
[ -z "$DIRTY" ] || die "look: uncommitted changes to tracked files: ${DIRTY% }. Commit or stash them, then run look again."
# The repo contract is read from HEAD too, but one in the checkout that is not
# what HEAD holds is refused, not silently passed over: its bytes compared
# with HEAD's, which also catches a change git status does not show
# (assume-unchanged, skip-worktree).
CONTRACT=.orchestrate
[ -f "$CONTRACT" ] || [ ! -f .herdr-orchestrate ] || CONTRACT=.herdr-orchestrate
if [ -f "$CONTRACT" ]; then
  [ ! -L "$CONTRACT" ] \
    || die "look: $CONTRACT is a symlink: look runs what it points at as bash, and a Reviewer sees only the link's target name in a diff. Commit the contract itself in its place, then run look again."
  git cat-file -e "HEAD:$CONTRACT" 2>/dev/null && git show "HEAD:$CONTRACT" | cmp -s - "$CONTRACT" \
    || die "look: $CONTRACT is not committed as it is in HEAD (untracked, or changed since): look runs it as bash, and no Reviewer sees it in a diff. Commit it, or move it out of the checkout, then run look again."
fi
MERGE_BASE=$(git merge-base "$BASE" HEAD) || die "look: no merge base between '$BASE' and HEAD"

# --- the temp worktree of HEAD -------------------------------------------------
# Everything below runs in it, and it goes on every exit.
# All of it in one dir under look's own (look_root, above): the worktree, and
# every file look reads its verdict from, where no lane may write.
WORK=""
cleanup() {
  [ -z "$WORK" ] || { git -C "$TOP" worktree remove --force "$WORK/tree" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
  git -C "$TOP" worktree prune >/dev/null 2>&1 || true
}
trap cleanup EXIT; trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
look_root
WORK=$(mktemp -d "$LOOK_ROOT/look.XXXXXX") || die "look: cannot make a temp dir under $LOOK_ROOT"
TREE="$WORK/tree"
# The checkout's hooks stay off (-c reaches every git these start): a
# post-checkout hook is code from the checkout.
NOHOOKS=(-c core.hooksPath=/dev/null)
git "${NOHOOKS[@]}" worktree add --detach --quiet "$TREE" HEAD > "$WORK/worktree.err" 2>&1 \
  || die "look: could not make a temp worktree of HEAD (git worktree add: $(grep -m1 . "$WORK/worktree.err" || echo "no output")); look needs to write the git dir's worktrees/"
# Submodules, as HEAD pins them: a checkout has them, so the suite may need them.
if [ -f "$TREE/.gitmodules" ]; then
  git -C "$TREE" "${NOHOOKS[@]}" submodule --quiet update --init --recursive > "$WORK/submodule.err" 2>&1 \
    || die "look: could not check out HEAD's submodules in look's temp worktree (git submodule update: $(grep -m1 . "$WORK/submodule.err" || echo "no output"))"
fi
# The kit: HEAD's copy when look.sh is committed in this checkout (the repo
# under review is the kit's own), else the one beside look.sh as invoked.
KIT="$(dirname "$LOOK_DIR")/orchestrate"
case "$LOOK_DIR" in
  "$TOP"/*) REL=${LOOK_DIR#"$TOP"/}
            [ ! -f "$TREE/$REL/look.sh" ] || KIT="$TREE/$(dirname "$REL")/orchestrate" ;;
esac
cd "$TREE" || die "look: cannot enter its temp worktree $TREE"
[ -f "$KIT/common.sh" ] && [ -f "$KIT/detect-stack.sh" ] || die "look: no orchestrate kit at $KIT (common.sh, detect-stack.sh)"
. "$KIT/common.sh"
die() { echo "$*" >&2; exit 2; }  # again: common.sh's exits 1
need git python3
# The repo contract: STATIC_BASELINE, SUITE_SKIP, the suite steps, CHECK_CMD.
CHECK_CMD_FROM_ENV="${CHECK_CMD:+yes}"
unset CONTRACT_RUN  # the branch's own contract: look runs inside the Reviewer
. "$KIT/detect-stack.sh"
# The suite's dependencies, installed fresh: the checkout's node_modules is
# untracked, so look does not read it either.
if [ -n "$INSTALL_CMD" ]; then
  echo "look: install: $INSTALL_CMD" >&2
  rc=0; bash -c "$INSTALL_CMD" < /dev/null > "$WORK/install.out" 2>&1 || rc=$?
  [ "$rc" = 0 ] || die "look: the install failed (exit $rc): $INSTALL_CMD, in look's temp worktree of HEAD; its output ends: $(tail -n 5 "$WORK/install.out" | tr '\n' ' ')"
fi

VERDICT="$WORK/verdict.tsv"; FINDINGS="$WORK/findings.jsonl"; : > "$VERDICT"; : > "$FINDINGS"
verdict() {  # STEP STATUS NOTE; tabs, carriage returns and newlines in NOTE become spaces
  local note="${3//$'\t'/ }"; note="${note//$'\r'/ }"
  printf '%s\t%s\t%s\n' "$1" "$2" "${note//$'\n'/ }" >> "$VERDICT"
}

# --- the base ----------------------------------------------------------------
# Never a fetch: a sandbox may keep .git read-only. The remote is asked
# with ls-remote, which writes nothing.
BASE_REF=$(git rev-parse --symbolic-full-name "$BASE" 2>/dev/null || true)
REMOTE=""
for rem in $(git remote); do  # the longest remote name that prefixes the ref
  case "$BASE_REF" in
    "refs/remotes/$rem/"*) [ "${#rem}" -le "${#REMOTE}" ] || REMOTE=$rem ;;
  esac
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
py() { python3 "$LOOK_DIR/look.py" "$@"; }  # beside look.sh: never a here-doc (look.py)

# Changed files that are still in the checkout (a sparse checkout can lack
# some); -z keeps odd names unquoted.
FILES=()
while IFS= read -r -d '' f; do [ -e "$f" ] && FILES+=("$f"); done < <(git diff -z --name-only --diff-filter=d "$MERGE_BASE" HEAD)
COMMITS=$(git rev-list --count "$MERGE_BASE..HEAD")

# scan STEP VERSION-ARG CMD...: runs one scanner, turns its JSON into findings
# and adds its verdict row. Missing, erroring or unreadable is a warn row, never
# a stop.
scan() {
  local step="$1" version="$2" rc=0 n reason errors more; shift 2
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
  more=""; [ -z "$errors" ] || more="; $errors"
  case "$n" in
    0) if [ -n "$errors" ]; then verdict "$step" warn "$errors"; else verdict "$step" pass ""; fi ;;
    1) verdict "$step" fail "1 finding$more" ;;
    *) verdict "$step" fail "$n findings$more" ;;
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
    case "$s" in
      test) step test "$PM_RUN test" . ;;
      *) step typecheck "$PM_RUN $s" . ;;
    esac
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
  case " ${STEP_NAMES[*]:-} " in
    *" $name "*) ;;
    *) verdict SUITE_SKIP warn "no suite step named $name" ;;
  esac
done
py snapshot "$WORK/before.json" || die "look: git status failed in look's temp worktree"
for i in ${STEP_NAMES[@]+"${!STEP_NAMES[@]}"}; do
  name="${STEP_NAMES[$i]}"; cmd="${STEP_CMDS[$i]}"; dir="${STEP_DIRS[$i]}"
  case "$SKIP" in
    *",$name,"*) verdict "$name" skip SUITE_SKIP; continue ;;
  esac
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

# What the suite changed, it changed in the temp worktree, which goes with it:
# a should-fix finding names it, and nothing is put back (header).
py snapshot "$WORK/after.json" || die "look: git status failed in look's temp worktree"
py changed "$WORK/before.json" "$WORK/after.json" >> "$FINDINGS"

rc=0; py write "$VERDICT" "$FINDINGS" "$FINDINGS_DIR/look.json" || rc=$?
[ -z "$SETUP_STEPS" ] || die "look: setup error: suite step(s)${SETUP_STEPS} failed on a permission error, most likely the sandbox, not the code. Give them writable temp and cache dirs, then look again; their output is in look.json as watchpoints."
exit "$rc"
