/** The Panel: one HTML page rendered from the API's data, sized for a phone. */
import {
  STAGES,
  type AdviceProposal,
  type Bundle,
  type Job,
  type PanelIssue,
  type Station,
  type UsageRow,
  type UsageView,
} from "../types.ts";

export interface PanelData {
  issues: PanelIssue[];
  /** Why each stuck issue's job is stuck, by job id. */
  stuckReasons: Record<string, string>;
  repos: string[];
  stations: Station[];
  /**
   * The latest jobs, newest first, with how many events each has and the
   * workspace its run opened; a job's events load when it is opened.
   */
  jobs: (Job & { events: number; workspace: string | null })[];
  advice: AdviceProposal | null;
  usage: UsageView;
  bundles: Bundle[];
  /** How the issues are grouped: by stage, by bundle, or by issue area. */
  group: "stage" | "bundle" | "area";
}

export const esc = (s: string) =>
  s.replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ]!,
  );

const MOVABLE = STAGES.filter((s) => s !== "closed");

function card(i: PanelIssue, reasons: PanelData["stuckReasons"]): string {
  const path = `/api/issues/${i.repo}/${i.number}/stage`;
  const options = MOVABLE.map(
    (s) =>
      `<option value="${s}"${s === i.stage ? " selected" : ""}>${s}</option>`,
  ).join("");
  const move =
    i.stage === "closed"
      ? ""
      : `<select data-move="${esc(path)}" aria-label="Stage of ${esc(i.repo)}#${i.number}">${options}</select>`;
  const area = i.issueArea
    ? ` <span class="tag">${esc(i.issueArea)}</span>`
    : "";
  const isStuck = i.stuck && i.jobId !== null;
  const stuck = isStuck
    ? ` <span class="pill stuck">stuck: ${esc(reasons[i.jobId!] ?? "")}</span>`
    : "";
  const waits = i.blockedBy.length
    ? ` <span class="pill waits">waits on ${esc(i.blockedBy.join(", "))}</span>`
    : "";
  const mark = isStuck ? " is-stuck" : i.blockedBy.length ? " is-waiting" : "";
  return `<li class="card${mark}"><div class="card-main"><span class="ref">${esc(i.repo)}#${i.number}</span>${area} <span class="title">${esc(i.title)}</span>${waits}${stuck}</div>${move}</li>`;
}

/** A section's heading: its name and how many issues it holds. */
const head = (name: string, n: number) =>
  `<span class="name">${esc(name)}</span> <span class="count">${n}</span>`;

function stageSection(
  stage: string,
  issues: PanelIssue[],
  reasons: PanelData["stuckReasons"],
): string {
  const mine = issues.filter((i) => i.stage === stage);
  const list = `<ul>${mine.map((i) => card(i, reasons)).join("")}</ul>`;
  const h = head(stage, mine.length);
  // Closed issues stay out of the way: they left the active stages.
  return stage === "closed"
    ? `<section data-stage="${stage}"><details><summary><h2>${h}</h2></summary>${list}</details></section>`
    : `<section data-stage="${stage}"><h2>${h}</h2>${list}</section>`;
}

function bundleSections(
  issues: PanelIssue[],
  bundles: Bundle[],
  reasons: PanelData["stuckReasons"],
): string {
  const section = (key: string, name: string, mine: PanelIssue[]) =>
    `<section data-bundle="${esc(key)}"><h2>${head(name, mine.length)}</h2><ul>${mine.map((i) => card(i, reasons)).join("")}</ul></section>`;
  const of = (id: string | null) =>
    issues.filter((i) => i.bundleId === id && i.stage !== "closed");
  return [
    ...bundles
      .filter((b) => of(b.id).length)
      .map((b) =>
        section(b.id, `bundle ${b.repo} #${b.issues.join(", #")}`, of(b.id)),
      ),
    section("none", "no bundle", of(null)),
  ].join("\n");
}

