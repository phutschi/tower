# herdr behind the runner functions (runner.sh). Sourced by runner.sh; every
# herdr call of the kit is here, but runner_detect's probe.

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

# --- the layout (CONTEXT.md Layout, herdr) ----------------------------------
# A failing call returns non-zero with herdr's error on stderr, unless it dies
# with its own message. add-lane's functions name its rerun ($RERUN, $LANE).

runner_self() { echo "$HERDR_PANE_ID"; }
# The workspace of PANE (the orchestrator's): fails when herdr cannot say.
runner_workspace() { herdr pane get "$1" | jsonq 'd["result"]["pane"]["workspace_id"]'; }
# The orchestrator's tab: the console right of the orchestrator, half the tab
# (its 60 columns); under it the shell, and dev left of the shell when given,
# running DEV_CMD in REPO/DEV_DIR. Prints "<console> <shell> [<dev>]".
runner_open_run_panes() {
  local repo="$1" console_cmd="$2" console shell dev=""
  console=$(herdr_split "$repo" --current --direction right --ratio 0.5) || return 1
  shell=$(herdr_split "$repo" --pane "$console" --direction down --ratio 0.6) || return 1
  if [ $# -ge 4 ]; then
    dev=$shell
    shell=$(herdr_split "$repo" --pane "$dev" --direction right --ratio 0.5) || return 1
    herdr pane run "$dev" "cd $(printf %q "$repo/$3") && $4" >/dev/null || return 1
  fi
  herdr pane run "$console" "$console_cmd" >/dev/null || return 1
  echo "$console $shell${dev:+ $dev}"
}
herdr_split() { local repo="$1"; shift; herdr pane split "$@" --cwd "$repo" --no-focus | pane_id; }
# Lane A's tab LABEL in workspace WS, lane A its root, with the Reviewer
# column in the lanes tab. Prints "<pane> <tab>[   <column>]": the rest of
# the pane map's tab line after the pane.
runner_open_lane_a() {
  local out tab pane column=""
  out=$(herdr tab create --workspace "$1" --cwd "$2" --label "$3" --no-focus) || return 1
  tab=$(echo "$out" | jsonq 'd["result"]["tab"]["tab_id"]') || return 1
  pane=$(echo "$out" | jsonq 'd["result"]["root_pane"]["pane_id"]') || return 1
  if [ "$3" = lanes ]; then column=$(reviewer_column "$2" "$pane") || return 1; column="   $column"; fi
  echo "$pane $tab$column"
}
# Lane LANE's worktree WT on BRANCH from BASE, in REPO's .worktrees, its pane
# labelled LABEL. Prints the pane; dies saying what to remove.
runner_open_lane() {
  local repo="$1" branch="$2" base="$3" wt="$4" label="$5" out
  out=$(herdr worktree create --cwd "$repo" --branch "$branch" --base "$base" --path "$wt" --label "$label" --no-focus) \
    || die "add-lane: herdr worktree create failed: remove $wt and branch $branch if they exist, then rerun  $RERUN"
  echo "$out" | jsonq 'd["result"]["root_pane"]["pane_id"]' 2>/dev/null \
    || die "add-lane: herdr created $wt but its answer names no pane: close the pane labelled $label, remove $wt and branch $branch, then rerun  $RERUN"
}
# Places lane LANE's pane PANE in tab LABEL's grid, by its place among the
# lanes already there (layout.sh grid_anchor); a tab not open yet opens with
# it as its root (open_tab_with). A pane map from before the lanes tab has
# its lanes in the orchestrator's tab. Prints the pane's new id; dies saying
# how to recover.
runner_place_lane() {
  local map="$1" label="$2" pane="$3" target split tab moved
  read -r target split <<< "$(grid_anchor "$map" "$label")" || true
  tab=$(tab_line "$map" "$label")
  if [ -z "$target" ] && [ -z "$tab" ]; then
    moved=$(open_tab_with "$map" "$label" "$pane") \
      || die "add-lane: lane $LANE's pane $pane did not get a $label tab of its own (see above); it is in the pane map as unplaced: when it was not moved, rerun  $RERUN  to place it; else turn  unplaced lane $LANE: $pane  in $map into  lane $LANE: <its pane's id>  (the rest as it is), add its tab line (named above, else  $label tab: <its tab's id>), and rerun"
    echo "$moved"; return
  fi
  [ -n "$target" ] || die "add-lane: the $label tab has no lane to place lane $LANE beside (see $map)"
  [ -n "$tab" ] || tab=$HERDR_TAB_ID
  moved=$(herdr pane move "$pane" --tab "$tab" --split "$split" --target-pane "$target" --ratio 0.5 --no-focus) \
    || die "add-lane: herdr could not move lane $LANE's pane $pane into the grid; it is in the pane map as unplaced: rerun  $RERUN  to place it"
  echo "$moved" | jsonq 'd["result"].get("move_result", d["result"])["pane"]["pane_id"]' 2>/dev/null \
    || die "add-lane: herdr moved lane $LANE's pane $pane but its answer names no pane: find the lane's pane in the grid (checkout $WT), turn  unplaced lane $LANE: $pane  in $map into  lane $LANE: <that pane's id>  (the rest as it is), and rerun  $RERUN"
}
# The Reviewer slots' tab LABEL in workspace WS, opened in REPO: R2 under R1
# in a lanes tab (its column), right of it in a reviews tab. Prints
# "<tab> <r1> <r2>".
runner_open_reviewer_slots() {
  local out tab r1 r2 split=right
  [ "$3" != lanes ] || split=down
  out=$(herdr tab create --workspace "$1" --cwd "$2" --label "$3" --no-focus) || return 1
  tab=$(echo "$out" | jsonq 'd["result"]["tab"]["tab_id"]') || return 1
  r1=$(echo "$out" | jsonq 'd["result"]["root_pane"]["pane_id"]') || return 1
  r2=$(herdr_split "$2" --pane "$r1" --direction "$split" --ratio 0.5) || return 1
  echo "$tab $r1 $r2"
}
# 0: PANE is open; 1: herdr answers pane_not_found; 2: herdr cannot say, its
# error on stderr.
runner_pane_exists() {
  local err
  err=$(herdr pane get "$1" 2>&1 >/dev/null) && return 0
  case "$err" in
    *'"pane_not_found"'*) return 1 ;;
    *) echo "$err" >&2; return 2 ;;
  esac
}
runner_read_cmd()    { echo "herdr pane read <id> --source recent-unwrapped --lines 60"; }
runner_message_cmd() { echo "herdr agent prompt <agent> \"<text>\""; }

