/**
 * The hub (ADR 0017): serves the Panel and its HTTP API, holds the job queue,
 * and checks GitHub on a timer, since a tailnet-only Panel gets no webhooks.
 */
import {
  JOB_KINDS,
  STAGES,
  type Job,
  type JobResult,
  type PanelIssue,
  type Stage,
} from "../types.ts";
import { isStageLabel, record, sync } from "./dispatcher.ts";
import { GitHub } from "./github.ts";
import { sendInboxNote } from "./inbox.ts";
import { renderPanel } from "./panel-page.ts";
import { ACTIVE, Store, type SnapshotIssue } from "./store.ts";

export interface HubOptions {
  dbPath: string;
  host: string;
  port: number;
  pollMs: number;
  ghBin?: string;
  now?: () => Date;
  /** How long a claim holds without a heartbeat. */
  leaseMs?: number;
  /** The server Mac's station, the one switched on from the start. */
  serverStation?: string;
  plannotatorBin?: string;
}
export interface Hub {
  url: string;
  stop(): Promise<void>;
}

const bad = (error: string, status = 400) =>
  Response.json({ error }, { status });

/**
 * A request's JSON object body; anything else reads as an empty one. Only an
 * application/json body counts: another site's page cannot send one without
 * the browser asking the hub first, so it cannot move a stage.
 */
async function body(req: Request): Promise<Record<string, unknown>> {
  if (!req.headers.get("content-type")?.startsWith("application/json"))
    return {};
  const value: unknown = await req.json().catch(() => null);
  return value && typeof value === "object"
    ? (value as Record<string, unknown>)
    : {};
}

const NAME = /^[\w.-]+$/;
const isObject = (v: unknown): v is Record<string, unknown> =>
  typeof v === "object" && v !== null && !Array.isArray(v);
const isCount = (v: unknown): v is number =>
  typeof v === "number" && Number.isInteger(v) && v >= 0;

/** A result body, checked field by field; null when it is not one. */
function jobResult(id: string, b: Record<string, unknown>): JobResult | null {
  const { outcome, reason, sessionId, durationMs, tokens } = b;
  if (outcome !== "done" && outcome !== "failed" && outcome !== "stopped")
    return null;
  if (!isCount(durationMs)) return null;
  const r: JobResult = { jobId: id, outcome, durationMs };
  if (typeof reason === "string") r.reason = reason;
  if (typeof sessionId === "string") r.sessionId = sessionId;
  if (isObject(tokens) && isCount(tokens.input) && isCount(tokens.output))
    r.tokens = { input: tokens.input, output: tokens.output };
  return r;
}

/** The stage a job of each kind works an issue in: stuck there, it shows stuck. */
const WORKS_IN: Partial<Record<Job["kind"], Stage>> = {
  grill: "shaping",
  run: "in-progress",
};

/**
 * An issue as the Panel shows it. Its job is the one not over yet, or a
 * stuck one: the issue's last job, stuck in the stage it worked in, until a
 * move starts another.
 */
function panelIssue(i: SnapshotIssue, jobs: Job[]): PanelIssue {
  const area = i.labels.find((l) => l.startsWith("area:"));
  const mine = jobs.filter(
    (j) => j.repo === i.repo && j.issues.includes(i.number),
  );
  const last = mine.at(-1);
  const stuck =
    last?.state === "stuck" && WORKS_IN[last.kind] === i.stage ? last : null;
  const job = stuck ?? mine.filter((j) => ACTIVE.includes(j.state)).at(-1);
  return {
    repo: i.repo,
    number: i.number,
    title: i.title,
    stage: i.stage,
    issueArea: area ? area.slice("area:".length) : null,
    bundleId: null,
    blockedBy: [],
    jobId: job?.id ?? null,
    stuck: stuck !== null,
  };
}

