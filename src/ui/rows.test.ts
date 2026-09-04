import { describe, expect, test } from "bun:test";

import { AIRPORT, PLAIN } from "../theme.ts";
import { demoState, DEMO_NOW } from "./demo.ts";
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
});

describe("boardRows", () => {
  test("collapses the leading landed run, marks each state with its glyph, and appends the tail", () => {
    const rows = texts(boardRows(state, AIRPORT, 120, 40, opts));
    expect(rows[0]).toBe("✓ 11 landed  (1 … 11)");
    expect(rows.find((r) => r.startsWith("▸ 14"))).toMatch(
      /A .*sonnet-5\[1m\].*go around.*NORDO 24m$/,
    );
    expect(rows.find((r) => r.startsWith("⚠ 12"))).toMatch(
      /B .*holding short: needs the test DB created$/,
    );
    expect(rows.find((r) => r.startsWith("✓ 13"))).toMatch(
      /B .*opus .*a91c2f0$/,
    );
    expect(rows.find((r) => r.startsWith("○ 16"))).toBeDefined();
  });
  test("windows to the height, keeping the first row that needs eyes visible and counting the rest", () => {
    const rows = texts(boardRows(state, AIRPORT, 100, 5, opts));
    expect(rows).toHaveLength(5);
    expect(rows.some((r) => r.startsWith("⚠ 12") || r.startsWith("▸ 14"))).toBe(
      true,
    );
    expect(rows.at(-1)).toMatch(/^… \d+ more/);
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
    for (const height of [0, 1, 2, 3]) {
      const rows = boardRows(state, AIRPORT, 100, height, opts);
      expect(rows.length).toBeLessThanOrEqual(height);
    }
  });
  test("keeps the row that needs eyes visible even at height 1", () => {
    const rows = texts(boardRows(state, AIRPORT, 100, 1, opts));
    expect(rows[0]?.startsWith("⚠ 12")).toBe(true);
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
});
