#!/usr/bin/env bun
/**
 * The Panel's entry point: `hub` starts the hub on the server Mac, `station`
 * a station on any Mac; `install` and `uninstall` make either a launchd agent.
 */
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { homedir, hostname } from "node:os";
import { dirname, join } from "node:path";
import { parseArgs } from "node:util";

import { startHub } from "./hub/hub.ts";
import { label, stateDir, writePlist, type Role } from "./launchd.ts";
import { runStation } from "./station/station.ts";

const USAGE = `usage: bun skills/panel/cli.ts hub [--db <path>] [--host <addr>] [--port <n>] [--poll-seconds <n>] [--usage-seconds <n, 0 for never>] [--server-station <name>]
       bun skills/panel/cli.ts station --hub <url> [--name <mac>] [--workdir <dir>] [--heartbeat-seconds <n>]
       bun skills/panel/cli.ts install hub [--port <n>] [--server-station <name>] [--dir <dir>]
       bun skills/panel/cli.ts install station --hub <url> [--name <mac>] [--dir <dir>]
       bun skills/panel/cli.ts uninstall hub|station [--dir <dir>]`;

const AGENTS = join(homedir(), "Library/LaunchAgents");
const domain = () => `gui/${process.getuid?.() ?? 0}`;

function onStop(stop: () => Promise<void>) {
  const exit = () => void stop().then(() => process.exit(0));
  process.on("SIGINT", exit);
  process.on("SIGTERM", exit);
}

async function hub(args: string[]) {
  const { values } = parseArgs({
    args,
    options: {
      db: { type: "string", default: join(stateDir(), "hub.db") },
      host: { type: "string", default: "127.0.0.1" },
      port: { type: "string", default: "7420" },
      "poll-seconds": { type: "string", default: "60" },
      "usage-seconds": { type: "string", default: "300" },
      "server-station": { type: "string", default: hostname() },
    },
  });
  mkdirSync(dirname(values.db), { recursive: true });
  const usageMs = Number(values["usage-seconds"]) * 1000;
  if (!(usageMs >= 0)) usage();
  const hub = await startHub({
    dbPath: values.db,
    host: values.host,
    port: Number(values.port),
    pollMs: Number(values["poll-seconds"]) * 1000,
    serverStation: values["server-station"],
    ...(usageMs > 0 ? { usageMs } : { readUsage: async () => null }),
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
      workdir: { type: "string", default: join(stateDir(), "station") },
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

/** The Mac's Tailscale address: the hub listens there, and only there. */
function tailscaleIp(): string {
  try {
    const ip = execFileSync("tailscale", ["ip", "-4"], { encoding: "utf8" })
      .split("\n")[0]
      ?.trim();
    if (ip) return ip;
  } catch {
    // reported below
  }
  console.error(
    "install hub: this Mac has no Tailscale address (tailscale ip -4): the Panel is reached on the tailnet only",
  );
  process.exit(1);
}

/**
 * Unloads a role's agent, if it is loaded; exits 1 when launchctl cannot,
 * since the agent then still runs.
 */
const bootout = (cmd: string, role: Role) => {
  try {
    execFileSync("launchctl", ["bootout", `${domain()}/${label(role)}`], {
      stdio: "pipe",
    });
  } catch (err) {
    // Nothing runs: 3 (no such service), 112 (no such domain: nobody is
    // logged in at the screen), 113 (service not found).
    const { status } = err as { status?: number };
    if (status === 3 || status === 112 || status === 113) return;
    console.error(
      `${cmd} ${role}: launchctl could not unload ${label(role)}: ${String(err)}`,
    );
    process.exit(1);
  }
};

function install(args: string[]) {
  const [role, ...rest] = args;
  if (role !== "hub" && role !== "station") usage();
  const { values } = parseArgs({
    args: rest,
    options: {
      dir: { type: "string", default: AGENTS },
      port: { type: "string", default: "7420" },
      "server-station": { type: "string", default: hostname() },
      hub: { type: "string" },
      name: { type: "string", default: hostname() },
    },
  });
  let run: string[];
  let panel = "";
  if (role === "hub") {
    const host = tailscaleIp();
    panel = `http://${host}:${values.port}`;
    run = [
      "hub",
      "--host",
      host,
      "--port",
      values.port,
      "--server-station",
      values["server-station"],
    ];
  } else {
    if (!values.hub) usage();
    run = ["station", "--hub", values.hub, "--name", values.name];
  }
  // Unloaded first: a plist written over a running agent's would outlive it.
  bootout("install", role);
  const path = writePlist({ role, args: run, dir: values.dir });
  try {
    execFileSync("launchctl", ["bootstrap", domain(), path], { stdio: "pipe" });
  } catch (err) {
    // Left in place, the agent would start at the next login anyway.
    rmSync(path, { force: true });
    console.error(
      `install ${role}: launchctl could not load ${path}: ${String(err)}`,
    );
    process.exit(1);
  }
  console.log(`install ${role}: ${path} is loaded`);
  if (panel) console.log(`install hub: the Panel is at ${panel}`);
}

function uninstall(args: string[]) {
  const [role, ...rest] = args;
  if (role !== "hub" && role !== "station") usage();
  const { values } = parseArgs({
    args: rest,
    options: { dir: { type: "string", default: AGENTS } },
  });
  bootout("uninstall", role);
  rmSync(join(values.dir, `${label(role)}.plist`), { force: true });
  console.log(`uninstall ${role}: unloaded and removed`);
}

function usage(): never {
  console.error(USAGE);
  process.exit(2);
}

const [command, ...rest] = process.argv.slice(2);
if (command === "hub") await hub(rest);
else if (command === "station") await station(rest);
else if (command === "install") install(rest);
else if (command === "uninstall") uninstall(rest);
else usage();
