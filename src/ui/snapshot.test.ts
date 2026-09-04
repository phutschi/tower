import { expect, test } from "bun:test";

import { AIRPORT, PLAIN } from "../theme.ts";
import { demoState, DEMO_NOW } from "./demo.ts";
import { utcClock } from "./rows.ts";
import { renderSnapshot } from "./snapshot.ts";

test("the snapshot is the whole screen as text, at 60 and at 120 columns", () => {
  for (const columns of [60, 120]) {
    const lines = renderSnapshot(
      demoState(),
      AIRPORT,
      columns,
      DEMO_NOW,
      utcClock,
    );
    expect(lines[0]).toStartWith("TOWER ");
    expect(lines).toContain("DEPARTURES");
    expect(lines).toContain("TRANSCRIPT");
    expect(lines.every((l) => l.length <= columns)).toBe(true);
    expect(lines.join("\n")).toMatchSnapshot(`snapshot-${columns}`);
  }
});

test("plain shows literal states", () => {
  const text = renderSnapshot(demoState(), PLAIN, 100, DEMO_NOW, utcClock).join(
    "\n",
  );
  expect(text).toContain("in_progress");
  expect(text).not.toContain("airborne");
});
