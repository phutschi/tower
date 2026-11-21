/** The hub's SQLite tables: listed repos, the issue snapshot, jobs and their events. */
import { Database } from "bun:sqlite";

import type {
  Job,
  JobEvent,
  JobKind,
  JobResult,
  JobState,
  Stage,
  Station,
} from "../types.ts";

/** The states of a job that is not over yet. */
export const ACTIVE: readonly JobState[] = ["queued", "held", "claimed"];

export interface SnapshotIssue {
  repo: string;
  number: number;
  title: string;
  stage: Stage;
  labels: string[];
}

type IssueRow = Omit<SnapshotIssue, "labels"> & { labels: string };
const toIssue = (r: IssueRow): SnapshotIssue => ({
  ...r,
  labels: JSON.parse(r.labels) as string[],
});

interface JobRow {
  id: string;
  kind: JobKind;
  repo: string;
  issues: string;
  state: Job["state"];
  station: string | null;
  lease_until: string | null;
  reason: string | null;
  session_id: string | null;
  created_at: string;
  duration_ms: number | null;
  tokens_in: number | null;
  tokens_out: number | null;
}

const toJob = (r: JobRow): Job => ({
  id: r.id,
  kind: r.kind,
  repo: r.repo,
  issues: JSON.parse(r.issues) as number[],
  state: r.state,
  station: r.station,
  leaseUntil: r.lease_until,
  reason: r.reason,
  sessionId: r.session_id,
  createdAt: r.created_at,
  durationMs: r.duration_ms,
  tokens:
    r.tokens_in === null || r.tokens_out === null
      ? null
      : { input: r.tokens_in, output: r.tokens_out },
});

/**
 * `station` holds the job, or held it until its lease ran out and nobody took
 * it since: it may renew it.
 */
const HOLDS =
  "((state = 'claimed' AND station = ?) OR (state = 'queued' AND lost_by = ?))";
/**
 * The same, or a run marked stuck when its lease ran out: its result still
 * counts. A stuck run is never renewed: the user was told it is over.
 */
const FINISHES =
  "((state = 'claimed' AND station = ?) OR (state IN ('queued', 'stuck') AND lost_by = ?))";

const OUTCOME: Record<JobResult["outcome"], JobState> = {
  done: "done",
  failed: "stuck",
  stopped: "stopped",
};

export class Store {
  private readonly db: Database;

  constructor(path: string) {
    this.db = new Database(path, { create: true });
    this.db.exec(`
      PRAGMA journal_mode = WAL;
      CREATE TABLE IF NOT EXISTS repos (
        name TEXT PRIMARY KEY,
        baselined INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS issues (
        repo TEXT NOT NULL,
        number INTEGER NOT NULL,
        title TEXT NOT NULL,
        stage TEXT NOT NULL,
        labels TEXT NOT NULL,
        PRIMARY KEY (repo, number)
      );
      CREATE TABLE IF NOT EXISTS jobs (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        repo TEXT NOT NULL,
        issues TEXT NOT NULL,
        state TEXT NOT NULL,
        station TEXT,
        lease_until TEXT,
        reason TEXT,
        session_id TEXT,
        created_at TEXT NOT NULL,
        duration_ms INTEGER,
        tokens_in INTEGER,
        tokens_out INTEGER,
        lost_by TEXT,
        claimed_at TEXT,
        stop_reason TEXT,
        noted INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS stations (
        name TEXT PRIMARY KEY,
        enabled INTEGER NOT NULL,
        job_limit INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS job_events (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        job_id TEXT NOT NULL,
        ts TEXT NOT NULL,
        kind TEXT NOT NULL,
        data TEXT NOT NULL
      );
    `);
  }

  close() {
    this.db.close();
  }

  /** Runs `fn` as one transaction: all its writes land, or none. */
  transaction(fn: () => void) {
    this.db.transaction(fn)();
  }

  repos(): { name: string; baselined: boolean }[] {
    return this.db
      .query<{ name: string; baselined: number }, []>(
        "SELECT name, baselined FROM repos ORDER BY name",
      )
      .all()
      .map((r) => ({ name: r.name, baselined: r.baselined === 1 }));
  }

  addRepo(name: string) {
    this.db.run("INSERT OR IGNORE INTO repos (name) VALUES (?)", [name]);
  }

  /** Unlists a repo; its issues leave the snapshot, its jobs stay as history. */
  removeRepo(name: string) {
    this.db.transaction(() => {
      this.db.run("DELETE FROM repos WHERE name = ?", [name]);
      this.db.run("DELETE FROM issues WHERE repo = ?", [name]);
    })();
  }

  markBaselined(name: string) {
    this.db.run("UPDATE repos SET baselined = 1 WHERE name = ?", [name]);
  }

  issues(repo?: string): SnapshotIssue[] {
    return this.db
      .query<IssueRow, string[]>(
        `SELECT * FROM issues ${repo ? "WHERE repo = ?" : ""} ORDER BY repo, number`,
      )
      .all(...(repo ? [repo] : []))
      .map(toIssue);
  }

