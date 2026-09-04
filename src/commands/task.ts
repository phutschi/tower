/**
 * The three commands an executor is taught: `task`, `block`, `note`. Every
 * refusal here is a lesson — the message names the valid form, and nothing is
 * appended — because a rejected report must not be a silent one.
 */
import { parseArgs } from "node:util";

import type { Io } from "../io.ts";
import type { NoteEvent, ReportEvent } from "../types.ts";
import type { State } from "../state.ts";
import { appendEvent, NOTE_MAX_CHARS, readEvents } from "../events.ts";
import { gitInfo } from "../git.ts";
import { nearestId } from "../ids.ts";
import { UsageError } from "../io.ts";
import { eventsPath, readRun } from "../run.ts";
import { fold } from "../state.ts";
import { DEFAULT_STALE_MINUTES, isStatus, STATUSES } from "../types.ts";
import { locateRun } from "./locate.ts";

const TASK_USAGE =
  "usage: tower task <id> <status> [phase] [note] --model <model>";

function loadState(runDir: string, io: Io): State {
  const run = readRun(runDir);
  const { lines } = readEvents(eventsPath(runDir), 0);
  return fold(run, lines, {
    now: io.now(),
    staleMinutes: DEFAULT_STALE_MINUTES,
  });
}

function requireNote(note: string): void {
  if (note.length > NOTE_MAX_CHARS)
    throw new UsageError(
      `note is ${note.length} characters; the limit is ${NOTE_MAX_CHARS}`,
    );
}

function requireTask(state: State, id: string): void {
  const ids = state.tasks.map((t) => t.id);
  if (ids.includes(id)) return;
  const near = nearestId(id, ids);
  throw new UsageError(
    `unknown task "${id}"${near ? ` — did you mean ${near}?` : ""}\n       tasks: ${ids.join(", ")}`,
  );
}

export async function taskCommand(argv: string[], io: Io): Promise<number> {
  const { values, positionals } = parseArgs({
    args: argv,
    options: { model: { type: "string" }, run: { type: "string" } },
    allowPositionals: true,
  });
  const [id, status, phase = "", note = ""] = positionals;
  if (!id || !status) throw new UsageError(TASK_USAGE);
  if (!isStatus(status))
    throw new UsageError(
      `unknown status "${status}"\n       valid: ${STATUSES.join(", ")}`,
    );
  const runDir = locateRun(io, values.run);
  const state = loadState(runDir, io);
  requireTask(state, id);
  if ((status === "in_progress" || status === "reviewing") && !values.model)
    throw new UsageError(
      `${status} needs --model <model> (the model on the task; \`--model none\` if you do not track it)\n       ${TASK_USAGE}`,
    );
  if (status === "blocked" && !note)
    throw new UsageError(
      `blocked needs a note saying what you need:\n       tower block ${id} "<what you need>"`,
    );
  requireNote(note);
  const event: ReportEvent = {
    v: 1,
    kind: "report",
    ts: io.now().toISOString(),
    task: id,
    status,
    phase,
    model: values.model ?? "",
    note,
    commit: gitInfo(io.cwd).commit ?? "",
  };
  appendEvent(eventsPath(runDir), event);
  io.stdout(
    `task ${id} → ${status}${phase ? ` ${phase}` : ""}${event.model ? ` [${event.model}]` : ""}${note ? ` · ${note}` : ""}\n`,
  );
  return 0;
}

export async function blockCommand(argv: string[], io: Io): Promise<number> {
  const { values, positionals } = parseArgs({
    args: argv,
    options: { run: { type: "string" } },
    allowPositionals: true,
  });
  const [id, note] = positionals;
  if (!id || !note)
    throw new UsageError('usage: tower block <id> "<what you need>"');
  return taskCommand(
    [id, "blocked", "", note, ...(values.run ? ["--run", values.run] : [])],
    io,
  );
}

export async function noteCommand(argv: string[], io: Io): Promise<number> {
  const { values, positionals } = parseArgs({
    args: argv,
    options: {
      task: { type: "string" },
      lane: { type: "string" },
      run: { type: "string" },
    },
    allowPositionals: true,
  });
  const text = positionals.join(" ").trim();
  if (!text)
    throw new UsageError(
      'usage: tower note [--task <id> | --lane <lane>] "<text>"',
    );
  if (values.task && values.lane)
    throw new UsageError("a note speaks as a task or as a lane, not both");
  requireNote(text);
  const runDir = locateRun(io, values.run);
  const state = loadState(runDir, io);
  if (values.task) requireTask(state, values.task);
  if (values.lane && !(values.lane in state.lanes))
    throw new UsageError(
      `lane ${values.lane} has no tasks assigned\n       lanes: ${Object.keys(state.lanes).join(", ") || "(none)"}`,
    );
  const event: NoteEvent = {
    v: 1,
    kind: "note",
    ts: io.now().toISOString(),
    text,
    task: values.task ?? null,
    lane: values.lane ?? null,
  };
  appendEvent(eventsPath(runDir), event);
  io.stdout(
    `note${values.task ? ` task ${values.task}` : values.lane ? ` lane ${values.lane}` : ""}: ${text}\n`,
  );
  return 0;
}
