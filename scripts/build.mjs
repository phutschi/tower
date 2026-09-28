// The build, with Node alone: tsc emits dist/ from src/, and dist/cli.js
// becomes executable. `bun run build` and npm's `prepare` (the git install)
// both run it. Types are checked by `typecheck`, not here, so a type error
// never breaks an install.
import { execFileSync } from "node:child_process";
import { chmodSync } from "node:fs";
import { createRequire } from "node:module";
import { execPath } from "node:process";

const tsc = createRequire(import.meta.url).resolve("typescript/bin/tsc");
execFileSync(execPath, [tsc, "-p", "tsconfig.build.json", "--noCheck"], {
  stdio: "inherit",
});
chmodSync("dist/cli.js", 0o755);
