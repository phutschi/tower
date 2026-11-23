/**
 * A station process for seam 2: the real runStation with fake runners for the
 * kinds in FAKE_KINDS. Each fake job emits its workspace and two steps, then
 * waits for WORKDIR/release-<job id>: empty to finish, "fail" to fail. With
 * FAKE_CHECKPOINT=1 it first waits for WORKDIR/checkpoint-<job id>, sends a
 * "spec" checkpoint, and once the hub has it writes WORKDIR/acted-<job id>.
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { registerJobRunner, runStation } from "../station/station.ts";
import type { JobKind } from "../types.ts";

const env = (name: string) => process.env[name] ?? "";
const workdir = env("WORKDIR");

for (const kind of env("FAKE_KINDS").split(",").filter(Boolean))
  registerJobRunner(
    kind as JobKind,
    async ({ job, workspace, emit, checkpoint, signal }) => {
      await emit("workspace", {
        path: workspace.path,
        branch: workspace.branch,
        pid: process.pid,
      });
      await emit("step", { n: 1 });
      await emit("step", { n: 2 });
      if (env("FAKE_CHECKPOINT") === "1") {
        const at = join(workdir, `checkpoint-${job.id}`);
        while (!existsSync(at) && !signal.aborted) await Bun.sleep(20);
        await checkpoint("spec", { n: 3 });
        writeFileSync(join(workdir, `acted-${job.id}`), "");
      }
      const release = join(workdir, `release-${job.id}`);
      while (!existsSync(release) && !signal.aborted) await Bun.sleep(20);
      if (readFileSync(release, "utf8").trim() === "fail")
        return { outcome: "failed", reason: "boom" };
      return {
        outcome: "done",
        sessionId: `session-${job.id}`,
        tokens: { input: 10, output: 5 },
      };
    },
  );

const station = await runStation({
  hubUrl: env("HUB_URL"),
  name: env("STATION_NAME"),
  workdir,
  heartbeatMs: 50,
});
process.on("SIGTERM", () => void station.stop().then(() => process.exit(0)));
