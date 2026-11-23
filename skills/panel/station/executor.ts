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
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { createServer } from "node:net";
import { basename, join } from "node:path";
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
  /** Lets a job's workspace go: removed now, or kept `keepHours` first. */
  release(ws: Workspace, keepHours: number): Promise<void>;
  /** Removes the kept workspaces whose time is up. */
  prune(): Promise<void>;
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

/**
 * A job's test database: panel_, its repo, then its id's first 8 characters.
 * The repo part is cut so the id survives PostgreSQL's 63-byte names.
 */
export function databaseName(job: Job): string {
  const slug = (t: string) => t.toLowerCase().replace(/[^a-z0-9]+/g, "_");
  const id = slug(job.id.slice(0, 8));
  return `panel_${slug(job.repo).slice(0, 63 - "panel_".length - 1 - id.length)}_${id}`;
}

export class CheckoutExecutor implements Executor {
  // Jobs of one repo share its base clone: one fetch at a time.
  private readonly locks = new Map<string, Promise<unknown>>();
  // Ports handed to live workspaces, so two jobs never share one.
  private readonly taken = new Set<number>();

  // Kept checkouts, one file each naming its path and until when it stays.
  private readonly keep: string;

  constructor(
    private readonly workdir: string,
    private readonly now: () => Date = () => new Date(),
  ) {
    this.keep = join(workdir, "keep");
  }

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
    mkdirSync(this.workdir, { recursive: true });
    await this.locked(base, async () => {
      if (existsSync(base)) await git(base, "fetch", "--quiet", "origin");
      else await git(this.workdir, "clone", "--quiet", "--bare", url, base);
    });
    const path = join(this.workdir, "jobs", job.id);
    // A station that crashed left this job's checkout: start over.
    rmSync(path, { recursive: true, force: true });
    rmSync(join(this.keep, `${basename(path)}.json`), { force: true });
    await git(this.workdir, "clone", "--quiet", "--reference", base, url, path);
    const branch = `panel/${job.kind}-${job.issues.join("-")}-${job.id.slice(0, 8)}`;
    await git(path, "switch", "--quiet", "-c", branch);
    return {
      path,
      branch,
      ports: await this.ports(),
      databaseName: databaseName(job),
    };
  }

  async release(ws: Workspace, keepHours: number): Promise<void> {
    for (const port of ws.ports) this.taken.delete(port);
    if (keepHours <= 0) {
      rmSync(ws.path, { recursive: true, force: true });
      return;
    }
    const until = new Date(this.now().getTime() + keepHours * 3_600_000);
    mkdirSync(this.keep, { recursive: true });
    writeFileSync(
      join(this.keep, `${basename(ws.path)}.json`),
      JSON.stringify({ path: ws.path, until: until.toISOString() }),
    );
  }

  async prune(): Promise<void> {
    if (!existsSync(this.keep)) return;
    for (const f of readdirSync(this.keep)) {
      const marker = join(this.keep, f);
      // A marker left half-written counts as expired: its checkout is the
      // job's, by the marker's name.
      let kept = {
        path: join(this.workdir, "jobs", basename(f, ".json")),
        until: "",
      };
      try {
        kept = JSON.parse(readFileSync(marker, "utf8")) as typeof kept;
      } catch {
        // expired
      }
      if (Date.parse(kept.until) > this.now().getTime()) continue;
      rmSync(kept.path, { recursive: true, force: true });
      rmSync(marker, { force: true });
    }
  }
}
