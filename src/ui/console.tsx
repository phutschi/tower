import type { Io } from "../io.ts";

export async function consoleCommand(_argv: string[], io: Io): Promise<number> {
  io.stderr("tower: the console arrives in a later task\n");
  return 1;
}
