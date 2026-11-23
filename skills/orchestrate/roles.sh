# Sourced by bootstrap.sh, add-lane.sh, add-reviewer.sh and start-run.sh after common.sh:
# session roles (CONTEXT.md Session role). A Claude launcher may start every
# claude session with a role (its models, MCP servers and permissions) and a
# topic it names the session after:  claude --role <role> --topic <topic> .
# Codex and cursor sessions take neither.
#
# The launcher is there when the orchestrator's session says which role it
# runs in (CLAUDE_ROUTER_ROLE), or when claude lists --role in its --help.
# Without it (neither), a run is as it was before roles: no check, no flags,
# and one tower note saying so (bootstrap.sh). With it, orchestration runs
# only in an orchestrator session (CLAUDE_ROUTER_ROLE=orchestrator):
# bootstrap.sh refuses any other before it creates anything.
#
# With the launcher, every claude session starts with --role and --topic:
#   a lane:     the role its tasks name (a plan task's  Role: <role>  line),
#               code when none does; tasks that name different roles in one
#               lane are refused (lane_role). Its topic is the lane's letter
#               and its first task's title as a slug: b-shipto-fix, or a
#               alone for a lane with no task yet.
#   a Reviewer: review (lane reviews and preflight slots alike), topic its
#               slot: r1 or r2.
# bootstrap.sh writes the plan's roles to <run-dir>/roles.tsv (id<TAB>role,
# one line per task that names one) and the pane map's  roles:  line (on, or
# off and why), which add-lane.sh and add-reviewer.sh read for the whole run.
#
# Provides claude_launcher, roles_gate, plan_roles PLAN, lane_role SPEC ROLES_TEXT, roles_on MAP,
# topic_slug TITLE, lane_topic LANE TITLE, lane_first_title LANE and
# tasks_first_title IDS.

# 0 when a Claude launcher is there (CLAUDE_ROUTER_ROLE is set, or claude
# lists --role in its --help).
claude_launcher() {
  [ -n "${CLAUDE_ROUTER_ROLE:-}" ] \
    || claude --help </dev/null 2>/dev/null | grep -qE -- '(^|[^a-z-])--role([^a-z-]|$)'
}

# ROLES=on|off and ROLES_WHY for the off case; dies, saying how to start an
# orchestrator session, when the launcher is there and this session is not one.
roles_gate() {
  local how='start one with  claude --role orchestrator  and run /tower:orchestrate there'
  if [ -n "${CLAUDE_ROUTER_ROLE:-}" ]; then
    [ "$CLAUDE_ROUTER_ROLE" = orchestrator ] \
      || die "orchestrate runs only in an orchestrator session, and this one is $CLAUDE_ROUTER_ROLE (CLAUDE_ROUTER_ROLE): $how"
    ROLES=on; ROLES_WHY=""
  elif claude_launcher; then
    die "orchestrate runs only in an orchestrator session: claude takes --role, but CLAUDE_ROUTER_ROLE is not set here; $how"
  else
    ROLES=off; ROLES_WHY="no Claude launcher: CLAUDE_ROUTER_ROLE is not set and claude takes no --role"
  fi
}

