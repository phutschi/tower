/**
 * Seam 1: the hub, driven through its HTTP API, with the stub gh standing in
 * for GitHub. Each repo's open issues are a fixture file the stub reads and
 * edits.
 */
import { Database } from "bun:sqlite";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { expect, setDefaultTimeout, test } from "bun:test";

import type { Job, PanelIssue } from "../types.ts";
import { startHub } from "./hub.ts";
import {
  acceptBundle,
  api,
  blocks,
  dir,
  ghIssues,
  ghLog,
  held,
  hubUrl,
  issue,
  polls,
  post,
  put,
  setHead,
  setIssues,
  start,
  until,
  useFixture,
} from "../tests/fixture.ts";

useFixture();
// Stations and polls are slow on a busy Mac: a test gets 20 s, as in the job tests.
setDefaultTimeout(20_000);

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
  expect(twelve!.blockedBy).toEqual(["#5"]);
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
  await until(async () => labelsOf(3).includes("in-progress"));
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

test("a bundle accepted around an issue that already has a waiting run takes that run over", async () => {
  setIssues("acme/widgets", [issue(1, "shaping"), issue(3, "shaping")]);
  setHead("acme/widgets", "aaa");
  await start();
  await post("/api/issues/acme/widgets/1/stage", { stage: "ready-for-agent" });
  await acceptBundle(1, 3);
  await post("/api/issues/acme/widgets/3/stage", { stage: "ready-for-agent" });
  await polls(1);
  expect((await runs()).map((j) => [j.issues, j.state, j.reason])).toEqual([
    [[1], "stopped", "its bundle changed"],
    [[1, 3], "queued", null],
  ]);
});

test("a closed issue leaves its bundle: the rest runs without it", async () => {
  setIssues("acme/widgets", [issue(1, "shaping"), issue(3, "shaping")]);
  setHead("acme/widgets", "aaa");
  await start();
  await acceptBundle(1, 3);
  setIssues("acme/widgets", [issue(1, "shaping")]);
  await polls(2);
  await post("/api/issues/acme/widgets/1/stage", { stage: "ready-for-agent" });
  await polls(1);
  expect((await runs()).map((j) => [j.issues, j.state])).toEqual([
    [[1], "queued"],
  ]);
});

test("a bundle issue moved back on GitHub sends the others back, again on a later poll when gh failed", async () => {
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
  await until(async () => labelsOf(3).includes("in-progress"));
  process.env.GH_STUB_FAIL = "edit";
  setIssues("acme/widgets", [issue(1, "shaping"), issue(3, "in-progress")]);
  await polls(2);
  expect(labelsOf(3)).toEqual(["in-progress"]);
  delete process.env.GH_STUB_FAIL;
  await polls(2);
  expect(labelsOf(3)).toEqual(["ready-for-agent"]);
});

/** Gives acme/widgets a context map on GitHub. */
const contextMap = () =>
  writeFileSync(join(dir(), "acme_widgets.context-map"), "");
const labelJobs = async () =>
  (await jobsNow()).filter((j) => j.kind === "label-area");

test("a newly seen issue queues one label-area job; the issues of the first poll queue none", async () => {
  contextMap();
  setIssues("acme/widgets", [issue(1), issue(2, "area:parser")]);
  await start();
  expect(await labelJobs()).toEqual([]);
  // Issue 4 was opened with its issue area: it needs no job.
  setIssues("acme/widgets", [
    issue(1),
    issue(2, "area:parser"),
    issue(3),
    issue(4, "area:billing"),
  ]);
  await polls(2);
  expect((await labelJobs()).map((j) => [j.issues, j.state])).toEqual([
    [[3], "queued"],
  ]);
});

test("a repo without a context map queues no label-area job", async () => {
  setIssues("acme/widgets", [issue(1)]);
  await start();
  setIssues("acme/widgets", [issue(1), issue(3)]);
  await polls(2);
  expect(await labelJobs()).toEqual([]);
  expect((await api<PanelIssue[]>("/api/issues")).map((i) => i.number)).toEqual(
    [1, 3],
  );
});