# When anything reviews (LANE_REVIEW or PREFLIGHT on), a full-height column
# right of PANE, a third of its width, R1 over R2, opened in CWD; prints
# "(R1 <pane>, R2 <pane>)", else "(no Reviewer column)".  reviewer_column CWD PANE
reviewer_column() {
  local r1 r2
  if [ "$LANE_REVIEW" = on ] || [ "$PREFLIGHT" = on ]; then
    r1=$(herdr_split "$1" --pane "$2" --direction right --ratio 0.67) || return 1
    r2=$(herdr_split "$1" --pane "$r1" --direction down --ratio 0.5) || return 1
    echo "(R1 $r1, R2 $r2)"
  else
    echo "(no Reviewer column)"
  fi
}

# Moves PANE into a new tab LABEL in the orchestrator pane's workspace,
# unfocused; writes "<LABEL> tab:" to MAP, for the lanes tab with its Reviewer
# column (reviewer_column, in lane A's checkout); prints the pane's new id.
# Dies saying what went wrong. The column follows the run's LANE_REVIEW and
# PREFLIGHT, from MAP's switches: line.  open_tab_with MAP LABEL PANE
open_tab_with() {
  local orch ws moved pane tab column="" line LANE_REVIEW PREFLIGHT
  orch=$(sed -nE 's/^orchestrator: +([^ ]+).*/\1/p' "$1")
  ws=$(runner_workspace "$orch" 2>/dev/null) \
    || die "no workspace for the orchestrator pane $orch (herdr pane get): is it still open?"
  moved=$(herdr pane move "$3" --new-tab --workspace "$ws" --tab-label "$2" --no-focus) \
    || die "herdr could not move pane $3 into a new $2 tab"
  pane=$(echo "$moved" | jsonq 'd["result"].get("move_result", d["result"])["pane"]["pane_id"]' 2>/dev/null) \
    || die "herdr moved pane $3 into a new $2 tab, but its answer names no pane"
  tab=$(herdr pane get "$pane" 2>/dev/null | jsonq 'd["result"]["pane"]["tab_id"]' 2>/dev/null) \
    || die "herdr moved pane $3 into a new $2 tab as $pane, but does not say which tab (herdr pane get $pane)"
  if [ "$2" = lanes ]; then
    LANE_REVIEW=$(sed -nE 's/^switches: .* LANE_REVIEW=([a-z]+).*/\1/p' "$1")
    PREFLIGHT=$(sed -nE 's/^switches: .* PREFLIGHT=([a-z]+).*/\1/p' "$1")
    column=$(reviewer_column "$(sed -nE 's/^lane A: .* checkout (.*), model .*/\1/p' "$1")" "$pane") \
      || die "herdr moved pane $3 into a new lanes tab $tab as $pane, but could not open its Reviewer column"
    column="   $column"
  fi
  line=$(printf '%-16s%s%s' "$2 tab:" "$tab" "$column")
  # Called in a $( ) with || die, so errexit is off here: checked by hand.
  printf '%s\n' "$line" >> "$1" \
    || die "herdr moved pane $3 into a new $2 tab $tab as $pane, but could not write $1; its line:  $line"
  echo "$pane"
}
