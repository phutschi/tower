import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "bun:test";
import type { Subprocess } from "bun";

const CLI = join(import.meta.dir, "cli.ts");

async function hub(dir: string): Promise<{ proc: Subprocess; url: string }> {
  const proc = Bun.spawn(
    [
      "bun",
      CLI,
      "hub",
      "--db",
      join(dir, "hub.db"),
      "--port",
      "0",
      "--server-station",
      "server",
    ],
    { stdout: "pipe", stderr: "inherit" },
  );
  const { value } = await proc.stdout.getReader().read();
  const url = new TextDecoder().decode(value).match(/http:\/\/\S+/)?.[0];
  return { proc, url: url ?? "" };
}

test("`cli.ts hub` starts a hub and prints where it listens", async () => {
  const dir = mkdtempSync(join(tmpdir(), "panel-cli-"));
  const { proc, url } = await hub(dir);
  try {
    expect(url).toStartWith("http://127.0.0.1:");
    expect(await (await fetch(`${url}/api/repos`)).json()).toEqual([]);
    expect(await (await fetch(`${url}/api/stations/server`)).json()).toEqual({
      name: "server",
      enabled: true,
      limit: 1,
    });
  } finally {
    proc.kill();
    await proc.exited;
    rmSync(dir, { recursive: true, force: true });
  }
});

test("`cli.ts station` reports to the hub under its name", async () => {
  const dir = mkdtempSync(join(tmpdir(), "panel-cli-"));
  const h = await hub(dir);
  const station = Bun.spawn(
    [
      "bun",
      CLI,
      "station",
      "--hub",
      h.url,
      "--name",
      "laptop",
      "--workdir",
      dir,
    ],
    { stderr: "inherit" },
  );
  try {
    let html = "";
    for (let i = 0; i < 100 && !html.includes('data-station="laptop"'); i++) {
      await Bun.sleep(50);
      html = await (await fetch(`${h.url}/`)).text();
    }
    expect(html).toContain('<li data-station="laptop">');
  } finally {
    for (const p of [station, h.proc]) p.kill();
    await Promise.all([station.exited, h.proc.exited]);
    rmSync(dir, { recursive: true, force: true });
  }
});

test("`cli.ts` with an unknown command prints its usage and fails", async () => {
  const proc = Bun.spawn(["bun", CLI, "nope"], { stderr: "pipe" });
  expect(await proc.exited).toBe(2);
  expect(await new Response(proc.stderr).text()).toContain("usage:");
});
