import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";

import { main } from "../main.ts";
import { readRun } from "../run.ts";
import { seededRun } from "../testing.ts";

describe("tower brief", () => {
  test("prints the composed brief for a lane with tasks", async () => {
    const { io } = seededRun({ A: ["1", "2"] });
    expect(await main(["brief", "A"], io)).toBe(0);
    expect(io.out.join("")).toContain("You are lane A");
  });

  test("a lane with no tasks exits 1", async () => {
    const { io } = seededRun({ A: ["1", "2"] });
    expect(await main(["brief", "Q"], io)).toBe(1);
    expect(io.err.join("")).toContain("lane Q");
  });

  test("no lane given is a usage error", async () => {
    const { io } = seededRun();
    expect(await main(["brief"], io)).toBe(1);
    expect(io.err.join("")).toContain("usage: tower brief");
  });

  test("an unreadable planPath is a warning, not a crash, and the brief still prints", async () => {
    const { runDir, io } = seededRun({ A: ["1", "2"] });
    const run = readRun(runDir);
    writeFileSync(
      join(runDir, "run.json"),
      JSON.stringify({ ...run, planPath: "/nope/plan.md" }, null, 2),
    );
    expect(await main(["brief", "A"], io)).toBe(0);
    expect(io.err.join("")).toContain("cannot read the plan");
    expect(io.out.join("")).toContain("You are lane A");
  });
});
