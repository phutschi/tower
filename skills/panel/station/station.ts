/**
 * A station (ADR 0017): claims jobs from the hub for the kinds it has runners
 * for, works each in its own workspace, renews each lease while the job runs,
 * and posts the job's events and result. The hub decides how many jobs this
 * Mac takes and whether it takes any.
 */
import type { Job, JobKind, JobResult } from "../types.ts";
import { WorktreeExecutor, type Executor, type Workspace } from "./executor.ts";

export type { Workspace } from "./executor.ts";

export interface JobContext {
  job: Job;
  workspace: Workspace;
  emit(kind: string, data: Record<string, unknown>): Promise<void>;
  signal: AbortSignal;
}
export type JobRunner = (
  ctx: JobContext,
) => Promise<Omit<JobResult, "jobId" | "durationMs">>;

const runners = new Map<JobKind, JobRunner>();

/** Makes this station take jobs of `kind`; a kind with no runner is never claimed. */
export function registerJobRunner(kind: JobKind, runner: JobRunner): void {
  runners.set(kind, runner);
}

export interface StationOptions {
  hubUrl: string;
  name: string;
  workdir: string;
  heartbeatMs: number;
}

export async function runStation(
  opts: StationOptions,
): Promise<{ stop(): Promise<void> }> {
  const executor: Executor = new WorktreeExecutor(opts.workdir);
  const running = new Map<
    string,
    { abort: AbortController; done: Promise<void> }
  >();

  const call = (path: string, body: unknown) =>
    fetch(`${opts.hubUrl}${path}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ station: opts.name, ...(body as object) }),
    });

  // Events and results wait here, in order, until the hub takes them: a hub
  // that is down loses nothing a station sent.
  const outbox: { path: string; body: unknown }[] = [];
  let flushing: Promise<void> | undefined;
  const flush = () =>
    (flushing ??= (async () => {
      while (outbox[0]) {
        let res: Response;
        try {
          res = await call(outbox[0].path, outbox[0].body);
        } catch {
          break; // unreachable: try again on the next tick
        }
        if (res.status >= 500) break;
        if (!res.ok)
          console.error(
            `station: the hub refused ${outbox[0].path}: ${await res.text()}`,
          );
        outbox.shift();
      }
    })().finally(() => (flushing = undefined)));

  const work = async (job: Job, abort: AbortController) => {
    const started = Date.now();
    const emit = (kind: string, data: Record<string, unknown>) => {
      outbox.push({
        path: `/api/jobs/${job.id}/events`,
        body: { ts: new Date().toISOString(), kind, data },
      });
      return flush();
    };
    let result: Omit<JobResult, "jobId" | "durationMs"> | undefined;
    let workspace: Workspace | undefined;
    try {
      workspace = await executor.prepare(job);
      result = await runners.get(job.kind)!({
        job,
        workspace,
        emit,
        signal: abort.signal,
      });
    } catch (err) {
      result = { outcome: "failed", reason: String(err) };
    }
    if (workspace)
      await executor.release(workspace).catch((err: unknown) => {
        console.error(`station: releasing ${workspace.path}: ${String(err)}`);
      });
    running.delete(job.id);
    // A station that quits posts no result: the lease runs out and the job
    // waits in the queue for the next station.
    if (leaving) return;
    outbox.push({
      path: `/api/jobs/${job.id}/result`,
      body: { ...result, durationMs: Date.now() - started },
    });
    await flush();
  };

  const claim = async (): Promise<Job | null> => {
    try {
      const res = await call("/api/jobs/claim", { kinds: [...runners.keys()] });
      return res.ok ? ((await res.json()) as Job | null) : null;
    } catch {
      return null;
    }
  };

  const tick = async () => {
    await flush();
    for (const id of running.keys())
      await call(`/api/jobs/${id}/heartbeat`, {}).catch(() => {});
    for (let job = await claim(); job; job = await claim()) {
      if (running.has(job.id)) continue;
      const abort = new AbortController();
      running.set(job.id, { abort, done: work(job, abort) });
    }
  };

  let stopped = false;
  let leaving = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const loop = async () => {
    await tick();
    if (!stopped) timer = setTimeout(loop, opts.heartbeatMs);
  };
  void loop();

  return {
    async stop() {
      stopped = leaving = true;
      clearTimeout(timer);
      for (const { abort } of running.values()) abort.abort();
      await Promise.all([...running.values()].map((r) => r.done));
      await flush();
    },
  };
}
