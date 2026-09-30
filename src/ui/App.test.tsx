import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import chalk from "chalk";
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

  describe("colour", () => {
    // Under `bun test` stdout is no terminal, so chalk draws no colour at all.
    // FORCE_COLOR is read once, at import, so set the level on chalk itself.
    // This works because ink shares this one chalk copy; if it ever had its
    // own, "colours the rows when colour is on" fails.
    const ESC = String.fromCharCode(27);
    const level = chalk.level;
    beforeEach(() => {
      chalk.level = 1;
    });
    afterEach(() => {
      chalk.level = level;
    });

    const frame = (colour: boolean) => {
      const { lastFrame, unmount } = render(
        createElement(App, {
          state: demoState(),
          theme: AIRPORT,
          options: { now: DEMO_NOW, clock: utcClock },
          size: { columns: 100, rows: 30 },
          colour,
        }),
      );
      const text = lastFrame() ?? "";
      unmount();
      return text;
    };

    test("colours the rows when colour is on", () => {
      expect(frame(true)).toContain(`${ESC}[3`);
    });

    test("draws no colour when colour is off, and keeps bold", () => {
      const plain = frame(false);
      // SGR 30–39 and 90–97 are the foreground colours.
      expect(plain).not.toContain(`${ESC}[3`);
      expect(plain).not.toContain(`${ESC}[9`);
      expect(plain).toContain(`${ESC}[1m`);
      expect(plain).toContain("AIRBORNE");
    });
  });
});
