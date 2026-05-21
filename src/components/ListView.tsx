import { useState, useRef, useEffect, useMemo } from 'preact/hooks';
import type { ComponentChildren } from 'preact';
import type { Entry, EntryType } from '../types';
import { TYPE_BY_ID } from '../types';
import { SORT_OPTIONS, type SortKey, type SortDir } from '../list-sort';
import { Card } from './Card';
import { Icon, type IconName } from './Icon';
import { TypeIcon } from './TypeIcon';

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
  minRating: number;
  themeFilter: string | null;
  sortKey: SortKey;
  sortDir: SortDir;
  authorFilter: string;
  hasPdfOnly: boolean;
  limit: number;
  searchLoading: boolean;
  searchError: string | null;
  searchMode: 'lex' | 'hybrid';
  onToggleSearchMode: () => void;
  onOpenSearch: () => void;
  onClearQuery: () => void;
  onMinRatingChange: (n: number) => void;
  onClearTheme: () => void;
  onSortKeyChange: (key: SortKey) => void;
  onToggleSortDir: () => void;
  onAuthorFilterChange: (v: string) => void;
  onToggleHasPdf: (v: boolean) => void;
  onClearExtraFilters: () => void;
  onLoadMore: () => void;
  onCardClick: (entry: Entry, modifiers: { meta: boolean }) => void;
  onThemeClick: (theme: string) => void;
}

