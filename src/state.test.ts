import { describe, expect, test } from "bun:test";

import type { Event, RunFile, Status } from "./types.ts";
import type { ParsedLine } from "./events.ts";
import { fold } from "./state.ts";

const run: RunFile = {
  v: 1,
  plan: "P",
  planPath: null,
  repo: "acme",
  branch: "main",
  callsign: "ACME",
  theme: "airport",
  startedAt: "2026-09-04T19:00:00.000Z",
  models: { implementer: "m" },
  tasks: [
    { id: "1", title: "A", area: "" },
    { id: "2", title: "B", area: "" },
    { id: "3", title: "C", area: "" },
  ],
};

const T0 = "2026-09-04T20:00:00.000Z";
const at = (min: number) =>
  new Date(Date.parse(T0) + min * 60_000).toISOString();
const line = (event: Event): ParsedLine => ({
  raw: JSON.stringify(event),
  event,
});
const report = (
  task: string,
  status: Status,
  min: number,
  extra: Partial<Extract<Event, { kind: "report" }>> = {},
) =>
  line({
    v: 1,
    kind: "report",
    ts: at(min),
    task,
    status,
    phase: "",
    model: "",
    note: "",
    commit: "",
    ...extra,
  });

const opts = { now: new Date(at(30)), staleMinutes: 10 };