/** The open issues by issue area, A to Z, then the ones with none. */
function areaSections(
  issues: PanelIssue[],
  reasons: PanelData["stuckReasons"],
): string {
  const open = issues.filter((i) => i.stage !== "closed");
  const areas = [
    ...new Set(open.flatMap((i) => (i.issueArea ? [i.issueArea] : []))),
  ].sort();
  const section = (key: string, name: string) => {
    const mine = open.filter((i) => (i.issueArea ?? "") === key);
    return `<section data-area="${esc(key)}"><h2>${head(name, mine.length)}</h2><ul>${mine.map((i) => card(i, reasons)).join("")}</ul></section>`;
  };
  return [
    ...areas.map((a) => section(a, a)),
    section("", "no issue area"),
  ].join("\n");
}

/** The parts of the advice still waiting for the user; decided ones are hidden. */
function adviceView(advice: AdviceProposal | null): string {
  if (!advice) return "";
  const controls = (parts: object) =>
    ["accept", "reject"]
      .map(
        (d) =>
          `<button data-decide="/api/advice/${esc(advice.id)}/${d}" data-parts="${esc(JSON.stringify(parts))}">${d}</button>`,
      )
      .join(" ");
  const item = (text: string, parts: object) =>
    `<li class="advice"><span class="advice-text">${text}</span><span class="decide">${controls(parts)}</span></li>`;
  const items = [
    ...advice.order.flatMap((o, n) =>
      o.decision
        ? []
        : [
            item(
              `<span class="ref">${esc(o.repo)}#${o.issue}</span> after #${o.after.join(", #")}: ${esc(o.reason)}`,
              { order: [n] },
            ),
          ],
    ),
    ...advice.bundles.flatMap((b) =>
      b.decision
        ? []
        : [
            item(
              `bundle <span class="ref">${esc(b.repo)} #${b.issues.join(", #")}</span>: ${esc(b.reason)}`,
              { bundles: [b.id] },
            ),
          ],
    ),
  ];
  return items.length
    ? `<section data-advice><h2>Order advice</h2><ul>${items.join("")}</ul></section>`
    : "";
}

/**
 * An ISO time as people read it: 24-hour, in this machine's zone unless one
 * is given. Storage and the API keep ISO; a value that is no date passes on.
 */
export function localTime(iso: string, timeZone?: string): string {
  const t = Date.parse(iso);
  if (isNaN(t)) return iso;
  // Built from parts: runtimes' ICU join date and time differently.
  const part = Object.fromEntries(
    new Intl.DateTimeFormat("en-GB", {
      day: "numeric",
      month: "short",
      year: "numeric",
      hour: "2-digit",
      minute: "2-digit",
      hourCycle: "h23",
      ...(timeZone ? { timeZone } : {}),
    })
      .formatToParts(t)
      .map((p) => [p.type, p.value]),
  );
  return `${part.day} ${part.month} ${part.year}, ${part.hour}:${part.minute}`;
}

const LIMIT_NAMES = { session: "5-hour window", weekly_all: "weekly" };
const limitName = (r: UsageRow) =>
  r.kind === "weekly_scoped"
    ? `${r.model ?? "model"} weekly`
    : LIMIT_NAMES[r.kind];

/** The plan's limits, and the pause when Claude refused a job at one. */
function limitsView(u: UsageView): string {
  const rows = u.rows
    .map((r) => {
      const p = Math.min(100, Math.max(0, Math.round(r.percent)));
      const level = p >= 90 ? " high" : p >= 70 ? " warm" : "";
      return `<li class="limit${level}"><span class="limit-name">${esc(limitName(r))}: ${Math.round(r.percent)}%</span> <span class="resets">resets ${esc(localTime(r.resetsAt))}</span><span class="bar" aria-hidden="true"><span style="--p:${p}%"></span></span></li>`;
    })
    .join("");
  const paused = u.pausedUntil
    ? `<p data-paused>Paused at a usage limit: no new job starts until ${esc(localTime(u.pausedUntil))}.</p>`
    : "";
  const source =
    u.source === "job-events"
      ? `<p class="note">${u.rows.length ? "No usage report; these are the values from the latest jobs." : "No usage report, and no job has reported its limits yet."}</p>`
      : "";
  return `<section data-usage><h2>Limits</h2>${paused}${source}<ul>${rows}</ul></section>`;
}

