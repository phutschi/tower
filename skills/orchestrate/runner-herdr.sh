# herdr behind the runner functions (runner.sh). Sourced by runner.sh; every
# herdr call of the kit is here.

# NAME's agent CLI of KIND, started in PANE with HARNESS_ARGS. herdr's answer,
# or its error, is printed for the caller's busy and trust handling.
runner_agent_start() {
  local name="$1" kind="$2" pane="$3"; shift 4
  herdr agent start "$name" --kind "$kind" --pane "$pane" -- "$@"
}
# An agent as herdr reads it, one line: "<agent_status> <interactive_ready>"
# (True or False; True when herdr leaves the field out, as an older herdr
# does); gone only when herdr answers agent_not_found; unreadable when herdr
# fails for any other reason (a server restarting, a timeout) or answers
# without a status, which says nothing about the agent. herdr's errors are on
# stderr, read only when the call fails.
runner_agent_state() {
  local out err r
  err=$(mktemp)
  if out=$(herdr agent get "$1" 2>"$err"); then
    r=$(echo "$out" | jsonq '(lambda a: "%s %s" % (a["agent_status"], a.get("interactive_ready", True)) if a.get("agent_status") else "unreadable")((d.get("result") or {}).get("agent") or {})' 2>/dev/null) || r=unreadable
  elif grep -q '"agent_not_found"' "$err"; then r=gone
  else r=unreadable
  fi
  rm -f "$err"; echo "$r"
}
runner_agent_tail() { herdr agent read "$1" --source recent-unwrapped --lines "$3"; }
runner_send_text()  { herdr pane send-text "$1" "$2" >/dev/null; }
runner_send_keys()  { local pane="$1"; shift; herdr pane send-keys "$pane" "$@" >/dev/null; }
