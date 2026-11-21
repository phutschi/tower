/** The Panel: one HTML page rendered from the API's data, sized for a phone. */
import { STAGES, type PanelIssue } from "../types.ts";

export interface PanelData {
  issues: PanelIssue[];
  repos: string[];
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

function card(i: PanelIssue): string {
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
  return `<li><span class="ref">${esc(i.repo)}#${i.number}</span>${area} ${esc(i.title)} ${move}</li>`;
}

function stageSection(stage: string, issues: PanelIssue[]): string {
  const mine = issues.filter((i) => i.stage === stage);
  const list = `<ul>${mine.map(card).join("")}</ul>`;
  const head = `${stage} (${mine.length})`;
  // Closed issues stay out of the way: they left the active stages.
  return stage === "closed"
    ? `<section data-stage="${stage}"><details><summary>${head}</summary>${list}</details></section>`
    : `<section data-stage="${stage}"><h2>${head}</h2>${list}</section>`;
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

const STYLE = `
body { font: 16px/1.4 system-ui, sans-serif; margin: 0 auto; padding: 0 16px; max-width: 60rem; }
ul { list-style: none; padding: 0; }
li { padding: .5rem 0; border-bottom: 1px solid #8884; overflow-wrap: anywhere; }
.ref { font-family: ui-monospace, monospace; }
.tag { font-size: .8em; padding: 0 .4em; border: 1px solid #8888; border-radius: .4em; }
select, button, input { font: inherit; max-width: 100%; }
`;

// Each control calls the API, then reloads: the page is always the API's data.
const SCRIPT = `
const call = (url, method, body) => fetch(url, { method, headers: { "content-type": "application/json" }, body: body && JSON.stringify(body) })
  .then(async (r) => { if (!r.ok) alert((await r.json()).error); location.reload(); });
document.querySelectorAll("[data-move]").forEach((s) => s.addEventListener("change", () => call(s.dataset.move, "POST", { stage: s.value })));
document.querySelectorAll("[data-unlist]").forEach((b) => b.addEventListener("click", () => call(b.dataset.unlist, "DELETE")));
document.querySelector("[data-list]")?.addEventListener("submit", (e) => { e.preventDefault(); call("/api/repos", "POST", { repo: e.target.repo.value }); });
`;

export function renderPanel(data: PanelData): string {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Panel</title><style>${STYLE}</style></head>
<body><h1>Panel</h1>
${STAGES.map((s) => stageSection(s, data.issues)).join("\n")}
${repoList(data.repos)}
<script>${SCRIPT}</script></body></html>`;
}
