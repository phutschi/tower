/**
 * The orchestrate kit's stub herdr, for tests outside the kit that drive its
 * scripts (the Panel's run job): only the kit names herdr (AGENTS.md).
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

/** The environment that runs the kit's scripts against the stub, logging into `dir`. */
export function kitStubEnv(
  dir: string,
  fail?: "workspace" | "close",
): Record<string, string> {
  mkdirSync(join(dir, "kit-states"), { recursive: true });
  return {
    DRY_RUN: "1",
    HERDR_STUB_LOG: join(dir, "kit.log"),
    HERDR_STUB_COUNTER: join(dir, "kit.counter"),
    HERDR_STUB_STATES_DIR: join(dir, "kit-states"),
    ...(fail
      ? { HERDR_STUB_WORKSPACE_FAIL: fail === "workspace" ? "1" : "close" }
      : {}),
  };
}

/** What the kit asked the stub, one call a line, without the command's name. */
export const kitLog = (dir: string) =>
  existsSync(join(dir, "kit.log"))
    ? readFileSync(join(dir, "kit.log"), "utf8").replace(/^herdr /gm, "")
    : "";

/** Makes the stub answer that `agent` exited. */
export const agentExits = (dir: string, agent: string) =>
  writeFileSync(join(dir, "kit-states", agent), "gone\n");
