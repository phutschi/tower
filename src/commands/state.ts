/**
 * `state --json` and `wait`: the two commands scripts call. Both are literal
 * in every theme — a script parses states, not vocabulary.
 */
import { parseArgs } from "node:util";

import type { Io } from "../io.ts";
import { readEvents } from "../events.ts";
import { UsageError } from "../io.ts";
import { configPath, readConfig } from "../paths.ts";
import { eventsPath, readRun } from "../run.ts";
import { fold } from "../state.ts";
import { DEFAULT_STALE_MINUTES } from "../types.ts";
import { waitFor } from "../wait.ts";
import { locateRun } from "./locate.ts";

export function staleMinutes(io: Io, flag: string | undefined): number {
  if (flag !== undefined) {
    const n = Number(flag);
    if (!(n > 0))
      throw new UsageError(
        `--stale expects a positive number of minutes, got "${flag}"`,
      );
    return n;
  }
  return readConfig(configPath(io.env)).config.stale ?? DEFAULT_STALE_MINUTES;
}

export async function stateCommand(argv: string[], io: Io): Promise<number> {
  const { values } = parseArgs({
    args: argv,
    options: {
      json: { type: "boolean", default: false },
      run: { type: "string" },
      stale: { type: "string" },
    },
  });
  const runDir = locateRun(io, values.run);
  const run = readRun(runDir);
  const state = fold(run, readEvents(eventsPath(runDir), 0).lines, {
    now: io.now(),
    staleMinutes: staleMinutes(io, values.stale),
  });
  if (values.json) {
    io.stdout(`${JSON.stringify({ v: 1, runDir, ...state }, null, 2)}\n`);
    return 0;
  }
  // The plain-text board needs the theme table (Task 12) and the non-TTY
  // snapshot renderer (Task 13); until those land, --json is the only form.
  throw new UsageError(
    "tower state without --json needs the console, which arrives in a later task; use --json for now",
  );
}

export async function waitCommand(argv: string[], io: Io): Promise<number> {
  const { values } = parseArgs({
    args: argv,
    options: {
      timeout: { type: "string" },
      run: { type: "string" },
      stale: { type: "string" },
    },
  });
  if (values.timeout === undefined)
    throw new UsageError(
      "wait needs --timeout <seconds>; pick one under your harness's tool limit",
    );
  const seconds = Number(values.timeout);
  if (!(seconds > 0))
    throw new UsageError(`--timeout expects seconds, got "${values.timeout}"`);
  const runDir = locateRun(io, values.run);
  const result = await waitFor({
    runDir,
    timeoutMs: seconds * 1000,
    staleMinutes: staleMinutes(io, values.stale),
    now: io.now,
  });
  if (result.lines.length > 0) io.stdout(`${result.lines.join("\n")}\n`);
  return result.exit;
}
