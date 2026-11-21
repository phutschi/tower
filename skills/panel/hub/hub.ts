/**
 * The hub (ADR 0017): serves the Panel and its HTTP API, holds the job queue,
 * and checks GitHub on a timer, since a tailnet-only Panel gets no webhooks.
 */
import { STAGES, type Job, type PanelIssue, type Stage } from "../types.ts";
import { isStageLabel, record, sync } from "./dispatcher.ts";
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
  const github = new GitHub(opts.ghBin);

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
        GET: () =>
          new Response(
            renderPanel({
              issues: issues(),
              repos: store.repos().map((r) => r.name),
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
      await chain;
      await server.stop(true);
      store.close();
    },
  };
}
