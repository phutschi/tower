/**
 * The append-only log, and the two promises it keeps.
 *
 * Writing: every event is one `appendFileSync` of one line. The file is opened
 * with O_APPEND, and POSIX makes the seek-to-end plus the write indivisible
 * for a regular file on a local filesystem — so lanes in different worktrees
 * can report in the same millisecond and each line lands whole. That is the
 * entire concurrency story; there is no lock because none is needed. (It does
 * not hold on NFS. The README says so.)
 */
import { appendFileSync, readFileSync } from "node:fs";

import type { Event, TaskDef } from "./types.ts";
import { isStatus } from "./types.ts";
import { isValidId } from "./ids.ts";

/** Enforced by the callers that write a note (the `tower note` command), not here. */
export const NOTE_MAX_CHARS = 500;

export function appendEvent(path: string, event: Event): void {
  appendFileSync(path, `${JSON.stringify(event)}\n`, { flag: "a" });
}

export interface ParsedLine {
  raw: string;
  event: Event | null;
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const str = (value: unknown): value is string => typeof value === "string";

const strOrNull = (value: unknown): value is string | null =>
  value === null || typeof value === "string";

const isTaskDef = (value: unknown): value is TaskDef =>
  isRecord(value) &&
  str(value.id) &&
  isValidId(value.id) &&
  str(value.title) &&
  str(value.area);

export function parseEvent(raw: string): Event | null {
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!isRecord(value) || value.v !== 1 || !str(value.ts)) return null;
  switch (value.kind) {
    case "report":
      if (
        !str(value.task) ||
        !str(value.status) ||
        !isStatus(value.status) ||
        !str(value.phase) ||
        !str(value.model) ||
        !str(value.note) ||
        !str(value.commit)
      )
        return null;
      return {
        v: 1,
        kind: "report",
        ts: value.ts,
        task: value.task,
        status: value.status,
        phase: value.phase,
        model: value.model,
        note: value.note,
        commit: value.commit,
      };
    case "note":
      if (
        !str(value.text) ||
        !(value.task === null || str(value.task)) ||
        !(value.lane === null || str(value.lane))
      )
        return null;
      return {
        v: 1,
        kind: "note",
        ts: value.ts,
        text: value.text,
        task: value.task,
        lane: value.lane,
      };
    case "assign":
      if (
        !str(value.lane) ||
        !Array.isArray(value.tasks) ||
        !value.tasks.every(str)
      )
        return null;
      return {
        v: 1,
        kind: "assign",
        ts: value.ts,
        lane: value.lane,
        tasks: value.tasks,
      };
    case "close":
      if (!str(value.text)) return null;
      return { v: 1, kind: "close", ts: value.ts, text: value.text };
    case "add":
      if (!isTaskDef(value.task) || !strOrNull(value.after)) return null;
      return {
        v: 1,
        kind: "add",
        ts: value.ts,
        task: {
          id: value.task.id,
          title: value.task.title,
          area: value.task.area,
        },
        after: value.after,
      };
    case "change":
      if (
        !str(value.task) ||
        !strOrNull(value.title) ||
        !strOrNull(value.area) ||
        !strOrNull(value.after)
      )
        return null;
      return {
        v: 1,
        kind: "change",
        ts: value.ts,
        task: value.task,
        title: value.title,
        area: value.area,
        after: value.after,
      };
    case "remove":
      if (!str(value.task)) return null;
      return { v: 1, kind: "remove", ts: value.ts, task: value.task };
    default:
      return null;
  }
}

export interface ReadResult {
  lines: ParsedLine[];
  /** Byte offset after the last complete or torn line read. */
  offset: number;
  /** True when `fromOffset` was past the end: the file shrank and this read is from byte zero. */
  restarted: boolean;
}

export function readEvents(path: string, fromOffset: number): ReadResult {
  // One read gives both the bytes and the size they were read at, so a
  // concurrent append between a stat and a read can never make `offset`
  // claim bytes this call did not actually see.
  let buffer: Buffer;
  try {
    buffer = readFileSync(path);
  } catch {
    return { lines: [], offset: 0, restarted: false };
  }
  const size = buffer.length;
  // A smaller file than we last saw was truncated or rotated: start over.
  const restarted = fromOffset > size;
  const start = restarted ? 0 : fromOffset;
  const text = buffer.subarray(start).toString("utf8");
  const lines = text
    .split("\n")
    .filter((line) => line.length > 0)
    .map((raw) => ({ raw, event: parseEvent(raw) }));
  return { lines, offset: size, restarted };
}
