/**
 * A run that exercises every state once: pending, in_progress with each
 * phase, reviewing, done, blocked, stale, an unknown flight, a torn line, a
 * note from each voice, and a close. `tower theme preview` renders it; tests
 * snapshot it; `tower theme check` asserts every label appears in it.
 */
import type { ParsedLine } from "../events.ts";
import type { State } from "../state.ts";
import { fold } from "../state.ts";
import type { Event, RunFile, Status } from "../types.ts";

export const DEMO_NOW = new Date("2026-09-04T21:47:00.000Z");
const at = (min: number) =>
  new Date(Date.parse("2026-09-04T19:12:00.000Z") + min * 60_000).toISOString();

export const DEMO_RUN: RunFile = {
  v: 1,
  plan: "Widgets Implementation Plan",
  planPath: null,
  repo: "acme",
  branch: "feature/widgets",
  callsign: "ACME",
  theme: "airport",
  startedAt: at(0),
  models: {
    implementer: "sonnet-5[1m]",
    "spec-reviewer": "sonnet",
    "quality-reviewer": "opus",
  },
  tasks: [
    ...Array.from({ length: 11 }, (_, i) => ({
      id: String(i + 1),
      title: `Landed task ${i + 1}`,
      area: "packages/core",
    })),
    { id: "12", title: "Voice notes", area: "apps/server" },
    { id: "13", title: "The surface hint", area: "apps/server" },
    { id: "14", title: "The onDirectMessage handler", area: "apps/server" },
    { id: "15", title: "notifyTelegram", area: "apps/server" },
    { id: "16", title: "POST /telegram/notify", area: "apps/server" },
    { id: "17", title: "Attach the channel to the agent", area: "apps/server" },
    { id: "18", title: "surface on the threads route", area: "packages/api" },
    { id: "19", title: "The show-threads toggle", area: "apps/web" },
    { id: "20", title: "The terminal tags rows", area: "apps/tui" },
    { id: "21", title: "Docs and the runbook", area: "docs" },
  ],
};

const rep = (
  min: number,
  task: string,
  status: Status,
  phase: string,
  model: string,
  note = "",
  commit = "",
): ParsedLine => ({
  raw: "",
  event: {
    v: 1,
    kind: "report",
    ts: at(min),
    task,
    status,
    phase,
    model,
    note,
    commit,
  },
});
const line = (event: Event): ParsedLine => ({ raw: "", event });

export const DEMO_EVENTS: ParsedLine[] = [
  line({
    v: 1,
    kind: "assign",
    ts: at(0),
    lane: "A",
    tasks: [
      "1",
      "2",
      "3",
      "4",
      "6",
      "10",
      "11",
      "14",
      "15",
      "16",
      "17",
      "18",
      "19",
      "20",
      "21",
    ],
  }),
  line({
    v: 1,
    kind: "assign",
    ts: at(0),
    lane: "B",
    tasks: ["5", "7", "8", "9", "12", "13"],
  }),
  ...Array.from({ length: 11 }, (_, i) =>
    rep(
      i * 8 + 1,
      String(i + 1),
      "done",
      "committed",
      i % 2 ? "opus" : "sonnet-5[1m]",
      `feat: task ${i + 1}`,
      `a1b2c${String(i).padStart(2, "0")}`,
    ),
  ),
  rep(120, "13", "done", "committed", "opus", "feat: surface hint", "a91c2f0"),
  rep(121, "14", "in_progress", "implementing", "sonnet-5[1m]"),
  rep(122, "12", "in_progress", "implementing", "opus"),
  rep(130, "14", "reviewing", "spec-review", "sonnet"),
  rep(
    131,
    "14",
    "in_progress",
    "fixing",
    "sonnet-5[1m]",
    "spec review: missing null guard",
  ),
  line({
    v: 1,
    kind: "note",
    ts: at(132),
    text: "merged lane B at task 8",
    task: null,
    lane: "A",
  }),
  line({
    v: 1,
    kind: "note",
    ts: at(133),
    text: "escalating 14 to opus after the second bounce",
    task: null,
    lane: null,
  }),
  rep(134, "12", "blocked", "", "", "needs the test DB created"),
  rep(135, "99", "done", "committed", "opus"),
  { raw: '{"v":1,"kind":"re', event: null },
  rep(140, "15", "reviewing", "quality-review", "opus"),
  line({
    v: 1,
    kind: "add",
    ts: at(140),
    task: { id: "22", title: "Retry the webhook", area: "" },
    after: null,
  }),
  line({
    v: 1,
    kind: "change",
    ts: at(141),
    task: "22",
    title: "Retry the outbound webhook",
    area: null,
    after: null,
  }),
  line({ v: 1, kind: "remove", ts: at(142), task: "21" }),
];

export function demoState(options: { closed?: boolean } = {}): State {
  const lines = options.closed
    ? [
        ...DEMO_EVENTS,
        line({ v: 1, kind: "close", ts: at(150), text: "shipped as v0.1.0" }),
      ]
    : DEMO_EVENTS;
  return fold(DEMO_RUN, lines, { now: DEMO_NOW, staleMinutes: 10 });
}
