# Sourced by bootstrap.sh and add-lane.sh: everything that depends on which
# agent runs a lane. EXECUTOR_KIND=claude (default) | codex, chosen per lane:
# the repo's .herdr-orchestrate sets the run's default, the environment of the
# bootstrap or add-lane call overrides it (so source detect-stack.sh first).
# EXECUTOR_MODEL overrides the kind's default model the same way.
#
#   claude: claude-opus-5-5[1m], started with --model.
#   codex:  gpt-6-astra, started with -m, no approval prompts (-a never), writes
#           limited to the worktree (-s workspace-write) with network allowed
#           for installs and fetches. Two dirs outside the worktree are added as
#           writable: the run dir (tower task|block|note append to it) and the
#           repo's common git dir (a lane worktree commits into it).
#
# Expects `set -u`; provides agent_name SUFFIX, start_agent NAME PANE and
# start_agent_with_trust_retry NAME PANE.

EXECUTOR_KIND="${EXECUTOR_KIND:-claude}"
case "$EXECUTOR_KIND" in
  claude) EXECUTOR_MODEL="${EXECUTOR_MODEL:-claude-opus-5-5[1m]}" ;;
  codex)  EXECUTOR_MODEL="${EXECUTOR_MODEL:-gpt-6-astra}" ;;
  *) echo "EXECUTOR_KIND must be claude or codex (got '$EXECUTOR_KIND')" >&2; exit 2 ;;
esac

# The codex lane follows the same TDD skill as the claude lane. Codex reads user
# skills from ~/.codex/skills; the mattpocock tdd skill ships an agents/openai.yaml
# so a symlink is all it needs (plus the two skills it refers to).
if [ "$EXECUTOR_KIND" = codex ] && [ ! -e "$HOME/.codex/skills/tdd" ]; then
  cat >&2 <<'MSG'
info: ~/.codex/skills/tdd is missing — the codex lane cannot load the tdd skill the
      brief asks for. To add it (and the two skills it references):
        S=~/.claude/plugins/marketplaces/mattpocock/skills/engineering
        mkdir -p ~/.codex/skills
        ln -s $S/tdd ~/.codex/skills/tdd
        ln -s $S/codebase-design ~/.codex/skills/codebase-design
        ln -s $S/code-review ~/.codex/skills/code-review
MSG
fi

# An agent name herdr accepts: a lowercase letter first, then lowercase letters,
# digits, '-' or '_', at most 32 characters. Built from the repo's name (the main
# checkout's, so a lane or a worktree checkout does not lengthen it) plus the
# suffix; the repo part is truncated to keep the suffix whole.
agent_name() {
  local suffix="$1" repo
  repo="$(basename "$(git rev-parse --path-format=absolute --git-common-dir | sed 's#/\.git$##')")"
  repo="$(printf '%s' "$repo" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9_-]/-/g; s/^[^a-z]*//')"
  [ -n "$repo" ] || repo=repo
  repo="${repo:0:$(( 32 - ${#suffix} ))}"
  printf '%s%s' "${repo%-}" "$suffix"
}

start_agent() {
  local name="$1" pane="$2"
  case "$EXECUTOR_KIND" in
    claude) herdr agent start "$name" --kind claude --pane "$pane" -- --model "$EXECUTOR_MODEL" ;;
    codex)
      local extra=()
      [ -n "${RUN_DIR:-}" ] && extra+=(--add-dir "$RUN_DIR")
      extra+=(--add-dir "$(git rev-parse --path-format=absolute --git-common-dir)")
      herdr agent start "$name" --kind codex --pane "$pane" -- -m "$EXECUTOR_MODEL" \
        -a never -s workspace-write -c sandbox_workspace_write.network_access=true "${extra[@]}" ;;
  esac
}

# A fresh checkout shows the agent's trust prompt, which herdr reports as
# "blocked during startup". Claude's prompt wants Down Enter ("Yes, I trust this
# folder" is the second option); codex's wants Enter ("Yes, continue" is the
# first). Answer it and try once more.
start_agent_with_trust_retry() {
  local name="$1" pane="$2" out
  if ! out=$(start_agent "$name" "$pane" 2>&1); then
    if echo "$out" | grep -q "blocked during startup"; then
      case "$EXECUTOR_KIND" in
        claude) herdr pane send-keys "$pane" Down Enter >/dev/null ;;
        codex)  herdr pane send-keys "$pane" Enter >/dev/null ;;
      esac
      sleep 3
      herdr agent get "$name" >/dev/null 2>&1 || start_agent "$name" "$pane" >/dev/null
    else
      echo "$out" >&2; return 1
    fi
  fi
}
