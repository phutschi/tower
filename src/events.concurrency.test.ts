import { spawn } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "bun:test";

import { readEvents } from "./events.ts";

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
