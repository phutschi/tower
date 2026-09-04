import { describe, expect, test } from "bun:test";

import { expandIds, isValidId, nearestId, sortByPlan } from "./ids.ts";

describe("isValidId", () => {
  test("accepts digits, letters, dots, dashes, underscores", () => {
    for (const id of ["14", "3a", "auth-1", "T-12", "a.b_c"])
      expect(isValidId(id)).toBe(true);
  });
  test("rejects spaces, a leading punctuation, empty", () => {
    for (const id of ["", "a b", "-1", ".x", "t/1"])
      expect(isValidId(id)).toBe(false);
  });
});

describe("expandIds", () => {
  test("splits on commas and expands integer ranges", () => {
    expect(expandIds("5,7-9,auth-1")).toEqual(["5", "7", "8", "9", "auth-1"]);
  });
  test("a range must be integer to integer, ascending", () => {
    expect(() => expandIds("a-c")).toThrow(/range/);
    expect(() => expandIds("9-7")).toThrow(/range/);
  });
  test("an id like auth-1 is not a range", () => {
    expect(expandIds("auth-1")).toEqual(["auth-1"]);
  });
  test("rejects an invalid token by name", () => {
    expect(() => expandIds("1,a b")).toThrow(/"a b"/);
  });
  test("tolerates spaces after commas and drops duplicates, keeping first position", () => {
    expect(expandIds("1, 2, 1")).toEqual(["1", "2"]);
  });
});

describe("sortByPlan", () => {
  test("orders by the plan, never numerically", () => {
    expect(sortByPlan(["10", "2", "auth-1"], ["auth-1", "10", "2"])).toEqual([
      "auth-1",
      "10",
      "2",
    ]);
  });
});

describe("nearestId", () => {
  test("suggests the closest existing id", () => {
    expect(nearestId("auth1", ["auth-1", "auth-2", "14"])).toBe("auth-1");
    expect(nearestId("41", ["14", "15"])).toBe("14");
  });
  test("returns undefined when nothing is close", () => {
    expect(nearestId("zzzzzz", ["1", "2"])).toBeUndefined();
  });
});
