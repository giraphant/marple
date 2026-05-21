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
  searchLoading, searchError, searchMode, onToggleSearchMode,
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

        <div class="px-8 pb-1.5 flex items-center gap-3 flex-wrap">
          <div class="flex items-center gap-1 text-[11px] text-secondary">
            <span>评分 ≥</span>
            {[0, 1, 2, 3, 4].map(n => (
              <button
                key={n}
                onClick={() => onMinRatingChange(n)}
                class={`px-1.5 py-0.5 rounded-md ${minRating === n ? 'bg-accent-bg text-accent-text' : 'hover:bg-surface-2'}`}
              >{n || '·'}</button>
            ))}
          </div>

          <button
            type="button"
            class={`text-[11px] px-2 py-0.5 rounded-md ${
              searchMode === 'hybrid'
                ? 'bg-accent-bg text-accent-text'
                : 'bg-surface-2 text-secondary'
            }`}
            title="切换搜索模式（Cmd+K 后 Tab）"
            onClick={onToggleSearchMode}
          >
            {searchMode === 'hybrid' ? '深度' : '快速'}
          </button>

          <div class="flex items-center gap-1 text-[11px] text-secondary">
            <span>排序</span>
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

          <FilterControl
            type={type}
            authorFilter={authorFilter}
            hasPdfOnly={hasPdfOnly}
            active={extraActive}
            onAuthorFilterChange={onAuthorFilterChange}
            onToggleHasPdf={onToggleHasPdf}
            onClear={onClearExtraFilters}
          />

          {searchLoading && (
            <div class="text-[11px] text-muted">全文搜索中…</div>
          )}
          {searchError && (
            <div class="text-[11px] text-danger" title={searchError}>
              全文搜索失败，已使用本地匹配
            </div>
          )}
        </div>
        {themeFilter && (
          <div class="px-6 pb-2 flex items-center gap-2">
            <span class="text-[11px] text-muted">主题筛选</span>
            <button
              onClick={onClearTheme}
              class="text-[11px] px-2 py-0.5 rounded bg-accent-bg text-accent-text border border-accent/30 hover:bg-accent-bg transition"
            >
              {themeFilter} <span class="text-accent-text ml-1">✕</span>
            </button>
          </div>
        )}
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
              <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
                {visible.map(e => (
                  <Card
                    entry={e}
                    onClick={(entry, ev) => onCardClick(entry, { meta: ev.metaKey || ev.ctrlKey })}
                    key={e.path}
                  />
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

/** QUA-59: author / has-PDF filters behind a small popover so the header stays
 *  tidy. "有 PDF" only applies to papers and books (the types build-index scans
 *  for a matching source PDF). */
function FilterControl({
  type, authorFilter, hasPdfOnly, active, onAuthorFilterChange, onToggleHasPdf, onClear,
}: {
  type: EntryType;
  authorFilter: string;
  hasPdfOnly: boolean;
  active: boolean;
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
        class={`inline-flex items-center gap-1 text-[11px] px-1.5 py-0.5 rounded border transition ${
          active
            ? 'border-accent bg-accent-bg text-accent-text'
            : 'border-base text-secondary hover:bg-surface-2'
        }`}
        title="筛选（作者 / PDF）"
      >
        <Icon name="funnel" size={12} />
        筛选{active && <span class="text-accent-text">•</span>}
      </button>
      {open && (
        <div class="absolute left-0 top-full mt-1 z-20 bg-surface border border-base rounded shadow-lg p-3 w-[220px] space-y-2.5">
          <label class="block text-[11px] text-muted">
            作者
            <input
              type="text"
              value={authorFilter}
              placeholder="按作者筛选"
              onInput={(e) => onAuthorFilterChange((e.target as HTMLInputElement).value)}
              class="mt-1 w-full px-2 py-1 border border-base rounded text-[12px] bg-page text-secondary focus:outline-none focus:border-accent"
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
              清空筛选
            </button>
          )}
        </div>
      )}
    </div>
  );
}
