/**
 * The run job: opens the run's workspace through the orchestrate kit's
 * start-run.sh, which starts an orchestrator there with the brief, then
 * forwards the run's tower record as job events until the hub ends the job
 * (its PR is ready). A run the user stops has its workspace closed through
 * the kit's stop-run.sh. A run whose orchestrator exited, or that made no
 * progress for the repo's stale threshold with no question open in its Inbox
 * thread, is stuck: the job fails and frees the station; a stalled run's
 * workspace is closed, its checkout kept.
 */
import { execFile } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

import type { Job } from "../../types.ts";
import type { Workspace } from "../executor.ts";
import { waitsOnPerson } from "../inbox.ts";
import { wait } from "../retry.ts";
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

/** A kit or tower call that hangs is killed: it would hold the run's checks. */
const BOUNDED = { timeout: 60_000, killSignal: "SIGKILL" } as const;

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
    run(RUN_STATE, [opened.agent], { cwd: workspace.path, ...BOUNDED }).then(
      (r) => JSON.parse(r.stdout) as { agent: string; stale: number },
      () => null,
    );
  // Closes the run's workspace; what is wrong when it stays open.
  const close = () =>
    run(STOP_RUN, [opened.workspace]).then(
      () => "",
      (err: unknown) => `; its workspace is still open: ${String(err)}`,
    );
  const thread = job.issues.map((n) => `${job.repo}#${n}`).join(" + ");
  let last = "";
  let sent = 0; // transcript entries sent so far
  let stale = 30; // the last threshold the kit gave
  let progress = Date.now();
  while (!signal.aborted) {
    const state = await run("tower", ["state", "--json"], {
      cwd: workspace.path,
      maxBuffer: 256 * 1024 * 1024,
      ...BOUNDED,
    }).then(
      (r) => r.stdout.trim(),
      (err: { code?: unknown }) => {
        // A non-zero exit: no run recorded yet. Anything else is worth a line.
        if (typeof err.code !== "number")
          console.error(
            `station: reading the run's tower state: ${String(err)}`,
          );
        return "";
      },
    );
    if (state && state !== last) {
      last = state;
      const read = JSON.parse(state) as Record<string, unknown>;
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
    stale = now?.stale ?? stale;
    // A working orchestrator makes progress (planning has no record yet).
    if (now?.agent === "working") progress = Date.now();
    else if (Date.now() - progress > stale * 60_000) {
      // A question in the run's thread with no answer yet is no stall.
      if (await waitsOnPerson(thread, workspace.path).catch(() => false))
        progress = Date.now();
      else
        return {
          outcome: "failed",
          reason: `no progress for ${stale} min${await close()}`,
        };
    }
    await wait(POLL_MS, signal);
  }
  const stop = stopReason(signal);
  if (stop === null)
    return { outcome: "stopped", reason: "the station let the run go" };
  // A workspace that stays open keeps its orchestrator working: say so.
  return { outcome: "stopped", reason: stop + (await close()) };
});
