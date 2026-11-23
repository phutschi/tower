import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
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
      // The usage report would start a Claude session under the user's login.
      "--usage-seconds",
      "0",
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
    const server = await fetch(`${url}/api/stations/server`, {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: "{}",
    });
    expect(await server.json()).toEqual({
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

/** Runs `cli.ts` with the Panel's stubs first on PATH, in a temp dir. */
async function cli(args: string[], env: Record<string, string> = {}) {
  const proc = Bun.spawn(["bun", CLI, ...args], {
    env: {
      ...process.env,
      PATH: `${join(import.meta.dir, "tests/stub")}:${process.env.PATH}`,
      XDG_STATE_HOME: join(tmpdir(), "panel-cli-state"),
      ...env,
    },
    stdout: "pipe",
    stderr: "pipe",
  });
  const [out, err, code] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  return { out, err, code };
}

test("install hub writes and loads a launchd agent that starts the hub on the Tailscale address", async () => {
  const dir = mkdtempSync(join(tmpdir(), "panel-cli-"));
  const log = join(dir, "launchctl.log");
  try {
    const r = await cli(
      ["install", "hub", "--dir", dir, "--server-station", "server"],
      {
        LAUNCHCTL_STUB_LOG: log,
        LAUNCHCTL_STUB_NOT_LOADED: "1",
      },
    );
    expect(r.code).toBe(0);
    const path = join(dir, "dev.tower.panel.hub.plist");
    const plist = readFileSync(path, "utf8");
    expect(plist).toContain(
      "<string>hub</string><string>--host</string><string>100.64.0.7</string>",
    );
    expect(plist).toContain(
      "<string>--server-station</string><string>server</string>",
    );
    expect(readFileSync(log, "utf8")).toContain(
      `launchctl bootstrap gui/${process.getuid!()} ${path}`,
    );
    expect(r.out).toContain("http://100.64.0.7:7420");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("install hub off the tailnet refuses, and writes nothing", async () => {
  const dir = mkdtempSync(join(tmpdir(), "panel-cli-"));
  try {
    const r = await cli(["install", "hub", "--dir", dir], {
      TAILSCALE_STUB_IP: "none",
    });
    expect(r.code).toBe(1);
    expect(r.err).toContain("Tailscale");
    expect(existsSync(join(dir, "dev.tower.panel.hub.plist"))).toBe(false);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("install station writes a plist with the hub's URL and the station's name", async () => {
  const dir = mkdtempSync(join(tmpdir(), "panel-cli-"));
  try {
    const r = await cli(
      [
        "install",
        "station",
        "--dir",
        dir,
        "--hub",
        "http://100.64.0.7:7420",
        "--name",
        "laptop",
      ],
      { LAUNCHCTL_STUB_LOG: join(dir, "launchctl.log") },
    );
    expect(r.code).toBe(0);
    const plist = readFileSync(
      join(dir, "dev.tower.panel.station.plist"),
      "utf8",
    );
    expect(plist).toContain(
      "<string>station</string><string>--hub</string><string>http://100.64.0.7:7420</string><string>--name</string><string>laptop</string>",
    );
    expect((await cli(["install", "station", "--dir", dir])).code).toBe(2);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("uninstall unloads the agent and removes its plist", async () => {
  const dir = mkdtempSync(join(tmpdir(), "panel-cli-"));
  const log = join(dir, "launchctl.log");
  try {
    await cli(
      ["install", "station", "--dir", dir, "--hub", "http://100.64.0.7:7420"],
      {
        LAUNCHCTL_STUB_LOG: log,
      },
    );
    const r = await cli(["uninstall", "station", "--dir", dir], {
      LAUNCHCTL_STUB_LOG: log,
    });
    expect(r.code).toBe(0);
    expect(existsSync(join(dir, "dev.tower.panel.station.plist"))).toBe(false);
    expect(readFileSync(log, "utf8")).toContain(
      `launchctl bootout gui/${process.getuid!()}/dev.tower.panel.station`,
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("an install launchd refuses to load leaves no plist behind", async () => {
  const dir = mkdtempSync(join(tmpdir(), "panel-cli-"));
  try {
    const r = await cli(
      ["install", "station", "--dir", dir, "--hub", "http://100.64.0.7:7420"],
      { LAUNCHCTL_STUB_FAIL: "bootstrap" },
    );
    expect(r.code).toBe(1);
    expect(r.err).toContain("launchctl could not load");
    expect(existsSync(join(dir, "dev.tower.panel.station.plist"))).toBe(false);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("an agent launchd cannot unload stays installed, and uninstall says so", async () => {
  const dir = mkdtempSync(join(tmpdir(), "panel-cli-"));
  const hub = ["--hub", "http://100.64.0.7:7420"];
  const plist = join(dir, "dev.tower.panel.station.plist");
  try {
    await cli(["install", "station", "--dir", dir, ...hub, "--name", "laptop"]);
    const env = { LAUNCHCTL_STUB_FAIL: "bootout" };
    const again = await cli(
      ["install", "station", "--dir", dir, ...hub, "--name", "desk"],
      env,
    );
    expect(again.code).toBe(1);
    expect(again.err).toContain("launchctl could not unload");
    // The running agent's plist is left as it is.
    expect(readFileSync(plist, "utf8")).toContain("<string>laptop</string>");
    const r = await cli(["uninstall", "station", "--dir", dir], env);
    expect(r.code).toBe(1);
    expect(r.err).toContain("launchctl could not unload");
    expect(existsSync(plist)).toBe(true);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
