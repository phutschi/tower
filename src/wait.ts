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

function minutesSince(iso: string, now: Date): number {
  return Math.floor((now.getTime() - Date.parse(iso)) / 60_000);
}

/** The literal lines `tower wait` prints on exit 0. Never themed. */
export function attentionLines(state: State, now: Date): string[] {
  if (state.closed)
    return [`${pad("closed", 9)} ${state.closed.text}`.trimEnd()];
  if (state.summary.complete) return ["complete"];
  const lines: string[] = [];
  for (const task of state.tasks) {
    if (task.status === "blocked")
      lines.push(`${pad("blocked", 9)} ${pad(task.id, 8)} ${task.note}`);
  }
  for (const task of state.tasks) {
    if (task.stale && task.updatedAt)
      lines.push(
        `${pad("stale", 9)} ${pad(task.id, 8)} no event for ${minutesSince(task.updatedAt, now)}m`,
      );
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
  const run = readRun(options.runDir);
  const poll = options.pollMs ?? 2000;
  const started = Date.now();
  for (;;) {
    const now = options.now();
    const state = fold(run, readEvents(eventsPath(options.runDir), 0).lines, {
      now,
      staleMinutes: options.staleMinutes,
    });
    const lines = attentionLines(state, now);
    if (lines.length > 0) return { exit: 0, lines };
    if (Date.now() - started >= options.timeoutMs)
      return { exit: 3, lines: [] };
    await sleep(poll);
  }
}