  issue(repo: string, number: number): SnapshotIssue | undefined {
    const row = this.db
      .query<IssueRow, [string, number]>(
        "SELECT * FROM issues WHERE repo = ? AND number = ?",
      )
      .get(repo, number);
    return row ? toIssue(row) : undefined;
  }

  putIssue(i: SnapshotIssue) {
    this.db.run(
      `INSERT INTO issues (repo, number, title, stage, labels) VALUES (?, ?, ?, ?, ?)
       ON CONFLICT (repo, number) DO UPDATE SET
         title = excluded.title, stage = excluded.stage, labels = excluded.labels`,
      [i.repo, i.number, i.title, i.stage, JSON.stringify(i.labels)],
    );
  }

  jobs(): Job[] {
    return this.db
      .query<JobRow, []>("SELECT * FROM jobs ORDER BY created_at, rowid")
      .all()
      .map(toJob);
  }

  addJob(
    kind: JobKind,
    repo: string,
    issues: number[],
    now: Date,
    state: "queued" | "held" = "queued",
  ): Job {
    const id = crypto.randomUUID();
    this.db.run(
      "INSERT INTO jobs (id, kind, repo, issues, state, created_at) VALUES (?, ?, ?, ?, ?, ?)",
      [id, kind, repo, JSON.stringify(issues), state, now.toISOString()],
    );
    return this.job(id)!;
  }

  job(id: string): Job | undefined {
    const row = this.db
      .query<JobRow, [string]>("SELECT * FROM jobs WHERE id = ?")
      .get(id);
    return row ? toJob(row) : undefined;
  }

  stations(): Station[] {
    return this.db
      .query<{ name: string; enabled: number; job_limit: number }, []>(
        "SELECT * FROM stations ORDER BY name",
      )
      .all()
      .map((r) => ({
        name: r.name,
        enabled: r.enabled === 1,
        limit: r.job_limit,
      }));
  }

  /** A station, made on first sight: switched on only if it is the server's. */
  station(name: string, serverStation: string | undefined): Station {
    this.db.run(
      "INSERT OR IGNORE INTO stations (name, enabled, job_limit) VALUES (?, ?, 1)",
      [name, name === serverStation ? 1 : 0],
    );
    return this.stations().find((s) => s.name === name)!;
  }

  putStation(s: Station) {
    this.db.run(
      "UPDATE stations SET enabled = ?, job_limit = ? WHERE name = ?",
      [s.enabled ? 1 : 0, s.limit, s.name],
    );
  }

  /**
   * Hands the oldest queued job of one of `kinds` to `station`, with a lease
   * until `leaseUntil`, unless the station is off or at its limit.
   */
  claim(
    station: Station,
    kinds: JobKind[],
    now: Date,
    leaseUntil: Date,
  ): Job | null {
    let id: string | undefined;
    this.transaction(() => {
      const held = this.db
        .query<{ n: number }, [string]>(
          "SELECT count(*) AS n FROM jobs WHERE state = 'claimed' AND station = ?",
        )
        .get(station.name)!.n;
      if (!station.enabled || held >= station.limit || kinds.length === 0)
        return;
      id = this.db
        .query<{ id: string }, JobKind[]>(
          `SELECT id FROM jobs WHERE state = 'queued' AND kind IN (${kinds.map(() => "?").join(",")})
           ORDER BY created_at, rowid LIMIT 1`,
        )
        .get(...kinds)?.id;
      if (id)
        this.db.run(
          "UPDATE jobs SET state = 'claimed', station = ?, lease_until = ?, lost_by = NULL, claimed_at = ? WHERE id = ?",
          [station.name, leaseUntil.toISOString(), now.toISOString(), id],
        );
    });
    return id ? this.job(id)! : null;
  }

  /**
   * Renews the lease of a job `station` holds. A job whose lease ran out,
   * and that nobody claimed since, goes back to the station still working
   * it; a run marked stuck does not. False if it holds the job no more.
   */
  heartbeat(id: string, station: string, leaseUntil: Date): boolean {
    return (
      this.db.run(
        `UPDATE jobs SET state = 'claimed', station = ?, lease_until = ?, lost_by = NULL
         WHERE id = ? AND ${HOLDS}`,
        [station, leaseUntil.toISOString(), id, station, station],
      ).changes === 1
    );
  }

  /**
   * Ends a claimed job from the hub's side, as done: its run's PR is ready.
   * The station learns it from its next heartbeat and posts no result.
   */
  finishClaimed(id: string, now: Date) {
    this.db.run(
      `UPDATE jobs SET state = 'done', lease_until = NULL,
         duration_ms = CAST((julianday(?) - julianday(claimed_at)) * 86400000 AS INTEGER)
       WHERE id = ? AND state = 'claimed'`,
      [now.toISOString(), id],
    );
  }

