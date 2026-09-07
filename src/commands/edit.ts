/**
 * `add`, `change`, `remove`: the run's own word on what its tasks are, on
 * top of what the plan said. Every refusal names the valid form and appends
 * nothing. These are top-level verbs because `tower task add` cannot exist:
 * `add` is a valid task id.
 */
import { parseArgs } from "node:util";

import type { Io } from "../io.ts";
import type { State } from "../state.ts";
import type { AddEvent, ChangeEvent, RemoveEvent } from "../types.ts";
import { appendEvent } from "../events.ts";
import { isValidId } from "../ids.ts";
import { UsageError } from "../io.ts";
import { eventsPath, isClosed } from "../run.ts";
import { loadState, locateRun, requireTask } from "./locate.ts";

const ADD_USAGE =
  'usage: tower add "<title>" [--id <id>] [--area <text>] [--after <id>] [--lane <lane>]';
const CHANGE_USAGE =
  "usage: tower change <id> [--title <text>] [--area <text>] [--after <id>]";
const REMOVE_USAGE = "usage: tower remove <id> [--force]";

function openRun(
  io: Io,
  flag: string | undefined,
): { runDir: string; state: State } {
  const runDir = locateRun(io, flag);
  if (isClosed(runDir))
    throw new UsageError(
      `this run is closed: ${runDir}\n       start a new one with tower init`,
    );
  return { runDir, state: loadState(runDir, io) };
}

export async function addCommand(argv: string[], io: Io): Promise<number> {
  const { values, positionals } = parseArgs({
    args: argv,
    options: {
      id: { type: "string" },
      area: { type: "string", default: "" },
      after: { type: "string" },
      lane: { type: "string" },
      run: { type: "string" },
    },
    allowPositionals: true,
  });
  const title = positionals.join(" ").trim();
  if (!title) throw new UsageError(ADD_USAGE);
  const { runDir, state } = openRun(io, values.run);
  if (values.id !== undefined && !isValidId(values.id))
    throw new UsageError(
      `"${values.id}" is not a valid task id (letters, digits, . _ -; no spaces)\n       ${ADD_USAGE}`,
    );
  if (values.id !== undefined && state.tasks.some((t) => t.id === values.id))
    throw new UsageError(
      `task "${values.id}" already exists — change it with tower change ${values.id}, or pick another id`,
    );
  if (values.after !== undefined) requireTask(state, values.after);
  const id = values.id ?? state.nextId;
  const ts = io.now().toISOString();
  const event: AddEvent = {
    v: 1,
    kind: "add",
    ts,
    task: { id, title, area: values.area },
    after: values.after ?? null,
  };
  appendEvent(eventsPath(runDir), event);
  if (values.lane !== undefined) {
    const mine = state.lanes[values.lane] ?? [];
    appendEvent(eventsPath(runDir), {
      v: 1,
      kind: "assign",
      ts,
      lane: values.lane,
      tasks: [...mine, id],
    });
  }
  io.stdout(`${id}\n`);
  io.stdout(
    `added task ${id} — ${title}${values.after ? ` after ${values.after}` : ""}${values.lane ? ` (lane ${values.lane})` : ""}\n`,
  );
  return 0;
}

export async function changeCommand(argv: string[], io: Io): Promise<number> {
  const { values, positionals } = parseArgs({
    args: argv,
    options: {
      title: { type: "string" },
      area: { type: "string" },
      after: { type: "string" },
      run: { type: "string" },
    },
    allowPositionals: true,
  });
  const [id, ...extra] = positionals;
  if (!id || extra.length > 0) throw new UsageError(CHANGE_USAGE);
  if (
    values.title === undefined &&
    values.area === undefined &&
    values.after === undefined
  )
    throw new UsageError(`nothing to change\n       ${CHANGE_USAGE}`);
  if (values.title !== undefined && !values.title.trim())
    throw new UsageError("--title must not be empty");
  const { runDir, state } = openRun(io, values.run);
  requireTask(state, id);
  if (values.after !== undefined) {
    if (values.after === id)
      throw new UsageError(`task ${id} cannot be placed after itself`);
    requireTask(state, values.after);
  }
  const event: ChangeEvent = {
    v: 1,
    kind: "change",
    ts: io.now().toISOString(),
    task: id,
    title: values.title ?? null,
    area: values.area ?? null,
    after: values.after ?? null,
  };
  appendEvent(eventsPath(runDir), event);
  const what = [
    values.title !== undefined ? `title "${values.title}"` : "",
    values.area !== undefined ? `area "${values.area}"` : "",
    values.after !== undefined ? `after ${values.after}` : "",
  ]
    .filter(Boolean)
    .join(", ");
  io.stdout(`changed task ${id}: ${what}\n`);
  return 0;
}

export async function removeCommand(argv: string[], io: Io): Promise<number> {
  const { values, positionals } = parseArgs({
    args: argv,
    options: {
      force: { type: "boolean", default: false },
      run: { type: "string" },
    },
    allowPositionals: true,
  });
  const [id, ...extra] = positionals;
  if (!id || extra.length > 0) throw new UsageError(REMOVE_USAGE);
  const { runDir, state } = openRun(io, values.run);
  requireTask(state, id);
  const task = state.tasks.find((t) => t.id === id);
  if (
    task &&
    (task.status === "in_progress" || task.status === "reviewing") &&
    !values.force
  )
    throw new UsageError(
      `task ${id} is ${task.status}${task.note ? ` · ${task.note}` : ""} — an executor is on it\n       tower remove ${id} --force to remove it anyway`,
    );
  const event: RemoveEvent = {
    v: 1,
    kind: "remove",
    ts: io.now().toISOString(),
    task: id,
  };
  appendEvent(eventsPath(runDir), event);
  io.stdout(`removed task ${id}${task ? ` — ${task.title}` : ""}\n`);
  return 0;
}
