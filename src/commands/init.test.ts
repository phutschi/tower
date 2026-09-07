import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";

import { readEvents } from "../events.ts";
import { main } from "../main.ts";
import { readPointer, readRun } from "../run.ts";
import { fakeIo, seededRun } from "../testing.ts";

const PLAN = `---
repo: acme
branch: feature/widgets
---
# Widgets Implementation Plan

## Repo conventions every task must follow

- No non-null assertions.

## Tasks

### Task 1: The shared prompt shortcuts
### Task 2: The gate
### Task auth-1: Voice notes
`;

function planFile(): string {
  const dir = mkdtempSync(join(tmpdir(), "tower-plan-"));
  const path = join(dir, "plan.md");
  writeFileSync(path, PLAN);
  return path;
}

/** A git repository to run init in, so the pointer has a home. HEAD needs a
 * commit or `git rev-parse --abbrev-ref HEAD` cannot resolve a branch name. */
function gitRepo(): string {
  const dir = mkdtempSync(join(tmpdir(), "tower-repo-"));
  execFileSync("git", ["init", "-b", "main"], { cwd: dir, stdio: "pipe" });
  execFileSync(
    "git",
    [
      "-c",
      "user.name=tower",
      "-c",
      "user.email=tower@example.com",
      "commit",
      "--allow-empty",
      "-m",
      "start",
    ],
    { cwd: dir, stdio: "pipe" },
  );
  return dir;
}

