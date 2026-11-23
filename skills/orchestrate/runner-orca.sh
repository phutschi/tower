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
  local name="$1" kind="$2" pane="$3" line tries=0; shift 4
  # A missing CLI would leave a shell saying "command not found" (executor.sh kind_installed).
  kind_installed "$kind" || { echo "agent start: $(orca_cli "$kind") is not installed: install it, or use another kind" >&2; return 1; }
  line=$(printf '%q ' "$(orca_cli "$kind")" "$@"); line=${line% }
  orca terminal send --terminal "$pane" --text "$line" --enter --json >/dev/null || return 1
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
# (Orca's waiting is idle), "unknown False" while the agent has not reported
# to Orca yet, gone when the terminal is closed (terminal_handle_stale), and
# unreadable when Orca does not answer for any other reason.
runner_agent_state() {
  local out key
  if ! out=$(orca terminal show --terminal "$2" --json 2>/dev/null); then
    case "$out" in *'"terminal_handle_stale"'*) echo gone ;; *) echo unreadable ;; esac
    return
  fi
  key=$(echo "$out" | jsonq '"%s:%s" % (d["result"]["terminal"]["tabId"], d["result"]["terminal"]["leafId"])' 2>/dev/null) \
    && out=$(orca agent list --json 2>/dev/null) \
    && echo "$out" | KEY=$key jsonq '(lambda a: {"working": "working True", "waiting": "idle True", "done": "done True"}.get(a["state"], "%s False" % a["state"]) if a else "unknown False")(next((a for a in d["result"]["agents"] if a.get("paneKey") == __import__("os").environ["KEY"]), None))' 2>/dev/null \
    || echo unreadable
}
runner_name() { echo Orca; }
runner_ready_hint() { echo "orca agent list --json  shows it waiting"; }
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
