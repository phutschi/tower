# Orca behind the runner functions (runner.sh): its CLI's terminals,
# worktrees and agent statuses (`orca skills get orca-cli`). Sourced by
# runner.sh; every orca call of the kit is here, but runner_detect's probe.
# Every call takes --json; an error is {"ok":false,"error":{"code":…}} on
# stdout with a non-zero exit, and the code decides, never the wording.

# Every orca call runs the CLI the session names (ORCA_CLI_COMMAND: orca,
# orca-ide or a path), not whichever orca is on PATH.
orca() { command "$ORCA_CLI_COMMAND" "$@"; }   # set: runner_detect saw it

# NAME's agent CLI of KIND, started in terminal PANE with HARNESS_ARGS: its
# command line typed into the terminal's shell. Orca's error, if any, is
# printed, and 3 returned when Orca proves nothing was typed, 4 when it may
# have been (no receipt, a lost reply). It then reads the agent until
# Orca lists it as working, waiting or done (START_TRIES reads, a second
# apart). One blocked on the workspace trust menu, by Orca's wait reason, is
# 6, for executor.sh to answer; blocked on any other prompt, it fails, the
# prompt left for the operator. A launch line goes to a shell, which gives
# no delivery receipt: the agent's state, read after, is the evidence.
runner_agent_start() {
  local name="$1" kind="$2" pane="$3" line out tries=0; shift 4
  # A missing CLI would leave a shell saying "command not found" (executor.sh kind_installed).
  kind_installed "$kind" || { echo "agent start: $(kind_cli "$kind") is not installed: install it, or use another kind" >&2; return 3; }
  line=$(printf '%q ' "$(kind_cli "$kind")" "$@"); line=${line% }
  out=$(orca terminal send --terminal "$pane" --text "$line" --enter --json) || {
    echo "$out" >&2; if orca_send_refused "$out"; then return 3; else return 4; fi; }
  while :; do
    case "$(runner_agent_state "$name" "$pane")" in
      blocked*)
        orca_trust_menu "$pane" && return 6
        echo "agent start: $name is blocked on a prompt in terminal $pane that Orca does not report as the workspace trust prompt: answer it there, then brief it" >&2
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
# is idle once its terminal's TUI is, "blocked False" if Orca then gives the
# workspace-trust wait reason, "shell False" if the screen shows a bare shell
# (a launch refused, or an agent that exited before its first turn), else
# "unknown False"; never gone (not when the agent exits, and a stale handle
# may name a terminal still open under another); unreadable when Orca does
# not answer, a stale handle and a wait included.
runner_agent_state() {
  local out
  out=$(orca_listed "$2")
  [ "$out" = unlisted ] || { echo "$out"; return; }
  # Satisfied: idle; unsatisfied (or Orca's timeout code): not yet; any other
  # failure says nothing about the agent.
  out=$(orca terminal wait --terminal "$2" --for tui-idle --timeout-ms 1000 --json 2>/dev/null) || true
  out=$(echo "$out" | jsonq '("idle True" if d["result"]["wait"]["satisfied"] else "unknown False") if d.get("ok") else ("unknown False" if d["error"]["code"] == "timeout" else "unreadable")' 2>/dev/null) \
    || out=unreadable
  # A trust menu idles the TUI before the agent reports: blocked, not ready;
  # so does a bare shell.
  if [ "$out" = "idle True" ]; then
    if orca_trust_menu "$2"; then out="blocked False"
    elif screen_is_shell "$(orca_screen "$2")"; then out="shell False"; fi
  fi
  echo "$out"
}
# Is the agent in terminal PANE held at its workspace-trust prompt? Orca's own
# wait reason says so (terminal show's agentWait), which takes the prompt
# lowest on the screen; old words above it, from a question already answered,
# do not count.
orca_trust_menu() {
  case "$(orca_wait_reason "$1")" in agent-trust-workspace|codex-trust-workspace) return 0 ;; esac
  return 1
}
# Orca's reason the agent in terminal PANE waits on a prompt (terminal show's
# agentWait), empty for none; "?" when Orca does not answer.
orca_wait_reason() {
  orca terminal show --terminal "$1" --json 2>/dev/null \
    | jsonq '(d["result"]["terminal"].get("agentWait") or {}).get("reason") or ""' 2>/dev/null || echo "?"
}
# The state Orca's agent list gives the agent in terminal PANE (working,
# waiting, done, blocked, ...), unlisted, or unreadable.
orca_raw() {
  local out key
  # A stale handle proves nothing: Orca's handles end with its runtime.
  out=$(orca terminal show --terminal "$1" --json 2>/dev/null) || { echo unreadable; return; }
  key=$(echo "$out" | jsonq '"%s:%s" % (d["result"]["terminal"]["tabId"], d["result"]["terminal"]["leafId"])' 2>/dev/null) \
    && out=$(orca agent list --json 2>/dev/null) \
    && out=$(echo "$out" | KEY=$key jsonq '(lambda a: a["state"] if a else "unlisted")(next((a for a in d["result"]["agents"] if a.get("paneKey") == __import__("os").environ["KEY"]), None))' 2>/dev/null) \
    || { echo unreadable; return; }
  echo "$out"
}
# The same as "<status> <ready>" (waiting and done are idle), unlisted or
# unreadable: runner_agent_state, without the TUI's word.
orca_listed() {
  local s; s=$(orca_raw "$1")
  case "$s" in
    working) echo "working True" ;;
    waiting|done) echo "idle True" ;;
    unlisted|unreadable) echo "$s" ;;
    *) echo "$s False" ;;
  esac
}
# Terminal PANE's rendered screen, its lines that are not blank; empty when
# Orca has no rendered screen to give.
orca_screen() {
  orca terminal read --terminal "$1" --screen --json 2>/dev/null \
    | jsonq '"\n".join(d["result"]["terminal"]["tail"]) if d["result"]["terminal"].get("source") == "screen" else ""' 2>/dev/null \
    | grep -v '^[[:space:]]*$'
}
# Does SCREEN end in a shell prompt (bash, zsh, oh-my-zsh, fish)?
screen_ends_in_shell() {
  echo "$1" | tail -1 | grep -qE '([^0-9]%|[$#>❯➜])[[:space:]]*$|^[[:space:]]*➜'
}
# Does SCREEN show an agent's interface: its footer words in the last 3
# lines? They win over a last line shaped like a prompt (a status line under
# the input box). An empty SCREEN (Orca has no rendered one) shows nothing.
# shortcut: an agent is told from a shell by its interface's own words, upgrade once Orca's CLI says what runs in a terminal.
screen_shows_agent() {
  echo "$1" | tail -3 | grep -qiE '\? for shortcuts|shift\+tab to cycle|esc to interrupt|bypass permissions|context left|add a follow-up|/ commands'
}
# Does SCREEN show a bare shell: a prompt on its last line, and no agent's
# footer words?
screen_is_shell() { ! screen_shows_agent "$1" && screen_ends_in_shell "$1"; }
orca_screen_shows_agent() { screen_shows_agent "$(orca_screen "$1")"; }   # the same, for terminal PANE's screen
runner_name() { echo Orca; }
runner_ready_hint() { echo "\"\$ORCA_CLI_COMMAND\" agent list --json  shows it waiting or done"; }
runner_agent_tail() { orca terminal read --terminal "$2" --json | jsonq '"\n".join(d["result"]["terminal"]["tail"])' | tail -n "$3"; }
runner_send_text()  { orca terminal send --terminal "$1" --text "$2" --json >/dev/null; }
# Did a send's answer OUT (exit 0) show its prompt arrive? Orca's receipt says
# so, unless it names a host or provider that cannot tell (old-host,
# unsupported), or says delivery went unobserved (a permission prompt, the
# terminal's process replaced). No receipt shows nothing.
orca_send_seen() {
  echo "$1" | jsonq '(lambda p: bool(p) and p.get("provider") not in ("old-host", "unsupported") and p.get("observation") not in ("permission", "incarnation_replaced", "unsupported"))(d["result"]["send"].get("prompt") or {})' 2>/dev/null | grep -qx True
}
# Does a failed send's answer OUT prove nothing was typed? Orca refused the
# input (accepted false), called it safe to retry, or failed before any input
# (a bad handle or argument, a menu refusing text with Enter). A lost reply or
# a missing receipt proves nothing.
orca_send_refused() {
  echo "$1" | jsonq '(lambda d, x: (d["result"]["send"].get("accepted") is False) if d.get("ok") else (x.get("deliveryOutcome") != "unknown" and (x.get("retrySafe") is True or d["error"]["code"] in ("agent_prompt_blocked", "invalid_argument", "selector_not_found", "terminal_not_found", "terminal_handle_stale"))))(d, (d.get("error") or {}).get("data") or {})' 2>/dev/null | grep -qx True
}
# Does terminal PANE show a shell, verified: Orca lists no agent there, or one
# done (an agent that exited stays listed done), gives no wait reason, and the
# screen shows a bare shell (screen_is_shell). An agent listed waiting,
# working or blocked, or a prompt Orca names, holds whatever the screen shows.
runner_pane_at_shell() {
  case "$(orca_raw "$1")" in unlisted|done) ;; *) return 1 ;; esac
  [ -z "$(orca_wait_reason "$1")" ] || return 1
  screen_is_shell "$(orca_screen "$1")"
}
runner_names_agents() { return 1; }   # Orca reaches an agent only through its terminal handle
# NAME PANE TEXT: TEXT typed into terminal PANE, then Enter, only to an agent
# ready for input there: anything else at that address (a shell, a menu)
# would take the text as its own input. Working or waiting, it goes. Done, it
# goes only while the screen shows the agent: Orca keeps an agent that exited
# to its shell listed as done. Unlisted, it goes once the screen is idle, by
# the start's rule (runner_agent_state): a terminal agent reports to Orca on
# its first turn; and only while the screen shows the agent, not a shell, not
# a screen Orca cannot render, not one showing neither. Held, or refused by
# Orca, it returns 1: nothing was sent; sent without a receipt, or taken with
# a receipt that does not show it arrive (orca_send_seen), 4.
runner_send_message() {
  local s out
  s=$(orca_raw "$2")
  case "$s" in
    working|waiting) ;;
    done) orca_screen_shows_agent "$2" \
      || { echo "Orca lists $1 as done, but terminal $2's screen does not show the agent (it may have exited to its shell): check it there" >&2; return 1; } ;;
    unlisted)
      case "$(runner_agent_state "$1" "$2")" in
        "idle True") ;;
        # An agent that exited before its first turn leaves an idle shell.
        "shell False") echo "Orca lists no agent in terminal $2, and its screen shows a shell: check it there" >&2; return 1 ;;
        *) echo "Orca lists no agent in terminal $2, and its screen is not idle: send once  \"\$ORCA_CLI_COMMAND\" agent list --json  shows $1's terminal waiting or done" >&2; return 1 ;;
      esac
      orca_screen_shows_agent "$2" \
        || { echo "Orca lists no agent in terminal $2, and its screen does not show the agent (Orca has no rendered screen of it, or it shows neither the agent nor a shell): check it there" >&2; return 1; } ;;
    *) echo "Orca lists $1's terminal $2 as $s: not ready for input" >&2; return 1 ;;
  esac
  out=$(orca terminal send --terminal "$2" --text "$3" --enter --json) || {
    echo "$out" >&2; if orca_send_refused "$out"; then return 1; else return 4; fi; }
  orca_send_seen "$out" || { echo "Orca took the text, but its receipt does not show it arrive: $out" >&2; return 4; }
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
# [<dev>]", then the tabs' pane map lines. A failed call fails the function,
# which then prints what opened before it ("<console> [<shell>]"), to close.
runner_open_run_panes() {
  local ws="$1" repo="$2" cd console tab shell dev="" devtab=""
  cd="cd $(printf %q "$repo")"
  read -r console tab <<< "$(orca_new terminal create --worktree "id:$ws" --title tower --command "$cd && $3")" && [ -n "$console" ] || return 1
  read -r shell _ <<< "$(orca_new terminal split --terminal "$console" --direction horizontal --command "$cd")"
  [ -n "$shell" ] || { echo "$console"; return 1; }
  if [ $# -ge 5 ]; then
    read -r dev devtab <<< "$(orca_new terminal create --worktree "id:$ws" --title dev --command "cd $(printf %q "$repo/$4") && $5")"
    [ -n "$dev" ] || { echo "$console $shell"; return 1; }
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
runner_read_cmd()    { echo "\"\$ORCA_CLI_COMMAND\" terminal read --terminal <id> --json"; }
# Lane LANE's worktree on BRANCH from BASE, a child worktree of the
# orchestrator's workspace (the pane map's orchestrator line; $MAP is
# add-lane's), named LABEL, with a terminal of its own, started in it. Orca
# picks its path (WT is unused), and skips the repo's setup hooks: add-lane
# installs. A worktree Orca made on any branch but BRANCH is refused before
# its terminal opens. Prints "<pane> <checkout>"; dies saying what to remove,
# or what to look at first where the run may not own it.
# shortcut: Orca's own first terminal in the worktree is left as an idle shell, reuse it once `worktree create --json` is known to name its handle.
runner_open_lane() {
  local branch="$2" base="$3" label="$5" ws out id="" path="" got pane
  # Orca gives a taken branch name a numeric suffix: the lane would commit elsewhere.
  ! git -C "$1" show-ref --verify --quiet "refs/heads/$branch" \
    || die "add-lane: branch $branch exists, and Orca would make lane $LANE's worktree on another branch: remove it or pick another, then rerun  $RERUN"
  ws=$(orchestrator_of "$MAP")
  out=$(orca worktree create --name "$label" --branch "$branch" --base-branch "$base" --parent-worktree "id:$ws" --setup skip --json) \
    || die "add-lane: Orca could not create lane $LANE's worktree ($out). If branch $branch exists now, look at it before you remove it (another process may have taken it); then rerun  $RERUN"
  id=$(echo "$out" | jsonq 'd["result"]["worktree"]["id"]' 2>/dev/null) && path=$(echo "$out" | jsonq 'd["result"]["worktree"]["path"]' 2>/dev/null) || path=""
  [ -n "$path" ] || die "add-lane: Orca made lane $LANE's worktree but its answer names none ($out): find it (\"\$ORCA_CLI_COMMAND\" worktree list --json) and its branch, and remove only what is this lane's (another process may have taken branch $branch); then rerun  $RERUN"
  # The branch may have been taken since the check: Orca then suffixes it.
  # git says which branch the checkout is on; Orca, when it is not on this disk.
  if [ -d "$path" ]; then got=$(git -C "$path" symbolic-ref --short HEAD 2>/dev/null) || got=""
  else got=$(orca worktree show --worktree "id:$id" --json 2>/dev/null | jsonq '(d["result"]["worktree"].get("branch") or "").replace("refs/heads/", "", 1)' 2>/dev/null) || got=""
  fi
  # An unread branch proves nothing about who owns it: nothing is named for removal.
  [ -n "$got" ] || die "add-lane: Orca made lane $LANE's worktree $path, but its branch cannot be read: look at it (\"\$ORCA_CLI_COMMAND\" worktree show --worktree $(printf %q "id:$id") --json) and at branch $branch before you remove anything: another process may have taken the branch. Then rerun  $RERUN"
  [ "$got" = "$branch" ] || die "add-lane: Orca made lane $LANE's worktree on branch $got, not $branch: remove it (\"\$ORCA_CLI_COMMAND\" worktree rm --worktree $(printf %q "id:$id") --force) and branch $got, then rerun  $RERUN"
  read -r pane _ <<< "$(orca_new terminal create --worktree "id:$id" --title "$label" --command "cd $(printf %q "$path")")"
  [ -n "$pane" ] || die "add-lane: Orca created lane $LANE's worktree $path but no terminal in it: remove it (\"\$ORCA_CLI_COMMAND\" worktree rm --worktree $(printf %q "id:$id") --force) and branch $branch, then rerun  $RERUN"
  echo "$pane $path"
}
# Each lane has its worktree; there is no grid to place it in.
runner_place_lane() { echo "$3"; }
# 0: terminal PANE is open; 3: Orca says its handle is stale, which a closed
# terminal and a runtime restart alike give (the terminal may be open under a
# new handle); 2: Orca cannot say, its error on stderr. Never 1.
runner_pane_exists() {
  local out
  out=$(orca terminal show --terminal "$1" --json) && return 0
  case "$out" in
    *'"terminal_handle_stale"'*) return 3 ;;
    *) echo "$out" >&2; return 2 ;;
  esac
}
runner_pane_check() { echo Orca; }
# The Reviewer slots R1 and R2, a terminal tab each in workspace WS, started
# in REPO (LABEL is herdr's), one a call, for the caller to record each before
# the next: with no R1, R1's (prints "<tab> <r1>"); R1 and its tab given,
# R2's (prints "<tab>,<tab> <r1> <r2>").
runner_open_reviewer_slots() {
  local r1="${4:-}" t1="${5:-}" r2 t2 cd
  cd="cd $(printf %q "$2")"
  if [ -z "$r1" ]; then
    read -r r1 t1 <<< "$(orca_new terminal create --worktree "id:$1" --title R1 --command "$cd")" && [ -n "$r1" ] || return 1
    echo "$t1 $r1"; return
  fi
  read -r r2 t2 <<< "$(orca_new terminal create --worktree "id:$1" --title R2 --command "$cd")" && [ -n "$r2" ] || return 1
  echo "$t1,$t2 $r1 $r2"
}
# A Reviewer that exits leaves its terminal at a shell, which Orca still
# lists as done: its terminal is closed, which ends it for sure (0), and the
# next Reviewer gets a tab of its own.
# shortcut: a fixed pause for /exit to finish, wait instead once Orca can tell that an agent left its terminal.
runner_end_agent() { [ "${DRY_RUN:-0}" = 1 ] || sleep 2; orca terminal close --terminal "$1" --json >/dev/null; }
# PANE while it is open; with no PANE (runner_end_agent closed the last), a new
# terminal tab SLOT in the orchestrator's workspace ($MAP is add-reviewer's),
# started in REPO. A stale or unanswered PANE fails, saying so.
runner_reviewer_pane() {
  local rc=0 ws pane
  if [ -n "$2" ]; then
    runner_pane_exists "$2" 2>/dev/null || rc=$?
    case $rc in
      0) echo "$2"; return ;;
      3) stale_handle "Reviewer slot $1" "$2" "the $1 entry of the review tab line"; return 1 ;;
      *) echo "Orca cannot say whether Reviewer slot $1's terminal $2 is open" >&2; return 1 ;;
    esac
  fi
  ws=$(orchestrator_of "$MAP")
  read -r pane _ <<< "$(orca_new terminal create --worktree "id:$ws" --title "$1" --command "cd $(printf %q "$3")")" && [ -n "$pane" ] || return 1
  echo "$pane"
}
