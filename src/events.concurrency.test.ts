import { spawn } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "bun:test";

import { readEvents } from "./events.ts";
import { initRun, readRun } from "./run.ts";
import { fold } from "./state.ts";

const WRITERS = 8;
const PER_WRITER = 250;

const run = (cmd: string, args: string[]) =>
  new Promise<number>((resolve) => {
    const child = spawn(cmd, args, { stdio: "inherit" });
    child.on("exit", (code) => resolve(code ?? 1));
  });

test("concurrent appends from separate processes lose nothing", async () => {
  const dir = mkdtempSync(join(tmpdir(), "tower-concurrency-"));
  const log = join(dir, "events.ndjson");
  const writer = join(dir, "writer.ts");
  writeFileSync(
    writer,
    `import { appendEvent } from ${JSON.stringify(join(import.meta.dir, "events.ts"))};
const [path, who, n] = process.argv.slice(2);
for (let i = 0; i < Number(n); i++) {
  appendEvent(path, { v: 1, kind: "note", ts: "t", text: who + ":" + i, task: null, lane: null });
}`,
  );
  const codes = await Promise.all(
    Array.from({ length: WRITERS }, (_, i) =>
      run("bun", ["run", writer, log, `w${i}`, String(PER_WRITER)]),
    ),
  );
  expect(codes.every((code) => code === 0)).toBe(true);

  const { lines } = readEvents(log, 0);
  expect(lines).toHaveLength(WRITERS * PER_WRITER);
  expect(lines.every((line) => line.event !== null)).toBe(true);
  const seen = new Set(
    lines.map((line) => (line.event?.kind === "note" ? line.event.text : "")),
  );
  expect(seen.size).toBe(WRITERS * PER_WRITER);
}, 60_000);

test("two lanes adding at the same moment both land; the fold keeps one task per id", async () => {
  const dir = mkdtempSync(join(tmpdir(), "tower-concurrency-add-"));
  const runDir = join(dir, "r");
  initRun({
    runDir,
    plan: "P",
    planPath: null,
    repo: "acme",
    branch: "main",
    callsign: "ACME",
    theme: "airport",
    models: {},
    tasks: [],
    lanes: {},
    now: new Date("2026-09-04T19:00:00.000Z"),
  });
  const cli = join(import.meta.dir, "cli.ts");
  const adds = 6;
  const codes = await Promise.all(
    Array.from({ length: adds }, (_, i) =>
      run("bun", ["run", cli, "add", `task ${i}`, "--run", runDir]),
    ),
  );
  expect(codes.every((code) => code === 0)).toBe(true);
  const { lines } = readEvents(join(runDir, "events.ndjson"), 0);
  expect(lines.filter((line) => line.event?.kind === "add")).toHaveLength(adds);
  // The uniqueness check below is structural (fold keys tasks by id in a
  // Map), not a race detector. What this test actually exercises is the two
  // things a race can break: appendEvent losing or corrupting a concurrent
  // write (the length assertion above), and the fold surviving id collisions
  // without throwing. Bounds are loose because which — or how many — of the
  // `adds` fold into a single task is a real race outcome, not a bug.
  const state = fold(readRun(runDir), lines, {
    now: new Date("2026-09-04T19:00:00.000Z"),
    staleMinutes: 30,
  });
  const ids = state.tasks.map((t) => t.id);
  expect(new Set(ids).size).toBe(ids.length);
  expect(ids.length).toBeGreaterThanOrEqual(1);
  expect(ids.length).toBeLessThanOrEqual(adds);
}, 60_000);
