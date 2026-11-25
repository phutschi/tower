# The tabs of an orchestrate run and the grid inside each. Sourced after
# common.sh by bootstrap.sh and add-lane.sh. The lanes tab holds lanes of
# session role code or review (or every lane, without roles) and the Reviewer
# column; the research tab, lanes of any other role. Each opens with its first
# pane. The herdr calls that open them are runner-herdr.sh's; the lane grid
# (grid_anchor) is herdr's alone.
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
    if (match($0, /, tab [a-z]+\)( starting| unsent)?$/)) { t = substr($0, RSTART + 6); sub(/\).*/, "", t) }
    if (t == tab) print $3
  }' "$1"))
  case ${#p[@]} in
    0) sed -nE "s/^$2 tab: .*[(, ]R2 ([^,)]+).*/\\1 down/p" "$1" | head -1 ;;
    1) echo "${p[0]} right" ;;
    2) echo "${p[0]} down" ;;
    3) echo "${p[1]} down" ;;
  esac
}
