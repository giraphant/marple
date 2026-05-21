import { useState, useRef, useEffect, useMemo } from 'preact/hooks';
import type { ComponentChildren } from 'preact';
import type { Entry, EntryType } from '../types';
import { TYPE_BY_ID } from '../types';
import { SORT_FIELDS, defaultDirFor, type SortClause, type SortField } from '../list-sort';
import {
  FILTER_FIELDS, FILTER_FIELD_BY_ID, makeClause, clauseReady, clauseLabel,
  type FilterClause, type FilterMatch, type FilterField,
} from '../list-filter';
import { Card } from './Card';
import { Icon, type IconName } from './Icon';
import { TypeIcon } from './TypeIcon';

type ViewKey = 'all' | 'recent' | 'top';
const VIEW_SEGMENTS: [ViewKey, string][] = [['all', '全部'], ['recent', '近期'], ['top', '高分']];

type GroupKey = 'none' | 'year' | 'rating' | 'theme' | 'added';
const GROUP_OPTIONS: { key: GroupKey; label: string }[] = [
  { key: 'none', label: '不分组' },
  { key: 'year', label: '年份' },
  { key: 'rating', label: '评分' },
  { key: 'theme', label: '主题' },
  { key: 'added', label: '入库月份' },
];

interface Props {
  entries: Entry[];
  type: EntryType;
  typeEntries: Entry[];
  filtered: Entry[];
  query: string;
  filters: FilterClause[];
  filterMatch: FilterMatch;
  sortClauses: SortClause[];
  limit: number;
  searchLoading: boolean;
  searchError: string | null;
  searchMode: 'lex' | 'hybrid';
  onToggleSearchMode: () => void;
  onOpenSearch: () => void;
  onClearQuery: () => void;
  onFiltersChange: (filters: FilterClause[]) => void;
  onMatchChange: (m: FilterMatch) => void;
  onSortChange: (clauses: SortClause[]) => void;
  onLoadMore: () => void;
  onCardClick: (entry: Entry, modifiers: { meta: boolean }) => void;
  onThemeClick: (theme: string) => void;
  onAuthorClick: (author: string) => void;
}

