/**
 * The screen as data. Every row is `{ text, tone }`; the console colours
 * tones and the snapshot ignores them. Nothing here touches a terminal, a
 * clock it was not handed, or a file.
 */
import type { State, TaskState, TranscriptEntry } from "../state.ts";
import type { Theme } from "../theme.ts";
import { labelFor } from "../theme.ts";

export type Tone =
  | "title"
  | "muted"
  | "active"
  | "done"
  | "blocked"
  | "pending"
  | "plain"
  | "warn"
  | "heading";
export interface Row {
  text: string;
  tone: Tone;
}

export interface RowOptions {
  now: Date;
  /** ISO timestamp → "HH:MM:SS". Injected so tests are timezone-proof. */
  clock: (iso: string) => string;
}

const two = (n: number) => String(n).padStart(2, "0");
export const utcClock = (iso: string) => {
  const d = new Date(iso);
  return `${two(d.getUTCHours())}:${two(d.getUTCMinutes())}:${two(d.getUTCSeconds())}`;
};
export const localClock = (iso: string) => {
  const d = new Date(iso);
  return `${two(d.getHours())}:${two(d.getMinutes())}:${two(d.getSeconds())}`;
};
const hhmm = (clock: RowOptions["clock"], date: Date) =>
  clock(date.toISOString()).slice(0, 5);

const fit = (text: string, width: number): string => {
  if (width <= 0) return "";
  if (text.length <= width) return text;
  return width === 1 ? "…" : `${text.slice(0, width - 1)}…`;
};
const pad = (text: string, width: number) => fit(text, width).padEnd(width);

export function elapsed(ms: number): string {
  const minutes = Math.max(0, Math.floor(ms / 60_000));
  const h = Math.floor(minutes / 60);
  return h > 0 ? `${h}h${two(minutes % 60)}m` : `${minutes}m`;
}

const NATO = [
  "ALFA",
  "BRAVO",
  "CHARLIE",
  "DELTA",
  "ECHO",
  "FOXTROT",
  "GOLF",
  "HOTEL",
  "INDIA",
  "JULIETT",
  "KILO",
  "LIMA",
  "MIKE",
  "NOVEMBER",
  "OSCAR",
  "PAPA",
  "QUEBEC",
  "ROMEO",
  "SIERRA",
  "TANGO",
  "UNIFORM",
  "VICTOR",
  "WHISKEY",
  "XRAY",
  "YANKEE",
  "ZULU",
];
export const natoLetter = (hour: number): string =>
  NATO[((hour % 26) + 26) % 26] ?? "ALFA";

export function headerRows(
  state: State,
  theme: Theme,
  columns: number,
  options: RowOptions,
): Row[] {
  const left = `${theme.title} `;
  const right = ` ${state.run.callsign} · ${state.run.branch}`;
  const rule = "─".repeat(Math.max(0, columns - left.length - right.length));
  const title = fit(`${left}${rule}${right}`, columns);

  let broadcast: string;
  if (state.closed) {
    broadcast = `${theme.states.closed.toUpperCase()} · ${hhmm(options.clock, new Date(state.closed.ts))}${state.closed.text ? ` · ${state.closed.text}` : ""}`;
  } else if (state.firstEventAt) {
    const ms = options.now.getTime() - Date.parse(state.firstEventAt);
    broadcast = `${theme.broadcast} ${natoLetter(Math.floor(ms / 3_600_000))} · ${hhmm(options.clock, options.now)} · ${elapsed(ms)} ${theme.elapsed}`;
  } else {
    broadcast = `${theme.broadcast} ${natoLetter(0)} · ${hhmm(options.clock, options.now)} · ${theme.empty}`;
  }

  const { done, total, active, blocked } = state.summary;
  const width = Math.min(26, Math.max(10, columns - 40));
  const filled = total === 0 ? 0 : Math.round((done / total) * width);
  const bar = `${"█".repeat(filled)}${"▒".repeat(width - filled)}`;
  const parts = [`${done} of ${total} ${theme.states.done}`];
  if (active) parts.push(`${active} ${theme.states.in_progress}`);
  if (blocked) parts.push(`${blocked} ${theme.states.blocked}`);
  const progress = fit(`${bar}  ${parts.join(" · ")}`, columns);

  return [
    { text: title, tone: "title" },
    { text: fit(broadcast, columns), tone: state.closed ? "warn" : "muted" },
    { text: progress, tone: "plain" },
  ];
}

