/** The Panel's launchd agents: one for the hub, one for a station, per Mac. */
import { mkdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export type Role = "hub" | "station";

export const label = (role: Role) => `dev.tower.panel.${role}`;

const xml = (s: string) =>
  s.replace(
    /[&<>"']/g,
    (c) =>
      ({
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&apos;",
      })[c]!,
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
  const logs = join(
    process.env.XDG_STATE_HOME || join(homedir(), ".local/state"),
    "tower/panel",
  );
  const strings = (items: string[]) =>
    items.map((s) => `<string>${xml(s)}</string>`).join("");
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
<key>EnvironmentVariables</key><dict><key>PATH</key><string>${xml(process.env.PATH ?? "")}</string></dict>
<key>WorkingDirectory</key><string>${xml(homedir())}</string>
<key>StandardOutPath</key><string>${xml(join(logs, `${opts.role}.log`))}</string>
<key>StandardErrorPath</key><string>${xml(join(logs, `${opts.role}.log`))}</string>
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
