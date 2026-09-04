/**
 * Keep a folded State current. The events file is watched, and polled every
 * two seconds as well, because fs.watch on macOS can miss an append from
 * another process; reads are incremental from the last byte offset, and a
 * read that restarted (the file shrank) replaces what we had.
 */
import { watch } from "node:fs";
import { useEffect, useRef, useState } from "react";

import type { ParsedLine } from "../events.ts";
import type { State } from "../state.ts";
import type { RunFile } from "../types.ts";
import { readEvents } from "../events.ts";
import { eventsPath } from "../run.ts";
import { fold } from "../state.ts";

export interface RunStateOptions {
  runDir: string;
  run: RunFile;
  staleMinutes: number;
  now: () => Date;
  pollMs?: number;
}

export function useRunState(options: RunStateOptions): State {
  const { runDir, run, staleMinutes, now, pollMs = 2000 } = options;
  const [state, setState] = useState<State>(() =>
    fold(run, readEvents(eventsPath(runDir), 0).lines, {
      now: now(),
      staleMinutes,
    }),
  );
  // now/run read through a ref, not the effect's dependency array: `now` is
  // a fresh closure on every render for some callers, and `fold`'s own
  // return value is always a new object, so depending on either would
  // restart the watcher (and drop accumulated `lines`) every single poll —
  // an infinite subscribe/unsubscribe loop rather than a periodic refresh.
  const latest = useRef({ run, now });
  latest.current = { run, now };
  useEffect(() => {
    const path = eventsPath(runDir);
    let lines: ParsedLine[] = [];
    let offset = 0;
    const refresh = () => {
      const result = readEvents(path, offset);
      if (result.restarted) lines = result.lines;
      else if (result.lines.length > 0) lines = [...lines, ...result.lines];
      offset = result.offset;
      setState(
        fold(latest.current.run, lines, {
          now: latest.current.now(),
          staleMinutes,
        }),
      );
    };
    refresh();
    let watcher: ReturnType<typeof watch> | undefined;
    try {
      watcher = watch(path, refresh);
    } catch {
      /* the poll covers it */
    }
    const timer = setInterval(refresh, pollMs);
    return () => {
      watcher?.close();
      clearInterval(timer);
    };
  }, [runDir, staleMinutes, pollMs]);
  return state;
}
