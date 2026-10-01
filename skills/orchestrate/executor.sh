# Sourced by bootstrap.sh and add-lane.sh: everything that depends on which
# agent runs a lane. EXECUTOR_KIND=claude (default) | codex | cursor, chosen per lane:
# the repo's .orchestrate sets the run's default, the environment of the
# bootstrap or add-lane call overrides it (so source detect-stack.sh first).
# EXECUTOR_MODEL overrides the kind's default model the same way. Every
# default model is data: EXECUTOR_MODEL_<KIND> and the Reviewer's keys in
# model-defaults (MODEL_DEFAULTS_FILE, default $KIT/model-defaults), which the
# same key in the call's environment, the repo contract or the user contract
# replaces, in that order (detect-stack.sh loads the two contracts; ADR 0012).
#
#   claude: started with --model.
#   cursor: cursor-agent, started with --model, trusted (--trust), without
#           approvals (--force) or self-update (--disable-auto-update), no
#           sandbox flag; the run dir and the common git dir are added dirs.
#   codex:  started with -m, no approval prompts (-a never), writes
#           limited to the worktree (-s workspace-write) with network allowed
#           for installs and fetches. Outside the worktree, the run dir is
#           writable (tower task|block|note append to it), and what a commit
#           needs in the repo's common git dir. A lane in a worktree (lanes
#           B-D) gets only objects, refs, logs, packed-refs(.lock, .new) and
#           its own worktrees/<lane> (sandbox_workspace_write.writable_roots,
#           which replaces any the user's codex config sets): hooks and config
#           stay read-only. AGENT_CHECKOUT (default: the current directory) is
#           the agent's checkout, which decides this; add-lane.sh and
#           bootstrap.sh set it. A lane in the main checkout (lane A, and
#           a Reviewer, which works there) keeps its index, HEAD and rebase
#           and stash state in the common dir itself, so it gets the whole
#           common dir: its sandbox does not contain .git/hooks or .git/config,
#           and a hook or core.fsmonitor it writes runs outside the sandbox on
#           the orchestrator's next git command. Its
#           startup update check is off (-c check_for_update_on_startup=false):
#           a codex that updates itself on start exits before its brief.
#           AGENT_TMP=<dir> (add-reviewer.sh sets it for a codex Reviewer)
#           gives the commands it runs that dir as TMPDIR, BUN_TMPDIR,
#           BUN_INSTALL_CACHE_DIR and npm_config_cache, through codex's
#           shell_environment_policy: the defaults are outside its sandbox.
#           AGENT_LOOK=<dir> (add-reviewer.sh sets it for a codex Reviewer,
#           and only then; bootstrap.sh and add-lane.sh clear it) is one more
#           writable dir: where preflight's look.sh makes its temp worktree,
#           outside everything a lane may write; with it, the agent's
#           commands get TOWER_RUN=<RUN_DIR>, which look.sh checks against.
#
# Expects `set -u`; provides agent_name SUFFIX, start_agent NAME PANE,
# start_agent_with_trust_retry NAME PANE (it returns once the agent accepts
# input; one that exits right after its start is started once more, then the
# start fails), kind_installed KIND and
# reviewer_for LANE_KIND [LANE_MODEL] (the Reviewer's kind and model; see below).
# START_TRIES (default 10) is how often an agent start is tried, a second apart,
# while herdr answers agent_pane_busy (a new pane's shell is not ready yet).
# START_SETTLE_SECONDS (default 3) is how long a started agent is given before
# it is read again; READY_WAIT_SECONDS (default 30) how many reads, about a
# second apart, it then gets to accept input.

MODEL_DEFAULTS_FILE="${MODEL_DEFAULTS_FILE:-$KIT/model-defaults}"

# KEY's default: its value in this shell (the call's environment, the repo
# contract or the user contract) when set, else the model-defaults file's
# (ADR 0012). A key that none of them sets fails, saying so: a caller runs it
# as  v=$(model_default KEY) || exit 1 .
model_default() {
  local key="$1"
  if [ -n "${!key:-}" ]; then printf '%s\n' "${!key}"; return; fi
  # shellcheck source=/dev/null  # the kit's data file, or a test's copy
  ( unset "$key"; . "$MODEL_DEFAULTS_FILE" 2>/dev/null && [ -n "${!key:-}" ] && printf '%s\n' "${!key}" ) \
    || { echo "model-defaults: no $key in $MODEL_DEFAULTS_FILE" >&2; return 1; }
}
# VAR's default for KIND: VAR_<KIND upper>, e.g. kind_default EXECUTOR_MODEL codex.
kind_default() { model_default "$1_$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"; }

