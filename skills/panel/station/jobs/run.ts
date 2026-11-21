/**
 * The run job: opens the run's workspace through the orchestrate kit's
 * start-run.sh, which starts an orchestrator there with the brief, then
 * forwards the run's tower record as job events until the hub ends the job
 * (its PR is ready). A run the user stops has its workspace closed through
 * the kit's stop-run.sh.
 */
import { execFile } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

import type { Job } from "../../types.ts";
import type { Workspace } from "../executor.ts";
import { registerJobRunner, stopReason } from "../station.ts";

const run = promisify(execFile);
const KIT = join(import.meta.dir, "../../../orchestrate");
const START_RUN = join(KIT, "start-run.sh");
const STOP_RUN = join(KIT, "stop-run.sh");
const TEMPLATE = join(import.meta.dir, "../../prompts/run-brief.md");
// How often the run's tower state is read; tests set it short.
const POLL_MS = Number(process.env.PANEL_RUN_POLL_MS) || 30_000;

/** The workspace's name, after its issue: acme-widgets-12. */
export const workspaceName = (job: Job) =>
  `${job.repo.replace("/", "-")}-${job.issues.join("-")}`;

export function brief(job: Job, ws: Workspace): string {
  const refs = job.issues.map((n) => `${job.repo}#${n}`);
  const fill: Record<string, string> = {
    issues: refs.join(", "),
    closes: job.issues.map((n) => `#${n}`).join(", "),
    thread: refs.join(" + "),
    path: ws.path,
    branch: ws.branch,
    database: ws.databaseName,
    ports: ws.ports.join(", "),
  };
  return readFileSync(TEMPLATE, "utf8").replace(
    /\{\{(\w+)\}\}/g,
    (_, key: string) => fill[key] ?? "",
  );
}

/** Resolves after `ms`, or as soon as `signal` aborts. */
const sleep = (ms: number, signal: AbortSignal) =>
  new Promise<void>((resolve) => {
    const timer = setTimeout(resolve, ms);
    signal.addEventListener("abort", () => (clearTimeout(timer), resolve()), {
      once: true,
    });
  });

registerJobRunner("run", async ({ job, workspace, emit, signal }) => {
  // Stopped while its checkout was made: start no orchestrator.
  if (signal.aborted)
    return {
      outcome: "stopped",
      reason: stopReason(signal) ?? "the station let the run go",
    };
  const name = workspaceName(job);
  const dir = mkdtempSync(join(tmpdir(), "panel-brief-"));
  const file = join(dir, "brief.md");
  writeFileSync(file, brief(job, workspace));
  let out: string;
  try {
    out = (await run(START_RUN, [name, workspace.path, file])).stdout;
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
  const opened = JSON.parse(out) as { workspace: string; pane: string };
  await emit("run-started", {
    workspace: name,
    pane: opened.pane,
    path: workspace.path,
    branch: workspace.branch,
    databaseName: workspace.databaseName,
    ports: workspace.ports,
  });
  let last = "";
  while (!signal.aborted) {
    const state = await run("tower", ["state", "--json"], {
      cwd: workspace.path,
    }).then(
      (r) => r.stdout.trim(),
      () => "", // no run recorded yet
    );
    if (state && state !== last) {
      last = state;
      await emit("tower-state", JSON.parse(state) as Record<string, unknown>);
    }
    await sleep(POLL_MS, signal);
  }
  const stop = stopReason(signal);
  if (stop === null)
    return { outcome: "stopped", reason: "the station let the run go" };
  // A workspace that stays open keeps its orchestrator working: say so.
  const left = await run(STOP_RUN, [opened.workspace]).then(
    () => "",
    (err: unknown) => `; its workspace is still open: ${String(err)}`,
  );
  return { outcome: "stopped", reason: stop + left };
});
