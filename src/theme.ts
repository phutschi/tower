/**
 * A theme renames; it never re-models. It is a JSON lookup table over states
 * tower already has — which is why it is JSON and not code: a file that
 * cannot contain logic cannot fork the state machine or leak into
 * `state --json`. `airport` is that table shipped built in.
 */
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";

import airportJson from "../themes/airport.json" with { type: "json" };
import type { Env } from "./paths.ts";
import type { Status } from "./types.ts";
import { themesDir } from "./paths.ts";

export type StateKey = Status | "stale" | "closed";

export interface Theme {
  name: string;
  title: string;
  operator: string;
  unit: string;
  flight: string;
  broadcast: string;
  board: string;
  transcript: string;
  states: Record<StateKey, string>;
  phases: Record<string, string>;
  verbs: { started: string; blocked: string };
  empty: string;
  elapsed: string;
}

export const AIRPORT: Theme = airportJson as Theme;

export const PLAIN: Theme = {
  name: "plain",
  title: "TOWER",
  operator: "TOWER",
  unit: "LANE",
  flight: "task",
  broadcast: "RUN",
  board: "TASKS",
  transcript: "EVENTS",
  states: {
    pending: "pending",
    in_progress: "in_progress",
    reviewing: "reviewing",
    done: "done",
    blocked: "blocked",
    stale: "stale",
    closed: "closed",
  },
  phases: {},
  verbs: { started: "in_progress", blocked: "blocked" },
  empty: "no events yet",
  elapsed: "since first event",
};

const STATE_KEYS = [
  "pending",
  "in_progress",
  "reviewing",
  "done",
  "blocked",
  "stale",
  "closed",
];
const LIMITS = {
  name: 32,
  title: 8,
  operator: 8,
  unit: 8,
  flight: 12,
  broadcast: 12,
  board: 12,
  transcript: 12,
  empty: 40,
  elapsed: 24,
  state: 14,
} as const;

const ALLOWED_TOP = new Set([
  "name",
  "title",
  "operator",
  "unit",
  "flight",
  "broadcast",
  "board",
  "transcript",
  "states",
  "phases",
  "verbs",
  "empty",
  "elapsed",
]);

export function checkTheme(raw: unknown): string[] {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw))
    return ["a theme is a JSON object"];
  const problems: string[] = [];
  const doc = raw as Record<string, unknown>;
  for (const key of Object.keys(doc))
    if (!ALLOWED_TOP.has(key))
      problems.push(
        /colou?r/i.test(key)
          ? `"${key}": colour belongs to status, not to the theme — remove it`
          : `unknown key "${key}"`,
      );
  const str = (key: keyof typeof LIMITS) => {
    const value = doc[key];
    if (typeof value !== "string" || value.length === 0)
      problems.push(`${key}: required, a non-empty string`);
    else if (value.length > LIMITS[key])
      problems.push(
        `${key}: "${value}" is ${value.length} characters; the limit is ${LIMITS[key]}`,
      );
  };
  for (const key of [
    "name",
    "title",
    "operator",
    "unit",
    "flight",
    "broadcast",
    "board",
    "transcript",
    "empty",
    "elapsed",
  ] as const)
    str(key);

  const states = doc.states;
  const validStates = typeof states === "object" && states !== null;
  if (!validStates)
    problems.push("states: required, an object with one label per state");
  const s = validStates ? (states as Record<string, unknown>) : {};
  for (const key of STATE_KEYS) {
    const value = s[key];
    if (typeof value !== "string" || value.length === 0)
      problems.push(`states.${key}: required, a non-empty string`);
    else if (value.length > LIMITS.state)
      problems.push(
        `states.${key}: "${value}" is ${value.length} characters; the limit is ${LIMITS.state}`,
      );
  }
  const labels = STATE_KEYS.map((k) => s[k]).filter(
    (v): v is string => typeof v === "string",
  );
  const dupes = labels.filter((l, i) => labels.indexOf(l) !== i);
  for (const d of new Set(dupes))
    problems.push(
      `two states have the same label "${d}"; a glance must tell them apart`,
    );

  const phases = doc.phases;
  if (typeof phases !== "object" || phases === null || Array.isArray(phases))
    problems.push("phases: required, an object (may be empty)");
  else
    for (const [key, value] of Object.entries(
      phases as Record<string, unknown>,
    )) {
      if (typeof value !== "string" || value.length === 0)
        problems.push(`phases.${key}: a non-empty string`);
      else if (value.length > LIMITS.state)
        problems.push(
          `phases.${key}: "${value}" is ${value.length} characters; the limit is ${LIMITS.state}`,
        );
    }

  // Verbs are required but not length-limited: the built-in airport theme's
  // own "cleared for takeoff" (19 chars) exceeds the 14-char label limit, so
  // that limit cannot apply here without airport failing its own check.
  const verbs = doc.verbs;
  if (typeof verbs !== "object" || verbs === null || Array.isArray(verbs))
    problems.push("verbs: required, { started, blocked }");
  else
    for (const key of ["started", "blocked"]) {
      const value = (verbs as Record<string, unknown>)[key];
      if (typeof value !== "string" || value.length === 0)
        problems.push(`verbs.${key}: required, a non-empty string`);
    }

  return problems;
}