export function ListView({
  entries: _entries, type, typeEntries, filtered, query, minRating, themeFilter,
  sortKey, sortDir, authorFilter, hasPdfOnly, limit,
  searchLoading, searchError,
  onOpenSearch, onClearQuery, onMinRatingChange, onClearTheme,
  onSortKeyChange, onToggleSortDir, onAuthorFilterChange, onToggleHasPdf, onClearExtraFilters,
  onLoadMore, onCardClick, onThemeClick,
}: Props) {
  void _entries;
  const typeMeta = TYPE_BY_ID[type];
  const extraActive = !!(authorFilter.trim() || hasPdfOnly);
  const filterActive = minRating > 0 || extraActive;
  const showPdf = type === 'paper-analysis' || type === 'book-overview';
  const visible = query ? filtered : filtered.slice(0, limit);

  const [groupBy, setGroupBy] = useState<GroupKey>('none');
  const groups = useMemo(() => buildGroups(visible, groupBy), [visible, groupBy]);

  const renderCard = (e: Entry) => (
    <Card
      entry={e}
      onClick={(entry, ev) => onCardClick(entry, { meta: ev.metaKey || ev.ctrlKey })}
      onThemeClick={onThemeClick}
      onAuthorClick={onAuthorFilterChange}
    />
  );

  const loadMore = (!query && !themeFilter && filtered.length > limit) ? (
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
        <div class="px-8 pt-4 pb-2 flex items-center justify-between gap-4">
          <div class="flex items-center gap-2.5 min-w-0">
            <TypeIcon type={type} scale={1.4} />
            <div class="text-[20px] font-bold tracking-[-0.02em] text-primary truncate">
              {typeMeta?.label ?? type}
            </div>
          </div>

          {query ? (
            <div class="inline-flex items-center gap-1 shrink-0">
              <button
                onClick={onOpenSearch}
                title="点击修改 (⌘K)"
                class="inline-flex items-center gap-1 text-[12px] px-2.5 py-1 rounded-lg bg-accent-bg text-accent-text border border-accent/30 transition"
              >
                <Icon name="magnifying-glass" size={12} />
                <span class="truncate max-w-[200px]">{query}</span>
              </button>
              <button
                onClick={onClearQuery}
                title="清空"
                class="text-muted hover:text-primary p-1 rounded-lg hover:bg-hover/60"
              >
                <Icon name="x" size={12} />
              </button>
            </div>
          ) : (
            <button
              onClick={onOpenSearch}
              title="搜索 (⌘K)"
              aria-label="搜索"
              class="shrink-0 text-muted hover:text-primary p-1.5 rounded-lg hover:bg-hover/60"
            >
              <Icon name="magnifying-glass" size={16} />
            </button>
          )}
        </div>

        {/* Toolbar: active-filter chips on the left, count + filter/sort/group
            icon menus clustered on the right (Capacities-style arrangement). */}
        <div class="px-8 pb-2 flex items-center gap-2 flex-wrap">
          {minRating > 0 && <FilterChip label={`评分 ≥ ${minRating}`} onClear={() => onMinRatingChange(0)} />}
          {themeFilter && <FilterChip label={themeFilter} onClear={onClearTheme} />}
          {authorFilter.trim() && <FilterChip label={authorFilter} onClear={() => onAuthorFilterChange('')} />}
          {hasPdfOnly && <FilterChip label="有 PDF" onClear={() => onToggleHasPdf(false)} />}

          {searchLoading && <span class="text-[11px] text-muted">全文搜索中…</span>}
          {searchError && <span class="text-[11px] text-danger" title={searchError}>全文搜索失败，已用本地匹配</span>}

          <div class="ml-auto shrink-0 flex items-center gap-1">
            <span class="text-[11px] text-muted tabular-nums mr-1.5">
              # {filtered.length}{filtered.length !== typeEntries.length ? ` / ${typeEntries.length}` : ''}
            </span>

            <Pop icon="funnel" active={filterActive} title="筛选（评分 / 作者 / PDF）" width="w-[230px]">
              <div class="space-y-3">
                <div>
                  <div class="text-[11px] text-muted mb-1">评分 ≥</div>
                  <div class="flex items-center gap-1">
                    {[0, 1, 2, 3, 4].map(n => (
                      <button
                        key={n}
                        onClick={() => onMinRatingChange(n)}
                        class={`px-2 py-0.5 rounded-md text-[11px] tabular-nums ${minRating === n ? 'bg-accent-bg text-accent-text' : 'text-secondary hover:bg-surface-2'}`}
                      >{n || '任意'}</button>
                    ))}
                  </div>
                </div>
                <label class="block text-[11px] text-muted">
                  作者
                  <input
                    type="text"
                    value={authorFilter}
                    placeholder="按作者筛选"
                    onInput={(e) => onAuthorFilterChange((e.target as HTMLInputElement).value)}
                    class="mt-1 w-full px-2 py-1 border border-base rounded-md text-[12px] bg-page text-secondary focus:outline-none focus:border-accent"
                  />
                </label>
                {showPdf && (
                  <label class="flex items-center gap-1.5 text-[11px] text-secondary cursor-pointer">
                    <input
                      type="checkbox"
                      checked={hasPdfOnly}
                      onChange={(e) => onToggleHasPdf((e.target as HTMLInputElement).checked)}
                    />
                    仅含 PDF
                  </label>
                )}
                {filterActive && (
                  <button onClick={() => { onMinRatingChange(0); onClearExtraFilters(); }} class="text-[11px] text-muted hover:text-primary">
                    清空全部筛选
                  </button>
                )}
              </div>
            </Pop>

            <Pop icon="sort" active={sortKey !== 'default'} title="排序" width="w-[190px]">
              <div class="text-[11px] text-muted px-1 pb-1">排序依据</div>
              <div class="space-y-0.5">
                {SORT_OPTIONS.map(o => (
                  <button
                    key={o.key}
                    onClick={() => onSortKeyChange(o.key)}
                    class={`w-full text-left px-2 py-1 rounded-md text-[12px] ${sortKey === o.key ? 'bg-accent-bg text-accent-text' : 'text-secondary hover:bg-surface-2'}`}
                  >{o.label}</button>
                ))}
              </div>
              {sortKey !== 'default' && (
                <button
                  onClick={onToggleSortDir}
                  class="mt-1.5 pt-1.5 w-full text-left px-2 text-[11px] text-muted hover:text-primary border-t border-base"
                >
                  方向：{sortDir === 'asc' ? '升序 ↑' : '降序 ↓'}（点击切换）
                </button>
              )}
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

/** A removable active-filter chip shown in the toolbar; click to clear. */
function FilterChip({ label, onClear }: { label: string; onClear: () => void }) {
  return (
    <button
      onClick={onClear}
      title="点击移除"
      class="inline-flex items-center gap-1 text-[11px] px-2 py-0.5 rounded-md bg-accent-bg text-accent-text border border-accent/30 hover:bg-accent/15 transition"
    >
      <span class="truncate max-w-[160px]">{label}</span>
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
        class={`p-1.5 rounded-md transition ${active ? 'bg-accent-bg text-accent-text' : 'text-muted hover:text-primary hover:bg-surface-2'}`}
      >
        <Icon name={icon} size={15} />
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
