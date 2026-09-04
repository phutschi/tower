/**
 * Bare `tower`. A terminal gets the alternate screen and the live console; a
 * pipe gets one literal snapshot and exit 0, because an agent will run this
 * in a tool call one day and must not hang a lane on a React app.
 */
import { parseArgs } from "node:util";
import { render } from "ink";
import { createElement } from "react";

import type { Io } from "../io.ts";
import type { Theme } from "../theme.ts";
import type { RunFile } from "../types.ts";
import { locateRun } from "../commands/locate.ts";
import { staleMinutes } from "../commands/state.ts";
import { readEvents } from "../events.ts";
import { UsageError } from "../io.ts";
import { eventsPath, readRun } from "../run.ts";
import { fold } from "../state.ts";
import { loadTheme } from "../theme.ts";
import { App } from "./App.tsx";
import { localClock } from "./rows.ts";
import { renderSnapshot } from "./snapshot.ts";
import { useRunState } from "./useRunState.ts";

const ESC = String.fromCharCode(27);
/** Enter the alternate screen and hide the cursor. */
export const ENTER_ALT = `${ESC}[?1049h${ESC}[?25l`;
/** Show the cursor and leave the alternate screen — the shell exactly as it was. */
export const LEAVE_ALT = `${ESC}[?25h${ESC}[?1049l`;

interface LiveProps {
  runDir: string;
  run: RunFile;
  theme: Theme;
  stale: number;
  now: () => Date;
}

function Live(props: LiveProps) {
  const state = useRunState({
    runDir: props.runDir,
    run: props.run,
    staleMinutes: props.stale,
    now: props.now,
  });
  return createElement(App, {
    state,
    theme: props.theme,
    options: { now: props.now(), clock: localClock },
  });
}

export async function consoleCommand(argv: string[], io: Io): Promise<number> {
  const { values } = parseArgs({
    args: argv,
    options: {
      run: { type: "string" },
      theme: { type: "string" },
      plain: { type: "boolean", default: false },
      stale: { type: "string" },
    },
  });
  const runDir = locateRun(io, values.run);
  const run = readRun(runDir);
  const themeName = values.plain ? "plain" : (values.theme ?? run.theme);
  let theme: Theme;
  try {
    theme = loadTheme(themeName, io.env);
  } catch (error) {
    throw new UsageError((error as Error).message);
  }
  const stale = staleMinutes(io, values.stale);

  if (!io.isTTY) {
    const state = fold(run, readEvents(eventsPath(runDir), 0).lines, {
      now: io.now(),
      staleMinutes: stale,
    });
    io.stdout(
      `${renderSnapshot(state, theme, io.columns, io.now()).join("\n")}\n`,
    );
    return 0;
  }

  process.stdout.write(ENTER_ALT);
  const restore = () => process.stdout.write(LEAVE_ALT);
  process.once("exit", restore);
  try {
    const app = render(
      createElement(Live, { runDir, run, theme, stale, now: io.now }),
      { exitOnCtrlC: true },
    );
    await app.waitUntilExit();
  } finally {
    process.off("exit", restore);
    restore();
  }
  return 0;
}