const GLYPH: Record<TaskState["status"], string> = {
  pending: "○",
  in_progress: "▸",
  reviewing: "▸",
  done: "✓",
  blocked: "⚠",
};
const TONE: Record<TaskState["status"], Tone> = {
  pending: "pending",
  in_progress: "active",
  reviewing: "active",
  done: "done",
  blocked: "blocked",
};

function minutesQuiet(task: TaskState, now: Date): number {
  return task.updatedAt
    ? Math.floor((now.getTime() - Date.parse(task.updatedAt)) / 60_000)
    : 0;
}

/**
 * The runway strip: one cell per lane. When the cells do not fit one row they
 * wrap into as few rows as needed, spread evenly (four lanes wrap as two and
 * two, not three and one), with every cell padded to the same width so the
 * unit labels line up in columns.
 */
export function laneRows(state: State, theme: Theme, columns: number): Row[] {
  const lanes = Object.keys(state.lanes).sort();
  if (lanes.length === 0) return [];
  const cells = lanes.map((lane) => {
    const mine = state.tasks.filter((t) => t.lane === lane);
    const current =
      mine.find((t) => t.status === "blocked") ??
      mine.find(
        (t) => t.status === "in_progress" || t.status === "reviewing",
      ) ??
      mine.find((t) => t.status === "pending");
    if (!current) return `${theme.unit} ${lane}  ✓`;
    return `${theme.unit} ${lane}  ${GLYPH[current.status]} ${current.id}${current.model ? `  ${current.model}` : ""}`;
  });
  const gap = 8;
  const cellW = Math.max(...cells.map((c) => c.length));
  const perRowMax = Math.max(1, Math.floor((columns + gap) / (cellW + gap)));
  const lines = Math.ceil(cells.length / perRowMax);
  const perRow = Math.ceil(cells.length / lines);
  const rows: Row[] = [];
  for (let i = 0; i < cells.length; i += perRow) {
    const chunk = cells.slice(i, i + perRow);
    const text = chunk
      .map((c, j) => (j < chunk.length - 1 ? c.padEnd(cellW) : c))
      .join(" ".repeat(gap));
    rows.push({ text: fit(text, columns), tone: "plain" });
  }
  return rows;
}

function taskRow(
  task: TaskState,
  theme: Theme,
  columns: number,
  withArea: boolean,
  options: RowOptions,
): Row {
  const idW = 8;
  const laneW = 2;
  const modelW = 14;
  const areaW = withArea ? 16 : 0;
  let tail: string;
  if (task.status === "blocked") tail = `${theme.states.blocked}: ${task.note}`;
  else if (task.status === "done") tail = task.commit;
  else if (task.status === "pending") tail = "";
  else {
    const since = task.startedAt
      ? elapsed(options.now.getTime() - Date.parse(task.startedAt))
      : "";
    const label = labelFor(theme, task.status, task.phase);
    tail = [
      since,
      label,
      task.stale
        ? `${theme.states.stale} ${minutesQuiet(task, options.now)}m`
        : "",
    ]
      .filter(Boolean)
      .join(" · ");
  }
  const showModel = task.status !== "blocked" && task.status !== "pending";
  const fixed =
    2 +
    idW +
    2 +
    laneW +
    2 +
    (showModel ? modelW + 2 : 0) +
    (areaW ? areaW + 2 : 0);
  const titleW = Math.max(
    8,
    Math.min(32, columns - fixed - Math.min(tail.length, 24) - 2),
  );
  const cells = [
    `${GLYPH[task.status]} ${pad(task.id, idW)}`,
    pad(task.title, titleW),
    pad(task.lane ?? "", laneW),
  ];
  if (areaW) cells.push(pad(task.area, areaW));
  if (showModel)
    cells.push(
      pad(task.status === "done" ? task.implementer : task.model, modelW),
    );
  cells.push(tail);
  return {
    text: fit(cells.join("  ").trimEnd(), columns),
    tone: TONE[task.status],
  };
}

