import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import chalk from "chalk";
import { render } from "ink-testing-library";

import { readRun } from "../run.ts";
import { fakeIo, seededRun } from "../testing.ts";
import { AIRPORT } from "../theme.ts";
import { liveConsole, usesColour } from "./console.tsx";

describe("usesColour", () => {
  test.each([
    ["NO_COLOR unset", {}, true],
    ["NO_COLOR=1", { NO_COLOR: "1" }, false],
    ["NO_COLOR=0 (any non-empty value)", { NO_COLOR: "0" }, false],
    ["NO_COLOR empty", { NO_COLOR: "" }, true],
  ])("%s", (_, env, expected) => {
    expect(usesColour(fakeIo({ env }))).toBe(expected);
  });
});

describe("the live console", () => {
  // Under `bun test` chalk draws no colour at all; force it on (see
  // App.test.tsx) so the console's own choice shows in the frame.
  const ESC = String.fromCharCode(27);
  const level = chalk.level;
  beforeEach(() => {
    chalk.level = 1;
  });
  afterEach(() => {
    chalk.level = level;
  });

  const frame = (env: Record<string, string>) => {
    const { runDir, io } = seededRun();
    io.env = { ...io.env, ...env };
    const { lastFrame, unmount } = render(
      liveConsole(io, {
        runDir,
        run: readRun(runDir),
        theme: AIRPORT,
        stale: 20,
      }),
    );
    const text = lastFrame() ?? "";
    unmount();
    return text;
  };

  test("draws colour from an Io without NO_COLOR", () => {
    expect(frame({})).toContain(`${ESC}[3`);
  });

  test("draws no colour from an Io with NO_COLOR set", () => {
    const plain = frame({ NO_COLOR: "1" });
    // SGR 30–39 and 90–97 are the foreground colours.
    expect(plain).not.toContain(`${ESC}[3`);
    expect(plain).not.toContain(`${ESC}[9`);
    expect(plain).toContain("DEPARTURES");
  });
});
