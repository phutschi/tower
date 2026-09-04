import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { describe, expect, test } from "bun:test";

import { gitInfo } from "./git.ts";

function repo(): string {
  const dir = mkdtempSync(join(tmpdir(), "tower-git-"));
  const git = (...args: string[]) =>
    execFileSync("git", args, {
      cwd: dir,
      stdio: "pipe",
      env: { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null" },
    });
  git("init", "-b", "feature/widgets");
  git("config", "user.email", "someone@example.com");
  git("config", "user.name", "rex");
  writeFileSync(join(dir, "a"), "a");
  git("add", "a");
  git("commit", "-m", "one");
  return dir;
}

describe("gitInfo", () => {
  test("reads repo name, branch, short sha and the common dir", () => {
    const dir = repo();
    const info = gitInfo(dir);
    expect(info.repo).toBe(basename(dir));
    expect(info.branch).toBe("feature/widgets");
    expect(info.commit).toMatch(/^[0-9a-f]{7,}$/);
    expect(info.commonDir?.endsWith(".git")).toBe(true);
  });

  test("a worktree resolves to the same common dir as its main checkout", () => {
    const dir = repo();
    const wt = join(mkdtempSync(join(tmpdir(), "tower-wt-")), "lane-b");
    execFileSync("git", ["worktree", "add", "-b", "lane-b", wt], {
      cwd: dir,
      stdio: "pipe",
    });
    expect(gitInfo(wt).commonDir).toBe(gitInfo(dir).commonDir);
    expect(gitInfo(wt).branch).toBe("lane-b");
  });

  test("outside a repository everything is undefined, nothing throws", () => {
    expect(gitInfo(mkdtempSync(join(tmpdir(), "tower-nogit-")))).toEqual({});
  });
});
