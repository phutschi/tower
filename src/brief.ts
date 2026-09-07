/**
 * The executor letter, composed from what is already determined: this lane's
 * tasks, the command block, the plan's own conventions section, the model
 * roles, and the two standing prohibitions. Nothing here is prose tower
 * cannot derive; the orchestrator writes the judgement around it.
 */
import type { State } from "./state.ts";

export function commandBlock(lane: string): string {
  return `Report every change of state with tower, from the repository root:

    tower task <id> <status> [phase] [note] --model <model>
    tower block <id> "<what you need>"
    tower note [--task <id> | --lane <lane>] "<text>"

status: pending | in_progress | reviewing | done | blocked
phases, in order: implementing → spec-review → quality-review → (fixing) → committed

The order per task:
    tower task <id> in_progress implementing --model <implementer>
    tower task <id> reviewing spec-review --model <spec-reviewer>
    tower task <id> reviewing quality-review --model <quality-reviewer>
    tower task <id> in_progress fixing "<what the review asked for>" --model <implementer>   (only on a bounce)
    tower task <id> done committed "<commit subject>" --model <implementer>

--model is required on in_progress and reviewing. Pass \`--model none\` only if you truly do not track models.
When you cannot proceed: tower block <id> "<exactly what you need>" — then stop and wait.
tower refuses a malformed report and prints the correct form; fix it and report again.

When you discover a task the plan does not have, add it before you start it:
    tower add "<title>" --lane ${lane}
It prints the id on the first line; report against that id. Split a task the same way, then tower remove the original.`;
}

export function composeBrief(
  state: State,
  lane: string,
  conventions: string | undefined,
  conventionsHeading = "Repo conventions every task must follow",
): string {
  const mine = state.tasks.filter((t) => t.lane === lane);
  if (mine.length === 0)
    throw new Error(
      state.tasks.length === 0
        ? `lane ${lane} has no tasks; this run has none yet: tower add "<title>" --lane ${lane}`
        : `lane ${lane} has no tasks; assign some first: tower assign ${lane} <ids>`,
    );
  const others = state.tasks.filter((t) => t.lane !== lane && t.lane !== null);
  const roles = Object.entries(state.run.models).map(
    ([role, model]) => `- ${role}: ${model || "(not set)"}`,
  );

  return [
    `# Brief for lane ${lane} — ${state.run.plan}`,
    "",
    `You are lane ${lane} on \`${state.run.repo}\`, branch \`${state.run.branch}\`.`,
    ...(state.run.planPath
      ? [
          `The plan is at ${state.run.planPath}. Read your tasks there in full before starting.`,
        ]
      : []),
    "",
    "## Your tasks, in order",
    "",
    ...mine.map((t) => `- ${t.id} — ${t.title}${t.area ? ` (${t.area})` : ""}`),
    "",
    others.length > 0
      ? `not yours: ${others.map((t) => `${t.id} (lane ${t.lane})`).join(", ")} — do not touch them.`
      : "Every task is yours.",
    "",
    "## Reporting",
    "",
    commandBlock(lane),
    "",
    `## ${conventionsHeading}`,
    "",
    conventions ?? "(the plan has no conventions section)",
    "",
    "## Models",
    "",
    ...roles,
    "",
    "## Standing rules",
    "",
    "- Never push. The orchestrator pushes.",
    "- Never open a pull request.",
    "- Commit after every task with a conventional message and no attribution lines.",
    "",
  ].join("\n");
}
