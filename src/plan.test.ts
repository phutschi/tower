import { describe, expect, test } from "bun:test";

import { parsePlan, parseTsv, sectionOf } from "./plan.ts";

const PLAN = `---
type: plan
project: acme — widgets
repo: acme
branch: feature/widgets
---

# Widgets Implementation Plan

**Goal**: ship widgets.

## Repo conventions every task must follow

- Tests: \`bun:test\`.
- No non-null assertions.

## File structure

stuff

## Tasks

### Task 1: The shared prompt shortcuts

body

### Task 3: \`summarizeValue\` moves to \`packages/core\`

body

### Task auth-1: The gate

body
`;

describe("parsePlan", () => {
  test("takes title, repo and branch from the frontmatter and the H1", () => {
    const plan = parsePlan(PLAN);
    expect(plan.title).toBe("Widgets Implementation Plan");
    expect(plan.repo).toBe("acme");
    expect(plan.branch).toBe("feature/widgets");
  });

  test("finds every task heading, in order, with backticks stripped", () => {
    expect(parsePlan(PLAN).tasks).toEqual([
      { id: "1", title: "The shared prompt shortcuts", area: "" },
      { id: "3", title: "summarizeValue moves to packages/core", area: "" },
      { id: "auth-1", title: "The gate", area: "" },
    ]);
  });

  test("a plan without frontmatter still parses; repo and branch are undefined", () => {
    const plan = parsePlan("# P\n\n## Tasks\n\n### Task 1: A\n");
    expect(plan.repo).toBeUndefined();
    expect(plan.tasks).toHaveLength(1);
    expect(plan.title).toBe("P");
  });

  test("task headings outside a ## Tasks section still count", () => {
    expect(
      parsePlan("# P\n\n### Task 1: A\n### Task 2: B\n").tasks,
    ).toHaveLength(2);
  });

  test("no tasks is an error naming the convention", () => {
    expect(() => parsePlan("# P\n\nnothing here\n")).toThrow(
      /### Task <id>: <title>/,
    );
  });

  test("a duplicate id is an error", () => {
    expect(() => parsePlan("# P\n### Task 1: A\n### Task 1: B\n")).toThrow(
      /duplicate/,
    );
  });

  test("falls back to the project key, then to 'untitled', for the title", () => {
    expect(parsePlan("---\nproject: X\n---\n### Task 1: A\n").title).toBe("X");
    expect(parsePlan("### Task 1: A\n").title).toBe("untitled");
  });
});

describe("sectionOf", () => {
  test("returns the body of a ## heading up to the next heading of the same or higher level", () => {
    expect(sectionOf(PLAN, "Repo conventions every task must follow")).toBe(
      "- Tests: `bun:test`.\n- No non-null assertions.",
    );
  });
  test("is undefined when the heading is absent", () => {
    expect(sectionOf(PLAN, "Nope")).toBeUndefined();
  });
});

describe("parseTsv", () => {
  test("id, title, optional area; comments and blanks skipped", () => {
    expect(
      parseTsv("# id\ttitle\tarea\n1\tA\tpackages/core\n\n2\tB\n"),
    ).toEqual([
      { id: "1", title: "A", area: "packages/core" },
      { id: "2", title: "B", area: "" },
    ]);
  });
  test("an invalid id names the line", () => {
    expect(() => parseTsv("a b\tX\n")).toThrow(/line 1/);
  });
});
