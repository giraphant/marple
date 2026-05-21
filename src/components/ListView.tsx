import { useState, useRef, useEffect } from 'preact/hooks';
import type { Entry, EntryType } from '../types';
import { TYPE_BY_ID } from '../types';
import { SORT_OPTIONS, type SortKey, type SortDir } from '../list-sort';
import { Card } from './Card';
import { Dashboard } from './Dashboard';
import { Icon } from './Icon';

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
  const isFiltered = !!(query || themeFilter || minRating || extraActive);
  const visible = query ? filtered : filtered.slice(0, limit);

  return (
    <div class="flex-1 flex flex-col min-h-0">
      <header class="bg-surface/95 backdrop-blur border-b border-base sticky top-0 z-10">
        <div class="px-8 pt-3.5 pb-2.5 flex items-center justify-between gap-4">
          <div class="flex items-baseline gap-2.5 min-w-0">
            <div class="text-[22px] font-bold tracking-[-0.02em] text-primary truncate">
              {typeMeta?.label ?? type}
            </div>
            <div class="text-[12px] text-muted tabular-nums">
              {filtered.length}{filtered.length !== typeEntries.length && <span> / {typeEntries.length}</span>}
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

        {/* Active-filters + sort bar: filters are SET via the 筛选 menu or
            contextual clicks (card chips / author names) and SHOWN here as
            removable chips; sort sits on the right. */}
        <div class="px-8 pb-2 flex items-center gap-2 flex-wrap">
          <FilterControl
            type={type}
            minRating={minRating}
            authorFilter={authorFilter}
            hasPdfOnly={hasPdfOnly}
            active={minRating > 0 || extraActive}
            onMinRatingChange={onMinRatingChange}
            onAuthorFilterChange={onAuthorFilterChange}
            onToggleHasPdf={onToggleHasPdf}
            onClear={() => { onMinRatingChange(0); onClearExtraFilters(); }}
          />

          {minRating > 0 && <FilterChip label={`评分 ≥ ${minRating}`} onClear={() => onMinRatingChange(0)} />}
          {themeFilter && <FilterChip label={themeFilter} onClear={onClearTheme} />}
          {authorFilter.trim() && <FilterChip label={authorFilter} onClear={() => onAuthorFilterChange('')} />}
          {hasPdfOnly && <FilterChip label="有 PDF" onClear={() => onToggleHasPdf(false)} />}

          {searchLoading && <span class="text-[11px] text-muted">全文搜索中…</span>}
          {searchError && <span class="text-[11px] text-danger" title={searchError}>全文搜索失败，已用本地匹配</span>}

          <div class="ml-auto shrink-0 flex items-center gap-1 text-[11px] text-secondary">
            <span class="text-muted">排序</span>
            <select
              value={sortKey}
              onChange={(e) => onSortKeyChange((e.target as HTMLSelectElement).value as SortKey)}
              class="bg-surface border border-base rounded-md px-1.5 py-0.5 text-[11px] text-secondary focus:outline-none"
            >
              {SORT_OPTIONS.map(o => <option key={o.key} value={o.key}>{o.label}</option>)}
            </select>
            {sortKey !== 'default' && (
              <button
                onClick={onToggleSortDir}
                title={sortDir === 'asc' ? '升序（点击切降序）' : '降序（点击切升序）'}
                class="px-1.5 py-0.5 rounded-md hover:bg-surface-2 tabular-nums"
              >{sortDir === 'asc' ? '↑' : '↓'}</button>
            )}
          </div>
        </div>
      </header>

      <main class="flex-1 overflow-auto scrollbar-thin px-8 py-6">
        {!isFiltered && (
          <Dashboard
            type={type}
            typeEntries={typeEntries}
            onThemeClick={onThemeClick}
            onOpen={e => onCardClick(e, { meta: false })}
          />
        )}
        {filtered.length === 0
          ? <div class="text-sm text-muted py-20 text-center">没有匹配的条目</div>
          : (
            <>
              <div class="columns-[18rem] gap-5">
                {visible.map(e => (
                  <div class="mb-5 break-inside-avoid" key={e.path}>
                    <Card
                      entry={e}
                      onClick={(entry, ev) => onCardClick(entry, { meta: ev.metaKey || ev.ctrlKey })}
                      onThemeClick={onThemeClick}
                      onAuthorClick={onAuthorFilterChange}
                    />
                  </div>
                ))}
              </div>
              {!query && !themeFilter && filtered.length > limit && (
                <div class="text-center mt-6">
                  <button
                    onClick={onLoadMore}
                    class="px-4 py-2 bg-surface border border-base rounded-xl text-sm shadow-soft-sm hover:shadow-soft hover:-translate-y-px transition"
                  >
                    再加载 500 ( 已显示 {limit} / {filtered.length} )
                  </button>
                </div>
              )}
            </>
          )
        }
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

/** All filters (rating / author / has-PDF) behind one popover, so the toolbar
 *  itself stays an active-state bar. "有 PDF" only applies to papers and books
 *  (the types build-index scans for a matching source PDF). */
function FilterControl({
  type, minRating, authorFilter, hasPdfOnly, active,
  onMinRatingChange, onAuthorFilterChange, onToggleHasPdf, onClear,
}: {
  type: EntryType;
  minRating: number;
  authorFilter: string;
  hasPdfOnly: boolean;
  active: boolean;
  onMinRatingChange: (n: number) => void;
  onAuthorFilterChange: (v: string) => void;
  onToggleHasPdf: (v: boolean) => void;
  onClear: () => void;
}) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const showPdf = type === 'paper-analysis' || type === 'book-overview';

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
        class={`inline-flex items-center gap-1 text-[11px] px-2 py-0.5 rounded-md border transition ${
          active
            ? 'border-accent bg-accent-bg text-accent-text'
            : 'border-base text-secondary hover:bg-surface-2'
        }`}
        title="筛选（评分 / 作者 / PDF）"
      >
        <Icon name="funnel" size={12} />
        筛选{active && <span class="text-accent-text">•</span>}
      </button>
      {open && (
        <div class="absolute left-0 top-full mt-1 z-20 bg-surface border border-base rounded-xl shadow-soft-lg p-3 w-[230px] space-y-3">
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
          {active && (
            <button onClick={onClear} class="text-[11px] text-muted hover:text-primary">
              清空全部筛选
            </button>
          )}
        </div>
      )}
    </div>
  );
}
