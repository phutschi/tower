/**
 * Seam 2: a station run as its own process (tests/fake-station.ts, the real
 * runStation with fake runners) against a real hub, with real git against a
 * temp bare repo standing in for GitHub's.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  afterEach,
  beforeEach,
  expect,
  setDefaultTimeout,
  test,
} from "bun:test";
import type { Subprocess } from "bun";

import type { Job, JobEvent, Station } from "../types.ts";
import {
  api,
  dir,
  git,
  hubUrl,
  issue,
  post,
  put,
  gitRemotes,
  remote,
  restart,
  setIssues,
  start,
  stopHub,
  until,
  useFixture,
} from "../tests/fixture.ts";

useFixture();
// Stations and polls are slow on a busy Mac: a test gets 20 s, as in the job tests.
setDefaultTimeout(20_000);

const FAKE = join(import.meta.dir, "../tests/fake-station.ts");
let stations: Subprocess[] = [];

function station(
  name = "server",
  kinds = "grill",
  env: Record<string, string> = {},
) {
  const workdir = join(dir(), `station-${name}`);
  mkdirSync(workdir, { recursive: true });
  const proc = Bun.spawn(["bun", FAKE], {
    env: {
      ...process.env,
      HUB_URL: hubUrl(),
      STATION_NAME: name,
      WORKDIR: workdir,
      FAKE_KINDS: kinds,
      ...gitRemotes(),
      ...env,
    },
    stderr: "inherit",
  });
  stations.push(proc);
  return { proc, workdir };
}

const jobs = () => api<Job[]>("/api/jobs");

/** Queues one grill per issue, through a move into shaping. */
async function grills(...numbers: number[]) {
  for (const n of numbers)
    await post(`/api/issues/acme/widgets/${n}/stage`, { stage: "shaping" });
}

beforeEach(() => {
  stations = [];
});
afterEach(async () => {
  for (const s of stations) s.kill("SIGKILL");
  await Promise.all(stations.map((s) => s.exited));
});

async function setup(opts = {}) {
  remote();
  setIssues("acme/widgets", [issue(1), issue(2), issue(3)]);
  await start(["acme/widgets"], { serverStation: "server", ...opts });
}

test("a station claims a queued job and the hub shows it claimed by that station", async () => {
  await setup();
  await grills(1);
  station();
  await until(async () => (await jobs())[0]?.state === "claimed");
  const [job] = await jobs();
  expect(job).toMatchObject({ kind: "grill", station: "server" });
  expect(job!.leaseUntil).not.toBeNull();
});

test("a station never holds more jobs than its Mac's limit", async () => {
  await setup();
  expect((await put("/api/stations/server", { limit: 2 })).status).toBe(200);
  await grills(1, 2, 3);
  station();
  await until(
    async () =>
      (await jobs()).filter((j) => j.state === "claimed").length === 2,
  );
  await Bun.sleep(200);
  expect((await jobs()).map((j) => j.state)).toEqual([
    "claimed",
    "claimed",
    "queued",
  ]);
});

test("a station switched off claims nothing", async () => {
  await setup();
  await put("/api/stations/server", { enabled: false });
  await grills(1);
  const { workdir } = station();
  await Bun.sleep(300);
  expect((await jobs())[0]!.state).toBe("queued");
  expect(existsSync(join(workdir, "jobs"))).toBe(false);
});

test("a new station other than the server starts switched off", async () => {
  await setup();
  await grills(1);
  expect((await fetch(`${hubUrl()}/api/stations/laptop`)).status).toBe(404);
  station("laptop");
  await until(async () => (await fetch(`${hubUrl()}/api/stations/laptop`)).ok);
  await Bun.sleep(300);
  expect(await api<Station>("/api/stations/laptop")).toEqual({
    name: "laptop",
    enabled: false,
    limit: 1,
  });
  expect((await jobs())[0]!.state).toBe("queued");
  await put("/api/stations/laptop", { enabled: true });
  await until(async () => (await jobs())[0]?.station === "laptop");
});

test("a station setting that is not a switch or a whole number is refused", async () => {
  await setup();
  for (const body of [{ enabled: "yes" }, { limit: -1 }, { limit: 1.5 }])
    expect((await put("/api/stations/server", body)).status).toBe(400);
});

type JobWithEvents = Job & { events: JobEvent[] };
const release = (workdir: string, id: string, how = "") =>
  writeFileSync(join(workdir, `release-${id}`), how);