export function ListView({
  entries: _entries, type, typeEntries, filtered, query,
  filters, filterMatch, sortClauses, limit,
  searchLoading, searchError,
  onOpenSearch, onClearQuery,
  onFiltersChange, onMatchChange, onSortChange,
  onLoadMore, onCardClick, onThemeClick, onAuthorClick,
}: Props) {
  void _entries;
  const typeMeta = TYPE_BY_ID[type];
  const readyFilters = useMemo(() => filters.filter(clauseReady), [filters]);
  const filterActive = readyFilters.length > 0;

  const [view, setView] = useState<ViewKey>('all');
  const viewSorted = useMemo(() => {
    if (view === 'recent') return [...filtered].sort((a, b) => (b.added || 0) - (a.added || 0));
    if (view === 'top') return [...filtered].sort((a, b) => (b.rating_score || 0) - (a.rating_score || 0));
    return filtered;
  }, [filtered, view]);
  const visible = query ? viewSorted : viewSorted.slice(0, limit);

  const [groupBy, setGroupBy] = useState<GroupKey>('none');
  const groups = useMemo(() => buildGroups(visible, groupBy), [visible, groupBy]);

  // --- filter clause editing ---
  const setClause = (id: string, patch: Partial<FilterClause>) =>
    onFiltersChange(filters.map(c => (c.id === id ? { ...c, ...patch } : c)));
  const setClauseField = (id: string, field: FilterField) =>
    onFiltersChange(filters.map(c => (c.id === id ? makeClauseKeepId(c.id, field) : c)));
  const removeClause = (id: string) => onFiltersChange(filters.filter(c => c.id !== id));
  const addClause = () => onFiltersChange([...filters, makeClause('rating')]);

  // --- sort clause editing ---
  const setSort = (i: number, patch: Partial<SortClause>) =>
    onSortChange(sortClauses.map((s, j) => (j === i ? { ...s, ...patch } : s)));
  const removeSort = (i: number) => onSortChange(sortClauses.filter((_, j) => j !== i));
  const addSort = () => {
    const used = new Set(sortClauses.map(s => s.field));
    const next = SORT_FIELDS.find(f => !used.has(f.field)) ?? SORT_FIELDS[0];
    onSortChange([...sortClauses, { field: next.field, dir: defaultDirFor(next.field) }]);
  };

  const renderCard = (e: Entry) => (
    <Card
      entry={e}
      onClick={(entry, ev) => onCardClick(entry, { meta: ev.metaKey || ev.ctrlKey })}
      onThemeClick={onThemeClick}
      onAuthorClick={onAuthorClick}
    />
  );

  const loadMore = (!query && groupBy === 'none' && filtered.length > limit) ? (
    <div class="text-center mt-6">
      <button
        onClick={onLoadMore}
        class="px-4 py-2 bg-surface border border-base rounded-xl text-sm shadow-soft-sm hover:shadow-soft hover:-translate-y-px transition"
      >
        再加载 500 ( 已显示 {limit} / {filtered.length} )
      </button>
    </div>
  ) : null;

  return (
    <div class="flex-1 flex flex-col min-h-0">
      <header class="bg-surface/95 backdrop-blur border-b border-base sticky top-0 z-10">
        {/* One header row: type label on the left; quick-view segments in the
            middle; search + count + filter / sort / group icon menus on the
            right. Pinned to 88px so the bottom edge meets the sidebar divider. */}
        <div class="px-8 h-[87px] flex items-center gap-4">
          <div class="flex items-center gap-3 min-w-0 shrink-0">
            <TypeIcon type={type} scale={1.5} />
            <div class="text-[18px] font-bold tracking-[-0.01em] text-primary truncate">{typeMeta?.label ?? type}</div>
          </div>

          {/* Quick-view segments (扩展位:之后挂固定筛选视图) */}
          <div class="flex items-center gap-0.5 bg-surface-2 rounded-lg p-0.5 text-[12px] shrink-0">
            {VIEW_SEGMENTS.map(([v, label]) => (
              <button
                key={v}
                onClick={() => setView(v)}
                class={`px-2.5 py-1 rounded-md transition ${view === v ? 'bg-surface text-primary shadow-soft-sm' : 'text-secondary hover:text-primary'}`}
              >{label}</button>
            ))}
          </div>

          <div class="ml-auto shrink-0 flex items-center gap-1.5">
            <button
              onClick={onOpenSearch}
              title="搜索 (⌘K)"
              aria-label="搜索"
              class="p-2 rounded-md text-muted hover:text-primary hover:bg-surface-2 transition"
            >
              <Icon name="magnifying-glass" size={17} />
            </button>
            <span class="text-[12px] text-muted tabular-nums px-1">
              # {filtered.length}{filtered.length !== typeEntries.length ? ` / ${typeEntries.length}` : ''}
            </span>

            <Pop icon="funnel" active={filterActive} title="多重筛选" width="w-[340px]">
              <div class="flex items-center gap-2 text-[11.5px] text-secondary px-0.5 mb-2">
                满足
                <div class="flex gap-0.5 bg-surface-2 rounded-md p-0.5">
                  {(['all', 'any'] as FilterMatch[]).map(m => (
                    <button
                      key={m}
                      onClick={() => onMatchChange(m)}
                      class={`px-2 py-0.5 rounded text-[11px] transition ${filterMatch === m ? 'bg-surface text-primary shadow-soft-sm' : 'text-secondary hover:text-primary'}`}
                    >{m === 'all' ? '全部' : '任一'}</button>
                  ))}
                </div>
                条件
              </div>

              <div class="space-y-1.5">
                {filters.length === 0 && (
                  <div class="text-[11.5px] text-muted px-0.5 py-1">还没有筛选条件</div>
                )}
                {filters.map(c => (
                  <FilterRow
                    key={c.id}
                    clause={c}
                    onField={(field) => setClauseField(c.id, field)}
                    onOp={(op) => setClause(c.id, { op })}
                    onValue={(value) => setClause(c.id, { value })}
                    onRemove={() => removeClause(c.id)}
                  />
                ))}
              </div>

              <div class="flex items-center gap-2 mt-2.5 pt-2 border-t border-base">
                <button
                  onClick={addClause}
                  class="text-[12px] text-accent-text bg-accent-bg rounded-md px-2.5 py-1 hover:bg-accent/15 transition"
                >+ 添加筛选</button>
                {filters.length > 0 && (
                  <button onClick={() => onFiltersChange([])} class="text-[11.5px] text-muted hover:text-primary ml-auto">清空</button>
                )}
              </div>
            </Pop>

            <Pop icon="sort" active={sortClauses.length > 0} title="多重排序" width="w-[280px]">
              <div class="text-[11px] text-muted px-0.5 pb-1.5">排序（按顺序生效）</div>
              <div class="space-y-1.5">
                {sortClauses.length === 0 && (
                  <div class="text-[11.5px] text-muted px-0.5 py-1">默认顺序</div>
                )}
                {sortClauses.map((s, i) => (
                  <SortRow
                    key={s.field + i}
                    clause={s}
                    onField={(field) => setSort(i, { field, dir: defaultDirFor(field) })}
                    onToggleDir={() => setSort(i, { dir: s.dir === 'asc' ? 'desc' : 'asc' })}
                    onRemove={() => removeSort(i)}
                  />
                ))}
              </div>
              <div class="flex items-center gap-2 mt-2.5 pt-2 border-t border-base">
                <button
                  onClick={addSort}
                  class="text-[12px] text-accent-text bg-accent-bg rounded-md px-2.5 py-1 hover:bg-accent/15 transition"
                >+ 添加排序</button>
                {sortClauses.length > 0 && (
                  <button onClick={() => onSortChange([])} class="text-[11.5px] text-muted hover:text-primary ml-auto">恢复默认</button>
                )}
              </div>
            </Pop>

            <Pop icon="group" active={groupBy !== 'none'} title="分组" width="w-[170px]">
              <div class="text-[11px] text-muted px-1 pb-1">分组依据</div>
              <div class="space-y-0.5">
                {GROUP_OPTIONS.map(o => (
                  <button
                    key={o.key}
                    onClick={() => setGroupBy(o.key)}
                    class={`w-full text-left px-2 py-1 rounded-md text-[12px] ${groupBy === o.key ? 'bg-accent-bg text-accent-text' : 'text-secondary hover:bg-surface-2'}`}
                  >{o.label}</button>
                ))}
              </div>
            </Pop>
          </div>
        </div>

        {(query || filterActive) && (
          <div class="px-8 pb-2.5 flex items-center gap-2 flex-wrap">
            {query && <FilterChip label={`搜索：${query}`} onClear={onClearQuery} />}
            {readyFilters.length > 1 && (
              <span class="text-[11px] text-muted">{filterMatch === 'all' ? '满足全部' : '满足任一'}</span>
            )}
            {readyFilters.map(c => (
              <FilterChip key={c.id} label={clauseLabel(c)} onClear={() => removeClause(c.id)} />
            ))}
            {searchLoading && <span class="text-[11px] text-muted">全文搜索中…</span>}
            {searchError && <span class="text-[11px] text-danger" title={searchError}>全文搜索失败，已用本地匹配</span>}
          </div>
        )}
      </header>

      <main class="flex-1 overflow-auto scrollbar-thin px-8 py-6">
        {filtered.length === 0 ? (
          <div class="text-sm text-muted py-20 text-center">没有匹配的条目</div>
        ) : groupBy === 'none' ? (
          <>
            <div class="columns-[18rem] gap-5">
              {visible.map(e => (
                <div class="mb-5 break-inside-avoid" key={e.path}>{renderCard(e)}</div>
              ))}
            </div>
            {loadMore}
          </>
        ) : (
          <>
            <div class="space-y-8">
              {groups.map(g => (
                <section key={g.key}>
                  <div class="text-[12px] font-semibold text-secondary mb-3 flex items-baseline gap-2">
                    {g.label}
                    <span class="text-muted tabular-nums font-normal">{g.entries.length}</span>
                  </div>
                  <div class="columns-[18rem] gap-5">
                    {g.entries.map(e => (
                      <div class="mb-5 break-inside-avoid" key={g.key + e.path}>{renderCard(e)}</div>
                    ))}
                  </div>
                </section>
              ))}
            </div>
            {loadMore}
          </>
        )}
      </main>
    </div>
  );
}

