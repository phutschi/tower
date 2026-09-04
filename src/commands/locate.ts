import type { Io } from "../io.ts";
import { gitInfo } from "../git.ts";
import { UsageError } from "../io.ts";
import { resolveRun } from "../run.ts";

/** The run this invocation is about, or a usage error with exit 2. */
export function locateRun(io: Io, flag?: string): string {
  const resolution = resolveRun({
    flag,
    env: io.env,
    commonDir: gitInfo(io.cwd).commonDir,
  });
  if ("error" in resolution) throw new UsageError(resolution.error, 2);
  return resolution.runDir;
}
