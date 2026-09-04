/**
 * The shapes tower shares with the outside world. `run.json`, every line of
 * `events.ndjson`, and the folded state that `tower state --json` prints are
 * all built from these. Changing one is a contract change: bump `v`, and edit
 * docs/protocol.md in the same commit.
 */

export const STATUSES = [
  "pending",
  "in_progress",
  "reviewing",
  "done",
  "blocked",
] as const;
export type Status = (typeof STATUSES)[number];

export function isStatus(value: string): value is Status {
  return (STATUSES as readonly string[]).includes(value);
}
