/** The Panel: one HTML page rendered from the API's data, sized for a phone. */
import {
  STAGES,
  type AdviceProposal,
  type Bundle,
  type Job,
  type JobEvent,
  type PanelIssue,
  type Station,
} from "../types.ts";

export interface PanelData {
  issues: PanelIssue[];
  /** Why each stuck issue's job is stuck, by job id. */
  stuckReasons: Record<string, string>;
  repos: string[];
  stations: Station[];
  /** The latest jobs, newest first, each with its events. */
  jobs: (Job & { events: JobEvent[] })[];
  advice: AdviceProposal | null;
  bundles: Bundle[];
  /** How the issues are grouped: by stage, or by bundle. */
  group: "stage" | "bundle";
}

const esc = (s: string) =>
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
  const stuck =
    i.stuck && i.jobId
      ? ` <span class="stuck">stuck: ${esc(reasons[i.jobId] ?? "")}</span>`
      : "";
  return `<li><span class="ref">${esc(i.repo)}#${i.number}</span>${area} ${esc(i.title)}${stuck} ${move}</li>`;
}

function stageSection(
  stage: string,
  issues: PanelIssue[],
  reasons: PanelData["stuckReasons"],
): string {
  const mine = issues.filter((i) => i.stage === stage);
  const list = `<ul>${mine.map((i) => card(i, reasons)).join("")}</ul>`;
  const head = `${stage} (${mine.length})`;
  // Closed issues stay out of the way: they left the active stages.
  return stage === "closed"
    ? `<section data-stage="${stage}"><details><summary>${head}</summary>${list}</details></section>`
    : `<section data-stage="${stage}"><h2>${head}</h2>${list}</section>`;
}

function bundleSections(
  issues: PanelIssue[],
  bundles: Bundle[],
  reasons: PanelData["stuckReasons"],
): string {
  const section = (key: string, head: string, mine: PanelIssue[]) =>
    `<section data-bundle="${esc(key)}"><h2>${esc(head)} (${mine.length})</h2><ul>${mine.map((i) => card(i, reasons)).join("")}</ul></section>`;
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
  const items = [
    ...advice.order.flatMap((o, n) =>
      o.decision
        ? []
        : [
            `<li>${esc(o.repo)}#${o.issue} after #${o.after.join(", #")}: ${esc(o.reason)} ${controls({ order: [n] })}</li>`,
          ],
    ),
    ...advice.bundles.flatMap((b) =>
      b.decision
        ? []
        : [
            `<li>bundle ${esc(b.repo)} #${b.issues.join(", #")}: ${esc(b.reason)} ${controls({ bundles: [b.id] })}</li>`,
          ],
    ),
  ];
  return items.length
    ? `<section data-advice><h2>Order advice</h2><ul>${items.join("")}</ul></section>`
    : "";
}

function repoList(repos: string[]): string {
  const items = repos
    .map(
      (r) =>
        `<li>${esc(r)} <button data-unlist="/api/repos/${esc(r)}">unlist</button></li>`,
    )
    .join("");
  return `<section data-repos><h2>Repos</h2><ul>${items}</ul>
<form data-list><input name="repo" placeholder="owner/name" required> <button>list</button></form></section>`;
}

const jobName = (j: Job) => `${j.kind} ${j.repo}#${j.issues.join(", #")}`;

function stationList(stations: Station[], jobs: Job[]): string {
  const items = stations.map((s) => {
    const path = `/api/stations/${esc(s.name)}`;
    const mine = jobs
      .filter((j) => j.state === "claimed" && j.station === s.name)
      .map((j) => esc(jobName(j)));
    return `<li data-station="${esc(s.name)}"><label><input type="checkbox" data-switch="${path}"${s.enabled ? " checked" : ""}> ${esc(s.name)}</label>
<label>limit <input type="number" min="0" inputmode="numeric" data-limit="${path}" value="${s.limit}"></label>
<span>${mine.length ? mine.join(", ") : "idle"}</span></li>`;
  });
  return `<section data-stations><h2>Stations</h2><ul>${items.join("")}</ul></section>`;
}

function jobState(j: Job): string {
  if (j.state === "claimed") return `claimed by ${esc(j.station ?? "")}`;
  const took =
    j.durationMs === null ? "" : ` in ${Math.round(j.durationMs / 1000)}s`;
  const reason = j.reason ? `: ${esc(j.reason)}` : "";
  return `${j.state}${took}${reason}`;
}

function jobList(jobs: PanelData["jobs"]): string {
  const items = jobs.map((j) => {
    const events = j.events
      .map(
        (e) =>
          `<li>${esc(e.ts)} ${esc(e.kind)} ${esc(JSON.stringify(e.data))}</li>`,
      )
      .join("");
    const session = j.sessionId ? ` · session ${esc(j.sessionId)}` : "";
    // Where to attach to a run: the workspace its station opened.
    const opened = j.events
      .filter((e) => e.kind === "run-started")
      .at(-1)?.data;
    const ws =
      typeof opened?.workspace === "string"
        ? ` · workspace ${esc(opened.workspace)}`
        : "";
    return `<li data-job="${esc(j.id)}">${esc(jobName(j))} · ${jobState(j)}${ws}${session}
<details><summary>${j.events.length} events</summary><ul>${events}</ul></details></li>`;
  });
  return `<section data-jobs><h2>Jobs</h2><ul>${items.join("")}</ul></section>`;
}

const STYLE = `
body { font: 16px/1.4 system-ui, sans-serif; margin: 0 auto; padding: 0 16px; max-width: 60rem; }
ul { list-style: none; padding: 0; }
li { padding: .5rem 0; border-bottom: 1px solid #8884; overflow-wrap: anywhere; }
.ref { font-family: ui-monospace, monospace; }
.stuck { color: #c33; font-weight: 600; }
.tag { font-size: .8em; padding: 0 .4em; border: 1px solid #8888; border-radius: .4em; }
select, button, input { font: inherit; max-width: 100%; }
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
document.querySelector("[data-list]")?.addEventListener("submit", (e) => { e.preventDefault(); call("/api/repos", "POST", { repo: e.target.repo.value }); });
`;

export function renderPanel(data: PanelData): string {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Panel</title><style>${STYLE}</style></head>
<body><h1>Panel</h1>
<nav>group by <a href="/">stage</a> · <a href="/?group=bundle">bundle</a></nav>
${adviceView(data.advice)}
${data.group === "bundle" ? bundleSections(data.issues, data.bundles, data.stuckReasons) : STAGES.map((s) => stageSection(s, data.issues, data.stuckReasons)).join("\n")}
${stationList(data.stations, data.jobs)}
${jobList(data.jobs)}
${repoList(data.repos)}
<script>${SCRIPT}</script></body></html>`;
}
