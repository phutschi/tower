import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";

import {
  AIRPORT,
  checkTheme,
  labelFor,
  loadTheme,
  PLAIN,
  scaffoldTheme,
  THEME_RULES,
} from "./theme.ts";

const configHome = () => {
  const dir = mkdtempSync(join(tmpdir(), "tower-config-"));
  mkdirSync(join(dir, "tower", "themes"), { recursive: true });
  return dir;
};

describe("built-ins", () => {
  test("airport passes its own check", () => {
    expect(checkTheme(AIRPORT)).toEqual([]);
  });
  test("plain is literal: every state label is the state name", () => {
    expect(PLAIN.states.in_progress).toBe("in_progress");
    expect(PLAIN.states.stale).toBe("stale");
    expect(checkTheme(PLAIN)).toEqual([]);
  });
});

describe("checkTheme", () => {
  test("names every missing key", () => {
    const problems = checkTheme({ name: "x" });
    expect(problems.some((p) => p.includes("states.pending"))).toBe(true);
    expect(problems.some((p) => p.includes("board"))).toBe(true);
  });
  test("enforces the length limits", () => {
    const long = structuredClone(AIRPORT);
    long.states.pending = "waiting at the gate for ages";
    long.board = "THE DEPARTURES BOARD";
    long.operator = "AIRTRAFFIC";
    const problems = checkTheme(long);
    expect(
      problems.some((p) => p.includes("states.pending") && p.includes("14")),
    ).toBe(true);
    expect(problems.some((p) => p.includes("board") && p.includes("12"))).toBe(
      true,
    );
    expect(
      problems.some((p) => p.includes("operator") && p.includes("8")),
    ).toBe(true);
  });
  test("rejects two states sharing a label", () => {
    const dup = structuredClone(AIRPORT);
    dup.states.reviewing = dup.states.in_progress;
    expect(checkTheme(dup).some((p) => p.includes("same label"))).toBe(true);
  });
  test("rejects colour keys — colour belongs to status", () => {
    const coloured = {
      ...structuredClone(AIRPORT),
      colors: { blocked: "red" },
    };
    expect(checkTheme(coloured).some((p) => p.includes("colour"))).toBe(true);
  });
  test("enforces phase and verb requiredness and length limits", () => {
    const missing = structuredClone(AIRPORT) as unknown as Record<
      string,
      unknown
    >;
    delete missing.phases;
    delete missing.verbs;
    const problems = checkTheme(missing);
    expect(problems.some((p) => p.startsWith("phases:"))).toBe(true);
    expect(problems.some((p) => p.startsWith("verbs:"))).toBe(true);

    const long = structuredClone(AIRPORT);
    long.phases.fixing = "go around and try it again";
    const overflow = checkTheme(long);
    expect(
      overflow.some((p) => p.includes("phases.fixing") && p.includes("14")),
    ).toBe(true);
  });
  test("does not crash on non-object input", () => {
    expect(checkTheme(null)).toEqual(["a theme is a JSON object"]);
    expect(checkTheme("nope")).toEqual(["a theme is a JSON object"]);
    expect(checkTheme([1, 2])).toEqual(["a theme is a JSON object"]);
  });
});

describe("labelFor", () => {
  test("a known phase gets its label; an unknown phase falls back to the state label plus the phase", () => {
    expect(labelFor(AIRPORT, "reviewing", "quality-review")).toBe("on final");
    expect(labelFor(AIRPORT, "in_progress", "smoke-test")).toBe(
      "airborne · smoke-test",
    );
    expect(labelFor(AIRPORT, "in_progress", "")).toBe("airborne");
    expect(labelFor(PLAIN, "in_progress", "implementing")).toBe(
      "in_progress · implementing",
    );
  });
});

describe("loadTheme", () => {
  test("airport and plain are built in", () => {
    expect(loadTheme("airport", {}).name).toBe("airport");
    expect(loadTheme("plain", {}).name).toBe("plain");
  });
  test("a user theme is read from the XDG themes dir and checked", () => {
    const home = configHome();
    const ok = { ...structuredClone(AIRPORT), name: "police" };
    writeFileSync(
      join(home, "tower", "themes", "police.json"),
      JSON.stringify(ok),
    );
    expect(loadTheme("police", { XDG_CONFIG_HOME: home }).name).toBe("police");
    writeFileSync(
      join(home, "tower", "themes", "bad.json"),
      JSON.stringify({ name: "bad" }),
    );
    expect(() => loadTheme("bad", { XDG_CONFIG_HOME: home })).toThrow(
      /states\.pending/,
    );
  });
  test("an unknown theme lists what exists", () => {
    const home = configHome();
    writeFileSync(
      join(home, "tower", "themes", "police.json"),
      JSON.stringify(AIRPORT),
    );
    expect(() => loadTheme("nope", { XDG_CONFIG_HOME: home })).toThrow(
      /airport[\s\S]*police/,
    );
  });
  test("the built-in listing includes plain as well as airport", () => {
    const home = configHome();
    expect(() => loadTheme("nope", { XDG_CONFIG_HOME: home })).toThrow(
      /airport.*plain|plain.*airport/,
    );
  });
  test("rejects a name that would escape the themes directory", () => {
    const home = configHome();
    expect(() =>
      loadTheme("../../etc/passwd", { XDG_CONFIG_HOME: home }),
    ).toThrow(/name/);
  });
  test("a malformed JSON file names its own path", () => {
    const home = configHome();
    writeFileSync(join(home, "tower", "themes", "broken.json"), "{ not json");
    expect(() => loadTheme("broken", { XDG_CONFIG_HOME: home })).toThrow(
      /broken\.json.*not valid JSON/,
    );
  });
});

describe("scaffoldTheme", () => {
  test("writes every required key, empty, so check fails until the author fills it", () => {
    const home = configHome();
    const path = scaffoldTheme("fire", { XDG_CONFIG_HOME: home });
    const doc = JSON.parse(readFileSync(path, "utf8"));
    expect(doc.name).toBe("fire");
    expect(doc.states.pending).toBe("");
    expect(checkTheme(doc).length).toBeGreaterThan(5);
  });
  test("refuses to overwrite", () => {
    const home = configHome();
    scaffoldTheme("fire", { XDG_CONFIG_HOME: home });
    expect(() => scaffoldTheme("fire", { XDG_CONFIG_HOME: home })).toThrow(
      /exists/,
    );
  });
  test("rejects a name that would escape the themes directory", () => {
    const home = configHome();
    expect(() =>
      scaffoldTheme("../../etc/passwd", { XDG_CONFIG_HOME: home }),
    ).toThrow(/name/);
  });
});

test("the rules mention the two hard slots", () => {
  expect(THEME_RULES).toContain("bounced");
  expect(THEME_RULES).toContain("heard nothing");
});
