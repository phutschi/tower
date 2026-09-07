import { describe, expect, test } from "bun:test";

import type { ParsedLine } from "../events.ts";
import { fold } from "../state.ts";
import { AIRPORT, PLAIN } from "../theme.ts";
import type { Event, RunFile } from "../types.ts";
import { demoState, DEMO_NOW, DEMO_RUN } from "./demo.ts";
import {
  boardRows,
  elapsed,
  headerRows,
  laneRows,
  natoLetter,
  transcriptRows,
  utcClock,
} from "./rows.ts";

const state = demoState();
const opts = { now: DEMO_NOW, clock: utcClock };
const texts = (rows: { text: string }[]) => rows.map((r) => r.text);

describe("elapsed and the broadcast letter", () => {
  test("formats minutes and hours", () => {
    expect(elapsed(34 * 60_000)).toBe("34m");
    expect(elapsed((2 * 60 + 35) * 60_000)).toBe("2h35m");
    expect(elapsed(30_000)).toBe("0m");
  });
  test("advances one NATO letter per hour of the run, wrapping at 26", () => {
    expect(natoLetter(0)).toBe("ALFA");
    expect(natoLetter(2)).toBe("CHARLIE");
    expect(natoLetter(26)).toBe("ALFA");
  });
});

describe("headerRows", () => {
  test("title, broadcast, progress", () => {
    const rows = texts(headerRows(state, AIRPORT, 80, opts));
    expect(rows[0]).toContain("TOWER");
    expect(rows[0]).toContain("ACME · feature/widgets");
    expect(rows[1]).toBe(
      "INFORMATION CHARLIE · 21:47 · 2h34m since first departure",
    );
    expect(rows[2]).toContain("12 of 21 landed");
    // The demo's last reports leave only 14 (in_progress) and 15 (reviewing)
    // active — 2, not 3 — which matches spec.md's own screen mockup for this
    // run ("2 airborne").
    expect(rows[2]).toContain("2 airborne");
    expect(rows[2]).toContain("1 holding short");
  });
  test("a closed run says so in the broadcast row", () => {
    const rows = texts(
      headerRows(demoState({ closed: true }), AIRPORT, 80, opts),
    );
    expect(rows[1]).toContain("FIELD CLOSED");
    expect(rows[1]).toContain("shipped as v0.1.0");
  });
  test("plain is literal", () => {
    const rows = texts(headerRows(state, PLAIN, 80, opts));
    expect(rows[2]).toContain("12 of 21 done");
    expect(rows[2]).toContain("in_progress");
  });
});

describe("laneRows", () => {
  test("one entry per lane with its current task and model", () => {
    const [row] = texts(laneRows(state, AIRPORT, 120));
    expect(row).toContain("RUNWAY A  ▸ 14  sonnet-5[1m]");
    expect(row).toContain("RUNWAY B  ⚠ 12");
  });
  test("a lane with everything landed shows a tick", () => {
    const s = demoState();
    for (const t of s.tasks) if (t.lane === "B") t.status = "done";
    const [row] = texts(laneRows(s, AIRPORT, 120));
    expect(row).toContain("RUNWAY B  ✓");
  });
  test("wraps four lanes as two and two when one row is too narrow, with the units aligned", () => {
    const s = demoState();
    s.lanes = { A: [], B: [], C: [], D: [] };
    const wide = texts(laneRows(s, AIRPORT, 200));
    expect(wide).toHaveLength(1);
    expect(wide[0]).toMatch(/RUNWAY A.*RUNWAY B.*RUNWAY C.*RUNWAY D/);
    const rows = texts(laneRows(s, AIRPORT, 90));
    expect(rows).toHaveLength(2);
    expect(rows[0]).toMatch(/^RUNWAY A.*RUNWAY B/);
    expect(rows[1]).toMatch(/^RUNWAY C.*RUNWAY D/);
    expect(rows[0]?.indexOf("RUNWAY B")).toBe(
      rows[1]?.indexOf("RUNWAY D") ?? -1,
    );
    for (const row of rows) expect(row.length).toBeLessThanOrEqual(90);
  });
});