test("an area label changed by hand shows on the Panel at the next poll, and queues nothing", async () => {
  contextMap();
  setIssues("acme/widgets", [issue(1, "area:parser")]);
  await start();
  setIssues("acme/widgets", [issue(1, "area:billing")]);
  await polls(2);
  expect((await api<PanelIssue[]>("/api/issues"))[0]!.issueArea).toBe(
    "billing",
  );
  expect(await jobsNow()).toEqual([]);
});

test("the Panel groups issues by issue area, with ungrouped issues in their own group", async () => {
  setIssues("acme/widgets", [
    issue(1, "area:parser"),
    issue(2, "area:billing"),
    issue(3, "area:parser"),
    issue(4),
  ]);
  await start();
  const html = await (await fetch(`${hubUrl()}/?group=area`)).text();
  const group = (key: string) =>
    html.split(`<section data-area="${key}">`)[1]?.split("</section>")[0] ?? "";
  expect(group("parser")).toContain("acme/widgets#1");
  expect(group("parser")).toContain("acme/widgets#3");
  expect(group("parser")).not.toContain("acme/widgets#2");
  expect(group("billing")).toContain("acme/widgets#2");
  expect(group("")).toContain("acme/widgets#4");
  expect(html).toContain('<a href="/?group=area">issue area</a>');
});

test("the hub listens on a Tailscale or loopback address only: it is reached on the tailnet", async () => {
  for (const host of [
    "0.0.0.0",
    "::",
    "::0",
    "0:0:0:0:0:0:0:0",
    "",
    "192.168.1.20",
    "10.0.0.5",
    "100.128.0.1",
    "fe80::1",
  ])
    expect(
      startHub({ dbPath: join(dir(), "hub.db"), host, port: 0, pollMs: 20 }),
    ).rejects.toThrow("Tailscale address");
});

test("a request naming a host the Panel does not answer to is refused", async () => {
  setIssues("acme/widgets", [issue(1)]);
  await start();
  const as = (host: string) =>
    fetch(`${hubUrl()}/api/issues`, { headers: { host } });
  expect((await as("evil.example:80")).status).toBe(403);
  expect((await as("panel.evil.example")).status).toBe(403);
  expect((await as("127.evil.example")).status).toBe(403);
  expect((await as("100.64.evil.example")).status).toBe(403);
  for (const host of [
    new URL(hubUrl()).host,
    "localhost",
    "server-mac:7420",
    "server-mac.tail1234.ts.net",
  ])
    expect((await as(host)).status).toBe(200);
});

test("an issue card says what the issue waits on", async () => {
  setIssues("acme/widgets", [issue(5), issue(12, "shaping")]);
  blocks("acme/widgets", 12, 5);
  await start();
  await post("/api/issues/acme/widgets/12/stage", { stage: "ready-for-agent" });
  const html = await (await fetch(`${hubUrl()}/`)).text();
  const card = html.split("acme/widgets#12</span>")[1]?.split("</li>")[0] ?? "";
  expect(card).toContain("waits on #5");
});

test("an open issue with a label named closed is not closed", async () => {
  setIssues("acme/widgets", [
    issue(1, "closed"),
    issue(2, "closed", "shaping"),
  ]);
  await start();
  const stages = (await api<PanelIssue[]>("/api/issues")).map((i) => [
    i.number,
    i.stage,
  ]);
  expect(stages).toEqual([
    [1, "needs-triage"],
    [2, "shaping"],
  ]);
});

test("closing an issue stops its waiting label-area job", async () => {
  contextMap();
  setIssues("acme/widgets", [issue(1)]);
  await start();
  setIssues("acme/widgets", [issue(1), issue(3)]);
  await polls(2);
  setIssues("acme/widgets", [issue(1)]);
  await polls(2);
  expect((await labelJobs()).map((j) => [j.state, j.reason])).toEqual([
    ["stopped", "the issue was closed"],
  ]);
});

