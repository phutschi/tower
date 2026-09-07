import { describe, expect, test } from "bun:test";
import { render } from "ink-testing-library";
import { createElement } from "react";

import { AIRPORT } from "../theme.ts";
import { App } from "./App.tsx";
import { demoState, DEMO_NOW } from "./demo.ts";
import { utcClock } from "./rows.ts";

describe("App", () => {
  test("draws the board and the transcript at 100x30", () => {
    const { lastFrame } = render(
      createElement(App, {
        state: demoState(),
        theme: AIRPORT,
        options: { now: DEMO_NOW, clock: utcClock },
        size: { columns: 100, rows: 30 },
      }),
    );
    const frame = lastFrame() ?? "";
    expect(frame).toContain("DEPARTURES");
    expect(frame).toContain("AIRBORNE");
    expect(frame).toContain("ON THE GROUND");
    expect(frame).toContain("✓ 12 landed");
    expect(frame).toContain("holding short");
    expect(frame).toContain("[q] close the tower");
    expect(frame.split("\n").length).toBeLessThanOrEqual(30);
  });

  test("asks to be widened under 60 columns", () => {
    const { lastFrame } = render(
      createElement(App, {
        state: demoState(),
        theme: AIRPORT,
        options: { now: DEMO_NOW, clock: utcClock },
        size: { columns: 50, rows: 30 },
      }),
    );
    expect(lastFrame()).toContain("at least 60 columns");
  });

  test("asks to be made taller under the minimum row count", () => {
    const { lastFrame } = render(
      createElement(App, {
        state: demoState(),
        theme: AIRPORT,
        options: { now: DEMO_NOW, clock: utcClock },
        size: { columns: 100, rows: 8 },
      }),
    );
    expect(lastFrame()).toContain("taller");
  });
});
