# The runner orchestrate drives (CONTEXT.md Runner; ADR 0005, amended:
# herdr or Orca). Sourced by common.sh.
#
# runner_detect prints herdr or orca, or fails with the refusal on stderr:
# herdr when the session runs in a herdr pane and herdr answers (even inside
# an Orca terminal), orca when ORCA_CLI_COMMAND is set and `orca status`
# answers. need_runner exports RUNNER from it and loads that runner's
# functions, or stops the script.
runner_detect() {
  if [ "${HERDR_ENV:-}" = 1 ] && herdr --version >/dev/null 2>&1; then echo herdr; return 0; fi
  if [ -n "${ORCA_CLI_COMMAND:-}" ]; then
    orca status --json >/dev/null 2>&1 && { echo orca; return 0; }
    echo "Orca is not reachable: this session runs in Orca (ORCA_CLI_COMMAND is set), but \`orca status\` fails. Start Orca, or check that its runtime answers, then run the skill again." >&2
    return 1
  fi
  local hint=" DRY_RUN=1 shows what this script would do."
  [ "${DRY_RUN:-0}" = 1 ] && hint=""
  echo "not inside herdr or Orca: the orchestrate skill needs herdr (https://herdr.dev), run from a herdr pane (HERDR_ENV=1), or Orca, run from an Orca terminal or chat. Outside both, use /tower:run, which works with any runner.$hint" >&2
  return 1
}
need_runner() {
  RUNNER=$(runner_detect) || exit 1; export RUNNER
  # shellcheck source=/dev/null  # runner-herdr.sh or runner-orca.sh
  . "$KIT/runner-$RUNNER.sh"
}

# The runner functions, herdr's until need_runner says otherwise (each
# runner-<runner>.sh documents them):
#   runner_agent_start NAME KIND PANE -- HARNESS_ARGS...
#   runner_agent_state NAME PANE   "<status> <ready>", gone or unreadable;
#                                  gone: herdr, the agent is not found; Orca, its terminal is closed
#   runner_agent_tail NAME PANE LINES
#   runner_name                    the runner's name, for a message
#   runner_ready_hint NAME         how a human sees NAME accept input
#   runner_send_text PANE TEXT
#   runner_send_keys PANE KEY...
# and the layout (CONTEXT.md Layout):
#   runner_self                    the orchestrator's pane or workspace, for the pane map
#   runner_workspace PANE          the workspace the run's tabs open in
#   runner_open_run_panes REPO CONSOLE_CMD [DEV_DIR DEV_CMD]   "<console> <shell> [<dev>]"
#   runner_open_lane_a WS REPO LABEL                          "<pane> <tab line after the label>"
#   runner_open_lane REPO BRANCH BASE WT LABEL                the lane's pane; makes the worktree
#   runner_place_lane MAP LABEL PANE                          the pane's id once placed
#   runner_open_reviewer_slots WS REPO LABEL                  "<tab> <r1> <r2>"
#   runner_pane_exists PANE        0 open, 1 gone, 2 the runner cannot say
#   runner_read_cmd, runner_message_cmd   the pane map's read a pane and message a pane lines
# shellcheck source=/dev/null  # runner-herdr.sh or runner-orca.sh
. "$KIT/runner-${RUNNER:-herdr}.sh"
