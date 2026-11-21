/**
 * The Dispatcher (ADR 0016): compares each issue's stage with the one last
 * seen and queues the job the new stage asks for. No model runs here, and a
 * job starts only from a stage change, never from reading an issue.
 */
import { STAGES, type JobKind, type Stage } from "../types.ts";
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

function jobFor(to: Stage): JobKind | null {
  return to === "shaping" ? "grill" : null;
}

/** Records one issue's stage, and queues a job when it changed since last seen. */
export function record(store: Store, next: SnapshotIssue, now: Date) {
  const prev = store.issue(next.repo, next.number);
  store.putIssue(next);
  if (!prev || prev.stage === next.stage) return;
  const kind = jobFor(next.stage);
  if (kind) store.addJob(kind, next.repo, [next.number], now);
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
}