function repoList(repos: string[]): string {
  const items = repos
    .map(
      (r) =>
        `<li class="repo"><span class="ref">${esc(r)}</span> <button class="quiet" data-unlist="/api/repos/${esc(r)}">unlist</button></li>`,
    )
    .join("");
  return `<section data-repos><h2>Repos</h2><ul>${items}</ul>
<form data-list class="add"><input name="repo" placeholder="owner/name" aria-label="Repo to list" autocapitalize="off" autocorrect="off" spellcheck="false" required> <button>list</button></form></section>`;
}

const jobName = (j: Job) => `${j.kind} ${j.repo}#${j.issues.join(", #")}`;

function stationList(stations: Station[], jobs: Job[]): string {
  const items = stations.map((s) => {
    const path = `/api/stations/${esc(s.name)}`;
    const mine = jobs
      .filter((j) => j.state === "claimed" && j.station === s.name)
      .map((j) => esc(jobName(j)));
    return `<li data-station="${esc(s.name)}"><label class="switch"><input type="checkbox" data-switch="${path}"${s.enabled ? " checked" : ""}> <span>${esc(s.name)}</span></label>
<label class="cap">limit <input type="number" min="0" inputmode="numeric" data-limit="${path}" value="${s.limit}"></label>
<span class="busy${mine.length ? "" : " idle"}">${mine.length ? mine.join(", ") : "idle"}</span></li>`;
  });
  return `<section data-stations><h2>Stations</h2><ul>${items.join("")}</ul></section>`;
}

function jobState(j: Job): string {
  if (j.state === "claimed") return `claimed by ${esc(j.station ?? "")}`;
  const took =
    j.durationMs === null ? "" : ` in ${Math.round(j.durationMs / 1000)}s`;
  const reason = j.reason ? `: ${esc(j.reason)}` : "";
  const tokens = j.tokens
    ? `, ${j.tokens.input} in / ${j.tokens.output} out tokens`
    : "";
  return `${j.state}${took}${tokens}${reason}`;
}

function jobList(jobs: PanelData["jobs"]): string {
  const items = jobs.map((j) => {
    // Where to attach to a run: the workspace its station opened.
    const meta = [
      j.workspace ? `workspace ${esc(j.workspace)}` : "",
      j.sessionId ? `session ${esc(j.sessionId)}` : "",
    ].filter(Boolean);
    const where = meta.length
      ? `<span class="meta">${meta.join(" · ")}</span>`
      : "";
    return `<li data-job="${esc(j.id)}"><span class="job-name">${esc(jobName(j))}</span> <span class="state s-${j.state}">${jobState(j)}</span>${where}
<details data-events="/api/jobs/${esc(j.id)}"><summary>${j.events} events</summary><ul class="events"></ul></details></li>`;
  });
  return `<section data-jobs><h2>Jobs</h2><ul>${items.join("")}</ul></section>`;
}

