/**
 * The shapes tower shares with the outside world. `run.json`, every line of
 * `events.ndjson`, and the folded state that `tower state --json` prints are
 * all built from these. Changing one is a contract change: bump `v`, and edit
 * docs/protocol.md in the same commit.
 */

export const STATUSES = [
  "pending",
  "in_progress",
  "reviewing",
  "done",
  "blocked",
] as const;
export type Status = (typeof STATUSES)[number];

export function isStatus(value: string): value is Status {
  return (STATUSES as readonly string[]).includes(value);
}

/** The phases tower knows names for; any other string is allowed and shown as-is. */
export const KNOWN_PHASES = [
  "implementing",
  "spec-review",
  "quality-review",
  "fixing",
  "committed",
] as const;

export interface TaskDef {
  id: string;
  title: string;
  /** Free text such as a package path; empty when the plan has none. */
  area: string;
}

export interface RunFile {
  v: 1;
  plan: string;
  planPath: string | null;
  repo: string;
  branch: string;
  callsign: string;
  theme: string;
  startedAt: string;
  /** role → model, free-form. */
  models: Record<string, string>;
  tasks: TaskDef[];
}

export interface ReportEvent {
  v: 1;
  kind: "report";
  ts: string;
  task: string;
  status: Status;
  phase: string;
  model: string;
  note: string;
  commit: string;
}

export interface NoteEvent {
  v: 1;
  kind: "note";
  ts: string;
  text: string;
  task: string | null;
  lane: string | null;
}

export interface AssignEvent {
  v: 1;
  kind: "assign";
  ts: string;
  lane: string;
  tasks: string[];
}

export interface CloseEvent {
  v: 1;
  kind: "close";
  ts: string;
  text: string;
}

export type Event = ReportEvent | NoteEvent | AssignEvent | CloseEvent;

export const DEFAULT_MODELS: Record<string, string> = {
  implementer: "",
  "spec-reviewer": "",
  "quality-reviewer": "",
};

export const DEFAULT_STALE_MINUTES = 10;
