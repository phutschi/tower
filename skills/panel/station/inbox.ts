/**
 * Calls into the Plannotator Inbox, through `plannotator inbox call`: the
 * station's jobs and the hub's notes.
 */
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const run = promisify(execFile);

/** One message to the user; the same key never posts twice. */
export async function sendInboxNote(opts: {
  thread: string;
  subject: string;
  body: string;
  idempotencyKey: string;
  plannotatorBin?: string;
}): Promise<void> {
  await run(opts.plannotatorBin ?? "plannotator", [
    "inbox",
    "call",
    "send_message",
    JSON.stringify({
      thread: opts.thread,
      subject: opts.subject,
      body: opts.body,
      idempotency_key: opts.idempotencyKey,
    }),
  ]);
}