/** Build a clause for `field` reusing an existing id, so swapping a row's field
 *  resets its op/value without remounting the row. */
function makeClauseKeepId(id: string, field: FilterField): FilterClause {
  return { ...makeClause(field), id };
}

const SELECT_CLASS =
  'bg-page border border-base rounded-md text-[12px] px-1.5 py-1 text-primary focus:outline-none focus:border-accent';

/** One editable filter clause: 字段 + 操作符 + 值 + 移除. */
function FilterRow({ clause, onField, onOp, onValue, onRemove }: {
  clause: FilterClause;
  onField: (f: FilterField) => void;
  onOp: (op: FilterClause['op']) => void;
  onValue: (v: string) => void;
  onRemove: () => void;
}) {
  const def = FILTER_FIELD_BY_ID[clause.field];
  return (
    <div class="flex items-center gap-1.5">
      <select
        value={clause.field}
        onChange={(e) => onField((e.target as HTMLSelectElement).value as FilterField)}
        class={`${SELECT_CLASS} shrink-0`}
      >
        {FILTER_FIELDS.map(f => <option key={f.field} value={f.field}>{f.label}</option>)}
      </select>
      <select
        value={clause.op}
        onChange={(e) => onOp((e.target as HTMLSelectElement).value as FilterClause['op'])}
        class={`${SELECT_CLASS} shrink-0`}
        disabled={def.ops.length <= 1}
      >
        {def.ops.map(o => <option key={o.op} value={o.op}>{o.label}</option>)}
      </select>
      {def.input === 'none' ? (
        <span class="flex-1 min-w-0 text-[12px] text-muted px-1">—</span>
      ) : (
        <input
          type={def.input === 'number' ? 'number' : 'text'}
          value={clause.value}
          placeholder={def.placeholder}
          onInput={(e) => onValue((e.target as HTMLInputElement).value)}
          class="flex-1 min-w-0 bg-surface border border-base rounded-md text-[12px] px-2 py-1 text-primary placeholder:text-muted focus:outline-none focus:border-accent"
        />
      )}
      <button
        onClick={onRemove}
        aria-label="移除条件"
        class="shrink-0 w-6 h-6 rounded-md text-muted hover:text-primary hover:bg-surface-2 flex items-center justify-center transition"
      >
        <Icon name="x" size={12} />
      </button>
    </div>
  );
}

