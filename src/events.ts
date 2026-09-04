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
import { appendFileSync, readFileSync, statSync } from "node:fs";

import type { Event } from "./types.ts";
import { isStatus } from "./types.ts";

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
    default:
      return null;
  }
}

export interface ReadResult {
  lines: ParsedLine[];
  /** Byte offset after the last complete or torn line read. */
  offset: number;
}

export function readEvents(path: string, fromOffset: number): ReadResult {
  let size: number;
  try {
    size = statSync(path).size;
  } catch {
    return { lines: [], offset: 0 };
  }
  // A smaller file than we last saw was truncated or rotated: start over.
  const start = fromOffset > size ? 0 : fromOffset;
  const buffer = readFileSync(path);
  const text = buffer.subarray(start).toString("utf8");
  const lines = text
    .split("\n")
    .filter((line) => line.length > 0)
    .map((raw) => ({ raw, event: parseEvent(raw) }));
  return { lines, offset: size };
}
