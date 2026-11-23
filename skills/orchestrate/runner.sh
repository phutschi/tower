# The runner orchestrate drives (CONTEXT.md Runner; ADR 0005, amended:
# herdr or Orca). Sourced by common.sh.
#
# runner_detect prints herdr or orca, or fails with the refusal on stderr:
# herdr when the session runs in a herdr pane and herdr answers (even inside
# an Orca terminal), orca when ORCA_CLI_COMMAND is set and `orca status`
# answers. need_runner exports RUNNER from it, or stops the script.
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
need_runner() { RUNNER=$(runner_detect) || exit 1; export RUNNER; }
