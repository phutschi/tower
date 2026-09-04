/**
 * A run is a directory: `run.json` (identity, written once) and
 * `events.ndjson` (everything that happened). This module creates one, finds
 * one, and declares one finished.
 *
 * Discovery order — `--run`, `$TOWER_RUN`, then a pointer file in the
 * repository's common git directory — is what lets one global `tower` be
 * invoked from several worktrees on several branches and still land on the
 * same run, while a concurrent run in a different repository cannot collide.
 * A run is never created implicitly: the fallback is an error that prints the
 * exact `tower init` line.
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import type { AssignEvent, RunFile, TaskDef } from "./types.ts";
import { appendEvent, readEvents } from "./events.ts";
import { nearestId } from "./ids.ts";
import { UsageError } from "./io.ts";

export const RUN_FILE = "run.json";
export const EVENTS_FILE = "events.ndjson";
export const POINTER_FILE = "tower-run";

export const eventsPath = (runDir: string) => join(runDir, EVENTS_FILE);

export function callsignOf(repo: string): string {
  return (
    repo
      .toUpperCase()
      .replaceAll(/[^A-Z0-9]/g, "")
      .slice(0, 8) || "RUN"
  );
}

// UTC, not local time: the stamp must be the same run directory name
// regardless of which timezone the orchestrator's machine is in.
const stamp = (d: Date) =>
  `${d.getUTCFullYear()}${String(d.getUTCMonth() + 1).padStart(
    2,
    "0",
  )}${String(d.getUTCDate()).padStart(2, "0")}-${String(
    d.getUTCHours(),
  ).padStart(2, "0")}${String(d.getUTCMinutes()).padStart(2, "0")}`;

export function defaultRunDir(
  runsDir: string,
  repo: string,
  branch: string,
  now: Date,
): string {
  const safe = (s: string) =>
    s.replaceAll(/[^A-Za-z0-9._]+/g, "-").replaceAll(/^-|-$/g, "");
  return join(runsDir, `${safe(repo)}-${safe(branch)}-${stamp(now)}`);
}

export interface InitOptions {
  runDir: string;
  plan: string;
  planPath: string | null;
  repo: string;
  branch: string;
  callsign: string;
  theme: string;
  models: Record<string, string>;
  tasks: TaskDef[];
  lanes: Record<string, string[]>;
  now: Date;
}

/** Throws when a lane names an id that is not a task, or two lanes claim one id. */
export function validateLanes(
  lanes: Record<string, string[]>,
  tasks: readonly TaskDef[],
): void {
  const ids = new Set(tasks.map((t) => t.id));
  const owner = new Map<string, string>();
  for (const [lane, members] of Object.entries(lanes)) {
    const seenInLane = new Set<string>();
    for (const id of members) {
      if (!ids.has(id)) {
        const near = nearestId(id, [...ids]);
        throw new Error(
          `lane ${lane}: "${id}" is not a task${near ? ` — did you mean ${near}?` : ""}`,
        );
      }
      if (seenInLane.has(id))
        throw new Error(`lane ${lane}: task ${id} is listed twice`);
      seenInLane.add(id);
      const prior = owner.get(id);
      if (prior && prior !== lane)
        throw new Error(`task ${id} is assigned to both ${prior} and ${lane}`);
      owner.set(id, lane);
    }
  }
}

export function initRun(options: InitOptions): RunFile {
  validateLanes(options.lanes, options.tasks);
  const run: RunFile = {
    v: 1,
    plan: options.plan,
    planPath: options.planPath,
    repo: options.repo,
    branch: options.branch,
    callsign: options.callsign,
    theme: options.theme,
    startedAt: options.now.toISOString(),
    models: options.models,
    tasks: options.tasks,
  };
  mkdirSync(options.runDir, { recursive: true });
  writeFileSync(
    join(options.runDir, RUN_FILE),
    `${JSON.stringify(run, null, 2)}\n`,
  );
  writeFileSync(eventsPath(options.runDir), "", { flag: "a" });
  for (const [lane, laneTasks] of Object.entries(options.lanes)) {
    const event: AssignEvent = {
      v: 1,
      kind: "assign",
      ts: options.now.toISOString(),
      lane,
      tasks: laneTasks,
    };
    appendEvent(eventsPath(options.runDir), event);
  }
  return run;
}

export function readRun(runDir: string): RunFile {
  const path = join(runDir, RUN_FILE);
  let text: string;
  try {
    text = readFileSync(path, "utf8");
  } catch (err) {
    throw new UsageError(`could not read ${path}: ${(err as Error).message}`);
  }
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch {
    throw new UsageError(`${path} is not valid JSON`);
  }
  if (
    typeof raw !== "object" ||
    raw === null ||
    (raw as { v?: unknown }).v !== 1
  )
    throw new UsageError(
      `${join(runDir, RUN_FILE)} is not a tower run file (expected "v": 1)`,
    );
  return raw as RunFile;
}

export function isClosed(runDir: string): boolean {
  return readEvents(eventsPath(runDir), 0).lines.some(
    (l) => l.event?.kind === "close",
  );
}

export function closeRun(runDir: string, text: string, now: Date): void {
  appendEvent(eventsPath(runDir), {
    v: 1,
    kind: "close",
    ts: now.toISOString(),
    text,
  });
}

export function writePointer(commonDir: string, runDir: string): void {
  writeFileSync(join(commonDir, POINTER_FILE), `${runDir}\n`);
}

export function readPointer(commonDir: string): string | undefined {
  try {
    return (
      readFileSync(join(commonDir, POINTER_FILE), "utf8").trim() || undefined
    );
  } catch {
    return undefined;
  }
}

export function clearPointer(commonDir: string): void {
  try {
    writeFileSync(join(commonDir, POINTER_FILE), "");
  } catch {
    // The pointer's directory is gone or unwritable; there is nothing left
    // to point at either way, so closing still succeeds.
  }
}

export const INIT_HINT =
  "no run found — create one from the plan:\n  tower init --plan <plan.md> --lane A=<ids>\nor point at one with --run <dir> or TOWER_RUN.";

export type Resolution = { runDir: string } | { error: string };

export function resolveRun(input: {
  flag?: string | undefined;
  env: Record<string, string | undefined>;
  commonDir?: string | undefined;
}): Resolution {
  if (input.flag) return { runDir: input.flag };
  if (input.env.TOWER_RUN) return { runDir: input.env.TOWER_RUN };
  if (input.commonDir) {
    const pointed = readPointer(input.commonDir);
    if (pointed) {
      if (!existsSync(join(pointed, RUN_FILE)))
        return {
          error: `the run this repository points at no longer exists: ${pointed}\nrun \`tower init\` again, or \`--run <dir>\`.`,
        };
      return { runDir: pointed };
    }
  }
  return { error: INIT_HINT };
}