// Dark by default: ink surfaces, warm text, one brass accent. Each state has
// its own colour, the same wherever it shows: stuck coral, waiting lavender,
// running blue, done green. Every text colour passes WCAG AA on its surface,
// and control borders reach 3:1 against it.
const STYLE = `
:root {
  color-scheme: dark;
  --bg: #0d1014;
  --surface: #151a20;
  --surface-2: #1f262e;
  --field: #0f1318;
  --line: #232a33;
  --line-strong: #343d48;
  --control-line: #5f6b78;
  --track: #262e38;
  --text: #e7e3da;
  --muted: #9ba5b0;
  --faint: #7d8794;
  --accent: #e6c068;
  --on-accent: #1b1606;
  --accent-bg: rgba(230, 192, 104, .12);
  --accent-line: rgba(230, 192, 104, .35);
  --go: #6fdc9f;
  --go-bg: rgba(111, 220, 159, .12);
  --run: #7cb8ff;
  --run-bg: rgba(124, 184, 255, .12);
  --held: #b9a6ff;
  --held-bg: rgba(185, 166, 255, .13);
  --stuck: #ff8a7a;
  --stuck-bg: rgba(255, 138, 122, .13);
  --rose: #f0a3c4;
  --mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, monospace;
  --radius: .9rem;
  --tap: 2.75rem;
}
*, *::before, *::after { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; text-size-adjust: 100%; }
body {
  margin: 0;
  padding: 0 max(1rem, env(safe-area-inset-right)) 3rem max(1rem, env(safe-area-inset-left));
  background-color: var(--bg);
  background-image: radial-gradient(56rem 24rem at 50% -8rem, #18202b, transparent 70%);
  background-repeat: no-repeat;
  color: var(--text);
  font: 1rem/1.45 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  -webkit-font-smoothing: antialiased;
}
.top, .layout { max-width: 76rem; margin-inline: auto; }

/* Header: the name, what needs a look, and the grouping. */
.top {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  align-items: center;
  gap: .75rem 1rem;
  padding-block: 1.25rem 1rem;
}
h1 {
  margin: 0;
  display: flex;
  align-items: center;
  gap: .65rem;
  font-size: 1.375rem;
  font-weight: 650;
  letter-spacing: -.01em;
}
h1::before {
  content: "";
  width: .7rem;
  height: .7rem;
  border-radius: .2rem;
  background: var(--accent);
  box-shadow: 0 0 0 .3rem var(--accent-bg);
}
.summary {
  margin: 0;
  display: flex;
  flex-wrap: wrap;
  justify-content: end;
  align-items: center;
  gap: .4rem;
  font-size: .8125rem;
  color: var(--muted);
  font-variant-numeric: tabular-nums;
}
.groups {
  grid-column: 1 / -1;
  display: flex;
  gap: .25rem;
  padding: .25rem;
  background: var(--surface);
  border: 1px solid var(--line);
  border-radius: .75rem;
}
.groups a {
  flex: 1;
  display: grid;
  place-items: center;
  min-height: var(--tap);
  padding: 0 .75rem;
  border-radius: .55rem;
  color: var(--muted);
  text-decoration: none;
  font-size: .9375rem;
  font-weight: 500;
}
.groups a:hover { color: var(--text); }
.groups a[aria-current] {
  background: var(--surface-2);
  color: var(--text);
  box-shadow: inset 0 0 0 1px var(--line-strong);
}

/* One column on a phone; the board and a side column on a laptop. */
.layout, .board, .side { display: grid; gap: .75rem; align-content: start; min-width: 0; }

section {
  min-width: 0;
  padding: .25rem 1rem .5rem;
  background: var(--surface);
  border: 1px solid var(--line);
  border-radius: var(--radius);
}
h2 {
  display: flex;
  align-items: center;
  gap: .5rem;
  margin: .8rem 0 .4rem;
  font-size: .78rem;
  font-weight: 650;
  letter-spacing: .08em;
  text-transform: uppercase;
  color: var(--muted);
  overflow-wrap: anywhere;
}
h2 .name { min-width: 0; overflow-wrap: anywhere; }
.count {
  min-width: 1.5rem;
  padding: 0 .45rem;
  border-radius: 999px;
  background: var(--surface-2);
  color: var(--text);
  font-size: .75rem;
  letter-spacing: 0;
  text-align: center;
  font-variant-numeric: tabular-nums;
}
[data-stage] { --dot: var(--muted); }
[data-stage="shaping"] { --dot: var(--rose); }
[data-stage="ready-for-agent"] { --dot: var(--accent); }
[data-stage="in-progress"] { --dot: var(--run); }
[data-stage="in-review"] { --dot: var(--go); }
[data-stage="closed"] { --dot: var(--line-strong); }
[data-stage] h2::before {
  content: "";
  width: .55rem;
  height: .55rem;
  border-radius: 50%;
  background: var(--dot);
}
/* An empty section stays a quiet one-line heading. */
:is([data-stage], [data-bundle], [data-area]):has(> ul:empty) {
  background: transparent;
  border-style: dashed;
  padding-bottom: .1rem;
}
:is([data-stage], [data-bundle], [data-area]) > ul:empty { display: none; }

ul { list-style: none; margin: 0; padding: 0; }
li { overflow-wrap: anywhere; min-width: 0; }
section > ul > li,
section > details > ul > li { padding-block: .75rem; }
section > ul > li + li,
section > details > ul > li + li { border-top: 1px solid var(--line); }

/* An issue's card: ref and area, title, what holds it, its move. */
.card { display: grid; gap: .6rem; }
.card-main { display: flex; flex-wrap: wrap; align-items: center; gap: .35rem .5rem; min-width: 0; }
.card .title { flex-basis: 100%; font-weight: 500; }
.ref { font-family: var(--mono); font-size: .8125rem; color: var(--muted); }
.tag {
  padding: .05rem .5rem;
  border: 1px solid var(--line-strong);
  border-radius: 999px;
  font-size: .75rem;
  color: var(--muted);
}
.pill {
  padding: .15rem .6rem;
  border-radius: 999px;
  font-size: .8125rem;
  font-weight: 500;
}
.pill.stuck { color: var(--stuck); background: var(--stuck-bg); }
.pill.waits { color: var(--held); background: var(--held-bg); }
.card.is-stuck, .card.is-waiting { margin-inline: -1rem; padding-inline: 1rem; }
.card.is-stuck {
  box-shadow: inset .2rem 0 0 var(--stuck);
  background: linear-gradient(90deg, var(--stuck-bg), transparent 70%);
}
.card.is-waiting { box-shadow: inset .2rem 0 0 var(--held); }

/* Controls: native, sized for a thumb. */
select, input, button { font: inherit; color: inherit; max-width: 100%; margin: 0; }
select, input:not([type="checkbox"]), button { min-height: var(--tap); border-radius: .6rem; }
select, input:not([type="checkbox"]) {
  padding: .5rem .75rem;
  background-color: var(--field);
  border: 1px solid var(--control-line);
}
select {
  -webkit-appearance: none;
  appearance: none;
  width: 100%;
  padding-right: 2.25rem;
  background-image:
    linear-gradient(45deg, transparent 50%, var(--muted) 50%),
    linear-gradient(135deg, var(--muted) 50%, transparent 50%);
  background-position: calc(100% - 1.25rem) 50%, calc(100% - .94rem) 50%;
  background-size: .32rem .32rem;
  background-repeat: no-repeat;
}
input::placeholder { color: var(--faint); }
button {
  padding: .5rem 1rem;
  background: var(--surface-2);
  border: 1px solid var(--control-line);
  font-weight: 550;
  cursor: pointer;
  -webkit-tap-highlight-color: transparent;
}
button:hover, select:hover { border-color: var(--muted); }
button:active { transform: translateY(1px); }
button.quiet { background: transparent; color: var(--muted); }
:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }

/* Order advice: the one thing that asks for a decision. */
[data-advice] {
  border-color: var(--accent-line);
  background: linear-gradient(var(--accent-bg), var(--surface) 5rem);
}
[data-advice] h2 { color: var(--accent); }
.advice { display: grid; gap: .6rem; }
.decide { display: flex; gap: .5rem; }
.decide button { flex: 1; }
[data-decide$="/accept"] { background: var(--accent); color: var(--on-accent); border-color: transparent; }

/* Limits: a bar each, warm from 70%, coral from 90%. */
[data-paused] {
  margin: .25rem 0 .5rem;
  padding: .75rem;
  border: 1px solid var(--stuck);
  border-radius: .6rem;
  background: var(--stuck-bg);
  color: var(--stuck);
  font-weight: 500;
}
.note { margin: .25rem 0 .5rem; font-size: .875rem; color: var(--muted); }
.limit {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  align-items: baseline;
  gap: .4rem .75rem;
}
.limit-name { font-variant-numeric: tabular-nums; }
.resets { font-size: .8125rem; color: var(--muted); text-align: right; }
.bar {
  grid-column: 1 / -1;
  display: block;
  height: .375rem;
  border-radius: 999px;
  background: var(--track);
  overflow: hidden;
}
.bar > span { display: block; height: 100%; width: var(--p); border-radius: inherit; background: var(--go); }
.limit.warm .bar > span { background: var(--accent); }
.limit.high .bar > span { background: var(--stuck); }

/* Stations: a switch, how many jobs at once, what each runs. */
[data-station] {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  align-items: center;
  gap: .25rem 1rem;
}
.switch {
  display: flex;
  align-items: center;
  gap: .75rem;
  min-height: var(--tap);
  min-width: 0;
  font-weight: 550;
  cursor: pointer;
}
.switch input {
  -webkit-appearance: none;
  appearance: none;
  position: relative;
  flex: none;
  width: 2.75rem;
  height: 1.6rem;
  border-radius: 999px;
  background: var(--track);
  box-shadow: inset 0 0 0 1px var(--control-line);
  cursor: pointer;
  transition: background-color .15s;
}
.switch input::before {
  content: "";
  position: absolute;
  top: .2rem;
  left: .2rem;
  width: 1.2rem;
  height: 1.2rem;
  border-radius: 50%;
  background: var(--muted);
  transition: transform .15s, background-color .15s;
}
.switch input:checked { background: var(--go-bg); box-shadow: inset 0 0 0 1px var(--go); }
.switch input:checked::before { transform: translateX(1.15rem); background: var(--go); }
.cap { display: flex; align-items: center; gap: .5rem; font-size: .875rem; color: var(--muted); }
.cap input { width: 4.5rem; font-size: 1rem; text-align: center; color: var(--text); font-variant-numeric: tabular-nums; }
.busy { grid-column: 1 / -1; font-size: .875rem; color: var(--run); }
.busy.idle { color: var(--muted); }

/* Jobs: what, its state, where to attach, its events on demand. */
[data-job] { display: flex; flex-wrap: wrap; align-items: center; gap: .35rem .5rem; }
.job-name { font-family: var(--mono); font-size: .8125rem; }
.state {
  padding: .1rem .55rem;
  border-radius: 999px;
  background: var(--surface-2);
  color: var(--muted);
  font-size: .8125rem;
  font-variant-numeric: tabular-nums;
}
.s-queued { color: var(--text); }
.s-claimed { color: var(--run); background: var(--run-bg); }
.s-done { color: var(--go); background: var(--go-bg); }
.s-held { color: var(--held); background: var(--held-bg); }
.s-stuck { color: var(--stuck); background: var(--stuck-bg); }
.meta { flex-basis: 100%; font-family: var(--mono); font-size: .75rem; color: var(--muted); }
[data-job] details { flex-basis: 100%; }
summary {
  display: flex;
  align-items: center;
  gap: .6rem;
  min-height: var(--tap);
  list-style: none;
  color: var(--muted);
  font-size: .875rem;
  cursor: pointer;
}
summary::-webkit-details-marker { display: none; }
summary::before {
  content: "";
  flex: none;
  width: .45rem;
  height: .45rem;
  margin-inline: .15rem;
  border-right: 2px solid currentColor;
  border-bottom: 2px solid currentColor;
  transform: rotate(-45deg);
  transition: transform .15s;
}
details[open] > summary::before { transform: rotate(45deg); }
summary h2 { margin: 0; }
.events {
  max-height: 20rem;
  overflow: auto;
  padding: .25rem .75rem;
  border-radius: .6rem;
  background: var(--field);
  font-family: var(--mono);
  font-size: .75rem;
  color: var(--muted);
}
.events:empty { display: none; }
.events li { padding-block: .4rem; }
.events li + li { border-top: 1px solid var(--line); }

/* Repos: the listed ones, and a field to list one more. */
.repo { display: flex; align-items: center; justify-content: space-between; gap: .75rem; }
.repo .ref { color: var(--text); }
.add { display: flex; gap: .5rem; padding-block: .75rem .5rem; border-top: 1px solid var(--line); }
.add input { flex: 1; min-width: 0; }

@media (min-width: 40rem) {
  .card { grid-template-columns: minmax(0, 1fr) minmax(10rem, auto); align-items: start; }
  .advice { grid-template-columns: minmax(0, 1fr) auto; align-items: center; }
  .decide button { flex: none; }
}
@media (min-width: 64rem) {
  body { padding-inline: 2rem; }
  .top { grid-template-columns: auto minmax(0, 1fr) auto; padding-block: 1.75rem 1.25rem; }
  .summary { justify-content: start; }
  .groups { grid-column: auto; }
  .groups a { flex: none; }
  .layout { grid-template-columns: minmax(0, 1fr) minmax(0, 24rem); gap: 1.25rem; align-items: start; }
}
@media (prefers-reduced-motion: reduce) {
  *, *::before { transition: none !important; }
}
`;

