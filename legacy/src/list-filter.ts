import type { Entry } from './types';

/**
 * QUA-63: flat multi-filter for the per-type card lists.
 *
 * A filter is a flat list of `{field, op, value}` clauses combined with a
 * single match mode — 满足全部 (AND) or 满足任一 (OR). No nested groups. Pure
 * functions over already-loaded entries; no fetch, no state.
 */

export type FilterField = 'rating' | 'year' | 'author' | 'theme' | 'source' | 'haspdf' | 'added';
export type FilterOp = 'gte' | 'lte' | 'eq' | 'contains' | 'is' | 'yes' | 'within';
export type FilterMatch = 'all' | 'any';

export interface FilterClause {
  /** Stable React key + chip identity. */
  id: string;
  field: FilterField;
  op: FilterOp;
  /** Raw text; numeric ops parse it. Ignored for 'haspdf'. */
  value: string;
}

export interface FilterFieldDef {
  field: FilterField;
  label: string;
  ops: { op: FilterOp; label: string }[];
  /** What kind of value input the row shows. */
  input: 'number' | 'text' | 'none';
  placeholder?: string;
}

export const FILTER_FIELDS: FilterFieldDef[] = [
  { field: 'rating', label: '评分', input: 'number', placeholder: '0–4',
    ops: [{ op: 'gte', label: '≥' }, { op: 'eq', label: '=' }, { op: 'lte', label: '≤' }] },
  { field: 'year', label: '年份', input: 'number', placeholder: '如 2015',
    ops: [{ op: 'gte', label: '≥' }, { op: 'eq', label: '=' }, { op: 'lte', label: '≤' }] },
  { field: 'author', label: '作者', input: 'text', placeholder: '作者名',
    ops: [{ op: 'contains', label: '包含' }] },
  { field: 'theme', label: '主题', input: 'text', placeholder: '主题',
    ops: [{ op: 'is', label: '是' }, { op: 'contains', label: '包含' }] },
  { field: 'source', label: '来源', input: 'text', placeholder: '来源',
    ops: [{ op: 'contains', label: '包含' }, { op: 'is', label: '是' }] },
  { field: 'haspdf', label: '有 PDF', input: 'none',
    ops: [{ op: 'yes', label: '是' }] },
  { field: 'added', label: '入库', input: 'number', placeholder: '天数',
    ops: [{ op: 'within', label: '近 N 天' }] },
];

export const FILTER_FIELD_BY_ID: Record<FilterField, FilterFieldDef> =
  Object.fromEntries(FILTER_FIELDS.map(f => [f.field, f])) as Record<FilterField, FilterFieldDef>;

function newId(): string {
  try {
    if (typeof crypto !== 'undefined' && crypto.randomUUID) return crypto.randomUUID();
  } catch {}
  return Math.random().toString(36).slice(2);
}

/** Build a fresh clause for a field, defaulting to its first operator. */
export function makeClause(field: FilterField, op?: FilterOp, value = ''): FilterClause {
  const def = FILTER_FIELD_BY_ID[field];
  return { id: newId(), field, op: op ?? def.ops[0].op, value };
}

/** True when a clause has enough input to actually filter. */
export function clauseReady(c: FilterClause): boolean {
  const def = FILTER_FIELD_BY_ID[c.field];
  if (def.input === 'none') return true;
  if (def.input === 'number') return Number.isFinite(Number(c.value)) && c.value.trim() !== '';
  return c.value.trim() !== '';
}

function toNum(v: unknown): number | null {
  if (v == null || v === '') return null;
  const n = typeof v === 'number' ? v : Number(v);
  return Number.isFinite(n) ? n : null;
}

function testClause(e: Entry, c: FilterClause): boolean {
  switch (c.field) {
    case 'rating': {
      const want = toNum(c.value);
      if (want == null) return true;
      const got = e.rating_score || 0;
      return c.op === 'lte' ? got <= want : c.op === 'eq' ? got === want : got >= want;
    }
    case 'year': {
      const want = toNum(c.value);
      const got = toNum(e.year);
      if (want == null) return true;
      if (got == null) return false;
      return c.op === 'lte' ? got <= want : c.op === 'eq' ? got === want : got >= want;
    }
    case 'author': {
      const v = c.value.trim().toLowerCase();
      return (e.author ?? '').toLowerCase().includes(v);
    }
    case 'theme': {
      const v = c.value.trim().toLowerCase();
      const themes = e.themes ?? [];
      return c.op === 'is'
        ? themes.some(t => t.toLowerCase() === v)
        : themes.some(t => t.toLowerCase().includes(v));
    }
    case 'source': {
      const v = c.value.trim().toLowerCase();
      const src = (e.source ?? '').toLowerCase();
      return c.op === 'is' ? src === v : src.includes(v);
    }
    case 'haspdf':
      return !!e.has_pdf;
    case 'added': {
      const days = toNum(c.value);
      if (days == null || !e.added) return false;
      return Date.now() - e.added <= days * 86400000;
    }
  }
}

/** Apply ready clauses; empty/incomplete clauses are ignored so half-typed
 *  rows don't blank the list. */
export function applyFilters(list: Entry[], clauses: FilterClause[], match: FilterMatch): Entry[] {
  const active = clauses.filter(clauseReady);
  if (active.length === 0) return list;
  return list.filter(e =>
    match === 'all' ? active.every(c => testClause(e, c)) : active.some(c => testClause(e, c)),
  );
}

/** Short human label for a clause chip, e.g. "评分 ≥ 3". */
export function clauseLabel(c: FilterClause): string {
  const def = FILTER_FIELD_BY_ID[c.field];
  if (c.field === 'haspdf') return '有 PDF';
  const op = def.ops.find(o => o.op === c.op)?.label ?? '';
  if (c.field === 'added') return `入库近 ${c.value} 天`;
  return `${def.label} ${op} ${c.value}`.trim();
}