EXECUTOR_KIND="${EXECUTOR_KIND:-claude}"
kind_known "$EXECUTOR_KIND" || { echo "EXECUTOR_KIND must be $(kinds_say) (got '$EXECUTOR_KIND')" >&2; exit 2; }
[ -n "${EXECUTOR_MODEL:-}" ] || EXECUTOR_MODEL=$(kind_default EXECUTOR_MODEL "$EXECUTOR_KIND") || exit 1

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
# A cursor lane reads skills from ~/.agents/skills, ~/.claude/skills and
# ~/.codex/skills: the tdd skill in any of them will do.
if [ "$EXECUTOR_KIND" = cursor ] && [ ! -e "$HOME/.agents/skills/tdd" ] \
  && [ ! -e "$HOME/.claude/skills/tdd" ] && [ ! -e "$HOME/.codex/skills/tdd" ]; then
  cat >&2 <<'MSG'
info: no tdd skill in ~/.agents/skills, ~/.claude/skills or ~/.codex/skills — the cursor
      lane cannot load the tdd skill the brief asks for. To add it (and the two skills it
      references):
        S=~/.claude/plugins/marketplaces/mattpocock/skills/engineering
        mkdir -p ~/.agents/skills
        ln -s $S/tdd ~/.agents/skills/tdd
        ln -s $S/codebase-design ~/.agents/skills/codebase-design
        ln -s $S/code-review ~/.agents/skills/code-review
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

# The agent's checkout (AGENT_CHECKOUT, default: here). Under DRY_RUN the
# stub's worktree create makes no worktree, so a missing one is here.
agent_checkout() {
  local co="${AGENT_CHECKOUT:-.}"
  [ -d "$co" ] || [ "${DRY_RUN:-0}" != 1 ] || co=.
  printf '%s' "$co"
}

start_agent() {
  local name="$1" pane="$2"
  case "$EXECUTOR_KIND" in
    claude) herdr agent start "$name" --kind claude --pane "$pane" -- --model "$EXECUTOR_MODEL" ;;
    cursor)
      # --trust is the only guard against cursor's trust box: herdr reports
      # that box as idle and ready, so a brief would be typed into it, and
      # it is never answered with keys. --force runs commands without
      # approvals; no --sandbox, so the user's own sandbox setting applies.
      # --disable-auto-update keeps the harness version still under a
      # running lane; it is undocumented (not in --help as of 2026.09.28).
      # The run dir (tower's record) and the common git dir (commits from a
      # lane worktree) are added dirs.
      local common
      common=$(git -C "$(agent_checkout)" rev-parse --path-format=absolute --git-common-dir) || return 1
      herdr agent start "$name" --kind cursor --pane "$pane" -- --model "$EXECUTOR_MODEL" \
        --trust --force --disable-auto-update ${RUN_DIR:+--add-dir "$RUN_DIR"} --add-dir "$common" ;;
    codex)
      local extra=() common gitdir roots="" p co
      co=$(agent_checkout)
      common=$(git -C "$co" rev-parse --path-format=absolute --git-common-dir) || return 1
      gitdir=$(git -C "$co" rev-parse --path-format=absolute --git-dir) || return 1
      [ -n "${RUN_DIR:-}" ] && extra+=(--add-dir "$RUN_DIR")
      if [ "$gitdir" = "$common" ]; then
        extra+=(--add-dir "$common")
        [ -z "${AGENT_LOOK:-}" ] || extra+=(--add-dir "$AGENT_LOOK")
      else
        # These roots replace any in the user's codex config, and the run dir
        # is listed here too in case they replace --add-dir's.
        for p in ${RUN_DIR:+"$RUN_DIR"} "$common/objects" "$common/refs" "$common/logs" \
          "$common/packed-refs" "$common/packed-refs.lock" "$common/packed-refs.new" "$gitdir" \
          ${AGENT_LOOK:+"$AGENT_LOOK"}; do
          roots+="${roots:+,}$(toml_string "$p")"
        done
        extra+=(-c "sandbox_workspace_write.writable_roots=[$roots]")
      fi
      # A Reviewer's look.sh refuses a worktree dir under the run dir: it
      # needs to know it.
      if [ -n "${AGENT_LOOK:-}" ] && [ -n "${RUN_DIR:-}" ]; then
        extra+=(-c "shell_environment_policy.set.TOWER_RUN=$(toml_string "$RUN_DIR")")
      fi
      if [ -n "${AGENT_TMP:-}" ]; then
        local v q; q=$(toml_string "$AGENT_TMP")
        for v in TMPDIR BUN_TMPDIR BUN_INSTALL_CACHE_DIR npm_config_cache; do
          extra+=(-c "shell_environment_policy.set.$v=$q")
        done
      fi
      herdr agent start "$name" --kind codex --pane "$pane" -- -m "$EXECUTOR_MODEL" \
        -a never -s workspace-write -c sandbox_workspace_write.network_access=true \
        -c check_for_update_on_startup=false "${extra[@]}" ;;
  esac
}

