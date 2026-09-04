import { readFileSync } from "node:fs";
import { parseArgs } from "node:util";

import type { Io } from "../io.ts";
import { composeBrief } from "../brief.ts";
import { readEvents } from "../events.ts";
import { UsageError } from "../io.ts";
import { sectionOf } from "../plan.ts";
import { eventsPath, readRun } from "../run.ts";
import { fold } from "../state.ts";
import { DEFAULT_STALE_MINUTES } from "../types.ts";
import { locateRun } from "./locate.ts";

export async function briefCommand(argv: string[], io: Io): Promise<number> {
  const { values, positionals } = parseArgs({
    args: argv,
    options: {
      run: { type: "string" },
      "conventions-heading": {
        type: "string",
        default: "Repo conventions every task must follow",
      },
    },
    allowPositionals: true,
  });
  const [lane] = positionals;
  if (!lane)
    throw new UsageError(
      "usage: tower brief <lane> [--conventions-heading <heading>]",
    );
  const runDir = locateRun(io, values.run);
  const run = readRun(runDir);
  const state = fold(run, readEvents(eventsPath(runDir), 0).lines, {
    now: io.now(),
    staleMinutes: DEFAULT_STALE_MINUTES,
  });
  const heading = values["conventions-heading"];
  let conventions: string | undefined;
  if (run.planPath) {
    try {
      conventions = sectionOf(readFileSync(run.planPath, "utf8"), heading);
    } catch {
      io.stderr(
        `tower: cannot read the plan at ${run.planPath}; the brief has no conventions section\n`,
      );
    }
  }
  let text: string;
  try {
    text = composeBrief(state, lane, conventions, heading);
  } catch (error) {
    throw new UsageError((error as Error).message);
  }
  io.stdout(text);
  return 0;
}
