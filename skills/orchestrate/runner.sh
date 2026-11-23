# The runner orchestrate drives (CONTEXT.md Runner; ADR 0005, amended:
# herdr or Orca). Sourced by common.sh.
#
# runner_detect prints herdr or orca, or fails with the refusal on stderr:
# herdr when the session runs in a herdr pane and herdr answers (even inside
# an Orca terminal), orca when ORCA_CLI_COMMAND is set and the CLI it names
# says, asked for its status, that its runtime is reachable. need_runner
# exports RUNNER from it and loads that runner's functions, or stops the
# script.
runner_detect() {
  if [ "${HERDR_ENV:-}" = 1 ] && herdr --version >/dev/null 2>&1; then echo herdr; return 0; fi
  if [ -n "${ORCA_CLI_COMMAND:-}" ]; then
    # Its JSON answer can succeed with the runtime down: reachable must be true.
    command -v python3 >/dev/null || { echo "missing dependency: python3" >&2; return 1; }
    if [ "$(command "$ORCA_CLI_COMMAND" status --json 2>/dev/null | jsonq 'd["result"]["runtime"]["reachable"] is True' 2>/dev/null)" = True ]; then echo orca; return 0; fi
    echo "Orca is not reachable: this session runs in Orca (ORCA_CLI_COMMAND is set), but \`$ORCA_CLI_COMMAND status\` does not say its runtime is reachable. Start Orca, or check that its runtime answers, then run the skill again." >&2
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

# The runner functions, loaded by need_runner alone (each runner-<runner>.sh
# documents them):
#   runner_agent_start NAME KIND PANE -- HARNESS_ARGS...   3: it failed with nothing sent
#   runner_agent_state NAME PANE   "<status> <ready>", gone or unreadable;
#                                  gone: herdr, the agent is not found (Orca never says it:
#                                  a stale handle may name a terminal still open)
#   runner_agent_tail NAME PANE LINES
#   runner_name                    the runner's name, for a message
#   runner_ready_hint NAME         how a human sees NAME accept input
#   runner_send_text PANE TEXT
#   runner_send_keys PANE KEY...
#   runner_send_message NAME PANE TEXT   TEXT as one prompt to NAME (send-brief.sh)
#   runner_names_agents            0 when the runner reaches an agent by its name (herdr)
# and the layout (CONTEXT.md Layout):
#   runner_self                    the orchestrator's pane or workspace, for the pane map
#   runner_workspace PANE          the workspace the run's tabs open in
#   runner_open_run_panes WS REPO CONSOLE_CMD [DEV_DIR DEV_CMD]
#                                  "<console> <shell> [<dev>]", then the pane map lines it adds;
#                                  failing (Orca), the panes it opened before (to close)
#   runner_open_lane_a WS REPO LABEL                          "<pane> <tab line after the label>"
#   runner_open_lane REPO BRANCH BASE WT LABEL                "<pane> [<checkout>]": makes the
#                                  worktree, at WT unless the runner names another checkout
#   runner_place_lane MAP LABEL PANE                          the pane's id once placed
#   runner_open_reviewer_slots WS REPO LABEL [R1 TAB]         "<tab(s)> <r1> <r2>"; R1 given,
#                                  only R2 opens; failing after R1 (Orca), "<tab> <r1>"
#   runner_end_agent PANE          after /exit: whatever else ends the agent in PANE; 0 when
#                                  that ended it for sure, 1 when the caller waits for gone
#   runner_reviewer_pane SLOT PANE REPO   the pane a fresh Reviewer in SLOT starts in (PANE
#                                  empty: the runner closed the last one)
#   runner_pane_exists PANE        0 open, 1 gone, 2 the runner cannot say, 3 its handle is
#                                  stale (Orca): it may be open under another
#   runner_pane_check              what runner_pane_exists asks, for a message
#   runner_read_cmd                the pane map's read a pane line