// Each control calls the API, then reloads: the page is always the API's data.
const SCRIPT = `
const call = (url, method, body) => fetch(url, { method, headers: { "content-type": "application/json" }, body: body && JSON.stringify(body) })
  .then(async (r) => { if (!r.ok) alert((await r.json()).error); location.reload(); });
document.querySelectorAll("[data-move]").forEach((s) => s.addEventListener("change", () => call(s.dataset.move, "POST", { stage: s.value })));
document.querySelectorAll("[data-unlist]").forEach((b) => b.addEventListener("click", () => call(b.dataset.unlist, "DELETE")));
document.querySelectorAll("[data-switch]").forEach((c) => c.addEventListener("change", () => call(c.dataset.switch, "PUT", { enabled: c.checked })));
document.querySelectorAll("[data-limit]").forEach((i) => i.addEventListener("change", () => call(i.dataset.limit, "PUT", { limit: Number(i.value) })));
document.querySelectorAll("[data-decide]").forEach((b) => b.addEventListener("click", () => call(b.dataset.decide, "POST", JSON.parse(b.dataset.parts))));
// A job's events load when it is opened: a phone gets no event it did not ask for.
document.querySelectorAll("[data-events]").forEach((d) => d.addEventListener("toggle", async () => {
  if (!d.open || d.dataset.loaded) return;
  const res = await fetch(d.dataset.events).catch(() => null);
  if (!res?.ok) return; // closed and opened again, it tries again
  const { events } = await res.json();
  if (d.dataset.loaded) return;
  d.dataset.loaded = "1";
  const list = d.querySelector("ul");
  for (const e of events) {
    const li = document.createElement("li");
    li.textContent = e.ts + " " + e.kind + " " + JSON.stringify(e.data);
    list.append(li);
  }
}));
document.querySelector("[data-list]")?.addEventListener("submit", (e) => { e.preventDefault(); call("/api/repos", "POST", { repo: e.target.repo.value }); });
`;

