/**
 * The advice job: a headless Opus session reads the Panel's open issues and
 * the latest merges, and proposes an order and bundles. The hub stores the
 * proposal; nothing changes until the user accepts a part of it.
 */
import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { promisify } from "node:util";

import { parseProposal } from "../../hub/advice.ts";
import type { PanelIssue } from "../../types.ts";
import { runHeadless } from "../claude.ts";
import { sendInboxNote } from "../inbox.ts";
import { registerJobRunner } from "../station.ts";

const run = promisify(execFile);
const PROMPT = join(import.meta.dir, "../../prompts/advice.md");

/** The JSON object in a session's answer, fenced or bare; null if it holds none. */
function jsonIn(text: string): unknown {
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  try {
    return start < 0
      ? null
      : (JSON.parse(text.slice(start, end + 1)) as unknown);
  } catch {
    return null;
  }
}

registerJobRunner(
  "advice",
  async ({ job, hubUrl, workspace, emit, signal }) => {
    const res = await fetch(`${hubUrl}/api/issues`);
    if (!res.ok) throw new Error(`the hub refused its issues: ${res.status}`);
    const open = ((await res.json()) as PanelIssue[])
      .filter((i) => i.stage !== "closed")
      .map(({ repo, number, title, stage, issueArea, blockedBy }) => ({
        repo,
        number,
        title,
        stage,
        issueArea,
        blockedBy,
      }));
    const merges = (
      await run(
        "git",
        ["log", "--first-parent", "-n", "20", "--format=%h %cs %s"],
        {
          cwd: workspace.path,
        },
      )
    ).stdout;
    const prompt = `${readFileSync(PROMPT, "utf8")}
<open-issues>
${JSON.stringify(open)}
</open-issues>

<recent-merges repo="${job.repo}">
${merges}</recent-merges>
`;
    const session = await runHeadless({
      prompt,
      cwd: workspace.path,
      model: "opus",
      signal,
    });
    const ran = { sessionId: session.sessionId, tokens: session.tokens };
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
    const proposal = parseProposal(answer, (repo, n) =>
      open.some((i) => i.repo === repo && i.number === n),
    );
    if (typeof proposal === "string")
      return { outcome: "failed", reason: proposal, ...ran };
    await emit("proposal", { ...proposal });
    const parts = proposal.order.length + proposal.bundles.length;
    await sendInboxNote({
      thread: "Order advice",
      subject: "A new order advice",
      body: `A new order advice is on the Panel after a merge to ${job.repo}: ${parts} part${parts === 1 ? "" : "s"} to accept or reject.`,
      idempotencyKey: `panel-advice-${job.id}`,
    }).catch((err: unknown) => emit("inbox-failed", { error: String(err) }));
    return { outcome: "done", ...ran };
  },
);
