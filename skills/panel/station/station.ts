/**
 * A station (ADR 0017): claims jobs from the hub for the kinds it has runners
 * for, works each in its own workspace, renews each lease while the job runs,
 * and posts the job's events and result. The hub decides how many jobs this
 * Mac takes and whether it takes any.
 */
import type { Job, JobKind, JobResult } from "../types.ts";
import { CheckoutExecutor, type Executor, type Workspace } from "./executor.ts";

export type { Workspace } from "./executor.ts";

export interface JobContext {
  job: Job;
  /** The hub this station reports to, for a job that reads the Panel. */
  hubUrl: string;
  workspace: Workspace;
  /** Sends an event; the hub gets it in order, later if it is down now. */
  emit(kind: string, data: Record<string, unknown>): Promise<void>;
  /**
   * Sends an event an action depends on: resolves once the hub has stored it,
   * waiting while the hub is down. Rejects when the hub refuses it (this
   * station holds the job no more) or the job is aborted meanwhile.
   */
  checkpoint(kind: string, data: Record<string, unknown>): Promise<void>;
  signal: AbortSignal;
}
export type JobRunner = (
  ctx: JobContext,
) => Promise<Omit<JobResult, "jobId" | "durationMs">>;

const runners = new Map<JobKind, JobRunner>();

/** How long a stopped or failed job's checkout, and any run's, is kept. */
const KEEP_HOURS = 24;

/**
 * Why the station stopped a job, when the user stopped it (moved its issue
 * back or closed it); null when the job was aborted for another reason (the
 * hub ended it, or the station quits).
 */
export function stopReason(signal: AbortSignal): string | null {
  const reason: unknown = signal.reason;
  return typeof reason === "object" && reason !== null && "stop" in reason
    ? String(reason.stop)
    : null;
}

/** Makes this station take jobs of `kind`; a kind with no runner is never claimed. */
export function registerJobRunner(kind: JobKind, runner: JobRunner): void {
  runners.set(kind, runner);
}

interface Control {
  stop: boolean;
  reason: string | null;
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
  const executor: Executor = new CheckoutExecutor(opts.workdir);
  const running = new Map<
    string,
    {
      abort: AbortController;
      done: Promise<void>;
      ended?: boolean;
      stopped?: boolean;
    }
  >();

  const call = (path: string, body: unknown) =>
    fetch(`${opts.hubUrl}${path}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ station: opts.name, ...(body as object) }),
    });

  // Events and results wait here, in order, until the hub takes them: a hub
  // that is down loses nothing a station sent.
  // A checkpoint's entry is settled once the hub took or refused it.
  const outbox: {
    path: string;
    body: unknown;
    settle?: (refused?: Error) => void;
  }[] = [];
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
        const sent = outbox.shift()!;
        if (res.ok) sent.settle?.();
        else {
          const why = `the hub refused ${sent.path}: ${await res.text()}`;
          console.error(`station: ${why}`);
          sent.settle?.(new Error(why));
        }
      }
    })().finally(() => (flushing = undefined)));

  const work = async (job: Job, abort: AbortController) => {
    const started = Date.now();
    const event = (kind: string, data: Record<string, unknown>) => ({
      path: `/api/jobs/${job.id}/events`,
      body: { ts: new Date().toISOString(), kind, data },
    });
    const emit = (kind: string, data: Record<string, unknown>) => {
      outbox.push(event(kind, data));
      return flush();
    };
    const checkpoint = (kind: string, data: Record<string, unknown>) =>
      new Promise<void>((resolve, reject) => {
        const aborted = () =>
          reject(new Error(`aborted before the hub stored its ${kind}`));
        if (abort.signal.aborted) return aborted();
        abort.signal.addEventListener("abort", aborted, { once: true });
        outbox.push({
          ...event(kind, data),
          settle: (refused) => (refused ? reject(refused) : resolve()),
        });
        void flush();
      });
    let result: Omit<JobResult, "jobId" | "durationMs"> | undefined;
    let workspace: Workspace | undefined;
    try {
      workspace = await executor.prepare(job);
      result = await runners.get(job.kind)!({
        job,
        hubUrl: opts.hubUrl,
        workspace,
        emit,
        checkpoint,
        signal: abort.signal,
      });
    } catch (err) {
      result = { outcome: "failed", reason: String(err) };
    }
    const stop = stopReason(abort.signal);
    // The runner's own stopped result says more (a workspace left open).
    if (stop !== null && result.outcome !== "stopped")
      result = {
        outcome: "stopped",
        reason: stop,
        ...(result.sessionId ? { sessionId: result.sessionId } : {}),
      };
    // A stopped or failed job's checkout stays a day for a look at what it
    // did; so does a run's, whose orchestrator lives on in its own workspace
    // after the station lets go. A job handed back to the queue keeps none:
    // its next try starts over.
    const keep =
      job.kind === "run" || (result.outcome !== "done" && !leaving)
        ? KEEP_HOURS
        : 0;
    if (workspace)
      await executor.release(workspace, keep).catch((err: unknown) => {
        console.error(`station: releasing ${workspace.path}: ${String(err)}`);
      });
    const { ended } = running.get(job.id) ?? {};
    running.delete(job.id);
    // A station that quits posts no result: the lease runs out and the job
    // waits in the queue for the next station. A job the hub ended has its
    // result already.
    if (leaving || ended) return;
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
    for (const [id, job] of running) {
      const res = await call(`/api/jobs/${id}/heartbeat`, {}).catch(() => null);
      // 409: the job is no longer this station's (the hub ended it): let go.
      if (res?.status === 409 && !job.ended) {
        job.ended = true;
        job.abort.abort();
        continue;
      }
      // The user stopped it: moved its issue back, or closed it.
      const control = await fetch(`${opts.hubUrl}/api/jobs/${id}/control`)
        .then((r) => (r.ok ? (r.json() as Promise<Control>) : null))
        .catch(() => null);
      if (control?.stop && !job.stopped) {
        job.stopped = true;
        job.abort.abort({ stop: control.reason ?? "stopped" });
      }
    }
    await executor.prune().catch((err: unknown) => {
      console.error(`station: pruning kept checkouts: ${String(err)}`);
    });
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
