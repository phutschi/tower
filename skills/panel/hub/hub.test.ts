/**
 * Seam 1: the hub, driven through its HTTP API, with the stub gh standing in
 * for GitHub. Each repo's open issues are a fixture file the stub reads and
 * edits.
 */
import { expect, test } from "bun:test";

import type { Job, PanelIssue } from "../types.ts";
import {
  acceptBundle,
  api,
  blocks,
  ghIssues,
  ghLog,
  hubUrl,
  issue,
  polls,
  post,
  setHead,
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

test("moving an issue back and forth stops its waiting grill and queues one new one", async () => {
  setIssues("acme/widgets", [issue(1, "needs-triage")]);
  await start();
  for (const stage of ["shaping", "needs-triage", "shaping"])
    await post("/api/issues/acme/widgets/1/stage", { stage });
  const jobs = await api<Job[]>("/api/jobs");
  expect(jobs.map((j) => [j.kind, j.state, j.reason])).toEqual([
    ["grill", "stopped", "moved back to needs-triage"],
    ["grill", "queued", null],
  ]);
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

test("a run stuck after its lease ran out stays stuck when its station reports again", async () => {
  setIssues("acme/widgets", [issue(1, "shaping")]);
  await start(["acme/widgets"], { leaseMs: 300, serverStation: "server" });
  await post("/api/issues/acme/widgets/1/stage", { stage: "ready-for-agent" });
  await post("/api/jobs/claim", { station: "server", kinds: ["run"] });
  const [run] = await api<Job[]>("/api/jobs");
  for (
    let i = 0;
    i < 100 && (await api<Job[]>("/api/jobs"))[0]!.state !== "stuck";
    i++
  )
    await Bun.sleep(20);
  const res = await post(`/api/jobs/${run!.id}/heartbeat`, {
    station: "server",
  });
  expect(res.status).toBe(409);
  expect((await api<Job[]>("/api/jobs"))[0]!.state).toBe("stuck");
});

const jobsNow = () => api<Job[]>("/api/jobs");
const runs = async () => (await jobsNow()).filter((j) => j.kind === "run");
const labelsOf = (n: number) =>
  ghIssues("acme/widgets")
    .find((i) => i.number === n)!
    .labels.map((l) => l.name);

test("a run for an issue with an open blocker is held, not claimable, and the Panel says what it waits on", async () => {
  setIssues("acme/widgets", [issue(5), issue(12, "shaping")]);
  blocks("acme/widgets", 12, 5);
  await start(["acme/widgets"], { serverStation: "server" });
  await post("/api/issues/acme/widgets/12/stage", { stage: "ready-for-agent" });
  await polls(1);
  const [run] = await runs();
  expect(run).toMatchObject({ state: "held", reason: "waits on #5" });
  const claimed = await post("/api/jobs/claim", {
    station: "server",
    kinds: ["run"],
  });
  expect(await claimed.json()).toBeNull();
  const twelve = (await api<PanelIssue[]>("/api/issues")).find(
    (i) => i.number === 12,
  );
  expect(twelve!.blockedBy).toEqual([5]);
  const html = await (await fetch(`${hubUrl()}/`)).text();
  expect(html).toContain("held: waits on #5");
});

test("a held run becomes queued once its last blocker closes", async () => {
  setIssues("acme/widgets", [issue(5), issue(6), issue(12, "shaping")]);
  blocks("acme/widgets", 12, 5);
  blocks("acme/widgets", 12, 6);
  await start();
  await post("/api/issues/acme/widgets/12/stage", { stage: "ready-for-agent" });
  await polls(1);
  expect((await runs())[0]).toMatchObject({
    state: "held",
    reason: "waits on #5, #6",
  });
  setIssues("acme/widgets", [issue(6), issue(12, "ready-for-agent")]);
  await polls(2);
  expect((await runs())[0]).toMatchObject({
    state: "held",
    reason: "waits on #6",
  });
  setIssues("acme/widgets", [issue(12, "ready-for-agent")]);
  await polls(2);
  expect((await runs())[0]).toMatchObject({ state: "queued", reason: null });
});

test("a bundle with one issue not yet ready-for-agent queues nothing; all ready, exactly one run for all its issues", async () => {
  setIssues("acme/widgets", [
    issue(1, "shaping"),
    issue(3, "shaping"),
    issue(4),
  ]);
  setHead("acme/widgets", "aaa");
  await start();
  await acceptBundle(1, 3);
  await post("/api/issues/acme/widgets/1/stage", { stage: "ready-for-agent" });
  await polls(1);
  expect(await runs()).toEqual([]);
  await post("/api/issues/acme/widgets/3/stage", { stage: "ready-for-agent" });
  await polls(2);
  expect((await runs()).map((j) => [j.issues, j.state])).toEqual([
    [[1, 3], "queued"],
  ]);
});

test("a bundle that waits on an open issue outside it is held; one inside it holds nothing", async () => {
  setIssues("acme/widgets", [
    issue(1, "shaping"),
    issue(3, "shaping"),
    issue(4),
  ]);
  blocks("acme/widgets", 3, 1);
  blocks("acme/widgets", 3, 4);
  setHead("acme/widgets", "aaa");
  await start();
  await acceptBundle(1, 3);
  for (const n of [1, 3])
    await post(`/api/issues/acme/widgets/${n}/stage`, {
      stage: "ready-for-agent",
    });
  await polls(1);
  expect((await runs()).map((j) => [j.issues, j.state, j.reason])).toEqual([
    [[1, 3], "held", "waits on #4"],
  ]);
});

test("moving one bundle issue back stops the run and moves its other issues back to ready-for-agent", async () => {
  setIssues("acme/widgets", [issue(1, "shaping"), issue(3, "shaping")]);
  setHead("acme/widgets", "aaa");
  await start(["acme/widgets"], { serverStation: "server" });
  await acceptBundle(1, 3);
  for (const n of [1, 3])
    await post(`/api/issues/acme/widgets/${n}/stage`, {
      stage: "ready-for-agent",
    });
  await polls(1);
  await post("/api/jobs/claim", { station: "server", kinds: ["run"] });
  for (let i = 0; i < 100 && !labelsOf(3).includes("in-progress"); i++)
    await Bun.sleep(20);
  await post("/api/issues/acme/widgets/1/stage", { stage: "shaping" });
  const [run] = await runs();
  expect(await api<unknown>(`/api/jobs/${run!.id}/control`)).toEqual({
    stop: true,
    reason: "moved back to shaping",
  });
  expect(labelsOf(1)).toEqual(["shaping"]);
  expect(labelsOf(3)).toEqual(["ready-for-agent"]);
  await polls(2);
  // Issue 3 alone in ready-for-agent starts nothing: its bundle is not ready.
  expect((await runs()).length).toBe(1);
});
