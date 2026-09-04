/**
 * These spawn `src/cli.ts` for real, so what they assert is the byte stream a
 * shell (or an agent's tool call) would see — including the promise never to
 * leave a pipe in the alternate screen.
 */
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { describe, expect, test } from "bun:test";

import { seededRun } from "../testing.ts";
import { ENTER_ALT } from "./console.tsx";

const CLI = join(dirname(import.meta.path), "..", "cli.ts");

function tower(args: string[], env: Record<string, string>) {
  const result = spawnSync("bun", ["run", CLI, ...args], {
    env: {
      ...process.env,
      TOWER_RUN: "",
      ...env,
      HOME: mkdtempSync(join(tmpdir(), "tower-home-")),
    },
    encoding: "utf8",
    cwd: mkdtempSync(join(tmpdir(), "tower-cwd-")),
  });
  return { code: result.status, out: result.stdout, err: result.stderr };
}

describe("bare tower in a pipe", () => {
  test("prints one snapshot, never enters the alternate screen, exits 0", () => {
    const { runDir } = seededRun();
    const { code, out } = tower([], { TOWER_RUN: runDir });
    expect(code).toBe(0);
    expect(out).toContain("ACME · feature/widgets");
    expect(out).toContain("DEPARTURES");
    expect(out).not.toContain(ENTER_ALT);
  });
  test("--plain is literal", () => {
    const { runDir } = seededRun();
    expect(tower(["--plain"], { TOWER_RUN: runDir }).out).toContain("TASKS");
  });
});

describe("starting with nothing", () => {
  test("no run: exit 2 and the init line", () => {
    const { code, err } = tower([], {});
    expect(code).toBe(2);
    expect(err).toContain("tower init");
  });
  test("a corrupt run.json is named", () => {
    const { runDir } = seededRun();
    writeFileSync(join(runDir, "run.json"), "{ nope");
    const { code, err } = tower([], { TOWER_RUN: runDir });
    expect(code).toBe(1);
    expect(err).toContain("run.json");
  });
  test("an unknown theme lists what exists and exits 1", () => {
    const { runDir } = seededRun();
    const { code, err } = tower(["--theme", "nope"], { TOWER_RUN: runDir });
    expect(code).toBe(1);
    expect(err).toContain("airport");
  });
  test("a corrupt config file is a warning, not a failure", () => {
    const { runDir } = seededRun();
    const config = mkdtempSync(join(tmpdir(), "tower-config-"));
    mkdirSync(join(config, "tower"), { recursive: true });
    writeFileSync(join(config, "tower", "config.json"), "{ nope");
    const { code } = tower(["state", "--json"], {
      TOWER_RUN: runDir,
      XDG_CONFIG_HOME: config,
    });
    expect(code).toBe(0);
  });
});
