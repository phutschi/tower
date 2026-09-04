import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";

import { configPath, readConfig, runsDir, themesDir } from "./paths.ts";

const home = "/home/rex";

describe("XDG resolution", () => {
  test("defaults under the home directory", () => {
    expect(runsDir({}, home)).toBe("/home/rex/.local/state/tower/runs");
    expect(themesDir({}, home)).toBe("/home/rex/.config/tower/themes");
    expect(configPath({}, home)).toBe("/home/rex/.config/tower/config.json");
  });

  test("honours XDG_STATE_HOME and XDG_CONFIG_HOME", () => {
    const env = { XDG_STATE_HOME: "/s", XDG_CONFIG_HOME: "/c" };
    expect(runsDir(env, home)).toBe("/s/tower/runs");
    expect(themesDir(env, home)).toBe("/c/tower/themes");
  });
});

describe("readConfig", () => {
  test("a missing file is the empty config, not a problem", () => {
    const { config, problem } = readConfig(
      join(mkdtempSync(join(tmpdir(), "t-")), "config.json"),
    );
    expect(config).toEqual({});
    expect(problem).toBeUndefined();
  });

  test("reads the three keys and ignores others", () => {
    const dir = mkdtempSync(join(tmpdir(), "t-"));
    const path = join(dir, "config.json");
    writeFileSync(
      path,
      JSON.stringify({
        defaultTheme: "police",
        stale: 5,
        models: { implementer: "x" },
        extra: 1,
      }),
    );
    expect(readConfig(path).config).toEqual({
      defaultTheme: "police",
      stale: 5,
      models: { implementer: "x" },
    });
  });

  test("a broken file is reported by path, and yields the empty config", () => {
    const dir = mkdtempSync(join(tmpdir(), "t-"));
    const path = join(dir, "config.json");
    writeFileSync(path, "{ nope");
    const { config, problem } = readConfig(path);
    expect(config).toEqual({});
    expect(problem).toContain(path);
  });

  test("a wrong type is reported, not silently coerced", () => {
    const dir = mkdtempSync(join(tmpdir(), "t-"));
    mkdirSync(dir, { recursive: true });
    const path = join(dir, "config.json");
    writeFileSync(path, JSON.stringify({ stale: "ten" }));
    expect(readConfig(path).problem).toContain("stale");
  });
});
