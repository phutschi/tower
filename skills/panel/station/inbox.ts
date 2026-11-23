/**
 * Calls into the Plannotator Inbox, through `plannotator inbox call`: the
 * station's jobs and the hub's notes.
 */
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { promisify } from "node:util";

const run = promisify(execFile);

/** One Inbox action; `cwd` is the project it is filed under (default: here). */
const call = async (
  action: string,
  fields: object,
  cwd?: string,
): Promise<unknown> =>
  JSON.parse(
    (
      await run(
        "plannotator",
        ["inbox", "call", action, JSON.stringify(fields)],
        {
          timeout: 60_000,
          ...(cwd ? { cwd } : {}),
        },
      )
    ).stdout,
  ) as unknown;

/** The Inbox takes a thread name of 1 to 120 characters. */
const THREAD_MAX = 120;

/**
 * A run's Inbox thread, named after its issues: every ref while they fit,
 * else the first, how many more, and a hash of them all.
 */
export function threadName(repo: string, issues: number[]): string {
  const full = issues.map((n) => `${repo}#${n}`).join(" + ");
  if (full.length <= THREAD_MAX) return full;
  const hash = createHash("sha256")
    .update(issues.join(","))
    .digest("hex")
    .slice(0, 8);
  const tail = ` + ${issues.length - 1} more (${hash})`;
  return `${repo}#${issues[0]}`.slice(0, THREAD_MAX - tail.length) + tail;
}

/** One message to the user in `thread`; the same key never posts twice. */
export async function sendMessage(opts: {
  thread: string;
  subject: string;
  body: string;
  idempotencyKey: string;
}): Promise<{ threadId: string; cursor: string }> {
  const sent = (await call("send_message", {
    thread: opts.thread,
    subject: opts.subject,
    body: opts.body,
    idempotency_key: opts.idempotencyKey,
  })) as { thread_id: string; cursor: string };
  return { threadId: sent.thread_id, cursor: sent.cursor };
}

/** A note to the user that needs no answer. */
export async function sendInboxNote(opts: {
  thread: string;
  subject: string;
  body: string;
  idempotencyKey: string;
}): Promise<void> {
  await sendMessage(opts);
}

interface ThreadRead {
  thread?: {
    messages?: { id: string; author?: { kind?: string }; body?: string }[];
  };
  cursor?: string;
}

/** What the person wrote in a thread since `after`, and the cursor to read on from. */
export async function readThread(
  threadId: string,
  opts: { after?: string } = {},
): Promise<{ cursor: string; personReplies: { id: string; body: string }[] }> {
  const read = (await call("read_thread", {
    thread_id: threadId,
    format: "full",
    ...(opts.after ? { after: opts.after } : {}),
  })) as ThreadRead;
  return {
    cursor: read.cursor ?? opts.after ?? "",
    personReplies: (read.thread?.messages ?? [])
      .filter((m) => m.author?.kind === "person")
      .map((m) => ({ id: m.id, body: m.body ?? "" })),
  };
}

/**
 * Whether the thread named `thread`, in the project at `cwd`, has a question
 * the person has not answered yet (open, or picked and not sent).
 */
export async function waitsOnPerson(
  thread: string,
  cwd: string,
): Promise<boolean> {
  const list = (await call(
    "read_thread",
    { asked_by: "anyone", limit: 50 },
    cwd,
  )) as {
    threads?: {
      thread_name?: string;
      questions?: { open?: number; picked?: number };
    }[];
  };
  // The Inbox ignores case and spacing in a thread's name.
  const norm = (n = "") => n.toLowerCase().replace(/\s+/g, "");
  return (list.threads ?? []).some(
    (t) =>
      norm(t.thread_name) === norm(thread) &&
      (t.questions?.open ?? 0) + (t.questions?.picked ?? 0) > 0,
  );
}
