/**
 * Seam 1 for the order advice: the hub, driven through its HTTP API, with the
 * stub gh standing in for GitHub. A repo's main is the head file the stub
 * answers `commits/HEAD` from.
 */
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "bun:test";

import type { AdviceProposal, Job, PanelIssue } from "../types.ts";
import {
  api,
  dir,
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

const setHead = (repo: string, sha: string) =>
  writeFileSync(join(dir(), `${repo.replace("/", "_")}.head`), sha);
const jobs = () => api<Job[]>("/api/jobs");

test("a new merge to main of a listed repo queues one advice job, seen twice or not", async () => {
  setIssues("acme/widgets", [issue(1)]);
  setHead("acme/widgets", "aaa");
  await start();
  await polls(1);
  expect(await jobs()).toEqual([]);
  setHead("acme/widgets", "bbb");
  await polls(2);
  expect((await jobs()).map((j) => [j.kind, j.repo, j.state])).toEqual([
    ["advice", "acme/widgets", "queued"],
  ]);
  setHead("acme/widgets", "ccc");
  await polls(2);
  // One queued advice reads every merge: a second would say the same.
  expect((await jobs()).length).toBe(1);
});

/** An advice job, queued by a merge, with issues 1–4 of acme/widgets open. */
async function adviceJob(): Promise<Job> {
  setIssues("acme/widgets", [issue(1), issue(2), issue(3), issue(4)]);
  setHead("acme/widgets", "aaa");
  await start();
  setHead("acme/widgets", "bbb");
  await polls(2);
  return (await jobs())[0]!;
}

const PROPOSAL = {
  order: [
    { repo: "acme/widgets", issue: 2, after: [1], reason: "2 builds on 1" },
    { repo: "acme/widgets", issue: 4, after: [3], reason: "4 needs 3's API" },
  ],
  bundles: [
    { repo: "acme/widgets", issues: [1, 3], reason: "both touch the parser" },
  ],
};

const propose = (job: Job, data: unknown) =>
  post(`/api/jobs/${job.id}/events`, {
    ts: "2026-11-21T10:00:00.000Z",
    kind: "proposal",
    data,
  });

test("the advice job stores a proposal with order, bundles and reasons", async () => {
  const job = await adviceJob();
  expect((await propose(job, PROPOSAL)).status).toBe(200);
  const advice = await api<AdviceProposal>("/api/advice");
  expect(advice.id).toBe(job.id);
  expect(advice.order).toEqual(
    PROPOSAL.order.map((o) => ({ ...o, decision: null })),
  );
  expect(advice.bundles).toEqual([
    {
      id: expect.any(String),
      repo: "acme/widgets",
      issues: [1, 3],
      reason: "both touch the parser",
      decision: null,
    },
  ]);
});

test("a malformed proposal is refused with the reason and stores nothing", async () => {
  const job = await adviceJob();
  const bad = [
    { order: "first 1" },
    { ...PROPOSAL, order: [{ ...PROPOSAL.order[0], reason: "" }] },
    { ...PROPOSAL, order: [{ ...PROPOSAL.order[0], issue: 99 }] },
    { ...PROPOSAL, order: [{ ...PROPOSAL.order[0], repo: "acme/other" }] },
    { ...PROPOSAL, bundles: [{ ...PROPOSAL.bundles[0], issues: [1] }] },
  ];
  for (const data of bad) {
    const res = await propose(job, data);
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: string }).error).toMatch(
      /^malformed proposal: ./,
    );
  }
  expect(await api<AdviceProposal | null>("/api/advice")).toBeNull();
});

/** An advice job with PROPOSAL stored. */
async function proposed(): Promise<AdviceProposal> {
  await propose(await adviceJob(), PROPOSAL);
  return api<AdviceProposal>("/api/advice");
}
const writes = () =>
  ghLog().filter((l) => l.startsWith("gh issue edit") || / -X POST /.test(l));
const bundleIds = async () =>
  (await api<PanelIssue[]>("/api/issues")).map((i) => [i.number, i.bundleId]);

test("the proposal changes no label, dependency or bundle until accepted", async () => {
  await proposed();
  await polls(1);
  expect(writes()).toEqual([]);
  expect(await bundleIds()).toEqual([
    [1, null],
    [2, null],
    [3, null],
    [4, null],
  ]);
});