describe("tower init", () => {
  test("from a plan: writes run.json, assigns lanes, drops the pointer, prints the run dir", async () => {
    const cwd = gitRepo();
    const state = mkdtempSync(join(tmpdir(), "tower-state-"));
    const io = fakeIo({ cwd, env: { XDG_STATE_HOME: state } });
    const code = await main(
      ["init", "--plan", planFile(), "--lane", "A=1-2", "--lane", "B=auth-1"],
      io,
    );
    expect(code).toBe(0);
    const printed = io.out.join("");
    const runDir = /run dir: (.+)/.exec(printed)?.[1]?.trim();
    expect(runDir?.startsWith(join(state, "tower", "runs"))).toBe(true);
    const run = readRun(runDir as string);
    expect(run.repo).toBe("acme");
    expect(run.branch).toBe("feature/widgets");
    expect(run.callsign).toBe("ACME");
    expect(run.tasks).toHaveLength(3);
    expect(run.planPath).toContain("plan.md");
    const kinds = readEvents(
      join(runDir as string, "events.ndjson"),
      0,
    ).lines.map((l) => l.event?.kind);
    expect(kinds).toEqual(["assign", "assign"]);
    expect(readPointer(join(cwd, ".git"))).toBe(runDir);
    expect(printed).toContain("3 tasks");
  });

  test("with no --model and no config, models default to the three empty roles", async () => {
    const io = fakeIo({
      cwd: gitRepo(),
      env: { XDG_STATE_HOME: mkdtempSync(join(tmpdir(), "s-")) },
    });
    await main(["init", "--plan", planFile()], io);
    const runDir = /run dir: (.+)/.exec(io.out.join(""))?.[1]?.trim() as string;
    expect(readRun(runDir).models).toEqual({
      implementer: "",
      "spec-reviewer": "",
      "quality-reviewer": "",
    });
  });

  test("models come from the config file when no --model is given", async () => {
    const { mkdirSync } = await import("node:fs");
    const config = mkdtempSync(join(tmpdir(), "tower-config-"));
    mkdirSync(join(config, "tower"), { recursive: true });
    writeFileSync(
      join(config, "tower", "config.json"),
      JSON.stringify({ models: { implementer: "from-config" } }),
    );
    const io = fakeIo({
      cwd: gitRepo(),
      env: {
        XDG_STATE_HOME: mkdtempSync(join(tmpdir(), "s-")),
        XDG_CONFIG_HOME: config,
      },
    });
    await main(["init", "--plan", planFile()], io);
    const runDir = /run dir: (.+)/.exec(io.out.join(""))?.[1]?.trim() as string;
    expect(readRun(runDir).models).toEqual({ implementer: "from-config" });
  });

  test("a --model flag overrides the config file", async () => {
    const { mkdirSync } = await import("node:fs");
    const config = mkdtempSync(join(tmpdir(), "tower-config-"));
    mkdirSync(join(config, "tower"), { recursive: true });
    writeFileSync(
      join(config, "tower", "config.json"),
      JSON.stringify({ models: { implementer: "from-config" } }),
    );
    const io = fakeIo({
      cwd: gitRepo(),
      env: {
        XDG_STATE_HOME: mkdtempSync(join(tmpdir(), "s-")),
        XDG_CONFIG_HOME: config,
      },
    });
    await main(
      ["init", "--plan", planFile(), "--model", "implementer=sonnet-5[1m]"],
      io,
    );
    const runDir = /run dir: (.+)/.exec(io.out.join(""))?.[1]?.trim() as string;
    expect(readRun(runDir).models).toEqual({ implementer: "sonnet-5[1m]" });
  });

  test("refuses over an open run and says how to close it", async () => {
    const cwd = gitRepo();
    const env = { XDG_STATE_HOME: mkdtempSync(join(tmpdir(), "s-")) };
    const first = fakeIo({ cwd, env });
    await main(["init", "--plan", planFile()], first);
    const second = fakeIo({
      cwd,
      env,
      now: () => new Date("2026-09-04T21:00:00.000Z"),
    });
    expect(await main(["init", "--plan", planFile()], second)).toBe(1);
    expect(second.err.join("")).toContain("tower close");
  });

  test("--force overrides the open-run refusal", async () => {
    const cwd = gitRepo();
    const env = { XDG_STATE_HOME: mkdtempSync(join(tmpdir(), "s-")) };
    const first = fakeIo({ cwd, env });
    await main(["init", "--plan", planFile()], first);
    const forced = fakeIo({
      cwd,
      env,
      now: () => new Date("2026-09-04T22:00:00.000Z"),
    });
    expect(await main(["init", "--plan", planFile(), "--force"], forced)).toBe(
      0,
    );
  });

  test("from a TSV on stdin, with repo and branch from git", async () => {
    const cwd = gitRepo();
    writeFileSync(join(cwd, "a"), "a");
    execFileSync(
      "git",
      [
        "-c",
        "user.email=someone@example.com",
        "-c",
        "user.name=rex",
        "add",
        "a",
      ],
      { cwd },
    );
    execFileSync(
      "git",
      [
        "-c",
        "user.email=someone@example.com",
        "-c",
        "user.name=rex",
        "commit",
        "-m",
        "one",
      ],
      { cwd, stdio: "pipe" },
    );
    const io = fakeIo({
      cwd,
      env: { XDG_STATE_HOME: mkdtempSync(join(tmpdir(), "s-")) },
      stdinText: () => "1\tA\n2\tB\n",
    });
    expect(await main(["init"], io)).toBe(0);
    const runDir = /run dir: (.+)/.exec(io.out.join(""))?.[1]?.trim() as string;
    expect(readRun(runDir).branch).toBe("main");
    expect(readRun(runDir).tasks).toHaveLength(2);
  });

  test("--title names the run when the source has no title, e.g. TSV or stdin", async () => {
    const cwd = gitRepo();
    writeFileSync(join(cwd, "a"), "a");
    execFileSync(
      "git",
      [
        "-c",
        "user.email=someone@example.com",
        "-c",
        "user.name=rex",
        "add",
        "a",
      ],
      { cwd },
    );
    execFileSync(
      "git",
      [
        "-c",
        "user.email=someone@example.com",
        "-c",
        "user.name=rex",
        "commit",
        "-m",
        "one",
      ],
      { cwd, stdio: "pipe" },
    );
    const io = fakeIo({
      cwd,
      env: { XDG_STATE_HOME: mkdtempSync(join(tmpdir(), "s-")) },
      stdinText: () => "1\tA\n2\tB\n",
    });
    expect(await main(["init", "--title", "Widgets Rollout"], io)).toBe(0);
    const runDir = /run dir: (.+)/.exec(io.out.join(""))?.[1]?.trim() as string;
    expect(readRun(runDir).plan).toBe("Widgets Rollout");
  });

  test("--title overrides a plan's own title too", async () => {
    const io = fakeIo({
      cwd: gitRepo(),
      env: { XDG_STATE_HOME: mkdtempSync(join(tmpdir(), "s-")) },
    });
    await main(["init", "--plan", planFile(), "--title", "Custom Title"], io);
    const runDir = /run dir: (.+)/.exec(io.out.join(""))?.[1]?.trim() as string;
    expect(readRun(runDir).plan).toBe("Custom Title");
  });

  test("with no source, creates an empty run: 0 tasks, title untitled, planPath null", async () => {
    const io = fakeIo({ cwd: gitRepo() });
    expect(await main(["init"], io)).toBe(0);
    const out = io.out.join("");
    expect(out).toContain("0 tasks");
    const runDir = /run dir: (.+)/.exec(out)?.[1]?.trim() as string;
    const run = readRun(runDir);
    expect(run.tasks).toEqual([]);
    expect(run.plan).toBe("untitled");
    expect(run.planPath).toBeNull();
  });

  test("with no source and a non-TTY stdin that reads empty (the real caller in any non-interactive harness), still creates an empty run", async () => {
    const io = fakeIo({ cwd: gitRepo(), stdinText: () => "" });
    expect(await main(["init"], io)).toBe(0);
    expect(io.out.join("")).toContain("0 tasks");
  });

  test("with no source, --lane is refused because there is nothing to assign", async () => {
    const io = fakeIo({ cwd: gitRepo() });
    expect(await main(["init", "--lane", "A=1"], io)).toBe(1);
    expect(io.err.join("")).toContain("no tasks to assign");
    expect(io.err.join("")).toContain("tower add");
  });

  test("a TSV source outside a git checkout gets a message that doesn't blame a nonexistent plan", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tower-nogit-"));
    const io = fakeIo({ cwd: dir, stdinText: () => "1\tA\n" });
    expect(await main(["init"], io)).toBe(1);
    expect(io.err.join("")).not.toContain("plan");
    expect(io.err.join("")).toContain("repo");
  });

  test("a missing plan file is named", async () => {
    const io = fakeIo({ cwd: gitRepo() });
    expect(await main(["init", "--plan", "/nope/plan.md"], io)).toBe(1);
    expect(io.err.join("")).toContain("/nope/plan.md");
  });

  test("a missing --tasks file is named, not a raw crash", async () => {
    const io = fakeIo({ cwd: gitRepo() });
    expect(await main(["init", "--tasks", "/nope/tasks.tsv"], io)).toBe(1);
    expect(io.err.join("")).toContain("/nope/tasks.tsv");
  });

  test("a lane naming a non-task fails before anything is written", async () => {
    const cwd = gitRepo();
    const state = mkdtempSync(join(tmpdir(), "s-"));
    const io = fakeIo({ cwd, env: { XDG_STATE_HOME: state } });
    expect(
      await main(["init", "--plan", planFile(), "--lane", "A=auth1"], io),
    ).toBe(1);
    expect(io.err.join("")).toContain("auth-1");
    const { existsSync } = await import("node:fs");
    expect(existsSync(join(state, "tower"))).toBe(false);
  });

  test("an unwritable run dir is reported with the path", async () => {
    const io = fakeIo({ cwd: gitRepo() });
    expect(
      await main(["init", "--plan", planFile(), "--run", "/proc/nope/run"], io),
    ).toBe(1);
    expect(io.err.join("")).toContain("/proc/nope/run");
  });

  test("a run is still created and reported even when the pointer cannot be written", async () => {
    const { chmodSync } = await import("node:fs");
    const cwd = gitRepo();
    const state = mkdtempSync(join(tmpdir(), "s-"));
    const io = fakeIo({ cwd, env: { XDG_STATE_HOME: state } });
    chmodSync(join(cwd, ".git"), 0o555);
    try {
      expect(await main(["init", "--plan", planFile()], io)).toBe(0);
      expect(io.out.join("")).toContain("run dir:");
    } finally {
      chmodSync(join(cwd, ".git"), 0o755);
    }
  });
});

