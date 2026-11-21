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
export const JOB_KINDS = ["grill", "run", "label-area", "advice"] as const;
export type JobKind = (typeof JOB_KINDS)[number];
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
  durationMs: number | null;
  tokens: { input: number; output: number } | null;
}

export interface JobEvent {
  jobId: string;
  ts: string;
  kind: string;
  data: Record<string, unknown>;
}

export interface JobResult {
  jobId: string;
  outcome: "done" | "failed" | "stopped";
  reason?: string;
  sessionId?: string;
  durationMs: number;
  tokens?: { input: number; output: number };
}

export interface Station {
  name: string;
  enabled: boolean;
  limit: number;
}
