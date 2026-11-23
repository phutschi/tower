/**
 * The run job: opens the run's workspace through the orchestrate kit's
 * start-run.sh, which starts an orchestrator there with the brief, then
 * forwards the run's tower record as job events until the hub ends the job
 * (its PR is ready). A run the user stops has its workspace closed through
 * the kit's stop-run.sh. A run whose orchestrator exited, or that made no
 * progress for the repo's stale threshold while waiting on no answer, is
 * stuck: the job fails and frees the station.
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
const RUN_STATE = join(KIT, "run-state.sh");
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
    // GitHub links an issue to the PR only with a keyword of its own.
    closes: job.issues.map((n) => `Closes #${n}`).join(", "),
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
  const opened = JSON.parse(out) as {
    workspace: string;
    pane: string;
    agent: string;
  };
  await emit("run-started", {
    workspace: name,
    pane: opened.pane,
    path: workspace.path,
    branch: workspace.branch,
    databaseName: workspace.databaseName,
    ports: workspace.ports,
  });
  // The orchestrator and the repo's stale threshold; null when the kit
  // cannot say, which counts as alive.
  const health = () =>
    run(RUN_STATE, [opened.agent], { cwd: workspace.path }).then(
      (r) => JSON.parse(r.stdout) as { agent: string; stale: number },
      () => null,
    );
  let last = "";
  let tasks: { status?: string }[] = [];
  let sent = 0; // transcript entries sent so far
  let progress = Date.now();
  while (!signal.aborted) {
    const state = await run("tower", ["state", "--json"], {
      cwd: workspace.path,
    }).then(
      (r) => r.stdout.trim(),
      () => "", // no run recorded yet
    );
    if (state && state !== last) {
      last = state;
      const read = JSON.parse(state) as Record<string, unknown>;
      tasks = Array.isArray(read.tasks) ? (read.tasks as typeof tasks) : [];
      const transcript = Array.isArray(read.transcript) ? read.transcript : [];
      if (transcript.length < sent) sent = 0; // another run's record
      // Progress is a new event; tower marking a quiet task stale is not.
      if (transcript.length !== sent) progress = Date.now();
      // The board as it is now, and only the transcript entries not sent yet.
      await emit("tower-state", {
        ...read,
        transcript: transcript.slice(sent),
      });
      sent = transcript.length;
    }
    const now = await health();
    if (now?.agent === "gone")
      return { outcome: "failed", reason: "its orchestrator exited" };
    // A working orchestrator makes progress (planning has no record yet).
    // So does an idle one with a blocked task: it waits on an answer. One
    // blocked itself (a prompt nobody answers) does not.
    if (
      now?.agent === "working" ||
      (now?.agent === "idle" && tasks.some((t) => t.status === "blocked"))
    )
      progress = Date.now();
    else if (now && Date.now() - progress > now.stale * 60_000)
      return { outcome: "failed", reason: `no progress for ${now.stale} min` };
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
