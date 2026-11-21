/**
 * Where a job executes (ADR 0017): behind this one seam, so a container can
 * replace it later. v1 is a git worktree per job, off the station's own clone
 * of the job's repo.
 */
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { promisify } from "node:util";

import type { Job } from "../types.ts";

const run = promisify(execFile);
const git = async (cwd: string, ...args: string[]) =>
  (await run("git", args, { cwd })).stdout.trim();

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

export class WorktreeExecutor implements Executor {
  // Jobs of one repo share its clone: one git command on it at a time.
  private readonly locks = new Map<string, Promise<unknown>>();
  // Each workspace's clone, so release finds the clone to remove it from.
  private readonly clones = new Map<string, string>();

  constructor(private readonly workdir: string) {}

  private locked<T>(key: string, fn: () => Promise<T>): Promise<T> {
    const prev = this.locks.get(key) ?? Promise.resolve();
    const next = prev.then(fn, fn);
    this.locks.set(
      key,
      next.catch(() => {}),
    );
    return next;
  }

  prepare(job: Job): Promise<Workspace> {
    const clone = join(this.workdir, "repos", job.repo);
    return this.locked(clone, async () => {
      if (existsSync(clone)) await git(clone, "fetch", "--quiet", "origin");
      else
        await git(
          this.workdir,
          "clone",
          "--quiet",
          `https://github.com/${job.repo}.git`,
          clone,
        );
      const path = join(this.workdir, "jobs", job.id);
      const branch = `panel/${job.kind}-${job.issues.join("-")}-${job.id.slice(0, 8)}`;
      await git(
        clone,
        "worktree",
        "add",
        "--quiet",
        "-b",
        branch,
        path,
        "origin/HEAD",
      );
      this.clones.set(path, clone);
      return { path, branch, ports: [], databaseName: "" };
    });
  }

  async release(ws: Workspace): Promise<void> {
    const clone = this.clones.get(ws.path);
    if (!clone) return;
    this.clones.delete(ws.path);
    await this.locked(clone, async () => {
      await git(clone, "worktree", "remove", "--force", ws.path);
      await git(clone, "branch", "-D", ws.branch);
    });
  }
}
