import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "bun:test";

import { writePlist } from "./launchd.ts";

test("writePlist writes a launchd agent that runs the Panel's role and keeps it alive", () => {
  const dir = mkdtempSync(join(tmpdir(), "panel-launchd-"));
  const state = process.env.XDG_STATE_HOME;
  process.env.XDG_STATE_HOME = join(dir, "state");
  try {
    const path = writePlist({
      role: "station",
      args: [
        "station",
        "--hub",
        "http://100.64.0.7:7420",
        "--name",
        "rex & sam's <mac>",
      ],
      dir,
    });
    expect(path).toBe(join(dir, "dev.tower.panel.station.plist"));
    const plist = readFileSync(path, "utf8");
    expect(plist).toStartWith('<?xml version="1.0" encoding="UTF-8"?>');
    expect(plist).toContain(
      "<key>Label</key><string>dev.tower.panel.station</string>",
    );
    const args = [
      ...plist
        .split("<key>ProgramArguments</key>")[1]!
        .split("</array>")[0]!
        .matchAll(/<string>(.*?)<\/string>/g),
    ].map((m) => m[1]);
    expect(args.slice(0, 2)).toEqual([
      process.execPath,
      join(import.meta.dir, "cli.ts"),
    ]);
    expect(args.slice(2)).toEqual([
      "station",
      "--hub",
      "http://100.64.0.7:7420",
      "--name",
      "rex &amp; sam&apos;s &lt;mac&gt;",
    ]);
    expect(plist).toContain("<key>RunAtLoad</key><true/>");
    expect(plist).toContain("<key>KeepAlive</key><true/>");
    // The jobs need gh, git, claude and the rest: the PATH of the install.
    expect(plist).toContain(
      `<key>PATH</key><string>${process.env.PATH}</string>`,
    );
    expect(plist).toContain(
      `<key>StandardErrorPath</key><string>${join(dir, "state/tower/panel/station.log")}</string>`,
    );
  } finally {
    if (state === undefined) delete process.env.XDG_STATE_HOME;
    else process.env.XDG_STATE_HOME = state;
    rmSync(dir, { recursive: true, force: true });
  }
});
