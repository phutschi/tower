import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";

import type { Event } from "./types.ts";
import { appendEvent, parseEvent, readEvents } from "./events.ts";

const dir = () => mkdtempSync(join(tmpdir(), "tower-events-"));

const report: Event = {
  v: 1,
  kind: "report",
  ts: "2026-09-04T21:04:11+02:00",
  task: "14",
  status: "in_progress",
  phase: "implementing",
  model: "sonnet-5[1m]",
  note: "",
  commit: "4f27b92",
};

describe("appendEvent", () => {
  test("writes exactly one line, newline-terminated", () => {
    const path = join(dir(), "events.ndjson");
    appendEvent(path, report);
    const text = readFileSync(path, "utf8");
    expect(text.endsWith("\n")).toBe(true);
    expect(text.split("\n").filter(Boolean)).toHaveLength(1);
    expect(JSON.parse(text)).toEqual(report);
  });

  test("creates the file when it does not exist and appends after", () => {
    const path = join(dir(), "events.ndjson");
    appendEvent(path, report);
    appendEvent(path, { ...report, status: "done" });
    expect(readFileSync(path, "utf8").split("\n").filter(Boolean)).toHaveLength(
      2,
    );
  });
});

describe("parseEvent", () => {
  test("accepts a report", () => {
    expect(parseEvent(JSON.stringify(report))).toEqual(report);
  });

  test("accepts a note", () => {
    const note: Event = {
      v: 1,
      kind: "note",
      ts: "t",
      text: "hi",
      task: null,
      lane: "A",
    };
    expect(parseEvent(JSON.stringify(note))).toEqual(note);
  });

  test("accepts an assign", () => {
    const assign: Event = {
      v: 1,
      kind: "assign",
      ts: "t",
      lane: "B",
      tasks: ["5", "7"],
    };
    expect(parseEvent(JSON.stringify(assign))).toEqual(assign);
  });

  test("accepts a close", () => {
    const close: Event = { v: 1, kind: "close", ts: "t", text: "" };
    expect(parseEvent(JSON.stringify(close))).toEqual(close);
  });

  test("returns null for a torn line", () => {
    expect(parseEvent('{"v":1,"kind":"rep')).toBeNull();
  });

  test("returns null for a non-object", () => {
    expect(parseEvent("42")).toBeNull();
  });

  test("returns null for an unknown kind", () => {
    expect(parseEvent('{"v":1,"kind":"party","ts":"t"}')).toBeNull();
  });

  test("returns null for a bad status", () => {
    expect(
      parseEvent(JSON.stringify({ ...report, status: "flying" })),
    ).toBeNull();
  });

  test("returns null for a future major version", () => {
    expect(parseEvent(JSON.stringify({ ...report, v: 2 }))).toBeNull();
  });
});

describe("readEvents", () => {
  test("reads from an offset and returns the new offset", () => {
    const path = join(dir(), "events.ndjson");
    appendEvent(path, report);
    const first = readEvents(path, 0);
    expect(first.lines).toHaveLength(1);
    expect(first.offset).toBeGreaterThan(0);
    appendEvent(path, { ...report, status: "done" });
    const second = readEvents(path, first.offset);
    expect(second.lines).toHaveLength(1);
    expect(second.lines[0]?.event?.kind).toBe("report");
    expect(second.restarted).toBe(false);
  });

  test("keeps a torn last line as unreadable rather than throwing", () => {
    const path = join(dir(), "events.ndjson");
    appendEvent(path, report);
    writeFileSync(path, '{"v":1,"kind":"re', { flag: "a" });
    const { lines } = readEvents(path, 0);
    expect(lines).toHaveLength(2);
    expect(lines[1]?.event).toBeNull();
    expect(lines[1]?.raw).toBe('{"v":1,"kind":"re');
  });

  test("a missing file is an empty log, not an error", () => {
    const { lines, offset } = readEvents(join(dir(), "nope.ndjson"), 0);
    expect(lines).toEqual([]);
    expect(offset).toBe(0);
  });

  test("an offset past the end means the file shrank: read from zero", () => {
    const path = join(dir(), "events.ndjson");
    appendEvent(path, report);
    const { lines, restarted } = readEvents(path, 10_000);
    expect(lines).toHaveLength(1);
    expect(restarted).toBe(true);
  });

  test("re-reading from the returned offset with no new writes yields nothing", () => {
    const path = join(dir(), "events.ndjson");
    appendEvent(path, report);
    const { offset } = readEvents(path, 0);
    expect(readEvents(path, offset).lines).toHaveLength(0);
  });
});
