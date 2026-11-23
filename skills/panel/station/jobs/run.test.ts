/**
 * Seam 2 for runs: the real station (`cli.ts station`, which loads the run
 * runner) against a real hub. start-run.sh runs under DRY_RUN=1, so it drives
 * the kit's stubs (kit-stubs.ts); tower is the Panel's stub, answering a run's state
 * from a file.
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, expect, setDefaultTimeout, test } from "bun:test";
import type { Subprocess } from "bun";

import {
  agentIs,
  kitLog,
  kitStubEnv,
} from "../../../orchestrate/tests/kit-stubs.ts";
import type { Job, JobEvent, PanelIssue } from "../../types.ts";
import {
  api,
  dir,
  ghIssues,
  ghLog,
  gitRemotes,
  hubUrl,
  issue,
  post,
  put,
  remote,
  setHead,
  setIssues,
  start,
  acceptBundle,
  inboxLog,
  polls,
  until,
  useFixture,
} from "../../tests/fixture.ts";

useFixture();
// Stations and polls are slow on a busy Mac: a test gets 20 s, as in the job tests.
setDefaultTimeout(20_000);

const CLI = join(import.meta.dir, "../../cli.ts");
const STUBS = join(import.meta.dir, "../../tests/stub");
let proc: Subprocess | undefined;
afterEach(async () => {
  proc?.kill("SIGKILL");
  await proc?.exited;
  proc = undefined;
});

type JobWithEvents = Job & { events: JobEvent[] };
const jobs = () => api<Job[]>("/api/jobs");
const job = (id: string) => api<JobWithEvents>(`/api/jobs/${id}`);
const log = () => kitLog(dir());
const towerLog = () =>
  existsSync(join(dir(), "tower.log"))
    ? readFileSync(join(dir(), "tower.log"), "utf8")
    : "";
const labels = (n: number) =>
  ghIssues("acme/widgets")
    .find((i) => i.number === n)!
    .labels.map((l) => l.name);
const started = async (id: string) =>
  (await job(id)).events.find((e) => e.kind === "run-started")?.data;

async function setup(
  env: Record<string, string> = {},
  leaseMs?: number,
  fail?: "workspace" | "close",
  files: Record<string, string> = {},
) {
  remote(files);
  setIssues("acme/widgets", [issue(12, "shaping"), issue(13, "shaping")]);
  setHead("acme/widgets", "aaa");
  await start(["acme/widgets"], {
    serverStation: "server",
    ...(leaseMs ? { leaseMs } : {}),
  });
  proc = Bun.spawn(
    [
      "bun",
      CLI,
      "station",
      "--hub",
      hubUrl(),
      "--name",
      "server",
      "--workdir",
      join(dir(), "station"),
      "--heartbeat-seconds",
      "0.05",
    ],
    {
      env: {
        ...process.env,
        ...gitRemotes(),
        PATH: `${STUBS}:${process.env.PATH}`,
        ...kitStubEnv(dir(), fail),
        TOWER_STUB_STATE: join(dir(), "tower-state.json"),
        TOWER_STUB_LOG: join(dir(), "tower.log"),
        PANEL_RUN_POLL_MS: "50",
        ...env,
      },
      stderr: "inherit",
    },
  );
}

/** Moves issues into ready-for-agent, queuing one run each. */
async function ready(...numbers: number[]) {
  for (const n of numbers)
    await post(`/api/issues/acme/widgets/${n}/stage`, {
      stage: "ready-for-agent",
    });
}

test("a claimed run sets in-progress and opens a workspace named after the issue, with the run's brief", async () => {
  await setup();
  await ready(12);
  await until(async () => (await jobs())[0]?.state === "claimed");
  const id = (await jobs())[0]!.id;
  await until(async () => labels(12).includes("in-progress"));
  expect(labels(12)).toEqual(["in-progress"]);
  await until(async () => (await started(id)) !== undefined);
  const ws = (await started(id))!;
  expect(ws).toMatchObject({ workspace: "acme-widgets-12", pane: "pane-1" });
  const calls = log();
  expect(calls).toContain(
    `workspace create --cwd ${String(ws.path)} --label acme-widgets-12 --no-focus`,
  );
  expect(calls).toMatch(/^agent start acme-widgets-12 --kind claude/m);
  const brief = calls.split("agent prompt acme-widgets-12 ")[1] ?? "";
  const at = (s: string) => brief.indexOf(s);
  expect(at("/tower:spec-to-plan")).toBeGreaterThan(-1);
  expect(at("/tower:orchestrate")).toBeGreaterThan(at("/tower:spec-to-plan"));
  expect(brief).toContain("TRIAGE=auto");
  expect(brief).toContain("PR=ready");
  // Nobody answers the planner's approval question: the move was the approval.
  expect(brief).toContain(
    "Moving acme/widgets#12 to ready-for-agent was the approval",
  );
  expect(brief).toContain("approve the task list and the lane split yourself");
  expect(brief).toContain("Closes #12");
  expect(brief).toContain("acme/widgets#12");
  expect(brief).toContain("thread named `acme/widgets#12`");
  expect(brief).toContain(String(ws.databaseName));
});

