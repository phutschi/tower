/**
 * The four things tower asks git: what repository is this, which branch,
 * what is HEAD, and where is the common directory that every worktree of the
 * repository shares (that is where the run pointer lives). Outside a
 * repository every answer is simply absent; nothing here throws.
 */
import { execFileSync } from "node:child_process";
import { realpathSync } from "node:fs";
import { basename, resolve } from "node:path";

export interface GitInfo {
  repo?: string;
  branch?: string;
  commit?: string;
  commonDir?: string;
}

function git(cwd: string, ...args: string[]): string | undefined {
  try {
    return execFileSync("git", args, {
      cwd,
      stdio: ["ignore", "pipe", "ignore"],
    })
      .toString("utf8")
      .trim();
  } catch {
    return undefined;
  }
}

export function gitInfo(cwd: string): GitInfo {
  const top = git(cwd, "rev-parse", "--show-toplevel");
  if (!top) return {};
  const info: GitInfo = { repo: basename(top) };
  const branch = git(cwd, "rev-parse", "--abbrev-ref", "HEAD");
  if (branch && branch !== "HEAD") info.branch = branch;
  const commit = git(cwd, "rev-parse", "--short", "HEAD");
  if (commit) info.commit = commit;
  const common = git(cwd, "rev-parse", "--git-common-dir");
  // git resolves symlinks in some cases but not others (e.g. macOS's
  // /var -> /private/var); canonicalize so two worktrees of the same
  // repository always agree on the same path.
  if (common) info.commonDir = realpathSync(resolve(cwd, common));
  return info;
}
