import { describe, expect, test } from "bun:test";

import type { RunFile } from "./types.ts";
import { composeBrief } from "./brief.ts";
import { fold } from "./state.ts";
import { TASKS } from "./testing.ts";

const run: RunFile = {
  v: 1,
  plan: "Widgets Implementation Plan",
  planPath: "/plans/widgets.md",
  repo: "acme",
  branch: "feature/widgets",
  callsign: "ACME",
  theme: "airport",
  startedAt: "t",
  models: {
    implementer: "sonnet-5[1m]",
    "spec-reviewer": "sonnet",
    "quality-reviewer": "opus",
  },
  tasks: TASKS,
};
const state = fold(
  run,
  [
    {
      raw: "",
      event: { v: 1, kind: "assign", ts: "t", lane: "A", tasks: ["1", "2"] },
    },
    {
      raw: "",
      event: { v: 1, kind: "assign", ts: "t", lane: "B", tasks: ["auth-1"] },
    },
  ],
  { now: new Date(), staleMinutes: 10 },
);

describe("composeBrief", () => {
  const brief = composeBrief(
    state,
    "A",
    "- No non-null assertions.\n- Tests: `bun:test`.",
  );

  test("names the lane's tasks and the ones it does not own", () => {
    expect(brief).toContain("You are lane A");
    expect(brief).toContain("1 — The shared prompt shortcuts");
    expect(brief).toContain("2 — The gate");
    expect(brief).toContain("not yours: auth-1 (lane B)");
  });
  test("carries the command block verbatim", () => {
    expect(brief).toContain(
      "tower task <id> <status> [phase] [note] --model <model>",
    );
    expect(brief).toContain('tower block <id> "<what you need>"');
    expect(brief).toContain("tower note");
  });
  test("carries the plan's conventions verbatim under their heading", () => {
    expect(brief).toContain("## Repo conventions every task must follow");
    expect(brief).toContain("- No non-null assertions.");
  });
  test("lists the model roles and the two prohibitions", () => {
    expect(brief).toContain("implementer: sonnet-5[1m]");
    expect(brief).toContain("quality-reviewer: opus");
    expect(brief).toContain("Never push");
    expect(brief).toContain("Never open a pull request");
  });
  test("says where the plan is", () => {
    expect(brief).toContain("/plans/widgets.md");
  });
  test("a lane with no tasks is refused", () => {
    expect(() => composeBrief(state, "Q", undefined)).toThrow(/lane Q/);
  });
  test("with no conventions section, says so instead of inventing one", () => {
    expect(composeBrief(state, "A", undefined)).toContain(
      "(the plan has no conventions section)",
    );
  });
  test("with no planPath, no stray blank line is left where the plan location would be", () => {
    const noPlanPath = fold(
      { ...run, planPath: null },
      [
        {
          raw: "",
          event: { v: 1, kind: "assign", ts: "t", lane: "A", tasks: ["1"] },
        },
      ],
      { now: new Date(), staleMinutes: 10 },
    );
    const brief = composeBrief(noPlanPath, "A", undefined);
    expect(brief).not.toContain("\n\n\n");
  });

  test("teaches tower add and that the printed id is what to report against", () => {
    expect(brief).toContain('tower add "<title>" --lane A');
    expect(brief).toContain("prints the id");
  });

  test("lists a task added after init under the lane's tasks", () => {
    const withAdded = fold(
      run,
      [
        {
          raw: "",
          event: {
            v: 1,
            kind: "assign",
            ts: "t",
            lane: "A",
            tasks: ["1", "2"],
          },
        },
        {
          raw: "",
          event: {
            v: 1,
            kind: "add",
            ts: "t",
            task: { id: "3", title: "Late task", area: "" },
            after: null,
          },
        },
        {
          raw: "",
          event: {
            v: 1,
            kind: "assign",
            ts: "t",
            lane: "A",
            tasks: ["1", "2", "3"],
          },
        },
      ],
      { now: new Date(), staleMinutes: 10 },
    );
    expect(composeBrief(withAdded, "A", undefined)).toContain(
      "- 3 — Late task",
    );
  });
});
