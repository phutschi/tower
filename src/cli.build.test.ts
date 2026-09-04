/**
 * The built CLI is the actual artifact users run (`npm install -g`, or a
 * compiled binary); the source tests never exercise it. This builds for
 * real and spawns the result under plain Node — the same guard CI runs
 * (ci.yml's `node dist/cli.js --help` step) — so a bundler regression like
 * two shebang lines (the package.json banner plus one already in the
 * source) fails locally in `bun run check`, not only in CI.
 */
import { execFileSync, spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { describe, expect, test } from "bun:test";

describe("the built CLI", () => {
  test("has exactly one shebang line and runs under plain node", () => {
    execFileSync("bun", ["run", "build"], {
      cwd: import.meta.dir + "/..",
      stdio: "pipe",
    });
    const built = readFileSync(`${import.meta.dir}/../dist/cli.js`, "utf8");
    const shebangs = built
      .split("\n")
      .filter((line) => line.startsWith("#!/usr/bin/env node"));
    expect(shebangs).toHaveLength(1);
    expect(built.startsWith("#!/usr/bin/env node\n")).toBe(true);

    const result = spawnSync(
      "node",
      [`${import.meta.dir}/../dist/cli.js`, "--help"],
      { encoding: "utf8" },
    );
    expect(result.status).toBe(0);
    expect(result.stdout).toContain("tower —");
  });
});
