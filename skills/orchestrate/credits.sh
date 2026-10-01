# Sourced: how much of a kind's quota is left, for the Reviewer's credit guard
# (ADR 0013). Expects `set -u`; provides
#
#   credits_left KIND   prints the % left in KIND's tightest window, an integer
#                       0-100, or nothing when it cannot be read; always exits 0.
#   CREDITS_TIMEOUT     seconds a probe gets, default 2; a probe still running
#                       then is killed, with everything it started, and prints
#                       nothing.
#   CREDITS_FAKES       under DRY_RUN=1, a dir holding a test's own `security`
#                       and `curl`: the probes run with it first on PATH. Without
#                       one, a DRY_RUN probes nothing (no keychain, no endpoint,
#                       no app-server) and credits_left prints nothing.
#
# Every probe reads an OAuth token from the macOS keychain and calls an
# endpoint no vendor documents for this use; any CLI update can break one. A
# failure of any kind (no keychain, no item, 401, timeout, a reply of another
# shape, an unknown kind) prints nothing, which the guard counts as enough.
# A token only ever travels through a pipe (curl reads its header lines from
# stdin): never argv, a file, stdout or stderr. `security` reads an item
# without a prompt only when its ACL lets /usr/bin/security in; otherwise
# macOS asks, the probe times out and prints nothing.
#
#   claude: the token in the keychain item "Claude Code-credentials"
#           (claudeAiOauth.accessToken; with CLAUDE_CONFIG_DIR set, the
#           account is another item's, and the probe prints nothing), then Anthropic's OAuth usage endpoint
#           (api.anthropic.com/api/oauth/usage, internal): the least of
#           100 - utilization over five_hour and seven_day.
#   codex:  no token: `codex app-server` over stdio JSON-RPC (initialize,
#           initialized, then account/rateLimits/read, experimental): the
#           least of 100 - usedPercent over rateLimits.primary and .secondary.
#   cursor: the token in the keychain item "cursor-access-token", then
#           Cursor's dashboard service (api2.cursor.sh,
#           aiserver.v1.DashboardService/GetCurrentPeriodUsage, internal):
#           100 - planUsage.totalPercentUsed.

CREDITS_TIMEOUT="${CREDITS_TIMEOUT:-2}"
_CREDITS_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/credits.sh"

credits_left() {
  local path=$PATH
  case "${1:-}" in
    claude|codex|cursor) ;;
    *) return 0 ;;
  esac
  if [ "${DRY_RUN:-0}" = 1 ]; then
    local t
    [ -n "${CREDITS_FAKES:-}" ] || return 0
    for t in security curl; do
      [ -f "$CREDITS_FAKES/$t" ] && [ -x "$CREDITS_FAKES/$t" ] || return 0
    done
    path="$(cd "$CREDITS_FAKES" && pwd):$PATH" || return 0
  fi
  PATH=$path python3 - "$CREDITS_TIMEOUT" "$_CREDITS_SH" "$1" <<'PY' 2>/dev/null || true
import os, re, signal, subprocess, sys
timeout, module, kind = float(sys.argv[1]), sys.argv[2], sys.argv[3]
p = subprocess.Popen(["bash", "-c", '. "$0"; _credits_"$1"', module, kind],
                     stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL, start_new_session=True)
# Everything the probe started is in its process group, which goes with it.
try:
    out, _ = p.communicate(timeout=timeout)
except subprocess.TimeoutExpired:
    sys.exit(0)
finally:
    try: os.killpg(p.pid, signal.SIGKILL)
    except ProcessLookupError: pass
out = out.decode().strip()
if re.fullmatch(r"\d{1,3}", out) and int(out) <= 100:
    print(int(out))
PY
}

# JSON on stdin; EXPR (python, over d) is the list of used percents. Prints
# 100 - the largest, floored and kept within 0-100; nothing for no number.
_credits_tightest() {
  python3 -c '
import json, math, sys
d = json.load(sys.stdin)
used = [float(u) for u in ('"$1"') if isinstance(u, (int, float)) and not isinstance(u, bool)]
if used: print(max(0, min(100, math.floor(100 - max(used)))))'
}

_credits_claude() {
  local creds tok
  [ -z "${CLAUDE_CONFIG_DIR:-}" ] || return 0
  creds=$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null) || return 0
  tok=$(printf '%s' "$creds" | python3 -c 'import json,sys; print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])' 2>/dev/null) || return 0
  printf 'Authorization: Bearer %s\nanthropic-beta: oauth-2025-04-20\n' "$tok" \
    | curl -sf -H @- https://api.anthropic.com/api/oauth/usage 2>/dev/null \
    | _credits_tightest '[(d.get(w) or {}).get("utilization") for w in ("five_hour", "seven_day")]'
}

_credits_codex() {
  python3 -c '
import json, subprocess, sys
p = subprocess.Popen(["codex", "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL, text=True)
def send(m): p.stdin.write(json.dumps(m) + "\n"); p.stdin.flush()
def reply(i):
    for line in p.stdout:
        try: m = json.loads(line)
        except ValueError: continue
        if m.get("id") == i: return m.get("result") or sys.exit(1)
    sys.exit(1)
send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "tower", "version": "0"}}})
reply(1)
send({"method": "initialized"})
send({"id": 2, "method": "account/rateLimits/read"})
print(json.dumps(reply(2).get("rateLimits") or {}))
p.kill()' 2>/dev/null \
    | _credits_tightest '[(d.get(w) or {}).get("usedPercent") for w in ("primary", "secondary")]'
}

_credits_cursor() {
  local tok
  tok=$(security find-generic-password -s cursor-access-token -w 2>/dev/null) || return 0
  printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$tok" \
    | curl -sf -H @- --data '{}' \
        https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage 2>/dev/null \
    | _credits_tightest '[(d.get("planUsage") or {}).get("totalPercentUsed")]'
}
