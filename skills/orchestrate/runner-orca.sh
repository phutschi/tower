# Orca behind the runner functions (runner.sh): its CLI's terminals,
# worktrees and agent statuses (`orca skills get orca-cli`). Sourced by
# runner.sh; every orca call of the kit is here, but runner_detect's probe.
# Every call takes --json; an error is {"ok":false,"error":{"code":…}} on
# stdout with a non-zero exit, and the code decides, never the wording.

# The CLI a kind runs as (CONTEXT.md Kind).
orca_cli() { case "$1" in cursor) echo cursor-agent ;; *) echo "$1" ;; esac; }

# NAME's agent CLI of KIND, started in terminal PANE with HARNESS_ARGS: its
# command line typed into the terminal's shell. Orca's error, if any, is
# printed. It then reads the agent until Orca lists it as working, waiting or
# done (START_TRIES reads, a second apart). One blocked on the workspace trust
# menu, its terminal showing it, is said as herdr says it ("agent blocked
# during startup"), for executor.sh to answer; blocked on any other prompt, it
# fails, the prompt left for the operator.
runner_agent_start() {
  local name="$1" kind="$2" pane="$3" line out tries=0; shift 4
  # A missing CLI would leave a shell saying "command not found" (executor.sh kind_installed).
  kind_installed "$kind" || { echo "agent start: $(orca_cli "$kind") is not installed: install it, or use another kind" >&2; return 1; }
  line=$(printf '%q ' "$(orca_cli "$kind")" "$@"); line=${line% }
  out=$(orca terminal send --terminal "$pane" --text "$line" --enter --json) || { echo "$out" >&2; return 1; }
  while :; do
    case "$(runner_agent_state "$name" "$pane")" in
      blocked*)
        if runner_agent_tail "$name" "$pane" 40 2>/dev/null | grep -qiE 'trust[[:space:]]+(this|the[[:space:]]+files[[:space:]]+in[[:space:]]+this)[[:space:]]+folder|trust[[:space:]]+the[[:space:]]+contents[[:space:]]+of[[:space:]]+this[[:space:]]+directory'; then
          echo "agent blocked during startup" >&2
        else
          echo "agent start: $name is blocked on a prompt in terminal $pane that does not show the workspace trust menu: answer it there, then brief it" >&2
        fi
        return 1 ;;
      *" True"|gone|unreadable) return 0 ;;   # until_ready decides
    esac
    tries=$((tries+1)); [ "$tries" -lt "${START_TRIES:-10}" ] || return 0
    [ "${DRY_RUN:-0}" = 1 ] || sleep 1
  done
}
# The agent in terminal PANE as Orca reads it, as herdr's: "<status> <ready>"
# (Orca's waiting and done, a finished turn and its resting state, are idle);
# an agent Orca does not list yet (a terminal agent reports on its first turn)
# is idle once its terminal's TUI is, else "unknown False"; gone when the
# terminal is closed (terminal_handle_stale), not when the agent exits; and
# unreadable when Orca does not answer for any other reason, a wait included.
runner_agent_state() {
  local out
  out=$(orca_listed "$2")
  [ "$out" = unlisted ] || { echo "$out"; return; }
  # Satisfied: idle; unsatisfied (or Orca's timeout code): not yet; any other
  # failure says nothing about the agent.
  out=$(orca terminal wait --terminal "$2" --for tui-idle --timeout-ms 1000 --json 2>/dev/null) || true
  echo "$out" | jsonq '("idle True" if d["result"]["wait"]["satisfied"] else "unknown False") if d.get("ok") else ("unknown False" if d["error"]["code"] == "timeout" else "unreadable")' 2>/dev/null \
    || echo unreadable
}
# The agent in terminal PANE as Orca's agent list has it: "<status> <ready>",
# unlisted, gone or unreadable (runner_agent_state, without the TUI's word).
orca_listed() {
  local out key
  if ! out=$(orca terminal show --terminal "$1" --json 2>/dev/null); then
    case "$out" in *'"terminal_handle_stale"'*) echo gone ;; *) echo unreadable ;; esac
    return
  fi
  key=$(echo "$out" | jsonq '"%s:%s" % (d["result"]["terminal"]["tabId"], d["result"]["terminal"]["leafId"])' 2>/dev/null) \
    && out=$(orca agent list --json 2>/dev/null) \
    && out=$(echo "$out" | KEY=$key jsonq '(lambda a: {"working": "working True", "waiting": "idle True", "done": "idle True"}.get(a["state"], "%s False" % a["state"]) if a else "unlisted")(next((a for a in d["result"]["agents"] if a.get("paneKey") == __import__("os").environ["KEY"]), None))' 2>/dev/null) \
    || { echo unreadable; return; }
  echo "$out"
}
runner_name() { echo Orca; }
runner_ready_hint() { echo "orca agent list --json  shows it waiting or done"; }
runner_agent_tail() { orca terminal read --terminal "$2" --json | jsonq '"\n".join(d["result"]["terminal"]["tail"])' | tail -n "$3"; }
runner_send_text()  { orca terminal send --terminal "$1" --text "$2" --json >/dev/null; }
# NAME PANE TEXT: TEXT typed into terminal PANE, then Enter, only while Orca
# lists an agent there ready for input: anything else at that address (a
# shell, a menu) would take the text as its own input.
runner_send_message() {
  local s out; s=$(orca_listed "$2")
  case "$s" in
    "idle True"|"working True") ;;
    *) echo "Orca lists no agent ready for input in terminal $2 ($s): send once  orca agent list --json  shows $1's terminal waiting or done" >&2; return 1 ;;
  esac
  out=$(orca terminal send --terminal "$2" --text "$3" --enter --json) || { echo "$out" >&2; return 1; }
}
# Each key a send of its own: Orca refuses text and Enter together while an
# agent shows a menu.
runner_send_keys() {
  local pane="$1" key; shift
  for key in "$@"; do
    case "$key" in
      Enter) orca terminal send --terminal "$pane" --enter --json >/dev/null || return 1 ;;
      Down)  orca terminal send --terminal "$pane" --text $'\e[B' --json >/dev/null || return 1 ;;
      *) echo "runner_send_keys: no Orca send for key $key" >&2; return 1 ;;
    esac
  done
}

