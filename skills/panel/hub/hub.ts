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
  type UsageRow,
} from "../types.ts";
import { AdviceStore, keepOpen, parseProposal } from "./advice.ts";
import { isStageLabel, merged, record, regroup, sync } from "./dispatcher.ts";
import { GitHub, sameRepo, type IssueRef } from "./github.ts";
import { sendInboxNote } from "../station/inbox.ts";
import { renderPanel, type PanelData } from "./panel-page.ts";
import { ACTIVE, Store, type SnapshotIssue } from "./store.ts";
import { UsageStore, parseRateLimit, readUsageReport } from "./usage.ts";

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
  /** The plan's limits, asked for on a timer; the Agent SDK's usage report by default. */
  readUsage?: () => Promise<UsageRow[] | null>;
  usageMs?: number;
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
/** The events a station acts on once the hub has them (JobContext.checkpoint). */
const CHECKPOINTS = ["spec", "proposal", "asked", "replied"];
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
  if (typeof sessionId === "string" && sessionId) r.sessionId = sessionId;
  if (isObject(tokens) && isCount(tokens.input) && isCount(tokens.output))
    r.tokens = { input: tokens.input, output: tokens.output };
  return r;
}

/** How the Panel groups issues, from its `group` query. */
const groupOf = (q: string | null): PanelData["group"] =>
  q === "bundle" || q === "area" ? q : "stage";

/** The stage a job of each kind works an issue in: stuck there, it shows stuck. */
const WORKS_IN: Partial<Record<Job["kind"], Stage>> = {
  grill: "shaping",
  run: "in-progress",
};

/**
 * An issue as the Panel shows it, from its jobs (`mine`, oldest first). Its
 * job is the one not over yet, or a
 * stuck one: the issue's last job, stuck in the stage it worked in, until a
 * move starts another.
 */
