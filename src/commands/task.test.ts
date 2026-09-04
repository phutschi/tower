import { join } from "node:path";
import { describe, expect, test } from "bun:test";

import { readEvents } from "../events.ts";
import { main } from "../main.ts";
import { seededRun } from "../testing.ts";

const events = (runDir: string) =>
  readEvents(join(runDir, "events.ndjson"), 0).lines.map((l) => l.event);

describe("tower task", () => {
  test("appends a report and echoes it literally", async () => {
    const { runDir, io } = seededRun();
    const code = await main(
      ["task", "1", "in_progress", "implementing", "--model", "sonnet"],
      io,
    );
    expect(code).toBe(0);
    const last = events(runDir).at(-1);
    expect(last).toMatchObject({
      kind: "report",
      task: "1",
      status: "in_progress",
      phase: "implementing",
      model: "sonnet",
      note: "",
    });
    expect(io.out.join("")).toContain("task 1");
    expect(io.out.join("")).toContain("in_progress");
  });

  test("a misspelled status lists the valid ones and appends nothing", async () => {
    const { runDir, io } = seededRun();
    const before = events(runDir).length;
    expect(await main(["task", "1", "in-progress", "--model", "m"], io)).toBe(
      1,
    );
    expect(io.err.join("")).toContain(
      "valid: pending, in_progress, reviewing, done, blocked",
    );
    expect(events(runDir)).toHaveLength(before);
  });

  test("an unquoted note is refused rather than silently truncated to its first word", async () => {
    const { runDir, io } = seededRun();
    const before = events(runDir).length;
    expect(
      await main(["task", "1", "done", "committed", "my", "note", "here"], io),
    ).toBe(1);
    expect(io.err.join("")).toContain("quote");
    expect(events(runDir)).toHaveLength(before);
  });

  test("an unknown id suggests the nearest", async () => {
    const { io } = seededRun();
    expect(await main(["task", "auth1", "done"], io)).toBe(1);
    expect(io.err.join("")).toContain("did you mean auth-1");
  });

  test("in_progress and reviewing require --model; --model none is the escape", async () => {
    const { io } = seededRun();
    expect(await main(["task", "1", "in_progress"], io)).toBe(1);
    expect(io.err.join("")).toContain("--model");
    expect(await main(["task", "1", "reviewing", "spec-review"], io)).toBe(1);
    expect(
      await main(
        ["task", "1", "in_progress", "implementing", "--model", "none"],
        io,
      ),
    ).toBe(0);
  });

  test("done does not require --model", async () => {
    const { runDir, io } = seededRun();
    expect(
      await main(["task", "1", "done", "committed", "feat: shortcuts"], io),
    ).toBe(0);
    const last = events(runDir).at(-1);
    expect(last).toMatchObject({
      status: "done",
      phase: "committed",
      note: "feat: shortcuts",
    });
  });

  test("commit is empty when cwd is not a git repository", async () => {
    const { runDir, io } = seededRun();
    await main(["task", "1", "done"], io);
    expect(events(runDir).at(-1)).toMatchObject({ commit: "" });
  });

  test("records the sha when cwd is a git repository", async () => {
    const { runDir, io } = seededRun();
    const { execFileSync } = await import("node:child_process");
    const git = (...args: string[]) =>
      execFileSync("git", args, {
        cwd: io.cwd,
        stdio: "pipe",
        env: { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null" },
      });
    git("init", "-b", "main");
    git("config", "user.email", "someone@example.com");
    git("config", "user.name", "rex");
    const { writeFileSync } = await import("node:fs");
    writeFileSync(join(io.cwd, "a"), "a");
    git("add", "a");
    git("commit", "-m", "one");
    await main(["task", "1", "done"], io);
    const commit = (events(runDir).at(-1) as { commit?: string } | undefined)
      ?.commit;
    expect(commit).toMatch(/^[0-9a-f]{7,}$/);
  });

  test("blocked via task requires a note", async () => {
    const { io } = seededRun();
    expect(await main(["task", "1", "blocked"], io)).toBe(1);
    expect(io.err.join("")).toContain("note");
  });

  test("a note longer than 500 characters is refused", async () => {
    const { io } = seededRun();
    expect(
      await main(["task", "1", "done", "committed", "x".repeat(501)], io),
    ).toBe(1);
    expect(io.err.join("")).toContain("500");
  });

  test("with no run it exits 2 and prints the init line", async () => {
    const { io } = seededRun();
    io.env = {};
    expect(await main(["task", "1", "done"], io)).toBe(2);
    expect(io.err.join("")).toContain("tower init");
  });
});

describe("tower block", () => {
  test("is blocked with a required note", async () => {
    const { runDir, io } = seededRun();
    expect(await main(["block", "2", "needs the test DB created"], io)).toBe(0);
    expect(events(runDir).at(-1)).toMatchObject({
      kind: "report",
      task: "2",
      status: "blocked",
      note: "needs the test DB created",
    });
    expect(await main(["block", "2"], io)).toBe(1);
  });
});

describe("tower note", () => {
  test("speaks as TOWER by default, as a flight with --task, as a runway with --lane", async () => {
    const { runDir, io } = seededRun();
    expect(await main(["note", "merged lane B at task 2"], io)).toBe(0);
    expect(events(runDir).at(-1)).toMatchObject({
      kind: "note",
      task: null,
      lane: null,
    });
    expect(await main(["note", "--task", "1", "retrying"], io)).toBe(0);
    expect(events(runDir).at(-1)).toMatchObject({
      kind: "note",
      task: "1",
      lane: null,
    });
    expect(await main(["note", "--lane", "B", "merged A"], io)).toBe(0);
    expect(events(runDir).at(-1)).toMatchObject({
      kind: "note",
      task: null,
      lane: "B",
    });
  });

  test("an unassigned lane is refused; --task and --lane together are refused", async () => {
    const { io } = seededRun();
    expect(await main(["note", "--lane", "Q", "hi"], io)).toBe(1);
    expect(io.err.join("")).toContain("lane Q");
    expect(await main(["note", "--lane", "A", "--task", "1", "hi"], io)).toBe(
      1,
    );
  });
});

describe("dispatch", () => {
  test("an unknown command exits 1 and names the commands", async () => {
    const io = seededRun().io;
    expect(await main(["fly"], io)).toBe(1);
    expect(io.err.join("")).toContain("task");
  });
  test("--help prints usage on stdout and exits 0", async () => {
    const io = seededRun().io;
    expect(await main(["--help"], io)).toBe(0);
    expect(io.out.join("")).toContain("tower task");
  });
});
