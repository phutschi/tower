/** The hub's notes to the user, in the server Mac's Plannotator Inbox. */
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const run = promisify(execFile);

/**
 * Posts one message to the Inbox thread `thread`. The idempotency key makes
 * a second send of the same note return the first instead of posting twice.
 */
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
