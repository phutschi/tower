import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterAll, describe, expect, test } from "bun:test";

const repoRoot = resolve(import.meta.dir, "..");
const preload = join(import.meta.dir, "test-tmpdir.ts");

const work = mkdtempSync(join(tmpdir(), "tower-tmpdir-check-"));
afterAll(() => rmSync(work, { recursive: true, force: true }));

const makesTempFolders = `
import { expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
test("makes temp folders", () => {
  mkdtempSync(join(tmpdir(), "fixture-"));
  mkdtempSync(join(tmpdir(), "fixture-"));
  expect(1).toBe(1);
});
`;

const failsAfterMakingTempFolders = makesTempFolders.replace(
  "expect(1).toBe(1)",
  "expect(1).toBe(2)",
);

const passes = `
import { expect, test } from "bun:test";
test("passes", () => {
  expect(1).toBe(1);
});
`;

// Runs a nested `bun test` with the preload and TMPDIR pointed at a private
// base folder. The cwd has no bunfig.toml, so only the explicit --preload
// applies. TOWER_TEST_TMP_ROOT is never inherited. With `linkBase` the base
// is a symlink to a folder, as the temp folder is on macOS.
function runNested(
  source: string | ((base: string) => string),
  options: {
    setup?: (base: string) => void;
    env?: Record<string, string>;
    missingBase?: boolean;
    linkBase?: boolean;
  } = {},
) {
  const dir = mkdtempSync(join(work, "case-"));
  const base = join(dir, "tmp");
  if (options.linkBase) {
    mkdirSync(join(dir, "real"));
    symlinkSync(join(dir, "real"), base);
  } else if (!options.missingBase) mkdirSync(base);
  options.setup?.(base);
  const file = join(dir, "fixture.test.ts");
  writeFileSync(file, typeof source === "string" ? source : source(base));
  const env: Record<string, string | undefined> = {
    ...process.env,
    TMPDIR: base,
    ...options.env,
  };
  if (!options.env?.TOWER_TEST_TMP_ROOT) delete env.TOWER_TEST_TMP_ROOT;
  const result = spawnSync(
    process.execPath,
    ["test", "--preload", preload, file],
    { cwd: dir, env, encoding: "utf8", timeout: 30_000 },
  );
  return {
    status: result.status,
    output: `${result.stdout}${result.stderr}`,
    base,
    entries: () => readdirSync(base),
  };
}

describe("test temp folder preload", () => {
  test("a passing fixture leaves no temp folders behind", () => {
    const run = runNested(makesTempFolders);
    expect(run.output).toMatch(/^ 1 pass$/m);
    expect(run.status).toBe(0);
    expect(run.entries()).toEqual([]);
  });

  test("a failing fixture leaves no temp folders behind", () => {
    const run = runNested(failsAfterMakingTempFolders);
    expect(run.output).toMatch(/^ 1 fail$/m);
    expect(run.status).not.toBe(0);
    expect(run.entries()).toEqual([]);
  });

  test("removes only the roots of runs whose process is gone", () => {
    const gone = spawnSync(process.execPath, ["-e", ""]).pid;
    const left = `tower-test-run-${gone}-left`;
    // Kept: the root of a live run, the root of a process another user owns
    // (pid 1), and folders that only look like a root.
    const kept = [
      `tower-test-run-${process.pid}-live`,
      "tower-test-run-1-other-user",
      "tower-test-run-abc-not-a-pid",
      `tower-run-${gone}-fixture`,
      `tower-other-${gone}`,
    ];
    const run = runNested(makesTempFolders, {
      setup: (base) => {
        for (const name of [left, ...kept]) {
          mkdirSync(join(base, name));
          writeFileSync(join(base, name, "file.txt"), "");
        }
      },
    });
    expect(run.status).toBe(0);
    expect(run.entries().sort()).toEqual([...kept].sort());
    for (const name of kept) {
      expect(existsSync(join(run.base, name, "file.txt"))).toBe(true);
    }
  });

  // git reports real paths and the tests compare against them, so the root
  // must be one even when the temp folder sits behind a symlink.
  test("the root is a real path when TMPDIR is a symlink", () => {
    const run = runNested(
      `
import { expect, test } from "bun:test";
import { realpathSync } from "node:fs";
import { tmpdir } from "node:os";
test("the temp folder is a real path", () => {
  expect(tmpdir()).toBe(realpathSync(tmpdir()));
});
`,
      { linkBase: true },
    );
    expect(run.output).toMatch(/^ 1 pass$/m);
    expect(run.status).toBe(0);
    expect(run.entries()).toEqual([]);
  });

  test("with TOWER_TEST_TMP_ROOT set to an existing folder, neither creates nor removes a root", () => {
    const given = join(work, "given-root");
    mkdirSync(given);
    const run = runNested(
      (base) => `
import { expect, test } from "bun:test";
test("keeps the outer root", () => {
  expect(process.env.TMPDIR).toBe(${JSON.stringify(base)});
  expect(process.env.TOWER_TEST_TMP_ROOT).toBe(${JSON.stringify(given)});
});
`,
      { env: { TOWER_TEST_TMP_ROOT: given } },
    );
    expect(run.output).toMatch(/^ 1 pass$/m);
    expect(run.status).toBe(0);
    expect(run.entries()).toEqual([]);
    expect(existsSync(given)).toBe(true);
  });

  test("a missing TMPDIR does not fail the run", () => {
    const run = runNested(passes, { missingBase: true });
    expect(run.output).toMatch(/^ 1 pass$/m);
    expect(run.status).toBe(0);
    expect(existsSync(run.base)).toBe(false);
  });

  // Bun reads bunfig.toml from the current folder, so `bun test` from the
  // repo root gets the preload only while the root bunfig lists it.
  test("bunfig.toml lists the preload", () => {
    const list =
      readFileSync(join(repoRoot, "bunfig.toml"), "utf8").match(
        /preload\s*=\s*\[([^\]]*)\]/,
      )?.[1] ?? "";
    const entries = [...list.matchAll(/"([^"]+)"/g)].map((match) =>
      resolve(repoRoot, match[1] ?? ""),
    );
    expect(entries).toContain(preload);
  });

  // The preload imports bun:test, which plain Node cannot load, so it must
  // stay out of the built CLI.
  test("the build leaves the preload out", () => {
    const build = JSON.parse(
      readFileSync(join(repoRoot, "tsconfig.build.json"), "utf8"),
    ) as { exclude?: string[] };
    expect(build.exclude).toContain("src/test-tmpdir.ts");
  });
});
