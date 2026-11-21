/**
 * Where a job executes (ADR 0017): behind this one seam, so a container can
 * replace it later. v1 is a checkout per job on this Mac, with its own test
 * database name and ports.
 *
 * Each job gets its own clone, borrowing the objects of the station's base
 * clone of the repo (git clone --reference), not a worktree of it: tower
 * keeps one live run per git common dir (ADR 0006), so two runs of one repo
 * on one Mac need two.
 */
import { execFile } from "node:child_process";
import { existsSync, rmSync } from "node:fs";
import { createServer } from "node:net";
import { join } from "node:path";
import { promisify } from "node:util";

import type { Job } from "../types.ts";

const run = promisify(execFile);
const git = async (cwd: string, ...args: string[]) =>
  (await run("git", args, { cwd })).stdout.trim();

/** How many ports a job gets for its dev servers and test services. */
const PORTS = 3;

export interface Workspace {
  path: string;
  branch: string;
  ports: number[];
  databaseName: string;
}

export interface Executor {
  prepare(job: Job): Promise<Workspace>;
  release(ws: Workspace): Promise<void>;
}

/** A port free right now, from the OS. */
function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.unref();
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address() as { port: number };
      server.close(() => resolve(port));
    });
  });
}

export class CheckoutExecutor implements Executor {
  // Jobs of one repo share its base clone: one fetch at a time.
  private readonly locks = new Map<string, Promise<unknown>>();
  // Ports handed to live workspaces, so two jobs never share one.
  private readonly taken = new Set<number>();

  constructor(private readonly workdir: string) {}

  private locked<T>(key: string, fn: () => Promise<T>): Promise<T> {
    const next = (this.locks.get(key) ?? Promise.resolve()).then(fn, fn);
    this.locks.set(
      key,
      next.catch(() => {}),
    );
    return next;
  }

  private async ports(): Promise<number[]> {
    const ports: number[] = [];
    while (ports.length < PORTS) {
      const port = await freePort();
      if (this.taken.has(port)) continue;
      this.taken.add(port);
      ports.push(port);
    }
    return ports;
  }

  async prepare(job: Job): Promise<Workspace> {
    const url = `https://github.com/${job.repo}.git`;
    const base = join(this.workdir, "repos", job.repo);
    await this.locked(base, async () => {
      if (existsSync(base)) await git(base, "fetch", "--quiet", "origin");
      else await git(this.workdir, "clone", "--quiet", "--bare", url, base);
    });
    const path = join(this.workdir, "jobs", job.id);
    // A station that crashed left this job's checkout: start over.
    rmSync(path, { recursive: true, force: true });
    await git(this.workdir, "clone", "--quiet", "--reference", base, url, path);
    const branch = `panel/${job.kind}-${job.issues.join("-")}-${job.id.slice(0, 8)}`;
    await git(path, "switch", "--quiet", "-c", branch);
    const name = `${job.repo}_${job.id.slice(0, 8)}`;
    return {
      path,
      branch,
      ports: await this.ports(),
      databaseName: `panel_${name.toLowerCase().replace(/[^a-z0-9]+/g, "_")}`,
    };
  }

  async release(ws: Workspace): Promise<void> {
    for (const port of ws.ports) this.taken.delete(port);
    rmSync(ws.path, { recursive: true, force: true });
  }
}
