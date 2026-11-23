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
# done (START_TRIES reads, a second apart): one blocked shows a trust menu, said as herdr says
# it ("agent blocked during startup"), for executor.sh to answer.
runner_agent_start() {
  local name="$1" kind="$2" pane="$3" line out tries=0; shift 4
  # A missing CLI would leave a shell saying "command not found" (executor.sh kind_installed).
  kind_installed "$kind" || { echo "agent start: $(orca_cli "$kind") is not installed: install it, or use another kind" >&2; return 1; }
  line=$(printf '%q ' "$(orca_cli "$kind")" "$@"); line=${line% }
  out=$(orca terminal send --terminal "$pane" --text "$line" --enter --json) || { echo "$out" >&2; return 1; }
  while :; do
    case "$(runner_agent_state "$name" "$pane")" in
      blocked*) echo "agent blocked during startup" >&2; return 1 ;;
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
# unreadable when Orca does not answer for any other reason.
runner_agent_state() {
  local out key
  if ! out=$(orca terminal show --terminal "$2" --json 2>/dev/null); then
    case "$out" in *'"terminal_handle_stale"'*) echo gone ;; *) echo unreadable ;; esac
    return
  fi
  key=$(echo "$out" | jsonq '"%s:%s" % (d["result"]["terminal"]["tabId"], d["result"]["terminal"]["leafId"])' 2>/dev/null) \
    && out=$(orca agent list --json 2>/dev/null) \
    && out=$(echo "$out" | KEY=$key jsonq '(lambda a: {"working": "working True", "waiting": "idle True", "done": "idle True"}.get(a["state"], "%s False" % a["state"]) if a else "unlisted")(next((a for a in d["result"]["agents"] if a.get("paneKey") == __import__("os").environ["KEY"]), None))' 2>/dev/null) \
    || { echo unreadable; return; }
  [ "$out" = unlisted ] || { echo "$out"; return; }
  if orca terminal wait --terminal "$2" --for tui-idle --timeout-ms 1000 --json >/dev/null 2>&1; then echo "idle True"; else echo "unknown False"; fi
}
runner_name() { echo Orca; }
runner_ready_hint() { echo "orca agent list --json  shows it waiting or done"; }
runner_agent_tail() { orca terminal read --terminal "$2" --json | jsonq '"\n".join(d["result"]["terminal"]["tail"])' | tail -n "$3"; }
runner_send_text()  { orca terminal send --terminal "$1" --text "$2" --json >/dev/null; }
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
runner_message_cmd() { echo "orca terminal send --terminal ${2:-<id>} --text \"${3:-<text>}\" --enter --json"; }