# --- the layout (CONTEXT.md Layout, Orca) -----------------------------------
# A failing call returns non-zero with Orca's error on stderr.

# orca_new ARGS...: a call that makes a terminal or a split; prints the
# answer's handle, then its tab, on one line.
orca_new() {
  local out
  out=$(orca "$@" --json) || { echo "$out" >&2; return 1; }
  echo "$out" | jsonq '(lambda t: "%s %s" % (t["handle"], t["tabId"]))(d["result"].get("terminal") or d["result"]["split"])'
}
# The orchestrator's workspace, a chat or a terminal alike: the caller's.
runner_self() {
  local out
  out=$(orca worktree current --json) || { echo "$out" >&2; return 1; }
  echo "$out" | jsonq 'd["result"]["worktree"]["id"]'
}
runner_workspace() { [ -n "$1" ] && echo "$1"; }
# In workspace WS: a tower tab, the console (CONSOLE_CMD) over an empty
# shell; the dev server, when given, in a tab of its own, running DEV_CMD in
# REPO/DEV_DIR. Each starts in REPO: Orca opens a terminal in its workspace's
# root, which may be a checkout REPO is nested in. Prints "<console> <shell>
# [<dev>]", then the tabs' pane map lines. A failed call leaves its pane
# empty, which fails the function.
runner_open_run_panes() {
  local ws="$1" repo="$2" cd console tab shell dev="" devtab=""
  cd="cd $(printf %q "$repo")"
  read -r console tab <<< "$(orca_new terminal create --worktree "id:$ws" --title tower --command "$cd && $3")" && [ -n "$console" ] || return 1
  read -r shell _ <<< "$(orca_new terminal split --terminal "$console" --direction horizontal --command "$cd")" && [ -n "$shell" ] || return 1
  if [ $# -ge 5 ]; then
    read -r dev devtab <<< "$(orca_new terminal create --worktree "id:$ws" --title dev --command "cd $(printf %q "$repo/$4") && $5")" && [ -n "$dev" ] || return 1
  fi
  echo "$console $shell${dev:+ $dev}"
  printf '%-16s%s   (console over shell)\n' "tower tab:" "$tab"
  [ -z "$dev" ] || printf '%-16s%s\n' "dev tab:" "$devtab"
}
# Lane A's terminal in workspace WS, a tab of its own, started in REPO (the
# user's checkout). Prints "<pane> <tab>".
runner_open_lane_a() {
  local pane tab
  read -r pane tab <<< "$(orca_new terminal create --worktree "id:$1" --title lane-a --command "cd $(printf %q "$2")")" && [ -n "$pane" ] || return 1
  echo "$pane $tab"
}
runner_read_cmd()    { echo "orca terminal read --terminal <id> --json"; }
# Lane LANE's worktree on BRANCH from BASE, a child worktree of the
# orchestrator's workspace (the pane map's orchestrator line; $MAP is
# add-lane's), named LABEL, with a terminal of its own, started in it. Orca
# picks its path (WT is unused), and skips the repo's setup hooks: add-lane
# installs. A worktree Orca made on any branch but BRANCH is refused before
# its terminal opens. Prints "<pane> <checkout>"; dies saying what to remove.
# shortcut: Orca also opens the worktree's first terminal, left as an idle shell; reuse it once `worktree create --json` is known to name its handle.
runner_open_lane() {
  local branch="$2" base="$3" label="$5" ws out id="" path="" got pane
  # Orca gives a taken branch name a numeric suffix: the lane would commit elsewhere.
  ! git -C "$1" show-ref --verify --quiet "refs/heads/$branch" \
    || die "add-lane: branch $branch exists, and Orca would make lane $LANE's worktree on another branch: remove it or pick another, then rerun  $RERUN"
  ws=$(orchestrator_of "$MAP")
  out=$(orca worktree create --name "$label" --branch "$branch" --base-branch "$base" --parent-worktree "id:$ws" --setup skip --json) \
    || die "add-lane: Orca could not create lane $LANE's worktree ($out): remove branch $branch if it exists, then rerun  $RERUN"
  id=$(echo "$out" | jsonq 'd["result"]["worktree"]["id"]' 2>/dev/null) && path=$(echo "$out" | jsonq 'd["result"]["worktree"]["path"]' 2>/dev/null) || path=""
  [ -n "$path" ] || die "add-lane: Orca made lane $LANE's worktree but its answer names none ($out): remove it (orca worktree list --json) and branch $branch, then rerun  $RERUN"
  # The branch may have been taken since the check: Orca then suffixes it.
  got=$(orca worktree show --worktree "id:$id" --json 2>/dev/null | jsonq '(d["result"]["worktree"].get("branch") or "").replace("refs/heads/", "", 1)' 2>/dev/null) || got=""
  [ "$got" = "$branch" ] || die "add-lane: Orca made lane $LANE's worktree on branch ${got:-(none it names)}, not $branch: remove it (orca worktree rm --worktree id:$id --force) and branch ${got:-$branch}, then rerun  $RERUN"
  read -r pane _ <<< "$(orca_new terminal create --worktree "id:$id" --title "$label" --command "cd $(printf %q "$path")")"
  [ -n "$pane" ] || die "add-lane: Orca created lane $LANE's worktree $path but no terminal in it: remove it (orca worktree rm --worktree id:$id --force) and branch $branch, then rerun  $RERUN"
  echo "$pane $path"
}
# Each lane has its worktree; there is no grid to place it in.
runner_place_lane() { echo "$3"; }
# 0: terminal PANE is open; 1: Orca says its handle is stale; 2: Orca cannot
# say, its error on stderr.
runner_pane_exists() {
  local out
  out=$(orca terminal show --terminal "$1" --json) && return 0
  case "$out" in
    *'"terminal_handle_stale"'*) return 1 ;;
    *) echo "$out" >&2; return 2 ;;
  esac
}
runner_pane_check() { echo Orca; }
# The Reviewer slots R1 and R2: a terminal tab each in workspace WS, started
# in REPO (LABEL is herdr's). Prints "<tab>,<tab> <r1> <r2>".
runner_open_reviewer_slots() {
  local r1 t1 r2 t2 cd
  cd="cd $(printf %q "$2")"
  read -r r1 t1 <<< "$(orca_new terminal create --worktree "id:$1" --title R1 --command "$cd")" && [ -n "$r1" ] || return 1
  read -r r2 t2 <<< "$(orca_new terminal create --worktree "id:$1" --title R2 --command "$cd")" && [ -n "$r2" ] || return 1
  echo "$t1,$t2 $r1 $r2"
}
# A Reviewer that exits leaves its terminal at a shell, which Orca still
# lists as done: its terminal is closed, so it reads gone, and the next
# Reviewer gets a tab of its own.
# shortcut: a fixed pause for /exit to finish; wait instead once Orca can tell that an agent left its terminal.
runner_end_agent() { [ "${DRY_RUN:-0}" = 1 ] || sleep 2; orca terminal close --terminal "$1" --json >/dev/null; }
# PANE while it is open, else a new terminal tab SLOT in the orchestrator's
# workspace ($MAP is add-reviewer's), started in REPO.
runner_reviewer_pane() {
  local rc=0 ws pane
  runner_pane_exists "$2" 2>/dev/null || rc=$?
  case $rc in
    0) echo "$2"; return ;;
    2) echo "Orca cannot say whether Reviewer slot $1's terminal $2 is open" >&2; return 1 ;;
  esac
  ws=$(orchestrator_of "$MAP")
  read -r pane _ <<< "$(orca_new terminal create --worktree "id:$ws" --title "$1" --command "cd $(printf %q "$3")")" && [ -n "$pane" ] || return 1
  echo "$pane"
}
