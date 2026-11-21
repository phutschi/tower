/**
 * Seam 1: the hub, driven through its HTTP API, with the stub gh standing in
 * for GitHub. Each repo's open issues are a fixture file the stub reads and
 * edits.
 */
import { expect, test } from "bun:test";

import type { Job, PanelIssue } from "../types.ts";
import {
  api,
  ghIssues,
  ghLog,
  hubUrl,
  issue,
  polls,
  post,
  setIssues,
  start,
  useFixture,
} from "../tests/fixture.ts";

useFixture();

test("the first poll records current stage labels and queues no job", async () => {
  setIssues("acme/widgets", [
    issue(1, "needs-triage"),
    issue(2, "shaping"),
    issue(3, "ready-for-agent", "bug"),
  ]);
  await start();
  const issues = await api<PanelIssue[]>("/api/issues");
  expect(issues.map((i) => [i.number, i.stage])).toEqual([
    [1, "needs-triage"],
    [2, "shaping"],
    [3, "ready-for-agent"],
  ]);
  expect(await api<Job[]>("/api/jobs")).toEqual([]);
});

test("a label changed into shaping on GitHub queues one grill job, seen twice or not", async () => {
  setIssues("acme/widgets", [issue(1, "needs-triage"), issue(2)]);
  await start();
  setIssues("acme/widgets", [issue(1, "shaping"), issue(2)]);
  await polls(2);
  const jobs = await api<Job[]>("/api/jobs");
  expect(jobs.map((j) => [j.kind, j.repo, j.issues, j.state])).toEqual([
    ["grill", "acme/widgets", [1], "queued"],
  ]);
  const [one] = await api<PanelIssue[]>("/api/issues");
  expect(one).toMatchObject({ stage: "shaping", jobId: jobs[0]!.id });
});

test("a move on the Panel into shaping sets the label through gh and queues one grill job", async () => {
  setIssues("acme/widgets", [issue(4, "needs-triage", "bug", "area:ui")]);
  await start();
  const res = await post("/api/issues/acme/widgets/4/stage", {
    stage: "shaping",
  });
  expect(res.status).toBe(200);
  // The old stage label goes, the new one comes, nothing else is touched.
  expect(ghIssues("acme/widgets")[0]!.labels.map((l) => l.name)).toEqual([
    "bug",
    "area:ui",
    "shaping",
  ]);
  expect(ghLog()).toContain(
    "gh issue edit 4 --repo acme/widgets --add-label shaping --remove-label needs-triage",
  );
  await polls(2);
  const jobs = await api<Job[]>("/api/jobs");
  expect(jobs.map((j) => [j.kind, j.issues])).toEqual([["grill", [4]]]);
  const [four] = await api<PanelIssue[]>("/api/issues");
  expect(four).toMatchObject({ stage: "shaping", issueArea: "ui" });
});

test("a move is refused for an unknown stage, closed, or an issue not on the Panel", async () => {
  setIssues("acme/widgets", [issue(1, "needs-triage")]);
  await start();
  for (const [path, stage] of [
    ["/api/issues/acme/widgets/1/stage", "done"],
    ["/api/issues/acme/widgets/1/stage", "closed"],
    ["/api/issues/acme/widgets/9/stage", "shaping"],
    ["/api/issues/acme/gadgets/1/stage", "shaping"],
  ] as const)
    expect((await post(path, { stage })).status).toBe(400);
  expect(ghLog().filter((l) => l.startsWith("gh issue edit"))).toEqual([]);
});

test("a move gh refuses is reported and changes nothing", async () => {
  setIssues("acme/widgets", [issue(1, "needs-triage")]);
  await start();
  process.env.GH_STUB_FAIL = "edit";
  const res = await post("/api/issues/acme/widgets/1/stage", {
    stage: "shaping",
  });
  expect(res.status).toBe(502);
  expect(await api<Job[]>("/api/jobs")).toEqual([]);
  const [one] = await api<PanelIssue[]>("/api/issues");
  expect(one!.stage).toBe("needs-triage");
});

test("a closed issue shows as closed, leaves the active stages and cannot be moved", async () => {
  setIssues("acme/widgets", [issue(1, "in-review"), issue(2, "shaping")]);
  await start();
  setIssues("acme/widgets", [issue(2, "shaping")]);
  await polls(2);
  const issues = await api<PanelIssue[]>("/api/issues");
  expect(issues.map((i) => [i.number, i.stage])).toEqual([
    [1, "closed"],
    [2, "shaping"],
  ]);
  const res = await post("/api/issues/acme/widgets/1/stage", {
    stage: "shaping",
  });
  expect(res.status).toBe(400);
  expect(await api<Job[]>("/api/jobs")).toEqual([]);
});

