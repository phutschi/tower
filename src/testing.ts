/**
 * Test doubles shared by the command tests. Not shipped: `package.json`
 * `files` lists `dist` only, and this module is never imported by `src/`
 * code that is not a test.
 */
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import type { Io } from "./io.ts";
import type { TaskDef } from "./types.ts";
import { initRun } from "./run.ts";

export interface FakeIo extends Io {
  out: string[];
  err: string[];
}

// State and config dirs for every fakeIo, so a run without --run never lands
// in the real ~/.local/state and no real config or theme leaks into a test.
// Made once and shared: run dirs carry a random repo name, so they don't
// collide.
let xdg: { XDG_STATE_HOME: string; XDG_CONFIG_HOME: string } | undefined;

export function fakeIo(overrides: Partial<Io> = {}): FakeIo {
  xdg ??= {
    XDG_STATE_HOME: mkdtempSync(join(tmpdir(), "tower-state-")),
    XDG_CONFIG_HOME: mkdtempSync(join(tmpdir(), "tower-config-")),
  };
  // A test's own env is laid over them.
  const env = { ...xdg, ...overrides.env };
  const io: FakeIo = {
    out: [],
    err: [],
    stdout: (t) => io.out.push(t),
    stderr: (t) => io.err.push(t),
    cwd: mkdtempSync(join(tmpdir(), "tower-cwd-")),
    now: () => new Date("2026-09-04T20:00:00.000Z"),
    isTTY: false,
    columns: 100,
    rows: 30,
    stdinText: () => undefined,
    ...overrides,
    env,
  };
  return io;
}

export const TASKS: TaskDef[] = [
  { id: "1", title: "The shared prompt shortcuts", area: "packages/core" },
  { id: "2", title: "The gate", area: "apps/server" },
  { id: "auth-1", title: "Voice notes", area: "apps/server" },
];

/** A run on disk, and an Io whose TOWER_RUN points at it. */
export function seededRun(
  lanes: Record<string, string[]> = { A: ["1", "2"], B: ["auth-1"] },
) {
  const runDir = join(mkdtempSync(join(tmpdir(), "tower-run-")), "r");
  initRun({
    runDir,
    plan: "Widgets Implementation Plan",
    planPath: null,
    repo: "acme",
    branch: "feature/widgets",
    callsign: "ACME",
    theme: "airport",
    models: {
      implementer: "sonnet",
      "spec-reviewer": "sonnet",
      "quality-reviewer": "opus",
    },
    tasks: TASKS,
    lanes,
    now: new Date("2026-09-04T19:00:00.000Z"),
  });
  const io = fakeIo({ env: { TOWER_RUN: runDir } });
  return { runDir, io };
}
