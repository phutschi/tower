import { describe, expect, test } from "bun:test";

import { appendEvent, readEvents } from "./events.ts";
import { eventsPath, readRun } from "./run.ts";
import { fold } from "./state.ts";
import { seededRun } from "./testing.ts";
import { attentionLines, waitFor } from "./wait.ts";

const NOW = new Date("2026-09-04T20:00:00.000Z");
const at = (min: number) => new Date(NOW.getTime() + min * 60_000);

describe("attentionLines", () => {
  test("a stale task with an unparseable timestamp prints no NaN", () => {
    const { runDir } = seededRun();
    appendEvent(eventsPath(runDir), {
      v: 1,
      kind: "report",
      ts: "not-a-date",
      task: "1",
      status: "in_progress",
      phase: "",
      model: "m",
      note: "",
      commit: "",
    });
    const state = fold(
      readRun(runDir),
      readEvents(eventsPath(runDir), 0).lines,
      { now: at(12), staleMinutes: 10 },
    );
    for (const line of attentionLines(state, at(12)))
      expect(line).not.toContain("NaN");
  });

  test("a blocked note has no trailing whitespace when empty", () => {
    const { runDir } = seededRun();
    appendEvent(eventsPath(runDir), {
      v: 1,
      kind: "report",
      ts: at(0).toISOString(),
      task: "1",
      status: "blocked",
      phase: "",
      model: "",
      note: "",
      commit: "",
    });
    const state = fold(
      readRun(runDir),
      readEvents(eventsPath(runDir), 0).lines,
      { now: at(12), staleMinutes: 10 },
    );
    expect(attentionLines(state, at(12))[0]).not.toMatch(/\s$/);
  });

  test("blocked and stale lines are literal and column-aligned", () => {
    const { runDir } = seededRun();
    appendEvent(eventsPath(runDir), {
      v: 1,
      kind: "report",
      ts: at(0).toISOString(),
      task: "auth-1",
      status: "blocked",
      phase: "",
      model: "",
      note: "needs the test DB created",
      commit: "",
    });
    appendEvent(eventsPath(runDir), {
      v: 1,
      kind: "report",
      ts: at(0).toISOString(),
      task: "1",
      status: "in_progress",
      phase: "implementing",
      model: "m",
      note: "",
      commit: "",
    });
    const state = fold(
      readRun(runDir),
      readEvents(eventsPath(runDir), 0).lines,
      { now: at(12), staleMinutes: 10 },
    );
    expect(attentionLines(state, at(12))).toEqual([
      "blocked   auth-1   needs the test DB created",
      "stale     1        no event for 12m",
    ]);
  });
});

describe("waitFor", () => {
  test("returns 0 at once when something already needs attention", async () => {
    const { runDir } = seededRun();
    appendEvent(eventsPath(runDir), {
      v: 1,
      kind: "report",
      ts: NOW.toISOString(),
      task: "1",
      status: "blocked",
      phase: "",
      model: "",
      note: "x",
      commit: "",
    });
    const result = await waitFor({
      runDir,
      timeoutMs: 1000,
      staleMinutes: 10,
      now: () => NOW,
      pollMs: 10,
    });
    expect(result.exit).toBe(0);
    expect(result.lines[0]).toStartWith("blocked");
  });

  test("does not overshoot the timeout by a full poll interval", async () => {
    const { runDir } = seededRun();
    const start = Date.now();
    await waitFor({
      runDir,
      timeoutMs: 50,
      staleMinutes: 10,
      now: () => NOW,
      // no pollMs override: the default poll (2000ms) must not be waited
      // out in full when the timeout is much shorter.
    });
    expect(Date.now() - start).toBeLessThan(500);
  });

  test("returns 3 with no lines on a quiet timeout", async () => {
    const { runDir } = seededRun();
    const result = await waitFor({
      runDir,
      timeoutMs: 50,
      staleMinutes: 10,
      now: () => NOW,
      pollMs: 10,
    });
    expect(result).toEqual({ exit: 3, lines: [] });
  });

  test("wakes when a report lands during the wait", async () => {
    const { runDir } = seededRun();
    setTimeout(() => {
      appendEvent(eventsPath(runDir), {
        v: 1,
        kind: "report",
        ts: NOW.toISOString(),
        task: "1",
        status: "blocked",
        phase: "",
        model: "",
        note: "later",
        commit: "",
      });
    }, 40);
    const result = await waitFor({
      runDir,
      timeoutMs: 2000,
      staleMinutes: 10,
      now: () => NOW,
      pollMs: 10,
    });
    expect(result.exit).toBe(0);
    expect(result.lines).toEqual(["blocked   1        later"]);
  });

  test("complete and closed also end the wait", async () => {
    const { runDir } = seededRun();
    for (const id of ["1", "2", "auth-1"])
      appendEvent(eventsPath(runDir), {
        v: 1,
        kind: "report",
        ts: NOW.toISOString(),
        task: id,
        status: "done",
        phase: "committed",
        model: "m",
        note: "",
        commit: "abc",
      });
    expect(
      (
        await waitFor({
          runDir,
          timeoutMs: 100,
          staleMinutes: 10,
          now: () => NOW,
          pollMs: 10,
        })
      ).lines,
    ).toEqual(["complete"]);
    appendEvent(eventsPath(runDir), {
      v: 1,
      kind: "close",
      ts: NOW.toISOString(),
      text: "shipped",
    });
    expect(
      (
        await waitFor({
          runDir,
          timeoutMs: 100,
          staleMinutes: 10,
          now: () => NOW,
          pollMs: 10,
        })
      ).lines,
    ).toEqual(["closed    shipped"]);
  });
});