test("a job whose lease runs out without a heartbeat returns to queued", async () => {
  await setup({ leaseMs: 300 });
  await grills(1);
  const { proc } = station();
  await until(async () => (await jobs())[0]?.state === "claimed");
  proc.kill("SIGKILL");
  await until(async () => (await jobs())[0]?.state === "queued");
  expect((await jobs())[0]).toMatchObject({ station: null, leaseUntil: null });
});

test("a heartbeat keeps a job claimed past its first lease", async () => {
  await setup({ leaseMs: 300 });
  await grills(1);
  station();
  await until(async () => (await jobs())[0]?.state === "claimed");
  await Bun.sleep(800);
  expect((await jobs())[0]!.state).toBe("claimed");
});

test("a job runs in its own worktree; its events are kept in order and its result marks it done", async () => {
  await setup();
  await grills(1);
  const { workdir } = station();
  await until(async () => (await jobs())[0]?.state === "claimed");
  const id = (await jobs())[0]!.id;
  await until(
    async () =>
      (await api<JobWithEvents>(`/api/jobs/${id}`)).events.length === 3,
  );
  const { events } = await api<JobWithEvents>(`/api/jobs/${id}`);
  expect(events.map((e) => [e.kind, e.data.n ?? null])).toEqual([
    ["workspace", null],
    ["step", 1],
    ["step", 2],
  ]);
  const ws = events[0]!.data as { path: string; branch: string };
  expect(ws.path).toBe(join(workdir, "jobs", id));
  expect(readFileSync(join(ws.path, "README.md"), "utf8")).toBe("widgets\n");
  expect(git(ws.path, "branch", "--show-current").trim()).toBe(ws.branch);
  release(workdir, id);
  await until(async () => (await jobs())[0]?.state === "done");
  const job = await api<JobWithEvents>(`/api/jobs/${id}`);
  expect(job).toMatchObject({
    station: "server",
    sessionId: `session-${id}`,
    tokens: { input: 10, output: 5 },
    leaseUntil: null,
  });
  expect(job.durationMs).toBeGreaterThan(0);
  // A finished job's worktree and branch are gone.
  expect(existsSync(ws.path)).toBe(false);
  const clone = join(workdir, "repos/acme/widgets");
  expect(git(clone, "branch", "--list", ws.branch).trim()).toBe("");
});

test("two jobs of one repo get two worktrees", async () => {
  await setup();
  await put("/api/stations/server", { limit: 2 });
  await grills(1, 2);
  station();
  await until(async () => (await jobs()).every((j) => j.state === "claimed"));
  const paths = await Promise.all(
    (await jobs()).map(async (j) => {
      await until(
        async () =>
          (await api<JobWithEvents>(`/api/jobs/${j.id}`)).events.length > 0,
      );
      return (await api<JobWithEvents>(`/api/jobs/${j.id}`)).events[0]!.data
        .path;
    }),
  );
  expect(new Set(paths).size).toBe(2);
});

test("a failed job is marked with its reason", async () => {
  await setup();
  await grills(1);
  const { workdir } = station();
  await until(async () => (await jobs())[0]?.state === "claimed");
  release(workdir, (await jobs())[0]!.id, "fail");
  await until(async () => (await jobs())[0]?.state !== "claimed");
  expect((await jobs())[0]).toMatchObject({ state: "stuck", reason: "boom" });
});

test("a station keeps retrying while the hub is unreachable and posts the result once it is back", async () => {
  await setup();
  await grills(1);
  const { workdir } = station();
  await until(async () => (await jobs())[0]?.state === "claimed");
  const id = (await jobs())[0]!.id;
  await stopHub();
  release(workdir, id);
  await Bun.sleep(300);
  await restart();
  await until(async () => (await jobs())[0]?.state === "done");
  expect((await jobs())[0]!.sessionId).toBe(`session-${id}`);
});

test("a job kind with no registered runner is never claimed by that station", async () => {
  await setup();
  await grills(1);
  station("server", "run");
  await Bun.sleep(300);
  expect((await jobs())[0]!.state).toBe("queued");
});

test("a result from a station that holds the job no more is refused", async () => {
  await setup();
  await grills(1);
  const [job] = await jobs();
  const res = await post(`/api/jobs/${job!.id}/heartbeat`, {
    station: "server",
  });
  expect(res.status).toBe(409);
  await post("/api/jobs/claim", { station: "server", kinds: ["grill"] });
  const late = await post(`/api/jobs/${job!.id}/result`, {
    station: "laptop",
    outcome: "done",
    durationMs: 5,
  });
  expect(late.status).toBe(409);
  expect((await jobs())[0]!.state).toBe("claimed");
});

