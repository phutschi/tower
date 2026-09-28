/**
 * One plugin, `tower`, with four skills. Its manifest carries the package's
 * version, and no name from the kit's old home (the `phutschi` plugin, the
 * herdr-orchestrate repo) is left behind.
 */
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "bun:test";

const root = join(import.meta.dir, "..");
const read = (path: string) => readFileSync(join(root, path), "utf8");
type Manifest = {
  version?: string;
  description?: string;
  plugins?: { name: string; description: string }[];
};
const json = (path: string) => JSON.parse(read(path)) as Manifest;

const SKILLS = ["run", "orchestrate", "spec-to-plan", "preflight"];

test("the plugin carries the package's version", () => {
  expect(json(".claude-plugin/plugin.json").version).toBe(
    json("package.json").version,
  );
});

test("the plugin and its marketplace entry name the four skills", () => {
  const plugin = json(".claude-plugin/plugin.json");
  const entry = json(".claude-plugin/marketplace.json").plugins?.find(
    (p) => p.name === "tower",
  );
  for (const description of [plugin.description, entry?.description])
    for (const skill of SKILLS)
      expect(description).toContain(`/tower:${skill}`);
});

// Files that keep the old names on purpose: history, and the parked glossary
// and ADRs (their own tasks rename them).
const HISTORY = /^(CHANGELOG\.md|docs\/kit-glossary\.md|docs\/adr\/)/;
// The install script removes the old plugin, marketplace and skill links, and
// its tests set them up.
const MIGRATION = /^(install\.sh|test\.sh)$/;

const STALE: { name: string; pattern: RegExp; migration: boolean }[] = [
  { name: "a /phutschi: command", pattern: /\/phutschi:/, migration: false },
  {
    name: "the phutschi plugin",
    pattern: /phutschi@phutschi/,
    migration: true,
  },
  // `.herdr-orchestrate` is the repo contract's old file name, still read.
  {
    name: "the herdr-orchestrate repo",
    pattern: /(?<!\.)herdr-orchestrate/,
    migration: true,
  },
  // phutschi-tower, phutschi/tower and @phutschi/tower are tower's own.
  {
    name: "phutschi as a plugin name",
    pattern: /(?<![/\w-])phutschi(?![-/@\w])/,
    migration: true,
  },
];

const files = execFileSync(
  "git",
  ["ls-files", "--cached", "--others", "--exclude-standard"],
  {
    cwd: root,
    encoding: "utf8",
  },
)
  .split("\n")
  .filter((f) => f && !HISTORY.test(f) && f !== "skills/plugin.test.ts");

test("no stale name from the kit's old home is left", () => {
  const hits: string[] = [];
  for (const file of files) {
    let text: string;
    try {
      text = read(file);
    } catch {
      continue; // listed but deleted in the working tree
    }
    if (text.includes("\0")) continue;
    text.split("\n").forEach((line, i) => {
      for (const { name, pattern, migration } of STALE)
        if (pattern.test(line) && !(migration && MIGRATION.test(file)))
          hits.push(`${file}:${i + 1}: ${name}`);
    });
  }
  expect(hits).toEqual([]);
});

test("orchestrate triggers on /tower:orchestrate and plans with /tower:spec-to-plan", () => {
  const frontmatter = read("skills/orchestrate/SKILL.md").split("---")[1] ?? "";
  expect(frontmatter).toContain("/tower:orchestrate <plan>");
  expect(frontmatter).toContain("/tower:spec-to-plan");
});

test("spec-to-plan is invoked by the user only", () => {
  const frontmatter =
    read("skills/spec-to-plan/SKILL.md").split("---")[1] ?? "";
  expect(frontmatter).toMatch(/^disable-model-invocation: true$/m);
});

test("specs and follow-ups go to tower's own issues", () => {
  const tracker = read("docs/agents/issue-tracker.md");
  expect(tracker).toContain("`phutschi/tower`");
  expect(tracker).toContain("gh issue create -R phutschi/tower ");
});

// A guard against home paths and for the acme example; the titles themselves
// are left to review.
test("the example tasks and fixtures are neutral", () => {
  const neutral = files.filter(
    (f) =>
      f === "skills/orchestrate/example-tasks.tsv" ||
      f.startsWith("skills/orchestrate/tests/fixtures/"),
  );
  expect(neutral.length).toBeGreaterThan(1);
  for (const file of neutral)
    expect(read(file)).not.toMatch(/\/Users\/|\/home\/|~\/(code|tools)\//);
  expect(read("skills/orchestrate/example-tasks.tsv")).toMatch(/^# .*acme/);
});

test("orchestrate checks for herdr first, and points to /tower:run", () => {
  const body = read("skills/orchestrate/SKILL.md").split("\n## ");
  const first = body[1] ?? "";
  expect(first).toMatch(/^First: /);
  expect(first).toContain("HERDR_ENV");
  expect(first).toContain("/tower:run");
});