describe("boardRows", () => {
  test("splits the board into the airborne and on-the-ground sections, then the landed line", () => {
    const rows = texts(boardRows(state, AIRPORT, 120, 40, opts));
    expect(rows[0]).toBe("AIRBORNE");
    expect(rows[1]).toMatch(
      /^⚠ 12 .*B .*holding short: needs the test DB created$/,
    );
    expect(rows[2]).toMatch(
      /^▸ 14 .*A .*sonnet-5\[1m\].*go around.*NORDO 24m$/,
    );
    expect(rows[3]).toMatch(/^▸ 15 /);
    expect(rows[4]).toBe("ON THE GROUND");
    expect(rows[5]).toMatch(/^○ 16 /);
    expect(rows.slice(5, 11).every((r) => r.startsWith("○ "))).toBe(true);
    expect(rows[11]).toBe("✓ 12 landed  (1 … 13)");
    expect(rows.some((r) => r.startsWith("✓ 13"))).toBe(false);
  });
  test("plain is literal in the section headings", () => {
    const rows = texts(boardRows(state, PLAIN, 120, 40, opts));
    expect(rows).toContain("IN_PROGRESS");
    expect(rows).toContain("PENDING");
  });
  test("an empty section shows a dash", () => {
    const s = demoState();
    for (const t of s.tasks) if (t.status === "pending") t.status = "done";
    const rows = texts(boardRows(s, AIRPORT, 120, 40, opts));
    expect(rows[rows.indexOf("ON THE GROUND") + 1]).toBe("—");
  });
  test("when short, every airborne row stays and the ground is counted", () => {
    const rows = texts(boardRows(state, AIRPORT, 100, 8, opts));
    expect(rows).toHaveLength(8);
    for (const id of ["⚠ 12", "▸ 14", "▸ 15"])
      expect(rows.some((r) => r.startsWith(id))).toBe(true);
    expect(rows[rows.indexOf("ON THE GROUND") + 1]).toBe(
      `… 6 more ${AIRPORT.states.pending}`,
    );
    expect(rows.at(-1)).toBe("⚠ 1 unreadable line");
    expect(rows).not.toContain("✓ 12 landed  (1 … 13)");
  });
  test("an airborne row far down the plan is still on the board", () => {
    const s = demoState();
    const far = s.tasks.find((t) => t.id === "20");
    if (!far) throw new Error("demo lost task 20");
    far.status = "in_progress";
    far.phase = "implementing";
    far.model = "haiku";
    far.startedAt = new Date(DEMO_NOW.getTime() - 5 * 60_000).toISOString();
    const rows = texts(boardRows(s, AIRPORT, 100, 8, opts));
    expect(rows).toHaveLength(8);
    expect(rows.indexOf("ON THE GROUND")).toBeGreaterThan(
      rows.findIndex((r) => r.startsWith("▸ 20")),
    );
  });
  test("when even the airborne rows overflow, the count still leaves one ground row", () => {
    const rows = texts(boardRows(state, AIRPORT, 100, 5, opts));
    expect(rows).toEqual([
      "AIRBORNE",
      expect.stringMatching(/^⚠ 12 /),
      "… 2 more",
      "ON THE GROUND",
      `… 6 more ${AIRPORT.states.pending}`,
    ]);
  });
  test("never exceeds the width", () => {
    for (const row of texts(boardRows(state, AIRPORT, 60, 40, opts)))
      expect(row.length).toBeLessThanOrEqual(60);
  });
  test("omits the area column when every area is empty, includes it otherwise", () => {
    expect(
      texts(boardRows(state, AIRPORT, 140, 40, opts)).some((r) =>
        r.includes("apps/server"),
      ),
    ).toBe(true);
    const bare = demoState();
    for (const t of bare.tasks) t.area = "";
    expect(
      texts(boardRows(bare, AIRPORT, 140, 40, opts)).some((r) =>
        r.includes("apps/server"),
      ),
    ).toBe(false);
  });
  test("the unknown flight and the torn line appear as warnings after the board", () => {
    const rows = texts(boardRows(state, AIRPORT, 100, 40, opts));
    expect(rows.at(-2)).toBe("⚠ unknown flight 99");
    expect(rows.at(-1)).toBe("⚠ 1 unreadable line");
  });
  test("never exceeds the given height, even at extreme small heights", () => {
    for (const height of [0, 1, 2, 3, 4]) {
      const rows = boardRows(state, AIRPORT, 100, height, opts);
      expect(rows.length).toBeLessThanOrEqual(height);
    }
  });
  test("below four rows there are no headings, only the rows that need eyes", () => {
    const rows = texts(boardRows(state, AIRPORT, 100, 1, opts));
    expect(rows[0]?.startsWith("⚠ 12")).toBe(true);
    const three = texts(boardRows(state, AIRPORT, 100, 3, opts));
    expect(three[0]?.startsWith("⚠ 12")).toBe(true);
    expect(three[1]?.startsWith("▸ 14")).toBe(true);
    expect(three[2]?.startsWith("▸ 15")).toBe(true);
  });
});

