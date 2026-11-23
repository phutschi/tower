/** The Panel's launchd agents: one for the hub, one for a station, per Mac. */
import { mkdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

import { esc } from "./hub/panel-page.ts";

export type Role = "hub" | "station";

export const label = (role: Role) => `dev.tower.panel.${role}`;

/** The Panel's state: the hub's database, the stations' checkouts, the logs. */
export const stateDir = () =>
  join(
    process.env.XDG_STATE_HOME || join(homedir(), ".local/state"),
    "tower/panel",
  );

/**
 * Writes the launchd agent that runs `bun cli.ts <args>` at login and keeps
 * it running, with the PATH of this install (its jobs need gh, git, claude
 * and the kit's tools). Returns the plist's path, in `dir`.
 */
export function writePlist(opts: {
  role: Role;
  args: string[];
  dir: string;
}): string {
  const logs = stateDir();
  // launchd starts the agent with none of the shell's environment: the PATH
  // its jobs need, and where tower keeps its state, go along.
  const env: Record<string, string> = { PATH: process.env.PATH ?? "" };
  if (process.env.XDG_STATE_HOME)
    env.XDG_STATE_HOME = process.env.XDG_STATE_HOME;
  const vars = Object.entries(env)
    .map(([k, v]) => `<key>${k}</key><string>${esc(v)}</string>`)
    .join("");
  const strings = (items: string[]) =>
    items.map((s) => `<string>${esc(s)}</string>`).join("");
  const program = [
    process.execPath,
    join(import.meta.dir, "cli.ts"),
    ...opts.args,
  ];
  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${label(opts.role)}</string>
<key>ProgramArguments</key><array>${strings(program)}</array>
<key>EnvironmentVariables</key><dict>${vars}</dict>
<key>WorkingDirectory</key><string>${esc(homedir())}</string>
<key>StandardOutPath</key><string>${esc(join(logs, `${opts.role}.log`))}</string>
<key>StandardErrorPath</key><string>${esc(join(logs, `${opts.role}.log`))}</string>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
</dict></plist>
`;
  mkdirSync(opts.dir, { recursive: true });
  mkdirSync(logs, { recursive: true });
  const path = join(opts.dir, `${label(opts.role)}.plist`);
  writeFileSync(path, plist);
  return path;
}