test("accepting an order part creates the GitHub issue dependency through gh", async () => {
  const advice = await proposed();
  const res = await post(`/api/advice/${advice.id}/accept`, {
    order: [0],
    bundles: [],
  });
  expect(res.status).toBe(200);
  // GitHub names the blocking issue by its id, not its number.
  expect(writes()).toEqual([
    "gh api -X POST repos/acme/widgets/issues/2/dependencies/blocked_by -F issue_id=1001",
  ]);
  const after = await api<AdviceProposal>("/api/advice");
  expect(after.order.map((o) => o.decision)).toEqual(["accepted", null]);
});

test("accepting a bundle stores it, and its issues show that bundle on the Panel", async () => {
  const advice = await proposed();
  const id = advice.bundles[0]!.id;
  await post(`/api/advice/${advice.id}/accept`, { order: [], bundles: [id] });
  expect(writes()).toEqual([]);
  expect(await bundleIds()).toEqual([
    [1, id],
    [2, null],
    [3, id],
    [4, null],
  ]);
});

test("rejecting a part changes nothing and marks it rejected", async () => {
  const advice = await proposed();
  const id = advice.bundles[0]!.id;
  const res = await post(`/api/advice/${advice.id}/reject`, {
    order: [1],
    bundles: [id],
  });
  expect(res.status).toBe(200);
  expect(writes()).toEqual([]);
  expect((await bundleIds()).every(([, b]) => b === null)).toBe(true);
  const after = await api<AdviceProposal>("/api/advice");
  expect(after.order.map((o) => o.decision)).toEqual([null, "rejected"]);
  expect(after.bundles[0]!.decision).toBe("rejected");
});

test("a part decided already, or not in the proposal, is refused and nothing changes", async () => {
  const advice = await proposed();
  await post(`/api/advice/${advice.id}/reject`, { order: [0], bundles: [] });
  for (const parts of [
    { order: [0], bundles: [] },
    { order: [1, 7], bundles: [] },
    { order: [], bundles: ["nope"] },
    { order: "all" },
  ])
    expect((await post(`/api/advice/${advice.id}/accept`, parts)).status).toBe(
      400,
    );
  expect((await post("/api/advice/nope/accept", { order: [] })).status).toBe(
    404,
  );
  expect(writes()).toEqual([]);
  const after = await api<AdviceProposal>("/api/advice");
  expect(after.order.map((o) => o.decision)).toEqual(["rejected", null]);
});

const page = async (query = "") => (await fetch(`${hubUrl()}/${query}`)).text();

test("the Panel shows the open parts of the advice, with accept and reject per part", async () => {
  const advice = await proposed();
  const bundle = advice.bundles[0]!.id;
  const view = async () =>
    (await page()).match(/<section data-advice>.*?<\/section>/s)?.[0] ?? "";
  let html = await view();
  expect(html).toContain("2 builds on 1");
  expect(html).toContain("4 needs 3&#39;s API");
  expect(html).toContain("both touch the parser");
  expect(html).toContain(`data-decide="/api/advice/${advice.id}/accept"`);
  expect(html).toContain(`data-decide="/api/advice/${advice.id}/reject"`);
  expect(html).toContain(
    `data-parts="{&quot;bundles&quot;:[&quot;${bundle}&quot;]}"`,
  );
  await post(`/api/advice/${advice.id}/reject`, { order: [1], bundles: [] });
  html = await view();
  expect(html).toContain("2 builds on 1");
  expect(html).not.toContain("4 needs 3&#39;s API");
});

test("the Panel can group issues by bundle", async () => {
  const advice = await proposed();
  const bundle = advice.bundles[0]!.id;
  await post(`/api/advice/${advice.id}/accept`, { bundles: [bundle] });
  const html = await page("?group=bundle");
  const section = (key: string) =>
    html.match(
      new RegExp(`<section data-bundle="${key}">.*?</section>`, "s"),
    )?.[0] ?? "";
  expect(section(bundle)).toContain("acme/widgets#1<");
  expect(section(bundle)).toContain("acme/widgets#3<");
  expect(section(bundle)).not.toContain("acme/widgets#2<");
  expect(section("none")).toContain("acme/widgets#2<");
  expect(section("none")).not.toContain("acme/widgets#1<");
  expect(html).not.toContain('<section data-stage="needs-triage">');
  // By stage stays the default.
  expect(await page()).toContain('<section data-stage="needs-triage">');
});