  /**
   * A job whose lease ran out goes back to the queue, unless it is a run: a
   * run is not tried again by itself, it is stuck. One being stopped is
   * stopped.
   */
  expireLeases(now: Date) {
    this.db.run(
      `UPDATE jobs SET
         state = CASE WHEN stop_reason IS NOT NULL THEN 'stopped'
                      WHEN kind = 'run' THEN 'stuck' ELSE 'queued' END,
         reason = CASE WHEN stop_reason IS NOT NULL THEN stop_reason
                       WHEN kind = 'run' THEN 'its station stopped reporting' ELSE reason END,
         lost_by = station, station = NULL, lease_until = NULL
       WHERE state = 'claimed' AND lease_until < ?`,
      [now.toISOString()],
    );
  }

  /** Gives every claimed job a fresh lease: the hub was down, not its stations. */
  renewLeases(leaseUntil: Date) {
    this.db.run("UPDATE jobs SET lease_until = ? WHERE state = 'claimed'", [
      leaseUntil.toISOString(),
    ]);
  }

  /** The jobs of an issue that are not over and not being stopped. */
  activeJobs(repo: string, number: number): Job[] {
    return this.db
      .query<JobRow, [string]>(
        `SELECT * FROM jobs WHERE repo = ? AND state IN ('queued', 'held', 'claimed')
         AND stop_reason IS NULL ORDER BY created_at, rowid`,
      )
      .all(repo)
      .map(toJob)
      .filter((j) => j.issues.includes(number));
  }

  /**
   * Stops a job: one no station holds stops now; a claimed one is told
   * through its control route, and stops when its station posts the result.
   */
  requestStop(id: string, reason: string) {
    this.db.run(
      `UPDATE jobs SET
         state = CASE WHEN state = 'claimed' THEN state ELSE 'stopped' END,
         reason = CASE WHEN state = 'claimed' THEN reason ELSE ? END,
         stop_reason = ?
       WHERE id = ? AND state IN ('queued', 'held', 'claimed')`,
      [reason, reason, id],
    );
  }

  /** Whether a job's station should stop it, and why. */
  control(id: string): { stop: boolean; reason: string | null } | undefined {
    const row = this.db
      .query<{ stop_reason: string | null }, [string]>(
        "SELECT stop_reason FROM jobs WHERE id = ?",
      )
      .get(id);
    return row
      ? { stop: row.stop_reason !== null, reason: row.stop_reason }
      : undefined;
  }

  /**
   * Holds a job not yet claimed while it waits on the open issues `waits`,
   * or queues it once it waits on none.
   */
  hold(id: string, waits: number[]) {
    this.db.run(
      `UPDATE jobs SET state = ?, reason = ?
       WHERE id = ? AND state IN ('queued', 'held') AND stop_reason IS NULL`,
      waits.length
        ? ["held", `waits on ${waits.map((n) => `#${n}`).join(", ")}`, id]
        : ["queued", null, id],
    );
  }

  /** Stuck runs nobody was told about yet. */
  unnotedStuckRuns(): Job[] {
    return this.db
      .query<JobRow, []>(
        "SELECT * FROM jobs WHERE kind = 'run' AND state = 'stuck' AND noted = 0",
      )
      .all()
      .map(toJob);
  }

  markNoted(id: string) {
    this.db.run("UPDATE jobs SET noted = 1 WHERE id = ?", [id]);
  }

  addEvent(e: JobEvent) {
    this.db.run(
      "INSERT INTO job_events (job_id, ts, kind, data) VALUES (?, ?, ?, ?)",
      [e.jobId, e.ts, e.kind, JSON.stringify(e.data)],
    );
  }

  /** A job's events, in the order they arrived. */
  events(jobId: string): JobEvent[] {
    return this.db
      .query<{ ts: string; kind: string; data: string }, [string]>(
        "SELECT ts, kind, data FROM job_events WHERE job_id = ? ORDER BY seq",
      )
      .all(jobId)
      .map((r) => ({
        jobId,
        ts: r.ts,
        kind: r.kind,
        data: JSON.parse(r.data) as Record<string, unknown>,
      }));
  }

  /**
   * Records a job's result from `station`. It counts while that station
   * holds the job, or once its lease ran out and nobody claimed it since: a
   * finished job beats a second try. False when it does not count.
   */
  finish(station: string, r: JobResult): boolean {
    return (
      this.db.run(
        `UPDATE jobs SET state = ?, reason = ?, session_id = ?, duration_ms = ?,
           tokens_in = ?, tokens_out = ?, lease_until = NULL, station = ?, lost_by = NULL
         WHERE id = ? AND ${FINISHES}`,
        [
          OUTCOME[r.outcome],
          r.reason ?? null,
          r.sessionId ?? null,
          r.durationMs,
          r.tokens?.input ?? null,
          r.tokens?.output ?? null,
          station,
          r.jobId,
          station,
          station,
        ],
      ).changes === 1
    );
  }
}
