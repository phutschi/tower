/**
 * The console. Rows come from rows.ts; this file colours them and lays them
 * out for the terminal's height. `q` quits — the only key, because there are
 * no actions.
 */
import { Box, Text, useApp, useInput, useStdout } from "ink";
import { useEffect, useState } from "react";

import type { State } from "../state.ts";
import type { Theme } from "../theme.ts";
import type { Row, RowOptions, Tone } from "./rows.ts";
import { boardRows, headerRows, laneRows, transcriptRows } from "./rows.ts";

const COLOR: Record<Tone, string | undefined> = {
  title: "cyanBright",
  muted: "gray",
  active: "cyan",
  done: "gray",
  blocked: "red",
  pending: undefined,
  plain: undefined,
  warn: "yellow",
};

export const MIN_COLUMNS = 60;

function Line({ row }: { row: Row }) {
  const color = COLOR[row.tone];
  return (
    <Text
      {...(color !== undefined ? { color } : {})}
      bold={row.tone === "title"}
      wrap="truncate"
    >
      {row.text}
    </Text>
  );
}

export interface AppProps {
  state: State;
  theme: Theme;
  options: RowOptions;
  /** Test hook: a fixed size instead of the terminal's. */
  size?: { columns: number; rows: number };
}

export function App({ state, theme, options, size }: AppProps) {
  const { exit } = useApp();
  const { stdout } = useStdout();
  const [dims, setDims] = useState(
    size ?? { columns: stdout.columns ?? 80, rows: stdout.rows ?? 24 },
  );
  useEffect(() => {
    if (size) return;
    const onResize = () =>
      setDims({ columns: stdout.columns ?? 80, rows: stdout.rows ?? 24 });
    stdout.on("resize", onResize);
    return () => {
      stdout.off("resize", onResize);
    };
  }, [stdout, size]);
  useInput((input) => {
    if (input === "q") exit();
  });

  if (dims.columns < MIN_COLUMNS)
    return (
      <Text color="yellow">
        widen the terminal to at least {MIN_COLUMNS} columns
      </Text>
    );

  const header = headerRows(state, theme, dims.columns, options);
  const lanes = laneRows(state, theme, dims.columns);
  // header 3 + blank + lanes + blank + board heading + blank + transcript heading + blank + footer
  const chrome = 3 + 1 + lanes.length + 1 + 1 + 1 + 1 + 1 + 1;
  const free = Math.max(6, dims.rows - chrome);
  const transcriptH = Math.max(3, Math.min(8, Math.floor(free / 3)));
  const boardH = Math.max(3, free - transcriptH);
  const board = boardRows(state, theme, dims.columns - 1, boardH, options);
  const transcript = transcriptRows(
    state,
    theme,
    dims.columns - 1,
    transcriptH,
    options,
  );

  return (
    <Box flexDirection="column" width={dims.columns}>
      {header.map((row, i) => (
        <Line key={`h${i}`} row={row} />
      ))}
      <Text> </Text>
      {lanes.map((row, i) => (
        <Line key={`l${i}`} row={row} />
      ))}
      {lanes.length > 0 && <Text> </Text>}
      <Text bold>{theme.board}</Text>
      {board.map((row, i) => (
        <Box key={`b${i}`} paddingLeft={1}>
          <Line row={row} />
        </Box>
      ))}
      <Text> </Text>
      <Text bold>{theme.transcript}</Text>
      {transcript.map((row, i) => (
        <Box key={`t${i}`} paddingLeft={1}>
          <Line row={row} />
        </Box>
      ))}
      <Text> </Text>
      <Text color="gray">[q] close the {theme.title.toLowerCase()}</Text>
    </Box>
  );
}
