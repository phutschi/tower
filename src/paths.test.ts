import { mkdtempSync, writeFileSync } from "node:fs";
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

  test("treats an empty XDG variable as unset, per the XDG spec", () => {
    const env = { XDG_STATE_HOME: "", XDG_CONFIG_HOME: "" };
    expect(runsDir(env, home)).toBe("/home/rex/.local/state/tower/runs");
    expect(themesDir(env, home)).toBe("/home/rex/.config/tower/themes");
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

  test("a wrong type for stale is reported, not silently coerced", () => {
    const dir = mkdtempSync(join(tmpdir(), "t-"));
    const path = join(dir, "config.json");
    writeFileSync(path, JSON.stringify({ stale: "ten" }));
    expect(readConfig(path).problem).toContain("stale");
  });

  test("a wrong type for defaultTheme is reported", () => {
    const dir = mkdtempSync(join(tmpdir(), "t-"));
    const path = join(dir, "config.json");
    writeFileSync(path, JSON.stringify({ defaultTheme: 5 }));
    expect(readConfig(path).problem).toContain("defaultTheme");
  });

  test("a wrong shape for models is reported", () => {
    const dir = mkdtempSync(join(tmpdir(), "t-"));
    const path = join(dir, "config.json");
    writeFileSync(path, JSON.stringify({ models: ["not", "a", "map"] }));
    expect(readConfig(path).problem).toContain("models");
  });

  test("a non-object top-level value is reported, not treated as a crash or empty config", () => {
    const dir = mkdtempSync(join(tmpdir(), "t-"));
    const path = join(dir, "config.json");
    writeFileSync(path, "null");
    const { config, problem } = readConfig(path);
    expect(config).toEqual({});
    expect(problem).toContain(path);
  });

  test("an unreadable file is reported, not silently treated as absent", () => {
    const dir = mkdtempSync(join(tmpdir(), "t-"));
    // a directory where a file is expected: readFileSync fails with EISDIR, not ENOENT
    const { config, problem } = readConfig(dir);
    expect(config).toEqual({});
    expect(problem).toContain(dir);
  });
});
