/**
 * The order advice on the hub: the head of each listed repo's main, the
 * proposals the advice jobs return, and the bundles the user accepted.
 * Nothing here changes GitHub; the hub writes an accepted order part.
 */
import { Database } from "bun:sqlite";

import type { AdviceProposal, Bundle, Decision } from "../types.ts";

/** A proposal as an advice session returns it: no ids, no decisions yet. */
export interface ProposalInput {
  order: Omit<AdviceProposal["order"][number], "decision">[];
  bundles: Omit<AdviceProposal["bundles"][number], "id" | "decision">[];
}

const isObject = (v: unknown): v is Record<string, unknown> =>
  typeof v === "object" && v !== null && !Array.isArray(v);
const isIssueNumber = (v: unknown): v is number =>
  typeof v === "number" && Number.isInteger(v) && v > 0;

/** A session's proposal, checked part by part, or why it is malformed. */
export function parseProposal(value: unknown): ProposalInput | string {
  const fail = (why: string) => `malformed proposal: ${why}`;
  if (!isObject(value)) return fail("not an object");
  const { order, bundles } = value;
  if (!Array.isArray(order) || !Array.isArray(bundles))
    return fail("order and bundles must be lists");
  const issues = (at: string, repo: unknown, list: unknown[]) => {
    if (typeof repo !== "string") return `${at}.repo is not a repo`;
    for (const n of list)
      if (!isIssueNumber(n)) return `${at} names ${String(n)}, not an issue`;
    return null;
  };
  const reason = (at: string, r: unknown) =>
    typeof r === "string" && r.trim() ? null : `${at}.reason is empty`;
  const out: ProposalInput = { order: [], bundles: [] };
  for (const [i, o] of order.entries()) {
    const at = `order[${i}]`;
    if (!isObject(o) || !Array.isArray(o.after) || !o.after.length)
      return fail(`${at} waits on no issue`);
    const why =
      issues(at, o.repo, [o.issue, ...o.after]) ??
      (o.after.includes(o.issue) ? `${at} comes after itself` : null) ??
      reason(at, o.reason);
    if (why) return fail(why);
    out.order.push({
      repo: o.repo as string,
      issue: o.issue as number,
      after: o.after as number[],
      reason: o.reason as string,
    });
  }
  for (const [i, b] of bundles.entries()) {
    const at = `bundles[${i}]`;
    if (!isObject(b) || !Array.isArray(b.issues))
      return fail(`${at} has no issues list`);
    const why =
      issues(at, b.repo, b.issues) ??
      (new Set(b.issues).size < 2
        ? `${at} bundles fewer than two issues`
        : null) ??
      reason(at, b.reason);
    if (why) return fail(why);
    out.bundles.push({
      repo: b.repo as string,
      issues: b.issues as number[],
      reason: b.reason as string,
    });
  }
  return out;
}

/**
 * The parts of a proposal whose issues are all open, and why each other part
 * was dropped: an issue closed since the session read them, or one it made up.
 */
export function keepOpen(
  p: ProposalInput,
  isOpen: (repo: string, issue: number) => boolean,
): { kept: ProposalInput; dropped: string[] } {
  const dropped: string[] = [];
  const open = (at: string, repo: string, issues: number[]) => {
    const shut = issues.find((n) => !isOpen(repo, n));
    if (shut === undefined) return true;
    dropped.push(`${at} names ${repo}#${shut}, not an open issue on the Panel`);
    return false;
  };
  return {
    kept: {
      order: p.order.filter((o, i) =>
        open(`order[${i}]`, o.repo, [o.issue, ...o.after]),
      ),
      bundles: p.bundles.filter((b, i) =>
        open(`bundles[${i}]`, b.repo, b.issues),
      ),
    },
    dropped,
  };
}

export class AdviceStore {
  private readonly db: Database;

  /** Its own connection to the hub's database, with its own tables. */
  constructor(path: string) {
    this.db = new Database(path, { create: true });
    this.db.exec(`
      PRAGMA journal_mode = WAL;
      CREATE TABLE IF NOT EXISTS heads (
        repo TEXT PRIMARY KEY,
        sha TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS proposals (
        id TEXT PRIMARY KEY,
        created_at TEXT NOT NULL,
        body TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS bundles (
        id TEXT PRIMARY KEY,
        repo TEXT NOT NULL,
        issues TEXT NOT NULL,
        accepted_at TEXT NOT NULL
      );
    `);
  }

