#!/usr/bin/env bun
/**
 * The Panel's entry point: `hub` starts the hub on the server Mac, `station`
 * a station on any Mac.
 */
import { existsSync, mkdirSync, readdirSync } from "node:fs";
import { homedir, hostname } from "node:os";
import { dirname, join } from "node:path";
import { parseArgs } from "node:util";

import { startHub } from "./hub/hub.ts";
import { runStation } from "./station/station.ts";

const USAGE = `usage: bun skills/panel/cli.ts hub [--db <path>] [--host <addr>] [--port <n>] [--poll-seconds <n>] [--server-station <name>]
       bun skills/panel/cli.ts station --hub <url> [--name <mac>] [--workdir <dir>] [--heartbeat-seconds <n>]`;

const stateDir = join(
  process.env.XDG_STATE_HOME || join(homedir(), ".local/state"),
  "tower/panel",
);

function onStop(stop: () => Promise<void>) {
  const exit = () => void stop().then(() => process.exit(0));
  process.on("SIGINT", exit);
  process.on("SIGTERM", exit);
}

async function hub(args: string[]) {
  const { values } = parseArgs({
    args,
    options: {
      db: { type: "string", default: join(stateDir, "hub.db") },
      host: { type: "string", default: "127.0.0.1" },
      port: { type: "string", default: "7420" },
      "poll-seconds": { type: "string", default: "60" },
      "server-station": { type: "string", default: hostname() },
    },
  });
  mkdirSync(dirname(values.db), { recursive: true });
  const hub = await startHub({
    dbPath: values.db,
    host: values.host,
    port: Number(values.port),
    pollMs: Number(values["poll-seconds"]) * 1000,
    serverStation: values["server-station"],
  });
  console.log(`hub: listening on ${hub.url}`);
  onStop(() => hub.stop());
}

async function station(args: string[]) {
  const { values } = parseArgs({
    args,
    options: {
      hub: { type: "string" },
      name: { type: "string", default: hostname() },
      workdir: { type: "string", default: join(stateDir, "station") },
      "heartbeat-seconds": { type: "string", default: "15" },
    },
  });
  if (!values.hub) usage();
  // Each module in station/jobs registers the runner of its job kind.
  const jobs = join(import.meta.dir, "station/jobs");
  if (existsSync(jobs))
    for (const f of readdirSync(jobs).sort())
      if (f.endsWith(".ts") && !f.endsWith(".test.ts"))
        await import(join(jobs, f));
  mkdirSync(values.workdir, { recursive: true });
  const station = await runStation({
    hubUrl: values.hub,
    name: values.name,
    workdir: values.workdir,
    heartbeatMs: Number(values["heartbeat-seconds"]) * 1000,
  });
  onStop(() => station.stop());
}

function usage(): never {
  console.error(USAGE);
  process.exit(2);
}

const [command, ...rest] = process.argv.slice(2);
if (command === "hub") await hub(rest);
else if (command === "station") await station(rest);
else usage();
