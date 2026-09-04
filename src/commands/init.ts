/**
 * `init`, `assign`, `close`: the orchestrator's three. `init` is the only
 * command that creates anything; it validates everything first so a bad lane
 * never leaves a half-made run behind.
 */
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { parseArgs } from "node:util";

import type { Io } from "../io.ts";
import type { TaskDef } from "../types.ts";
import { appendEvent, readEvents } from "../events.ts";
import { gitInfo } from "../git.ts";
import { expandIds } from "../ids.ts";
import { UsageError } from "../io.ts";
import { configPath, readConfig, runsDir } from "../paths.ts";
import { parsePlan, parseTsv } from "../plan.ts";
import {
  callsignOf,
  clearPointer,
  closeRun,
  defaultRunDir,
  eventsPath,
  initRun,
  isClosed,
  readPointer,
  readRun,
  RUN_FILE,
  validateLanes,
  writePointer,
} from "../run.ts";
import { fold } from "../state.ts";
import { DEFAULT_MODELS, DEFAULT_STALE_MINUTES } from "../types.ts";
import { locateRun } from "./locate.ts";

const SOURCES =
  "tasks come from one of: --plan <plan.md>, --tasks <tasks.tsv>, or a TSV on stdin";

function parseLanes(
  specs: string[],
  tasks: readonly TaskDef[],
): Record<string, string[]> {
  const lanes: Record<string, string[]> = {};
  for (const spec of specs) {
    const eq = spec.indexOf("=");
    if (eq === -1)
      throw new UsageError(`--lane expects <lane>=<ids>, got "${spec}"`);
    const lane = spec.slice(0, eq).trim();
    if (!lane) throw new UsageError(`--lane "${spec}" has no lane name`);
    try {
      lanes[lane] = expandIds(spec.slice(eq + 1));
    } catch (error) {
      throw new UsageError(`--lane ${lane}: ${(error as Error).message}`);
    }
  }
  try {
    validateLanes(lanes, tasks);
  } catch (error) {
    throw new UsageError((error as Error).message);
  }
  return lanes;
}

function parseModels(
  specs: string[],
  fromConfig: Record<string, string> | undefined,
): Record<string, string> {
  const models: Record<string, string> = { ...(fromConfig ?? DEFAULT_MODELS) };
  for (const spec of specs) {
    const eq = spec.indexOf("=");
    if (eq === -1)
      throw new UsageError(`--model expects <role>=<model>, got "${spec}"`);
    models[spec.slice(0, eq).trim()] = spec.slice(eq + 1).trim();
  }
  return models;
}

