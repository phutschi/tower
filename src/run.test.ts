import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";

import { readEvents } from "./events.ts";
import {
  callsignOf,
  closeRun,
  defaultRunDir,
  initRun,
  isClosed,
  readRun,
  resolveRun,
  writePointer,
} from "./run.ts";

const NOW = new Date("2026-09-04T19:12:00+02:00");
const tmp = (p: string) => mkdtempSync(join(tmpdir(), p));

const tasks = [
  { id: "1", title: "A", area: "" },
  { id: "2", title: "B", area: "" },
  { id: "auth-1", title: "C", area: "" },
];

describe("callsignOf", () => {
  test("upper-cases, keeps letters and digits, caps at 8", () => {
    expect(callsignOf("acme")).toBe("ACME");
    expect(callsignOf("holli-private")).toBe("HOLLIPRI");
    expect(callsignOf("my.app_2")).toBe("MYAPP2");
  });
});

describe("defaultRunDir", () => {
  // Stamped in UTC, not local time: two orchestrator machines in different
  // timezones (or CI, which runs in UTC) must derive the same run directory
  // name from the same instant.
  test("is runs/<repo>-<branch sanitised>-<stamp>", () => {
    expect(defaultRunDir("/runs", "acme", "feature/x y", NOW)).toBe(
      "/runs/acme-feature-x-y-20260904-1712",
    );
  });
});

describe("initRun", () => {
  test("writes run.json, emits the assign events, and creates the log", () => {
    const runDir = join(tmp("tower-run-"), "r");
    const run = initRun({
      runDir,
      plan: "P",
      planPath: null,
      repo: "acme",
      branch: "main",
      callsign: "ACME",
      theme: "airport",
      models: { implementer: "x" },
      tasks,
      lanes: { A: ["1", "2"], B: ["auth-1"] },
      now: NOW,
    });
    expect(run.v).toBe(1);
    expect(readRun(runDir)).toEqual(run);
    const { lines } = readEvents(join(runDir, "events.ndjson"), 0);
    expect(lines.map((l) => l.event?.kind)).toEqual(["assign", "assign"]);
  });

  test("rejects a lane naming an id that is not a task, suggesting the nearest", () => {
    expect(() =>
      initRun({
        runDir: join(tmp("tower-run-"), "r"),
        plan: "P",
        planPath: null,
        repo: "acme",
        branch: "main",
        callsign: "ACME",
        theme: "airport",
        models: {},
        tasks,
        lanes: { A: ["auth1"] },
        now: NOW,
      }),
    ).toThrow(/auth-1/);
  });

  test("rejects an id assigned to two lanes", () => {
    expect(() =>
      initRun({
        runDir: join(tmp("tower-run-"), "r"),
        plan: "P",
        planPath: null,
        repo: "acme",
        branch: "main",
        callsign: "ACME",
        theme: "airport",
        models: {},
        tasks,
        lanes: { A: ["1"], B: ["1"] },
        now: NOW,
      }),
    ).toThrow(/both A and B/);
  });
});

describe("close and isClosed", () => {
  test("a fresh run is open; closeRun appends a close event", () => {
    const runDir = join(tmp("tower-run-"), "r");
    initRun({
      runDir,
      plan: "P",
      planPath: null,
      repo: "acme",
      branch: "main",
      callsign: "ACME",
      theme: "airport",
      models: {},
      tasks,
      lanes: {},
      now: NOW,
    });
    expect(isClosed(runDir)).toBe(false);
    closeRun(runDir, "shipped", NOW);
    expect(isClosed(runDir)).toBe(true);
  });
});

describe("resolveRun", () => {
  test("--run wins", () => {
    expect(
      resolveRun({ flag: "/x", env: { TOWER_RUN: "/y" }, commonDir: "/z" }),
    ).toEqual({ runDir: "/x" });
  });
  test("then TOWER_RUN", () => {
    expect(resolveRun({ env: { TOWER_RUN: "/y" }, commonDir: "/z" })).toEqual({
      runDir: "/y",
    });
  });
  test("then the pointer in the git common dir", () => {
    const common = tmp("tower-common-");
    const runDir = join(tmp("tower-run-"), "r");
    initRun({
      runDir,
      plan: "P",
      planPath: null,
      repo: "acme",
      branch: "main",
      callsign: "ACME",
      theme: "airport",
      models: {},
      tasks,
      lanes: {},
      now: NOW,
    });
    writePointer(common, runDir);
    expect(resolveRun({ env: {}, commonDir: common })).toEqual({ runDir });
  });
  test("otherwise says exactly what to run", () => {
    const result = resolveRun({ env: {}, commonDir: tmp("tower-common-") });
    expect("error" in result && result.error).toContain("tower init");
  });
  test("a pointer to a run that no longer exists is reported, not followed blindly", () => {
    const common = tmp("tower-common-");
    writePointer(common, join(tmp("gone-"), "nope"));
    const result = resolveRun({ env: {}, commonDir: common });
    expect("error" in result && result.error).toContain("no longer exists");
  });
});