test("a move on out of shaping stops the issue's working grill; the grill's own move, after its spec, does not", async () => {
  setIssues("acme/widgets", [issue(1), issue(2)]);
  await start(["acme/widgets"], { serverStation: "server" });
  await put("/api/stations/server", { limit: 2 });
  for (const n of [1, 2])
    await post(`/api/issues/acme/widgets/${n}/stage`, { stage: "shaping" });
  const claim = async () =>
    (await (
      await post("/api/jobs/claim", { station: "server", kinds: ["grill"] })
    ).json()) as Job;
  const [one, two] = [await claim(), await claim()];
  // The grill of #2 keeps its spec on the hub, then moves #2 itself.
  await post(`/api/jobs/${two.id}/events`, {
    station: "server",
    ts: new Date().toISOString(),
    kind: "spec",
    data: { spec: "the spec" },
  });
  await post("/api/issues/acme/widgets/1/stage", { stage: "ready-for-agent" });
  setIssues("acme/widgets", [
    issue(1, "ready-for-agent"),
    issue(2, "ready-for-agent"),
  ]);
  await polls(2);
  expect(await api<unknown>(`/api/jobs/${one.id}/control`)).toEqual({
    stop: true,
    reason: "moved on to ready-for-agent",
  });
  expect(await api<unknown>(`/api/jobs/${two.id}/control`)).toEqual({
    stop: false,
    reason: null,
  });
  expect((await runs()).map((j) => [j.issues, j.state])).toEqual([
    [[1], "queued"],
    [[2], "queued"],
  ]);
});

test("accepting a bundle around a waiting run stops that run until the whole bundle is ready", async () => {
  setIssues("acme/widgets", [issue(1, "shaping"), issue(2, "shaping")]);
  setHead("acme/widgets", "aaa");
  await start();
  await post("/api/issues/acme/widgets/1/stage", { stage: "ready-for-agent" });
  await polls(1);
  await acceptBundle(1, 2);
  expect((await runs()).map((j) => [j.issues, j.state, j.reason])).toEqual([
    [[1], "stopped", "its bundle changed"],
  ]);
  await post("/api/issues/acme/widgets/2/stage", { stage: "ready-for-agent" });
  expect((await runs()).map((j) => [j.issues, j.state])).toEqual([
    [[1], "stopped"],
    [[1, 2], "queued"],
  ]);
});

test("a newer accepted bundle takes its issues out of older ones, and their waiting runs follow", async () => {
  setIssues("acme/widgets", [
    issue(1, "shaping"),
    issue(2, "shaping"),
    issue(3, "shaping"),
  ]);
  setHead("acme/widgets", "aaa");
  await start();
  await acceptBundle(1, 2);
  for (const n of [1, 2, 3])
    await post(`/api/issues/acme/widgets/${n}/stage`, {
      stage: "ready-for-agent",
    });
  const newer = await acceptBundle(2, 3);
  expect((await runs()).map((j) => [j.issues, j.state])).toEqual([
    [[1, 2], "stopped"],
    [[3], "stopped"],
    [[2, 3], "queued"],
    [[1], "queued"],
  ]);
  const bundles = (await api<PanelIssue[]>("/api/issues")).map((i) => [
    i.number,
    i.bundleId,
  ]);
  expect(bundles).toEqual([
    [1, null],
    [2, newer],
    [3, newer],
  ]);
});