# S as a TOML basic string, for a codex -c value.
toml_string() { local s=${1//\\/\\\\}; printf '"%s"' "${s//\"/\\\"}"; }

# A new pane's shell may not be ready yet when the agent starts: herdr answers
# agent_pane_busy. Try again once a second, START_TRIES times in all (default 10).
# A fresh checkout shows the agent's trust prompt, which herdr reports as
# "blocked during startup". Claude's prompt wants Down Enter ("Yes, I trust this
# folder" is the second option); codex's wants Enter ("Yes, continue" is the
# first). Answer it, and try once more if herdr then says the agent is gone.
# cursor's is never answered: it starts with --trust, and one still blocked
# fails the start, saying to check the pane.
# It returns 1, saying why, when the answer cannot be sent or the agent is
# then neither working nor idle (blocked, herdr's unknown, anything else).
# Once started, the agent is given START_SETTLE_SECONDS, then read about once
# a second (READY_WAIT_SECONDS checks, default 30) until it accepts input:
# idle or working, and herdr's interactive_ready (an answer without that field
# counts as ready: an older herdr). Only then is it ready. One that exited
# (codex updating itself, say) is started once more, and an exit after that
# fails the start, saying so; so does one that never accepts input, which is
# left running in its pane.
start_agent_with_trust_retry() {
  local name="$1" pane="$2" rc
  start_answering_trust "$name" "$pane" || return 1
  rc=0; until_ready "$name" "$pane" || rc=$?
  case $rc in
    0) return 0 ;;
    2) return 1 ;;
  esac
  echo "agent start: $name exited right after its start in pane $pane; starting it once more" >&2
  start_answering_trust "$name" "$pane" || return 1
  rc=0; until_ready "$name" "$pane" || rc=$?
  case $rc in
    0) return 0 ;;
    2) return 1 ;;
  esac
  echo "agent start: $name exited again after it was started once more in pane $pane; read the pane for why, then start it again" >&2
  return 1
}

# 0 once NAME accepts input; 1 when herdr says it is gone (agent_not_found);
# 2, saying so, when READY_WAIT_SECONDS checks passed without either.
until_ready() {
  local name="$1" pane="$2" state checks=0
  [ "${DRY_RUN:-0}" = 1 ] || sleep "${START_SETTLE_SECONDS:-3}"
  while :; do
    state=$(ready_of "$name"); checks=$((checks+1))
    case "$state" in
      ready) return 0 ;;
      gone)  return 1 ;;
    esac
    [ "$checks" -lt "${READY_WAIT_SECONDS:-30}" ] || break
    [ "${DRY_RUN:-0}" = 1 ] || sleep 1
  done
  if [ "$state" = unreadable ]; then
    echo "agent start: herdr cannot say whether $name runs in $pane after $checks checks" >&2
  else
    echo "agent start: $name does not accept input in pane $pane after $checks checks ($state); it is left running in $pane: brief it once  herdr agent get $name  shows interactive_ready true, or end it and start it again" >&2
  fi
  return 2
}

# NAME's readiness: ready (idle or working, and interactive_ready), gone,
# unreadable (common.sh agent_of), or its state when it does not accept input
# yet ("idle, not ready for input" when herdr says idle but not ready).
ready_of() {
  local a; a=$(agent_of "$1")
  case "$a" in
    "idle True"|"working True")   echo ready ;;
    "idle False"|"working False") echo "${a%% *}, not ready for input" ;;
    *)                            echo "${a%% *}" ;;
  esac
}

