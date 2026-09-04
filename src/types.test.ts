import { describe, expect, test } from "bun:test";

import { isStatus, STATUSES } from "./types.ts";

describe("statuses", () => {
  test("the five the protocol allows, in the documented order", () => {
    expect([...STATUSES]).toEqual([
      "pending",
      "in_progress",
      "reviewing",
      "done",
      "blocked",
    ]);
  });

  test("a hyphenated spelling is not a status", () => {
    expect(isStatus("in-progress")).toBe(false);
    expect(isStatus("in_progress")).toBe(true);
  });
});
