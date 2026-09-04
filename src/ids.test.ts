import { describe, expect, test } from "bun:test";

import { expandIds, isValidId, nearestId, sortByPlan } from "./ids.ts";

describe("isValidId", () => {
  test.each(["14", "3a", "auth-1", "T-12", "a.b_c"])(
    "%s is a valid id",
    (id) => {
      expect(isValidId(id)).toBe(true);
    },
  );
  test.each(["", "a b", "-1", ".x", "t/1"])("%j is not a valid id", (id) => {
    expect(isValidId(id)).toBe(false);
  });
});

describe("expandIds", () => {
  test("splits on commas and expands integer ranges", () => {
    expect(expandIds("5,7-9,auth-1")).toEqual(["5", "7", "8", "9", "auth-1"]);
  });
  test("a letter-to-letter range is rejected as not integer to integer", () => {
    expect(() => expandIds("a-c")).toThrow(/integer to integer/);
  });
  test("a descending range is rejected as running backwards", () => {
    expect(() => expandIds("9-7")).toThrow(/backwards/);
  });
  test("an id like auth-1 is not a range", () => {
    expect(expandIds("auth-1")).toEqual(["auth-1"]);
  });
  test("a zero-padded range preserves width rather than silently dropping it", () => {
    expect(expandIds("07-09")).toEqual(["07", "08", "09"]);
  });
  test("a range crossing a digit boundary is not zero-padded to the wider bound", () => {
    expect(expandIds("2-11")).toEqual([
      "2",
      "3",
      "4",
      "5",
      "6",
      "7",
      "8",
      "9",
      "10",
      "11",
    ]);
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
  test("an empty id never matches", () => {
    expect(nearestId("", ["14", "15"])).toBeUndefined();
  });
  test("an empty candidate list never matches", () => {
    expect(nearestId("14", [])).toBeUndefined();
  });
});