test("accepting an order part holds the waiting run it makes wait, before any poll", async () => {
  setIssues("acme/widgets", [issue(1), issue(2, "shaping")]);
  setHead("acme/widgets", "aaa");
  await start();
  await post("/api/issues/acme/widgets/2/stage", { stage: "ready-for-agent" });
  setHead("acme/widgets", "bbb");
  await polls(2);
  expect((await runs()).map((j) => j.state)).toEqual(["queued"]);
  const job = await held("advice");
  await post(`/api/jobs/${job.id}/events`, {
    station: job.station,
    ts: new Date().toISOString(),
    kind: "proposal",
    data: {
      order: [{ repo: "acme/widgets", issue: 2, after: [1], reason: "r" }],
      bundles: [],
    },
  });
  // No poll gets that far meanwhile: listing the issues fails.
  writeFileSync(join(dir(), "fail"), "list");
  await post(`/api/advice/${job.id}/accept`, { order: [0], bundles: [] });
  expect((await runs()).map((j) => [j.state, j.reason])).toEqual([
    ["held", "waits on #1"],
  ]);
});

test("unlisting a repo stops its waiting and claimed jobs, and keeps them", async () => {
  setIssues("acme/widgets", [issue(1), issue(2)]);
  await start(["acme/widgets"], { serverStation: "server" });
  for (const n of [1, 2])
    await post(`/api/issues/acme/widgets/${n}/stage`, { stage: "shaping" });
  const claimed = (await (
    await post("/api/jobs/claim", { station: "server", kinds: ["grill"] })
  ).json()) as Job;
  await fetch(`${hubUrl()}/api/repos/acme/widgets`, { method: "DELETE" });
  const [a, b] = await jobsNow();
  expect(a!.id).toBe(claimed.id);
  expect(await api<unknown>(`/api/jobs/${a!.id}/control`)).toEqual({
    stop: true,
    reason: "the repo was unlisted",
  });
  expect(b).toMatchObject({
    state: "stopped",
    reason: "the repo was unlisted",
  });
});

test("a blocker in another repo holds the run, even with a bundle member's number", async () => {
  setIssues("acme/widgets", [issue(1, "shaping"), issue(3, "shaping")]);
  setIssues("acme/other", [issue(1)]);
  blocks("acme/widgets", 3, 1, "acme/other");
  setHead("acme/widgets", "aaa");
  await start();
  await acceptBundle(1, 3);
  for (const n of [1, 3])
    await post(`/api/issues/acme/widgets/${n}/stage`, {
      stage: "ready-for-agent",
    });
  expect((await runs()).map((j) => [j.issues, j.state, j.reason])).toEqual([
    [[1, 3], "held", "waits on acme/other#1"],
  ]);
  const three = (await api<PanelIssue[]>("/api/issues")).find(
    (i) => i.number === 3,
  );
  expect(three!.blockedBy).toEqual(["acme/other#1"]);
});

test("an open blocker past GitHub's first page of 30 still holds the run", async () => {
  setIssues("acme/widgets", [issue(12, "shaping"), issue(100)]);
  for (let b = 200; b < 231; b++) blocks("acme/widgets", 12, b);
  blocks("acme/widgets", 12, 100);
  await start();
  await post("/api/issues/acme/widgets/12/stage", { stage: "ready-for-agent" });
  expect((await runs()).map((j) => [j.state, j.reason])).toEqual([
    ["held", "waits on #100"],
  ]);
});

/** A claimed run for #12, and a PR file the stub gh lists. */
async function claimedRun() {
  setIssues("acme/widgets", [issue(12, "shaping")]);
  await start(["acme/widgets"], { serverStation: "server" });
  await post("/api/issues/acme/widgets/12/stage", { stage: "ready-for-agent" });
  const run = (await (
    await post("/api/jobs/claim", { station: "server", kinds: ["run"] })
  ).json()) as Job;
  const pr = (state: string, repo = "acme/widgets") => ({
    number: 40,
    isDraft: false,
    state,
    createdAt: new Date(Date.now() + 1000).toISOString(),
    closingIssuesReferences: [
      {
        number: 12,
        repository: {
          name: repo.split("/")[1],
          owner: { login: repo.split("/")[0] },
        },
      },
    ],
  });
  const prs = (...list: unknown[]) =>
    writeFileSync(join(dir(), "acme_widgets.prs.json"), JSON.stringify(list));
  return { run, pr, prs };
}

