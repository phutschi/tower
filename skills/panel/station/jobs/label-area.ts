/**
 * The issue-area labelling job: a headless session on a small model reads a
 * new issue and the repo's context map, and picks the one context the issue
 * touches. The job sets that context's `area:` label, creating it first when
 * the repo has none yet. An issue that has an issue area already keeps it:
 * a person set it, and changing it by hand is the correction.
 */
import { execFile } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { promisify } from "node:util";

import { runHeadless } from "../claude.ts";
import { registerJobRunner } from "../station.ts";

const run = promisify(execFile);
const PROMPT = join(import.meta.dir, "../../prompts/label-area.md");

const HAS_AREA = "the issue has an issue area already";

const gh = async (...args: string[]) => (await run("gh", args)).stdout;

/** The contexts a CONTEXT-MAP.md lists: its `- [Name](path)` lines. */
export function contexts(map: string): string[] {
  return [...map.matchAll(/^\s*[-*]\s+\[([^\]]+)\]\(/gm)].map((m) =>
    m[1]!.trim(),
  );
}

/** The label of a context: `area:` and its name, lowercase, words joined by -. */
export const areaLabel = (context: string) =>
  `area:${context
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "")}`;

registerJobRunner("label-area", async ({ job, workspace, emit, signal }) => {
  const [number] = job.issues;
  const file = join(workspace.path, "CONTEXT-MAP.md");
  if (number === undefined || !existsSync(file))
    return { outcome: "done", reason: "the repo has no context map" };
  const names = contexts(readFileSync(file, "utf8"));
  if (names.length === 0)
    return { outcome: "done", reason: "the context map lists no context" };
  const view = async () =>
    JSON.parse(
      await gh(
        "issue",
        "view",
        String(number),
        "--repo",
        job.repo,
        "--json",
        "title,body,labels",
      ),
    ) as { title: string; body?: string; labels: { name: string }[] };
  const hasArea = (i: Awaited<ReturnType<typeof view>>) =>
    i.labels.some((l) => l.name.startsWith("area:"));
  const issue = await view();
  if (hasArea(issue)) return { outcome: "done", reason: HAS_AREA };

  // As JSON with < escaped, untrusted text cannot close the tag it sits in.
  const data = (v: unknown) => JSON.stringify(v).replaceAll("<", "\\u003c");
  const session = await runHeadless({
    prompt: `${readFileSync(PROMPT, "utf8")}
<contexts>
${data(names)}
</contexts>

<issue>
${data({ title: issue.title, body: issue.body ?? "" })}
</issue>
`,
    cwd: workspace.path,
    model: "haiku",
    tools: [],
    signal,
  });
  const ran = { sessionId: session.sessionId, tokens: session.tokens };
  if (session.error)
    return {
      outcome: "failed",
      reason: `${session.error.category}: ${session.error.message}`,
      ...ran,
    };
  const answer = session.finalText.trim();
  const context = names.find((n) => n.toLowerCase() === answer.toLowerCase());
  if (!context)
    return {
      outcome: "failed",
      reason: `the answer names no context of the map: ${answer.slice(0, 80)}`,
      ...ran,
    };

  const label = areaLabel(context);
  // Made if the repo lacks it. One that exists, or that another job of
  // this station made a moment ago, is set as it is.
  await gh(
    "label",
    "create",
    label,
    "--repo",
    job.repo,
    "--description",
    `Issue area: ${context}`,
  ).catch((err: unknown) => {
    if (!/already exists/.test(String(err))) throw err;
  });
  // A person may have set an issue area while the session ran: theirs stands.
  if (hasArea(await view()))
    return { outcome: "done", reason: HAS_AREA, ...ran };
  await gh(
    "issue",
    "edit",
    String(number),
    "--repo",
    job.repo,
    "--add-label",
    label,
  );
  await emit("issue-area", { label });
  return { outcome: "done", ...ran };
});
