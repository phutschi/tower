/**
 * Seam 1 for usage: the hub, driven through its HTTP API, with a fake usage
 * report and the stub plannotator first on PATH for its Inbox messages.
 */
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "bun:test";

import type { Job, UsageRow, UsageView } from "../types.ts";
import {
  api,
  dir,
  hubUrl,
  issue,
  post,
  setIssues,
  start,
  until,
  useFixture,
} from "../tests/fixture.ts";
import { usageRows } from "./usage.ts";

useFixture();

const REPORT: UsageRow[] = [
  { kind: "session", percent: 42, resetsAt: "2026-11-21T15:00:00.000Z" },
  { kind: "weekly_all", percent: 61, resetsAt: "2026-11-25T08:00:00.000Z" },
  {
    kind: "weekly_scoped",
    percent: 77,
    resetsAt: "2026-11-25T08:00:00.000Z",
    model: "Fable",
  },
];

/** The hub with one grill queued, for #1 of acme/widgets. */
async function hub(
  readUsage: () => Promise<UsageRow[] | null> = async () => null,
) {
  setIssues("acme/widgets", [issue(1)]);
  await start(["acme/widgets"], { serverStation: "server", readUsage });
  await post("/api/issues/acme/widgets/1/stage", { stage: "shaping" });
  return (await api<Job[]>("/api/jobs"))[0]!;
}
const claim = async () =>
  (
    await post("/api/jobs/claim", { station: "server", kinds: ["grill"] })
  ).json() as Promise<Job | null>;
const limit = (job: Job, data: Record<string, unknown>) =>
  post(`/api/jobs/${job.id}/events`, {
    station: "server",
    ts: new Date().toISOString(),
    kind: "rate-limit",
    data,
  });
const notes = () =>
  existsSync(join(dir(), "plannotator.log"))
    ? readFileSync(join(dir(), "plannotator.log"), "utf8")
        .split("\n")
        .filter(Boolean)
    : [];
const page = async () => (await fetch(`${hubUrl()}/`)).text();

test("a finished job shows its duration and tokens on the Panel", async () => {
  await hub();
  const job = (await claim())!;
  await post(`/api/jobs/${job.id}/result`, {
    station: "server",
    outcome: "done",
    durationMs: 93_000,
    tokens: { input: 12_345, output: 678 },
  });
  const html = await page();
  expect(html).toContain("in 93s");
  expect(html).toContain("12345 in / 678 out tokens");
});

test("a rejected rate-limit event pauses dispatch until its reset, with exactly one Inbox message", async () => {
  const job = await hub();
  const resetsAt = new Date(Date.now() + 3000).toISOString();
  for (let i = 0; i < 2; i++)
    expect(
      (
        await limit(job, {
          status: "rejected",
          rateLimitType: "five_hour",
          resetsAt,
        })
      ).status,
    ).toBe(200);
  expect((await api<UsageView>("/api/usage")).pausedUntil).toBe(resetsAt);
  expect(await claim()).toBeNull();
  const sends = () => notes().filter((l) => l.includes("send_message"));
  await until(async () => sends().length > 0);
  await Bun.sleep(100);
  const sent = sends();
  expect(sent).toHaveLength(1);
  expect(sent[0]).toContain(resetsAt);
  // After the reset, claiming resumes.
  await until(async () => (await claim()) !== null, 5000);
  expect((await api<UsageView>("/api/usage")).pausedUntil).toBeNull();
});

test("an allowed rate-limit event pauses nothing, and a malformed one is refused", async () => {
  const job = await hub();
  await limit(job, {
    status: "allowed_warning",
    rateLimitType: "seven_day",
    utilization: 0.9,
  });
  expect((await api<UsageView>("/api/usage")).pausedUntil).toBeNull();
  expect((await limit(job, { status: "fine" })).status).toBe(400);
  expect(
    (await limit(job, { status: "rejected", resetsAt: "soon" })).status,
  ).toBe(400);
  expect(await claim()).not.toBeNull();
});

test("the limits view shows the session, weekly and per-model weekly rows from the usage report", async () => {
  await hub(async () => REPORT);
  await until(async () => (await api<UsageView>("/api/usage")).rows.length > 0);
  expect(await api<UsageView>("/api/usage")).toEqual({
    rows: REPORT,
    source: "usage-report",
    pausedUntil: null,
  });
  const html = await page();
  expect(html).toContain("5-hour window: 42%");
  expect(html).toContain("weekly: 61%");
  expect(html).toContain("Fable weekly: 77%");
});

