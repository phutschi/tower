/**
 * Where tower keeps things, per the XDG base directory spec. State (runs) and
 * configuration (themes, config.json) are different kinds of thing and live
 * in different places; a well-behaved CLI does not invent a dotdir.
 */
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export type Env = Record<string, string | undefined>;

// The XDG spec requires an empty (or non-absolute) value to be treated as unset.
const xdgValue = (value: string | undefined) =>
  value && value.startsWith("/") ? value : undefined;

const stateHome = (env: Env, home: string) =>
  xdgValue(env.XDG_STATE_HOME) ?? join(home, ".local", "state");
const configHome = (env: Env, home: string) =>
  xdgValue(env.XDG_CONFIG_HOME) ?? join(home, ".config");

export const runsDir = (env: Env = process.env, home = homedir()) =>
  join(stateHome(env, home), "tower", "runs");
export const themesDir = (env: Env = process.env, home = homedir()) =>
  join(configHome(env, home), "tower", "themes");
export const configPath = (env: Env = process.env, home = homedir()) =>
  join(configHome(env, home), "tower", "config.json");

export interface UserConfig {
  defaultTheme?: string;
  stale?: number;
  models?: Record<string, string>;
}

export function readConfig(path: string): {
  config: UserConfig;
  problem?: string;
} {
  let text: string;
  try {
    text = readFileSync(path, "utf8");
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return { config: {} };
    return {
      config: {},
      problem: `${path} could not be read: ${(err as Error).message}`,
    };
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return { config: {}, problem: `${path} is not valid JSON` };
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed))
    return { config: {}, problem: `${path} must contain a JSON object` };
  const raw = parsed as Record<string, unknown>;
  const config: UserConfig = {};
  if (raw.defaultTheme !== undefined) {
    if (typeof raw.defaultTheme !== "string")
      return { config: {}, problem: `${path}: defaultTheme must be a string` };
    config.defaultTheme = raw.defaultTheme;
  }
  if (raw.stale !== undefined) {
    if (typeof raw.stale !== "number" || !(raw.stale > 0))
      return {
        config: {},
        problem: `${path}: stale must be a positive number of minutes`,
      };
    config.stale = raw.stale;
  }
  if (raw.models !== undefined) {
    const m = raw.models;
    if (
      typeof m !== "object" ||
      m === null ||
      Array.isArray(m) ||
      !Object.values(m).every((v) => typeof v === "string")
    )
      return {
        config: {},
        problem: `${path}: models must map role names to model names`,
      };
    config.models = m as Record<string, string>;
  }
  return { config };
}
