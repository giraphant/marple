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

export type SortKey = 'default' | 'title' | 'author' | 'year' | 'rating' | 'updated';
export type SortDir = 'asc' | 'desc';

export const SORT_OPTIONS: ReadonlyArray<{ key: SortKey; label: string }> = [
  { key: 'default', label: '默认' },
  { key: 'title', label: '标题' },
  { key: 'author', label: '作者' },
  { key: 'year', label: '年份' },
  { key: 'rating', label: '评分' },
  { key: 'updated', label: '更新时间' },
];

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
    case 'rating':  return (a, b) => numCmp(a.rating_score ?? 0, b.rating_score ?? 0, dir);
    case 'updated': return (a, b) => numCmp(a.mtime ?? null, b.mtime ?? null, dir);
  }
}

/** Stable sort. `default` returns the list unchanged (preserves relevance /
 *  index order). Tie-breaks on original index so equal keys keep input order. */
export function sortEntries(list: Entry[], key: SortKey, dir: SortDir): Entry[] {
  if (key === 'default') return list;
  const cmp = comparatorFor(key, dir);
  return list
    .map((e, i) => [e, i] as const)
    .sort((x, y) => cmp(x[0], y[0]) || x[1] - y[1])
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
