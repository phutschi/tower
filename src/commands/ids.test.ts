import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { main } from "../main.ts";
import { seededRun } from "../testing.ts";

describe("tower ids", () => {
  test("prints the expanded ids, one per line, as assign would record them", async () => {
    const { io } = seededRun();
    expect(await main(["ids", " 1-2, ,auth-1,2"], io)).toBe(0);
    expect(io.out.join("")).toBe("1\n2\nauth-1\n");
  });

  test("refuses an id the run does not have, with the likely typo", async () => {
    const { io } = seededRun();
    expect(await main(["ids", "1,auth1"], io)).toBe(1);
    expect(io.out).toEqual([]);
    expect(io.err.join("")).toContain(
      'unknown task "auth1" — did you mean auth-1?',
    );
  });

  test("refuses a spec tower cannot read, in tower's words", async () => {
    const { io } = seededRun();
    expect(await main(["ids", "9-7"], io)).toBe(1);
    expect(io.err.join("")).toBe('tower: range "9-7" runs backwards\n');
  });

  test("records nothing", async () => {
    const { runDir, io } = seededRun();
    const before = readFileSync(join(runDir, "events.ndjson"), "utf8");
    expect(await main(["ids", "1-2"], io)).toBe(0);
    expect(readFileSync(join(runDir, "events.ndjson"), "utf8")).toBe(before);
  });
});
