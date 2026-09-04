import { describe, expect, test } from "bun:test";

import { appendEvent } from "../events.ts";
import { main } from "../main.ts";
import { eventsPath } from "../run.ts";
import { seededRun } from "../testing.ts";

describe("tower state --json", () => {
  test("prints the literal folded state with runDir, summary and attention", async () => {
    const { runDir, io } = seededRun();
    expect(await main(["state", "--json"], io)).toBe(0);
    const doc = JSON.parse(io.out.join(""));
    expect(doc.v).toBe(1);
    expect(doc.runDir).toBe(runDir);
    expect(doc.run.callsign).toBe("ACME");
    expect(doc.tasks).toHaveLength(3);
    expect(doc.tasks[0].status).toBe("pending");
    expect(doc.summary.total).toBe(3);
    expect(doc.attention).toBe(false);
    expect(doc.lanes).toEqual({ A: ["1", "2"], B: ["auth-1"] });
  });

  // Depends on the theme table (Task 12) and the non-TTY snapshot renderer
  // (Task 13), owned by lane B; turn this on once those are merged.
  test.todo(
    "without --json it prints the same as the non-TTY snapshot would (one literal board)",
    () => {
      throw new Error("wire up once theme.ts and ui/snapshot.ts exist");
    },
  );
});

describe("tower wait", () => {
  test("requires --timeout", async () => {
    const { io } = seededRun();
    expect(await main(["wait"], io)).toBe(1);
    expect(io.err.join("")).toContain("--timeout");
  });

  test("exits 3 quietly on a short timeout", async () => {
    const { io } = seededRun();
    expect(await main(["wait", "--timeout", "0.05"], io)).toBe(3);
    expect(io.out.join("")).toBe("");
  });

  test("exits 0 and prints the attention lines when something already needs a human", async () => {
    const { runDir, io } = seededRun();
    appendEvent(eventsPath(runDir), {
      v: 1,
      kind: "report",
      ts: io.now().toISOString(),
      task: "1",
      status: "blocked",
      phase: "",
      model: "",
      note: "needs the test DB created",
      commit: "",
    });
    expect(await main(["wait", "--timeout", "5"], io)).toBe(0);
    expect(io.out.join("")).toContain("needs the test DB created");
  });
});