test("a PR that closes another repo's issue of the same number does not end the run", async () => {
  const { run, pr, prs } = await claimedRun();
  prs(pr("OPEN", "acme/other"));
  await polls(2);
  expect((await jobsNow()).find((j) => j.id === run.id)!.state).toBe("claimed");
});

test("a run whose PR was merged between two polls is done, not stopped", async () => {
  const { run, pr, prs } = await claimedRun();
  prs(pr("MERGED"));
  setIssues("acme/widgets", []);
  await polls(2);
  expect((await jobsNow()).find((j) => j.id === run.id)).toMatchObject({
    state: "done",
    reason: null,
  });
  expect(await api<unknown>(`/api/jobs/${run.id}/control`)).toEqual({
    stop: false,
    reason: null,
  });
});

test("accepting a bundle starts no run for an issue it does not touch", async () => {
  setIssues("acme/widgets", [
    issue(1, "shaping"),
    issue(2, "shaping"),
    issue(5, "ready-for-agent"),
  ]);
  setHead("acme/widgets", "aaa");
  await start();
  await acceptBundle(1, 2);
  expect(await runs()).toEqual([]);
});

test("closing one issue of a waiting bundle run queues a run for the rest", async () => {
  setIssues("acme/widgets", [
    issue(1, "shaping"),
    issue(2, "shaping"),
    issue(3, "shaping"),
    issue(9),
  ]);
  blocks("acme/widgets", 1, 9);
  setHead("acme/widgets", "aaa");
  await start();
  await acceptBundle(1, 2, 3);
  for (const n of [1, 2, 3])
    await post(`/api/issues/acme/widgets/${n}/stage`, {
      stage: "ready-for-agent",
    });
  setIssues("acme/widgets", [
    issue(1, "ready-for-agent"),
    issue(2, "ready-for-agent"),
    issue(9),
  ]);
  await polls(2);
  expect((await runs()).map((j) => [j.issues, j.state, j.reason])).toEqual([
    [[1, 2, 3], "stopped", "the issue was closed"],
    [[1, 2], "held", "waits on #9"],
  ]);
});

test("moving an issue on out of ready-for-agent stops its run not yet claimed", async () => {
  setIssues("acme/widgets", [issue(1, "shaping"), issue(9)]);
  blocks("acme/widgets", 1, 9);
  await start();
  await post("/api/issues/acme/widgets/1/stage", { stage: "ready-for-agent" });
  await post("/api/issues/acme/widgets/1/stage", { stage: "in-review" });
  expect((await runs()).map((j) => [j.state, j.reason])).toEqual([
    ["stopped", "moved on to in-review"],
  ]);
});

test("a claim made while a move back runs does not set in-progress over the move", async () => {
  setIssues("acme/widgets", [issue(1, "shaping")]);
  await start(["acme/widgets"], { serverStation: "server" });
  await post("/api/issues/acme/widgets/1/stage", { stage: "ready-for-agent" });
  writeFileSync(join(dir(), "slow"), "edit 0.5");
  const back = post("/api/issues/acme/widgets/1/stage", { stage: "shaping" });
  await Bun.sleep(200);
  const claimed = await post("/api/jobs/claim", {
    station: "server",
    kinds: ["run"],
  });
  expect(((await claimed.json()) as Job).kind).toBe("run");
  await back;
  await polls(1);
  expect(labelsOf(1)).toEqual(["shaping"]);
});

