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
import { AdviceStore, keepOpen, parseProposal } from "./advice.ts";
import { isStageLabel, merged, record, sync } from "./dispatcher.ts";
import { GitHub } from "./github.ts";
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

function panelIssue(i: SnapshotIssue, jobs: Job[]): PanelIssue {
  const area = i.labels.find((l) => l.startsWith("area:"));
  const job = jobs
    .filter(
      (j) =>
        j.repo === i.repo &&
        j.issues.includes(i.number) &&
        ACTIVE.includes(j.state),
    )
    .at(-1);
  return {
    repo: i.repo,
    number: i.number,
    title: i.title,
    stage: i.stage,
    issueArea: area ? area.slice("area:".length) : null,
    bundleId: null,
    blockedBy: [],
    jobId: job?.id ?? null,
    stuck: false,
  };
}

export async function startHub(opts: HubOptions): Promise<Hub> {
  const now = opts.now ?? (() => new Date());
  const store = new Store(opts.dbPath);
  const advice = new AdviceStore(opts.dbPath);
  const github = new GitHub(opts.ghBin);
  const leaseMs = opts.leaseMs ?? 90_000;
  const leaseUntil = () => new Date(now().getTime() + leaseMs);
  const sweep = () => store.expireLeases(now());
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

  const poll = () =>
    serial(async () => {
      for (const { name } of store.repos()) {
        try {
          sync(store, name, await github.openIssues(name), now());
          merged(store, advice, name, await github.head(name), now());
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
    const bundles = advice.bundles();
    return store.issues().map((i) => ({
      ...panelIssue(i, jobs),
      // The newest accepted bundle an issue is in.
      bundleId:
        bundles
          .filter((b) => b.repo === i.repo && b.issues.includes(i.number))
          .at(-1)?.id ?? null,
    }));
  };

  /** The user's accept or reject of parts of an order advice. */
  const decide = (
    id: string,
    decision: "accepted" | "rejected",
    b: Record<string, unknown>,
  ) =>
    serial(async () => {
      const p = advice.proposal(id);
      if (!p) return bad("no such advice", 404);
      const { order = [], bundles = [] } = b;
      if (
        !Array.isArray(order) ||
        !order.every(isCount) ||
        !Array.isArray(bundles) ||
        !bundles.every((x) => typeof x === "string")
      )
        return bad("order lists part indexes, bundles lists bundle ids");
      const closed = advice.undecided(p, order, bundles);
      if (closed) return bad(closed);
      if (decision === "accepted")
        for (const i of new Set(order)) {
          const part = p.order[i]!;
          try {
            await github.addBlockedBy(part.repo, part.issue, part.after);
          } catch (err) {
            return bad(`gh refused the dependency: ${String(err)}`, 502);
          }
          // Each part counts once its dependencies are on GitHub.
          advice.decide(id, decision, [i], [], now());
        }
      else advice.decide(id, decision, order, [], now());
      advice.decide(id, decision, [], bundles, now());
      return Response.json(advice.proposal(id));
    });

  /** The Panel's one write: the stage label of the issue the user moved (ADR 0003). */
  const move = (repo: string, number: number, stage: Stage) =>
    serial(async () => {
      const prev = store.issue(repo, number);
      if (!prev) return bad(`${repo}#${number} is not on the Panel`);
      if (prev.stage === "closed") return bad(`${repo}#${number} is closed`);
      let labels: string[];
      try {
        // GitHub's labels now, not the last poll's: a job may have moved it.
        labels = await github.labels(repo, number);
        const remove = labels.filter((l) => isStageLabel(l) && l !== stage);
        await github.editLabels(repo, number, [stage], remove);
        labels = labels.filter((l) => !remove.includes(l));
      } catch (err) {
        return bad(`gh refused the move: ${String(err)}`, 502);
      }
      if (!labels.includes(stage)) labels.push(stage);
      record(store, { ...prev, stage, labels }, now());
      return Response.json(
        issues().find((i) => i.repo === repo && i.number === number),
      );
    });

  const server = Bun.serve({
    hostname: opts.host,
    port: opts.port,
    routes: {
      "/": {
        GET: (req) =>
          new Response(
            renderPanel({
              group:
                new URL(req.url).searchParams.get("group") === "bundle"
                  ? "bundle"
                  : "stage",
              advice: advice.latest(),
              bundles: advice.bundles(),
              issues: issues(),
              repos: store.repos().map((r) => r.name),
              stations: store.stations(),
              jobs: store
                .jobs()
                .slice(-30)
                .reverse()
                .map((j) => ({ ...j, events: store.events(j.id) })),
            }),
            { headers: { "content-type": "text/html; charset=utf-8" } },
          ),
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
      "/api/advice": { GET: () => Response.json(advice.latest()) },
      "/api/advice/:id/accept": {
        POST: async (req) => decide(req.params.id, "accepted", await body(req)),
      },
      "/api/advice/:id/reject": {
        POST: async (req) => decide(req.params.id, "rejected", await body(req)),
      },
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
          return Response.json(store.claim(s, kinds, leaseUntil()));
        },
      },
      "/api/jobs/:id": {
        GET: (req) => {
          const job = store.job(req.params.id);
          if (!job) return bad("no such job", 404);
          return Response.json({ ...job, events: store.events(job.id) });
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
          const job = store.job(req.params.id);
          if (!job) return bad("no such job", 404);
          if (
            typeof ts !== "string" ||
            typeof kind !== "string" ||
            !isObject(data)
          )
            return bad("an event has ts, kind and data");
          if (kind === "session" && typeof data.sessionId === "string")
            store.setSession(job.id, data.sessionId);
          if (job.kind === "advice" && kind === "proposal") {
            const proposal = parseProposal(data);
            if (typeof proposal === "string") return bad(proposal);
            // An issue may have closed while the session ran: keep the rest.
            const { kept } = keepOpen(proposal, (repo, n) => {
              const i = store.issue(repo, n);
              return !!i && i.stage !== "closed";
            });
            advice.add(job.id, kept, now());
          }
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
          return store.finish(b.station, result)
            ? Response.json({ ok: true })
            : bad("the station holds this job no more", 409);
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
      advice.close();
    },
  };
}
