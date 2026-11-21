/** The station's calls into the Plannotator Inbox, through `plannotator inbox call`. */
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const run = promisify(execFile);

const call = async (action: string, fields: object): Promise<unknown> =>
  JSON.parse(
    (
      await run(
        "plannotator",
        ["inbox", "call", action, JSON.stringify(fields)],
        { timeout: 60_000 },
      )
    ).stdout,
  ) as unknown;

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
