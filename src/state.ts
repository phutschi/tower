/**
 * state = fold(run, lines). Pure: no I/O, and the clock is a parameter, so
 * the same log folds the same way in a test, in the console, and in
 * `tower state --json`.
 *
 * Rules that matter:
 *  - order is file order. Timestamps are for display; three shells in three
 *    worktrees do not share a clock.
 *  - the fold never invents a task. A report for an id the plan does not
 *    have is kept in the transcript, flagged, and counted — not a new row.
 *  - last report wins, and both stay in the transcript, so a task that went
 *    backwards is visible rather than rewritten.
 *  - stale applies to in_progress and reviewing only. blocked is already
 *    flagged; pending and done have nothing to hear from.
 */
import type { Event, RunFile, Status } from "./types.ts";
import type { ParsedLine } from "./events.ts";

export interface TaskState {
  id: string;
  title: string;
  area: string;
  lane: string | null;
  status: Status;
  phase: string;
  note: string;
  /** The model on the task right now (implementer or reviewer). */
  model: string;
  /** Sticky: the model that last held in_progress or done. */
  implementer: string;
  commit: string;
  startedAt: string | null;
  updatedAt: string | null;
  stale: boolean;
}

export interface TranscriptEntry {
  ts: string;
  event: Event | null;
  problem?: "unreadable" | "unknown-task";
  raw?: string;
}

export interface Summary {
  total: number;
  pending: number;
  active: number;
  done: number;
  blocked: number;
  stale: number;
  complete: boolean;
}

export interface State {
  run: RunFile;
  tasks: TaskState[];
  lanes: Record<string, string[]>;
  transcript: TranscriptEntry[];
  unreadable: number;
  unknown: string[];
  closed: { ts: string; text: string } | null;
  firstEventAt: string | null;
  summary: Summary;
  attention: boolean;
}

export interface FoldOptions {
  now: Date;
  staleMinutes: number;
}

export function fold(
  run: RunFile,
  lines: readonly ParsedLine[],
  options: FoldOptions,
): State {
  const tasks = new Map<string, TaskState>(
    run.tasks.map((t) => [
      t.id,
      {
        id: t.id,
        title: t.title,
        area: t.area,
        lane: null,
        status: "pending",
        phase: "",
        note: "",
        model: "",
        implementer: "",
        commit: "",
        startedAt: null,
        updatedAt: null,
        stale: false,
      },
    ]),
  );

  const transcript: TranscriptEntry[] = [];
  const unknown: string[] = [];
  let unreadable = 0;
  let closed: State["closed"] = null;
  // Named firstEventAt in the public contract, but only a *report* sets it:
  // assign/note/close mark planning or narration, not work starting, so they
  // must not move the run's "elapsed since work began" clock.
  let firstEventAt: string | null = null;

  for (const line of lines) {
    const event = line.event;
    if (!event) {
      unreadable += 1;
      transcript.push({
        ts: "",
        event: null,
        problem: "unreadable",
        raw: line.raw,
      });
      continue;
    }
    if (event.kind === "report") {
      const task = tasks.get(event.task);
      if (!task) {
        if (!unknown.includes(event.task)) unknown.push(event.task);
        transcript.push({ ts: event.ts, event, problem: "unknown-task" });
        continue;
      }
      firstEventAt ??= event.ts;
      // status/phase/note/updatedAt: last report always wins, whole value.
      task.status = event.status;
      task.phase = event.phase;
      task.note = event.note;
      task.updatedAt = event.ts;
      // model: sticky across empty reports (a status-only report with no
      // --model must not blank the board), and split into "who is on it
      // now" vs. "who last did the work" so a reviewer's model doesn't
      // overwrite the implementer's credit.
      if (event.model) {
        task.model = event.model;
        if (event.status === "in_progress" || event.status === "done")
          task.implementer = event.model;
      }
      // startedAt: first in_progress only, never overwritten by a later one
      // (a "go around" restarts phase, not the clock).
      if (event.status === "in_progress" && task.startedAt === null)
        task.startedAt = event.ts;
      // commit: sticky once set, so a later regressive report (e.g. a
      // reopened task going back to in_progress) doesn't erase which sha
      // landed.
      if (event.status === "done" && event.commit) task.commit = event.commit;
      transcript.push({ ts: event.ts, event });
    } else if (event.kind === "assign") {
      for (const task of tasks.values())
        if (task.lane === event.lane) task.lane = null;
      for (const id of event.tasks) {
        const task = tasks.get(id);
        if (task) task.lane = event.lane;
      }
      transcript.push({ ts: event.ts, event });
    } else if (event.kind === "close") {
      closed = { ts: event.ts, text: event.text };
      transcript.push({ ts: event.ts, event });
    } else if (event.kind === "note") {
      transcript.push({ ts: event.ts, event });
    }
  }

  const ACTIVE: readonly Status[] = ["in_progress", "reviewing"];
  const threshold = options.staleMinutes * 60_000;
  for (const task of tasks.values()) {
    if (
      closed !== null ||
      !ACTIVE.includes(task.status) ||
      task.updatedAt === null
    ) {
      task.stale = false;
      continue;
    }
    const elapsed = options.now.getTime() - Date.parse(task.updatedAt);
    // An unparseable ts (Date.parse -> NaN) must not silently read as "not
    // stale" — that is the one failure mode staleness exists to catch.
    task.stale = Number.isNaN(elapsed) || elapsed > threshold;
  }

  const list = [...tasks.values()];
  const count = (status: Status) =>
    list.filter((t) => t.status === status).length;
  const summary: Summary = {
    total: list.length,
    pending: count("pending"),
    active: count("in_progress") + count("reviewing"),
    done: count("done"),
    blocked: count("blocked"),
    stale: list.filter((t) => t.stale).length,
    complete: list.length > 0 && list.every((t) => t.status === "done"),
  };

  const lanes: Record<string, string[]> = {};
  for (const task of list)
    if (task.lane) (lanes[task.lane] ??= []).push(task.id);

  return {
    run,
    tasks: list,
    lanes,
    transcript,
    unreadable,
    unknown,
    closed,
    firstEventAt,
    summary,
    attention: closed === null && (summary.blocked > 0 || summary.stale > 0),
  };
}
