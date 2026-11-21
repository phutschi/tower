/**
 * The executor seam: a checkout per job, kept for a while after release when
 * asked, then pruned. Real git against a temp bare repo.
 */
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, expect, test } from "bun:test";

import type { Job } from "../types.ts";
import { dir, git, gitRemotes, remote, useFixture } from "../tests/fixture.ts";
import { CheckoutExecutor } from "./executor.ts";

useFixture();
afterEach(() => {
  for (const key of Object.keys(gitRemotes())) delete process.env[key];
});

const job = (id: string): Job => ({
  id,
  kind: "run",
  repo: "acme/widgets",
  issues: [12],
  state: "claimed",
  station: "server",
  leaseUntil: null,
  reason: null,
  sessionId: null,
  createdAt: "2026-11-21T00:00:00.000Z",
  durationMs: null,
  tokens: null,
});

test("a released checkout is kept with its branch for the hours asked, then pruned", async () => {
  remote();
  Object.assign(process.env, gitRemotes());
  let now = new Date("2026-11-21T10:00:00Z");
  const executor = new CheckoutExecutor(join(dir(), "station"), () => now);
  const kept = await executor.prepare(job("aaaaaaaa-1"));
  const gone = await executor.prepare(job("bbbbbbbb-2"));
  await executor.release(kept, 24);
  await executor.release(gone, 0);
  expect(existsSync(gone.path)).toBe(false);
  expect(git(kept.path, "branch", "--show-current").trim()).toBe(kept.branch);
  now = new Date("2026-11-22T09:59:00Z");
  await executor.prune();
  expect(existsSync(kept.path)).toBe(true);
  now = new Date("2026-11-22T10:01:00Z");
  await executor.prune();
  expect(existsSync(kept.path)).toBe(false);
});

test("a kept checkout is pruned by a new executor too, as after a station restart", async () => {
  remote();
  Object.assign(process.env, gitRemotes());
  const workdir = join(dir(), "station");
  const first = new CheckoutExecutor(
    workdir,
    () => new Date("2026-11-21T10:00:00Z"),
  );
  const kept = await first.prepare(job("cccccccc-3"));
  await first.release(kept, 24);
  const second = new CheckoutExecutor(
    workdir,
    () => new Date("2026-11-23T00:00:00Z"),
  );
  await second.prune();
  expect(existsSync(kept.path)).toBe(false);
});

test("a keep marker that cannot be read counts as expired and stops no other pruning", async () => {
  const workdir = join(dir(), "station");
  mkdirSync(join(workdir, "keep"), { recursive: true });
  mkdirSync(join(workdir, "jobs/dddddddd-4"), { recursive: true });
  writeFileSync(join(workdir, "keep/dddddddd-4.json"), "{half");
  await new CheckoutExecutor(workdir).prune();
  expect(existsSync(join(workdir, "jobs/dddddddd-4"))).toBe(false);
  expect(existsSync(join(workdir, "keep/dddddddd-4.json"))).toBe(false);
});