test("an event from a station that holds the job no more is refused and changes nothing", async () => {
  await setup();
  await grills(1);
  const [job] = await jobs();
  await post("/api/jobs/claim", { station: "server", kinds: ["grill"] });
  const event = (station: string) =>
    post(`/api/jobs/${job!.id}/events`, {
      station,
      ts: new Date().toISOString(),
      kind: "session",
      data: { sessionId: `session-of-${station}` },
    });
  expect((await event("laptop")).status).toBe(409);
  expect((await event("server")).status).toBe(200);
  const stored = await api<JobWithEvents>(`/api/jobs/${job!.id}`);
  expect(stored.events.map((e) => e.data.sessionId)).toEqual([
    "session-of-server",
  ]);
  expect(stored.sessionId).toBe("session-of-server");
});

test("a job's tokens add up over its tokens events and its result; a failed result keeps its session", async () => {
  await setup();
  await grills(1);
  const [job] = await jobs();
  await post("/api/jobs/claim", { station: "server", kinds: ["grill"] });
  const event = (kind: string, data: Record<string, unknown>) =>
    post(`/api/jobs/${job!.id}/events`, {
      station: "server",
      ts: new Date().toISOString(),
      kind,
      data,
    });
  await event("session", { sessionId: "s-1" });
  await event("tokens", { input: 100, output: 10 });
  await event("tokens", { input: 50, output: 5 });
  expect((await event("tokens", { input: -1, output: 5 })).status).toBe(400);
  await post(`/api/jobs/${job!.id}/result`, {
    station: "server",
    outcome: "failed",
    reason: "boom",
    durationMs: 5,
    tokens: { input: 1, output: 2 },
  });
  expect(await api<Job>(`/api/jobs/${job!.id}`)).toMatchObject({
    state: "stuck",
    sessionId: "s-1",
    tokens: { input: 151, output: 17 },
  });
});

test("a checkpoint the hub has not stored holds the job's next step until the hub is back", async () => {
  await setup();
  await grills(1);
  const { workdir } = station("server", "grill", { FAKE_CHECKPOINT: "1" });
  await until(async () => (await jobs())[0]?.state === "claimed");
  const id = (await jobs())[0]!.id;
  await stopHub();
  writeFileSync(join(workdir, `checkpoint-${id}`), "");
  await Bun.sleep(300);
  expect(existsSync(join(workdir, `acted-${id}`))).toBe(false);
  await restart();
  await until(async () => existsSync(join(workdir, `acted-${id}`)));
  const { events } = await api<JobWithEvents>(`/api/jobs/${id}`);
  expect(events.map((e) => e.kind)).toContain("spec");
});

test("a checkpoint for a job the station holds no more is refused, and its action never runs", async () => {
  await setup();
  await grills(1);
  const { workdir } = station("server", "grill", { FAKE_CHECKPOINT: "1" });
  await until(async () => (await jobs())[0]?.state === "claimed");
  const id = (await jobs())[0]!.id;
  // The hub ends the job: its result is in.
  await post(`/api/jobs/${id}/result`, {
    station: "server",
    outcome: "done",
    durationMs: 5,
  });
  writeFileSync(join(workdir, `checkpoint-${id}`), "");
  await until(async () => existsSync(join(workdir, `refused-${id}`)));
  expect(existsSync(join(workdir, `acted-${id}`))).toBe(false);
  const { events } = await api<JobWithEvents>(`/api/jobs/${id}`);
  expect(events.map((e) => e.kind)).not.toContain("spec");
});

