import { join } from "node:path";
import { describe, expect, test } from "bun:test";

import { readEvents } from "../events.ts";
import { main } from "../main.ts";
import { seededRun } from "../testing.ts";

const events = (runDir: string) =>
  readEvents(join(runDir, "events.ndjson"), 0).lines.map((l) => l.event);

describe("tower add", () => {
  test("appends an add with the next integer id and prints the id on its own line", async () => {
    const { runDir, io } = seededRun();
    expect(await main(["add", "Wire the webhook"], io)).toBe(0);
    expect(events(runDir).at(-1)).toEqual({
      v: 1,
      kind: "add",
      ts: "2026-09-04T20:00:00.000Z",
      task: { id: "3", title: "Wire the webhook", area: "" },
      after: null,
    });
    expect(io.out[0]).toBe("3\n");
  });

  test("--id, --area and --after are carried", async () => {
    const { runDir, io } = seededRun();
    expect(
      await main(
        [
          "add",
          "Voice notes 2",
          "--id",
          "auth-2",
          "--area",
          "apps/server",
          "--after",
          "1",
        ],
        io,
      ),
    ).toBe(0);
    expect(events(runDir).at(-1)).toMatchObject({
      kind: "add",
      task: { id: "auth-2", title: "Voice notes 2", area: "apps/server" },
      after: "1",
    });
  });

  test("--lane also appends an assign with the lane's current list plus the new id", async () => {
    const { runDir, io } = seededRun();
    expect(await main(["add", "More", "--lane", "A"], io)).toBe(0);
    const last = events(runDir).slice(-2);
    expect(last[0]).toMatchObject({ kind: "add", task: { id: "3" } });
    expect(last[1]).toEqual({
      v: 1,
      kind: "assign",
      ts: "2026-09-04T20:00:00.000Z",
      lane: "A",
      tasks: ["1", "2", "3"],
    });
  });

  test("--lane for a lane that has no tasks yet creates it", async () => {
    const { runDir, io } = seededRun();
    expect(await main(["add", "New lane work", "--lane", "C"], io)).toBe(0);
    expect(events(runDir).at(-1)).toMatchObject({
      kind: "assign",
      lane: "C",
      tasks: ["3"],
    });
  });

  test("refuses a missing title, an invalid --id, a taken --id, and an unknown --after; appends nothing", async () => {
    const { runDir, io } = seededRun();
    const before = events(runDir).length;
    expect(await main(["add"], io)).toBe(1);
    expect(io.err.at(-1)).toContain('usage: tower add "<title>"');
    expect(await main(["add", "x", "--id", "bad id"], io)).toBe(1);
    expect(io.err.at(-1)).toContain("not a valid task id");
    expect(await main(["add", "x", "--id", "1"], io)).toBe(1);
    expect(io.err.at(-1)).toContain('task "1" already exists');
    expect(await main(["add", "x", "--after", "99"], io)).toBe(1);
    expect(io.err.at(-1)).toContain('unknown task "99"');
    expect(events(runDir)).toHaveLength(before);
  });

  test("a closed run refuses", async () => {
    const { io } = seededRun();
    expect(await main(["close", "over"], io)).toBe(0);
    expect(await main(["add", "late"], io)).toBe(1);
    expect(io.err.at(-1)).toContain("closed");
  });
});

describe("tower change", () => {
  test("appends a change with null for fields not given", async () => {
    const { runDir, io } = seededRun();
    expect(await main(["change", "2", "--title", "The other gate"], io)).toBe(
      0,
    );
    expect(events(runDir).at(-1)).toEqual({
      v: 1,
      kind: "change",
      ts: "2026-09-04T20:00:00.000Z",
      task: "2",
      title: "The other gate",
      area: null,
      after: null,
    });
    expect(io.out.join("")).toContain("changed task 2");
  });

  test("with no flags is a usage error; an unknown id suggests the nearest; after itself is refused", async () => {
    const { runDir, io } = seededRun();
    const before = events(runDir).length;
    expect(await main(["change", "2"], io)).toBe(1);
    expect(io.err.at(-1)).toContain("usage: tower change <id>");
    expect(await main(["change", "auth1", "--title", "x"], io)).toBe(1);
    expect(io.err.at(-1)).toContain("did you mean auth-1");
    expect(await main(["change", "2", "--after", "2"], io)).toBe(1);
    expect(io.err.at(-1)).toContain("after itself");
    expect(events(runDir)).toHaveLength(before);
  });
});

describe("tower remove", () => {
  test("appends a remove for a pending task", async () => {
    const { runDir, io } = seededRun();
    expect(await main(["remove", "2"], io)).toBe(0);
    expect(events(runDir).at(-1)).toEqual({
      v: 1,
      kind: "remove",
      ts: "2026-09-04T20:00:00.000Z",
      task: "2",
    });
    expect(io.out.join("")).toContain("removed task 2");
  });

  test("refuses an in_progress task, quoting its last note, unless --force", async () => {
    const { runDir, io } = seededRun();
    await main(
      ["task", "2", "in_progress", "implementing", "halfway", "--model", "m"],
      io,
    );
    const before = events(runDir).length;
    expect(await main(["remove", "2"], io)).toBe(1);
    expect(io.err.at(-1)).toContain("in_progress");
    expect(io.err.at(-1)).toContain("halfway");
    expect(io.err.at(-1)).toContain("--force");
    expect(events(runDir)).toHaveLength(before);
    expect(await main(["remove", "2", "--force"], io)).toBe(0);
    expect(events(runDir).at(-1)).toMatchObject({ kind: "remove", task: "2" });
  });

  test("an unknown id is refused", async () => {
    const { io } = seededRun();
    expect(await main(["remove", "99"], io)).toBe(1);
    expect(io.err.at(-1)).toContain('unknown task "99"');
  });
});