# The plan's session roles: one  <id><TAB><role>  line per task that names
# one. A task's role is a  Role: <role>  line in its section (between its
# ### Task heading and the next heading of level 1 to 3, outside fenced code;
# bold as  **Role:** data  too). A role is lowercase letters, digits and -,
# starting with a letter. Dies, naming the task, on a bad role or a task with
# two Role lines.
plan_roles() {
  python3 - "$1" <<'PY' || exit 1
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
if text.startswith("---\n"):
    end = text.find("\n---", 4)
    if end != -1:
        text = text[end + 4:]
heading = re.compile(r"^###\s+Task\s+([A-Za-z0-9][A-Za-z0-9._-]*)\s*:\s*(.+?)\s*$")
other = re.compile(r"^#{1,3}\s")
role_line = re.compile(r"^\s*(?:[-*]\s+)?\*{0,2}Role\*{0,2}\s*:\s*\*{0,2}\s*(.*?)\s*$")
role_name = re.compile(r"^[a-z][a-z0-9-]*$")
task, roles, fenced = None, {}, False
for line in text.split("\n"):
    if re.match(r"^\s*```", line):
        fenced = not fenced
        continue
    if fenced:
        continue
    m = heading.match(line)
    if m:
        task = m.group(1)
        continue
    if other.match(line):
        task = None
        continue
    r = role_line.match(line) if task else None
    if not r:
        continue
    role = r.group(1).strip("`* ")
    if not role_name.match(role):
        sys.exit(f"plan: task {task}'s Role '{role}' is not a role name (lowercase letters, digits and -, a letter first)")
    if task in roles:
        sys.exit(f"plan: task {task} names a Role twice ({roles[task]}, {role}); give it one")
    roles[task] = role
for t, r in roles.items():
    print(f"{t}\t{r}")
PY
}

# The role of a lane owning the ids SPEC (tower's id spec: 1-4,6, or all:
# every task), from ROLES_TEXT (plan_roles' lines): the one role its tasks name, code when none does. Dies when they
# name more than one, saying which task names which. Ranges expand as tower
# expands them (src/ids.ts); an id tower would refuse is left to tower.
lane_role() {
  python3 - "$1" "$2" <<'PY' || exit 1
import re, sys
spec, text = sys.argv[1], sys.argv[2]
roles = dict(l.split("\t", 1) for l in text.split("\n") if "\t" in l)
if spec == "all":
    spec = ",".join(roles)
ids = []
for tok in (t.strip() for t in spec.replace("\n", ",").split(",")):
    if not tok:
        continue
    m = re.match(r"^(\d+)-(\d+)$", tok)
    if m:
        lo, hi = m.group(1), m.group(2)
        width = len(lo) if len(lo) == len(hi) else 0
        ids += [str(n).zfill(width) for n in range(int(lo), int(hi) + 1)]
    else:
        ids.append(tok)
named = {}
for i in ids:
    if i in roles:
        named.setdefault(roles[i], []).append(i)
if len(named) > 1:
    say = "; ".join(f"{r}: task{'s' if len(t) > 1 else ''} {', '.join(t)}" for r, t in named.items())
    sys.exit(f"tasks {sys.argv[1]} name different Roles ({say}): one lane runs in one role; put them in separate lanes, or give them one Role")
print(next(iter(named), "code"))
PY
}

# 0 when the pane map MAP says the run has roles (its  roles:  line is on); a
# map without the line is a run from before roles.
roles_on() { grep -qE '^roles: +on( |$)' "$1"; }

# TITLE as a topic slug: lowercase letters and digits, words joined by -, at
# most 24 characters, cut at a word.
topic_slug() {
  local s
  s=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  while [ "${#s}" -gt 24 ]; do
    case "$s" in
      *-*) s=${s%-*} ;;
      *) s=${s:0:24} ;;
    esac
  done
  printf '%s' "$s"
}

# The topic of lane LANE (A-D) whose first task, in plan order, has TITLE
# (empty: no task yet).
lane_topic() {
  local lane; lane=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  local slug; slug=$(topic_slug "${2:-}")
  printf '%s%s' "$lane" "${slug:+-$slug}"
}

# The title of lane LANE's first task in plan order on the board (the
# current run's: TOWER_RUN), or nothing for a lane with no task.
lane_first_title() {
  tower state --json | jsonq "next((t['title'] for t in d['tasks'] if t['id'] in d['lanes'].get('$1', [])), '')"
}

# The title of the first task, in plan order, of the ids IDS (one per line or
# comma-separated) on the current run's board.
tasks_first_title() {
  tower state --json | python3 -c '
import json, re, sys
ids = set(t for t in re.split(r"[,\n]", sys.argv[1]) if t)
d = json.load(sys.stdin)
print(next((t["title"] for t in d["tasks"] if t["id"] in ids), ""))' "$1"
}
