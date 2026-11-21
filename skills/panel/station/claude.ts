/** Runs a headless Claude Code session and reads its stream-json answer. */
export interface HeadlessRun {
  sessionId: string;
  finalText: string;
  tokens: { input: number; output: number };
  error?: { category: string; message: string };
}

interface Usage {
  input_tokens?: number;
  cache_creation_input_tokens?: number;
  cache_read_input_tokens?: number;
  output_tokens?: number;
}
interface StreamLine {
  type?: string;
  subtype?: string;
  session_id?: string;
  is_error?: boolean;
  result?: string;
  errors?: string[];
  error?: string;
  usage?: Usage;
}

/**
 * One `claude -p` session, the prompt on stdin, with only `tools` of the
 * built-in ones when given. Its error
 * says why it failed: the result's subtype, an API error's category, or the
 * exit when it gave no result. Input tokens count the cached ones too.
 */
export async function runHeadless(opts: {
  prompt: string;
  cwd: string;
  model: string;
  tools?: string[];
  signal?: AbortSignal;
}): Promise<HeadlessRun> {
  const args = ["-p", "--output-format", "stream-json", "--verbose"];
  args.push("--model", opts.model);
  // Only the tools named: none of the user's MCP servers either, since a
  // session may read text a stranger wrote.
  if (opts.tools)
    args.push("--strict-mcp-config", "--tools", opts.tools.join(","));
  const proc = Bun.spawn(["claude", ...args], {
    cwd: opts.cwd,
    stdin: new Blob([opts.prompt]),
    stdout: "pipe",
    stderr: "pipe",
    ...(opts.signal ? { signal: opts.signal } : {}),
  });
  const [out, err, code] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  const run: HeadlessRun = {
    sessionId: "",
    finalText: "",
    tokens: { input: 0, output: 0 },
  };
  let result: StreamLine | undefined;
  for (const line of out.split("\n")) {
    let msg: StreamLine;
    try {
      msg = JSON.parse(line) as StreamLine;
    } catch {
      continue; // not a stream-json line
    }
    if (msg.session_id) run.sessionId = msg.session_id;
    if (msg.type === "assistant" && msg.error)
      run.error = { category: msg.error, message: "the API refused the turn" };
    if (msg.type === "result") result = msg;
  }
  if (result) {
    const u = result.usage ?? {};
    run.finalText = result.result ?? "";
    run.tokens = {
      input:
        (u.input_tokens ?? 0) +
        (u.cache_creation_input_tokens ?? 0) +
        (u.cache_read_input_tokens ?? 0),
      output: u.output_tokens ?? 0,
    };
    if (result.is_error)
      run.error ??= {
        category: result.subtype ?? "error",
        message:
          result.errors?.join("; ") || result.result || "no reason given",
      };
  } else
    run.error ??= {
      category: "exit",
      message: `claude exited ${code} with no result: ${err.trim().slice(-500)}`,
    };
  return run;
}
