#!/usr/bin/env bash
# Record demo.gif: a scripted run of the acme repo inside herdr, with the
# orchestrator, two lanes and the tower console, all canned (no agent runs).
#
#   bun run build && demo/record.sh      from the repo root; needs vhs, herdr,
#                                        node, git and python3
#
# herdr runs fully isolated from any herdr you have open: env -i drops every
# HERDR_* variable of the caller, and HOME, HERDR_HOME, its config and both
# sockets live in a scratch dir. It refuses to record unless the isolated
# herdr client points at the demo's socket and no server runs there yet.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
[ -f "$ROOT/dist/cli.js" ] || { echo "demo: run  bun run build  first" >&2; exit 1; }
for c in vhs herdr node git python3; do command -v "$c" >/dev/null || { echo "demo: needs $c" >&2; exit 1; }; done
# Short, and resolved (/tmp is a link on macOS): a socket path has a length limit.
DEMO_DIR=$(cd "$(mktemp -d /tmp/tower-demo.XXXXXX)" && pwd -P)

demo_env() {
  env -i PATH="$(dirname "$(command -v herdr)"):$(dirname "$(command -v node)"):$(dirname "$(command -v python3)"):/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="$DEMO_DIR/home" TERM=xterm-256color LANG=en_US.UTF-8 BASH_SILENCE_DEPRECATION_WARNING=1 \
    HERDR_HOME="$DEMO_DIR/herdr" HERDR_CONFIG_PATH="$DEMO_DIR/herdr/config.toml" \
    HERDR_SOCKET_PATH="$DEMO_DIR/herdr/s.sock" HERDR_CLIENT_SOCKET_PATH="$DEMO_DIR/herdr/c.sock" \
    HERDR_SESSION=acme-demo DEMO_DIR="$DEMO_DIR" DEMO_ROOT="$ROOT" \
    XDG_STATE_HOME="$DEMO_DIR/state" XDG_CONFIG_HOME="$DEMO_DIR/config" \
    TOWER_RUN="$DEMO_DIR/run" "$@"
}
trap 'demo_env herdr server stop >/dev/null 2>&1 || true; rm -rf "$DEMO_DIR"' EXIT

mkdir -p "$DEMO_DIR/home" "$DEMO_DIR/herdr" "$DEMO_DIR/state" "$DEMO_DIR/config"
cat > "$DEMO_DIR/herdr/config.toml" <<'TOML'
onboarding = false

[terminal]
default_shell = "/bin/bash"
shell_mode = "non_login"

[update]
version_check = false
manifest_check = false
TOML
printf '%s\n' "PS1='rex@acme \$ '" > "$DEMO_DIR/home/.bashrc"


# Proof of isolation, before anything starts: the isolated client talks to its
# own socket, and no server is running there yet.
status=$(demo_env herdr status 2>&1)
printf '%s\n' "$status" | grep -qF "socket: $DEMO_DIR/herdr/s.sock" \
  || { echo "demo: the isolated herdr does not use its own socket; not recording" >&2; exit 1; }
printf '%s\n' "$status" | grep -qF 'status: not running' \
  || { echo "demo: a herdr server already answers on the demo socket; not recording" >&2; exit 1; }
echo "demo: herdr isolated in $DEMO_DIR"

# The acme repo and its run: six widget tasks, two lanes.
git init -q "$DEMO_DIR/acme"
git -C "$DEMO_DIR/acme" -c user.name=rex -c user.email=someone@example.com commit -q --allow-empty -m init
git -C "$DEMO_DIR/acme" checkout -qb feature/widgets
(cd "$DEMO_DIR/acme" && demo_env node "$ROOT/dist/cli.js" init --tasks "$ROOT/demo/tasks.tsv" --title Widgets \
  --lane A=1-3 --lane B=4-6 --model implementer=opus --model spec-reviewer=sonnet --model quality-reviewer=opus \
  --run "$DEMO_DIR/run" </dev/null >/dev/null)

(cd "$ROOT" && demo_env vhs demo.tape)
