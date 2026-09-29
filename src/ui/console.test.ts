import { describe, expect, test } from "bun:test";

import { fakeIo } from "../testing.ts";
import { usesColour } from "./console.tsx";

describe("usesColour", () => {
  test.each([
    ["NO_COLOR unset", {}, true],
    ["NO_COLOR=1", { NO_COLOR: "1" }, false],
    ["NO_COLOR=0 (any non-empty value)", { NO_COLOR: "0" }, false],
    ["NO_COLOR empty", { NO_COLOR: "" }, true],
  ])("%s", (_, env, expected) => {
    expect(usesColour(fakeIo({ env }))).toBe(expected);
  });
});
