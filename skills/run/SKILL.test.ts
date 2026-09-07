/**
 * The skill must never restate command syntax that could drift from the
 * binary, must never name a harness, and must reference only real commands.
 * All three are cheap to check.
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "bun:test";

const skill = readFileSync(join(import.meta.dir, "SKILL.md"), "utf8");
const frontmatter = skill.split("---")[1] ?? "";

const VALID_COMMANDS = [
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
  "add",
];

test("has the open Agent Skills frontmatter", () => {
  expect(skill.startsWith("---\nname: run\n")).toBe(true);
  expect(frontmatter).toMatch(/^description: .+/m);
});

test("names no harness", () => {
  const lower = skill.toLowerCase();
  for (const word of [
    "claude code",
    "claude-code",
    "codex",
    "cursor",
    "gemini",
    "run_in_background",
  ])
    expect(lower).not.toContain(word);
});

test("uses only commands tower has", () => {
  const matches = [...skill.matchAll(/(?:^|`)tower ([a-z]+)/gm)];
  expect(matches.length).toBeGreaterThan(0);
  for (const match of matches) expect(VALID_COMMANDS).toContain(match[1]!);
});
