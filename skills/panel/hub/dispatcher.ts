/**
 * The Dispatcher (ADR 0016): compares each issue's stage with the one last
 * seen and queues the job the new stage asks for. No model runs here, and a
 * job starts only from a stage change, never from reading an issue.
 */
import { STAGES, type JobKind, type Stage } from "../types.ts";
import type { AdviceStore } from "./advice.ts";
import type { GhIssue } from "./github.ts";
import { ACTIVE, type SnapshotIssue, type Store } from "./store.ts";

const LABELS: readonly string[] = STAGES.filter((s) => s !== "closed");

/** The furthest stage label an issue carries; no stage label is needs-triage. */
export function stageOf(labels: string[]): Stage {
  let stage: Stage = "needs-triage";
  for (const s of STAGES) if (labels.includes(s)) stage = s;
  return stage;
}

export const isStageLabel = (label: string) => LABELS.includes(label);

function jobFor(to: Stage): JobKind | null {
  return to === "shaping" ? "grill" : null;
}

/**
 * Records one issue's stage, and queues a job when it was moved since last
 * seen. A reopened issue was not moved, and an issue whose job of that kind is
 * not over yet gets no second one.
 */
export function record(store: Store, next: SnapshotIssue, now: Date) {
  store.transaction(() => {
    const prev = store.issue(next.repo, next.number);
    store.putIssue(next);
    if (!prev || prev.stage === next.stage || prev.stage === "closed") return;
    const kind = jobFor(next.stage);
    const waiting = store
      .jobs()
      .some(
        (j) =>
          j.kind === kind &&
          j.repo === next.repo &&
          j.issues.includes(next.number) &&
          ACTIVE.includes(j.state),
      );
    if (kind && !waiting) store.addJob(kind, next.repo, [next.number], now);
  });
}

/**
 * Records a repo's open issues as one poll saw them. Its first poll only
 * records, so listing a repo starts nothing. An issue gone from the open list
 * is closed.
 */
export function sync(store: Store, repo: string, open: GhIssue[], now: Date) {
  const listed = store.repos().find((r) => r.name === repo);
  if (!listed) return; // unlisted while the poll ran
  const seen = new Set<number>();
  store.transaction(() => {
    for (const i of open) {
      seen.add(i.number);
      const labels = i.labels.map((l) => l.name);
      const issue = { repo, number: i.number, title: i.title, labels };
      const next = { ...issue, stage: stageOf(labels) };
      if (listed.baselined) record(store, next, now);
      else store.putIssue(next);
    }
    for (const prev of store.issues(repo))
      if (!seen.has(prev.number) && prev.stage !== "closed")
        record(store, { ...prev, stage: "closed" }, now);
    store.markBaselined(repo);
  });
}

/**
 * Records the head of a repo's main, and queues an order advice when it moved
 * since last seen. The first sight only records. A queued advice reads every
 * merge up to its start, so it gets no second one.
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
  if (!store.jobs().some((j) => j.kind === "advice" && j.state === "queued"))
    store.addJob("advice", repo, [], now);
}