start_answering_trust() {
  local name="$1" pane="$2" out tries=1
  until out=$(start_agent "$name" "$pane" 2>&1); do
    if echo "$out" | grep -q agent_pane_busy && [ "$tries" -lt "${START_TRIES:-10}" ]; then
      tries=$((tries+1))
      [ "${DRY_RUN:-0}" = 1 ] || sleep 1
    elif echo "$out" | grep -q "blocked during startup" && [ "$EXECUTOR_KIND" = cursor ]; then
      # cursor starts with --trust, and its box is never answered with keys
      # (start_agent). herdr usually reports that box as idle and ready;
      # this covers a herdr that reports it as blocked.
      echo "agent start: $name is blocked during startup in pane $pane although it started with --trust; check the pane" >&2
      return 1
    elif echo "$out" | grep -q "blocked during startup"; then
      # Every failure returns 1 itself: callers run this under || too, where
      # errexit is off.
      local keys=(Enter); [ "$EXECUTOR_KIND" = codex ] || keys=(Down Enter)
      herdr pane send-keys "$pane" "${keys[@]}" >/dev/null || {
        echo "agent start: could not answer $name's trust prompt in pane $pane (herdr pane send-keys failed); answer it there, and the agent runs" >&2; return 1; }
      [ "${DRY_RUN:-0}" = 1 ] || sleep 3
      # Started again only when herdr says the agent is not there (common.sh
      # state_of): a failing herdr call must not put a second agent beside it.
      # Only working or idle is an agent running; any other state fails.
      local state; state=$(state_of "$name")
      case "$state" in
        working|idle) return 0 ;;
        gone) start_agent "$name" "$pane" >/dev/null || {
          echo "agent start: $name did not start again in pane $pane after its trust prompt; check it there" >&2; return 1; } ;;
        unreadable) echo "agent start: herdr cannot say whether $name started after its trust prompt; check pane $pane" >&2; return 1 ;;
        *) echo "agent start: $name is still $state in pane $pane after its trust prompt was answered; answer it there, and the agent runs" >&2; return 1 ;;
      esac
      return 0
    else
      echo "$out" >&2
      if echo "$out" | grep -q agent_pane_busy; then
        echo "agent start: pane $pane is still not a ready shell after $tries tries; check it, or raise START_TRIES" >&2
      fi
      return 1
    fi
  done
}

# Is KIND (one of KINDS) installed and runnable? --version answers in well
# under a second; keep the probe that cheap (macOS has no timeout(1)). cursor's
# CLI is cursor-agent (a plain cursor may be the editor).
kind_installed() {
  local c=$1; [ "$c" != cursor ] || c=cursor-agent
  command -v "$c" >/dev/null && "$c" --version </dev/null >/dev/null 2>&1
}

# The kinds that may review a lane of LANE_KIND, in order, one per line:
# never the lane's own kind, and never cursor unasked for a claude or codex lane.
reviewer_candidates() {
  case "$1" in
    claude) echo codex ;;
    codex)  echo claude ;;
    cursor) printf '%s\n' claude codex ;;
  esac
}

