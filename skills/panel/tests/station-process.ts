/**
 * Seam 2 for the jobs: the real station (`cli.ts station`, with every runner
 * in station/jobs) as its own process against the fixture's hub, the Panel's
 * stubs first on PATH, and real git against a temp bare repo for GitHub's.
 */
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach } from "bun:test";
import type { Subprocess } from "bun";

import { dir, hubUrl } from "./fixture.ts";

const CLI = join(import.meta.dir, "../cli.ts");
const STUBS = join(import.meta.dir, "stub");

const git = (cwd: string, ...args: string[]) =>
  execFileSync("git", args, { cwd, encoding: "utf8" });

/** acme/widgets as a bare repo with two merges; git reaches it for github.com. */
export function remote() {
  const seed = join(dir(), "seed");
  mkdirSync(seed, { recursive: true });
  git(seed, "init", "-q", "-b", "main");
  for (const subject of ["Add the parser", "Merge pull request #7"]) {
    writeFileSync(join(seed, "README.md"), `${subject}\n`);
    git(seed, "add", ".");
    git(
      seed,
      "-c",
      "user.name=rex",
      "-c",
      "user.email=someone@example.com",
      "commit",
      "-qm",
      subject,
    );
  }
  mkdirSync(join(dir(), "remotes/acme"), { recursive: true });
  git(
    dir(),
    "clone",
    "-q",
    "--bare",
    seed,
    join(dir(), "remotes/acme/widgets.git"),
  );
}

let procs: Subprocess[] = [];
afterEach(async () => {
  for (const p of procs) p.kill("SIGKILL");
  await Promise.all(procs.map((p) => p.exited));
  procs = [];
});

/** Starts the station `server` with `env` on top of the test's. */
export function station(env: Record<string, string> = {}) {
  const workdir = join(dir(), "station");
  mkdirSync(workdir, { recursive: true });
  const proc = Bun.spawn(
    [
      "bun",
      CLI,
      "station",
      "--hub",
      hubUrl(),
      "--name",
      "server",
      "--workdir",
      workdir,
      "--heartbeat-seconds",
      "0.05",
    ],
    {
      env: {
        ...process.env,
        PATH: `${STUBS}:${process.env.PATH}`,
        CLAUDE_STUB_LOG: join(dir(), "claude.log"),
        PLANNOTATOR_STUB_LOG: join(dir(), "plannotator.log"),
        GIT_CONFIG_COUNT: "1",
        GIT_CONFIG_KEY_0: `url.file://${join(dir(), "remotes")}/.insteadOf`,
        GIT_CONFIG_VALUE_0: "https://github.com/",
        ...env,
      },
      stderr: "inherit",
    },
  );
  procs.push(proc);
  return proc;
}
