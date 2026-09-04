/**
 * Task sources. tower reads one markdown convention — `### Task <id>: <title>`
 * — plus a tab-separated list. Both are documented in docs/plan-format.md;
 * neither requires a particular planning tool.
 *
 * Frontmatter is read with a deliberately small parser: `key: value` lines
 * between two `---` fences. That is all any plan tower has met needed, and a
 * YAML library would be the project's first dependency that is not Ink.
 */
import type { TaskDef } from "./types.ts";
import { isValidId } from "./ids.ts";

const TASK_HEADING =
  /^###\s+Task\s+([A-Za-z0-9][A-Za-z0-9._-]*)\s*:\s*(.+?)\s*$/;
const TASK_CONVENTION = "### Task <id>: <title>";

export interface ParsedPlan {
  title: string;
  repo?: string;
  branch?: string;
  tasks: TaskDef[];
}

function frontmatter(markdown: string): {
  fields: Record<string, string>;
  body: string;
} {
  if (!markdown.startsWith("---\n")) return { fields: {}, body: markdown };
  const end = markdown.indexOf("\n---", 4);
  if (end === -1) return { fields: {}, body: markdown };
  const fields: Record<string, string> = {};
  for (const line of markdown.slice(4, end).split("\n")) {
    const colon = line.indexOf(":");
    if (colon === -1) continue;
    fields[line.slice(0, colon).trim()] = line.slice(colon + 1).trim();
  }
  return { fields, body: markdown.slice(end + 4) };
}

const stripBackticks = (text: string) => text.replaceAll("`", "");

export function parsePlan(markdown: string): ParsedPlan {
  const { fields, body } = frontmatter(markdown);
  const h1 = /^#\s+(.+?)\s*$/m.exec(body)?.[1];
  const title = h1 ?? fields.project ?? "untitled";
  const tasks: TaskDef[] = [];
  const seen = new Set<string>();
  for (const line of body.split("\n")) {
    const match = TASK_HEADING.exec(line);
    if (!match) continue;
    const id = match[1] as string;
    if (seen.has(id)) throw new Error(`duplicate task id "${id}" in the plan`);
    seen.add(id);
    tasks.push({ id, title: stripBackticks(match[2] as string), area: "" });
  }
  if (tasks.length === 0)
    throw new Error(
      `no tasks found; tower looks for headings shaped ${TASK_CONVENTION}`,
    );
  const plan: ParsedPlan = { title, tasks };
  if (fields.repo) plan.repo = fields.repo;
  if (fields.branch) plan.branch = fields.branch;
  return plan;
}

/** The text under `## <heading>`, up to the next `#` or `##` heading. */
export function sectionOf(
  markdown: string,
  heading: string,
): string | undefined {
  const lines = frontmatter(markdown).body.split("\n");
  const start = lines.findIndex((line) => line.trim() === `## ${heading}`);
  if (start === -1) return undefined;
  const rest = lines.slice(start + 1);
  const stop = rest.findIndex((line) => /^#{1,2}\s/.test(line));
  return rest
    .slice(0, stop === -1 ? undefined : stop)
    .join("\n")
    .trim();
}

export function parseTsv(text: string): TaskDef[] {
  const tasks: TaskDef[] = [];
  text.split("\n").forEach((line, index) => {
    if (!line.trim() || line.startsWith("#")) return;
    const [id = "", title = "", area = ""] = line
      .split("\t")
      .map((cell) => cell.trim());
    if (!isValidId(id))
      throw new Error(`line ${index + 1}: "${id}" is not a valid task id`);
    tasks.push({ id, title, area });
  });
  return tasks;
}
