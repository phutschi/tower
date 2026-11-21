/**
 * Seam 2 for runs: the real station (`cli.ts station`, which loads the run
 * runner) against a real hub. start-run.sh runs under DRY_RUN=1, so it drives
 * the kit's stub herdr; tower is the Panel's stub, answering a run's state
 * from a file.
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, expect, test } from "bun:test";
import type { Subprocess } from "bun";

import type { Job, JobEvent } from "../../types.ts";
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
  setIssues,
  start,
  until,
  useFixture,
} from "../../tests/fixture.ts";

useFixture();

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
const herdrLog = () =>
  existsSync(join(dir(), "herdr.log"))
    ? readFileSync(join(dir(), "herdr.log"), "utf8")
    : "";
const labels = (n: number) =>
  ghIssues("acme/widgets")
    .find((i) => i.number === n)!
    .labels.map((l) => l.name);
const started = async (id: string) =>
  (await job(id)).events.find((e) => e.kind === "run-started")?.data;

async function setup() {
  remote();
  setIssues("acme/widgets", [issue(12, "shaping"), issue(13, "shaping")]);
  await start(["acme/widgets"], { serverStation: "server" });
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
        DRY_RUN: "1",
        HERDR_STUB_LOG: join(dir(), "herdr.log"),
        HERDR_STUB_COUNTER: join(dir(), "herdr.counter"),
        TOWER_STUB_STATE: join(dir(), "tower-state.json"),
        PANEL_RUN_POLL_MS: "50",
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
  const log = herdrLog();
  expect(log).toContain(
    `herdr workspace create --cwd ${String(ws.path)} --label acme-widgets-12 --no-focus`,
  );
  expect(log).toMatch(/^herdr agent start acme-widgets-12 --kind claude/m);
  const brief = log.split("herdr agent prompt acme-widgets-12 ")[1] ?? "";
  const at = (s: string) => brief.indexOf(s);
  expect(at("/tower:spec-to-plan")).toBeGreaterThan(-1);
  expect(at("/tower:orchestrate")).toBeGreaterThan(at("/tower:spec-to-plan"));
  expect(brief).toContain("TRIAGE=auto");
  expect(brief).toContain("PR=ready");
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

test("a ready PR that closes the issue sets in-review and marks the job done", async () => {
  await setup();
  await ready(12);
  await until(async () => (await jobs())[0]?.state === "claimed");
  const id = (await jobs())[0]!.id;
  await until(async () => (await started(id)) !== undefined);
  const path = String((await started(id))!.path);
  const prs = join(dir(), "acme_widgets.prs.json");
  writeFileSync(
    prs,
    JSON.stringify([
      { number: 40, isDraft: true, closingIssuesReferences: [{ number: 12 }] },
    ]),
  );
  await Bun.sleep(300);
  expect((await jobs())[0]!.state).toBe("claimed");
  writeFileSync(
    prs,
    JSON.stringify([
      { number: 40, isDraft: false, closingIssuesReferences: [{ number: 12 }] },
    ]),
  );
  await until(async () => (await jobs())[0]?.state === "done");
  expect(labels(12)).toEqual(["in-review"]);
  expect((await job(id)).durationMs).toBeGreaterThan(0);
  // The station lets the run go: its checkout is gone, and no result follows.
  await until(async () => !existsSync(path));
  expect((await jobs())[0]!.state).toBe("done");
  expect(
    ghLog().filter((l) => l.includes("--add-label in-review")).length,
  ).toBe(1);
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