const GROUPS = [
  ["stage", "/", "stage"],
  ["bundle", "/?group=bundle", "bundle"],
  ["area", "/?group=area", "issue area"],
] as const;

/** The ways to group the issues; the one shown is the current page. */
const groupLinks = (group: PanelData["group"]) =>
  GROUPS.map(
    ([g, href, label]) =>
      `<a href="${href}"${g === group ? ' aria-current="page"' : ""}>${label}</a>`,
  ).join(" ");

/** The page's header: what needs a look, before any section. */
function summary(issues: PanelIssue[]): string {
  const open = issues.filter((i) => i.stage !== "closed");
  const stuck = open.filter((i) => i.stuck && i.jobId !== null).length;
  const waiting = open.filter((i) => i.blockedBy.length).length;
  return [
    `<span>${open.length} open</span>`,
    stuck ? `<span class="pill stuck">${stuck} stuck</span>` : "",
    waiting ? `<span class="pill waits">${waiting} waiting</span>` : "",
  ].join("");
}

export function renderPanel(data: PanelData): string {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark">
<meta name="theme-color" content="#0d1014">
<title>Panel</title><style>${STYLE}</style></head>
<body><header class="top"><h1>Panel</h1><p class="summary">${summary(data.issues)}</p>
<nav class="groups" aria-label="Group issues by">${groupLinks(data.group)}</nav></header>
<div class="layout"><main class="board">
${adviceView(data.advice)}
${
  data.group === "bundle"
    ? bundleSections(data.issues, data.bundles, data.stuckReasons)
    : data.group === "area"
      ? areaSections(data.issues, data.stuckReasons)
      : STAGES.map((s) => stageSection(s, data.issues, data.stuckReasons)).join(
          "\n",
        )
}
</main>
<aside class="side">
${limitsView(data.usage)}
${stationList(data.stations, data.jobs)}
${jobList(data.jobs)}
${repoList(data.repos)}
</aside></div>
<script>${SCRIPT}</script></body></html>`;
}
