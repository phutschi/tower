/**
 * Usage on the hub: the plan's limits from the Agent SDK's usage report, the
 * latest rate-limit values the jobs saw as a fallback, and the pause that
 * stops dispatch once Claude rejects a request at a limit.
 */
import { Database } from "bun:sqlite";

import type { RateLimitInfo } from "../station/claude.ts";
import type { UsageRow, UsageView } from "../types.ts";

const STATUSES: readonly string[] = ["allowed", "allowed_warning", "rejected"];

/** A rate-limit event's data, checked; null when it is not one. */
export function parseRateLimit(
  v: Record<string, unknown>,
): RateLimitInfo | null {
  const { status, rateLimitType, utilization, resetsAt } = v;
  if (typeof status !== "string" || !STATUSES.includes(status)) return null;
  if (rateLimitType !== undefined && typeof rateLimitType !== "string")
    return null;
  if (utilization !== undefined && typeof utilization !== "number") return null;
  if (
    resetsAt !== undefined &&
    (typeof resetsAt !== "string" || isNaN(Date.parse(resetsAt)))
  )
    return null;
  return {
    status: status as RateLimitInfo["status"],
    ...(rateLimitType === undefined ? {} : { rateLimitType }),
    ...(utilization === undefined ? {} : { utilization }),
    ...(resetsAt === undefined
      ? {}
      : { resetsAt: new Date(resetsAt).toISOString() }),
  };
}

/** The rows a job's rate-limit windows stand for; others have no row. */
const WINDOWS: Record<string, Pick<UsageRow, "kind" | "model">> = {
  five_hour: { kind: "session" },
  seven_day: { kind: "weekly_all" },
  seven_day_opus: { kind: "weekly_scoped", model: "Opus" },
  seven_day_sonnet: { kind: "weekly_scoped", model: "Sonnet" },
};
// shortcut: a rejection that names no reset pauses this long, read the reset from the error once the CLI names one.
const UNNAMED_RESET_MS = 15 * 60_000;

/** shortcut: utilization as a share (0-1) or a percent, settle once the CLI's unit is documented. */
const percentOf = (u: number) => (u <= 1 ? Math.round(u * 1000) / 10 : u);

type Window =
  { utilization: number | null; resets_at: string | null } | null | undefined;
/** The usage report's plan limits (its `rate_limits`) as the Panel's rows. */
export function usageRows(
  limits: {
    five_hour?: Window;
    seven_day?: Window;
    seven_day_opus?: Window;
    seven_day_sonnet?: Window;
    model_scoped?: ({ display_name: string } & NonNullable<Window>)[];
    [other: string]: unknown;
  } | null,
): UsageRow[] | null {
  if (!limits) return null;
  const rows: UsageRow[] = [];
  const add = (w: Window, row: Pick<UsageRow, "kind" | "model">) => {
    if (w?.utilization == null || !w.resets_at) return;
    rows.push({ ...row, percent: w.utilization, resetsAt: w.resets_at });
  };
  add(limits.five_hour, { kind: "session" });
  add(limits.seven_day, { kind: "weekly_all" });
  for (const m of limits.model_scoped ?? [])
    add(m, { kind: "weekly_scoped", model: m.display_name });
  // An answer from the CLI's cache has no per-model rows; these windows remain.
  if (!limits.model_scoped) {
    add(limits.seven_day_opus, { kind: "weekly_scoped", model: "Opus" });
    add(limits.seven_day_sonnet, { kind: "weekly_scoped", model: "Sonnet" });
  }
  // No row at all is no report: the view falls back to the jobs' values.
  return rows.length ? rows : null;
}

/**
 * The plan's limits from the Agent SDK's usage report; null when it has none
 * (no claude.ai login, no SDK installed, or the experimental call changed).
 */
export async function readUsageReport(
  opts: { timeoutMs?: number } = {},
): Promise<UsageRow[] | null> {
  let close = () => {};
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const { query } = await import("@anthropic-ai/claude-agent-sdk");
    let end = () => {};
    const ended = new Promise<void>((r) => (end = r));
    // A session that never gets a prompt: asking for usage spends no tokens.
    // No settings: the user's plugins, hooks and MCP servers need not start.
    const q = query({
      prompt: (async function* () {
        await ended;
        yield* [];
      })(),
      options: { settingSources: [] },
    });
    close = () => (end(), q.close());
    const report = await Promise.race([
      q.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET({
        skipBehaviors: true,
      }),
      new Promise<never>((_, reject) => {
        timer = setTimeout(
          () => reject(new Error("usage report timed out")),
          opts.timeoutMs ?? 30_000,
        );
      }),
    ]);
    return usageRows(report.rate_limits);
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
    close();
  }
}

export class UsageStore {
  private readonly db: Database;

  /** Its own connection to the hub's database, with its own tables. */
  constructor(path: string) {
    this.db = new Database(path, { create: true });
    this.db.exec(`
      PRAGMA journal_mode = WAL;
      CREATE TABLE IF NOT EXISTS rate_limits (
        window TEXT PRIMARY KEY,
        percent REAL NOT NULL,
        resets_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS pause (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        until TEXT NOT NULL
      );
    `);
  }

  close() {
    this.db.close();
  }

  /** When dispatch resumes, while it is paused. */
  pausedUntil(now: Date): string | null {
    const until = this.db
      .query<{ until: string }, []>("SELECT until FROM pause")
      .get()?.until;
    return until && until > now.toISOString() ? until : null;
  }

  /**
   * Keeps a job's rate-limit values, and pauses dispatch on a rejection
   * until its reset. Returns the reset when this began a pause or moved it to
   * a named later reset, so the hub tells the person once per reset.
   */
  record(info: RateLimitInfo, now: Date): string | null {
    if (info.rateLimitType && info.utilization !== undefined && info.resetsAt)
      this.db.run(
        `INSERT INTO rate_limits (window, percent, resets_at) VALUES (?, ?, ?)
         ON CONFLICT (window) DO UPDATE SET percent = excluded.percent, resets_at = excluded.resets_at`,
        [info.rateLimitType, percentOf(info.utilization), info.resetsAt],
      );
    if (info.status !== "rejected") return null;
    const until =
      info.resetsAt ?? new Date(now.getTime() + UNNAMED_RESET_MS).toISOString();
    // A rejection that arrives late, after its reset, pauses nothing.
    if (until <= now.toISOString()) return null;
    const paused = this.pausedUntil(now);
    if (paused && paused >= until) return null;
    this.db.run(
      "INSERT INTO pause (id, until) VALUES (1, ?) ON CONFLICT (id) DO UPDATE SET until = excluded.until",
      [until],
    );
    // A pause a named reset moved later is news; a guessed extension is not.
    return !paused || info.resetsAt ? until : null;
  }

  /** The limits view: the usage report's rows, or else the jobs' latest values. */
  view(report: UsageRow[] | null, now: Date): UsageView {
    const pausedUntil = this.pausedUntil(now);
    if (report?.length)
      return { rows: report, source: "usage-report", pausedUntil };
    const order = Object.keys(WINDOWS);
    const rows = this.db
      .query<{ window: string; percent: number; resets_at: string }, []>(
        "SELECT * FROM rate_limits",
      )
      .all()
      .filter((r) => WINDOWS[r.window])
      .sort((a, b) => order.indexOf(a.window) - order.indexOf(b.window))
      .map((r) => ({
        ...WINDOWS[r.window]!,
        percent: r.percent,
        resetsAt: r.resets_at,
      }));
    return { rows, source: "job-events", pausedUntil };
  }
}