test("a run whose issue gains a blocker by an accepted order part is not claimable while gh writes it", async () => {
  setIssues("acme/widgets", [issue(1), issue(2, "shaping")]);
  setHead("acme/widgets", "aaa");
  await start(["acme/widgets"], { serverStation: "server" });
  await post("/api/issues/acme/widgets/2/stage", { stage: "ready-for-agent" });
  setHead("acme/widgets", "bbb");
  await polls(2);
  const job = await held("advice");
  await post(`/api/jobs/${job.id}/events`, {
    station: job.station,
    ts: new Date().toISOString(),
    kind: "proposal",
    data: {
      order: [{ repo: "acme/widgets", issue: 2, after: [1], reason: "r" }],
      bundles: [],
    },
  });
  writeFileSync(join(dir(), "slow"), "repos 0.3");
  const accept = post(`/api/advice/${job.id}/accept`, {
    order: [0],
    bundles: [],
  });
  // gh looks up the blocker's id, then writes the dependency.
  await until(async () =>
    ghLog().includes("gh api repos/acme/widgets/issues/1"),
  );
  const claimed = await post("/api/jobs/claim", {
    station: "server",
    kinds: ["run"],
  });
  expect(await claimed.json()).toBeNull();
  await accept;
});

test("issues left in an older bundle cut down by a newer one get their run", async () => {
  setIssues("acme/widgets", [
    issue(1, "shaping"),
    issue(2, "shaping"),
    issue(3, "shaping"),
    issue(4, "shaping"),
  ]);
  setHead("acme/widgets", "aaa");
  await start();
  await acceptBundle(1, 2, 3);
  for (const n of [1, 2])
    await post(`/api/issues/acme/widgets/${n}/stage`, {
      stage: "ready-for-agent",
    });
  expect(await runs()).toEqual([]);
  await acceptBundle(3, 4);
  expect((await runs()).map((j) => [j.issues, j.state])).toEqual([
    [[1, 2], "queued"],
  ]);
});

test("a run whose PR merged without closing its issue puts it in review", async () => {
  const { run, pr, prs } = await claimedRun();
  prs(pr("MERGED"));
  await polls(2);
  expect((await jobsNow()).find((j) => j.id === run.id)!.state).toBe("done");
  expect(labelsOf(12)).toEqual(["in-review"]);
});

test("a repo listed again in other letter case is listed once", async () => {
  await start();
  const res = await post("/api/repos", { repo: "Acme/Widgets" });
  expect(await res.json()).toEqual(["acme/widgets"]);
});

test("an advice part for a repo no longer listed is refused", async () => {
  setIssues("acme/widgets", [issue(1), issue(2)]);
  setHead("acme/widgets", "aaa");
  await start();
  setHead("acme/widgets", "bbb");
  await polls(2);
  const job = await held("advice");
  await post(`/api/jobs/${job.id}/events`, {
    station: job.station,
    ts: new Date().toISOString(),
    kind: "proposal",
    data: {
      order: [{ repo: "acme/widgets", issue: 2, after: [1], reason: "r" }],
      bundles: [],
    },
  });
  await fetch(`${hubUrl()}/api/repos/acme/widgets`, { method: "DELETE" });
  const res = await post(`/api/advice/${job.id}/accept`, {
    order: [0],
    bundles: [],
  });
  expect(res.status).toBe(400);
  expect(ghLog().some((l) => l.includes("-X POST"))).toBe(false);
});

test("a hub on an IPv6 loopback names its URL with brackets", async () => {
  const hub = await startHub({
    dbPath: join(dir(), "v6.db"),
    host: "::1",
    port: 0,
    pollMs: 60_000,
    readUsage: async () => null,
  });
  try {
    expect(hub.url).toMatch(/^http:\/\/\[::1\]:\d+$/);
  } finally {
    await hub.stop();
  }
});

test("a hub database from an earlier development build is refused, saying to delete it", async () => {
  const path = join(dir(), "old.db");
  const db = new Database(path, { create: true });
  db.exec("CREATE TABLE jobs (id TEXT PRIMARY KEY, kind TEXT NOT NULL)");
  db.close();
  expect(
    startHub({ dbPath: path, host: "127.0.0.1", port: 0, pollMs: 20 }),
  ).rejects.toThrow("delete it");
});
