import type { GitInfo } from "../git.ts";
import type { Io } from "../io.ts";
import type { State } from "../state.ts";
import { readEvents } from "../events.ts";
import { gitInfo } from "../git.ts";
import { nearestId } from "../ids.ts";
import { UsageError } from "../io.ts";
import { eventsPath, readRun } from "../run.ts";
import { fold } from "../state.ts";
import { DEFAULT_STALE_MINUTES } from "../types.ts";
import { resolveRun } from "../run.ts";

/**
 * The run this invocation is about, or a usage error with exit 2.
 *
 * Accepts an already-computed `GitInfo` so a caller that also needs the
 * commit sha (as `tower task` does) spawns `git` once, not twice.
 */
export function locateRun(
  io: Io,
  flag?: string,
  git: GitInfo = gitInfo(io.cwd),
): string {
  const resolution = resolveRun({
    flag,
    env: io.env,
    commonDir: git.commonDir,
  });
  if ("error" in resolution) throw new UsageError(resolution.error, 2);
  return resolution.runDir;
}

/** Read a run directory fresh and fold it — the one-shot read every command needs. */
export function loadState(
  runDir: string,
  io: Io,
  staleMinutes = DEFAULT_STALE_MINUTES,
): State {
  const run = readRun(runDir);
  const { lines } = readEvents(eventsPath(runDir), 0);
  return fold(run, lines, { now: io.now(), staleMinutes });
}

/** Refuse an unknown task id, naming the correct form and, when close, the likely typo. */
export function requireTask(state: State, id: string): void {
  const ids = state.tasks.map((t) => t.id);
  if (ids.includes(id)) return;
  const near = nearestId(id, ids);
  throw new UsageError(
    `unknown task "${id}"${near ? ` — did you mean ${near}?` : ""}\n       tasks: ${ids.join(", ") || "(none)"}`,
  );
}