/**
 * The board: two sections — the flights that need eyes (blocked, then
 * active, in board order) under the in_progress label, and the pending ones
 * under the pending label — then one line for everything that landed, then
 * the warnings.
 */
export function boardRows(
  state: State,
  theme: Theme,
  columns: number,
  height: number,
  options: RowOptions,
): Row[] {
  const withArea = state.tasks.some((t) => t.area !== "");
  const row = (task: TaskState) =>
    taskRow(task, theme, columns, withArea, options);
  const running = state.tasks
    .filter((t) => t.status !== "done" && t.status !== "pending")
    .map(row);
  const waiting = state.tasks.filter((t) => t.status === "pending").map(row);
  const done = state.tasks.filter((t) => t.status === "done");
  const first = done[0]?.id ?? "";
  const last = done.at(-1)?.id ?? "";
  const landed: Row | null =
    done.length === 0
      ? null
      : {
          text: `✓ ${done.length} ${theme.states.done}  (${done.length === 1 ? first : `${first} … ${last}`})`,
          tone: "done",
        };

  const warnings: Row[] = [];
  for (const id of state.unknown)
    warnings.push({ text: `⚠ unknown ${theme.flight} ${id}`, tone: "warn" });
  if (state.unreadable > 0)
    warnings.push({
      text: `⚠ ${state.unreadable} unreadable line${state.unreadable === 1 ? "" : "s"}`,
      tone: "warn",
    });

  return windowBoard({ running, waiting, landed, warnings }, height, theme);
}

interface Board {
  running: Row[];
  waiting: Row[];
  landed: Row | null;
  warnings: Row[];
}

/** The first `n` rows; when that hides some, the last shown row is their count. */
function takeUpTo(rows: Row[], n: number, label: string): Row[] {
  if (rows.length <= n) return rows;
  if (n <= 0) return [];
  const shown = rows.slice(0, n - 1);
  return [
    ...shown,
    {
      text: `… ${rows.length - shown.length} more${label ? ` ${label}` : ""}`,
      tone: "muted",
    },
  ];
}

const EMPTY_SECTION: Row = { text: "—", tone: "muted" };

/**
 * Lay the board out in `height` rows. Rows are handed out in this order:
 * every running row, one waiting row (or the count), the warnings, the
 * landed line, then the rest of the waiting rows. Always returns at most
 * `height` rows.
 */
function windowBoard(board: Board, height: number, theme: Theme): Row[] {
  if (height <= 0) return [];
  const runBody = board.running.length ? board.running : [EMPTY_SECTION];
  const waitBody = board.waiting.length ? board.waiting : [EMPTY_SECTION];

  // Too short for two headings: just the rows that need eyes, and at a
  // single row the first of them rather than their count.
  if (height < 4) {
    const rows = board.running.length ? board.running : board.waiting;
    if (height === 1) return rows.slice(0, 1);
    return takeUpTo(
      rows,
      height,
      board.running.length ? "" : theme.states.pending,
    );
  }

  let left = height - 2;
  const runN = Math.min(runBody.length, left - 1);
  left -= runN;
  let waitN = 1;
  left -= 1;
  const warnings = board.warnings.slice(0, left);
  left -= warnings.length;
  const landed = board.landed && left > 0 ? [board.landed] : [];
  left -= landed.length;
  waitN += Math.max(0, Math.min(left, waitBody.length - waitN));

  return [
    { text: theme.states.in_progress.toUpperCase(), tone: "heading" },
    ...takeUpTo(runBody, runN, ""),
    { text: theme.states.pending.toUpperCase(), tone: "heading" },
    ...takeUpTo(waitBody, waitN, theme.states.pending),
    ...landed,
    ...warnings,
  ];
}