describe("tower assign", () => {
  test("appends an assign event and moves a task between lanes", async () => {
    const { runDir, io } = seededRun({ A: ["1", "2"] });
    expect(await main(["assign", "B", "2,auth-1"], io)).toBe(0);
    const last = readEvents(join(runDir, "events.ndjson"), 0).lines.at(
      -1,
    )?.event;
    expect(last).toMatchObject({
      kind: "assign",
      lane: "B",
      tasks: ["2", "auth-1"],
    });
  });
  test("rejects an unknown id with a suggestion", async () => {
    const { io } = seededRun();
    expect(await main(["assign", "B", "auth1"], io)).toBe(1);
    expect(io.err.join("")).toContain("auth-1");
  });

  test("can assign a task that was added after init", async () => {
    const { runDir, io } = seededRun();
    expect(await main(["add", "Late task"], io)).toBe(0);
    expect(await main(["assign", "B", "auth-1,3"], io)).toBe(0);
    const last = readEvents(join(runDir, "events.ndjson"), 0).lines.at(
      -1,
    )?.event;
    expect(last).toMatchObject({
      kind: "assign",
      lane: "B",
      tasks: ["auth-1", "3"],
    });
  });
});

describe("tower close", () => {
  test("appends a close event and clears the pointer", async () => {
    const cwd = gitRepo();
    const env = { XDG_STATE_HOME: mkdtempSync(join(tmpdir(), "s-")) };
    const io = fakeIo({ cwd, env });
    await main(["init", "--plan", planFile()], io);
    expect(await main(["close", "shipped"], io)).toBe(0);
    expect(readPointer(join(cwd, ".git"))).toBeUndefined();
    const runDir = /run dir: (.+)/.exec(io.out.join(""))?.[1]?.trim() as string;
    expect(
      readEvents(join(runDir, "events.ndjson"), 0).lines.at(-1)?.event,
    ).toMatchObject({ kind: "close", text: "shipped" });
  });
  test("closing twice is refused", async () => {
    const { io } = seededRun();
    expect(await main(["close"], io)).toBe(0);
    expect(await main(["close"], io)).toBe(1);
    expect(io.err.join("")).toContain("already closed");
  });
});
