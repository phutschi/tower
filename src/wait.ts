/**
 * Block until the run needs a human. This is the one thing every
 * orchestrator loop wants and the one thing a harness-neutral tool can offer:
 * exit 0 with the reasons printed, or exit 3 in silence when the timeout
 * passes with nothing to say.
 *
 * Polling, not fs.watch: a wait is long and rare, a 2 s poll is invisible,
 * and fs.watch on macOS has enough edge cases that the console pairs it with
 * a poll anyway.
 */
import type { State } from "./state.ts";
import { readEvents } from "./events.ts";
import { eventsPath, readRun } from "./run.ts";
import { fold } from "./state.ts";

const pad = (text: string, width: number) => text.padEnd(width);

/** Minutes since `iso`, or null when `iso` doesn't parse to a real instant. */
function minutesSince(iso: string, now: Date): number | null {
  const minutes = Math.floor((now.getTime() - Date.parse(iso)) / 60_000);
  return Number.isFinite(minutes) ? minutes : null;
}

/** The literal lines `tower wait` prints on exit 0. Never themed. */
export function attentionLines(state: State, now: Date): string[] {
  if (state.closed)
    return [`${pad("closed", 9)} ${state.closed.text}`.trimEnd()];
  if (state.summary.complete) return ["complete"];
  const lines: string[] = [];
  for (const task of state.tasks) {
    if (task.status === "blocked")
      lines.push(
        `${pad("blocked", 9)} ${pad(task.id, 8)} ${task.note}`.trimEnd(),
      );
  }
  for (const task of state.tasks) {
    if (!task.stale || !task.updatedAt) continue;
    const minutes = minutesSince(task.updatedAt, now);
    const since = minutes === null ? "an unreadable time" : `${minutes}m`;
    lines.push(`${pad("stale", 9)} ${pad(task.id, 8)} no event for ${since}`);
  }
  return lines;
}

export interface WaitOptions {
  runDir: string;
  timeoutMs: number;
  staleMinutes: number;
  now: () => Date;
  pollMs?: number;
}

export interface WaitResult {
  exit: 0 | 3;
  lines: string[];
}

const sleep = (ms: number) =>
  new Promise<void>((resolve) => setTimeout(resolve, ms));

export async function waitFor(options: WaitOptions): Promise<WaitResult> {
  // readRun once: run.json is written once at init and never rewritten
  // (ADR 0001), so re-reading it every poll would be pure overhead.
  const run = readRun(options.runDir);
  const poll = options.pollMs ?? 2000;
  const started = Date.now();
  for (;;) {
    // The fold's clock is injected (so a test can freeze staleness), but the
    // deadline is real wall-clock time: a wait genuinely blocks a process.
    const now = options.now();
    const state = fold(run, readEvents(eventsPath(options.runDir), 0).lines, {
      now,
      staleMinutes: options.staleMinutes,
    });
    const lines = attentionLines(state, now);
    if (lines.length > 0) return { exit: 0, lines };
    const remaining = options.timeoutMs - (Date.now() - started);
    if (remaining <= 0) return { exit: 3, lines: [] };
    await sleep(Math.min(poll, remaining));
  }
}
