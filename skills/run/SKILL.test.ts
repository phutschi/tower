/**
 * The skill must never restate command syntax that could drift from the
 * binary, and must never name a harness. Both are cheap to check.
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "bun:test";

const skill = readFileSync(join(import.meta.dir, "SKILL.md"), "utf8");

test("has the open Agent Skills frontmatter", () => {
  expect(skill.startsWith("---\nname: run\n")).toBe(true);
  expect(skill).toMatch(/^description: .+/m);
});

test("names no harness", () => {
  for (const word of [
    "Claude Code",
    "Codex",
    "Cursor",
    "Gemini",
    "run_in_background",
  ])
    expect(skill).not.toContain(word);
});

test("uses only commands tower has", () => {
  const commands = [...skill.matchAll(/^tower (\w+)/gm)]
    .map((m) => m[1])
    .filter((c): c is string => c !== undefined);
  for (const command of commands)
    expect([
      "init",
      "brief",
      "wait",
      "close",
      "state",
      "note",
      "task",
      "block",
      "assign",
      "theme",
    ]).toContain(command);
});
