/**
 * The Dispatcher (ADR 0016): compares each issue's stage with the one last
 * seen and queues the job the new stage asks for. No model runs here, and a
 * job starts only from a stage change, never from reading an issue.
 */
import {
  STAGES,
  type Bundle,
  type Job,
  type JobKind,
  type Stage,
} from "../types.ts";
import type { AdviceStore } from "./advice.ts";
import type { GhIssue } from "./github.ts";
import type { SnapshotIssue, Store } from "./store.ts";

const LABELS: readonly string[] = STAGES.filter((s) => s !== "closed");

/** The furthest stage label an issue carries; no stage label is needs-triage. */
export function stageOf(labels: string[]): Stage {
  let stage: Stage = "needs-triage";
  // A label named closed is any label: closed is GitHub's state.
  for (const s of LABELS) if (labels.includes(s)) stage = s as Stage;
  return stage;
}

export const isStageLabel = (label: string) => LABELS.includes(label);

/** The job a move into each stage asks for. */
const JOB_FOR: Partial<Record<Stage, JobKind>> = {
  shaping: "grill",
  "ready-for-agent": "run",
};
const jobFor = (to: Stage): JobKind | null => JOB_FOR[to] ?? null;

/** The jobs a step back calls off: the ones working an issue's stage. */
const STOPPABLE: readonly JobKind[] = ["grill", "run"];

/**
 * Why a move stops one of the issue's jobs, or null when it does not. A
 * close stops every job; a step back the ones working the stage; a move on
 * out of shaping its grill, unless the grill made that move (it keeps its
 * spec on the hub before it moves the issue); a move on out of
 * ready-for-agent its run not yet claimed.
 */
function stopsJob(store: Store, j: Job, from: Stage, to: Stage): string | null {
  if (to === "closed") return "the issue was closed";
  if (STAGES.indexOf(to) < STAGES.indexOf(from))
    return STOPPABLE.includes(j.kind) ? `moved back to ${to}` : null;
  if (
    j.kind === "grill" &&
    from === "shaping" &&
    !store.events(j.id).some((e) => e.kind === "spec")
  )
    return `moved on to ${to}`;
  // A run not yet claimed: the hub's own in-progress move follows a claim.
  if (j.kind === "run" && from === "ready-for-agent" && j.state !== "claimed")
    return `moved on to ${to}`;
  return null;
}

/** The accepted bundle an issue is built in, if any. */
export type BundleOf = (repo: string, issue: number) => Bundle | undefined;
const noBundle: BundleOf = () => undefined;

/**
 * The issues a run for `issue` builds: its bundle's open ones, once every one
 * of them is in ready-for-agent; null while one is not. A closed issue has
 * left its bundle. A single issue is its own.
 */
function runIssues(
  store: Store,
  repo: string,
  issue: number,
  bundleOf: BundleOf,
): number[] | null {
  const bundle = bundleOf(repo, issue);
  if (!bundle) return [issue];
  const open = bundle.issues.filter(
    (n) => store.issue(repo, n)?.stage !== "closed",
  );
  const ready = open.every(
    (n) => store.issue(repo, n)?.stage === "ready-for-agent",
  );
  return ready ? open : null;
}

/**
 * Queues the job of `kind` a move of `number` asks for. A run is queued held,
 * until the hub has checked its blockers. An issue whose job of that kind is
 * not over yet gets no second one. A bundle that is ready takes over the
 * waiting runs of its issues; one already claimed keeps them.
 */
function queue(
  store: Store,
  repo: string,
  number: number,
  kind: JobKind,
  now: Date,
  bundleOf: BundleOf,
) {
  const issues =
    kind === "run" ? runIssues(store, repo, number, bundleOf) : [number];
  if (!issues) return;
  const others = [
    ...new Map(
      issues
        .flatMap((n) => store.activeJobs(repo, n))
        .filter((j) => j.kind === kind)
        .map((j) => [j.id, j]),
    ).values(),
  ];
  const same = (j: Job) => j.issues.join() === issues.join();
  if (others.some((j) => same(j) || j.state === "claimed")) return;
  for (const j of others) store.requestStop(j.id, "joined a bundle");
  store.addJob(kind, repo, issues, now, kind === "run" ? "held" : "queued");
}

/**
 * Records one issue's stage, and acts when it was moved since last seen: a
 * move stops the jobs it calls off (stopsJob), and the new stage queues the
 * job it asks for. A reopened issue was not moved.
 */
