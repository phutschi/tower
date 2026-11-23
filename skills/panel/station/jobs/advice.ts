/**
 * The advice job: a headless Opus session reads the Panel's open issues and
 * the latest merges, and proposes an order and bundles. The hub stores the
 * proposal; nothing changes until the user accepts a part of it.
 */
import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { promisify } from "node:util";

import { keepOpen, parseProposal } from "../../hub/advice.ts";
import { GitHub, sameRepo } from "../../hub/github.ts";
import type { JobEvent, PanelIssue } from "../../types.ts";
import { jsonIn, reportLimits, runHeadless } from "../claude.ts";
import { sendInboxNote } from "../inbox.ts";
import { retry } from "../retry.ts";
import { registerJobRunner } from "../station.ts";

const run = promisify(execFile);
const PROMPT = join(import.meta.dir, "../../prompts/advice.md");
const github = new GitHub();

/** What the Inbox note counts of a proposal. */
type Parts = { order: unknown[]; bundles: unknown[] };

interface Commit {
  sha: string;
  commit: { message: string; committer: { date: string } };
  parents: { sha: string }[];
}

/**
 * `repo`'s latest 20 commits on main, one `sha date subject` line each:
 * main's own, following first parents as `git log --first-parent` does, so a
 * merged branch's commits crowd out no merge.
 */
async function latestCommits(repo: string): Promise<string[]> {
  const { stdout } = await run(
    "gh",
    ["api", `repos/${repo}/commits?per_page=100`],
    { timeout: 60_000 },
  );
  // shortcut: first parents within the latest 100 commits only, page on when a merged branch outgrows them.
  const listed = JSON.parse(stdout) as Commit[];
  const bySha = new Map(listed.map((c) => [c.sha, c]));
  const lines: string[] = [];
  for (let c = listed[0]; c && lines.length < 20;) {
    lines.push(
      `${c.sha.slice(0, 7)} ${c.commit.committer.date.slice(0, 10)} ${c.commit.message.split("\n")[0]}`,
    );
    c = c.parents[0] && bySha.get(c.parents[0].sha);
  }
  return lines;
}

registerJobRunner(
  "advice",
  async ({ job, hubUrl, workspace, emit, checkpoint, signal }) => {
    /** Points the person to the stored proposal; `ran` is its session's. */
    const note = async (proposal: Parts, ran: object) => {
      const parts = proposal.order.length + proposal.bundles.length;
      try {
        // The key makes a note that got through and is sent again post once.
        await retry(
          () =>
            sendInboxNote({
              thread: "Order advice",
              subject: "A new order advice",
              body: `A new order advice is on the Panel after a merge to ${job.repo}: ${parts} part${parts === 1 ? "" : "s"} to accept or reject.`,
              idempotencyKey: `panel-advice-${job.id}`,
            }),
          signal,
          { tries: 3, maxWaitMs: 1000 },
        );
      } catch (err) {
        return {
          outcome: "failed" as const,
          reason: `the proposal is on the Panel, but its Inbox note failed: ${String(err)}`,
          ...ran,
        };
      }
      return { outcome: "done" as const, ...ran };
    };

    // An earlier claim stored its proposal: only the note is left.
    const claimed = await fetch(`${hubUrl}/api/jobs/${job.id}`);
    if (!claimed.ok)
      throw new Error(`the hub refused job ${job.id}: ${claimed.status}`);
    const { events } = (await claimed.json()) as { events: JobEvent[] };
    const stored = events.filter((e) => e.kind === "proposal").at(-1);
    if (stored) return note(stored.data as Parts, {});

    const res = await fetch(`${hubUrl}/api/issues`);
    if (!res.ok) throw new Error(`the hub refused its issues: ${res.status}`);
    const open: Pick<
      PanelIssue,
      "repo" | "number" | "title" | "stage" | "issueArea" | "blockedBy"
    >[] = [];
    // Each issue's open blockers, read here: the hub checks only waiting runs'.
    for (const { repo, number, title, stage, issueArea } of (
      (await res.json()) as PanelIssue[]
    ).filter((i) => i.stage !== "closed")) {
      const blockers = await retry(
        () => github.openBlockers(repo, number),
        signal,
        { tries: 3, maxWaitMs: 1000 },
      );
      open.push({
        repo,
        number,
        title,
        stage,
        issueArea,
        // As refs: #5 in the same repo, acme/other#5 in another.
        blockedBy: blockers.map((b) =>
          sameRepo(b.repo, repo) ? `#${b.number}` : `${b.repo}#${b.number}`,
        ),
      });
    }
    // The latest commits on main of every listed repo, newest first.
    const listed = await fetch(`${hubUrl}/api/repos`);
    if (!listed.ok)
      throw new Error(`the hub refused its repos: ${listed.status}`);
    const repos = (await listed.json()) as string[];
    const merges = Object.fromEntries(
      await Promise.all(
        repos.map(async (r) => [
          r,
          await retry(() => latestCommits(r), signal, {
            tries: 3,
            maxWaitMs: 1000,
          }),
        ]),
      ),
    );
    // As JSON with < escaped, untrusted text cannot close the tag it sits in.
    const data = (v: unknown) => JSON.stringify(v).replaceAll("<", "\\u003c");
    const prompt = `${readFileSync(PROMPT, "utf8")}
<open-issues>
${data(open)}
</open-issues>

<recent-merges>
${data(merges)}
</recent-merges>
`;
    const session = await runHeadless({
      prompt,
      cwd: workspace.path,
      model: "opus",
      tools: [],
      signal,
    });
    // Sent now, not with the result: a claim that dies before it still counts.
    await emit("tokens", { ...session.tokens });
    if (session.sessionId)
      await emit("session", { sessionId: session.sessionId });
    await reportLimits(session, emit);
    const ran = { sessionId: session.sessionId };
    if (session.error)
      return {
        outcome: "failed",
        reason: `${session.error.category}: ${session.error.message}`,
        ...ran,
      };
    const answer = jsonIn(session.finalText);
    if (answer === null)
      return {
        outcome: "failed",
        reason: "malformed proposal: the answer holds no JSON object",
        ...ran,
      };
    const parsed = parseProposal(answer);
    if (typeof parsed === "string")
      return { outcome: "failed", reason: parsed, ...ran };
    // An issue the session made up makes the whole answer suspect.
    const { kept: proposal, dropped } = keepOpen(parsed, (repo, n) =>
      open.some((i) => i.repo === repo && i.number === n),
    );
    if (dropped.length)
      return {
        outcome: "failed",
        reason: `malformed proposal: ${dropped[0]}`,
        ...ran,
      };
    // Stored on the hub before the note points the person to it.
    try {
      await checkpoint("proposal", { ...proposal });
    } catch (err) {
      return { outcome: "failed", reason: String(err), ...ran };
    }
    return note(proposal, ran);
  },
);
