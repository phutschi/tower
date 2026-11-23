/** Retries for a job's calls to GitHub, the Inbox and the hub, which have outages. */
import { setTimeout as sleep } from "node:timers/promises";

/** Waits `ms`, or less when `signal` aborts. */
export const wait = (ms: number, signal: AbortSignal) =>
  sleep(ms, undefined, { signal }).catch(() => {});

/**
 * `fn` until it works, `tries` times at most, waiting twice as long after
 * each failure, `maxWaitMs` at most. A stopped job calls it no more, even
 * mid-retry.
 */
export async function retry<T>(
  fn: () => Promise<T>,
  signal: AbortSignal,
  opts: { tries: number; maxWaitMs: number },
): Promise<T> {
  for (let n = 1; ; n++) {
    signal.throwIfAborted();
    try {
      return await fn();
    } catch (err) {
      if (n >= opts.tries || signal.aborted) throw err;
      console.error(`station: ${String(err)}; trying again`);
      await wait(Math.min(1000 * 2 ** n, opts.maxWaitMs), signal);
    }
  }
}