# WORD... as prose: "a", "a and b", "a, b and c".
and_list() {
  local out="" i=1
  while [ $# -gt 0 ]; do
    if [ "$i" -eq 1 ]; then out=$1
    elif [ $# -eq 1 ]; then out="$out and $1"
    else out="$out, $1"; fi
    i=$((i+1)); shift
  done
  printf '%s' "$out"
}

# "is" for a count of 1, else "are".
is_are() { [ "$1" -eq 1 ] && echo is || echo are; }

# Who reviews a lane of LANE_KIND [on LANE_MODEL] (ADR 0010). Prints one line:
#   <kind>\t<model>\t<fallback note, or empty>
# The first installed of reviewer_candidates, on REVIEWER_MODEL_<its kind>.
# Otherwise the lane's own kind, with a fallback note naming the candidates
# passed over: claude on REVIEWER_MODEL_CLAUDE_SELF, cursor on
# REVIEWER_MODEL_CURSOR, codex on the lane's model (a fresh agent; LANE_MODEL
# when given, which add-reviewer.sh reads from the pane map, else
# EXECUTOR_MODEL when EXECUTOR_KIND is codex, else EXECUTOR_MODEL_CODEX).
# Every default is kind_default's (model-defaults). REVIEWER_KIND=claude|codex|cursor
# forces the kind (refused when not installed); REVIEWER_MODEL replaces the
# model the rules picked.
# With REVIEWER_BY_CREDITS=on (ADR 0013; never with a forced REVIEWER_KIND),
# credits.sh probes each installed candidate: one with less than
# REVIEWER_CREDITS_MIN % left is skipped, with the note
# "reviewer: skipped <kind>, <n>% credits left"; unreadable credits count as
# enough, with the note "reviewer: <kind> credits unreadable, counted as
# enough". Every candidate absent or skipped, the lane's own kind reviews;
# with that not installed, the first candidate skipped reviews after all (the
# first in order, deliberately not the one with the most credits left).
# Several notes are "; "-separated: the credit guard's (skips and unreadable
# candidates) first, in candidate order, then a fallback.
reviewer_for() {
  local lane="$1" lane_model="${2:-}" c kind="" model note="" why="" guard_notes="" left min=""
  local absent=() low=()
  kind_known "$lane" || die "lane kind must be $(kinds_say) (got '$lane')"
  case "${REVIEWER_KIND:-other}" in
    other)
      if [ "${REVIEWER_BY_CREDITS:-off}" = on ]; then
        . "$KIT/credits.sh"
        min=${REVIEWER_CREDITS_MIN:-}
        [ -n "$min" ] || min=$(model_default REVIEWER_CREDITS_MIN) || exit 1
        credits_min_ok "$min" || credits_min_refused "$min"
      fi
      for c in $(reviewer_candidates "$lane"); do
        if ! kind_installed "$c"; then absent+=("$c"); continue; fi
        if [ -n "$min" ]; then
          left=$(credits_left "$c")
          if [ -z "$left" ]; then
            guard_notes="${guard_notes}reviewer: $c credits unreadable, counted as enough; "
          elif [ "$left" -lt "$min" ]; then
            low+=("$c"); guard_notes="${guard_notes}reviewer: skipped $c, $left% credits left; "; continue
          fi
        fi
        kind=$c; break
      done
      if [ -n "$kind" ]; then note=${guard_notes%??}  # less the last "; "
      elif kind_installed "$lane"; then
        kind=$lane
        [ "${#absent[@]}" -eq 0 ] || why="$(and_list "${absent[@]}") $(is_are "${#absent[@]}") not installed"
        [ "${#low[@]}" -eq 0 ] || why="${why:+$why and }$(and_list "${low[@]}") $(is_are "${#low[@]}") low on credits"
        case "$lane" in
          claude) note="${guard_notes}fallback: $why, so claude reviews claude" ;;
          *)      note="${guard_notes}fallback: $why, so a fresh $lane agent reviews $lane" ;;
        esac
      elif [ "${#low[@]}" -gt 0 ]; then
        # Credits steer, never block: with the lane's own kind not there, the
        # first candidate skipped for them reviews after all.
        kind=${low[0]}
        note="${guard_notes}fallback: $lane is not installed, so $kind reviews despite its credits"
      else
        note="no Reviewer for a $lane lane: $(and_list "${absent[@]}" "$lane") are not installed"
        [ "$lane" = cursor ] || note="$note (cursor reviews a $lane lane only with REVIEWER_KIND=cursor)"
        die "$note"
      fi ;;
    *)
      kind_known "$REVIEWER_KIND" || die "REVIEWER_KIND must be other, $(kinds_say) (got '$REVIEWER_KIND')"
      kind=$REVIEWER_KIND
      kind_installed "$kind" || die "REVIEWER_KIND=$kind, but $kind is not installed" ;;
  esac
  case "$kind:$lane" in
    claude:claude) model=$(model_default REVIEWER_MODEL_CLAUDE_SELF) || exit 1 ;;
    codex:codex)
      if [ -n "$lane_model" ]; then model=$lane_model
      elif [ "$EXECUTOR_KIND" = codex ]; then model=$EXECUTOR_MODEL
      else model=$(kind_default EXECUTOR_MODEL "$lane") || exit 1; fi ;;
    *) model=$(kind_default REVIEWER_MODEL "$kind") || exit 1 ;;
  esac
  model="${REVIEWER_MODEL:-$model}"
  printf '%s\t%s\t%s\n' "$kind" "$model" "$note"
}