test("repos are listed and unlisted through the API; an unlisted repo's issues disappear", async () => {
  setIssues("acme/widgets", [issue(1, "needs-triage")]);
  setIssues("acme/gadgets", [issue(7, "shaping")]);
  await start(["acme/widgets", "acme/gadgets"]);
  expect(await api<string[]>("/api/repos")).toEqual([
    "acme/gadgets",
    "acme/widgets",
  ]);
  expect((await api<PanelIssue[]>("/api/issues")).length).toBe(2);
  const res = await fetch(`${hubUrl()}/api/repos/acme/gadgets`, {
    method: "DELETE",
  });
  expect(res.status).toBe(200);
  expect(await api<string[]>("/api/repos")).toEqual(["acme/widgets"]);
  await polls(1);
  const issues = await api<PanelIssue[]>("/api/issues");
  expect(issues.map((i) => [i.repo, i.number])).toEqual([["acme/widgets", 1]]);
  expect((await post("/api/repos", { repo: "not a repo" })).status).toBe(400);
  expect(
    (
      await fetch(`${hubUrl()}/api/repos`, {
        method: "POST",
        body: "{not json",
      })
    ).status,
  ).toBe(400);
});

test("a newly listed repo's first poll records its stages and queues no job", async () => {
  setIssues("acme/widgets", [issue(1, "needs-triage")]);
  setIssues("acme/gadgets", [issue(7, "shaping")]);
  await start();
  await post("/api/repos", { repo: "acme/gadgets" });
  await polls(2);
  expect((await api<PanelIssue[]>("/api/issues")).length).toBe(2);
  expect(await api<Job[]>("/api/jobs")).toEqual([]);
});

test("the Panel holds each stage's issues with a move control per issue, sized for a phone", async () => {
  setIssues("acme/widgets", [
    issue(1, "needs-triage"),
    { ...issue(2, "shaping"), title: "Fix <script> & friends" },
    issue(3, "in-review"),
  ]);
  await start();
  const res = await fetch(`${hubUrl()}/`);
  expect(res.headers.get("content-type")).toContain("text/html");
  const html = await res.text();
  expect(html).toContain(
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
  );
  // No fixed-width layout: no width set in px anywhere.
  expect(html).not.toMatch(/(^|[^-])width:\s*\d+px/);
  const section = (stage: string) =>
    html.split(`<section data-stage="${stage}">`)[1]?.split("</section>")[0] ??
    "";
  expect(section("needs-triage")).toContain("acme/widgets#1");
  expect(section("shaping")).toContain("Fix &lt;script&gt; &amp; friends");
  expect(section("in-review")).toContain("acme/widgets#3");
  expect(section("ready-for-agent")).not.toContain("acme/widgets#");
  for (const n of [1, 2, 3])
    expect(html).toContain(
      `<select data-move="/api/issues/acme/widgets/${n}/stage"`,
    );
  expect(html).toContain("acme/widgets");
});

test("a write without a JSON content type is refused, so another site's form cannot move a stage", async () => {
  setIssues("acme/widgets", [issue(1, "needs-triage")]);
  await start();
  for (const path of ["/api/issues/acme/widgets/1/stage", "/api/repos"]) {
    const res = await fetch(`${hubUrl()}${path}`, {
      method: "POST",
      headers: { "content-type": "text/plain" },
      body: JSON.stringify({ stage: "shaping", repo: "acme/evil" }),
    });
    expect(res.status).toBe(400);
  }
  expect(ghLog().filter((l) => l.startsWith("gh issue edit"))).toEqual([]);
  expect(await api<string[]>("/api/repos")).toEqual(["acme/widgets"]);
});

test("reopening an issue queues nothing: no stage was moved", async () => {
  setIssues("acme/widgets", [issue(1, "shaping")]);
  await start();
  setIssues("acme/widgets", []);
  await polls(1);
  setIssues("acme/widgets", [issue(1, "shaping")]);
  await polls(1);
  const [one] = await api<PanelIssue[]>("/api/issues");
  expect(one!.stage).toBe("shaping");
  expect(await api<Job[]>("/api/jobs")).toEqual([]);
});

test("an issue with a grill still waiting gets no second one", async () => {
  setIssues("acme/widgets", [issue(1, "needs-triage")]);
  await start();
  for (const stage of ["shaping", "needs-triage", "shaping"])
    await post("/api/issues/acme/widgets/1/stage", { stage });
  expect((await api<Job[]>("/api/jobs")).length).toBe(1);
});

test("a move removes the stage labels GitHub has now, not the ones the last poll saw", async () => {
  setIssues("acme/widgets", [issue(4, "shaping")]);
  await start();
  // A grill moved it on GitHub since the last poll, and no poll ran since.
  process.env.GH_STUB_FAIL = "list";
  await polls(1);
  setIssues("acme/widgets", [issue(4, "ready-for-agent")]);
  await post("/api/issues/acme/widgets/4/stage", { stage: "in-review" });
  expect(ghIssues("acme/widgets")[0]!.labels.map((l) => l.name)).toEqual([
    "in-review",
  ]);
});

test("a label changed into ready-for-agent queues one run job", async () => {
  setIssues("acme/widgets", [issue(1, "shaping"), issue(2, "needs-triage")]);
  await start();
  setIssues("acme/widgets", [issue(1, "ready-for-agent"), issue(2)]);
  await polls(2);
  const jobs = await api<Job[]>("/api/jobs");
  expect(jobs.map((j) => [j.kind, j.issues, j.state])).toEqual([
    ["run", [1], "queued"],
  ]);
});