  close() {
    this.db.close();
  }

  /** The head of `repo`'s main as last seen, if ever. */
  head(repo: string): string | undefined {
    return this.db
      .query<{ sha: string }, [string]>("SELECT sha FROM heads WHERE repo = ?")
      .get(repo)?.sha;
  }

  setHead(repo: string, sha: string) {
    this.db.run(
      "INSERT INTO heads (repo, sha) VALUES (?, ?) ON CONFLICT (repo) DO UPDATE SET sha = excluded.sha",
      [repo, sha],
    );
  }

  /** Stores an advice job's proposal under the job's id; a resend keeps the first. */
  add(id: string, input: ProposalInput, now: Date) {
    const proposal: AdviceProposal = {
      id,
      createdAt: now.toISOString(),
      order: input.order.map((o) => ({ ...o, decision: null })),
      bundles: input.bundles.map((b) => ({
        ...b,
        id: crypto.randomUUID(),
        decision: null,
      })),
    };
    this.db.run(
      "INSERT OR IGNORE INTO proposals (id, created_at, body) VALUES (?, ?, ?)",
      [id, proposal.createdAt, JSON.stringify(proposal)],
    );
  }

  /** The newest proposal: each one reads every merge before it. */
  latest(): AdviceProposal | null {
    const row = this.db
      .query<{ body: string }, []>(
        "SELECT body FROM proposals ORDER BY created_at DESC, rowid DESC LIMIT 1",
      )
      .get();
    return row ? (JSON.parse(row.body) as AdviceProposal) : null;
  }

  proposal(id: string): AdviceProposal | null {
    const row = this.db
      .query<{ body: string }, [string]>(
        "SELECT body FROM proposals WHERE id = ?",
      )
      .get(id);
    return row ? (JSON.parse(row.body) as AdviceProposal) : null;
  }

  /**
   * Why `order` (indexes into the proposal's order) and `bundles` (bundle ids)
   * cannot be decided: a part that is not there or was decided already.
   */
  undecided(
    p: AdviceProposal,
    order: number[],
    bundles: string[],
  ): string | null {
    for (const i of order)
      if (p.order[i]?.decision !== null) return `order part ${i} is not open`;
    for (const id of bundles)
      if (p.bundles.find((b) => b.id === id)?.decision !== null)
        return `bundle ${id} is not open`;
    return null;
  }

  /** Records the user's decision on parts of a proposal; an accepted bundle is stored. */
  decide(
    id: string,
    decision: Exclude<Decision, null>,
    order: number[],
    bundles: string[],
    now: Date,
  ) {
    this.db.transaction(() => {
      const p = this.proposal(id);
      if (!p) return;
      for (const i of order) p.order[i]!.decision = decision;
      for (const b of p.bundles) {
        if (!bundles.includes(b.id)) continue;
        b.decision = decision;
        if (decision !== "accepted") continue;
        // The newest bundle wins: its issues leave the older ones, and an
        // older one left with a single issue is no bundle.
        for (const old of this.bundles()) {
          if (old.repo !== b.repo) continue;
          const rest = old.issues.filter((n) => !b.issues.includes(n));
          if (rest.length === old.issues.length) continue;
          if (rest.length < 2)
            this.db.run("DELETE FROM bundles WHERE id = ?", [old.id]);
          else
            this.db.run("UPDATE bundles SET issues = ? WHERE id = ?", [
              JSON.stringify(rest),
              old.id,
            ]);
        }
        this.db.run(
          "INSERT INTO bundles (id, repo, issues, accepted_at) VALUES (?, ?, ?, ?)",
          [b.id, b.repo, JSON.stringify(b.issues), now.toISOString()],
        );
      }
      this.db.run("UPDATE proposals SET body = ? WHERE id = ?", [
        JSON.stringify(p),
        id,
      ]);
    })();
  }

  /** The accepted bundles, oldest first. */
  bundles(): Bundle[] {
    return this.db
      .query<
        { id: string; repo: string; issues: string; accepted_at: string },
        []
      >("SELECT * FROM bundles ORDER BY accepted_at, rowid")
      .all()
      .map((r) => ({
        id: r.id,
        repo: r.repo,
        issues: JSON.parse(r.issues) as number[],
        acceptedAt: r.accepted_at,
      }));
  }
}
