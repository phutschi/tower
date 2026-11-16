# The tabs of an orchestrate run and the grid inside each. Sourced after
# common.sh by bootstrap.sh and add-lane.sh. The lanes tab holds lanes of
# session role code or review (or every lane, without roles) and the Reviewer
# column; the research tab, lanes of any other role. Each opens with its first
# pane.
#
# A lane's pane map line ends its parenthesis with  tab <label> : the tab it
# is in. A line without one (a pane map written before the lanes tab) is a
# lane in the lanes tab. A tab's lanes are in the order of their lines, which
# is the order they were placed: add-lane appends a lane's line when it places
# the lane, and rewrites it in place after that.

lane_tab() {  # ROLE: the tab a lane of session role ROLE goes to: lanes for code,
  # review or none (roles off), research for any other
  case "$1" in
    code|review|"") echo lanes ;;
    *) echo research ;;
  esac
}

tab_line() {  # MAP LABEL: the tab id on MAP's "<LABEL> tab:" line, empty when absent
  sed -nE "s/^$2 tab: +([^ ]+).*/\\1/p" "$1" | head -1
}

grid_anchor() {  # MAP LABEL: "<pane> <right|down>" for the next lane in tab LABEL:
  # the second goes right of the first, the third under the first, the fourth
  # under the second. The first goes under R2 when the tab has only its
  # Reviewer column (add-reviewer opened it), else it has no anchor: nothing.
  local p
  # shellcheck disable=SC2207  # pane ids, one word each
  p=($(awk -v tab="$2" '/^lane [A-D]: / {
    t = "lanes"
    if (match($0, /, tab [a-z]+\)( starting)?$/)) { t = substr($0, RSTART + 6); sub(/\).*/, "", t) }
    if (t == tab) print $3
  }' "$1"))
  case ${#p[@]} in
    0) sed -nE "s/^$2 tab: .*[(, ]R2 ([^,)]+).*/\\1 down/p" "$1" | head -1 ;;
    1) echo "${p[0]} right" ;;
    2) echo "${p[0]} down" ;;
    3) echo "${p[1]} down" ;;
  esac
}

reviewer_column() {  # CWD PANE: when anything reviews (LANE_REVIEW or PREFLIGHT on),
  # a full-height column right of PANE, a third of its width, R1 over R2, opened
  # in CWD; prints "(R1 <pane>, R2 <pane>)", else "(no Reviewer column)"
  local r1 r2
  if [ "$LANE_REVIEW" = on ] || [ "$PREFLIGHT" = on ]; then
    r1=$(herdr pane split --pane "$2" --direction right --ratio 0.67 --cwd "$1" --no-focus | pane_id) || return 1
    r2=$(herdr pane split --pane "$r1" --direction down --ratio 0.5 --cwd "$1" --no-focus | pane_id) || return 1
    echo "(R1 $r1, R2 $r2)"
  else
    echo "(no Reviewer column)"
  fi
}

open_tab_with() {  # MAP LABEL PANE: moves PANE into a new tab LABEL in the orchestrator
  # pane's workspace, unfocused; writes "<LABEL> tab:" to MAP, for the lanes tab
  # with its Reviewer column (reviewer_column, in lane A's checkout); prints
  # the pane's new id. Dies saying what went wrong. The column follows the
  # run's LANE_REVIEW and PREFLIGHT, from MAP's switches: line.
  local orch ws moved pane tab column="" line LANE_REVIEW PREFLIGHT
  orch=$(sed -nE 's/^orchestrator: +([^ ]+).*/\1/p' "$1")
  ws=$(herdr pane get "$orch" 2>/dev/null | jsonq 'd["result"]["pane"]["workspace_id"]' 2>/dev/null) \
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
