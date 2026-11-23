/**
 * Seam 2 for the jobs: the real station (`cli.ts station`, with every runner
 * in station/jobs) as its own process against the fixture's hub, the Panel's
 * stubs first on PATH, and real git against the fixture's `remote()` for GitHub's.
 */
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { afterEach } from "bun:test";
import type { Subprocess } from "bun";

import { dir, gitRemotes, hubUrl } from "./fixture.ts";

const CLI = join(import.meta.dir, "../cli.ts");
const STUBS = join(import.meta.dir, "stub");

let procs: Subprocess[] = [];

/**
 * Kills every station a test of this file started, passed or not. Call it at
 * the top of each test file: a hook registered here at import would reach
 * only the first file that imports this module.
 */
export function useStations() {
  afterEach(async () => {
    for (const p of procs) p.kill("SIGKILL");
    await Promise.all(procs.map((p) => p.exited));
    procs = [];
  });
}

/** A station outlives no test: one leaked by a broken teardown dies by this. */
const STATION_MAX_MS = 60_000;

/**
 * Starts the station `server` with `env` on top of the test's, in `workdir`:
 * another workdir stands for another Mac.
 */
export function station(env: Record<string, string> = {}, at = "station") {
  const workdir = join(dir(), at);
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
        ...gitRemotes(),
        ...env,
      },
      stderr: "inherit",
      timeout: STATION_MAX_MS,
      killSignal: "SIGKILL",
    },
  );
  procs.push(proc);
  return proc;
}