describe("transcriptRows", () => {
  test("renders each kind in the theme's voice, newest last", () => {
    const rows = texts(transcriptRows(state, AIRPORT, 100, 40, opts));
    expect(rows).toContain("21:12:00  ACME 13   landed  a91c2f0");
    expect(rows).toContain(
      "21:13:00  ACME 14   cleared for takeoff · sonnet-5[1m]",
    );
    expect(rows).toContain("21:22:00  ACME 14   on approach · sonnet");
    expect(rows).toContain(
      "21:23:00  ACME 14   go around · spec review: missing null guard",
    );
    expect(rows).toContain("21:24:00  RUNWAY A  merged lane B at task 8");
    expect(rows).toContain(
      "21:25:00  TOWER     escalating 14 to opus after the second bounce",
    );
    expect(rows).toContain(
      "21:26:00  ACME 12   squawk 7700 · needs the test DB created",
    );
    expect(rows).toContain("21:27:00  ⚠ unknown flight 99");
    expect(rows).toContain("          ⚠ unreadable line");
    expect(rows).toContain("21:32:00  ACME 15   on final · opus");
  });
  test("keeps only the last `height` rows", () => {
    expect(transcriptRows(state, AIRPORT, 100, 3, opts)).toHaveLength(3);
  });
  test("a height of 0 shows nothing rather than everything", () => {
    expect(transcriptRows(state, AIRPORT, 100, 0, opts)).toHaveLength(0);
  });
  test("assign and close have the operator's voice", () => {
    const rows = texts(
      transcriptRows(demoState({ closed: true }), AIRPORT, 100, 40, opts),
    );
    expect(rows[0]).toBe(
      "19:12:00  TOWER     RUNWAY A ← 1, 2, 3, 4, 6, 10, 11, 14, 15, 16, 17, 18, 19, 20, 21",
    );
    expect(rows.at(-1)).toBe(
      "21:42:00  TOWER     field closed · shipped as v0.1.0",
    );
  });
  test("an empty log shows the theme's empty line", () => {
    const empty = { ...state, transcript: [] };
    expect(texts(transcriptRows(empty, AIRPORT, 100, 5, opts))).toEqual([
      "the field is quiet",
    ]);
  });

  test("add, change and remove read as tower's voice in the transcript", () => {
    const run: RunFile = {
      ...DEMO_RUN,
      tasks: [{ id: "1", title: "A", area: "" }],
    };
    const ev = (event: Event): ParsedLine => ({ raw: "", event });
    const state = fold(
      run,
      [
        ev({
          v: 1,
          kind: "add",
          ts: "2026-09-04T20:00:00.000Z",
          task: { id: "2", title: "Wire the webhook", area: "" },
          after: null,
        }),
        ev({
          v: 1,
          kind: "change",
          ts: "2026-09-04T20:01:00.000Z",
          task: "2",
          title: "Wire it",
          area: null,
          after: null,
        }),
        ev({
          v: 1,
          kind: "change",
          ts: "2026-09-04T20:01:30.000Z",
          task: "2",
          title: null,
          area: null,
          after: "99",
        }),
        ev({ v: 1, kind: "remove", ts: "2026-09-04T20:02:00.000Z", task: "2" }),
      ],
      { now: new Date("2026-09-04T20:05:00.000Z"), staleMinutes: 30 },
    );
    const text = transcriptRows(state, AIRPORT, 100, 10, {
      now: new Date("2026-09-04T20:05:00.000Z"),
      clock: utcClock,
    })
      .map((r) => r.text)
      .join("\n");
    expect(text).toContain("added ACME 2 · Wire the webhook");
    expect(text).toContain("changed ACME 2 · title");
    expect(text).toContain("⚠ unknown after 99");
    expect(text).toContain("removed ACME 2");
  });

  test("an unknown-task change or remove names the id, not just 'unknown flight'", () => {
    const run: RunFile = {
      ...DEMO_RUN,
      tasks: [{ id: "1", title: "A", area: "" }],
    };
    const ev = (event: Event): ParsedLine => ({ raw: "", event });
    const state = fold(
      run,
      [
        ev({
          v: 1,
          kind: "change",
          ts: "2026-09-04T20:00:00.000Z",
          task: "9",
          title: "x",
          area: null,
          after: null,
        }),
        ev({ v: 1, kind: "remove", ts: "2026-09-04T20:00:01.000Z", task: "9" }),
      ],
      { now: new Date("2026-09-04T20:05:00.000Z"), staleMinutes: 30 },
    );
    const text = transcriptRows(state, AIRPORT, 100, 10, {
      now: new Date("2026-09-04T20:05:00.000Z"),
      clock: utcClock,
    })
      .map((r) => r.text)
      .join("\n");
    expect(text).toContain("⚠ unknown flight 9");
    expect(text).not.toContain("unknown flight \n");
  });
});