export async function initCommand(argv: string[], io: Io): Promise<number> {
  const { values } = parseArgs({
    args: argv,
    options: {
      plan: { type: "string" },
      tasks: { type: "string" },
      title: { type: "string" },
      lane: { type: "string", multiple: true, default: [] },
      model: { type: "string", multiple: true, default: [] },
      theme: { type: "string" },
      callsign: { type: "string" },
      run: { type: "string" },
      force: { type: "boolean", default: false },
    },
  });

  let tasks: TaskDef[];
  let title = "untitled";
  let planPath: string | null = null;
  let repo: string | undefined;
  let branch: string | undefined;
  const git = gitInfo(io.cwd);

  if (values.plan) {
    planPath = resolve(io.cwd, values.plan);
    let text: string;
    try {
      text = readFileSync(planPath, "utf8");
    } catch {
      throw new UsageError(`cannot read plan file ${planPath}`);
    }
    try {
      const plan = parsePlan(text);
      tasks = plan.tasks;
      title = plan.title;
      repo = plan.repo;
      branch = plan.branch;
    } catch (error) {
      throw new UsageError(`${planPath}: ${(error as Error).message}`);
    }
  } else {
    let source: string | undefined;
    if (values.tasks) {
      const tasksPath = resolve(io.cwd, values.tasks);
      try {
        source = readFileSync(tasksPath, "utf8");
      } catch {
        throw new UsageError(`cannot read tasks file ${tasksPath}`);
      }
    } else {
      source = io.stdinText();
    }
    if (source === undefined) throw new UsageError(SOURCES);
    try {
      tasks = parseTsv(source);
    } catch (error) {
      throw new UsageError((error as Error).message);
    }
  }

  if (values.title) title = values.title;
  repo ??= git.repo;
  branch ??= git.branch;
  if (!repo || !branch)
    throw new UsageError(
      values.plan
        ? "the plan has no repo/branch frontmatter and this is not a git checkout — run init from the repository"
        : "the repo/branch could not be determined; this is not a git checkout — run init from the repository",
    );

  const lanes = parseLanes(values.lane, tasks);
  const { config, problem } = readConfig(configPath(io.env));
  if (problem) io.stderr(`tower: ignoring config — ${problem}\n`);
  const models = parseModels(values.model, config.models);
  const theme = values.theme ?? config.defaultTheme ?? "airport";
  const now = io.now();
  const runDir = values.run
    ? resolve(io.cwd, values.run)
    : defaultRunDir(runsDir(io.env), repo, branch, now);

  if (git.commonDir && !values.force) {
    const pointed = readPointer(git.commonDir);
    if (pointed && existsSync(resolve(pointed, RUN_FILE)) && !isClosed(pointed))
      throw new UsageError(
        `this repository already has an open run: ${pointed}\n       finish it with \`tower close\`, or pass --force to point at a new one`,
      );
  }

  try {
    initRun({
      runDir,
      plan: title,
      planPath,
      repo,
      branch,
      callsign: values.callsign ?? callsignOf(repo),
      theme,
      models,
      tasks,
      lanes,
      now,
    });
  } catch (error) {
    throw new UsageError(
      `cannot create run dir ${runDir}: ${(error as Error).message}`,
    );
  }
  if (git.commonDir) {
    try {
      writePointer(git.commonDir, runDir);
    } catch (error) {
      io.stderr(
        `tower: run created, but could not record it as the current run: ${(error as Error).message}\n       point at it explicitly with --run ${runDir}\n`,
      );
    }
  }

  io.stdout(
    `${title}\n${tasks.length} tasks, ${Object.keys(lanes).length} lanes, theme ${theme}\nrun dir: ${runDir}\n`,
  );
  return 0;
}

export async function assignCommand(argv: string[], io: Io): Promise<number> {
  const { values, positionals } = parseArgs({
    args: argv,
    options: { run: { type: "string" } },
    allowPositionals: true,
  });
  const [lane, spec] = positionals;
  if (!lane || !spec)
    throw new UsageError(
      "usage: tower assign <lane> <ids>   e.g. tower assign B 5,7-9",
    );
  const runDir = locateRun(io, values.run);
  const run = readRun(runDir);
  let ids: string[];
  try {
    ids = expandIds(spec);
    validateLanes({ [lane]: ids }, run.tasks);
  } catch (error) {
    throw new UsageError((error as Error).message);
  }
  appendEvent(eventsPath(runDir), {
    v: 1,
    kind: "assign",
    ts: io.now().toISOString(),
    lane,
    tasks: ids,
  });
  io.stdout(`lane ${lane}: ${ids.join(", ")}\n`);
  return 0;
}

export async function closeCommand(argv: string[], io: Io): Promise<number> {
  const { values, positionals } = parseArgs({
    args: argv,
    options: { run: { type: "string" } },
    allowPositionals: true,
  });
  const git = gitInfo(io.cwd);
  const runDir = locateRun(io, values.run, git);
  if (isClosed(runDir))
    throw new UsageError(`this run is already closed: ${runDir}`);
  const text = positionals.join(" ").trim();
  closeRun(runDir, text, io.now());
  if (git.commonDir && readPointer(git.commonDir) === runDir)
    clearPointer(git.commonDir);
  const state = fold(readRun(runDir), readEvents(eventsPath(runDir), 0).lines, {
    now: io.now(),
    staleMinutes: DEFAULT_STALE_MINUTES,
  });
  io.stdout(
    `closed: ${state.summary.done} of ${state.summary.total} tasks done${text ? ` · ${text}` : ""}\n`,
  );
  return 0;
}
