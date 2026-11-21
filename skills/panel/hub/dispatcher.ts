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
  for (const s of STAGES) if (labels.includes(s)) stage = s;
  return stage;
}

export const isStageLabel = (label: string) => LABELS.includes(label);

/** The job a move into each stage asks for. */
const JOB_FOR: Partial<Record<Stage, JobKind>> = {
  shaping: "grill",
  "ready-for-agent": "run",
};
const jobFor = (to: Stage): JobKind | null => JOB_FOR[to] ?? null;

/** The jobs a stage move calls off: the ones working an issue's stage. */
const STOPPABLE: readonly JobKind[] = ["grill", "run"];

/** Why a move stops the issue's jobs, or null when it is not a step back. */
function stopsJobs(from: Stage, to: Stage): string | null {
  if (to === "closed") return "the issue was closed";
  return STAGES.indexOf(to) < STAGES.indexOf(from)
    ? `moved back to ${to}`
    : null;
}

/** The accepted bundle an issue is built in, if any. */
export type BundleOf = (repo: string, issue: number) => Bundle | undefined;
const noBundle: BundleOf = () => undefined;

/**
 * The issues a run for `issue` builds: its bundle's, once every one of them
 * is in ready-for-agent; null while one is not. A single issue is its own.
 */
function runIssues(
  store: Store,
  repo: string,
  issue: number,
  bundleOf: BundleOf,
): number[] | null {
  const bundle = bundleOf(repo, issue);
  if (!bundle) return [issue];
  const ready = bundle.issues.every(
    (n) => store.issue(repo, n)?.stage === "ready-for-agent",
  );
  return ready ? bundle.issues : null;
}

/**
 * Records one issue's stage, and acts when it was moved since last seen: a
 * step back or a close stops the issue's job, and the new stage queues the
 * job it asks for. A run is queued held, until the hub has checked its
 * blockers. A reopened issue was not moved, and an issue whose job of that
 * kind is not over yet gets no second one. Returns the jobs it stopped.
 */
export function record(
  store: Store,
  next: SnapshotIssue,
  now: Date,
  bundleOf: BundleOf = noBundle,
): Job[] {
  const stopped: Job[] = [];
  store.transaction(() => {
    const prev = store.issue(next.repo, next.number);
    store.putIssue(next);
    if (!prev || prev.stage === next.stage || prev.stage === "closed") return;
    const stop = stopsJobs(prev.stage, next.stage);
    if (stop)
      for (const j of store.activeJobs(next.repo, next.number))
        if (STOPPABLE.includes(j.kind)) {
          store.requestStop(j.id, stop);
          stopped.push(j);
        }
    const kind = jobFor(next.stage);
    if (!kind) return;
    const issues =
      kind === "run"
        ? runIssues(store, next.repo, next.number, bundleOf)
        : [next.number];
    const waiting = issues?.some((n) =>
      store.activeJobs(next.repo, n).some((j) => j.kind === kind),
    );
    if (issues && !waiting)
      store.addJob(
        kind,
        next.repo,
        issues,
        now,
        kind === "run" ? "held" : "queued",
      );
  });
  return stopped;
}

/**
 * Records a repo's open issues as one poll saw them. Its first poll only
 * records, so listing a repo starts nothing. An issue gone from the open list
 * is closed.
 */
export function sync(
  store: Store,
  repo: string,
  open: GhIssue[],
  now: Date,
  bundleOf: BundleOf = noBundle,
): Job[] {
  const stopped: Job[] = [];
  const listed = store.repos().find((r) => r.name === repo);
  if (!listed) return stopped; // unlisted while the poll ran
  const seen = new Set<number>();
  store.transaction(() => {
    for (const i of open) {
      seen.add(i.number);
      const labels = i.labels.map((l) => l.name);
      const issue = { repo, number: i.number, title: i.title, labels };
      const next = { ...issue, stage: stageOf(labels) };
      if (listed.baselined) stopped.push(...record(store, next, now, bundleOf));
      else store.putIssue(next);
    }
    for (const prev of store.issues(repo))
      if (!seen.has(prev.number) && prev.stage !== "closed")
        stopped.push(
          ...record(store, { ...prev, stage: "closed" }, now, bundleOf),
        );
    store.markBaselined(repo);
  });
  return stopped;
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
  advice.setHead(repo, head);
  if (prev === undefined || prev === head) return;
  const queued = (j: Job) =>
    j.kind === "advice" && j.repo === repo && j.state === "queued";
  if (!store.jobs().some(queued)) store.addJob("advice", repo, [], now);
}
