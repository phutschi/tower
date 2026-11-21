#!/usr/bin/env bun
/** The Panel's entry point: `hub` starts the hub on the server Mac. */
import { mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { parseArgs } from "node:util";

import { startHub } from "./hub/hub.ts";

const USAGE = `usage: bun skills/panel/cli.ts hub [--db <path>] [--host <addr>] [--port <n>] [--poll-seconds <n>]`;

const stateDir = join(
  process.env.XDG_STATE_HOME || join(homedir(), ".local/state"),
  "tower/panel",
);

async function main(argv: string[]) {
  const [command, ...rest] = argv;
  if (command !== "hub") {
    console.error(USAGE);
    process.exit(2);
  }
  const { values } = parseArgs({
    args: rest,
    options: {
      db: { type: "string", default: join(stateDir, "hub.db") },
      host: { type: "string", default: "127.0.0.1" },
      port: { type: "string", default: "7420" },
      "poll-seconds": { type: "string", default: "60" },
    },
  });
  mkdirSync(dirname(values.db), { recursive: true });
  const hub = await startHub({
    dbPath: values.db,
    host: values.host,
    port: Number(values.port),
    pollMs: Number(values["poll-seconds"]) * 1000,
  });
  console.log(`hub: listening on ${hub.url}`);
  const stop = () => void hub.stop().then(() => process.exit(0));
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
}

await main(process.argv.slice(2));