export async function startHub(opts: HubOptions): Promise<Hub> {
  const now = opts.now ?? (() => new Date());
  const store = new Store(opts.dbPath);
  const github = new GitHub(opts.ghBin);
  const leaseMs = opts.leaseMs ?? 90_000;
  const leaseUntil = () => new Date(now().getTime() + leaseMs);
  // A stuck run gets one Inbox note; one that fails to send is tried again
  // on the next sweep.
  let noting = false;
  const noteStuck = async () => {
    if (noting) return;
    noting = true;
    try {
      for (const run of store.unnotedStuckRuns()) {
        const refs = run.issues.map((n) => `${run.repo}#${n}`);
        await sendInboxNote({
          thread: refs.join(" + "),
          subject: `Stuck: ${refs.join(", ")}`,
          body: [
            `The run for ${refs.join(", ")} is stuck: ${run.reason ?? "no reason given"}.`,
            "It is not tried again. Move the issue back to ready-for-agent to start a new run.",
            ...(run.sessionId ? [`Its session: ${run.sessionId}`] : []),
          ].join("\n\n"),
          idempotencyKey: `stuck-${run.id}`,
          ...(opts.plannotatorBin
            ? { plannotatorBin: opts.plannotatorBin }
            : {}),
        });
        store.markNoted(run.id);
      }
    } catch (err) {
      console.error(`hub: an Inbox note failed: ${String(err)}`);
    } finally {
      noting = false;
    }
  };
  const sweep = () => {
    store.expireLeases(now());
    void noteStuck();
  };
  // The hub was down, not its stations: they get a lease's time to report.
  store.renewLeases(leaseUntil());
  sweep();
  const sweeper = setInterval(sweep, Math.max(leaseMs / 4, 10));

  // Polls and moves run one at a time, so a poll that read GitHub before a
  // move never writes its older stage over the move.
  let chain: Promise<unknown> = Promise.resolve();
  const serial = <T>(fn: () => Promise<T>): Promise<T> => {
    const next = chain.then(fn, fn);
    chain = next.catch(() => {});
    return next;
  };

  /**
   * Sets an issue's stage label on GitHub and records it; throws when gh
   * fails. Callers run it inside serial().
   */
  const setStage = async (prev: SnapshotIssue, stage: Stage) => {
    // GitHub's labels now, not the last poll's: a job may have moved it.
    let labels = await github.labels(prev.repo, prev.number);
    const remove = labels.filter((l) => isStageLabel(l) && l !== stage);
    await github.editLabels(prev.repo, prev.number, [stage], remove);
    labels = labels.filter((l) => !remove.includes(l));
    if (!labels.includes(stage)) labels.push(stage);
    record(store, { ...prev, stage, labels }, now());
  };

  /** Sets a stage the hub itself owns (in-progress, in-review) on each of a job's issues. */
  const setStages = async (job: Job, stage: Stage) => {
    for (const n of job.issues) {
      const prev = store.issue(job.repo, n);
      if (prev && prev.stage !== "closed") await setStage(prev, stage);
    }
  };

  /**
   * Keeps each claimed run's issues true on GitHub. Issues still in
   * ready-for-agent get in-progress (the claim's own try may have failed). A
   * run whose issues one ready (not draft) PR opened since the run closes is
   * over: its issues go to in-review and the job is done. Until the labels
   * are set the job stays claimed, so a gh failure is tried again on the next
   * poll. An older PR is the work of an earlier run or of a person.
   */
  const followRuns = async (repo: string) => {
    const runs = store
      .jobs()
      .filter(
        (j) => j.kind === "run" && j.state === "claimed" && j.repo === repo,
      );
    if (runs.length === 0) return;
    for (const run of runs)
      if (
        run.issues.some(
          (n) => store.issue(repo, n)?.stage === "ready-for-agent",
        )
      )
        await setStages(run, "in-progress");
    const pulls = await github.readyPulls(repo);
    for (const run of runs)
      if (
        pulls.some(
          (p) =>
            Date.parse(p.createdAt) > Date.parse(run.createdAt) &&
            run.issues.every((n) => p.closes.includes(n)),
        )
      ) {
        await setStages(run, "in-review");
        store.finishClaimed(run.id, now());
      }
  };

  const poll = () =>
    serial(async () => {
      for (const { name } of store.repos()) {
        try {
          sync(store, name, await github.openIssues(name), now());
          await followRuns(name);
        } catch (err) {
          console.error(`hub: polling ${name} failed: ${String(err)}`);
        }
      }
    });

  let stopped = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const loop = async () => {
    await poll();
    if (!stopped) timer = setTimeout(loop, opts.pollMs);
  };

  const issues = () => {
    const jobs = store.jobs();
    return store.issues().map((i) => panelIssue(i, jobs));
  };

  /** The Panel's one write: the stage label of the issue the user moved (ADR 0003). */
  const move = (repo: string, number: number, stage: Stage) =>
    serial(async () => {
      const prev = store.issue(repo, number);
      if (!prev) return bad(`${repo}#${number} is not on the Panel`);
      if (prev.stage === "closed") return bad(`${repo}#${number} is closed`);
      try {
        await setStage(prev, stage);
      } catch (err) {
        return bad(`gh refused the move: ${String(err)}`, 502);
      }
      return Response.json(
        issues().find((i) => i.repo === repo && i.number === number),
      );
    });

  const server = Bun.serve({
    hostname: opts.host,
    port: opts.port,
    routes: {
      "/": {
        GET: () => {
          const panelIssues = issues();
          return new Response(
            renderPanel({
              issues: panelIssues,
              stuckReasons: Object.fromEntries(
                panelIssues
                  .filter((i) => i.stuck && i.jobId)
                  .map((i) => [i.jobId, store.job(i.jobId!)?.reason ?? ""]),
              ),
              repos: store.repos().map((r) => r.name),
              stations: store.stations(),
              jobs: store
                .jobs()
                .slice(-30)
                .reverse()
                .map((j) => ({ ...j, events: store.events(j.id) })),
            }),
            { headers: { "content-type": "text/html; charset=utf-8" } },
          );
        },
      },
      "/api/issues": { GET: () => Response.json(issues()) },
      "/api/issues/:owner/:repo/:number/stage": {
        POST: async (req) => {
          const { owner, repo, number } = req.params;
          const { stage } = await body(req);
          if (!STAGES.includes(stage as Stage) || stage === "closed")
            return bad("stage must be a stage other than closed");
          return move(`${owner}/${repo}`, Number(number), stage as Stage);
        },
      },
      "/api/jobs": { GET: () => Response.json(store.jobs()) },
      "/api/jobs/claim": {
        POST: async (req) => {
          const { station, kinds } = await body(req);
          if (typeof station !== "string" || !NAME.test(station))
            return bad("station must be a name");
          if (
            !Array.isArray(kinds) ||
            !kinds.every((k) => JOB_KINDS.includes(k))
          )
            return bad("kinds must list job kinds");
          sweep();
          const s = store.station(station, opts.serverStation);
          const job = store.claim(s, kinds, now(), leaseUntil());
          // A claimed run moves its issues to in-progress; the poll tries
          // again if this fails (followRuns).
          if (job?.kind === "run")
            void serial(() => setStages(job, "in-progress")).catch((err) =>
              console.error(`hub: setting in-progress failed: ${String(err)}`),
            );
          return Response.json(job);
        },
      },
      "/api/jobs/:id": {
        GET: (req) => {
          const job = store.job(req.params.id);
          if (!job) return bad("no such job", 404);
          return Response.json({ ...job, events: store.events(job.id) });
        },
      },
      "/api/jobs/:id/control": {
        GET: (req) => {
          const control = store.control(req.params.id);
          return control ? Response.json(control) : bad("no such job", 404);
        },
      },
      "/api/jobs/:id/heartbeat": {
        POST: async (req) => {
          const { station } = await body(req);
          if (typeof station !== "string") return bad("station must be a name");
          return store.heartbeat(req.params.id, station, leaseUntil())
            ? Response.json({ ok: true })
            : bad("the station holds this job no more", 409);
        },
      },
      "/api/jobs/:id/events": {
        POST: async (req) => {
          const { ts, kind, data } = await body(req);
          if (!store.job(req.params.id)) return bad("no such job", 404);
          if (
            typeof ts !== "string" ||
            typeof kind !== "string" ||
            !isObject(data)
          )
            return bad("an event has ts, kind and data");
          store.addEvent({ jobId: req.params.id, ts, kind, data });
          return Response.json({ ok: true });
        },
      },
      "/api/jobs/:id/result": {
        POST: async (req) => {
          const b = await body(req);
          const result = jobResult(req.params.id, b);
          if (typeof b.station !== "string" || !result)
            return bad("a result has station, outcome and durationMs");
          if (!store.finish(b.station, result))
            return bad("the station holds this job no more", 409);
          void noteStuck();
          return Response.json({ ok: true });
        },
      },
      "/api/stations/:name": {
        GET: (req) => {
          const s = store.stations().find((s) => s.name === req.params.name);
          return s ? Response.json(s) : bad("no such station", 404);
        },
        PUT: async (req) => {
          const { name } = req.params;
          const { enabled, limit } = await body(req);
          if (!NAME.test(name)) return bad("station must be a name");
          if (enabled !== undefined && typeof enabled !== "boolean")
            return bad("enabled must be true or false");
          if (limit !== undefined && !isCount(limit))
            return bad("limit must be a whole number");
          const s = store.station(name, opts.serverStation);
          const next = {
            ...s,
            enabled: enabled ?? s.enabled,
            limit: limit ?? s.limit,
          };
          store.putStation(next);
          return Response.json(next);
        },
      },
      "/api/repos": {
        GET: () => Response.json(store.repos().map((r) => r.name)),
        POST: async (req) => {
          const { repo } = await body(req);
          if (typeof repo !== "string" || !/^[\w.-]+\/[\w.-]+$/.test(repo))
            return bad("repo must be owner/name");
          store.addRepo(repo);
          return Response.json(store.repos().map((r) => r.name));
        },
      },
      "/api/repos/:owner/:repo": {
        DELETE: (req) =>
          serial(async () => {
            store.removeRepo(`${req.params.owner}/${req.params.repo}`);
            return Response.json(store.repos().map((r) => r.name));
          }),
      },
    },
    fetch: () => new Response("not found", { status: 404 }),
  });

  void loop();

  return {
    url: `http://${opts.host}:${server.port}`,
    async stop() {
      stopped = true;
      clearTimeout(timer);
      clearInterval(sweeper);
      await chain;
      await server.stop(true);
      store.close();
    },
  };
}
