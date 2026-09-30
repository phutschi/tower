/**
 * `ids`: expand a task-id spec against the open run and print the ids, one
 * per line, exactly as `assign` would record them. It writes nothing, so a
 * script can check ids the way tower reads them without recording anything.
 */
import { parseArgs } from "node:util";

import type { Io } from "../io.ts";
import { expandIds } from "../ids.ts";
import { UsageError } from "../io.ts";
import { loadState, locateRun, requireTask } from "./locate.ts";

export async function idsCommand(argv: string[], io: Io): Promise<number> {
  const { values, positionals } = parseArgs({
    args: argv,
    options: { run: { type: "string" } },
    allowPositionals: true,
  });
  const [spec] = positionals;
  if (spec === undefined)
    throw new UsageError("usage: tower ids <ids>   e.g. tower ids 5,7-9");
  const runDir = locateRun(io, values.run);
  const state = loadState(runDir, io);
  let ids: string[];
  try {
    ids = expandIds(spec);
  } catch (error) {
    throw new UsageError((error as Error).message);
  }
  for (const id of ids) requireTask(state, id);
  io.stdout(ids.map((id) => `${id}\n`).join(""));
  return 0;
}
