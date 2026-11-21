import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "bun:test";

const CLI = join(import.meta.dir, "cli.ts");

test("`cli.ts hub` starts a hub and prints where it listens", async () => {
  const dir = mkdtempSync(join(tmpdir(), "panel-cli-"));
  const proc = Bun.spawn(
    ["bun", CLI, "hub", "--db", join(dir, "hub.db"), "--port", "0"],
    { stdout: "pipe", stderr: "inherit" },
  );
  try {
    const reader = proc.stdout.getReader();
    const { value } = await reader.read();
    const url = new TextDecoder().decode(value).match(/http:\/\/\S+/)?.[0];
    expect(url).toStartWith("http://127.0.0.1:");
    expect(await (await fetch(`${url}/api/repos`)).json()).toEqual([]);
  } finally {
    proc.kill();
    await proc.exited;
    rmSync(dir, { recursive: true, force: true });
  }
});

test("`cli.ts` with an unknown command prints its usage and fails", async () => {
  const proc = Bun.spawn(["bun", CLI, "nope"], { stderr: "pipe" });
  expect(await proc.exited).toBe(2);
  expect(await new Response(proc.stderr).text()).toContain("usage:");
});