test("with no usage report the limits view shows the latest job rate-limit values and says so", async () => {
  const job = await hub();
  await limit(job, {
    status: "allowed",
    rateLimitType: "five_hour",
    utilization: 0.3,
    resetsAt: "2026-11-21T15:00:00.000Z",
  });
  await limit(job, {
    status: "allowed",
    rateLimitType: "five_hour",
    utilization: 0.35,
    resetsAt: "2026-11-21T15:00:00.000Z",
  });
  await limit(job, {
    status: "allowed",
    rateLimitType: "seven_day",
    utilization: 0.6,
    resetsAt: "2026-11-25T08:00:00.000Z",
  });
  const view = await api<UsageView>("/api/usage");
  expect(view.source).toBe("job-events");
  expect(view.rows).toEqual([
    { kind: "session", percent: 35, resetsAt: "2026-11-21T15:00:00.000Z" },
    { kind: "weekly_all", percent: 60, resetsAt: "2026-11-25T08:00:00.000Z" },
  ]);
  const html = await page();
  expect(html).toContain("5-hour window: 35%");
  expect(html).toContain("from the latest jobs");
});

test("the usage report's plan limits become session, weekly and per-model rows", () => {
  expect(
    usageRows({
      five_hour: { utilization: 42, resets_at: "2026-11-21T15:00:00.000Z" },
      seven_day: { utilization: 61, resets_at: "2026-11-25T08:00:00.000Z" },
      seven_day_opus: null,
      model_scoped: [
        {
          display_name: "Fable",
          utilization: 77,
          resets_at: "2026-11-25T08:00:00.000Z",
        },
        { display_name: "Unknown", utilization: null, resets_at: null },
      ],
    }),
  ).toEqual(REPORT);
  expect(usageRows(null)).toBeNull();
});

test("an empty usage report falls back to the jobs' values", async () => {
  const job = await hub(async () => []);
  await limit(job, {
    status: "allowed",
    rateLimitType: "five_hour",
    utilization: 0.2,
    resetsAt: "2026-11-21T15:00:00.000Z",
  });
  await Bun.sleep(50);
  expect(await api<UsageView>("/api/usage")).toMatchObject({
    source: "job-events",
    rows: [{ kind: "session", percent: 20 }],
  });
});

test("a rejection whose reset has passed pauses nothing and sends no note", async () => {
  const job = await hub();
  await limit(job, {
    status: "rejected",
    resetsAt: new Date(Date.now() - 60_000).toISOString(),
  });
  expect((await api<UsageView>("/api/usage")).pausedUntil).toBeNull();
  expect(await claim()).not.toBeNull();
  await Bun.sleep(100);
  expect(notes()).toEqual([]);
});

test("a pause moved later by a named reset sends a note for the new reset", async () => {
  const job = await hub();
  const soon = new Date(Date.now() + 60 * 60_000).toISOString();
  const later = new Date(Date.now() + 3 * 24 * 60 * 60_000).toISOString();
  await limit(job, {
    status: "rejected",
    rateLimitType: "five_hour",
    resetsAt: soon,
  });
  await limit(job, {
    status: "rejected",
    rateLimitType: "seven_day",
    resetsAt: later,
  });
  const sends = () => notes().filter((l) => l.includes("send_message"));
  await until(async () => sends().length === 2);
  // The two notes are sent side by side: either may land first.
  expect(sends().some((l) => l.includes(later))).toBe(true);
  expect(sends().some((l) => l.includes(soon))).toBe(true);
  expect((await api<UsageView>("/api/usage")).pausedUntil).toBe(later);
});

test("a report without per-model rows still names Opus and Sonnet from their weekly windows", () => {
  expect(
    usageRows({
      seven_day_opus: {
        utilization: 10,
        resets_at: "2026-11-25T08:00:00.000Z",
      },
      seven_day_sonnet: {
        utilization: 20,
        resets_at: "2026-11-25T08:00:00.000Z",
      },
    }),
  ).toEqual([
    {
      kind: "weekly_scoped",
      model: "Opus",
      percent: 10,
      resetsAt: "2026-11-25T08:00:00.000Z",
    },
    {
      kind: "weekly_scoped",
      model: "Sonnet",
      percent: 20,
      resetsAt: "2026-11-25T08:00:00.000Z",
    },
  ]);
  expect(usageRows({ five_hour: null })).toBeNull();
});
