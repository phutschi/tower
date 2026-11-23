/**
 * Bun test preload: give each test run its own temp folder and remove it after.
 *
 * The tests make their fixtures (fake homes, repos, run and state dirs) under
 * `os.tmpdir()` and never remove them, so every run left about 290 folders in
 * the shared temp folder. This points `TMPDIR` at a per-run root
 * (`tower-test-run-<pid>-*`) and removes that root when the run ends, whether
 * the tests passed or failed.
 *
 * A run that was killed, stopped by `--bail`, or ended by a test that calls
 * `process.exit` never gets that far and leaves its root behind. So each run
 * first removes the roots whose process is gone. A pid that was reused by
 * another process only delays that removal.
 *
 * Child processes started with node:child_process inherit the redirect, which
 * is how every test starts one today. A child started with Bun.spawn and no
 * `env` option would keep the outer TMPDIR.
 *
 * If `TOWER_TEST_TMP_ROOT` already names an existing folder, an outer test
 * process owns that root and this preload does nothing. That covers a file
 * loaded twice in one process and a test that starts a nested `bun test` with
 * its own environment passed on.
 *
 * `bunfig.toml` lists this file, and Bun reads it from the current folder
 * only, so the redirect applies to `bun test` run from the repo root. `test.sh`
 * is a separate shell suite and removes its own temp folder. Not shipped:
 * `tsconfig.build.json` leaves this file out, like `testing.ts`.
 */
import {
  existsSync,
  mkdtempSync,
  readdirSync,
  realpathSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll } from "bun:test";

function isRunning(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    // EPERM: the process exists but belongs to another user.
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}

const existing = process.env.TOWER_TEST_TMP_ROOT;
if (!existing || !existsSync(existing)) {
  try {
    const base = tmpdir();
    for (const name of readdirSync(base)) {
      const owner = /^tower-test-run-(\d+)-/.exec(name)?.[1];
      if (!owner || isRunning(Number(owner))) continue;
      try {
        rmSync(join(base, name), { recursive: true, force: true });
      } catch {
        // Another run may be removing it; a leftover only costs disk space.
      }
    }
    // A real path: git reports real paths, the tests compare against them,
    // and on macOS the temp folder sits behind a symlink.
    const root = realpathSync(
      mkdtempSync(join(base, `tower-test-run-${process.pid}-`)),
    );
    const outer = { TMPDIR: process.env.TMPDIR, TOWER_TEST_TMP_ROOT: existing };
    process.env.TMPDIR = root;
    process.env.TOWER_TEST_TMP_ROOT = root;
    afterAll(() => {
      try {
        rmSync(root, { recursive: true, force: true });
      } catch {
        // Never fail the run over cleanup.
      }
      // Bun runs this preload again on each `bun test --watch` pass. Restore
      // the outer environment so the next pass starts from the real temp folder.
      for (const [key, value] of Object.entries(outer)) {
        if (value === undefined) delete process.env[key];
        else process.env[key] = value;
      }
    });
  } catch {
    // No usable temp folder: run unredirected rather than fail every test.
  }
}
