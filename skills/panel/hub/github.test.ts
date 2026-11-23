import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "bun:test";

import { GitHub } from "./github.ts";

test("a gh that hangs is killed after the timeout, so it holds up nothing", async () => {
  const dir = mkdtempSync(join(tmpdir(), "panel-gh-"));
  const gh = join(dir, "gh");
  writeFileSync(gh, "#!/bin/sh\nsleep 30\n");
  chmodSync(gh, 0o755);
  try {
    const started = Date.now();
    await expect(
      new GitHub(gh, 200).openIssues("acme/widgets"),
    ).rejects.toThrow();
    expect(Date.now() - started).toBeLessThan(5000);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
