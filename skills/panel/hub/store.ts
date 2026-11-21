/** The hub's SQLite tables: listed repos, the issue snapshot, jobs and their events. */
import { Database } from "bun:sqlite";

import type { Job, JobKind, Stage } from "../types.ts";

export interface SnapshotIssue {
  repo: string;
  number: number;
  title: string;
  stage: Stage;
  labels: string[];
}

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
});

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
        created_at TEXT NOT NULL
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
    const rows = this.db
      .query<
        {
          repo: string;
          number: number;
          title: string;
          stage: Stage;
          labels: string;
        },
        string[]
      >(
        `SELECT * FROM issues ${repo ? "WHERE repo = ?" : ""} ORDER BY repo, number`,
      )
      .all(...(repo ? [repo] : []));
    return rows.map((r) => ({
      ...r,
      labels: JSON.parse(r.labels) as string[],
    }));
  }

  issue(repo: string, number: number): SnapshotIssue | undefined {
    return this.issues(repo).find((i) => i.number === number);
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

  addJob(kind: JobKind, repo: string, issues: number[], now: Date): Job {
    const id = crypto.randomUUID();
    this.db.run(
      "INSERT INTO jobs (id, kind, repo, issues, state, created_at) VALUES (?, ?, ?, ?, 'queued', ?)",
      [id, kind, repo, JSON.stringify(issues), now.toISOString()],
    );
    return this.jobs().find((j) => j.id === id)!;
  }
}
