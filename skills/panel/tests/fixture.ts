/**
 * The Panel's test fixture: a temp dir, the stub gh first in line with each
 * repo's open issues as a file it reads and edits, and a real hub on it.
 * `useFixture()` sets it up and tears it down around each test of a file.
 */
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, expect } from "bun:test";

import { startHub, type Hub, type HubOptions } from "../hub/hub.ts";

export const GH = join(import.meta.dir, "stub/gh");

let root = "";
let hub: Hub | undefined;
let hubOpts: HubOptions | undefined;

export interface Issue {
  number: number;
  title: string;
  labels: { name: string }[];
}
export const issue = (number: number, ...labels: string[]): Issue => ({
  number,
  title: `Issue ${number}`,
  labels: labels.map((name) => ({ name })),
});

export const dir = () => root;
export const hubUrl = () => hub!.url;

const fixture = (repo: string) => join(root, `${repo.replace("/", "_")}.json`);
export const setIssues = (repo: string, issues: Issue[]) =>
  writeFileSync(fixture(repo), JSON.stringify(issues));
export const ghIssues = (repo: string) =>
  JSON.parse(readFileSync(fixture(repo), "utf8")) as Issue[];
export const ghLog = () =>
  existsSync(join(root, "gh.log"))
    ? readFileSync(join(root, "gh.log"), "utf8").split("\n").filter(Boolean)
    : [];
/** How many polls every one of `repos` has had: the fewest any one had. */
const lists = (repos: string[]) =>
  Math.min(
    ...repos.map(
      (r) =>
        ghLog().filter((l) => l.startsWith(`gh issue list --repo ${r} `))
          .length,
    ),
  );

/** Waits for the hub to finish `n` more polls of every listed repo. */
export async function polls(n: number) {
  const repos = await api<string[]>("/api/repos");
  if (!repos.length) return;
  const target = lists(repos) + n;
  for (let i = 0; i < 200 && lists(repos) < target; i++) await Bun.sleep(10);
  // One more poll after the target, so the target's poll has been applied.
  const applied = lists(repos) + 1;
  for (let i = 0; i < 200 && lists(repos) < applied; i++) await Bun.sleep(10);
}

/** Waits until `check` holds, for up to `ms`. */
export async function until(check: () => Promise<boolean>, ms = 5000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (await check()) return;
    await Bun.sleep(20);
  }
  throw new Error("timed out waiting");
}

export async function api<T>(path: string): Promise<T> {
  const res = await fetch(`${hubUrl()}${path}`);
  expect(res.ok).toBe(true);
  return (await res.json()) as T;
}
const send = (method: string) => (path: string, body: unknown) =>
  fetch(`${hubUrl()}${path}`, {
    method,
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
export const post = send("POST");
export const put = send("PUT");

/** Starts the hub with `repos` listed, and waits for its first poll. */
export async function start(
  repos: string[] = ["acme/widgets"],
  opts: Partial<HubOptions> = {},
) {
  hubOpts = {
    dbPath: join(root, "hub.db"),
    host: "127.0.0.1",
    port: 0,
    pollMs: 20,
    ghBin: GH,
    // Never the real usage report: it starts a Claude CLI with the user's login.
    readUsage: async () => null,
    ...opts,
  };
  hub = await startHub(hubOpts);
  for (const repo of repos) await post("/api/repos", { repo });
  await polls(1);
}

/** Stops the hub; `restart()` brings it back on the same port and database. */
export async function stopHub() {
  await hub?.stop();
}
export async function restart() {
  const port = Number(new URL(hubUrl()).port);
  hub = await startHub({ ...hubOpts!, port });
}

const PATH = process.env.PATH;

export function useFixture() {
  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), "panel-"));
    // The hub runs in this process: its plannotator and claude are the stubs,
    // never the user's own Inbox or login.
    process.env.PATH = `${join(import.meta.dir, "stub")}:${PATH}`;
    process.env.PLANNOTATOR_STUB_LOG = join(root, "plannotator.log");
    process.env.GH_STUB_DIR = root;
    process.env.GH_STUB_LOG = join(root, "gh.log");
    delete process.env.GH_STUB_FAIL;
  });
  afterEach(async () => {
    await hub?.stop();
    hub = undefined;
    rmSync(root, { recursive: true, force: true });
    process.env.PATH = PATH;
    delete process.env.PLANNOTATOR_STUB_LOG;
  });
}
