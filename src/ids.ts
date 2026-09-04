/**
 * Task ids are strings: `14`, `3a`, `auth-1`. Order is always the plan's,
 * never numeric or lexical. A range `7-9` is expanded only when both ends are
 * integers — so `auth-1` is an id, not a range from "auth" to "1".
 */

export const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

export const isValidId = (id: string): boolean => ID_PATTERN.test(id);

const INT_RANGE = /^(\d+)-(\d+)$/;

export function expandIds(spec: string): string[] {
  const out: string[] = [];
  for (const token of spec
    .split(",")
    .map((t) => t.trim())
    .filter(Boolean)) {
    const range = INT_RANGE.exec(token);
    if (range) {
      const lo = Number(range[1]);
      const hi = Number(range[2]);
      if (hi < lo) throw new Error(`range "${token}" runs backwards`);
      for (let n = lo; n <= hi; n++) out.push(String(n));
      continue;
    }
    if (token.includes("-") && /^[A-Za-z]+-[A-Za-z]+$/.test(token))
      throw new Error(`range "${token}" must be integer to integer, like 7-9`);
    if (!isValidId(token))
      throw new Error(
        `"${token}" is not a valid task id (letters, digits, . _ -; no spaces)`,
      );
    out.push(token);
  }
  return [...new Set(out)];
}

export function sortByPlan(
  ids: readonly string[],
  planIds: readonly string[],
): string[] {
  const rank = new Map(planIds.map((id, i) => [id, i]));
  return [...ids].sort(
    (a, b) => (rank.get(a) ?? Infinity) - (rank.get(b) ?? Infinity),
  );
}

function distance(a: string, b: string): number {
  const rows = Array.from({ length: a.length + 1 }, (_, i) => [
    i,
    ...new Array<number>(b.length).fill(0),
  ]);
  for (let j = 0; j <= b.length; j++) (rows[0] as number[])[j] = j;
  for (let i = 1; i <= a.length; i++)
    for (let j = 1; j <= b.length; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      const row = rows[i] as number[];
      const prev = rows[i - 1] as number[];
      row[j] = Math.min(
        (row[j - 1] as number) + 1,
        (prev[j] as number) + 1,
        (prev[j - 1] as number) + cost,
      );
    }
  return (rows[a.length] as number[])[b.length] as number;
}

/** The closest existing id, when it is close enough to be a typo. */
export function nearestId(
  id: string,
  ids: readonly string[],
): string | undefined {
  let best: { id: string; d: number } | undefined;
  for (const candidate of ids) {
    const d = distance(id.toLowerCase(), candidate.toLowerCase());
    if (!best || d < best.d) best = { id: candidate, d };
  }
  if (!best) return undefined;
  const limit = Math.max(2, Math.floor(id.length / 2));
  return best.d <= limit ? best.id : undefined;
}
