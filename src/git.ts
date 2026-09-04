/**
 * The four things tower asks git: what repository is this, which branch,
 * what is HEAD, and where is the common directory that every worktree of the
 * repository shares (that is where the run pointer lives). Outside a
 * repository — including a bare one, which has no work tree — every answer
 * is simply absent; nothing here throws.
 */
import { execFileSync } from "node:child_process";
import { realpathSync } from "node:fs";
import { basename, dirname, resolve } from "node:path";

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

/** name would derive from `--show-toplevel`, but that is the worktree's own
 * directory in a linked worktree — every lane would report a different repo.
 * The common dir is shared by every worktree, so its parent (or itself, for
 * a bare repo) is the one name all of them agree on. */
function repoNameFromCommonDir(commonDir: string): string {
  return basename(commonDir.endsWith(".git") ? dirname(commonDir) : commonDir);
}

export function gitInfo(cwd: string): GitInfo {
  const top = git(cwd, "rev-parse", "--show-toplevel");
  if (!top) return {};
  const info: GitInfo = {};
  const branch = git(cwd, "rev-parse", "--abbrev-ref", "HEAD");
  if (branch && branch !== "HEAD") info.branch = branch;
  const commit = git(cwd, "rev-parse", "--short", "HEAD");
  if (commit) info.commit = commit;
  const common = git(cwd, "rev-parse", "--git-common-dir");
  if (common) {
    // git resolves symlinks in some cases but not others (e.g. macOS's
    // /var -> /private/var); canonicalize so two worktrees of the same
    // repository always agree on the same path. realpath can still fail
    // (a stale worktree gitdir, an unreadable parent) — this module
    // promises never to throw, so fall back to the uncanonicalized path.
    const resolved = resolve(cwd, common);
    info.commonDir = (() => {
      try {
        return realpathSync(resolved);
      } catch {
        return resolved;
      }
    })();
    info.repo = repoNameFromCommonDir(info.commonDir);
  } else {
    info.repo = basename(top);
  }
  return info;
}