function speaker(entry: TranscriptEntry, state: State, theme: Theme): string {
  const e = entry.event;
  if (!e) return "";
  if (e.kind === "report") return `${state.run.callsign} ${e.task}`;
  if (e.kind === "note")
    return e.task
      ? `${state.run.callsign} ${e.task}`
      : e.lane
        ? `${theme.unit} ${e.lane}`
        : theme.operator;
  return theme.operator;
}

export function transcriptRows(
  state: State,
  theme: Theme,
  columns: number,
  height: number,
  options: RowOptions,
): Row[] {
  if (state.transcript.length === 0)
    return [{ text: theme.empty, tone: "muted" }];
  const started = new Set<string>();
  const rows: Row[] = [];
  for (const entry of state.transcript) {
    const e = entry.event;
    const time = entry.ts ? options.clock(entry.ts) : "        ";
    const who = pad(speaker(entry, state, theme), 9);
    let text: string;
    let tone: Tone = "plain";
    if (!e) {
      text = `${time}  ⚠ unreadable line`;
      tone = "warn";
    } else if (entry.problem === "unknown-task") {
      const id =
        e.kind === "report" || e.kind === "change" || e.kind === "remove"
          ? e.task
          : "";
      text = `${time}  ⚠ unknown ${theme.flight} ${id}`;
      tone = "warn";
    } else if (e.kind === "report") {
      let what: string;
      if (e.status === "blocked") {
        what = `${theme.verbs.blocked} · ${e.note}`;
        tone = "blocked";
      } else if (e.status === "done") {
        what = `${labelFor(theme, "done", e.phase)}  ${e.commit}`.trimEnd();
        tone = "done";
      } else if (
        e.status === "in_progress" &&
        e.phase !== "fixing" &&
        !started.has(e.task)
      ) {
        what = `${theme.verbs.started}${e.model ? ` · ${e.model}` : ""}`;
        tone = "active";
      } else {
        const detail = e.note || e.model;
        what = `${labelFor(theme, e.status, e.phase)}${detail ? ` · ${detail}` : ""}`;
        tone = e.status === "pending" ? "pending" : "active";
      }
      if (e.status === "in_progress") started.add(e.task);
      text = `${time}  ${who} ${what}`;
    } else if (e.kind === "note") {
      text = `${time}  ${who} ${e.text}`;
    } else if (e.kind === "assign") {
      text = `${time}  ${who} ${theme.unit} ${e.lane} ← ${e.tasks.join(", ")}`;
      tone = "muted";
    } else if (entry.problem === "unknown-after") {
      const id =
        e.kind === "add" ? e.task.id : e.kind === "change" ? e.task : "";
      const after = e.kind === "add" || e.kind === "change" ? e.after : "";
      text = `${time}  ${who} ${e.kind === "add" ? "added" : "changed"} ${state.run.callsign} ${id} · ⚠ unknown after ${after}`;
      tone = "warn";
    } else if (e.kind === "add") {
      text = `${time}  ${who} added ${state.run.callsign} ${e.task.id} · ${e.task.title}`;
      tone = "muted";
    } else if (e.kind === "change") {
      const what = [
        e.title !== null ? "title" : "",
        e.area !== null ? "area" : "",
        e.after !== null ? `moved after ${e.after}` : "",
      ]
        .filter(Boolean)
        .join(", ");
      text = `${time}  ${who} changed ${state.run.callsign} ${e.task} · ${what}`;
      tone = "muted";
    } else if (e.kind === "remove") {
      text = `${time}  ${who} removed ${state.run.callsign} ${e.task}`;
      tone = "muted";
    } else {
      text = `${time}  ${who} ${theme.states.closed}${e.text ? ` · ${e.text}` : ""}`;
      tone = "warn";
    }
    rows.push({ text: fit(text.trimEnd(), columns), tone });
  }
  return height <= 0 ? [] : rows.slice(-height);
}