test("two runs on one Mac get their own checkouts, database names and ports", async () => {
  await setup();
  await put("/api/stations/server", { limit: 2 });
  await ready(12, 13);
  await until(
    async () =>
      (await jobs()).filter((j) => j.state === "claimed").length === 2,
  );
  const [a, b] = await jobs();
  await until(
    async () =>
      (await started(a!.id)) !== undefined &&
      (await started(b!.id)) !== undefined,
  );
  const [one, two] = [(await started(a!.id))!, (await started(b!.id))!];
  expect(one.path).not.toBe(two.path);
  expect(one.databaseName).not.toBe(two.databaseName);
  const ports = [...(one.ports as number[]), ...(two.ports as number[])];
  expect(ports.length).toBeGreaterThan(1);
  expect(new Set(ports).size).toBe(ports.length);
  expect(readFileSync(join(String(one.path), "README.md"), "utf8")).toBe(
    "widgets\n",
  );
});

test("the run's tower state reaches the hub as job events", async () => {
  await setup();
  await ready(12);
  await until(async () => (await jobs())[0]?.state === "claimed");
  const id = (await jobs())[0]!.id;
  writeFileSync(
    join(dir(), "tower-state.json"),
    JSON.stringify({ v: 1, tasks: [{ id: "1", status: "in_progress" }] }),
  );
  await until(async () =>
    (await job(id)).events.some((e) => e.kind === "tower-state"),
  );
  writeFileSync(
    join(dir(), "tower-state.json"),
    JSON.stringify({ v: 1, tasks: [{ id: "1", status: "done" }] }),
  );
  await until(
    async () =>
      (await job(id)).events.filter((e) => e.kind === "tower-state").length ===
      2,
  );
  await Bun.sleep(200);
  const states = (await job(id)).events.filter((e) => e.kind === "tower-state");
  // Only a changed state is sent again.
  expect(
    states.map((e) => (e.data.tasks as { status: string }[])[0]!.status),
  ).toEqual(["in_progress", "done"]);
});

test("a ready PR opened for the run sets in-review and marks the job done; the run keeps its checkout", async () => {
  await setup();
  await ready(12);
  await until(async () => (await jobs())[0]?.state === "claimed");
  const id = (await jobs())[0]!.id;
  await until(async () => (await started(id)) !== undefined);
  const path = String((await started(id))!.path);
  const prs = join(dir(), "acme_widgets.prs.json");
  const pr = (number: number, isDraft: boolean, createdAt: string) => ({
    number,
    isDraft,
    state: "OPEN",
    createdAt,
    closingIssuesReferences: [
      { number: 12, repository: { name: "widgets", owner: { login: "acme" } } },
    ],
  });
  // A ready PR from before the run, and the run's own PR still a draft.
  const before = "2026-01-01T00:00:00Z";
  const now = new Date().toISOString();
  writeFileSync(
    prs,
    JSON.stringify([pr(30, false, before), pr(40, true, now)]),
  );
  await Bun.sleep(300);
  expect((await jobs())[0]!.state).toBe("claimed");
  writeFileSync(
    prs,
    JSON.stringify([pr(30, false, before), pr(40, false, now)]),
  );
  await until(async () => (await jobs())[0]?.state === "done");
  expect(labels(12)).toEqual(["in-review"]);
  expect((await job(id)).durationMs).toBeGreaterThan(0);
  // The station lets the run go: it stops reading the run's state and posts
  // no result. The orchestrator may still be closing the run: its checkout stays.
  const reads = () => towerLog().split("\n").length;
  await until(async () => {
    const n = reads();
    await Bun.sleep(200);
    return reads() === n;
  });
  expect((await jobs())[0]!.state).toBe("done");
  expect(existsSync(path)).toBe(true);
  expect(
    ghLog().filter((l) => l.includes("--add-label in-review")).length,
  ).toBe(1);
});

