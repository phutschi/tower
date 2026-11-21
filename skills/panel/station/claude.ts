/** Runs a headless Claude Code session and reads its stream-json answer. */

/** One of the session's rate-limit events; `resetsAt` is ISO time. */
export interface RateLimitInfo {
  status: "allowed" | "allowed_warning" | "rejected";
  rateLimitType?: string;
  utilization?: number;
  resetsAt?: string;
}

export interface HeadlessRun {
  sessionId: string;
  finalText: string;
  tokens: { input: number; output: number };
  rateLimits: RateLimitInfo[];
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
  rate_limit_info?: {
    status: RateLimitInfo["status"];
    rateLimitType?: string;
    utilization?: number;
    /** Seconds since the epoch. */
    resetsAt?: number;
    overageStatus?: RateLimitInfo["status"];
    isUsingOverage?: boolean;
  };
}

/**
 * One `claude -p` session, or a resumed one, the prompt on stdin, with only
 * `tools` of the built-in ones when given. Its error
 * says why it failed: the result's subtype, an API error's category, or the
 * exit when it gave no result. Input tokens count the cached ones too.
 */
export async function runHeadless(opts: {
  prompt: string;
  cwd: string;
  model: string;
  tools?: string[];
  resume?: string;
  signal?: AbortSignal;
}): Promise<HeadlessRun> {
  const args = ["-p", "--output-format", "stream-json", "--verbose"];
  args.push("--model", opts.model);
  // Only the tools named: none of the user's MCP servers either, since a
  // session may read text a stranger wrote.
  if (opts.tools)
    args.push("--strict-mcp-config", "--tools", opts.tools.join(","));
  if (opts.resume) args.push("--resume", opts.resume);
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
    sessionId: opts.resume ?? "",
    finalText: "",
    tokens: { input: 0, output: 0 },
    rateLimits: [],
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
    const info = msg.type === "rate_limit_event" && msg.rate_limit_info;
    if (info)
      run.rateLimits.push({
        // A request the plan refused but extra usage pays for goes on.
        status:
          info.status === "rejected" &&
          (info.overageStatus === "allowed" || info.isUsingOverage)
            ? "allowed_warning"
            : info.status,
        ...(info.rateLimitType ? { rateLimitType: info.rateLimitType } : {}),
        ...(info.utilization === undefined
          ? {}
          : { utilization: info.utilization }),
        ...(info.resetsAt
          ? { resetsAt: new Date(info.resetsAt * 1000).toISOString() }
          : {}),
      });
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

/** The JSON object in a session's answer, fenced or bare; null if it holds none. */
export function jsonIn(text: string): unknown {
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  try {
    return start < 0
      ? null
      : (JSON.parse(text.slice(start, end + 1)) as unknown);
  } catch {
    return null;
  }
}

/**
 * Hands a session's rate-limit events to the hub, which pauses dispatch at a
 * rejection. A rate_limit error with no rejection of its own counts as one,
 * at the earliest reset the session named.
 */
export async function reportLimits(
  run: HeadlessRun,
  emit: (kind: string, data: Record<string, unknown>) => Promise<void>,
) {
  for (const info of run.rateLimits) await emit("rate-limit", { ...info });
  if (
    run.error?.category === "rate_limit" &&
    !run.rateLimits.some((r) => r.status === "rejected")
  ) {
    // The earliest reset: a wrong guess costs one more refused job, not days.
    const resetsAt = run.rateLimits
      .map((r) => r.resetsAt)
      .filter((r) => r !== undefined)
      .sort()[0];
    await emit("rate-limit", {
      status: "rejected",
      ...(resetsAt ? { resetsAt } : {}),
    });
  }
}
