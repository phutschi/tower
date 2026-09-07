/**
 * state = fold(run, lines). Pure: no I/O, and the clock is a parameter, so
 * the same log folds the same way in a test, in the console, and in
 * `tower state --json`.
 *
 * Rules that matter:
 *  - order is file order. Timestamps are for display; three shells in three
 *    worktrees do not share a clock.
 *  - the fold never invents a task from a report; only an `add` creates one.
 *    A report for an id the plan does not have is kept in the transcript,
 *    flagged, and counted — not a new row.
 *  - last report wins, and both stay in the transcript, so a task that went
 *    backwards is visible rather than rewritten.
 *  - stale applies to in_progress and reviewing only. blocked is already
 *    flagged; pending and done have nothing to hear from.
 */
import type { Event, RunFile, Status, TaskDef } from "./types.ts";
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
  /** Whether the plan defined this task or the run added it. */
  origin: "plan" | "added";
}

export interface TranscriptEntry {
  ts: string;
  event: Event | null;
  problem?: "unreadable" | "unknown-task" | "unknown-after";
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
  /** The id `tower add` picks when none is given: one above the largest integer id ever seen. */
  nextId: string;
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
  const blank = (t: TaskDef, origin: TaskState["origin"]): TaskState => ({
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
    origin,
  });

  // `order` is the board: ids in plan order, then adds. `known` keeps every
  // task ever defined, removed ones included, so a re-add restores history.
  // `removed` is the set of ids currently off the board.
  const order: string[] = run.tasks.map((t) => t.id);
  const known = new Map<string, TaskState>(
    run.tasks.map((t) => [t.id, blank(t, "plan")]),
  );
  const removed = new Set<string>();
  let maxInt = 0;
  const seeId = (id: string) => {
    if (/^\d+$/.test(id)) maxInt = Math.max(maxInt, Number(id));
  };
  for (const id of order) seeId(id);

  const onBoard = (id: string) => known.has(id) && !removed.has(id);

  /** Move `id` to right after `after` (or the end when null). Returns false when `after` is unknown. */
  const place = (id: string, after: string | null): boolean => {
    const at = order.indexOf(id);
    if (at !== -1) order.splice(at, 1);
    if (after === null || after === id) {
      order.push(id);
      return after === null;
    }
    const anchor = order.indexOf(after);
    if (anchor === -1 || !onBoard(after)) {
      order.push(id);
      return false;
    }
    order.splice(anchor + 1, 0, id);
    return true;
  };

  const transcript: TranscriptEntry[] = [];
  const unknown: string[] = [];
  let unreadable = 0;
  let closed: State["closed"] = null;
  // Named firstEventAt in the public contract, but only a *report* sets it:
  // assign/note/close/add/change/remove mark planning or narration, not
  // work starting, so they must not move the "elapsed since work began" clock.
  let firstEventAt: string | null = null;
  const flagUnknown = (id: string, event: Event) => {
    if (!unknown.includes(id)) unknown.push(id);
    transcript.push({ ts: event.ts, event, problem: "unknown-task" });
  };

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
      const task = onBoard(event.task) ? known.get(event.task) : undefined;
      if (!task) {
        flagUnknown(event.task, event);
        continue;
      }
      firstEventAt ??= event.ts;
      task.status = event.status;
      task.phase = event.phase;
      task.note = event.note;
      task.updatedAt = event.ts;
      if (event.model) {
        task.model = event.model;
        if (event.status === "in_progress" || event.status === "done")
          task.implementer = event.model;
      }
      if (event.status === "in_progress" && task.startedAt === null)
        task.startedAt = event.ts;
      if (event.status === "done" && event.commit) task.commit = event.commit;
      transcript.push({ ts: event.ts, event });
    } else if (event.kind === "assign") {
      for (const task of known.values())
        if (task.lane === event.lane) task.lane = null;
      for (const id of event.tasks) {
        const task = known.get(id);
        if (task && onBoard(id)) task.lane = event.lane;
      }
      transcript.push({ ts: event.ts, event });
    } else if (event.kind === "add") {
      const id = event.task.id;
      seeId(id);
      const existing = known.get(id);
      if (existing) {
        // An add for a known id is a change (and a restore if it was removed).
        existing.title = event.task.title;
        existing.area = event.task.area;
        removed.delete(id);
      } else {
        known.set(id, blank(event.task, "added"));
      }
      const placed = place(id, event.after);
      transcript.push(
        placed
          ? { ts: event.ts, event }
          : { ts: event.ts, event, problem: "unknown-after" },
      );
    } else if (event.kind === "change") {
      const task = onBoard(event.task) ? known.get(event.task) : undefined;
      if (!task) {
        flagUnknown(event.task, event);
        continue;
      }
      if (event.title !== null) task.title = event.title;
      if (event.area !== null) task.area = event.area;
      const placed =
        event.after === null ? true : place(event.task, event.after);
      transcript.push(
        placed
          ? { ts: event.ts, event }
          : { ts: event.ts, event, problem: "unknown-after" },
      );
    } else if (event.kind === "remove") {
      if (!onBoard(event.task)) {
        flagUnknown(event.task, event);
        continue;
      }
      removed.add(event.task);
      const at = order.indexOf(event.task);
      if (at !== -1) order.splice(at, 1);
      transcript.push({ ts: event.ts, event });
    } else if (event.kind === "close") {
      closed = { ts: event.ts, text: event.text };
      transcript.push({ ts: event.ts, event });
    } else if (event.kind === "note") {
      transcript.push({ ts: event.ts, event });
    }
  }

  const list = order.map((id) => known.get(id) as TaskState);

  const ACTIVE: readonly Status[] = ["in_progress", "reviewing"];
  const threshold = options.staleMinutes * 60_000;
  for (const task of list) {
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
    nextId: String(maxInt + 1),
  };
}