test("a claimed run whose in-progress label gh refused gets it on a later poll", async () => {
  await setup();
  await ready(12);
  process.env.GH_STUB_FAIL = "edit";
  await until(async () => (await jobs())[0]?.state === "claimed");
  await Bun.sleep(200);
  expect(labels(12)).toEqual(["ready-for-agent"]);
  delete process.env.GH_STUB_FAIL;
  await until(async () => labels(12).includes("in-progress"));
  expect(labels(12)).toEqual(["in-progress"]);
});

test("the Panel shows the run's Mac and workspace name", async () => {
  await setup();
  await ready(12);
  await until(async () => (await jobs())[0]?.state === "claimed");
  const id = (await jobs())[0]!.id;
  await until(async () => (await started(id)) !== undefined);
  const html = await (await fetch(`${hubUrl()}/`)).text();
  const line =
    html.split(`<li data-job="${id}">`)[1]?.split("<details>")[0] ?? "";
  expect(line).toContain("claimed by server");
  expect(line).toContain("workspace acme-widgets-12");
});

test("a run whose workspace does not open is stuck in in-progress with its reason, one Inbox message, and no retry", async () => {
  await setup({}, undefined, "workspace");
  await ready(12);
  await until(async () => (await jobs())[0]?.state === "stuck");
  const [run] = await jobs();
  expect(run!.reason).toContain("could not open workspace acme-widgets-12");
  await until(async () => labels(12).includes("in-progress"));
  const [twelve] = (await api<PanelIssue[]>("/api/issues")).filter(
    (i) => i.number === 12,
  );
  expect(twelve).toMatchObject({
    stage: "in-progress",
    stuck: true,
    jobId: run!.id,
  });
  await until(async () => inboxLog().length > 0);
  await polls(3);
  expect((await jobs()).length).toBe(1);
  expect((await jobs())[0]!.state).toBe("stuck");
  const notes = inboxLog();
  expect(notes.length).toBe(1);
  expect(notes[0]).toStartWith("plannotator inbox call send_message ");
  const note = JSON.parse(
    notes[0]!.slice("plannotator inbox call send_message ".length),
  ) as Record<string, string>;
  expect(note).toMatchObject({
    thread: "acme/widgets#12",
    idempotency_key: `stuck-${run!.id}`,
  });
  expect(note.body).toContain("could not open workspace");
  const html = await (await fetch(`${hubUrl()}/`)).text();
  const card = html.split("acme/widgets#12</span>")[1]?.split("</li>")[0] ?? "";
  expect(card).toContain("stuck: ");
  expect(card).toContain("could not open workspace");
});

test("a run whose station stops reporting is marked stuck, not queued again", async () => {
  await setup({}, 300);
  await ready(12);
  await until(async () => (await jobs())[0]?.state === "claimed");
  proc!.kill("SIGKILL");
  await until(async () => (await jobs())[0]?.state !== "claimed");
  expect((await jobs())[0]).toMatchObject({
    state: "stuck",
    reason: "its station stopped reporting",
  });
  await until(async () => inboxLog().length === 1);
});

test("moving a run's issue back closes its workspace and keeps its checkout", async () => {
  await setup();
  await ready(12);
  await until(async () => (await jobs())[0]?.state === "claimed");
  const id = (await jobs())[0]!.id;
  await until(async () => (await started(id)) !== undefined);
  const path = String((await started(id))!.path);
  await post("/api/issues/acme/widgets/12/stage", { stage: "shaping" });
  await until(async () => (await jobs())[0]?.state === "stopped");
  expect((await jobs())[0]!.reason).toBe("moved back to shaping");
  expect(log()).toMatch(/^workspace close ws-1$/m);
  expect(existsSync(path)).toBe(true);
});

test("a stopped run whose workspace does not close says so in its reason", async () => {
  await setup({}, undefined, "close");
  await ready(12);
  await until(async () => (await jobs())[0]?.state === "claimed");
  const id = (await jobs())[0]!.id;
  await until(async () => (await started(id)) !== undefined);
  await post("/api/issues/acme/widgets/12/stage", { stage: "shaping" });
  await until(async () => (await jobs())[0]?.state === "stopped");
  const { reason } = (await jobs())[0]!;
  expect(reason).toStartWith(
    "moved back to shaping; its workspace is still open: ",
  );
  expect(reason).toContain("could not close workspace ws-1");
});

