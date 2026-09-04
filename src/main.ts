/**
 * Dispatch. A bare `tower` (or one that starts with a flag) is the console;
 * anything else is a subcommand. The console is imported lazily so that
 * `tower task`, which agents call dozens of times a run, never pays for
 * loading React.
 */
import type { Io } from "./io.ts";
import { UsageError } from "./io.ts";
import { assignCommand, closeCommand, initCommand } from "./commands/init.ts";
import { stateCommand, waitCommand } from "./commands/state.ts";
import { themeCommand } from "./commands/theme.ts";
import { briefCommand } from "./commands/brief.ts";
import { blockCommand, noteCommand, taskCommand } from "./commands/task.ts";

export const USAGE = `tower — a control tower for long-running agent implementation runs

  tower [--run <dir>] [--theme <name>] [--plain] [--stale <minutes>]
                                    the console; watch the run until you press q

  orchestrator
    tower init --plan <plan.md> [--lane A=1-4,6]... [--theme <name>]
               [--model <role>=<model>]... [--callsign <X>] [--run <dir>] [--force]
    tower init --tasks <tasks.tsv> [--title <text>] ...  (or pipe a TSV on stdin)
    tower assign <lane> <ids>                 record which tasks a lane owns
    tower brief <lane> [--conventions-heading <heading>]
    tower close ["<note>"]                    declare the run finished

  scripts
    tower state --json
    tower wait --timeout <seconds>            exit 0 when something needs a human, 3 when quiet

  themes
    tower theme rules | new <name> | check <name> | preview <name>

  executors
    tower task <id> <status> [phase] [note] --model <model>
    tower block <id> "<what you need>"
    tower note [--task <id> | --lane <lane>] "<text>"

status: pending | in_progress | reviewing | done | blocked
`;

type Command = (argv: string[], io: Io) => Promise<number>;

const COMMANDS: Record<string, () => Promise<Command>> = {
  task: async () => taskCommand,
  block: async () => blockCommand,
  note: async () => noteCommand,
  init: async () => initCommand,
  assign: async () => assignCommand,
  close: async () => closeCommand,
  state: async () => stateCommand,
  wait: async () => waitCommand,
  theme: async () => themeCommand,
  brief: async () => briefCommand,
};

export async function main(argv: string[], io: Io): Promise<number> {
  const [first, ...rest] = argv;
  try {
    if (first === "--help" || first === "-h" || first === "help") {
      io.stdout(USAGE);
      return 0;
    }
    if (first === undefined || first.startsWith("-")) {
      const { consoleCommand } = await import("./ui/console.tsx");
      return await consoleCommand(argv, io);
    }
    const load = COMMANDS[first];
    if (!load)
      throw new UsageError(
        `unknown command "${first}"\n       commands: ${Object.keys(COMMANDS).join(", ")}\n       tower --help for usage`,
      );
    return await (
      await load()
    )(rest, io);
  } catch (error) {
    if (error instanceof UsageError) {
      io.stderr(`tower: ${error.message}\n`);
      return error.exit;
    }
    if (
      error instanceof Error &&
      String((error as { code?: string }).code).startsWith("ERR_PARSE_ARGS")
    ) {
      io.stderr(`tower: ${error.message}\n       tower --help for usage\n`);
      return 1;
    }
    throw error;
  }
}
