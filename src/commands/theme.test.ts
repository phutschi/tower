import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";

import { main } from "../main.ts";
import { AIRPORT } from "../theme.ts";
import { fakeIo } from "../testing.ts";

const io = () =>
  fakeIo({
    env: { XDG_CONFIG_HOME: mkdtempSync(join(tmpdir(), "tower-config-")) },
  });

describe("tower theme", () => {
  test("rules prints the contract", async () => {
    const i = io();
    expect(await main(["theme", "rules"], i)).toBe(0);
    expect(i.out.join("")).toContain("A theme renames");
  });

  test("new scaffolds; check lists what is missing; once filled, check passes and preview renders", async () => {
    const i = io();
    expect(await main(["theme", "new", "police"], i)).toBe(0);
    const path = /(\S+police\.json)/.exec(i.out.join(""))?.[1] as string;
    const check = fakeIo({ env: i.env });
    expect(await main(["theme", "check", "police"], check)).toBe(1);
    expect(check.err.join("")).toContain("states.pending");
    // `pending` itself is exercised above via the raw-scaffold assertion;
    // `blocked` is used here because — unlike `pending` — its label is
    // always printed on a blocked task's own row (see rows.ts's taskRow),
    // so it is provable through the rendered preview, which is the point
    // of this half of the test.
    writeFileSync(
      path,
      JSON.stringify({
        ...structuredClone(AIRPORT),
        name: "police",
        states: { ...AIRPORT.states, blocked: "at the station" },
      }),
    );
    const ok = fakeIo({ env: i.env });
    expect(await main(["theme", "check", "police"], ok)).toBe(0);
    expect(ok.out.join("")).toContain("police: ok");
    const pv = fakeIo({ env: i.env });
    expect(await main(["theme", "preview", "police"], pv)).toBe(0);
    expect(pv.out.join("")).toContain("at the station");
  });

  test("a valid theme with an unusual verb still passes: the demo transcript renders every verb", async () => {
    const i = io();
    await main(["theme", "new", "odd"], i);
    const path = /(\S+odd\.json)/.exec(i.out.join(""))?.[1] as string;
    writeFileSync(
      path,
      JSON.stringify({
        ...structuredClone(AIRPORT),
        name: "odd",
        verbs: { started: "wheels up", blocked: "squawk 7700" },
      }),
    );
    const check = fakeIo({ env: i.env });
    expect(await main(["theme", "check", "odd"], check)).toBe(0);
    expect(check.out.join("")).toContain("odd: ok");
  });

  test("preview of the built-in works without a themes dir", async () => {
    const i = fakeIo();
    expect(await main(["theme", "preview", "airport"], i)).toBe(0);
    expect(i.out.join("")).toContain("NORDO");
  });

  test("an unknown subcommand names the four", async () => {
    const i = io();
    expect(await main(["theme", "paint"], i)).toBe(1);
    expect(i.err.join("")).toContain("rules");
  });
});
