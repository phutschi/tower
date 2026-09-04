#!/usr/bin/env node
import { realIo } from "./io.ts";
import { main } from "./main.ts";

process.exitCode = await main(process.argv.slice(2), realIo());