/** The label for a task's status and phase: the phase's word when the theme has one, else the state's word with the phase after it. */
export function labelFor(theme: Theme, status: Status, phase: string): string {
  const known = phase ? theme.phases[phase] : undefined;
  if (known) return known;
  return phase ? `${theme.states[status]} · ${phase}` : theme.states[status];
}

const BUILT_IN: Record<string, Theme> = { airport: AIRPORT, plain: PLAIN };

export function listThemes(env: Env): { builtIn: string[]; user: string[] } {
  let user: string[] = [];
  try {
    user = readdirSync(themesDir(env))
      .filter((f) => f.endsWith(".json"))
      .map((f) => f.slice(0, -5))
      .sort();
  } catch {
    /* no user themes dir yet */
  }
  return { builtIn: Object.keys(BUILT_IN).sort(), user };
}

const VALID_NAME = /^[a-z0-9][a-z0-9_-]*$/i;

function themeFilePath(name: string, env: Env): string {
  if (!VALID_NAME.test(name))
    throw new Error(
      `invalid theme name "${name}"; use letters, digits, "-" and "_" only`,
    );
  return join(themesDir(env), `${name}.json`);
}

export function loadTheme(name: string, env: Env): Theme {
  const builtIn = BUILT_IN[name];
  if (builtIn) return builtIn;
  const path = themeFilePath(name, env);
  if (!existsSync(path)) {
    const { builtIn: b, user } = listThemes(env);
    throw new Error(
      `no theme "${name}"\n       built in: ${b.join(", ")}\n       yours (${themesDir(env)}): ${user.join(", ") || "(none)"}`,
    );
  }
  let raw: unknown;
  try {
    raw = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    throw new Error(`${path} is not valid JSON`);
  }
  const problems = checkTheme(raw);
  if (problems.length > 0)
    throw new Error(
      `${path} is not a valid theme:\n  ${problems.join("\n  ")}`,
    );
  return raw as Theme;
}

/** Writes `<themes dir>/<name>.json` with every key present and empty; returns the path. */
export function scaffoldTheme(name: string, env: Env): string {
  const path = themeFilePath(name, env);
  const dir = themesDir(env);
  mkdirSync(dir, { recursive: true });
  const blank: Theme = {
    name,
    title: "",
    operator: "",
    unit: "",
    flight: "",
    broadcast: "",
    board: "",
    transcript: "",
    states: {
      pending: "",
      in_progress: "",
      reviewing: "",
      done: "",
      blocked: "",
      stale: "",
      closed: "",
    },
    phases: {
      implementing: "",
      "spec-review": "",
      "quality-review": "",
      fixing: "",
      committed: "",
    },
    verbs: { started: "", blocked: "" },
    empty: "",
    elapsed: "",
  };
  try {
    writeFileSync(path, `${JSON.stringify(blank, null, 2)}\n`, { flag: "wx" });
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "EEXIST")
      throw new Error(`${path} already exists; edit it, or pick another name`);
    throw err;
  }
  return path;
}

export const THEME_RULES = `tower theme rules — how to author a theme

A theme is a JSON file at <XDG_CONFIG_HOME>/tower/themes/<name>.json. It is a
lookup table over states tower already has. It cannot contain logic; that is
the point.

1. A theme renames; it never re-models. The states are fixed — pending,
   in_progress (+implementing/fixing), reviewing (+spec-review/quality-review),
   done, blocked, derived stale, and the closed-run banner. Every one needs a
   label. You may not add, merge, or drop a state.

2. Pick a domain that already has all of these situations, and use its real
   words. "Go around" is what air traffic control genuinely says for a
   rejected approach that must be re-flown. Test your domain against the two
   hard slots: a review that bounced and must be redone, and an active worker
   we have heard nothing from. A fire department has "toned out", "working",
   "recall", "no contact". A school has "handed in", "returned for
   corrections", "absent". An office has "circulated", "sent back with
   comments", "unresponsive". If your domain needs an invented phrase for
   either slot, the domain is wrong — choose another rather than making one up.

3. Never a synonym list. If the labels only make sense once someone explains
   the joke, it is a costume. Someone glancing at the board should infer
   roughly what is happening without being told the theme.

4. Length is enforced, because panes are narrow: state, phase and verb labels
   are at most 14 characters; board, transcript and broadcast headings 12;
   title, operator and unit 8. \`tower theme check\` fails on overflow rather
   than letting the board wrap.

5. Colour belongs to status, not to the theme. Blocked is red, active is cyan,
   done is dim, in every theme. A theme file has no colour keys to set.

6. Nothing outside the renderer is themed. \`tower state --json\`, \`tower wait\`,
   validation errors, \`tower brief\` and \`--plain\` are literal in every theme.

7. A theme ships with its preview. \`tower theme check <name>\` renders the
   theme against a demo run that shows every state, and fails if any label is
   missing from the output. Read that preview back before calling it done.

The loop:
  tower theme new <name>       scaffold every key, empty
  tower theme check <name>     what is missing or too long
  tower theme preview <name>   see it against the demo run
  tower --theme <name>         use it (or --theme at tower init)

Keys: name, title, operator, unit, flight, broadcast, board, transcript,
states{pending,in_progress,reviewing,done,blocked,stale,closed},
phases{implementing,spec-review,quality-review,fixing,committed,…},
verbs{started,blocked}, empty, elapsed.
`;
