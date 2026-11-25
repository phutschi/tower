#!/usr/bin/env bash
# Sends a brief or a fix prompt to a lane or Reviewer agent through the runner.
#
#   send-brief.sh <run-dir> <agent> <brief-file>
#
# <brief-file> is a file directly in <run-dir>, given by its name or by its
# path. Its text is the prompt as it is, but for trailing newlines, which are
# trimmed; a brief holding a NUL byte is refused, since no prompt carries one.
#
# The agent's pane is its one lane or Reviewer line in <run-dir>/panes.txt,
# bound to the kit's launch record (common.sh bound_pane); nothing else in
# the map is read, and nothing in it is run: a lane can write the run dir. The pane must be open; the runner then
# sends the file's text as one prompt (runner_send_message), Orca only to an
# agent it lists as ready. Otherwise nothing is sent: exit 1, saying why; a
# send with no receipt fails too, saying to look at the terminal before
# sending again.
#
# Never run this for real to see what it does; use DRY_RUN=1, which answers
# every herdr and orca call from tests/stub and sends nothing.
set -euo pipefail
KIT="$(cd "$(dirname "$0")" && pwd)"
. "$KIT/common.sh"
need_runner; need python3
[ $# -eq 3 ] || die 'usage: send-brief.sh <run-dir> <agent> <brief-file>'
RUN_DIR="$1"; NAME="$2"; BRIEF="$3"; MAP="$RUN_DIR/panes.txt"
[ -f "$MAP" ] || die "send-brief: no pane map at $MAP"
# Read once, here: the brief lives in the run dir, which a lane can write. So
# only a file directly in it counts, opened by its name relative to the run
# dir itself (a directory or link on the way could lead anywhere); a link or
# anything but a regular file is refused, and so is a failed or empty read.
case "$BRIEF" in
  */*) d=$(cd -- "$(dirname -- "$BRIEF")" 2>/dev/null && pwd -P) && [ "$d" = "$(cd -- "$RUN_DIR" && pwd -P)" ] \
         || die "send-brief: a brief must be a file directly in $RUN_DIR: nothing sent" ;;
esac
BASE=$(basename -- "$BRIEF")
case "$BASE" in .|..) die "send-brief: a brief must be a file directly in $RUN_DIR: nothing sent" ;; esac
[ -e "$RUN_DIR/$BASE" ] || [ -L "$RUN_DIR/$BASE" ] || die "send-brief: no brief, or an empty one, at $BRIEF"
rc=0; TEXT=$(python3 -I -c 'import os, stat, sys
dfd = os.open(sys.argv[1], os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
fd = os.open(sys.argv[2], os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_NONBLOCK", 0), dir_fd=dfd)
if not stat.S_ISREG(os.fstat(fd).st_mode): sys.exit(3)
with os.fdopen(fd, "rb") as f: b = f.read()
if b"\0" in b: sys.exit(4)
b.decode(); sys.stdout.buffer.write(b)' "$RUN_DIR" "$BASE" 2>/dev/null) || rc=$?
case $rc in
  0) ;;
  4) die "send-brief: $BRIEF holds a NUL byte, which a prompt cannot carry: nothing sent" ;;
  *) die "send-brief: $BRIEF is not a regular UTF-8 text file, or cannot be read: nothing sent" ;;
esac
[ -n "$TEXT" ] || die "send-brief: no brief, or an empty one, at $BRIEF"
PANE=$(bound_pane "$RUN_DIR" "$NAME" 2>&1) || die "send-brief: $PANE: nothing sent"
rc=0; err=$(runner_pane_exists "$PANE" 2>&1) || rc=$?
case $rc in
  0) ;;
  1) die "send-brief: $NAME's pane $PANE is gone ($(runner_pane_check)): nothing sent" ;;
  3) stale_handle "$NAME" "$PANE" "its line" "" "$NAME"; exit 1 ;;
  *) die "send-brief: $(runner_name) cannot say whether $NAME's pane $PANE is open; nothing sent, send again once it answers ($(runner_name): ${err:-no output})" ;;
esac
rc=0; err=$(runner_send_message "$NAME" "$PANE" "$TEXT" 2>&1) || rc=$?
case $rc in
  0) ;;
  4) die "send-brief: $(runner_name) cannot say whether the brief reached $NAME in $PANE (no receipt): look at that terminal before you send anything again${err:+ ($err)}" ;;
  *) die "send-brief: $(runner_name) did not take the brief for $NAME in $PANE; nothing was sent, send again${err:+ ($err)}" ;;
esac
echo "brief $BRIEF sent to $NAME in $PANE"
