/**
 * The world, as one object. Commands never touch `process` directly: they
 * write to `io.stdout`, read `io.env`, and ask `io.now()` for the time. A
 * test hands in a fake; `cli.ts` hands in the real thing.
 */
import { readFileSync } from "node:fs";

export interface Io {
  stdout: (text: string) => void;
  stderr: (text: string) => void;
  env: Record<string, string | undefined>;
  cwd: string;
  now: () => Date;
  /** Whether stdout is a terminal. Decides console vs. snapshot. */
  isTTY: boolean;
  columns: number;
  rows: number;
  /** All of stdin, or undefined when stdin is a terminal (nothing piped). */
  stdinText: () => string | undefined;
}

export class UsageError extends Error {
  constructor(
    message: string,
    public readonly exit: number = 1,
  ) {
    super(message);
  }
}

export function realIo(): Io {
  return {
    stdout: (text) => process.stdout.write(text),
    stderr: (text) => process.stderr.write(text),
    env: process.env,
    cwd: process.cwd(),
    now: () => new Date(),
    isTTY: process.stdout.isTTY === true,
    columns: process.stdout.columns ?? 80,
    rows: process.stdout.rows ?? 24,
    stdinText: () =>
      process.stdin.isTTY ? undefined : readFileSync(0, "utf8"),
  };
}
