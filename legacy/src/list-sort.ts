import type { Entry } from './types';

/**
 * QUA-59: client-side sort + extra filters for the per-type card lists.
 *
 * Pure functions over the already-loaded entries — no fetch, no state. The
 * vault has no `status` field and no uniform creation time, so we sort by the
 * fields that actually exist (see the design spec). Empty values always sort
 * last regardless of direction, so toggling asc/desc never floats blanks to the
 * top.
 */

export type SortKey = 'default' | 'title' | 'author' | 'year' | 'rating' | 'updated' | 'added';
export type SortDir = 'asc' | 'desc';
export type SortField = Exclude<SortKey, 'default'>;

export const SORT_OPTIONS: ReadonlyArray<{ key: SortKey; label: string }> = [
  { key: 'default', label: '默认' },
  { key: 'title', label: '标题' },
  { key: 'author', label: '作者' },
  { key: 'year', label: '年份' },
  { key: 'rating', label: '评分' },
  { key: 'updated', label: '更新时间' },
  { key: 'added', label: '入库时间' },
];

/** Fields available to the multi-sort UI (no 'default' — an empty clause list
 *  IS the default/index order). */
export const SORT_FIELDS: ReadonlyArray<{ field: SortField; label: string }> = [
  { field: 'rating', label: '评分' },
  { field: 'year', label: '年份' },
  { field: 'added', label: '入库时间' },
  { field: 'updated', label: '更新时间' },
  { field: 'title', label: '标题' },
  { field: 'author', label: '作者' },
];

const SORT_FIELD_SET: ReadonlySet<string> = new Set(SORT_FIELDS.map(f => f.field));

const SORT_KEYS: ReadonlySet<string> = new Set(SORT_OPTIONS.map(o => o.key));

/** Coerce a persisted/untrusted value to a valid SortKey (defaults to 'default'),
 *  so a stale localStorage blob can't reach the comparator and throw. */
export function asSortKey(v: unknown): SortKey {
  return typeof v === 'string' && SORT_KEYS.has(v) ? (v as SortKey) : 'default';
}

export function asSortDir(v: unknown): SortDir {
  return v === 'asc' || v === 'desc' ? v : 'desc';
}

/** Sensible default direction when the user switches to a sort key. */
export function defaultDirFor(key: SortKey): SortDir {
  switch (key) {
    case 'title':
    case 'author':
      return 'asc';
    default:
      return 'desc'; // year / rating / updated read best newest/highest first
  }
}

function toNum(v: unknown): number | null {
  if (v == null || v === '') return null;
  const n = typeof v === 'number' ? v : Number(v);
  return Number.isFinite(n) ? n : null;
}

function textCmp(a: string | null | undefined, b: string | null | undefined, dir: SortDir): number {
  const ea = a == null || a === '';
  const eb = b == null || b === '';
  if (ea && eb) return 0;
  if (ea) return 1; // empties last
  if (eb) return -1;
  const c = String(a).localeCompare(String(b), 'zh-Hans-CN', { numeric: true, sensitivity: 'base' });
  return dir === 'asc' ? c : -c;
}

function numCmp(a: number | null, b: number | null, dir: SortDir): number {
  const ea = a == null;
  const eb = b == null;
  if (ea && eb) return 0;
  if (ea) return 1; // empties last
  if (eb) return -1;
  const c = a! - b!;
  return dir === 'asc' ? c : -c;
}

function comparatorFor(key: Exclude<SortKey, 'default'>, dir: SortDir): (a: Entry, b: Entry) => number {
  switch (key) {
    case 'title':   return (a, b) => textCmp(a.title, b.title, dir);
    case 'author':  return (a, b) => textCmp(a.author, b.author, dir);
    case 'year':    return (a, b) => numCmp(toNum(a.year), toNum(b.year), dir);
    // rating_score 0 means "unrated" in this vault — treat as empty so it sorts
    // last in both directions (matches the empties-last contract above).
    case 'rating':  return (a, b) => numCmp(a.rating_score || null, b.rating_score || null, dir);
    case 'updated': return (a, b) => numCmp(a.mtime ?? null, b.mtime ?? null, dir);
    case 'added':   return (a, b) => numCmp(a.added || null, b.added || null, dir);
  }
}

/** Stable sort. `default` returns the list unchanged (preserves relevance /
 *  index order). Tie-breaks on original index so equal keys keep input order. */
export function sortEntries(list: Entry[], key: SortKey, dir: SortDir): Entry[] {
  if (key === 'default' || !SORT_KEYS.has(key)) return list;
  const cmp = comparatorFor(key, dir);
  return list
    .map((e, i) => [e, i] as const)
    .sort((x, y) => cmp(x[0], y[0]) || x[1] - y[1])
    .map(([e]) => e);
}

/** One level of a multi-sort: a field plus its direction. The clause list is
 *  applied in order, each level breaking ties of the level above it. */
export interface SortClause {
  field: SortField;
  dir: SortDir;
}

/** Validate an untrusted value (e.g. a persisted settings blob) into a clean
 *  SortClause list. Drops anything malformed so a stale store can't crash sort. */
export function coerceSortClauses(v: unknown): SortClause[] {
  if (!Array.isArray(v)) return [];
  const out: SortClause[] = [];
  for (const c of v) {
    if (c && typeof c === 'object' && SORT_FIELD_SET.has((c as SortClause).field)) {
      out.push({ field: (c as SortClause).field, dir: asSortDir((c as SortClause).dir) });
    }
  }
  return out;
}

/** Multi-level stable sort. Empty clause list returns the input unchanged
 *  (preserves relevance / index order). Ties fall through to the next clause,
 *  then to original index so equal keys keep input order. */
export function sortEntriesMulti(list: Entry[], clauses: SortClause[]): Entry[] {
  if (clauses.length === 0) return list;
  const cmps = clauses.map(c => comparatorFor(c.field, c.dir));
  return list
    .map((e, i) => [e, i] as const)
    .sort((x, y) => {
      for (const cmp of cmps) {
        const r = cmp(x[0], y[0]);
        if (r) return r;
      }
      return x[1] - y[1];
    })
    .map(([e]) => e);
}

export interface ExtraFilters {
  /** Case-insensitive substring match against entry.author. */
  author?: string;
  /** Keep only entries that have a matching PDF in sources/. */
  hasPdfOnly?: boolean;
}

export function applyExtraFilters(list: Entry[], f: ExtraFilters): Entry[] {
  const author = f.author?.trim().toLowerCase();
  if (!author && !f.hasPdfOnly) return list;
  return list.filter(e => {
    if (author && !(e.author ?? '').toLowerCase().includes(author)) return false;
    if (f.hasPdfOnly && !e.has_pdf) return false;
    return true;
  });
}