/** One editable sort level: 字段 + 升降 + 移除. */
function SortRow({ clause, onField, onToggleDir, onRemove }: {
  clause: SortClause;
  onField: (f: SortField) => void;
  onToggleDir: () => void;
  onRemove: () => void;
}) {
  return (
    <div class="flex items-center gap-1.5">
      <select
        value={clause.field}
        onChange={(e) => onField((e.target as HTMLSelectElement).value as SortField)}
        class={`${SELECT_CLASS} flex-1 min-w-0`}
      >
        {SORT_FIELDS.map(f => <option key={f.field} value={f.field}>{f.label}</option>)}
      </select>
      <button
        onClick={onToggleDir}
        class="shrink-0 text-[11.5px] text-secondary bg-page border border-base rounded-md px-2 py-1 hover:border-accent transition"
      >{clause.dir === 'asc' ? '升序 ↑' : '降序 ↓'}</button>
      <button
        onClick={onRemove}
        aria-label="移除排序"
        class="shrink-0 w-6 h-6 rounded-md text-muted hover:text-primary hover:bg-surface-2 flex items-center justify-center transition"
      >
        <Icon name="x" size={12} />
      </button>
    </div>
  );
}

/** A removable active-filter chip shown in the toolbar; click to clear. */
function FilterChip({ label, onClear }: { label: string; onClear: () => void }) {
  return (
    <button
      onClick={onClear}
      title="点击移除"
      class="inline-flex items-center gap-1 text-[11px] px-2 py-0.5 rounded-md bg-accent-bg text-accent-text border border-accent/30 hover:bg-accent/15 transition"
    >
      <span class="truncate max-w-[180px]">{label}</span>
      <span aria-hidden="true">✕</span>
    </button>
  );
}