describe("fold", () => {
  test("an empty log: every task pending, nothing needs attention", () => {
    const s = fold(run, [], opts);
    expect(s.tasks.map((t) => t.status)).toEqual([
      "pending",
      "pending",
      "pending",
    ]);
    expect(s.summary).toEqual({
      total: 3,
      pending: 3,
      active: 0,
      done: 0,
      blocked: 0,
      stale: 0,
      complete: false,
    });
    expect(s.attention).toBe(false);
    expect(s.closed).toBeNull();
  });

  test("last report wins; model is sticky as implementer on in_progress and done", () => {
    const s = fold(
      run,
      [
        report("1", "in_progress", 0, {
          phase: "implementing",
          model: "sonnet",
        }),
        report("1", "reviewing", 5, { phase: "spec-review", model: "opus" }),
      ],
      opts,
    );
    const t = s.tasks[0];
    expect(t?.status).toBe("reviewing");
    expect(t?.model).toBe("opus");
    expect(t?.implementer).toBe("sonnet");
    expect(t?.startedAt).toBe(at(0));
    expect(t?.updatedAt).toBe(at(5));
  });

  test("done keeps the commit and counts toward complete", () => {
    const s = fold(
      run,
      [
        report("1", "done", 0, { commit: "abc1234" }),
        report("2", "done", 1, { commit: "abc1235" }),
        report("3", "done", 2, { commit: "abc1236" }),
      ],
      opts,
    );
    expect(s.tasks[0]?.commit).toBe("abc1234");
    expect(s.summary.complete).toBe(true);
    expect(s.summary.done).toBe(3);
  });

  test("blocked is never stale, even out of contact", () => {
    const s = fold(run, [report("1", "blocked", 0, { note: "need db" })], {
      now: new Date(at(30)),
      staleMinutes: 10,
    });
    expect(s.tasks[0]?.stale).toBe(false);
    expect(s.summary.blocked).toBe(1);
  });

  test("an active task with no report for longer than the threshold is stale and needs attention", () => {
    const s = fold(run, [report("2", "in_progress", 5, { model: "m" })], {
      now: new Date(at(30)),
      staleMinutes: 10,
    });
    expect(s.tasks[1]?.stale).toBe(true);
    expect(s.summary.stale).toBe(1);
    expect(s.attention).toBe(true);
  });

  test("reviewing goes stale too", () => {
    const s = fold(run, [report("1", "reviewing", 0, { model: "m" })], {
      now: new Date(at(30)),
      staleMinutes: 10,
    });
    expect(s.tasks[0]?.stale).toBe(true);
  });

  test("pending and done never go stale", () => {
    const s = fold(run, [report("2", "done", 0)], {
      now: new Date(at(30)),
      staleMinutes: 10,
    });
    expect(s.tasks[0]?.stale).toBe(false);
    expect(s.tasks[1]?.stale).toBe(false);
  });

  test("a closed run never reports a task stale, even one that would otherwise qualify", () => {
    const s = fold(
      run,
      [
        report("1", "in_progress", 0, { model: "m" }),
        line({ v: 1, kind: "close", ts: at(1), text: "abandoned" }),
      ],
      { now: new Date(at(30)), staleMinutes: 10 },
    );
    expect(s.tasks[0]?.stale).toBe(false);
    expect(s.summary.stale).toBe(0);
  });

  test("an unparseable timestamp is treated as stale, not silently exempt", () => {
    const s = fold(
      run,
      [report("1", "in_progress", 0, { model: "m", ts: "not-a-date" })],
      { now: new Date(at(30)), staleMinutes: 10 },
    );
    expect(s.tasks[0]?.stale).toBe(true);
  });

  test("assign events give tasks a lane; a later assign moves them", () => {
    const s = fold(
      run,
      [
        line({ v: 1, kind: "assign", ts: at(0), lane: "A", tasks: ["1", "2"] }),
        line({ v: 1, kind: "assign", ts: at(1), lane: "B", tasks: ["2"] }),
      ],
      opts,
    );
    expect(s.tasks.map((t) => t.lane)).toEqual(["A", "B", null]);
    expect(s.lanes).toEqual({ A: ["1"], B: ["2"] });
  });

  test("an unknown task id is kept in the transcript and counted, never a new row", () => {
    const s = fold(run, [report("99", "done", 0)], opts);
    expect(s.tasks).toHaveLength(3);
    expect(s.unknown).toEqual(["99"]);
    expect(s.transcript.at(-1)?.problem).toBe("unknown-task");
  });

  test("repeated reports for the same unknown id are recorded once in unknown", () => {
    const s = fold(
      run,
      [report("99", "in_progress", 0, { model: "m" }), report("99", "done", 1)],
      opts,
    );
    expect(s.unknown).toEqual(["99"]);
  });

  test("a torn line is counted, not fatal", () => {
    const s = fold(run, [{ raw: '{"v":1,"ki', event: null }], opts);
    expect(s.unreadable).toBe(1);
    expect(s.transcript.at(-1)?.problem).toBe("unreadable");
  });

  test("order is file order, not timestamp order", () => {
    const s = fold(
      run,
      [report("1", "done", 10), report("1", "in_progress", 0, { model: "m" })],
      opts,
    );
    expect(s.tasks[0]?.status).toBe("in_progress");
  });

  test("a regressive report is visible: both lines stay in the transcript", () => {
    const s = fold(
      run,
      [report("1", "done", 0), report("1", "in_progress", 1, { model: "m" })],
      opts,
    );
    expect(s.transcript.filter((e) => e.event?.kind === "report")).toHaveLength(
      2,
    );
    expect(s.tasks[0]?.status).toBe("in_progress");
  });

  test("close is recorded and clears attention", () => {
    const s = fold(
      run,
      [
        report("1", "blocked", 0, { note: "x" }),
        line({ v: 1, kind: "close", ts: at(1), text: "abandoned" }),
      ],
      opts,
    );
    expect(s.closed).toEqual({ ts: at(1), text: "abandoned" });
    expect(s.attention).toBe(false);
  });

  test("firstEventAt is the first report, for the elapsed clock", () => {
    const s = fold(
      run,
      [
        line({ v: 1, kind: "assign", ts: at(0), lane: "A", tasks: ["1"] }),
        report("1", "in_progress", 3, { model: "m" }),
      ],
      opts,
    );
    expect(s.firstEventAt).toBe(at(3));
  });

  test("tasks come out in plan order regardless of report order", () => {
    const s = fold(run, [report("3", "done", 0), report("1", "done", 1)], opts);
    expect(s.tasks.map((t) => t.id)).toEqual(["1", "2", "3"]);
  });

  test("a plan with no tasks is never complete", () => {
    const emptyRun: RunFile = { ...run, tasks: [] };
    const s = fold(emptyRun, [], opts);
    expect(s.summary.complete).toBe(false);
  });
});