test("the Panel lists stations with switch, limit and current jobs, and each job's events", async () => {
  await setup();
  await put("/api/stations/laptop", { limit: 3 });
  await grills(1);
  station();
  await until(async () => (await jobs())[0]?.state === "claimed");
  const id = (await jobs())[0]!.id;
  await until(
    async () =>
      (await api<JobWithEvents>(`/api/jobs/${id}`)).events.length === 3,
  );
  const html = await (await fetch(`${hubUrl()}/`)).text();
  const station_ = (name: string) =>
    html.split(`<li data-station="${name}">`)[1]?.split("</li>")[0] ?? "";
  expect(station_("server")).toContain(
    '<input type="checkbox" data-switch="/api/stations/server" checked>',
  );
  expect(station_("server")).toContain(
    'data-limit="/api/stations/server" value="1"',
  );
  expect(station_("server")).toContain("grill acme/widgets#1");
  expect(station_("laptop")).toContain(
    '<input type="checkbox" data-switch="/api/stations/laptop">',
  );
  expect(station_("laptop")).toContain('value="3"');
  const job =
    html.split(`<li data-job="${id}">`)[1]?.split("</details>")[0] ?? "";
  expect(job).toContain("claimed by server");
  expect(job).toMatch(/workspace.*step.*step/s);
});

test("a hub down for longer than the lease gets the job back from the station that still runs it", async () => {
  await setup({ leaseMs: 300 });
  await grills(1);
  const { workdir } = station();
  await until(async () => (await jobs())[0]?.state === "claimed");
  const id = (await jobs())[0]!.id;
  await stopHub();
  await Bun.sleep(600);
  await restart();
  await Bun.sleep(300);
  expect((await jobs())[0]).toMatchObject({
    state: "claimed",
    station: "server",
  });
  release(workdir, id);
  await until(async () => (await jobs())[0]?.state === "done");
  const { events } = await api<JobWithEvents>(`/api/jobs/${id}`);
  expect(events.filter((e) => e.kind === "workspace").length).toBe(1);
});

test("quitting a station hands its jobs back to the queue", async () => {
  await setup({ leaseMs: 300 });
  await grills(1);
  const { proc } = station();
  await until(async () => (await jobs())[0]?.state === "claimed");
  proc.kill("SIGTERM");
  expect(await proc.exited).toBe(0);
  await until(async () => (await jobs())[0]?.state === "queued");
});

test("a station that crashed redoes its job in a fresh worktree", async () => {
  await setup({ leaseMs: 300 });
  await grills(1);
  const first = station();
  const events = async () =>
    (await api<JobWithEvents>(`/api/jobs/${(await jobs())[0]!.id}`)).events;
  await until(async () => (await events()).length === 3);
  first.proc.kill("SIGKILL");
  await first.proc.exited;
  await until(async () => (await jobs())[0]?.state === "queued");
  const { workdir } = station();
  await until(async () => (await events()).length === 6);
  const pids = (await events()).map((e) => e.data.pid).filter(Boolean);
  expect(new Set(pids).size).toBe(2);
  release(workdir, (await jobs())[0]!.id);
  await until(async () => (await jobs())[0]?.state === "done");
});

test("moving an issue back stops its job; the job's checkout and branch stay", async () => {
  await setup();
  await grills(1);
  station();
  await until(async () => (await jobs())[0]?.state === "claimed");
  const id = (await jobs())[0]!.id;
  await until(
    async () =>
      (await api<JobWithEvents>(`/api/jobs/${id}`)).events.length === 3,
  );
  const ws = (await api<JobWithEvents>(`/api/jobs/${id}`)).events[0]!.data as {
    path: string;
    branch: string;
  };
  await post("/api/issues/acme/widgets/1/stage", { stage: "needs-triage" });
  await until(async () => (await jobs())[0]?.state === "stopped");
  expect((await jobs())[0]!.reason).toBe("moved back to needs-triage");
  expect(git(ws.path, "branch", "--show-current").trim()).toBe(ws.branch);
});

test("closing an issue stops its job", async () => {
  await setup();
  await grills(1);
  station();
  await until(async () => (await jobs())[0]?.state === "claimed");
  setIssues("acme/widgets", [issue(2), issue(3)]);
  await until(async () => (await jobs())[0]?.state === "stopped");
  expect((await jobs())[0]!.reason).toBe("the issue was closed");
});

test("moving an issue back stops a job still queued, with no station", async () => {
  await setup();
  await grills(1);
  await post("/api/issues/acme/widgets/1/stage", { stage: "needs-triage" });
  expect((await jobs())[0]).toMatchObject({
    state: "stopped",
    reason: "moved back to needs-triage",
  });
});

test("the Panel shows a stopped job's reason", async () => {
  await setup();
  await grills(1);
  await post("/api/issues/acme/widgets/1/stage", { stage: "needs-triage" });
  const html = await (await fetch(`${hubUrl()}/`)).text();
  expect(html).toContain("stopped: moved back to needs-triage");
});