/** An icon button that toggles a popover (filter / sort / group), right-aligned
 *  so the panel opens leftward and never overflows the viewport. */
function Pop({ icon, active, title, width, children }: {
  icon: IconName;
  active?: boolean;
  title: string;
  width?: string;
  children: ComponentChildren;
}) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const onDocClick = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener('mousedown', onDocClick);
    return () => document.removeEventListener('mousedown', onDocClick);
  }, [open]);
  return (
    <div class="relative" ref={ref}>
      <button
        onClick={() => setOpen(v => !v)}
        title={title}
        aria-label={title}
        class={`p-2 rounded-md transition ${active ? 'bg-accent-bg text-accent-text' : 'text-muted hover:text-primary hover:bg-surface-2'}`}
      >
        <Icon name={icon} size={17} />
      </button>
      {open && (
        <div class={`absolute right-0 top-full mt-1 z-20 bg-surface border border-base rounded-xl shadow-soft-lg p-2.5 ${width ?? 'w-[220px]'}`}>
          {children}
        </div>
      )}
    </div>
  );
}

/** Stars for a numeric rating score (used as a group label). */
function ratingStars(score: number): string {
  return score > 0 ? '★'.repeat(Math.max(1, Math.round(score))) : '';
}

/** Split entries into labelled groups for the chosen field. Theme grouping is
 *  multi-membership (a paper appears under each of its themes). */
function buildGroups(entries: Entry[], key: GroupKey): { key: string; label: string; entries: Entry[] }[] {
  if (key === 'none') return [];

  if (key === 'theme') {
    const freq = new Map<string, number>();
    for (const e of entries) for (const t of (e.themes ?? [])) freq.set(t, (freq.get(t) ?? 0) + 1);
    const ordered = [...freq.entries()].sort((a, b) => b[1] - a[1]).map(([t]) => t);
    const groups = ordered.map(t => ({
      key: 't:' + t,
      label: t,
      entries: entries.filter(e => (e.themes ?? []).includes(t)),
    }));
    const untagged = entries.filter(e => !(e.themes && e.themes.length));
    if (untagged.length) groups.push({ key: 't:__none', label: '无主题', entries: untagged });
    return groups;
  }

  const labelOf = (e: Entry): string => {
    if (key === 'year') return e.year != null && String(e.year).trim() ? String(e.year) : '未知年份';
    if (key === 'rating') return e.rating_score > 0 ? ratingStars(e.rating_score) : '未评分';
    return e.added ? new Date(e.added).toISOString().slice(0, 7) : '未知入库'; // added → YYYY-MM
  };
  const map = new Map<string, Entry[]>();
  for (const e of entries) {
    const l = labelOf(e);
    const arr = map.get(l);
    if (arr) arr.push(e); else map.set(l, [e]);
  }
  const rank = (label: string): number => {
    if (key === 'rating') return label === '未评分' ? -1 : label.length;
    if (key === 'added') { const m = label.match(/^(\d{4})-(\d{2})$/); return m ? +m[1] * 100 + +m[2] : -Infinity; }
    const n = parseInt(label, 10);
    return Number.isNaN(n) ? -Infinity : n;
  };
  return [...map.entries()]
    .sort((a, b) => rank(b[0]) - rank(a[0]))
    .map(([label, es]) => ({ key: key + ':' + label, label, entries: es }));
}