function panelIssue(i: SnapshotIssue, mine: Job[]): PanelIssue {
  const area = i.labels.find((l) => l.startsWith("area:"));
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

/** A Tailscale address (100.64.0.0/10, fd7a:115c:a1e0::/48) or a loopback one. */
function tailnetOrLoopback(host: string): boolean {
  const h = host.toLowerCase();
  if (h === "localhost" || h === "::1" || /^127(\.\d{1,3}){3}$/.test(h))
    return true;
  if (h.startsWith("fd7a:115c:a1e0:")) return true;
  const v4 = /^100\.(\d+)\.\d+\.\d+$/.exec(h);
  return !!v4 && Number(v4[1]) >= 64 && Number(v4[1]) <= 127;
}

/**
 * Whether a request names a host the Panel answers to: its own address, a
 * loopback name, or a tailnet name (MagicDNS: dotless, or under .ts.net). A
 * page on another site that rebinds its own name to the hub names that site.
 */
function trustedHost(req: Request, own: string): boolean {
  const header = req.headers.get("host");
  if (!header) return false;
  let name: string;
  try {
    name = new URL(`http://${header}`).hostname.toLowerCase();
  } catch {
    return false;
  }
  name = name.replace(/^\[|\]$/g, "");
  return (
    name === own.toLowerCase() ||
    tailnetOrLoopback(name) ||
    name.endsWith(".ts.net") ||
    !name.includes(".")
  );
}

export async function startHub(opts: HubOptions): Promise<Hub> {
  // No login guards the Panel: only the tailnet does (ADR 0017).
  if (!tailnetOrLoopback(opts.host))
    throw new Error(
      `the hub listens on the Mac's Tailscale address (or loopback), never on another or every address (${opts.host || "none given"})`,
    );
  const now = opts.now ?? (() => new Date());
  const store = new Store(opts.dbPath);
  const advice = new AdviceStore(opts.dbPath);
  const usage = new UsageStore(opts.dbPath);
  let report: UsageRow[] | null = null;
  const readUsage = opts.readUsage ?? readUsageReport;
  const refreshUsage = async () => {
    report = await readUsage().catch(() => null);
  };
  void refreshUsage();
  const usageTimer = setInterval(refreshUsage, opts.usageMs ?? 5 * 60_000);
  const github = new GitHub(opts.ghBin);
  const leaseMs = opts.leaseMs ?? 90_000;
  const leaseUntil = () => new Date(now().getTime() + leaseMs);
  // A stuck run gets one Inbox note, and so does each kept note (a pause);
  // one that fails to send is tried again on the next sweep.
  // A call while notes are sending makes that send look again when done.
  let noting = false;
  let again = false;
  const sendNotes = async () => {
    if (noting) {
      again = true;
      return;
    }
    noting = true;
    try {
      do {
        again = false;
        for (const run of store.unnotedStuckRuns()) {
          const refs = run.issues.map((n) => `${run.repo}#${n}`);
          await sendInboxNote({
            thread: refs.join(" + "),
            subject: `Stuck: ${refs.join(", ")}`,
            body: [
              `The run for ${refs.join(", ")} is stuck: ${run.reason ?? "no reason given"}.`,
              "It is not tried again. Move its issues back to ready-for-agent to start a new run.",
              ...(run.sessionId ? [`Its session: ${run.sessionId}`] : []),
            ].join("\n\n"),
            idempotencyKey: `stuck-${run.id}`,
          });
          store.markNoted(run.id);
        }
        for (const n of store.unsentNotes()) {
          await sendInboxNote({ ...n, idempotencyKey: n.key });
          store.markSent(n.key);
        }
      } while (again);
    } catch (err) {
      console.error(`hub: an Inbox note failed: ${String(err)}`);
    } finally {
      noting = false;
    }
  };
  const sweep = () => {
    store.expireLeases(now());
    void sendNotes();
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
    record(store, { ...prev, stage, labels }, now(), bundleOf);
  };

  /** The newest accepted bundle an issue is in. */
  const bundleOf = (repo: string, issue: number) =>
    advice
      .bundles()
      .filter((b) => b.repo === repo && b.issues.includes(issue))
      .at(-1);

  /**
   * A bundle's run stopped by one of its issues sends the others back from
   * in-progress to ready-for-agent: a bundle never ships half done. Worked
   * out from the jobs each poll, so a gh failure is tried again.
   */
  async function sendBack(repo: string) {
    const jobs = store.jobs();
    for (const i of store.issues(repo)) {
      if (i.stage !== "in-progress") continue;
      const run = jobs
        .filter(
          (j) =>
            j.kind === "run" && j.repo === repo && j.issues.includes(i.number),
        )
        .at(-1);
      if (run && run.issues.length > 1 && store.control(run.id)?.stop)
        await setStage(i, "ready-for-agent");
    }
  }

  // The open issues each issue waits on, from the last blocker check, as
  // refs: #5 in the same repo, acme/other#5 in another.
  const blockers = new Map<string, string[]>();
  const refOf = (b: IssueRef, repo: string) =>
    sameRepo(b.repo, repo) ? `#${b.number}` : `${b.repo}#${b.number}`;

  /**
   * Holds each run not yet claimed while one of its issues waits on an open
   * issue outside the run, and queues it once none does. Runs start held
   * (the Dispatcher), so none is claimed before its first check.
   */
  const gate = async (repo: string) => {
    const waiting = store
      .jobs()
      .filter(
        (j) =>
          j.kind === "run" &&
          j.repo === repo &&
          (j.state === "held" || j.state === "queued"),
      );
    const seen = new Map<string, string[]>();
    for (const job of waiting) {
      const waits = new Set<string>();
      for (const n of job.issues) {
        const own = (await github.openBlockers(repo, n))
          .filter(
            (b) => !(sameRepo(b.repo, repo) && job.issues.includes(b.number)),
          )
          .map((b) => refOf(b, repo));
        for (const r of own) waits.add(r);
        seen.set(`${repo}#${n}`, own);
      }
      store.hold(
        job.id,
        [...waits].sort((a, b) => a.localeCompare(b, "en", { numeric: true })),
      );
    }
    // Swapped in whole, so a read meanwhile sees the last check, not none.
    for (const key of blockers.keys())
      if (key.startsWith(`${repo}#`)) blockers.delete(key);
    for (const [key, waits] of seen) blockers.set(key, waits);
  };

  /** Sets a stage the hub itself owns (in-progress, in-review) on each of a job's issues. */
  const setStages = async (job: Job, stage: Stage) => {
    for (const n of job.issues) {
      const prev = store.issue(job.repo, n);
      if (prev && prev.stage !== "closed") await setStage(prev, stage);
    }
  };

  /** The claimed runs of `repo` nobody is stopping. */
  const claimedRuns = (repo: string) =>
    store
      .jobs()
      .filter(
        (j) =>
          j.kind === "run" &&
          j.state === "claimed" &&
          j.repo === repo &&
          !store.control(j.id)?.stop,
      );

  type Pulls = Awaited<ReturnType<GitHub["readyPulls"]>>;
  /** The ready PR, opened since the run, that closes all its issues. */
  const prOf = (run: Job, pulls: Pulls) =>
    pulls.find(
      (p) =>
        Date.parse(p.createdAt) > Date.parse(run.createdAt) &&
        run.issues.every((n) => p.closes.includes(n)),
    );

  /**
   * Keeps each claimed run's issues true on GitHub. Issues still in
   * ready-for-agent get in-progress (the claim's own try may have failed). A
   * run whose issues one ready (not draft) PR opened since the run closes is
   * over: its issues go to in-review and the job is done. Until the labels
   * are set the job stays claimed, so a gh failure is tried again on the next
   * poll. An older PR is the work of an earlier run or of a person.
   */
  const followRuns = async (repo: string, pulls: Pulls) => {
    for (const run of claimedRuns(repo)) {
      const pr = prOf(run, pulls);
      if (pr && !pr.merged) {
        await setStages(run, "in-review");
        store.finishClaimed(run.id, now());
      } else if (
        run.issues.some(
          (n) => store.issue(repo, n)?.stage === "ready-for-agent",
        )
      )
        await setStages(run, "in-progress");
    }
  };

  const poll = () =>
    serial(async () => {
      for (const { name, baselined } of store.repos()) {
        try {
          const open = await github.openIssues(name);
          // Read after the issues: a merge that closed one is in the list.
          const pulls = claimedRuns(name).length
            ? await github.readyPulls(name)
            : [];
          // A run whose PR was merged since the last poll is done before
          // its issues' close is recorded, which would stop it.
          const mergedRuns = claimedRuns(name).filter(
            (run) => prOf(run, pulls)?.merged,
          );
          for (const run of mergedRuns) store.finishClaimed(run.id, now());
          // Asked only when the poll brings a new issue to label.
          const fresh =
            baselined && open.some((i) => !store.issue(name, i.number));
          const labelAreas = fresh && (await github.hasContextMap(name));
          sync(store, name, open, now(), bundleOf, labelAreas);
          await sendBack(name);
          await gate(name);
          await followRuns(name, pulls);
          // A merge that closed no issue (another base, no auto-close)
          // leaves them in review; setStages skips the closed ones.
          for (const run of mergedRuns) await setStages(run, "in-review");
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

  /** Every issue as the Panel shows it, from one read of the jobs and bundles. */
  const issues = () => {
    const byIssue = new Map<string, Job[]>();
    for (const j of store.jobs())
      for (const n of j.issues) {
        const key = `${j.repo}#${n}`;
        byIssue.set(key, [...(byIssue.get(key) ?? []), j]);
      }
    const inBundle = new Map<string, string>();
    for (const b of advice.bundles())
      // oldest first: the newest wins
      for (const n of b.issues) inBundle.set(`${b.repo}#${n}`, b.id);
    return store.issues().map((i) => {
      const key = `${i.repo}#${i.number}`;
      return {
        ...panelIssue(i, byIssue.get(key) ?? []),
        blockedBy: blockers.get(key) ?? [],
        bundleId: inBundle.get(key) ?? null,
      };
    });
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
      const chosen = [
        ...order.map((i) => p.order[i]?.repo),
        ...p.bundles.filter((x) => bundles.includes(x.id)).map((x) => x.repo),
      ];
      const listed = store.repos().map((r) => r.name);
      const gone = chosen.find((r) => r && !listed.some((l) => sameRepo(l, r)));
      // Rejecting writes nothing, so a part of an unlisted repo may go.
      if (gone && decision === "accepted")
        return bad(`${gone} is not listed on the Panel`);
      if (decision === "accepted") {
        // Held at once, every part first: a claim must not take a run while
        // gh writes a dependency. The blocker check after says all it waits on.
        for (const i of new Set(order)) {
          const part = p.order[i]!;
          for (const j of store.jobs()) {
            const waits = part.after.filter((n) => !j.issues.includes(n));
            if (
              j.kind === "run" &&
              sameRepo(j.repo, part.repo) &&
              j.issues.includes(part.issue) &&
              waits.length &&
              (j.state === "queued" || j.state === "held")
            )
              store.hold(
                j.id,
                waits.map((n) => `#${n}`),
              );
          }
        }
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
      } else advice.decide(id, decision, order, [], now());
      const accepted = p.bundles.filter((x) => bundles.includes(x.id));
      // The older bundles the accepted ones cut down: their issues regroup too.
      const cut =
        decision === "accepted"
          ? advice
              .bundles()
              .filter((o) =>
                accepted.some(
                  (x) =>
                    sameRepo(x.repo, o.repo) &&
                    x.issues.some((n) => o.issues.includes(n)),
                ),
              )
          : [];
      advice.decide(id, decision, [], bundles, now());
      // What was accepted holds now, not at the next poll: runs follow
      // their bundles, and wait on their new blockers.
      if (decision === "accepted") {
        const repos = new Set([
          ...order.map((i) => p.order[i]!.repo),
          ...accepted.map((x) => x.repo),
        ]);
        // Every repo regroups before any gh call, so no claim meanwhile
        // takes a run its bundle has left.
        for (const repo of repos) {
          const issues = [...accepted, ...cut]
            .filter((x) => x.repo === repo)
            .flatMap((x) => x.issues);
          regroup(store, repo, issues, now(), bundleOf);
        }
        for (const repo of repos)
          await gate(repo).catch((err: unknown) =>
            console.error(`hub: checking ${repo}'s blockers: ${String(err)}`),
          );
      }
      return Response.json(advice.proposal(id));
    });

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
      // What the move set off happens now, not at the next poll (which
      // tries again what fails here): a bundle's other issues go back, and
      // a run the move queued is checked for blockers.
      await sendBack(repo)
        .then(() => gate(repo))
        .catch((err: unknown) =>
          console.error(
            `hub: after the move of ${repo}#${number}: ${String(err)}`,
          ),
        );
      return Response.json(
        issues().find((i) => i.repo === repo && i.number === number),
      );
    });

  // Every route answers only requests that name a host the Panel trusts.
  const guard = <R extends string>(
    routes: Bun.Serve.Routes<undefined, R>,
  ): Bun.Serve.Routes<undefined, R> =>
    Object.fromEntries(
      Object.entries(routes).map(([path, methods]) => [
        path,
        Object.fromEntries(
          Object.entries(
            methods as Record<string, (req: Request, s: unknown) => unknown>,
          ).map(([method, handle]) => [
            method,
            (req: Request, s: unknown) =>
              trustedHost(req, opts.host)
                ? handle(req, s)
                : bad("the Panel does not answer to that host", 403),
          ]),
        ),
      ]),
    ) as unknown as Bun.Serve.Routes<undefined, R>;

  const server = Bun.serve({
    hostname: opts.host,
    port: opts.port,
    routes: guard({
      "/": {
        GET: (req) => {
          const panelIssues = issues();
          return new Response(
            renderPanel({
              group: groupOf(new URL(req.url).searchParams.get("group")),
              advice: advice.latest(),
              usage: usage.view(report, now()),
              bundles: advice.bundles(),
              issues: panelIssues,
              stuckReasons: Object.fromEntries(
                panelIssues
                  .filter((i) => i.stuck && i.jobId)
                  .map((i) => [i.jobId, store.job(i.jobId!)?.reason ?? ""]),
              ),
              repos: store.repos().map((r) => r.name),
              stations: store.stations(),
              jobs: (() => {
                // The 30 newest, and every claimed one: a station shows
                // what it holds.
                const all = store.jobs();
                const shown = all
                  .filter(
                    (j, n) => n >= all.length - 30 || j.state === "claimed",
                  )
                  .reverse();
                const summary = store.summaries(shown.map((j) => j.id));
                return shown.map((j) => ({
                  ...j,
                  events: summary.get(j.id)?.events ?? 0,
                  workspace: summary.get(j.id)?.workspace ?? null,
                }));
              })(),
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
      "/api/advice": { GET: () => Response.json(advice.latest()) },
      "/api/usage": { GET: () => Response.json(usage.view(report, now())) },
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
          // At a usage limit nothing new starts until the reset.
          if (usage.pausedUntil(now())) return Response.json(null);
          const job = store.claim(s, kinds, now(), leaseUntil());
          // A claimed run moves its issues to in-progress; the poll tries
          // again if this fails (followRuns).
          if (job?.kind === "run")
            void serial(async () => {
              // Not if the user stopped it while a move ran ahead of it, or
              // a poll ahead of it found its PR.
              if (
                store.job(job.id)?.state === "claimed" &&
                !store.control(job.id)?.stop
              )
                await setStages(job, "in-progress");
            }).catch((err) =>
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
          const { station, id, ts, kind, data } = await body(req);
          const job = store.job(req.params.id);
          if (!job) return bad("no such job", 404);
          if (
            typeof ts !== "string" ||
            typeof kind !== "string" ||
            !isObject(data)
          )
            return bad("an event has ts, kind and data");
          // Only from the station working the job: one that lost it says nothing.
          if (typeof station !== "string" || !store.holds(job.id, station))
            return bad("the station holds this job no more", 409);
          // A checkpoint is what a job acts on next: a stopped job acts no more.
          if (CHECKPOINTS.includes(kind) && store.control(job.id)?.stop)
            return bad("the job is being stopped", 409);
          if (
            kind === "tokens" &&
            !(isCount(data.input) && isCount(data.output))
          )
            return bad("a tokens event has input and output counts");
          if (kind === "rate-limit") {
            const info = parseRateLimit(data);
            if (!info)
              return bad("a rate-limit event has a status and an ISO resetsAt");
            const paused = usage.record(info, now());
            if (paused) {
              store.addNote({
                key: `panel-pause-${paused}`,
                thread: "Panel usage",
                subject: "Dispatch paused at a usage limit",
                body: `Claude refused a job at a usage limit${info.rateLimitType ? ` (${info.rateLimitType})` : ""}. No new job starts until ${paused}.`,
              });
              void sendNotes();
            }
          }
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
          // An event sent again with its id (its answer was lost) counts once.
          store.transaction(() => {
            const eventId = typeof id === "string" ? id : undefined;
            if (!store.addEvent({ jobId: job.id, ts, kind, data }, eventId))
              return;
            if (kind === "session" && typeof data.sessionId === "string")
              store.setSession(job.id, data.sessionId);
            if (kind === "tokens")
              store.addTokens(job.id, {
                input: data.input as number,
                output: data.output as number,
              });
          });
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
          void sendNotes();
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
          // GitHub ignores case: one repo is listed once.
          if (!store.repos().some((r) => sameRepo(r.name, repo)))
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
    }),
    fetch: () => new Response("not found", { status: 404 }),
  });

  void loop();

  return {
    url: `http://${opts.host.includes(":") ? `[${opts.host}]` : opts.host}:${server.port}`,
    async stop() {
      stopped = true;
      clearTimeout(timer);
      clearInterval(sweeper);
      clearInterval(usageTimer);
      await chain;
      await server.stop(true);
      store.close();
      advice.close();
      usage.close();
    },
  };
}
