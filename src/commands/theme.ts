/**
 * The theme loop: rules → new → check → preview. `check` is what lets an agent
 * author a theme unsupervised — it fails with the exact key and limit, and
 * it renders the demo run to prove every state label actually shows.
 */
import { parseArgs } from "node:util";

import type { Io } from "../io.ts";
import type { Theme } from "../theme.ts";
import { UsageError } from "../io.ts";
import { loadTheme, scaffoldTheme, THEME_RULES } from "../theme.ts";
import { demoState, DEMO_NOW } from "../ui/demo.ts";
import { utcClock } from "../ui/rows.ts";
import { renderSnapshot } from "../ui/snapshot.ts";

const USAGE =
  "usage: tower theme rules | new <name> | check <name> | preview <name>";

function preview(theme: Theme, columns: number): string[] {
  return [
    ...renderSnapshot(demoState(), theme, columns, DEMO_NOW, utcClock),
    "",
    ...renderSnapshot(
      demoState({ closed: true }),
      theme,
      columns,
      DEMO_NOW,
      utcClock,
    ).slice(0, 2),
  ];
}

export async function themeCommand(argv: string[], io: Io): Promise<number> {
  const { positionals } = parseArgs({ args: argv, allowPositionals: true });
  const [sub, name] = positionals;
  switch (sub) {
    case "rules":
      io.stdout(THEME_RULES);
      return 0;
    case "new": {
      if (!name) throw new UsageError(USAGE);
      let path: string;
      try {
        path = scaffoldTheme(name, io.env);
      } catch (error) {
        throw new UsageError((error as Error).message);
      }
      io.stdout(
        `${path}\nfill in every key, then: tower theme check ${name}\n`,
      );
      return 0;
    }
    case "check": {
      if (!name) throw new UsageError(USAGE);
      let theme: Theme;
      try {
        theme = loadTheme(name, io.env);
      } catch (error) {
        io.stderr(`tower: ${(error as Error).message}\n`);
        return 1;
      }
      // Structural problems (missing/duplicate/over-length keys) are already
      // caught by loadTheme, which runs checkTheme and throws before this
      // point is reached; everything below is the preview-coverage check on
      // top of that (rule 7 — every label must actually show up).
      const problems: string[] = [];
      // Case-insensitive: the closed banner is rendered upper-cased (spec's
      // "FIELD CLOSED" banner) while the theme stores the label lower-case,
      // so an exact-case search would always flag `states.closed`.
      const text = preview(theme, io.columns).join("\n").toLowerCase();
      for (const [key, label] of Object.entries(theme.states)) {
        if (!text.includes(label.toLowerCase()))
          problems.push(
            `states.${key} "${label}" never appears in the preview`,
          );
      }
      for (const [key, label] of Object.entries(theme.verbs))
        if (!text.includes(label.toLowerCase()))
          problems.push(`verbs.${key} "${label}" never appears in the preview`);
      if (problems.length > 0) {
        io.stderr(
          `tower: ${name} has ${problems.length} problem${problems.length === 1 ? "" : "s"}:\n  ${problems.join("\n  ")}\n`,
        );
        return 1;
      }
      io.stdout(
        `${name}: ok — read it back with: tower theme preview ${name}\n`,
      );
      return 0;
    }
    case "preview": {
      if (!name) throw new UsageError(USAGE);
      let theme: Theme;
      try {
        theme = loadTheme(name, io.env);
      } catch (error) {
        throw new UsageError((error as Error).message);
      }
      io.stdout(`${preview(theme, io.columns).join("\n")}\n`);
      return 0;
    }
    default:
      throw new UsageError(USAGE);
  }
}
