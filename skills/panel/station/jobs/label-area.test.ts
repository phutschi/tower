/**
 * Seam 2 for the issue-area labelling job: a station process claims it from
 * a real hub and runs it with the stub claude and gh, against a repo whose
 * context map is in its checkout.
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, expect, setDefaultTimeout, test } from "bun:test";
import type { Subprocess } from "bun";

import type { Job } from "../../types.ts";
import {
  api,
  dir,
  ghIssues,
  ghLog,
  issue,
  polls,
  remote,
  setIssues,
  start,
  until,
  useFixture,
  type Issue,
} from "../../tests/fixture.ts";
import { station } from "../../tests/station-process.ts";

useFixture();
setDefaultTimeout(20_000);

// This file's stations: station-process.ts ends only those of the first
// file that imports it, so a later file ends its own.
let stations: Subprocess[] = [];
afterEach(async () => {
  for (const p of stations) p.kill("SIGKILL");
  await Promise.all(stations.map((p) => p.exited));
  stations = [];
});
const startStation = (env: Record<string, string>) =>
  stations.push(station(env));

const MAP = `# Context Map

## Contexts

- [Parser](./src/parser/CONTEXT.md): reads widget files
- [Billing](./src/billing/CONTEXT.md): invoices and payments
`;

/** Stream-json lines of a session that answers `text`. */
function answers(text: string) {
  const lines = [
    { type: "system", subtype: "init", session_id: "sess-7" },
    {
      type: "result",
      subtype: "success",
      is_error: false,
      result: text,
      session_id: "sess-7",
      usage: { input_tokens: 400, output_tokens: 3 },
    },
  ];
  const file = join(dir(), "claude.out");
  writeFileSync(file, lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
  return { CLAUDE_STUB_OUT: file };
}

const labels = (n: number) =>
  ghIssues("acme/widgets")
    .find((i) => i.number === n)!
    .labels.map((l) => l.name);
const repoLabels = () => {
  const file = join(dir(), "acme_widgets.labels");
  return existsSync(file)
    ? readFileSync(file, "utf8").split("\n").filter(Boolean)
    : [];
};
const labelJob = async () =>
  (await api<Job[]>("/api/jobs")).find((j) => j.kind === "label-area");

/** A new issue 3 in a repo with a context map: its label-area job is queued. */
async function newIssue(
  third: Issue = { ...issue(3), title: "Invoices round the tax wrong" },
) {
  remote({ "CONTEXT-MAP.md": MAP });
  writeFileSync(join(dir(), "acme_widgets.context-map"), "");
  setIssues("acme/widgets", [issue(1), issue(2)]);
  await start(["acme/widgets"], { serverStation: "server" });
  setIssues("acme/widgets", [issue(1), issue(2), third]);
  await polls(2);
  expect((await labelJob())?.issues).toEqual([3]);
}

test("the job creates the missing area label, then sets exactly that one, naming a context of the map", async () => {
  await newIssue();
  startStation(answers("Billing"));
  await until(async () => (await labelJob())?.state === "done");
  expect(labels(3)).toEqual(["area:billing"]);
  expect(repoLabels()).toEqual(["area:billing"]);
  const log = ghLog();
  const create = log.findIndex((l) =>
    l.startsWith("gh label create area:billing "),
  );
  const set = log.findIndex(
    (l) =>
      l.includes("issue edit 3 ") && l.includes("--add-label area:billing"),
  );
  expect(create).toBeGreaterThan(-1);
  expect(set).toBeGreaterThan(create);
  expect(await labelJob()).toMatchObject({
    sessionId: "sess-7",
    tokens: { input: 400, output: 3 },
  });
  const claude = readFileSync(join(dir(), "claude.log"), "utf8");
  expect(claude).toContain("--model haiku");
  const prompt = readFileSync(join(dir(), "claude.log.prompts"), "utf8");
  expect(prompt).toContain("Invoices round the tax wrong");
  expect(prompt).toContain("Parser");
  expect(prompt).toContain("Billing");
});

test("an area label that already exists is not created again", async () => {
  await newIssue();
  writeFileSync(join(dir(), "acme_widgets.labels"), "area:billing\n");
  startStation(answers("Billing"));
  await until(async () => (await labelJob())?.state === "done");
  expect(labels(3)).toEqual(["area:billing"]);
  expect(ghLog().some((l) => l.startsWith("gh label create"))).toBe(false);
});

test("an area a person set before the job ran is never overwritten", async () => {
  await newIssue();
  setIssues("acme/widgets", [issue(1), issue(2), issue(3, "area:parser")]);
  startStation(answers("Billing"));
  await until(async () => (await labelJob())?.state === "done");
  expect(labels(3)).toEqual(["area:parser"]);
  expect(ghLog().some((l) => l.includes("issue edit 3 "))).toBe(false);
});

test("an answer that names no context of the map fails the job and sets nothing", async () => {
  await newIssue();
  startStation(answers("Shipping"));
  await until(async () => (await labelJob())?.state === "stuck");
  expect((await labelJob())!.reason).toContain(
    "names no context of the map: Shipping",
  );
  expect(labels(3)).toEqual([]);
});
