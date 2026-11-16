# The tabs of an orchestrate run and the grid inside each. Sourced after
# common.sh by add-lane.sh.
#
# A lane's pane map line ends its parenthesis with  tab <label> : the tab it
# is in. A line without one (a pane map written before the lanes tab) is a
# lane in the lanes tab. A tab's lanes are in the order of their lines, which
# is the order they were placed: add-lane appends a lane's line when it places
# the lane, and rewrites it in place after that.

lane_tab() {  # ROLE: the tab a lane of session role ROLE goes to
  echo lanes
}

tab_line() {  # MAP LABEL: the tab id on MAP's "<LABEL> tab:" line, empty when absent
  sed -nE "s/^$2 tab: +([^ ]+).*/\\1/p" "$1" | head -1
}

grid_anchor() {  # MAP LABEL: "<pane> <right|down>" for the next lane in tab LABEL,
  # nothing when the tab has no lane: the second goes right of the first, the
  # third under the first, the fourth under the second.
  local p
  # shellcheck disable=SC2207  # pane ids, one word each
  p=($(awk -v tab="$2" '/^lane [A-D]: / {
    t = "lanes"
    if (match($0, /, tab [a-z]+\)( starting)?$/)) { t = substr($0, RSTART + 6); sub(/\).*/, "", t) }
    if (t == tab) print $3
  }' "$1"))
  case ${#p[@]} in
    1) echo "${p[0]} right" ;;
    2) echo "${p[0]} down" ;;
    3) echo "${p[1]} down" ;;
  esac
}