test("a bundle's run opens one workspace named after the bundle, with one brief naming every issue and one PR", async () => {
  await setup();
  // The station would take the advice job the bundle comes from.
  await put("/api/stations/server", { enabled: false });
  await acceptBundle(12, 13);
  await put("/api/stations/server", { enabled: true });
  await ready(12, 13);
  await until(async () =>
    (await jobs()).some((j) => j.kind === "run" && j.state === "claimed"),
  );
  const run = (await jobs()).find((j) => j.kind === "run")!;
  expect(run.issues).toEqual([12, 13]);
  await until(async () => (await started(run.id)) !== undefined);
  expect((await started(run.id))!.workspace).toBe("acme-widgets-12-13");
  const brief = log().split("agent prompt acme-widgets-12-13 ")[1] ?? "";
  expect(brief).toContain("acme/widgets#12, acme/widgets#13");
  expect(brief).toContain("one plan and one PR");
  // GitHub links each issue only with its own keyword.
  expect(brief).toContain("Closes #12, Closes #13");
  expect(brief).toContain("thread named `acme/widgets#12 + acme/widgets#13`");
  expect(log().match(/^workspace create /gm)?.length).toBe(1);
});

test("each tower-state event carries only the transcript entries new since the last", async () => {
  await setup();
  await ready(12);
  await until(async () => (await jobs())[0]?.state === "claimed");
  const id = (await jobs())[0]!.id;
  const state = (transcript: string[]) =>
    writeFileSync(
      join(dir(), "tower-state.json"),
      JSON.stringify({ v: 1, tasks: [], transcript }),
    );
  state(["a"]);
  await until(async () =>
    (await job(id)).events.some((e) => e.kind === "tower-state"),
  );
  state(["a", "b"]);
  const states = async () =>
    (await job(id)).events.filter((e) => e.kind === "tower-state");
  await until(async () => (await states()).length === 2);
  expect((await states()).map((e) => e.data.transcript)).toEqual([
    ["a"],
    ["b"],
  ]);
});

test("a run whose orchestrator exited is stuck, and frees its station", async () => {
  await setup();
  await ready(12);
  await until(async () => (await jobs())[0]?.state === "claimed");
  const id = (await jobs())[0]!.id;
  await until(async () => (await started(id)) !== undefined);
  agentIs(dir(), "acme-widgets-12", "gone");
  await until(async () => (await jobs())[0]?.state === "stuck");
  expect((await jobs())[0]!.reason).toBe("its orchestrator exited");
});

test("a stalled run is stuck and its workspace closed, unless its Inbox thread waits on an answer", async () => {
  const threads = join(dir(), "threads.json");
  const thread = (lastAuthor: string) =>
    writeFileSync(
      threads,
      JSON.stringify({
        threads: [
          { thread_name: "acme/widgets#12", last_author: lastAuthor },
          { thread_name: "acme/widgets#99", last_author: "agent" },
        ],
      }),
    );
  // The orchestrator asked in the run's thread: no stall while it waits.
  thread("agent");
  await setup({ PLANNOTATOR_STUB_THREADS: threads }, undefined, undefined, {
    ".orchestrate": "STALE=0\n",
  });
  await ready(12);
  await until(async () => (await jobs())[0]?.state === "claimed");
  const id = (await jobs())[0]!.id;
  await until(async () => (await started(id)) !== undefined);
  agentIs(dir(), "acme-widgets-12", "idle");
  await Bun.sleep(500);
  expect((await jobs())[0]!.state).toBe("claimed");
  // The person answered; the run does nothing with it.
  thread("person");
  await until(async () => (await jobs())[0]?.state === "stuck");
  expect((await jobs())[0]!.reason).toBe("no progress for 0 min");
  // Nobody watches it: its workspace closes, its checkout stays.
  expect(log()).toMatch(/^workspace close ws-1$/m);
  expect(existsSync(String((await started(id))!.path))).toBe(true);
});

test("a run whose orchestrator is working is not stuck, even before it has a tower record", async () => {
  await setup({}, undefined, undefined, { ".orchestrate": "STALE=0\n" });
  await ready(12);
  await until(async () => (await jobs())[0]?.state === "claimed");
  await Bun.sleep(500);
  expect((await jobs())[0]!.state).toBe("claimed");
});