export function record(
  store: Store,
  next: SnapshotIssue,
  now: Date,
  bundleOf: BundleOf = noBundle,
) {
  store.transaction(() => {
    const prev = store.issue(next.repo, next.number);
    store.putIssue(next);
    if (!prev || prev.stage === next.stage || prev.stage === "closed") return;
    const left: number[] = [];
    for (const j of store.activeJobs(next.repo, next.number)) {
      const stop = stopsJob(store, j, prev.stage, next.stage);
      if (!stop) continue;
      store.requestStop(j.id, stop);
      if (next.stage === "closed" && j.kind === "run")
        left.push(...j.issues.filter((n) => n !== next.number));
    }
    const kind = jobFor(next.stage);
    if (kind) queue(store, next.repo, next.number, kind, now, bundleOf);
    // A closed issue left its bundle: the rest of a waiting run runs without it.
    for (const n of left)
      if (store.issue(next.repo, n)?.stage === "ready-for-agent")
        queue(store, next.repo, n, "run", now, bundleOf);
  });
}

/**
 * After bundles of `repo` were accepted around `issues`: stops each waiting
 * run whose issues are no longer what their bundle builds, and queues the
 * runs those issues, and the stopped runs' issues, ask for now. A claimed
 * run keeps its issues; an issue nothing touched gets no run (ADR 0016).
 */
export function regroup(
  store: Store,
  repo: string,
  issues: number[],
  now: Date,
  bundleOf: BundleOf,
) {
  store.transaction(() => {
    const touched = new Set(issues);
    for (const j of store.jobs()) {
      if (j.kind !== "run" || j.repo !== repo) continue;
      if (j.state !== "queued" && j.state !== "held") continue;
      const wants = j.issues.map((n) =>
        runIssues(store, repo, n, bundleOf)?.join(),
      );
      if (wants.every((w) => w === j.issues.join())) continue;
      store.requestStop(j.id, "its bundle changed");
      for (const n of j.issues) touched.add(n);
    }
    for (const n of touched)
      if (store.issue(repo, n)?.stage === "ready-for-agent")
        queue(store, repo, n, "run", now, bundleOf);
  });
}

/**
 * Records a repo's open issues as one poll saw them. Its first poll only
 * records, so listing a repo starts nothing. An issue gone from the open list
 * is closed. With `labelAreas` (the repo has a context map), an issue seen
 * for the first time queues the job that labels its issue area.
 */
export function sync(
  store: Store,
  repo: string,
  open: GhIssue[],
  now: Date,
  bundleOf: BundleOf = noBundle,
  labelAreas = false,
) {
  const listed = store.repos().find((r) => r.name === repo);
  if (!listed) return; // unlisted while the poll ran
  const seen = new Set<number>();
  store.transaction(() => {
    for (const i of open) {
      seen.add(i.number);
      const labels = i.labels.map((l) => l.name);
      const issue = { repo, number: i.number, title: i.title, labels };
      const next = { ...issue, stage: stageOf(labels) };
      const hasArea = labels.some((l) => l.startsWith("area:"));
      if (
        labelAreas &&
        listed.baselined &&
        !hasArea &&
        !store.issue(repo, i.number)
      )
        store.addJob("label-area", repo, [i.number], now);
      if (listed.baselined) record(store, next, now, bundleOf);
      else store.putIssue(next);
    }
    for (const prev of store.issues(repo))
      if (!seen.has(prev.number) && prev.stage !== "closed")
        record(store, { ...prev, stage: "closed" }, now, bundleOf);
    store.markBaselined(repo);
  });
}

/**
 * Records the head of a repo's main, and queues an order advice when it moved
 * since last seen. The first sight only records. A repo's queued advice reads
 * every merge up to its start, so it gets no second one.
 */
export function merged(
  store: Store,
  advice: AdviceStore,
  repo: string,
  head: string,
  now: Date,
) {
  const prev = advice.head(repo);
  // Queued before the head is saved: the two stores commit apart, and a
  // repeat finds the queued advice.
  const queued = (j: Job) =>
    j.kind === "advice" && j.repo === repo && j.state === "queued";
  if (prev !== undefined && prev !== head && !store.jobs().some(queued))
    store.addJob("advice", repo, [], now);
  advice.setHead(repo, head);
}
