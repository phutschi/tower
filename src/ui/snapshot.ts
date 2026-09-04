/**
 * The non-TTY rendering: the same rows the console draws, joined as text.
 * This is what an agent sees when it runs bare `tower` in a tool call, and
 * what `tower state` (without --json) prints.
 */
import type { State } from "../state.ts";
import type { Theme } from "../theme.ts";
import {
  boardRows,
  headerRows,
  laneRows,
  localClock,
  transcriptRows,
} from "./rows.ts";

export function renderSnapshot(
  state: State,
  theme: Theme,
  columns: number,
  now: Date,
  clock = localClock,
): string[] {
  const options = { now, clock };
  const width = Math.max(60, columns);
  return [
    ...headerRows(state, theme, width, options).map((r) => r.text),
    "",
    ...laneRows(state, theme, width).map((r) => r.text),
    "",
    theme.board,
    ...boardRows(state, theme, width - 1, 200, options).map(
      (r) => ` ${r.text}`,
    ),
    "",
    theme.transcript,
    ...transcriptRows(state, theme, width - 1, 12, options).map(
      (r) => ` ${r.text}`,
    ),
  ];
}
