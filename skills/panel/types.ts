/** Shared types of the Panel: the hub, the Dispatcher and the stations. */

/** The ladder, in order. Closed is GitHub's closed state, not a label. */
export const STAGES = [
  "needs-triage",
  "shaping",
  "ready-for-agent",
  "in-progress",
  "in-review",
  "closed",
] as const;
export type Stage = (typeof STAGES)[number];
export type JobKind = "grill" | "run" | "label-area" | "advice";
export type JobState =
  "queued" | "held" | "claimed" | "done" | "stuck" | "stopped";

export interface PanelIssue {
  repo: string;
  number: number;
  title: string;
  stage: Stage;
  issueArea: string | null;
  bundleId: string | null;
  blockedBy: number[];
  jobId: string | null;
  stuck: boolean;
}

export interface Job {
  id: string;
  kind: JobKind;
  repo: string;
  issues: number[];
  state: JobState;
  station: string | null;
  leaseUntil: string | null;
  reason: string | null;
  sessionId: string | null;
  createdAt: string;
}
