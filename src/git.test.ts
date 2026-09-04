import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { describe, expect, test } from "bun:test";

import { gitInfo } from "./git.ts";

function isolatedGit(dir: string) {
  return (...args: string[]) =>
    execFileSync("git", args, {
      cwd: dir,
      stdio: "pipe",
      env: { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null" },
    });
}

function repo(): { dir: string; git: ReturnType<typeof isolatedGit> } {
  const dir = mkdtempSync(join(tmpdir(), "tower-git-"));
  const git = isolatedGit(dir);
  git("init", "-b", "feature/widgets");
  git("config", "user.email", "someone@example.com");
  git("config", "user.name", "rex");
  writeFileSync(join(dir, "a"), "a");
  git("add", "a");
  git("commit", "-m", "one");
  return { dir, git };
}

describe("gitInfo", () => {
  test("reads repo name, branch, short sha and the common dir", () => {
    const { dir } = repo();
    const info = gitInfo(dir);
    expect(info.repo).toBe(basename(dir));
    expect(info.branch).toBe("feature/widgets");
    expect(info.commit).toMatch(/^[0-9a-f]{7,}$/);
    expect(info.commonDir?.endsWith(".git")).toBe(true);
  });

  test("a worktree resolves to the same common dir as its main checkout", () => {
    const { dir, git } = repo();
    const wt = join(mkdtempSync(join(tmpdir(), "tower-wt-")), "lane-b");
    git("worktree", "add", "-b", "lane-b", wt);
    expect(gitInfo(wt).commonDir).toBe(gitInfo(dir).commonDir);
  });

  test("a worktree reports the main checkout's repo name, not its own directory", () => {
    const { dir, git } = repo();
    const wt = join(mkdtempSync(join(tmpdir(), "tower-wt-")), "lane-b");
    git("worktree", "add", "-b", "lane-b", wt);
    expect(gitInfo(wt).repo).toBe(gitInfo(dir).repo);
  });

  test("a worktree's branch is its own, not the main checkout's", () => {
    const { dir, git } = repo();
    const wt = join(mkdtempSync(join(tmpdir(), "tower-wt-")), "lane-b");
    git("worktree", "add", "-b", "lane-b", wt);
    expect(gitInfo(wt).branch).toBe("lane-b");
    expect(gitInfo(dir).branch).toBe("feature/widgets");
  });

  test("a repository with no commits yet has no branch or commit", () => {
    const dir = mkdtempSync(join(tmpdir(), "tower-git-empty-"));
    isolatedGit(dir)("init", "-b", "main");
    const info = gitInfo(dir);
    expect(info.branch).toBeUndefined();
    expect(info.commit).toBeUndefined();
    expect(info.repo).toBe(basename(dir));
  });

  test("a detached HEAD has no branch but does have a commit", () => {
    const { dir, git } = repo();
    git("checkout", "--detach", "HEAD");
    const info = gitInfo(dir);
    expect(info.branch).toBeUndefined();
    expect(info.commit).toMatch(/^[0-9a-f]{7,}$/);
  });

  test("outside a repository everything is undefined, nothing throws", () => {
    expect(gitInfo(mkdtempSync(join(tmpdir(), "tower-nogit-")))).toEqual({});
  });
});
