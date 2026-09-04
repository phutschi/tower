import type { GitInfo } from "../git.ts";
import type { Io } from "../io.ts";
import { gitInfo } from "../git.ts";
import { UsageError } from "../io.ts";
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
